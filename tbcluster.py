#!/usr/bin/env python3
"""
tbcluster — TB5 cluster model dashboard + transfer tool.

Runs on ANY node of the Studio/mbp1/mbp2 Thunderbolt triangle. It:
  1. detects which node it is and which peers are reachable over TB5,
  2. scans the local model stores (.lmstudio, .exo, .cache/huggingface/hub,
     .mtplx) and lists ONLY fully-completed downloads,
  3. lets you pick models + destination node(s) + a destination "home"
     (.lmstudio or .exo),
  4. transfers over TB5 ONLY (rsync daemon, plain-TCP, the trusted-mode fast
     path — same mechanics as TBTransfer.app), and
  5. if the home is .exo, auto-creates the EXO custom model card.

Stdlib only (no pip/uv) so it runs unmodified on every node.

Modes:
  (no args)            interactive dashboard
  --list               print completed local models and exit
  --self-info          print detected node + reachable TB peers and exit
  --scan-json          print completed local models as JSON (used for remote
                       scans and testing) and exit
  --to NODE[,NODE] --models SEL --home {lmstudio,exo} [--yes] [--dry-run]
                       non-interactive transfer
"""
import argparse, json, os, re, shlex, socket, subprocess, sys, time
from pathlib import Path

HOME = Path.home()
DAEMON_PORT = 8730
PARALLEL = 16
RSYNC_FLAGS = ["-aWL", "--inplace", "--no-compress", "--partial"]
DEFAULT_KEYS = ["~/.ssh/tbtransfer_ed25519", "~/.ssh/id_ed25519", "~/.ssh/id_rsa"]

# Stable per-node TB-bridge MAC prefixes (first 5 octets) + login user.
NODES = [
    {"name": "mac-studio", "mac": "36:0a:fa:6e:db", "user": "ray", "hostnames": ["mac-studio"]},
    {"name": "mbp1",       "mac": "36:c2:03:f3:96", "user": "rd",  "hostnames": ["mbp", "mbp1"]},
    {"name": "mbp2",       "mac": "36:c3:e8:89:79", "user": "ray", "hostnames": ["mbp2"]},
    {"name": "ms2",        "mac": "36:9b:32:eb:02", "user": "ray", "hostnames": ["ms2", "mac-studio2"]},
]

STORES = {
    "lmstudio": HOME / ".lmstudio/models",
    "exo":      HOME / ".exo/models",
    "hf":       HOME / ".cache/huggingface/hub",
    "mtplx":    HOME / ".mtplx/models",
}
HOME_DIRS = {  # destination "home" -> store key + on-node path
    "lmstudio": ".lmstudio/models",
    "exo":      ".exo/models",
    "skulk":    ".exo/models",
}
PARTIAL_RE = re.compile(r"\.(part|partial|download|incomplete|tmp)$", re.I)
WEIGHT_RE = re.compile(r"\.(safetensors|gguf|bin|npz)$", re.I)
SKIP_NAMES = {"caches", ".DS_Store", ".locks", "tmp", "version.txt", ".cache"}

# ----------------------------------------------------------------------------- ANSI
_TTY = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None
def c(s, code): return f"\033[{code}m{s}\033[0m" if _TTY else str(s)
def bold(s):  return c(s, "1")
def dim(s):   return c(s, "2")
def grn(s):   return c(s, "32")
def yel(s):   return c(s, "33")
def cyn(s):   return c(s, "36")
def red(s):   return c(s, "31")

def human(n):
    n = float(n)
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or u == "TB":
            return f"{n:.0f}{u}" if u in ("B", "KB") else f"{n:.1f}{u}"
        n /= 1024

