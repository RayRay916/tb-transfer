# TBTransfer code audit

Focused review of the files listed in the audit brief. Findings below are limited
to correctness, edge cases, and race conditions — not style. Severity reflects
likelihood × impact: a `high` will almost certainly bite a real user; a `low`
is a corner case worth a comment.

Capped at ~15 most-impactful issues. Each file gets a section even when no
issues were found (so absences are explicit, not silent).

Audit covers the codebase at HEAD on 2026-05-11. Build was clean and all tests
pass after the audit's parser-access change.

---

## `Sources/TBTransfer/Network/TBInterfaceMonitor.swift`

### Issue: Own-MAC filter only matches the peer's *own* interface entry
**File:** Sources/TBTransfer/Network/TBInterfaceMonitor.swift:132-133
**Severity:** low
**Description:** `ownMacByInterface[line.ifname]` returns the local Mac's
own MAC for that ifname. The compare `if line.mac == ownMac { continue }`
only drops self-loops on the *same* interface. Across-port collisions (own
MAC on en2 showing up via en3's ARP cache, which can happen with bridged
TB configurations) leak through as a phantom peer.
**Repro:** Hard to repro on a 2-port Mac; the architectural concern is that
the predicate is too narrow. A test where the same MAC appears under two
ifnames will surface it.
**Suggested fix:** Build a single set:
`let ownMacs = Set(active.map(\.macAddress))` and check membership.

### Issue: `parseGlobalArpTable` searches all tokens for the IP token
**File:** Sources/TBTransfer/Network/TBInterfaceMonitor.swift:260
**Severity:** low
**Description:** `tokens.first(where: { $0.hasPrefix("(") && $0.hasSuffix(")") })`
will match a parenthesized *hostname* (token 0) and treat it as the IP.
Today's `?` and `mbp.local` hostnames don't trigger this, but a pathological
remote name would silently nuke that peer's row.
**Suggested fix:** Skip token 0 when searching: `tokens.dropFirst().first(where:)`.

---

## `Sources/TBTransfer/Persistence/PeerStore.swift`

### Issue: `prefillForNewPeer` auto-applies `mbp1` defaults to any `mbp.*` hostname
**File:** Sources/TBTransfer/Persistence/PeerStore.swift:168-172
**Severity:** medium
**Description:** The `isMbp1` predicate accepts `normalized.hasPrefix("mbp.")`,
so a peer named `mbp16.local`, `mbpdev.local`, or `mbp9000.local` gets the
hard-coded developer profile: label "mbp1", username "Apple", key
`~/.ssh/id_ed25519`. The exact-name set already covers the intended hosts;
the prefix clause is too broad and will surprise any user not named "Apple".
**Repro:** Plug in any Mac with a hostname starting with `mbp.` other than
`mbp.local`/`mbp1.local`/`mbp16.local`/`mbp-tb.local`. Observed prefilled
defaults match the dev's own machine.
**Suggested fix:** Drop the `hasPrefix("mbp.")` branch; rely on the exact-name
set. Other peers fall through to the generic path.

### Issue: `reconcile` calls `save()` once per discovered peer per refresh
**File:** Sources/TBTransfer/Persistence/PeerStore.swift:127, 138
**Severity:** low
**Description:** Each discovery cycle iterates discoveredPeers and calls
`reconcile`, which writes peers.json to disk inside the function. With N
peers that's N atomic JSON writes every 5 seconds. Trivial cost today, but
noisy under fsevent observers / Time Machine / backup tools.
**Suggested fix:** Have `reconcile` mutate the in-memory list without saving;
batch-save at the end of the discovery pass from AppState.

---

## `Sources/TBTransfer/Persistence/TransferHistory.swift`

### No significant issues
File is small and disciplined: tolerates missing file, atomic writes, dual
trim on load+append, `.iso8601` encode/decode strategies match.

---

## `Sources/TBTransfer/Transfer/TransferEngine.swift`

