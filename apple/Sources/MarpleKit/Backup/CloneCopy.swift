import Foundation

/// Whole-tree snapshotting via APFS `clonefile(2)`: each non-excluded top-level
/// child of the vault is cloned into the snapshot directory. On the same APFS
/// volume this shares blocks (near-zero extra space); cross-volume / non-APFS
/// transparently falls back to a full recursive copy.
///
/// Excluded from snapshots: rebuildable caches (`.marple`, ~1GB), VCS internals
/// (`.git` — itself a history mechanism, and on a binary-heavy vault its history
/// is huge), Finder junk (`.DS_Store`), the file-sync journal (`.sync_*`), and
/// agent/CLI session-state dirs (`.claude`, `.codex`, … — not vault content, and
/// written constantly by background tools, which would otherwise mark the vault
/// dirty on every tick and flood the timeline with meaningless snapshots).
/// Everything else — including user-facing tool configs like `.obsidian` — is
/// cloned (free under COW).
public enum CloneCopy {
    public static let excludedNames: Set<String> = [
        ".marple", ".git", ".DS_Store",
        ".claude", ".codex", ".factory", ".antigravitycli", ".playwright-mcp", ".superset",
    ]

    public static func isExcluded(_ name: String) -> Bool {
        if excludedNames.contains(name) { return true }
        if name.hasPrefix(".sync_") { return true }  // Nextcloud/ownCloud sync journal
        return false
    }

    /// Clone each non-excluded immediate child of `root` into `dest`. `dest` is
    /// created fresh; callers should point it at a not-yet-published temp path
    /// and atomically rename afterwards.
    public static func snapshotTree(from root: URL, to dest: URL,
                                    isExcluded: (String) -> Bool = isExcluded) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let children = try fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [])
        for child in children {
            if isExcluded(child.lastPathComponent) { continue }
            try cloneItem(at: child, to: dest.appendingPathComponent(child.lastPathComponent))
        }
    }

    /// Clone a single file or directory (recursively). `dst` must not exist.
    /// Falls back to a recursive copy when `clonefile` is unavailable for the
    /// source/target pair (cross-volume, non-APFS).
    public static func cloneItem(at src: URL, to dst: URL) throws {
        let result = src.withUnsafeFileSystemRepresentation { s -> Int32 in
            dst.withUnsafeFileSystemRepresentation { d -> Int32 in
                guard let s, let d else { return -1 }
                return clonefile(s, d, 0)
            }
        }
        if result == 0 { return }
        try FileManager.default.copyItem(at: src, to: dst)
    }
}