# ----------------------------------------------------------------------------- shell
def run(cmd, timeout=None, inp=None):
    """Run argv list; return (rc, stdout, stderr)."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           input=inp)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    except FileNotFoundError as e:
        return 127, "", str(e)

def gnu_rsync():
    for p in ("/opt/homebrew/bin/rsync", "/usr/local/bin/rsync", "/opt/local/bin/rsync"):
        if os.access(p, os.X_OK):
            return p
    return "rsync"
RSYNC = gnu_rsync()

# ----------------------------------------------------------------------------- mac utils
def mac_octets(s, n=None):
    try:
        o = [int(x, 16) for x in s.strip().split(":")]
    except ValueError:
        return None
    return o[:n] if n else o

def mac_matches(prefix, mac):
    a, b = mac_octets(prefix), mac_octets(mac, 5)
    return a is not None and b is not None and a[:5] == b

# ----------------------------------------------------------------------------- node detect
def tb_ifaces():
    """Return {iface: {'ip': ip|None, 'mac': mac|None}} for mtu-65518 ifaces.

    On macOS the interface header line carries both flags and mtu, e.g.
    `en3: flags=8863<...> mtu 65518`, with ether/inet on the indented lines
    that follow until the next header.
    """
    rc, out, _ = run(["ifconfig"])
    res, cur, is_tb = {}, None, False
    for line in out.splitlines():
        m = re.match(r"^(\w+):\s.*\bmtu (\d+)", line)
        if m:
            cur, is_tb = m.group(1), (m.group(2) == "65518")
            if is_tb:
                res[cur] = {"ip": None, "mac": None}
            continue
        if not is_tb or cur not in res:
            continue
        me = re.search(r"\bether ([0-9a-f:]+)", line)
        if me: res[cur]["mac"] = me.group(1)
        mi = re.search(r"\binet (169\.254\.\d+\.\d+)", line)
        if mi: res[cur]["ip"] = mi.group(1)
    return res

def detect_self():
    ifs = tb_ifaces()
    mymacs = [v["mac"] for v in ifs.values() if v["mac"]]
    for node in NODES:
        if any(mac_matches(node["mac"], mm) for mm in mymacs):
            return node
    rc, host, _ = run(["hostname", "-s"])
    host = host.strip()
    for node in NODES:
        if host in node["hostnames"] or host == node["name"]:
            return node
    return {"name": host or "unknown", "mac": "", "user": os.environ.get("USER", "ray"), "hostnames": [host]}

def ssh_key():
    for k in DEFAULT_KEYS:
        if Path(k).expanduser().exists():
            return str(Path(k).expanduser())
    return None

def ssh_base(key):
    o = ["ssh"]
    if key:
        o += ["-i", key, "-o", "IdentitiesOnly=yes"]
    o += ["-o", "StrictHostKeyChecking=accept-new", "-o", "BatchMode=yes",
          "-o", "ConnectTimeout=6", "-c", "aes128-gcm@openssh.com", "-o", "Compression=no"]
    return o

# ----------------------------------------------------------------------------- TB IP discovery
def neighbor_table():
    """[(iface, ip, mac)] of v4 neighbors on TB ifaces."""
    tb = set(tb_ifaces().keys())
    # prime ND so the kernel learns the point-to-point peers
    for ifc in tb:
        run(["ping6", "-c", "1", "-i", "0.2", f"ff02::1%{ifc}"], timeout=2)
    rc, out, _ = run(["arp", "-an"])
    res = []
    for line in out.splitlines():
        m = re.search(r"\((169\.254\.\d+\.\d+)\) at ([0-9a-f:]+) on (\w+)", line)
        if m and m.group(3) in tb and "incomplete" not in line:
            res.append((m.group(3), m.group(1), m.group(2)))
    return res

def tb_ip_for(mac_prefix):
    for ifc, ip, mac in neighbor_table():
        if mac_matches(mac_prefix, mac):
            return ip, ifc
    return None, None

def reachable_peers(self_node):
    out = {}
    for node in NODES:
        if node["name"] == self_node["name"]:
            continue
        ip, ifc = tb_ip_for(node["mac"])
        if ip:
            out[node["name"]] = {"node": node, "ip": ip, "iface": ifc}
    return out

# ----------------------------------------------------------------------------- completeness
def dir_size(path, _seen=None):
    total = 0
    try:
        for root, _dirs, files in os.walk(path, followlinks=True):
            for f in files:
                fp = os.path.join(root, f)
                try:
                    total += os.stat(fp).st_size  # stat follows symlinks
                except OSError:
                    pass
    except OSError:
        pass
    return total

def _has_partial(path):
    for root, _d, files in os.walk(path, followlinks=False):
        for f in files:
            if PARTIAL_RE.search(f):
                return True
    return False

def is_complete_weight_dir(path):
    """A directory holding a model: complete if its weight set is fully present."""
    p = Path(path)
    if not p.is_dir():
        return False
    try:
        entries = list(os.scandir(p))
    except OSError:
        return False
    names = [e.name for e in entries]
    if _has_partial(p):
        return False
    # safetensors index = authoritative shard manifest
    idx = p / "model.safetensors.index.json"
    if idx.exists():
        try:
            wm = json.loads(idx.read_text()).get("weight_map", {})
            shards = set(wm.values())
            return bool(shards) and all((p / s).exists() and (p / s).stat().st_size > 0 for s in shards)
        except (OSError, ValueError):
            return False
    sts = [n for n in names if n.endswith(".safetensors")]
    if sts:
        # sharded by name: model-00001-of-00006.safetensors -> need all N
        m = re.search(r"-of-(\d+)\.safetensors$", sts[0])
        if m:
            return len([s for s in sts if "-of-" in s]) >= int(m.group(1))
        return any((p / s).stat().st_size > 0 for s in sts)
    ggufs = [n for n in names if n.endswith(".gguf")]
    if ggufs:
        m = re.search(r"-(\d+)-of-(\d+)\.gguf$", ggufs[0])
        if m:
            return len(ggufs) >= int(m.group(2))
        return True
    # mlx .npz / pytorch .bin fallbacks
    if any(n.endswith((".npz", ".bin")) for n in names) and (p / "config.json").exists():
        return True
    return False

def hf_snapshot(repo_path):
    """Resolve a models--* repo to its current snapshot dir via refs/main."""
    p = Path(repo_path)
    ref = p / "refs" / "main"
    snaps = p / "snapshots"
    if ref.exists():
        h = ref.read_text().strip()
        sd = snaps / h
        if sd.is_dir():
            return sd
    if snaps.is_dir():  # fall back to the single newest snapshot
        ds = [d for d in snaps.iterdir() if d.is_dir()]
        if len(ds) == 1:
            return ds[0]
    return None

def hf_has_incomplete(repo_path):
    blobs = Path(repo_path) / "blobs"
    if blobs.is_dir():
        for b in blobs.iterdir():
            if b.name.endswith(".incomplete"):
                return True
    return False

def split_owner(flat):
    """owner--model -> (owner, model). Split on the first DOUBLE hyphen."""
    parts = flat.split("--", 1)
    return (parts[0], parts[1]) if len(parts) == 2 else ("", flat)

def mk_model(store, owner, name, path, complete=None, size=None):
    flat = f"{owner}--{name}" if owner else name
    model_id = f"{owner}/{name}" if owner else name
    if complete is None:
        complete = is_complete_weight_dir(path)
    return {
        "store": store, "owner": owner, "name": name, "flat": flat,
        "model_id": model_id, "path": str(path),
        "size": size if size is not None else dir_size(path),
        "complete": complete,
    }

def scan_lmstudio():
    root = STORES["lmstudio"]; out = []
    if not root.is_dir(): return out
    for owner_dir in sorted(root.iterdir()):
        if not owner_dir.is_dir() or owner_dir.name in SKIP_NAMES: continue
        for repo in sorted(owner_dir.iterdir()):
            if not repo.is_dir() or repo.name in SKIP_NAMES: continue
            out.append(mk_model("lmstudio", owner_dir.name, repo.name, repo))
    return out

def scan_exo():
    root = STORES["exo"]; out = []
    if not root.is_dir(): return out
    for e in sorted(root.iterdir()):
        if e.name in SKIP_NAMES or e.name.startswith("."): continue
        if e.is_symlink() and not e.exists():  # broken symlink = incomplete
            continue
        if not e.is_dir(): continue
        owner, name = split_owner(e.name)
        out.append(mk_model("exo", owner, name, e.resolve()))
    return out

def scan_hf():
    root = STORES["hf"]; out = []
    if not root.is_dir(): return out
    for repo in sorted(root.iterdir()):
        if not repo.name.startswith("models--"): continue
        snap = hf_snapshot(repo)
        if snap is None or hf_has_incomplete(repo):
            continue
        flat = repo.name[len("models--"):]
        owner, name = split_owner(flat)
        complete = is_complete_weight_dir(snap)
        out.append(mk_model("hf", owner, name, snap, complete=complete))
    return out

def scan_mtplx():
    root = STORES["mtplx"]; out = []
    if not root.is_dir(): return out
    for e in sorted(root.iterdir()):
        if e.name in SKIP_NAMES or e.name.startswith(".") or not e.is_dir(): continue
        owner, name = split_owner(e.name)
        out.append(mk_model("mtplx", owner, name, e))
    return out

def scan_all(complete_only=True):
    models = scan_lmstudio() + scan_exo() + scan_hf() + scan_mtplx()
    if complete_only:
        models = [m for m in models if m["complete"]]
    models.sort(key=lambda m: (m["store"], m["model_id"].lower()))
    return models

# ----------------------------------------------------------------------------- remote scan
def remote_scan(ip, user, key):
    """Run THIS script on a remote node over TB to list its completed models."""
    base = ssh_base(key) + [f"{user}@{ip}", "python3", "-", "--scan-json"]
    rc, out, err = run(base, timeout=60, inp=Path(__file__).read_text())
    if rc != 0:
        raise RuntimeError(f"remote scan failed ({rc}): {err.strip()[:200]}")
    return json.loads(out)

# ----------------------------------------------------------------------------- EXO card
def build_exo_card(model, size_bytes):
    """Minimal EXO card per the exo-add-local-model recipe (no reasoning_dialect)."""
    cfg = {}
    cfgp = Path(model["path"]) / "config.json"
    if cfgp.exists():
        try: cfg = json.loads(cfgp.read_text())
        except ValueError: cfg = {}
    tc = cfg.get("text_config", cfg)
    def g(k, default=0): return tc.get(k, cfg.get(k, default))
    lines = [
        f'model_id = "{model["model_id"]}"',
        f'n_layers = {g("num_hidden_layers", 0)}',
        f'hidden_size = {g("hidden_size", 0)}',
        "supports_tensor = true",
        f'num_key_value_heads = {g("num_key_value_heads", 0)}',
        'tasks = ["TextGeneration"]',
        'family = ""', 'quantization = ""', 'base_model = ""', "capabilities = []",
        f'context_length = {g("max_position_embeddings", 0)}',
        "uses_cfg = false", "trust_remote_code = false",
        "", "[storage_size]", f"in_bytes = {size_bytes}",
    ]
    if "vision_config" in cfg or "image_token_id" in cfg:
        lines += ["", "[vision]",
                  f'image_token_id = {cfg.get("image_token_id", 0)}',
                  f'model_type = "{cfg.get("model_type", "")}"',
                  f'weights_repo = "{model["model_id"]}"']
    lines += ["", "[sampling_defaults]", ""]
    return "\n".join(lines)

def build_skulk_card(model, size_bytes):
    # Skulk card = exo base fields + [runtime]/[reasoning] + capability detection (Skulk is an exo fork).
    cfg = {}
    cfgp = Path(model["path"]) / "config.json"
    if cfgp.exists():
        try: cfg = json.loads(cfgp.read_text())
        except ValueError: cfg = {}
    tc = cfg.get("text_config", cfg)
    def g(k, default=0): return tc.get(k, cfg.get(k, default))
    qc = cfg.get("quantization") or cfg.get("quantization_config") or {}
    q = ""
    if isinstance(qc, dict) and qc.get("bits"):
        q = f"{qc['bits']}bit"
    else:
        ml = model["flat"].lower()
        for tag in ("mxfp8", "mxfp4", "8bit", "6bit", "4bit", "3bit", "2bit", "bf16", "fp16"):
            if tag in ml:
                q = tag; break
    mt = (cfg.get("model_type") or "").lower()
    blob = (mt + " " + model["flat"]).lower()
    family = "qwen" if "qwen" in blob else ("llama" if "llama" in blob else (mt.split("_")[0] if mt else ""))
    is_vision = ("vision_config" in cfg) or ("image_token_id" in cfg)
    is_thinking = ("thinking" in model["flat"].lower()) or ("reasoning" in model["flat"].lower())
    caps = ["text"]
    if is_vision:
        caps.append("vision")
    if is_thinking:
        caps += ["thinking", "thinking_toggle"]
    caps_str = ", ".join('"' + c + '"' for c in caps)
    lines = [
        f'model_id = "{model["model_id"]}"',
        f'n_layers = {g("num_hidden_layers", 0)}',
        f'hidden_size = {g("hidden_size", 0)}',
        f'num_key_value_heads = {g("num_key_value_heads", 0)}',
        "supports_tensor = true",
        'tasks = ["TextGeneration"]',
        f'family = "{family}"',
        f'quantization = "{q}"',
        'base_model = ""',
        f"capabilities = [{caps_str}]",
    ]
    if is_thinking:
        lines += ["", "[reasoning]", "supports_toggle = true",
                  'format = "token_delimited"', 'default_effort = "medium"', 'disabled_effort = "none"']
    lines += ["", "[runtime]", "mtp_heads = false"]
    if is_vision:
        lines += ["", "[vision]",
                  f'image_token_id = {cfg.get("image_token_id", 0)}',
                  f'model_type = "{cfg.get("model_type", "")}"']
    lines += ["", "[storage_size]", f"in_bytes = {size_bytes}"]
    return "\n".join(lines)


# ----------------------------------------------------------------------------- transfer
def start_daemon(ip, user, key, port):
    conf = (
        "use chroot = no\nread only = no\nhosts allow = 169.254.0.0/16\n"
        "hosts deny = *\nmax connections = 32\n"
        "lock file = /tmp/tbcluster-rsyncd.lock\nlog file = /tmp/tbcluster-rsyncd.log\n"
        "pid file = /tmp/tbcluster-rsyncd.pid\n"
        "[home]\n    path = HOMEPLACEHOLDER\n    read only = no\n    list = no\n"
    )
    script = f"""set -e