### Issue: `cancel()` issued during preflight / size-estimation has no effect for up to 15 seconds
**File:** Sources/TBTransfer/Transfer/TransferEngine.swift:58-65, 377-401
**Severity:** medium
**Description:** Only the rsync pipeline stores its `Process` into
`runningProcess`. The `preflight` and `estimateTotalBytes` SSH calls go
through `ShellRunner.run` whose Process never escapes — so `cancel()` cannot
terminate it. The status flag is set to `.cancelled`, but the preflight
keeps running until it returns (up to 15s on a hung ssh handshake). The UI
shows a queued/running task that won't go away when the user presses Cancel.
**Repro:** Attempt a push to a peer with `ssh` blocked at the network layer
(stale IP). Press Cancel during the connect; observe a 15s delay before the
task moves to history.
**Suggested fix:** Plumb cancellation through `ShellRunner.run` (Process
ref-back-via-actor, or honor `Task.isCancelled`), so preflight can be killed.

### Issue: Stderr drain race after `runBashPipeline` exits
**File:** Sources/TBTransfer/Transfer/TransferEngine.swift:540-547
**Severity:** medium
**Description:** After `process.waitUntilExit()` returns, the code sets both
pipes' `readabilityHandler = nil` and *then* calls `readToEnd()` to drain
leftover stderr. Setting the handler to nil doesn't synchronize with a
handler call already in flight on its internal dispatch queue, and the
handler may have already drained the pipe between exit and `readToEnd()`.
Net effect: the last chunk of rsync's stderr can be lost or duplicated.
User-visible as a truncated/empty `task.error` in the recent rows.
**Repro:** Force rsync to fail with a multi-line error (e.g., bad SSH key);
observe that the captured error sometimes ends abruptly.
**Suggested fix:** Accumulate everything via the readability handler with a
final `readabilityHandler = nil` *after* `readToEnd()` has flushed (or drop
`readToEnd()` and rely solely on the handler having run to completion).

### Issue: `completedTasks` index assumption can desync if engine ever trims its history
**File:** Sources/TBTransfer/Transfer/TransferEngine.swift:316, Sources/TBTransfer/AppState.swift:88-95
**Severity:** low
**Description:** `harvestCompletedTransfers` uses
`completed.count > lastCompletedCount` and `prefix(count - last)` to find new
entries. Today `completedTasks` only grows (and lives forever in memory),
which masks the brittle invariant: any future trimming of `completedTasks`
would silently break harvest. Not a current bug, but worth tracking by ID
instead of count.
**Suggested fix:** Track harvested IDs in a `Set<UUID>` or move completed
tasks to "needs harvest" → "harvested" queues.

---

## `Sources/TBTransfer/Transfer/MirrorWatcher.swift`

### Issue: Use-after-free race in FSEvents `CallbackBox` lifetime
**File:** Sources/TBTransfer/Transfer/MirrorWatcher.swift:467-484, 380-381
**Severity:** medium (needs TSan to verify)
**Description:** `startWatcher` does `Unmanaged.passRetained(box)` to bump
the refcount, stores the raw pointer in `WatcherHandle.boxPtr`. The C
callback uses `Unmanaged.fromOpaque(info).takeUnretainedValue()` — does not
retain. `stopWatcher` calls `release()` on the same pointer.
`FSEventStreamInvalidate` should drain pending callbacks per Apple docs, but
provides no guarantees about in-flight callbacks already executing on
`fsEventQueue`. If the dispatch queue is mid-callback when we release, the
box can be freed underneath it. The callback reads `box.configID` and
`box.owner` synchronously before hopping to MainActor — so the deref is in
the window.
**Repro:** Tight loop of `setEnabled(true)`/`setEnabled(false)` while
touching files in the watched dir, under TSan.
**Suggested fix:** Simplest — hold a strong ref to the box in the
`WatcherHandle` (e.g. `let box: CallbackBox`), pass `Unmanaged.passUnretained`
in the C context, and let normal ARC handle teardown.

