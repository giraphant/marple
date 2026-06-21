import Testing
import Foundation
@testable import MarpleKit

@Suite struct RetentionPolicyTests {
    /// Fixed UTC calendar + anchor so bucket math is deterministic (no DST/locale).
    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let policy = RetentionPolicy(calendar: cal)
    /// 2026-05-29 12:00:00 UTC
    private let now = Date(timeIntervalSince1970: 1_780_056_000)

    private func ago(hours: Double = 0, days: Double = 0) -> Date {
        now.addingTimeInterval(-(hours * 3600 + days * 86400))
    }

    @Test func emptyInEmptyOut() {
        let d = policy.evaluate(snapshots: [], now: now)
        #expect(d.keep.isEmpty && d.delete.isEmpty)
    }

    @Test func dailyTierKeepsDistinctDays() {
        // Two snapshots on different days, both within 7d → both kept.
        let yesterday = ago(days: 1)
        let threeDaysAgo = ago(days: 3)
        let d = policy.evaluate(snapshots: [threeDaysAgo, yesterday], now: now)
        #expect(Set(d.keep) == Set([threeDaysAgo, yesterday]))
        #expect(d.delete.isEmpty)
    }

    @Test func dailyTierCollapsesSameDay() {
        // Age between 12h and 7d → daily bucket. Same day, two times → newest.
        let morning = ago(hours: 3, days: 2)   // 2 days ago 09:00
        let evening = ago(days: 2).addingTimeInterval(-3 * 3600 + 6 * 3600) // 2 days ago 15:00
        let d = policy.evaluate(snapshots: [morning, evening], now: now)
        #expect(d.keep.count == 1)
        #expect(d.keep.first == max(morning, evening))
    }

    @Test func weeklyTierCollapsesSameWeekKeepsDifferentWeeks() {
        let eightDays = ago(days: 8)
        let eightDaysLater = ago(days: 8).addingTimeInterval(2 * 3600) // same day/week
        let fortyDays = ago(days: 40)                                  // different week
        let d = policy.evaluate(snapshots: [eightDays, eightDaysLater, fortyDays], now: now)
        // 8d pair collapses to one; 40d stands alone → 2 kept total.
        #expect(d.keep.count == 2)
        #expect(d.keep.contains(eightDaysLater))
        #expect(d.keep.contains(fortyDays))
        #expect(d.delete == [eightDays])
    }

    @Test func dropsOlderThanSixMonths() {
        let old = ago(days: 200)
        let recent = ago(hours: 1)
        let d = policy.evaluate(snapshots: [old, recent], now: now)
        #expect(d.keep == [recent])
        #expect(d.delete == [old])
    }

    @Test func futureDatedSnapshotsAreKept() {
        let future = now.addingTimeInterval(3600)
        let d = policy.evaluate(snapshots: [future], now: now)
        #expect(d.keep == [future])
        #expect(d.delete.isEmpty)
    }
}