RS=$(for p in /opt/homebrew/bin/rsync /usr/local/bin/rsync /opt/local/bin/rsync; do [ -x "$p" ] && {{ echo "$p"; break; }}; done)
[ -z "$RS" ] && {{ echo "no gnu rsync" >&2; exit 3; }}
CONF=$(mktemp /tmp/tbcluster-rsyncd.XXXXXX.conf)
cat > "$CONF" <<'CONF_EOF'
{conf}CONF_EOF
sed -i.bak "s|HOMEPLACEHOLDER|$HOME|" "$CONF" && rm -f "$CONF.bak"
[ -f /tmp/tbcluster-rsyncd.pid ] && kill "$(cat /tmp/tbcluster-rsyncd.pid)" 2>/dev/null || true
exec "$RS" --daemon --no-detach --port {port} --config "$CONF" --address {ip}
"""
    cmd = ssh_base(key) + [f"{user}@{ip}", "bash -s"]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                         stderr=subprocess.PIPE, text=True)
    p.stdin.write(script); p.stdin.close()
    for _ in range(40):
        try:
            with socket.create_connection((ip, port), timeout=0.5):
                return p
        except OSError:
            time.sleep(0.2)
    p.terminate()
    raise RuntimeError(f"rsync daemon never bound :{port} on {ip}")

def stop_daemon(p, ip, user, key):
    try: p.terminate()
    except Exception: pass
    run(ssh_base(key) + [f"{user}@{ip}", "pkill -f 'rsync --daemon.*tbcluster' ; rm -f /tmp/tbcluster-rsyncd.*"], timeout=10)

def ssh_run(ip, user, key, remote_cmd, timeout=30, inp=None):
    return run(ssh_base(key) + [f"{user}@{ip}", remote_cmd], timeout=timeout, inp=inp)

def dest_free_bytes(peer, key):
    """Available bytes in the dest user's home volume (None if unknown)."""
    rc, out, _ = ssh_run(peer["ip"], peer["node"]["user"], key, "df -k ~ | tail -1")
    if rc != 0:
        return None
    parts = out.split()
    try:
        return int(parts[3]) * 1024          # macOS df -k: Avail is field 3
    except (IndexError, ValueError):
        return None

