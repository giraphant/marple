import Foundation

/// Shared, cached `DateFormatter`s for app chrome. `DateFormatter` is expensive
/// to allocate, so these are created once. Reads are thread-safe.
enum AppDateFormatters {
    /// "yyyy-MM-dd HH:mm" in zh_CN — used by Settings and the backup browser to
    /// show a minute-resolution timestamp. Read-only (string(from:)) → thread-safe.
    static let friendlyMinute: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
