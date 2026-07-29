import Foundation
import SwiftData

/// Runs materialisation off the main thread.
///
/// A window pass touches 38 days across every active schedule. On the main
/// context that work lands between the user's finger and the screen; here it
/// runs on the actor's own context and the timeline picks up the results
/// through its `@Query`.
///
/// `@ModelActor` synthesises `init(modelContainer:)` and a `modelContext`
/// bound to this actor's executor.
@ModelActor
public actor ScheduleEngine {

    /// What a maintenance pass actually did. Returned rather than logged so
    /// callers — and tests — can assert on it.
    public struct Result: Sendable, Equatable {
        public var created: Int = 0
        public var swept: Int = 0
        public var pruned: Int = 0

        public var didChangeAnything: Bool {
            created > 0 || swept > 0 || pruned > 0
        }
    }

    /// The routine run on launch, on foreground, and from background refresh.
    ///
    /// Ordered deliberately:
    /// 1. **Sweep** first, so yesterday's stragglers become `missed` before
    ///    anything else looks at them.
    /// 2. **Prune** next, clearing unresolved rows that fell out of the window.
    /// 3. **Materialise** last, refilling the window — including any day the
    ///    prune just emptied at the leading edge.
    ///
    /// Running materialise first would generate rows the prune then deletes.
    @discardableResult
    public func runMaintenance(
        now: Date = .now,
        calendar: Calendar = .current
    ) throws -> Result {
        var result = Result()

        result.swept = try OccurrenceMaterializer.sweepMissed(
            now: now, context: modelContext, calendar: calendar
        )

        result.pruned = try OccurrenceMaterializer.pruneOldUnresolved(
            before: OccurrenceMaterializer.retentionCutoff(around: now, calendar: calendar),
            context: modelContext
        )

        result.created = try OccurrenceMaterializer.materializeWindow(
            around: now, context: modelContext, calendar: calendar
        )

        return result
    }

    /// Rebuilds every future pending row against the current time zone.
    ///
    /// Called when the system time zone changes. Stored occurrences hold
    /// absolute dates resolved against the *old* zone, so after a flight the
    /// user's "8:00 AM" dose would fire at 8:00 AM in the zone they left.
    @discardableResult
    public func handleTimeZoneChange(
        now: Date = .now,
        calendar: Calendar = .current
    ) throws -> Int {
        try OccurrenceMaterializer.rematerializeFuture(
            now: now, context: modelContext, calendar: calendar
        )
    }

    // MARK: - Notification support

    /// Resolves an occurrence by id. This is the path a notification action
    /// takes: the response carries an identifier and nothing else.
    ///
    /// Returns false when the row has vanished — deleted, pruned, or already
    /// resolved on another device — so the caller can decline to act rather
    /// than resurrect it.
    @discardableResult
    public func resolve(
        occurrenceID: UUID,
        as state: OccurrenceState,
        at moment: Date = .now
    ) throws -> Bool {
        guard let occurrence = try fetchOccurrence(id: occurrenceID) else { return false }
        guard !occurrence.isResolved else { return false }

        occurrence.state = state
        occurrence.resolvedAt = moment
        occurrence.snoozedUntil = nil
        try modelContext.save()
        return true
    }

    /// Pushes an occurrence back without touching its scheduled time.
    ///
    /// `scheduledAt` stays put and `snoozedUntil` moves, so the record still
    /// shows what was originally due when — snoozing is not rescheduling.
    @discardableResult
    public func snooze(
        occurrenceID: UUID,
        until moment: Date
    ) throws -> Bool {
        guard let occurrence = try fetchOccurrence(id: occurrenceID) else { return false }
        guard !occurrence.isResolved else { return false }

        occurrence.snoozedUntil = moment
        try modelContext.save()
        return true
    }

    /// Snapshots of the occurrences a notification could be scheduled for:
    /// unresolved, and still ahead of `now`.
    ///
    /// Returns `Reminder` values rather than models because `Occurrence` is not
    /// `Sendable` and must not leave this actor. Mapping happens here, inside
    /// the isolation that owns the objects.
    ///
    /// Fetches a bounded number rather than the whole window — the budget will
    /// only ever use the soonest few dozen, and materialising hundreds of model
    /// objects to discard them is wasted work on every foreground.
    public func reminders(
        now: Date = .now,
        limit: Int = NotificationBudget.scheduledLimit
    ) throws -> [Reminder] {
        let pending = OccurrenceState.pending.rawValue
        var descriptor = FetchDescriptor<Occurrence>(
            predicate: #Predicate<Occurrence> { occurrence in
                occurrence.stateRaw == pending && occurrence.scheduledAt > now
            },
            sortBy: [SortDescriptor(\.scheduledAt, order: .forward)]
        )
        // Generous headroom over the budget: a snoozed row sorts by
        // `scheduledAt` here but by `effectiveTime` in the budget, so the
        // ordering isn't identical and trimming to exactly `limit` could clip
        // one that belongs.
        descriptor.fetchLimit = limit * 2

        return try modelContext.fetch(descriptor).compactMap(Reminder.init(occurrence:))
    }

    private func fetchOccurrence(id: UUID) throws -> Occurrence? {
        var descriptor = FetchDescriptor<Occurrence>(
            predicate: #Predicate<Occurrence> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// Regenerates future rows for one edited schedule.
    @discardableResult
    public func reconcile(
        scheduleID: UUID,
        now: Date = .now,
        calendar: Calendar = .current
    ) throws -> Int {
        try OccurrenceMaterializer.removeFuturePending(
            scheduleID: scheduleID, after: now, context: modelContext
        )
        return try OccurrenceMaterializer.materializeWindow(
            around: now, context: modelContext, calendar: calendar
        )
    }
}
