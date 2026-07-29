import Testing
import Foundation
import SwiftData
@testable import MagicPillKit

/// Phase 5: the notification budget and the engine paths a banner action takes.
///
/// The budget is tested exhaustively because its failure mode is silent. iOS
/// drops requests past 64 without an error, a callback, or any signal at all —
/// the reminder simply never arrives, and the user has no way to know the app
/// stopped reminding them.
@Suite("Notifications")
struct NotificationTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func reminder(offsetMinutes: Int, title: String = "Vitamin D") -> Reminder {
        Reminder(
            id: UUID(),
            fireDate: now.addingTimeInterval(TimeInterval(offsetMinutes) * 60),
            title: title,
            body: "1 Tablet"
        )
    }

    // MARK: - Budget

    @Test("The scheduled limit stays under the system limit, with snooze headroom")
    func limitLeavesHeadroom() {
        #expect(NotificationBudget.systemLimit == 64)
        #expect(NotificationBudget.scheduledLimit < NotificationBudget.systemLimit)
    }

    /// The defect the budget exists to prevent: schedule everything and iOS
    /// silently discards the overflow.
    @Test("More reminders than the budget are trimmed, never dropped by iOS")
    func budgetTrims() {
        let many = (1...200).map { reminder(offsetMinutes: $0) }
        let selected = NotificationBudget.select(from: many, now: now)

        #expect(selected.count == NotificationBudget.scheduledLimit)
        #expect(selected.count <= NotificationBudget.systemLimit)
    }

    @Test("The soonest reminders win the available slots")
    func budgetPrefersSoonest() {
        let many = (1...200).map { reminder(offsetMinutes: $0) }
        let selected = NotificationBudget.select(from: many, now: now, limit: 5)

        let expected = many.prefix(5).map(\.id)
        #expect(selected.map(\.id) == expected)
    }

    @Test("Selection is sorted earliest first regardless of input order")
    func budgetSorts() {
        let shuffled = [
            reminder(offsetMinutes: 90),
            reminder(offsetMinutes: 10),
            reminder(offsetMinutes: 50),
        ]
        let selected = NotificationBudget.select(from: shuffled, now: now)

        #expect(selected.map(\.fireDate) == selected.map(\.fireDate).sorted())
        #expect(selected.first?.fireDate == now.addingTimeInterval(600))
    }

    /// A notification scheduled for the past never fires, and would consume one
    /// of only 64 slots to do nothing.
    @Test("Reminders in the past are excluded")
    func budgetExcludesPast() {
        let mixed = [
            reminder(offsetMinutes: -60),
            reminder(offsetMinutes: -1),
            reminder(offsetMinutes: 30),
        ]
        let selected = NotificationBudget.select(from: mixed, now: now)

        #expect(selected.count == 1)
        #expect(selected.first?.fireDate == now.addingTimeInterval(1800))
    }

    @Test("An empty or zero-limit selection returns nothing rather than crashing")
    func budgetDegenerateInputs() {
        #expect(NotificationBudget.select(from: [], now: now).isEmpty)
        #expect(NotificationBudget.select(
            from: [reminder(offsetMinutes: 10)], now: now, limit: 0
        ).isEmpty)
    }

    // MARK: - Reminder snapshots

    @Test("Request identifiers round-trip through the occurrence id")
    func identifierRoundTrip() {
        let id = UUID()
        let requestID = NotificationIDs.requestID(for: id)
        #expect(NotificationIDs.occurrenceID(fromRequestID: requestID) == id)
        #expect(NotificationIDs.occurrenceID(fromRequestID: "not-a-uuid") == nil)
    }

    @Test("A resolved occurrence never becomes a reminder")
    @MainActor
    func resolvedNeverRings() throws {
        let container = try PersistenceStore.inMemory()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext

        let item = TrackedItem(name: "Vitamin D", detail: "1 Tablet")
        context.insert(item)

        let pending = Occurrence(item: item, scheduledAt: now.addingTimeInterval(3600))
        let taken = Occurrence(
            item: item, scheduledAt: now.addingTimeInterval(7200), state: .taken
        )
        context.insert(pending)
        context.insert(taken)

        #expect(Reminder(occurrence: pending) != nil)
        #expect(Reminder(occurrence: taken) == nil)
    }

    @Test("A snoozed reminder fires at its snoozed time, not its scheduled time")
    @MainActor
    func snoozeMovesFireDate() throws {
        let container = try PersistenceStore.inMemory()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext

        let item = TrackedItem(name: "Vitamin D")
        context.insert(item)
        let occurrence = Occurrence(item: item, scheduledAt: now)
        occurrence.snoozedUntil = now.addingTimeInterval(900)
        context.insert(occurrence)

        let snapshot = try #require(Reminder(occurrence: occurrence))
        #expect(snapshot.fireDate == now.addingTimeInterval(900))
    }

    @Test("Reminder body joins dosage and note, skipping empties")
    @MainActor
    func reminderBody() throws {
        let container = try PersistenceStore.inMemory()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext

        let full = TrackedItem(name: "A", detail: "1 Tablet", note: "With food")
        let sparse = TrackedItem(name: "B", detail: "2 Capsules")
        context.insert(full)
        context.insert(sparse)

        let fullOccurrence = Occurrence(item: full, scheduledAt: now)
        let sparseOccurrence = Occurrence(item: sparse, scheduledAt: now)
        context.insert(fullOccurrence)
        context.insert(sparseOccurrence)

        #expect(Reminder(occurrence: fullOccurrence)?.body == "1 Tablet · With food")
        #expect(Reminder(occurrence: sparseOccurrence)?.body == "2 Capsules")
    }

    @Test("Snooze default is 15 minutes and is defined in exactly one place")
    func snoozeDefault() {
        #expect(SnoozeDefaults.interval == 15 * 60)
        #expect(SnoozeDefaults.nextTime(from: now) == now.addingTimeInterval(900))
    }

    // MARK: - Engine paths taken by banner actions

    @Test("Resolving by id marks the occurrence and clears any snooze")
    @MainActor
    func engineResolvesByID() async throws {
        let container = try PersistenceStore.inMemory()
        let context = container.mainContext

        let item = TrackedItem(name: "Vitamin D")
        context.insert(item)
        let occurrence = Occurrence(item: item, scheduledAt: now)
        occurrence.snoozedUntil = now.addingTimeInterval(900)
        context.insert(occurrence)
        try context.save()
        let id = occurrence.id

        let engine = ScheduleEngine(modelContainer: container)
        let didResolve = try await engine.resolve(occurrenceID: id, as: .taken, at: now)

        // Re-fetch rather than reading `occurrence`. The engine writes through
        // its own context; the instance held here is a different context's
        // snapshot and is not refreshed by the write. Asserting on it would be
        // testing SwiftData's change propagation, not the engine.
        let reloaded = try #require(
            try context.fetch(FetchDescriptor<Occurrence>(
                predicate: #Predicate { $0.id == id }
            )).first
        )

        #expect(didResolve)
        #expect(reloaded.state == .taken)
        #expect(reloaded.snoozedUntil == nil)
        #expect(reloaded.resolvedAt == now)
    }

    /// Guards against double-resolution — a banner tapped twice, or the same
    /// dose resolved on two devices.
    @Test("Resolving an already-resolved occurrence is refused")
    @MainActor
    func engineRefusesDoubleResolve() async throws {
        let container = try PersistenceStore.inMemory()
        let context = container.mainContext

        let item = TrackedItem(name: "Vitamin D")
        context.insert(item)
        let occurrence = Occurrence(item: item, scheduledAt: now, state: .taken)
        context.insert(occurrence)
        try context.save()

        let engine = ScheduleEngine(modelContainer: container)
        let didResolve = try await engine.resolve(
            occurrenceID: occurrence.id, as: .skipped, at: now
        )

        #expect(!didResolve)
        #expect(occurrence.state == .taken)
    }

    @Test("Resolving an unknown id is refused rather than resurrecting a row")
    @MainActor
    func engineRefusesUnknownID() async throws {
        let container = try PersistenceStore.inMemory()
        let engine = ScheduleEngine(modelContainer: container)

        let didResolve = try await engine.resolve(occurrenceID: UUID(), as: .taken, at: now)
        #expect(!didResolve)
    }

    /// Snoozing is not rescheduling: the record must still show what was
    /// originally due when.
    @Test("Snoozing moves the effective time and preserves the scheduled time")
    @MainActor
    func engineSnoozePreservesSchedule() async throws {
        let container = try PersistenceStore.inMemory()
        let context = container.mainContext

        let item = TrackedItem(name: "Vitamin D")
        context.insert(item)
        let occurrence = Occurrence(item: item, scheduledAt: now)
        context.insert(occurrence)
        try context.save()

        let engine = ScheduleEngine(modelContainer: container)
        let until = now.addingTimeInterval(900)
        let id = occurrence.id
        let didSnooze = try await engine.snooze(occurrenceID: id, until: until)

        let reloaded = try #require(
            try context.fetch(FetchDescriptor<Occurrence>(
                predicate: #Predicate { $0.id == id }
            )).first
        )

        #expect(didSnooze)
        #expect(reloaded.scheduledAt == now)
        #expect(reloaded.effectiveTime == until)
        #expect(reloaded.state == .pending)
    }

    @Test("Snoozing a resolved occurrence is refused")
    @MainActor
    func engineRefusesSnoozeOnResolved() async throws {
        let container = try PersistenceStore.inMemory()
        let context = container.mainContext

        let item = TrackedItem(name: "Vitamin D")
        context.insert(item)
        let occurrence = Occurrence(item: item, scheduledAt: now, state: .taken)
        context.insert(occurrence)
        try context.save()

        let engine = ScheduleEngine(modelContainer: container)
        let didSnooze = try await engine.snooze(
            occurrenceID: occurrence.id, until: now.addingTimeInterval(900)
        )

        #expect(!didSnooze)
        #expect(occurrence.snoozedUntil == nil)
    }

    @Test("The engine yields only future, unresolved reminders")
    @MainActor
    func engineRemindersAreSchedulable() async throws {
        let container = try PersistenceStore.inMemory()
        let context = container.mainContext

        let item = TrackedItem(name: "Vitamin D")
        context.insert(item)
        context.insert(Occurrence(item: item, scheduledAt: now.addingTimeInterval(-3600)))
        context.insert(Occurrence(
            item: item, scheduledAt: now.addingTimeInterval(3600), state: .taken
        ))
        context.insert(Occurrence(item: item, scheduledAt: now.addingTimeInterval(7200)))
        try context.save()

        let engine = ScheduleEngine(modelContainer: container)
        let reminders = try await engine.reminders(now: now)

        #expect(reminders.count == 1)
        #expect(reminders.first?.fireDate == now.addingTimeInterval(7200))
    }

    /// End-to-end on the data side: a full window's worth of occurrences must
    /// still yield a budget-sized set, not 200 doomed requests.
    @Test("A busy schedule still produces a budget-sized set")
    @MainActor
    func busyScheduleStaysWithinBudget() async throws {
        let container = try PersistenceStore.inMemory()
        let context = container.mainContext

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!

        // Four items, twice a day, across the whole forward window: ~248 rows.
        for name in ["A", "B", "C", "D"] {
            let item = TrackedItem(name: name)
            context.insert(item)
            let schedule = Schedule(
                rule: .everyDay,
                timesOfDay: [TimeOfDay.minutes(hour: 8), TimeOfDay.minutes(hour: 20)],
                startDate: now.addingTimeInterval(-86_400)
            )
            schedule.item = item
            context.insert(schedule)
        }
        try context.save()

        let engine = ScheduleEngine(modelContainer: container)
        _ = try await engine.runMaintenance(now: now, calendar: calendar)

        let reminders = try await engine.reminders(now: now)
        let selected = NotificationBudget.select(from: reminders, now: now)

        #expect(selected.count == NotificationBudget.scheduledLimit)
        #expect(selected.count < NotificationBudget.systemLimit)
    }
}
