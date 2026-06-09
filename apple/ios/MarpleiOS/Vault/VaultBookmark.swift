import Foundation

/// Persists the user's pick of the iCloud-Drive-synced vault folder as a
/// security-scoped bookmark, and resolves it on launch. iOS analogue of the Mac
/// workspace picker. The caller owns balancing start/stop access.
enum VaultBookmark {
    private static let key = "marple.ios.vaultBookmark"

    /// Save a freshly picked folder URL as a security-scoped bookmark.
    static func save(_ url: URL) throws {
        let data = try url.bookmarkData(options: [],
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Resolve the persisted bookmark to a URL. Returns nil if none saved.
    /// `isStale` true means re-save (caller should re-pick if resolution fails).
    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return url
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
