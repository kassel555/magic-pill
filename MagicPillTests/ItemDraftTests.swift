import Testing
import Foundation
import SwiftData
@testable import MagicPillKit

/// Tests for the editor's save path.
///
/// The SwiftUI form around `ItemDraft` is thin plumbing; everything that can
/// actually go wrong — creating vs. updating, reconciling a changed schedule,
/// preserving history — lives here and is tested without standing up a view.
@Suite("Item draft")
@MainActor
struct ItemDraftTests {

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

    // MARK: - Validation

    @Test("A draft needs a name and at least one time")
    func validation() {
        var draft = ItemDraft()
        #expect(!draft.isValid)

        draft.name = "   "
        #expect(!draft.isValid)

        draft.name = "Vitamin D"
        #expect(draft.isValid)

        draft.timesOfDay = []
        #expect(!draft.isValid)
    }

    @Test("Whitespace is trimmed on commit")
    func trimsWhitespace() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }

        var draft = ItemDraft()
        draft.name = "  Vitamin D  "
        draft.detail = "  1 Tablet "
        draft.note = " With food "

        let item = try draft.commit(context: context, calendar: calendar, now: date(2026, 7, 10, 6))

        #expect(item.name == "Vitamin D")
        #expect(item.detail == "1 Tablet")
        #expect(item.note == "With food")
    }

    // MARK: - Creating

    @Test("Committing a new draft creates the item, its schedule, and today's rows")
    func createsItem() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }

        var draft = ItemDraft()
        draft.name = "Vitamin D"
        draft.startDate = date(2026, 7, 1)
        draft.timesOfDay = [TimeOfDay.minutes(hour: 8), TimeOfDay.minutes(hour: 20)]

        let item = try draft.commit(
            context: context, calendar: calendar, now: date(2026, 7, 10, 6)
        )

        #expect(try context.fetchCount(FetchDescriptor<TrackedItem>()) == 1)
        #expect(item.schedules?.count == 1)
        #expect(item.schedules?.first?.timesOfDay == [480, 1200])
        #expect(try context.fetchCount(FetchDescriptor<Occurrence>()) == 2)
    }

    @Test("Times are stored sorted regardless of entry order")
    func sortsTimes() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }

        var draft = ItemDraft()
        draft.name = "Vitamin D"
        draft.timesOfDay = [
            TimeOfDay.minutes(hour: 20),
            TimeOfDay.minutes(hour: 8),
            TimeOfDay.minutes(hour: 13),
        ]

        let item = try draft.commit(context: context, calendar: calendar, now: date(2026, 7, 10, 6))
        #expect(item.schedules?.first?.timesOfDay == [480, 780, 1200])
    }

    // MARK: - Editing

    @Test("Committing an existing item updates rather than duplicating")
    func updatesItem() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let now = date(2026, 7, 10, 6)

        var draft = ItemDraft()
        draft.name = "Vitamin D"
        draft.startDate = date(2026, 7, 1)
        let item = try draft.commit(context: context, calendar: calendar, now: now)

        var edit = ItemDraft(item: item)
        edit.name = "Vitamin D3"
        edit.detail = "2 Tablets"
        edit.colorToken = .ocean
        try edit.commit(existing: item, context: context, calendar: calendar, now: now)

        #expect(try context.fetchCount(FetchDescriptor<TrackedItem>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Schedule>()) == 1)
        #expect(item.name == "Vitamin D3")
        #expect(item.detail == "2 Tablets")
        #expect(item.colorToken == .ocean)
    }

    @Test("A round-trip through the draft changes nothing")
    func roundTripIsStable() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let now = date(2026, 7, 10, 6)

        var draft = ItemDraft()
        draft.name = "Blood Pressure"
        draft.detail = "1 Capsule"
        draft.note = "With water"
        draft.colorToken = .lavender
        draft.rule = .weekly(interval: 2, weekdays: [2, 4])
        draft.timesOfDay = [TimeOfDay.minutes(hour: 9)]
        draft.startDate = date(2026, 7, 1)
        draft.endDate = date(2026, 12, 31)

        let item = try draft.commit(context: context, calendar: calendar, now: now)
        let reloaded = ItemDraft(item: item)

        #expect(reloaded.name == draft.name)
        #expect(reloaded.detail == draft.detail)
        #expect(reloaded.note == draft.note)
        #expect(reloaded.colorToken == draft.colorToken)
        #expect(reloaded.rule == draft.rule)
        #expect(reloaded.timesOfDay == draft.timesOfDay)
    }

    /// The behaviour that makes "Cancel" honest. Mutating a draft must not
    /// reach the store until it is committed.
    @Test("Editing a draft without committing leaves the store untouched")
    func draftIsNotLive() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let now = date(2026, 7, 10, 6)

        var draft = ItemDraft()
        draft.name = "Vitamin D"
        let item = try draft.commit(context: context, calendar: calendar, now: now)

        var abandoned = ItemDraft(item: item)
        abandoned.name = "Something Else"
        abandoned.detail = "99 Tablets"
        // No commit.

        #expect(item.name == "Vitamin D")
        #expect(item.detail.isEmpty)
    }

    // MARK: - Reconciliation

    /// Rescheduling must move future doses without rewriting the record of
    /// doses already taken.
    @Test("Changing the time reschedules the future and preserves history")
    func reschedulingPreservesHistory() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }

        // Commit at 06:00, so the day's 08:00 row is still in the future.
        let morning = date(2026, 7, 10, 6)
        var draft = ItemDraft()
        draft.name = "Vitamin D"
        draft.startDate = date(2026, 7, 1)
        draft.timesOfDay = [TimeOfDay.minutes(hour: 8)]
        let item = try draft.commit(context: context, calendar: calendar, now: morning)

        // The user takes it.
        let taken = try #require(try context.fetch(FetchDescriptor<Occurrence>()).first)
        taken.state = .taken
        taken.resolvedAt = date(2026, 7, 10, 8)
        try context.save()

        // Later that day they move the schedule to 20:00.
        let evening = date(2026, 7, 10, 12)
        var edit = ItemDraft(item: item)
        edit.timesOfDay = [TimeOfDay.minutes(hour: 20)]
        try edit.commit(existing: item, context: context, calendar: calendar, now: evening)

        let occurrences = try context.fetch(FetchDescriptor<Occurrence>())
        let states = occurrences.map(\.state)

        // The taken 08:00 row survives; a new pending 20:00 row joins it.
        #expect(occurrences.count == 2)
        #expect(states.contains(.taken))
        #expect(states.contains(.pending))
        #expect(occurrences.contains { $0.scheduledAt == date(2026, 7, 10, 8) })
        #expect(occurrences.contains { $0.scheduledAt == date(2026, 7, 10, 20) })
    }

    @Test("Committing repeatedly does not accumulate duplicate rows")
    func repeatedCommitsAreIdempotent() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let now = date(2026, 7, 10, 6)

        var draft = ItemDraft()
        draft.name = "Vitamin D"
        draft.startDate = date(2026, 7, 1)
        draft.timesOfDay = [TimeOfDay.minutes(hour: 8)]

        let item = try draft.commit(context: context, calendar: calendar, now: now)
        try draft.commit(existing: item, context: context, calendar: calendar, now: now)
        try draft.commit(existing: item, context: context, calendar: calendar, now: now)

        #expect(try context.fetchCount(FetchDescriptor<Occurrence>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Schedule>()) == 1)
    }

    @Test("An as-needed item generates no occurrences")
    func asNeededGeneratesNothing() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }

        var draft = ItemDraft()
        draft.name = "Painkiller"
        draft.rule = .asNeeded
        try draft.commit(context: context, calendar: calendar, now: date(2026, 7, 10, 6))

        #expect(try context.fetchCount(FetchDescriptor<TrackedItem>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Occurrence>()) == 0)
    }

    @Test("Deleting an item cascades to its schedules and occurrences")
    func deleteCascades() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }

        var draft = ItemDraft()
        draft.name = "Vitamin D"
        draft.startDate = date(2026, 7, 1)
        let item = try draft.commit(context: context, calendar: calendar, now: date(2026, 7, 10, 6))

        #expect(try context.fetchCount(FetchDescriptor<Occurrence>()) == 1)

        context.delete(item)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<TrackedItem>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Schedule>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Occurrence>()) == 0)
    }
}