def push_dir_cmd(src, ip, port, dest_rel):
    """The exact 16-stream daemon pipeline TBTransfer uses for directories."""
    rurl = f"rsync://{ip}:{port}/home/{dest_rel}/"
    flags = " ".join(RSYNC_FLAGS)
    return (f"ls -1A {shlex.quote(src)} | xargs -P {PARALLEL} -I{{}} "
            f"{shlex.quote(RSYNC)} {flags} {shlex.quote(src)}/\"{{}}\" {shlex.quote(rurl)}")

def transfer_model(model, peer, key, home, dry=False):
    ip, user = peer["ip"], peer["node"]["user"]
    home_rel = HOME_DIRS[home]
    if home in ("exo", "skulk"):
        dest_rel = f"{home_rel}/{model['flat']}"
    else:  # lmstudio keeps owner/name layout
        dest_rel = f"{home_rel}/{model['owner']}/{model['name']}" if model["owner"] else f"{home_rel}/{model['name']}"
    src = model["path"]
    pipeline = push_dir_cmd(src, ip, port=DAEMON_PORT, dest_rel=dest_rel)
    mkdir_cmd = f"mkdir -p ~/{shlex.quote(dest_rel)}"
    if dry:
        print(dim(f"    mkdir : ssh {user}@{ip} {mkdir_cmd}"))
        print(dim(f"    daemon: rsync --daemon :{DAEMON_PORT} --address {ip} (module home -> $HOME)"))
        print(dim(f"    push  : {pipeline}"))
        return True, 0.0
    ssh_run(ip, user, key, mkdir_cmd)
    daemon = start_daemon(ip, user, key, DAEMON_PORT)
    try:
        t0 = time.time()
        rc, out, err = run(["bash", "-c", pipeline], timeout=3600)
        dt = time.time() - t0
    finally:
        stop_daemon(daemon, ip, user, key)
    if rc != 0:
        print(red(f"    transfer FAILED rc={rc}: {err.strip()[:300]}"))
        return False, dt
    return True, dt