### Issue: `runMkdir(ip:)` parameter is unused; SSH target re-resolved internally
**File:** Sources/TBTransfer/Transfer/MirrorWatcher.swift:274-295
**Severity:** medium
**Description:** Signature is
`runMkdir(peer:ip:remotePath:)`, but the body calls
`SSHHelper.sshCommand(for: peer)` which uses
`peer.lastSeenIP ?? peer.lastKnownHostname` internally — ignoring the
`ip` arg entirely. Works today because `syncNow` already verified
`peer.lastSeenIP` is non-empty, but the parameter is misleading and creates
a footgun if a future change to SSHHelper's selection logic diverges from
the caller's intent.
**Suggested fix:** Drop the `ip` parameter from `runMkdir`, or apply it by
constructing a peer copy with `lastSeenIP = ip` and passing that to
SSHHelper.

---

## `Sources/TBTransfer/SSH/SSHHelper.swift`

### Issue: `listDirectory` parser is split on `\n` — filenames containing newline produce phantom entries
**File:** Sources/TBTransfer/SSH/SSHHelper.swift:157-176
**Severity:** low
**Description:** Output is line-separated; the remote `printf "%s\t%s\t%s\t%s\n" "$k" "$s" "$m" "$f"` and the parser splits on `\n`. A file with a literal newline in its name (`touch $'foo\nbar'`) emits two lines that both parse as garbage entries. Filenames with `\t` are handled (`parts[3...]` joined) but newlines are not.
**Suggested fix:** Use NUL-delimited output and split on NUL.

### Issue: `effectiveHost` silently falls back to `.local` hostname which can resolve over Wi-Fi
**File:** Sources/TBTransfer/SSH/SSHHelper.swift:215-217
**Severity:** medium
**Description:** When `peer.lastSeenIP` is nil, the fallback is
`peer.lastKnownHostname` — typically a `.local` (mDNS) name. SSH happily
resolves that over the regular network interface (Wi-Fi or wired) at ~1 Gb/s.
The app continues to work, but completely defeats the Thunderbolt speed
benefit. No error, no warning.
**Repro:** Set / wait for `peer.lastSeenIP` to be nil. Start a transfer. Speed
caps at LAN bandwidth.
**Suggested fix:** When `lastSeenIP` is nil, refuse the transfer with a
"No TB link" error rather than silently downgrading.

---

## `Sources/TBTransfer/AppState.swift`

### No significant issues
`pasteFromClipboard` uses `as?` (safe cast). Discovery loop captures `[weak self]`.
The status string formatting is straightforward. `harvestCompletedTransfers`'s
prefix-then-reverse-then-prepend dance is correct but worth a one-line comment;
that's documentation rather than a bug.

---

## `Sources/TBTransfer/UI/MainWindow.swift`

### Issue: `.onDrop` always returns `true` even when no file URLs are accepted
**File:** Sources/TBTransfer/UI/MainWindow.swift:196-199, 552-557, 570-573
**Severity:** low
**Description:** All three `.onDrop` sites return `true` unconditionally. If
the dropped payload doesn't include a file URL (e.g. dragged text from a
browser), the drop animation completes, the drop zone resets, but nothing is
queued. The user sees no feedback that the drop was ignored.
**Suggested fix:** Synchronously check `providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) })` and return false if empty. (Actual URL extraction can still be async.)

---

## `Sources/TBTransfer/UI/LocalFileBrowser.swift`

### No significant issues
The browser respects symlinks (with a minor cosmetic note that symlinks-to-dirs
show as files — not worth fixing). Formatter globals are `@MainActor` so the
compiler enforces correctness. URL-based selection survives renavigation.

---

## `Sources/TBTransfer/UI/RemoteFileBrowser.swift`

