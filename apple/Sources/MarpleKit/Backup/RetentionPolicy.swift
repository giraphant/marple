import Foundation

/// Decides which vault snapshots to keep vs delete, mirroring Ulysses' tiered
/// density. Pure over `(snapshots, now)` so creation cadence can be finer than
/// the visible density without changing this logic — pruning normalizes it.
///
/// Tiers (by age = now − snapshot):
///   · < 7d          keep the newest snapshot per calendar day
///   · 7d … 6 months keep the newest per calendar week
///   · > 6 months    delete
public struct RetentionPolicy: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public struct Decision: Equatable, Sendable {
        public var keep: [Date]
        public var delete: [Date]
    }

    /// One bucket key per tier resolution. Snapshots sharing a key collapse to
    /// the newest one.
    private enum Granularity {
        case day, week
    }

    public func evaluate(snapshots: [Date], now: Date) -> Decision {
        guard !snapshots.isEmpty else { return Decision(keep: [], delete: []) }

        let cutoff7d = calendar.date(byAdding: .day, value: -7, to: now) ?? now.addingTimeInterval(-7 * 86400)
        let cutoff6mo = calendar.date(byAdding: .month, value: -6, to: now) ?? now.addingTimeInterval(-182 * 86400)

        // Future-dated snapshots (clock skew) are always kept — never delete
        // something newer than "now".
        var keep: Set<Date> = []
        var perTier: [Granularity: [String: Date]] = [.day: [:], .week: [:]]

        for date in snapshots {
            if date >= now {
                keep.insert(date)
                continue
            }
            if date < cutoff6mo {
                continue  // dropped
            }
            let gran: Granularity
            if date > cutoff7d { gran = .day }
            else { gran = .week }

            let key = bucketKey(for: date, gran: gran)
            if let existing = perTier[gran]?[key] {
                if date > existing { perTier[gran]?[key] = date }
            } else {
                perTier[gran]?[key] = date
            }
        }

        for (_, buckets) in perTier {
            for (_, winner) in buckets { keep.insert(winner) }
        }

        let delete = snapshots.filter { !keep.contains($0) }
        let keepList = snapshots.filter { keep.contains($0) }
        return Decision(keep: keepList, delete: delete)
    }

    private func bucketKey(for date: Date, gran: Granularity) -> String {
        switch gran {
        case .day:
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
        case .week:
            let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return "\(c.yearForWeekOfYear ?? 0)-w\(c.weekOfYear ?? 0)"
        }
    }
}