def register_exo(model, peer, key, all_peers, build_fn=build_exo_card):
    """Create the card (on all reachable nodes) for a model placed in .exo (exo or skulk format)."""
    card = build_fn(model, model["size"])
    targets = {peer["node"]["name"]: peer}
    for n, p in all_peers.items():
        targets.setdefault(n, p)
    wrote = []
    for name, p in targets.items():
        ip, user = p["ip"], p["node"]["user"]
        ssh_run(ip, user, key, "mkdir -p ~/.exo/custom_model_cards ~/.exo/models")
        rc, _, err = ssh_run(ip, user, key,
                             f"cat > ~/.exo/custom_model_cards/{shlex.quote(model['flat'] + '.toml')}",
                             inp=card)
        if rc == 0:
            wrote.append(name)
    return wrote, card

# ----------------------------------------------------------------------------- UI
def parse_selection(s, n):
    """Index/range selection (1-based) -> sorted 0-based indices. For short
    menus shown right before selection (nodes)."""
    s = s.strip().lower()
    if s in ("all", "*", "a"):
        return list(range(n))
    idx = set()
    for tok in re.split(r"[,\s]+", s):
        if not tok: continue
        if "-" in tok:
            a, b = tok.split("-", 1)
            try: idx.update(range(int(a) - 1, int(b)))
            except ValueError: pass
        else:
            try: idx.add(int(tok) - 1)
            except ValueError: pass
    return sorted(i for i in idx if 0 <= i < n)

