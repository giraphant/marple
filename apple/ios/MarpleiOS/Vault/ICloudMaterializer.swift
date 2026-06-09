import Foundation

/// Ensures an iCloud-Drive file is materialized (downloaded) before we read it.
/// iCloud evicts unused files to 0-byte placeholders; reading one needs an
/// explicit download. Only used for `.md` (and, in v2, media).
enum ICloudMaterializer {
    enum MaterializeError: Error { case timedOut(URL) }

    /// Download `url` if it is an evicted placeholder, polling until current.
    /// No-op if already downloaded or not an iCloud item. Throws on timeout.
    static func ensureDownloaded(_ url: URL, timeout: TimeInterval = 20) async throws {
        let keys: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey]
        func status() -> URLUbiquitousItemDownloadingStatus? {
            (try? url.resourceValues(forKeys: keys))?.ubiquitousItemDownloadingStatus
        }
        // Not an iCloud item, or already current → nothing to do.
        if status() == .current || status() == nil { return }

        try FileManager.default.startDownloadingUbiquitousItem(at: url)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if status() == .current { return }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw MaterializeError.timedOut(url)
    }
}
