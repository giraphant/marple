import Foundation

/// Shared, cached `DateFormatter`s for app chrome. `DateFormatter` is expensive
/// to allocate, so these are created once. Reads are thread-safe.
enum AppDateFormatters {
    /// Minute-resolution timestamps for Settings and the backup browser. Read-only
    /// (string(from:)) → thread-safe.
    static let friendlyMinute: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