def resolve_models(spec, models):
    """Resolve a selection spec to model dicts. Accepts 1-based indices,
    ranges (5-8), 'all', AND name substrings (case-insensitive match against
    model_id / flat / name). Name matching makes non-interactive use safe even
    if the scan order shifts between a `--list` and a `--to` invocation.
    Order-preserving and de-duplicated."""
    if spec.strip().lower() in ("all", "*", "a"):
        return list(models)
    chosen, seen = [], set()
    def take(i):
        if 0 <= i < len(models) and i not in seen:
            seen.add(i); chosen.append(models[i])
    for tok in re.split(r"[,\n]+", spec):
        tok = tok.strip()
        if not tok:
            continue
        if re.fullmatch(r"\d+(-\d+)?", tok):              # index or range
            if "-" in tok:
                a, b = tok.split("-", 1)
                for i in range(int(a) - 1, int(b)): take(i)
            else:
                take(int(tok) - 1)
        else:                                              # name substring
            t = tok.lower()
            for i, m in enumerate(models):
                if t in m["model_id"].lower() or t in m["flat"].lower() or t in m["name"].lower():
                    take(i)
    return chosen

def print_table(models):
    if not models:
        print(yel("  (no completed models found)")); return
    w_store = max(len(m["store"]) for m in models)
    w_id = min(60, max(len(m["model_id"]) for m in models))
    header = f"  {'#':>3}  {'store':<{w_store}}  {'model':<{w_id}}  {'size':>9}"
    print(bold(header))
    for i, m in enumerate(models, 1):
        mid = m["model_id"] if len(m["model_id"]) <= w_id else m["model_id"][:w_id-1] + "…"
        sz = human(m["size"])
        print(f"  {cyn(f'{i:>3}')}  {m['store']:<{w_store}}  {mid:<{w_id}}  {dim(f'{sz:>9}')}")

