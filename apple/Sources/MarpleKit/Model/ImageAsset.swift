import Foundation

public enum ImageAsset {
    public static let originalStem = "original"
    public static let supportedExtensions = ["png", "jpg", "jpeg", "webp", "gif", "heic", "tiff"]

    public static func slug(forImageEntryPath path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        return parts[parts.count - 2]
    }

    public static func isSupportedImageURL(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    public static func slug(fromTitle title: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in title.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash, !out.isEmpty { out.append("-") }
                out.unicodeScalars.append(scalar)
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? "image" : out
    }

    public static func originalPath(forImageEntryPath path: String,
                                    existingFilenames: [String]) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.last == "image.md", parts.count >= 2 else { return nil }
        let match = supportedExtensions
            .map { "\(originalStem).\($0)" }
            .first { candidate in existingFilenames.contains(candidate) }
        guard let match else { return nil }
        return (parts.dropLast() + [match]).joined(separator: "/")
    }
}
