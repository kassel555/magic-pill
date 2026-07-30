import Foundation
import SwiftData

/// How one day went for one item.
public struct DayAdherence: Sendable, Equatable, Identifiable {
    public let date: Date
    public let taken: Int
    public let skipped: Int
    public let missed: Int
    public let pending: Int

    public var id: Date { date }

    public init(date: Date, taken: Int, skipped: Int, missed: Int, pending: Int) {
        self.date = date
        self.taken = taken
        self.skipped = skipped
        self.missed = missed
        self.pending = pending
    }

    public var scheduled: Int { taken + skipped + missed + pending }

    /// Doses whose outcome is settled. Pending ones are not judged.
    public var resolved: Int { taken + skipped + missed }

    public enum State: Sendable, Equatable {
        /// Nothing was scheduled. Not a failure, and must not look like one.
        case unscheduled
        /// Everything scheduled was taken.
        case complete
        /// Some taken, some not.
        case partial
        /// Nothing was taken, and the day is settled.
        case missed
        /// Deliberately skipped, nothing missed. A choice, not a lapse.
        case skipped
        /// Still to come, or still open.
        case upcoming
    }

    public var state: State {
        if scheduled == 0 { return .unscheduled }
        if pending > 0 && resolved == 0 { return .upcoming }
        if taken == scheduled { return .complete }
        if taken > 0 { return .partial }
        if missed > 0 { return .missed }
        return .skipped
    }
}

/// Adherence for one item over a window of days.
public struct AdherenceSummary: Sendable, Equatable {
    /// Oldest first, one entry per day in the window, including empty days.
    public let days: [DayAdherence]

    public init(days: [DayAdherence]) {
        self.days = days
    }

    public var totalTaken: Int { days.reduce(0) { $0 + $1.taken } }
    public var totalSkipped: Int { days.reduce(0) { $0 + $1.skipped } }
    public var totalMissed: Int { days.reduce(0) { $0 + $1.missed } }
    public var totalResolved: Int { days.reduce(0) { $0 + $1.resolved } }

    /// Taken as a fraction of settled doses, or **nil** when nothing has
    /// settled yet.
    ///
    /// Nil rather than zero on purpose. A brand-new item has taken nothing, and
    /// showing "0%" to someone who has done nothing wrong is both inaccurate
    /// and discouraging — this app's job is not to score people.
    ///
    /// Pending doses are excluded entirely, so the figure doesn't sag through
    /// the day and recover each evening.
    public var rate: Double? {
        guard totalResolved > 0 else { return nil }
        return Double(totalTaken) / Double(totalResolved)
    }

    /// Consecutive days ending today (or yesterday) with everything taken.
    ///
    /// Days with nothing scheduled don't break a streak — they aren't part of
    /// it. Today counts only once it's complete, so an unfinished day never
    /// reads as a broken streak.
    public var currentStreak: Int {
        var streak = 0
        for day in days.reversed() {
            switch day.state {
            case .complete:
                streak += 1
            case .unscheduled, .upcoming:
                continue
            case .partial, .missed, .skipped:
                return streak
            }
        }
        return streak
    }

    public var hasHistory: Bool { totalResolved > 0 }
}

/// Builds an `AdherenceSummary` from the store.
public enum AdherenceCalculator {

    /// Days shown in the detail view's grid.
    public static let windowDays = 30

    /// Summarises the last `windowDays` days up to and including `now`.
    public static func summary(
        for item: TrackedItem,
        now: Date = .now,
        windowDays: Int = windowDays,
        calendar: Calendar = .current
    ) -> AdherenceSummary {
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(
            byAdding: .day, value: -(windowDays - 1), to: today
        ), let windowEnd = calendar.date(byAdding: .day, value: 1, to: today) else {
            return AdherenceSummary(days: [])
        }

        // Bucket by day start. Reads the item's own occurrences rather than
        // issuing a fetch, so this works from any context that already loaded
        // the item.
        var buckets: [Date: (taken: Int, skipped: Int, missed: Int, pending: Int)] = [:]

        for occurrence in item.occurrences ?? [] {
            guard occurrence.scheduledAt >= windowStart,
                  occurrence.scheduledAt < windowEnd else { continue }

            let day = calendar.startOfDay(for: occurrence.scheduledAt)
            var bucket = buckets[day] ?? (0, 0, 0, 0)

            switch occurrence.state {
            case .taken:   bucket.taken += 1
            case .skipped: bucket.skipped += 1
            case .missed:  bucket.missed += 1
            case .pending: bucket.pending += 1
            }
            buckets[day] = bucket
        }

        // Every day in the window appears, including the empty ones — a grid
        // with gaps punched out of it would misrepresent a paused schedule as
        // missing data.
        var days: [DayAdherence] = []
        var cursor = windowStart
        while cursor < windowEnd {
            let bucket = buckets[cursor] ?? (0, 0, 0, 0)
            days.append(DayAdherence(
                date: cursor,
                taken: bucket.taken,
                skipped: bucket.skipped,
                missed: bucket.missed,
                pending: bucket.pending
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        return AdherenceSummary(days: days)
    }
}