def ask(prompt, default=None):
    try:
        r = input(prompt).strip()
    except EOFError:
        return default
    return r or default

def interactive(self_node, key):
    print(bold(cyn(f"\n  TB5 cluster  ·  this node: {self_node['name']} ({self_node['user']})\n")))
    peers = reachable_peers(self_node)
    if not peers:
        print(red("  No TB5 peers reachable. Is a Thunderbolt cable connected?")); sys.exit(1)
    print("  reachable over TB5:")
    for nm, p in peers.items():
        print(f"    {grn('●')} {nm:<12} {dim(p['ip'] + ' via ' + p['iface'])}")
    print(bold("\n  Scanning local model stores…"))
    models = scan_all()
    print()
    print_table(models)
    if not models: sys.exit(0)

    chosen = resolve_models(ask(bold("\n  Select models (e.g. 1,3,5-8 / all / a name): "), ""), models)
    if not chosen:
        print(yel("  nothing selected.")); sys.exit(0)

    pnames = list(peers.keys())
    print(bold("\n  Destination node(s):"))
    for i, nm in enumerate(pnames, 1):
        print(f"    {cyn(i)}) {nm}  {dim(peers[nm]['ip'])}")
    dsel = parse_selection(ask(bold("  choose (e.g. 1 / 1,2 / all): "), ""), len(pnames))
    dests = [peers[pnames[i]] for i in dsel]
    if not dests:
        print(yel("  no destination.")); sys.exit(0)

    print(bold("\n  Destination home:"))
    print(f"    {cyn(1)}) .lmstudio/models")
    print(f"    {cyn(2)}) .exo/models   {dim('(auto-creates EXO card)')}")
    home = {"1": "lmstudio", "2": "exo"}.get(ask(bold("  choose [1]: "), "1"), "lmstudio")

    total = sum(m["size"] for m in chosen)
    print(bold("\n  ── Plan ──"))
    for m in chosen:
        print(f"    {m['store']:<8} {m['model_id']}  {dim(human(m['size']))}")
    print(f"    → {bold(', '.join(d['node']['name'] for d in dests))}  home={bold('.'+home)}  total={bold(human(total))}")
    if home == "exo":
        print(dim("    + EXO card written to all reachable nodes; weights to the chosen node(s)."))
    if ask(bold("\n  Proceed? [y/N]: "), "n").lower() not in ("y", "yes"):
        print(yel("  aborted.")); sys.exit(0)

    do_transfer(chosen, dests, home, key, peers)

