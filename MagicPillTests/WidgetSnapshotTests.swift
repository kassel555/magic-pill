import Testing
import Foundation
import SwiftData
@testable import MagicPillKit

/// Phase 6: the data a widget renders from.
///
/// Worth testing carefully because the widget's failure mode is quiet. It runs
/// in another process, refreshes on WidgetKit's schedule, and a wrong number on
/// the home screen looks exactly like a right one.
@Suite("Widget snapshot")
@MainActor
struct WidgetSnapshotTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func makeStore() throws -> (ModelContainer, ModelContext) {
        let container = try PersistenceStore.inMemory()
        return (container, container.mainContext)
    }

    @discardableResult
    private func addOccurrence(
        _ item: TrackedItem,
        at when: Date,
        state: OccurrenceState = .pending,
        context: ModelContext
    ) -> Occurrence {
        let occurrence = Occurrence(item: item, scheduledAt: when, state: state)
        context.insert(occurrence)
        return occurrence
    }

    // MARK: - Progress

    @Test("Today's progress counts resolved against total")
    func progressCounts() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let now = date(2026, 7, 15, 12)

        let item = TrackedItem(name: "Vitamin D", detail: "1 Tablet")
        context.insert(item)
        addOccurrence(item, at: date(2026, 7, 15, 8), state: .taken, context: context)
        addOccurrence(item, at: date(2026, 7, 15, 9), state: .skipped, context: context)
        addOccurrence(item, at: date(2026, 7, 15, 20), context: context)
        try context.save()

        let snapshot = try WidgetSnapshotLoader.load(
            context: context, now: now, calendar: calendar
        )

        #expect(snapshot.totalToday == 3)
        #expect(snapshot.completedToday == 2)
        #expect(snapshot.remainingToday == 1)
        #expect(!snapshot.isDayComplete)
    }

    /// A day with nothing on it should read as calm, not as a zeroed-out ring
    /// that looks like failure.
    @Test("An empty day reads as complete, not as zero progress")
    func emptyDayIsComplete() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }

        let snapshot = try WidgetSnapshotLoader.load(
            context: context, now: date(2026, 7, 15, 12), calendar: calendar
        )

        #expect(snapshot.totalToday == 0)
        #expect(snapshot.progress == 1)
        #expect(snapshot.isDayComplete)
        #expect(snapshot.next == nil)
    }

    @Test("Yesterday's and tomorrow's rows don't count towards today")
    func progressIsScopedToToday() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }

        let item = TrackedItem(name: "Vitamin D")
        context.insert(item)
        addOccurrence(item, at: date(2026, 7, 14, 8), state: .taken, context: context)
        addOccurrence(item, at: date(2026, 7, 15, 8), state: .taken, context: context)
        addOccurrence(item, at: date(2026, 7, 16, 8), context: context)
        try context.save()

        let snapshot = try WidgetSnapshotLoader.load(
            context: context, now: date(2026, 7, 15, 12), calendar: calendar
        )

        #expect(snapshot.totalToday == 1)
        #expect(snapshot.completedToday == 1)
    }

    // MARK: - Upcoming

    @Test("Upcoming is future, unresolved, and earliest first")
    func upcomingOrdering() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let now = date(2026, 7, 15, 12)

        let item = TrackedItem(name: "Vitamin D")
        context.insert(item)
        addOccurrence(item, at: date(2026, 7, 15, 8), context: context)          // past
        addOccurrence(item, at: date(2026, 7, 15, 20), state: .taken, context: context)
        addOccurrence(item, at: date(2026, 7, 15, 18), context: context)
        addOccurrence(item, at: date(2026, 7, 15, 14), context: context)
        try context.save()

        let snapshot = try WidgetSnapshotLoader.load(
            context: context, now: now, calendar: calendar
        )

        #expect(snapshot.upcoming.count == 2)
        #expect(snapshot.next?.fireDate == date(2026, 7, 15, 14))
        #expect(snapshot.upcoming.map(\.fireDate) == snapshot.upcoming.map(\.fireDate).sorted())
    }

    /// At 11pm the useful answer is tomorrow's first dose, not an empty widget.
    @Test("Upcoming crosses midnight rather than stopping at end of day")
    func upcomingCrossesMidnight() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let lateNight = date(2026, 7, 15, 23)

        let item = TrackedItem(name: "Thyroid")
        context.insert(item)
        addOccurrence(item, at: date(2026, 7, 16, 7), context: context)
        try context.save()

        let snapshot = try WidgetSnapshotLoader.load(
            context: context, now: lateNight, calendar: calendar
        )

        #expect(snapshot.totalToday == 0)
        #expect(snapshot.next?.fireDate == date(2026, 7, 16, 7))
        #expect(snapshot.next?.title == "Thyroid")
    }

    @Test("Upcoming respects its limit")
    func upcomingIsLimited() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let now = date(2026, 7, 15, 0)

        let item = TrackedItem(name: "Vitamin D")
        context.insert(item)
        for hour in 1...20 {
            addOccurrence(item, at: date(2026, 7, 15, hour), context: context)
        }
        try context.save()

        let snapshot = try WidgetSnapshotLoader.load(
            context: context, now: now, calendar: calendar, limit: 3
        )

        #expect(snapshot.upcoming.count == 3)
        #expect(snapshot.next?.fireDate == date(2026, 7, 15, 1))
    }

    @Test("Snapshot carries the item's dosage and note")
    func snapshotCarriesDetail() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }

        let item = TrackedItem(name: "Vitamin D", detail: "1 Tablet", note: "With breakfast")
        context.insert(item)
        addOccurrence(item, at: date(2026, 7, 15, 14), context: context)
        try context.save()

        let snapshot = try WidgetSnapshotLoader.load(
            context: context, now: date(2026, 7, 15, 12), calendar: calendar
        )

        #expect(snapshot.next?.title == "Vitamin D")
        #expect(snapshot.next?.body == "1 Tablet · With breakfast")
    }

    // MARK: - Fixtures

    /// The gallery preview must never look empty or broken — it's the only
    /// impression a user gets before deciding to add the widget.
    @Test("The placeholder is populated and coherent")
    func placeholderIsPopulated() {
        let snapshot = WidgetSnapshot.placeholder()

        #expect(!snapshot.upcoming.isEmpty)
        #expect(snapshot.next != nil)
        #expect(snapshot.totalToday > 0)
        #expect(snapshot.completedToday <= snapshot.totalToday)
        #expect((0...1).contains(snapshot.progress))
    }

    @Test("Progress never leaves 0…1 even with impossible counts")
    func progressIsBounded() {
        let overshoot = WidgetSnapshot(
            generatedAt: .now, upcoming: [], completedToday: 9, totalToday: 3
        )
        #expect(overshoot.remainingToday == 0)
        #expect(overshoot.isDayComplete)
    }
}