### Issue: Peer change mid-load can clobber new peer's listing with the old peer's result
**File:** Sources/TBTransfer/UI/RemoteFileBrowser.swift:33, 336-354
**Severity:** medium
**Description:** `.task(id: TaskKey(peerID:path:token:))` is supposed to
cancel the prior task when the key changes. But `SSHHelper.listDirectory` ->
`ShellRunner.run` doesn't honor `Task.isCancelled`; the SSH process keeps
running and eventually assigns `entries = listed` for the *old* peer. The
new task may have already populated `entries` for the new peer, which then
gets overwritten when the old SSH returns. Visible as a flicker back to the
old peer's content.
**Repro:** Trigger a slow remote listing (huge directory), then switch peers
in the sidebar before the listing completes. Observe content flickers.
**Suggested fix:** Capture `peer.id` at the start of `loadIfPossible`; after
`await SSHHelper.listDirectory`, only assign `entries` if `peer.id` still
matches what was captured (or use a generation counter in `loadToken` /
`TaskKey`).

---

## `Sources/TBTransfer/UI/MenubarController.swift`

### Issue: `formatThroughput` uses base-1000; `TransferQueueView` uses base-1024 — same data, two units
**File:** Sources/TBTransfer/UI/MenubarController.swift:365-384, Sources/TBTransfer/UI/TransferQueueView.swift:336-348, 391-404
**Severity:** medium
**Description:** Menubar's `formatThroughput` divides by 1000 (decimal SI),
while `TransferQueueView`'s `formatBytesPerSecond` and `formatBytes` divide
by 1024 (binary). For a transfer at 2,000,000,000 B/s, menubar shows
"2.00 GB/s" and the queue view shows "1.86 GB/s". User sees two different
speeds for the same transfer simultaneously.
**Suggested fix:** Pick one base (1024 is more familiar for file size; 1000
is more "MB"-correct in SI). Use it everywhere.

### Issue: 500ms refresh timer rebuilds `item.menu` even while the menu is open
**File:** Sources/TBTransfer/UI/MenubarController.swift:81-87, 132
**Severity:** medium (needs UX verification on a real menu open)
**Description:** Every 500ms `refresh()` assigns `item.menu = buildMenu()`.
If the user has the menu open (or a submenu hovered), assigning a brand-new
NSMenu can dismiss it or break ongoing hover state on macOS. Worse, it
allocates a fresh menu twice per second whether or not anything changed.
**Repro:** Open the menubar, hover a peer's submenu, wait 500ms.
**Suggested fix:** Track whether the menu is open (NSMenu delegate
`menuWillOpen`/`menuDidClose`) and skip rebuilds while open. Better yet,
only rebuild when state actually changed (peer set / running tasks).

---

## `Sources/TBTransfer/UI/TransferQueueView.swift`

### No significant issues beyond the byte-unit inconsistency
The 1024-vs-1000 issue is covered in the MenubarController section. The rest
of the view is straightforward formatting.

---

## Summary

**Issues by severity (15 total):**
- High: 0
- Medium: 9 (cancel-during-preflight, stderr drain race, FSEvents UAF,
  runMkdir unused param, effectiveHost Wi-Fi fallback, peer-change load
  clobber, byte-unit inconsistency, refresh-while-menu-open, mbp.* prefill)
- Low: 6 (own-MAC filter scope, parseGlobalArpTable IP-token search,
  reconcile per-peer save, completedTasks index assumption, listDirectory
  newline split, onDrop returning true)
- High-risk areas to prioritize: **cancellation surface** in TransferEngine
  (two medium issues both hurt UX), **FSEvents lifetime** in MirrorWatcher
  (one latent UAF), and **silent unit/host fallbacks** (effectiveHost
  Wi-Fi, byte-unit base mismatch) where the app "works" but does the
  wrong thing.

Files with no significant issues: TransferHistory.swift, AppState.swift,
LocalFileBrowser.swift, TransferQueueView.swift.
