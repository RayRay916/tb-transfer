import Foundation

/// Path-expansion helpers. macOS Foundation does NOT expand `~` automatically
/// in path APIs (FileManager, URL(fileURLWithPath:), FSEventStreamCreate, etc.)
/// — only the shell does. So we expand here at the boundary where the user-
/// supplied string crosses into Foundation APIs that operate on absolute paths.
///
/// For commands that go through `bash -c "..."` (e.g., rsync pipelines), DO
/// NOT pre-expand — the shell handles it correctly. Pre-expanding would still
/// work, but breaks the principle that what the user typed is what runs.
enum PathExpander {
    /// Returns an absolute filesystem path. If `path` begins with `~/`, it is
    /// expanded against `NSHomeDirectory()`. If `path` is just `~`, returns
    /// the home directory. Otherwise the input is returned unchanged.
    static func absolute(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        let home = NSHomeDirectory()
        if path == "~" { return home }
        if path.hasPrefix("~/") {
            return home + String(path.dropFirst(1))
        }
        // `~user/...` form — fall back to NSString's resolver which knows the
        // user database. If lookup fails, return input unchanged.
        return (path as NSString).expandingTildeInPath
    }
}
