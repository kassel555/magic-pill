import Foundation
import SwiftData

/// Turns schedules into the concrete `Occurrence` rows a timeline can show.
///
/// The correctness contract, in order of how much damage a violation does:
///
/// - **Idempotent.** The window overlaps itself on every run. If generation
///   weren't idempotent the user would see their morning dose two, three, four
///   times.
/// - **History is immutable.** Only inserts, never edits. Resolved occurrences
///   are the user's own record; nothing here may touch one.
/// - **Calendar arithmetic only.** Wall-clock times resolve through `Calendar`
///   so they survive DST and time-zone travel. Adding 86,400 seconds is not a
///   day.
///
/// Every function takes its `ModelContext` rather than capturing one, so the
/// same code runs on the main context (from the editor, where the user is
/// waiting for a result) and inside `ScheduleEngine`'s background actor.
public enum OccurrenceMaterializer {

    /// How far back unresolved rows are kept before pruning.
    ///
    /// A **retention** bound, deliberately not a generation bound. See
    /// `materializationRange`.
    public static let retentionDays = 7

    /// Days ahead materialised. Comfortably beyond the notification budget's
    /// reach, so Phase 5 always has rows to schedule from.
    public static let futureWindowDays = 30

    // MARK: - Window

    /// The range that gets generated: **today forward**, never backwards.
    ///
    /// Generation must not backfill. A past occurrence should exist only
    /// because that day was once today and the app created it then. Generating
    /// rows for days already gone invents a record the user never lived: add an
    /// item this morning and the next sweep would declare a week of doses
    /// "missed" that nobody was ever reminded about. For a medication app,
    /// fabricating non-adherence is worse than showing nothing at all.
    public static func materializationRange(
        around date: Date = .now,
        calendar: Calendar = .current
    ) -> ClosedRange<Date> {
        let today = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: futureWindowDays, to: today) ?? today
        return today...end
    }

    /// Unresolved rows older than this are pruned. Resolved rows are never
    /// pruned at all — they're the adherence history.
    public static func retentionCutoff(
        around date: Date = .now,
        calendar: Calendar = .current
    ) -> Date {
        let today = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: -retentionDays, to: today) ?? today
    }

    /// Materialises the rolling window forward from `date`. Returns rows created.
    @discardableResult
    public static func materializeWindow(
        around date: Date = .now,
        context: ModelContext,
        calendar: Calendar = .current
    ) throws -> Int {
        let range = materializationRange(around: date, calendar: calendar)
        return try materialize(
            from: range.lowerBound,
            through: range.upperBound,
            context: context,
            calendar: calendar
        )
    }

    /// Materialises every day in `from...through` inclusive. Returns rows created.
    ///
    /// Existing rows and items are fetched once for the whole range rather than
    /// per day — the day-at-a-time version issued two fetches per day, which is
    /// 74 fetches for a single window pass.
    @discardableResult
    public static func materialize(
        from startDay: Date,
        through endDay: Date,
        context: ModelContext,
        calendar: Calendar = .current
    ) throws -> Int {
        let rangeStart = calendar.startOfDay(for: startDay)
        guard let rangeEnd = calendar.date(
            byAdding: .day, value: 1, to: calendar.startOfDay(for: endDay)
        ), rangeStart < rangeEnd else { return 0 }

        let existing = try context.fetch(
            FetchDescriptor<Occurrence>(
                predicate: #Predicate { $0.scheduledAt >= rangeStart && $0.scheduledAt < rangeEnd }
            )
        )
        var index = Set(existing.map(Key.init))

        let items = try context.fetch(
            FetchDescriptor<TrackedItem>(predicate: #Predicate { !$0.isArchived })
        )
        guard !items.isEmpty else { return 0 }

        var created = 0
        var day = rangeStart

        while day < rangeEnd {
            for item in items {
                for schedule in item.activeSchedules {
                    let rule = schedule.rule
                    guard rule.generatesOccurrences else { continue }
                    guard rule.occurs(
                        on: day,
                        startDate: schedule.startDate,
                        endDate: schedule.endDate,
                        calendar: calendar
                    ) else { continue }

                    for minutes in schedule.timesOfDay {
                        let parts = TimeOfDay.components(from: minutes)
                        guard let scheduledAt = calendar.date(
                            bySettingHour: parts.hour,
                            minute: parts.minute,
                            second: 0,
                            of: day
                        ) else { continue }

                        let key = Key(scheduleID: schedule.id, scheduledAt: scheduledAt)
                        guard !index.contains(key) else { continue }

                        context.insert(Occurrence(
                            item: item,
                            scheduledAt: scheduledAt,
                            generatedFromScheduleID: schedule.id
                        ))
                        index.insert(key)
                        created += 1
                    }
                }
            }

            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        if created > 0 {
            try context.save()
        }
        return created
    }

    /// Convenience for a single day.
    @discardableResult
    public static func materialize(
        day: Date,
        context: ModelContext,
        calendar: Calendar = .current
    ) throws -> Int {
        try materialize(from: day, through: day, context: context, calendar: calendar)
    }

    // MARK: - Reconciliation

    /// Removes future, still-pending rows produced by a schedule so it can be
    /// regenerated after an edit.
    ///
    /// Deliberately narrow: past rows and anything already resolved are left
    /// alone. Editing "8:00 AM" to "9:00 AM" must not rewrite the record of
    /// doses already taken at 8:00.
    public static func removeFuturePending(
        scheduleID: UUID,
        after moment: Date = .now,
        context: ModelContext
    ) throws {
        let pending = OccurrenceState.pending.rawValue
        let stale = try context.fetch(
            FetchDescriptor<Occurrence>(
                predicate: #Predicate<Occurrence> { occurrence in
                    occurrence.generatedFromScheduleID == scheduleID
                        && occurrence.scheduledAt > moment
                        && occurrence.stateRaw == pending
                }
            )
        )
        for occurrence in stale {
            context.delete(occurrence)
        }
        if !stale.isEmpty {
            try context.save()
        }
    }

    /// Drops *every* future pending row and regenerates the window.
    ///
    /// This is the time-zone-change path. When the device moves between zones,
    /// each occurrence's stored absolute time no longer matches the wall-clock
    /// time the user asked for — "8:00 AM" was resolved against the old zone.
    /// Regenerating is the only way to put them back on the clock. Resolved
    /// history stays exactly where it is, because it records when something
    /// actually happened.
    @discardableResult
    public static func rematerializeFuture(
        now: Date = .now,
        context: ModelContext,
        calendar: Calendar = .current
    ) throws -> Int {
        let pending = OccurrenceState.pending.rawValue
        let stale = try context.fetch(
            FetchDescriptor<Occurrence>(
                predicate: #Predicate<Occurrence> { occurrence in
                    occurrence.scheduledAt > now && occurrence.stateRaw == pending
                }
            )
        )
        for occurrence in stale {
            context.delete(occurrence)
        }
        if !stale.isEmpty {
            try context.save()
        }
        return try materializeWindow(around: now, context: context, calendar: calendar)
    }

    // MARK: - Missed sweep

    /// Marks still-pending rows from days before today as `missed`.
    ///
    /// Deliberately end-of-day rather than a short grace period. `isOverdue` is
    /// the live, gentle display state for "this is late but the day isn't
    /// over"; `missed` is terminal and belongs to a day that has finished. An
    /// app that declares a dose missed thirty minutes late, while the user is
    /// still perfectly likely to take it, is nagging rather than helping.
    ///
    /// Returns the number of rows swept.
    @discardableResult
    public static func sweepMissed(
        now: Date = .now,
        context: ModelContext,
        calendar: Calendar = .current
    ) throws -> Int {
        let today = calendar.startOfDay(for: now)
        let pending = OccurrenceState.pending.rawValue

        let stale = try context.fetch(
            FetchDescriptor<Occurrence>(
                predicate: #Predicate<Occurrence> { occurrence in
                    occurrence.scheduledAt < today && occurrence.stateRaw == pending
                }
            )
        )
        for occurrence in stale {
            occurrence.state = .missed
        }
        if !stale.isEmpty {
            try context.save()
        }
        return stale.count
    }

    // MARK: - Pruning

    /// Deletes unresolved rows that have fallen out of the back of the window,
    /// so the store doesn't grow without bound.
    ///
    /// Resolved rows are kept forever — they are the adherence history, and the
    /// only reason this app is worth trusting.
    @discardableResult
    public static func pruneOldUnresolved(
        before date: Date,
        context: ModelContext
    ) throws -> Int {
        let pending = OccurrenceState.pending.rawValue
        let missed = OccurrenceState.missed.rawValue

        let old = try context.fetch(
            FetchDescriptor<Occurrence>(
                predicate: #Predicate<Occurrence> { occurrence in
                    occurrence.scheduledAt < date
                        && (occurrence.stateRaw == pending || occurrence.stateRaw == missed)
                }
            )
        )
        for occurrence in old {
            context.delete(occurrence)
        }
        if !old.isEmpty {
            try context.save()
        }
        return old.count
    }

    /// Identity of a generated occurrence: which schedule made it, and when for.
    ///
    /// CloudKit forbids unique constraints, so idempotency is enforced with
    /// this key rather than by the store.
    private struct Key: Hashable {
        let scheduleID: UUID
        let scheduledAt: Date

        init(scheduleID: UUID, scheduledAt: Date) {
            self.scheduleID = scheduleID
            self.scheduledAt = scheduledAt
        }

        init(_ occurrence: Occurrence) {
            self.scheduleID = occurrence.generatedFromScheduleID ?? UUID()
            self.scheduledAt = occurrence.scheduledAt
        }
    }
}