def do_transfer(chosen, dests, home, key, all_peers, dry=False):
    need = sum(m["size"] for m in chosen)
    for dest in dests:
        dn = dest["node"]["name"]
        print(bold(cyn(f"\n  ▸ {dn} ({dest['ip']})")))
        if not dry:
            free = dest_free_bytes(dest, key)
            if free is not None:
                tag = red(f"  ⚠ need {human(need)} > free {human(free)}") if need > free * 0.97 else dim(f"  free {human(free)}")
                print(f"    {dim(human(need)+' to send')}{tag}")
        for m in chosen:
            print(f"    {m['model_id']} {dim('('+human(m['size'])+')')} …")
            ok, dt = transfer_model(m, dest, key, home, dry=dry)
            if ok and not dry:
                rate = m["size"] / dt / 1e9 if dt > 0 else 0
                print(grn(f"      ✓ done in {dt:.1f}s  ({rate:.2f} GB/s)"))
            if ok and home in ("exo", "skulk") and not dry:
                wrote, _ = register_exo(m, dest, key, all_peers, build_skulk_card if home == "skulk" else build_exo_card)
                print(grn(f"      ✓ {home} card → {', '.join(wrote)}"))
            elif home in ("exo", "skulk") and dry:
                print(dim(f"      card: ~/.exo/custom_model_cards/{m['flat']}.toml (all nodes, {home})"))
    if home == "exo" and not dry:
        print(yel("\n  Note: restart EXO on the affected node(s) to load new cards (cards load at startup)."))

# ----------------------------------------------------------------------------- main
def main(argv=None):
    ap = argparse.ArgumentParser(description="TB5 cluster model dashboard + transfer")
    ap.add_argument("--list", action="store_true", help="list completed local models and exit")
    ap.add_argument("--self-info", action="store_true", help="show detected node + TB peers")
    ap.add_argument("--scan-json", action="store_true", help="emit completed local models as JSON")
    ap.add_argument("--all", action="store_true", help="with --list: include incomplete too")
    ap.add_argument("--to", help="destination node(s), comma-separated (non-interactive)")
    ap.add_argument("--models", help="selection (indices/ranges/'all') against --list order")
    ap.add_argument("--home", choices=["lmstudio", "exo", "skulk"], help="destination home")
    ap.add_argument("--key", help="ssh identity (default: auto-detect)")
    ap.add_argument("--yes", action="store_true", help="skip confirmation")
    ap.add_argument("--dry-run", action="store_true", help="show plan + commands, do nothing")
    args = ap.parse_args(argv)

    key = str(Path(args.key).expanduser()) if args.key else ssh_key()

    if args.scan_json:
        print(json.dumps(scan_all(complete_only=not args.all))); return
    self_node = detect_self()
    if args.self_info:
        print(bold(f"node: {self_node['name']} (user {self_node['user']})"))
        print(f"ssh key: {key or '(none — using agent/ssh_config)'}")
        print("TB ifaces:")
        for ifc, v in tb_ifaces().items():
            print(f"  {ifc}: ip={v['ip']} mac={v['mac']}")
        print("reachable TB5 peers:")
        for nm, p in reachable_peers(self_node).items():
            print(f"  {grn('●')} {nm}: {p['ip']} via {p['iface']}")
        return
    if args.list:
        models = scan_all(complete_only=not args.all)
        print(bold(f"\n  completed models on {self_node['name']}:\n"))
        print_table(models)
        print(dim(f"\n  {len(models)} models, {human(sum(m['size'] for m in models))} total\n"))
        return

    # non-interactive transfer
    if args.to and args.models and args.home:
        peers = reachable_peers(self_node)
        models = scan_all()
        chosen = resolve_models(args.models, models)
        want = [x.strip() for x in args.to.split(",")]
        dests = [peers[n] for n in want if n in peers]
        if not chosen or not dests:
            print(red("nothing to do (check --models / --to against --list).")); sys.exit(1)
        if not args.yes and not args.dry_run:
            print(f"about to send {len(chosen)} model(s) to {', '.join(d['node']['name'] for d in dests)} "
                  f"home=.{args.home}")
            if ask("proceed? [y/N]: ", "n").lower() not in ("y", "yes"): sys.exit(0)
        do_transfer(chosen, dests, args.home, key, peers, dry=args.dry_run)
        return

    if not sys.stdin.isatty():
        ap.print_help()
        print(dim("\n(no TTY — run --list / --self-info, or use --to/--models/--home)"))
        return
    interactive(self_node, key)

if __name__ == "__main__":
    main()
