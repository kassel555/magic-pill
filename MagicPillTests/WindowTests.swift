import Testing
import Foundation
import SwiftData
@testable import MagicPillKit

/// Phase 4: the rolling window, the missed sweep, pruning, time-zone travel,
/// and the background engine.
///
/// Every test pins its own calendar and time zone. A scheduling test that
/// depends on where the machine running it happens to be is not a test.
@Suite("Window")
@MainActor
struct WindowTests {

    private func calendar(_ zone: String = "America/New_York") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0,
        zone: String = "America/New_York"
    ) -> Date {
        calendar(zone).date(from: DateComponents(
            year: year, month: month, day: day, hour: hour
        ))!
    }

    private func makeStore() throws -> (ModelContainer, ModelContext) {
        let container = try PersistenceStore.inMemory()
        return (container, container.mainContext)
    }

    /// A daily item at 08:00, starting well before any window under test.
    @discardableResult
    private func addDailyItem(
        named name: String = "Vitamin D",
        at times: [Int] = [TimeOfDay.minutes(hour: 8)],
        start: Date,
        context: ModelContext
    ) -> TrackedItem {
        let item = TrackedItem(name: name)
        context.insert(item)
        let schedule = Schedule(rule: .everyDay, timesOfDay: times, startDate: start)
        schedule.item = item
        context.insert(schedule)
        return item
    }

    // MARK: - Window shape

    @Test("Generation runs from today forward; retention reaches backwards")
    func windowSpan() {
        let cal = calendar()
        let today = date(2026, 7, 15)
        let range = OccurrenceMaterializer.materializationRange(around: today, calendar: cal)

        #expect(range.lowerBound == today)
        #expect(range.upperBound == date(2026, 8, 14))
        #expect(OccurrenceMaterializer.retentionCutoff(around: today, calendar: cal)
                == date(2026, 7, 8))
    }

    @Test("A window pass creates one row per day per time")
    func windowCreatesRows() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let cal = calendar()

        addDailyItem(
            at: [TimeOfDay.minutes(hour: 8), TimeOfDay.minutes(hour: 20)],
            start: date(2026, 1, 1),
            context: context
        )
        try context.save()

        let created = try OccurrenceMaterializer.materializeWindow(
            around: date(2026, 7, 15), context: context, calendar: cal
        )

        // 31 days inclusive (today + 30 forward), twice a day.
        #expect(created == 31 * 2)
    }

    /// Regression test for a real defect: an earlier window spanned 7 days
    /// *behind* today, so generation backfilled rows for days already gone and
    /// the next sweep declared them missed. Adding an item would manufacture a
    /// week of non-adherence the user was never reminded about.
    @Test("Generation never backfills days that have already passed")
    func generationDoesNotBackfill() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let cal = calendar()
        let today = date(2026, 7, 15)

        // An item whose schedule began well before today.
        addDailyItem(start: date(2026, 1, 1), context: context)
        try context.save()

        try OccurrenceMaterializer.materializeWindow(
            around: today, context: context, calendar: cal
        )

        let occurrences = try context.fetch(FetchDescriptor<Occurrence>())
        #expect(!occurrences.isEmpty)
        #expect(occurrences.allSatisfy { $0.scheduledAt >= today })
    }

    /// The property that matters most. The window overlaps itself on every
    /// run; without idempotency the user's morning dose appears twice, then
    /// three times, then four.
    @Test("Overlapping window passes never duplicate rows")
    func overlappingWindowsAreIdempotent() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let cal = calendar()

        addDailyItem(start: date(2026, 1, 1), context: context)
        try context.save()

        let first = try OccurrenceMaterializer.materializeWindow(
            around: date(2026, 7, 15), context: context, calendar: cal
        )
        let second = try OccurrenceMaterializer.materializeWindow(
            around: date(2026, 7, 15), context: context, calendar: cal
        )
        // A day later: the window slides forward by one day.
        let third = try OccurrenceMaterializer.materializeWindow(
            around: date(2026, 7, 16), context: context, calendar: cal
        )

        #expect(first == 31)
        #expect(second == 0)
        #expect(third == 1)
        #expect(try context.fetchCount(FetchDescriptor<Occurrence>()) == 32)
    }

    // MARK: - Missed sweep

    @Test("Yesterday's unresolved rows become missed; today's are left alone")
    func sweepMarksMissed() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let cal = calendar()
        let now = date(2026, 7, 15, 10)

        let item = addDailyItem(start: date(2026, 7, 1), context: context)
        let yesterday = Occurrence(item: item, scheduledAt: date(2026, 7, 14, 8))
        // Earlier today, already late, but the day is not over.
        let earlierToday = Occurrence(item: item, scheduledAt: date(2026, 7, 15, 8))
        context.insert(yesterday)
        context.insert(earlierToday)
        try context.save()

        let swept = try OccurrenceMaterializer.sweepMissed(
            now: now, context: context, calendar: cal
        )

        #expect(swept == 1)
        #expect(yesterday.state == .missed)
        #expect(earlierToday.state == .pending)
    }

    /// `missed` is derived, never chosen. It must not overwrite what the user
    /// actually did.
    @Test("The sweep never touches resolved history")
    func sweepPreservesResolved() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let cal = calendar()

        let item = addDailyItem(start: date(2026, 7, 1), context: context)
        let taken = Occurrence(item: item, scheduledAt: date(2026, 7, 14, 8), state: .taken)
        let skipped = Occurrence(item: item, scheduledAt: date(2026, 7, 13, 8), state: .skipped)
        context.insert(taken)
        context.insert(skipped)
        try context.save()

        let swept = try OccurrenceMaterializer.sweepMissed(
            now: date(2026, 7, 15, 10), context: context, calendar: cal
        )

        #expect(swept == 0)
        #expect(taken.state == .taken)
        #expect(skipped.state == .skipped)
    }

    @Test("The sweep is idempotent")
    func sweepIsIdempotent() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let cal = calendar()

        let item = addDailyItem(start: date(2026, 7, 1), context: context)
        context.insert(Occurrence(item: item, scheduledAt: date(2026, 7, 14, 8)))
        try context.save()

        let now = date(2026, 7, 15, 10)
        #expect(try OccurrenceMaterializer.sweepMissed(now: now, context: context, calendar: cal) == 1)
        #expect(try OccurrenceMaterializer.sweepMissed(now: now, context: context, calendar: cal) == 0)
    }

    // MARK: - Pruning

    @Test("Pruning drops old unresolved rows but keeps the adherence history")
    func pruneKeepsHistory() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }

        let item = addDailyItem(start: date(2026, 1, 1), context: context)
        let ancientTaken = Occurrence(item: item, scheduledAt: date(2026, 1, 5, 8), state: .taken)
        let ancientMissed = Occurrence(item: item, scheduledAt: date(2026, 1, 6, 8), state: .missed)
        let ancientPending = Occurrence(item: item, scheduledAt: date(2026, 1, 7, 8))
        let recent = Occurrence(item: item, scheduledAt: date(2026, 7, 14, 8), state: .taken)
        for occurrence in [ancientTaken, ancientMissed, ancientPending, recent] {
            context.insert(occurrence)
        }
        try context.save()

        let pruned = try OccurrenceMaterializer.pruneOldUnresolved(
            before: date(2026, 7, 8), context: context
        )

        #expect(pruned == 2)
        let remaining = try context.fetch(FetchDescriptor<Occurrence>())
        #expect(remaining.count == 2)
        #expect(remaining.allSatisfy { $0.state == .taken })
    }

    // MARK: - Time-zone travel

    /// The reason `rematerializeFuture` exists. An occurrence stores an
    /// absolute date resolved against the zone the user was in. Fly from New
    /// York to Tokyo and that same instant is no longer 08:00 local — the dose
    /// would fire in the middle of the night.
    @Test("Future rows are rebuilt against the new time zone; history is not")
    func timeZoneTravel() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }

        let newYork = calendar("America/New_York")
        let tokyo = calendar("Asia/Tokyo")

        addDailyItem(start: date(2026, 7, 1), context: context)
        try context.save()

        // Materialise while in New York.
        let departure = date(2026, 7, 15, 10)
        try OccurrenceMaterializer.materializeWindow(
            around: departure, context: context, calendar: newYork
        )

        // Resolve one row, so there is history to protect.
        let past = try #require(
            try context.fetch(FetchDescriptor<Occurrence>())
                .filter { $0.scheduledAt < departure }
                .max(by: { $0.scheduledAt < $1.scheduledAt })
        )
        past.state = .taken
        let historicInstant = past.scheduledAt
        try context.save()

        // Land in Tokyo.
        try OccurrenceMaterializer.rematerializeFuture(
            now: departure, context: context, calendar: tokyo
        )

        let all = try context.fetch(FetchDescriptor<Occurrence>())
        let future = all.filter { $0.scheduledAt > departure }

        // Every future row now reads 08:00 on a Tokyo clock.
        #expect(!future.isEmpty)
        for occurrence in future {
            let hour = tokyo.component(.hour, from: occurrence.scheduledAt)
            let minute = tokyo.component(.minute, from: occurrence.scheduledAt)
            #expect(hour == 8)
            #expect(minute == 0)
        }

        // The taken dose still records the instant it was actually taken.
        #expect(all.contains { $0.state == .taken && $0.scheduledAt == historicInstant })
    }

    @Test("Rematerialising is idempotent when the zone has not changed")
    func rematerializeIsIdempotent() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let cal = calendar()
        let now = date(2026, 7, 15, 10)

        addDailyItem(start: date(2026, 7, 1), context: context)
        try context.save()
        try OccurrenceMaterializer.materializeWindow(around: now, context: context, calendar: cal)

        let before = try context.fetchCount(FetchDescriptor<Occurrence>())
        try OccurrenceMaterializer.rematerializeFuture(now: now, context: context, calendar: cal)
        let after = try context.fetchCount(FetchDescriptor<Occurrence>())

        #expect(before == after)
    }

    // MARK: - DST inside the window

    /// A daily 08:00 dose must read 08:00 on every single day of the window,
    /// including the two days either side of a DST transition.
    @Test("Every row in a window spanning DST reads 8:00 local")
    func windowAcrossDST() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let cal = calendar()

        addDailyItem(start: date(2026, 10, 1), context: context)
        try context.save()

        // US DST ends 1 November 2026; this window straddles it.
        try OccurrenceMaterializer.materializeWindow(
            around: date(2026, 10, 25), context: context, calendar: cal
        )

        let occurrences = try context.fetch(FetchDescriptor<Occurrence>())
        #expect(occurrences.count == 31)
        for occurrence in occurrences {
            #expect(cal.component(.hour, from: occurrence.scheduledAt) == 8)
        }
    }

    // MARK: - Engine

    @Test("Maintenance sweeps, prunes, and refills in one pass")
    func maintenanceRuns() async throws {
        let container = try PersistenceStore.inMemory()
        let cal = calendar()
        let now = date(2026, 7, 15, 10)

        let context = container.mainContext
        let item = addDailyItem(start: date(2026, 1, 1), context: context)
        // One straggler from yesterday, one row far outside the window.
        context.insert(Occurrence(item: item, scheduledAt: date(2026, 7, 14, 8)))
        context.insert(Occurrence(item: item, scheduledAt: date(2026, 1, 5, 8)))
        try context.save()

        let engine = ScheduleEngine(modelContainer: container)
        let result = try await engine.runMaintenance(now: now, calendar: cal)

        #expect(result.swept == 2)
        #expect(result.pruned == 1)
        #expect(result.created > 0)
        #expect(result.didChangeAnything)
    }

    @Test("Maintenance run twice changes nothing the second time")
    func maintenanceIsIdempotent() async throws {
        let container = try PersistenceStore.inMemory()
        let cal = calendar()
        let now = date(2026, 7, 15, 10)

        addDailyItem(start: date(2026, 1, 1), context: container.mainContext)
        try container.mainContext.save()

        let engine = ScheduleEngine(modelContainer: container)
        _ = try await engine.runMaintenance(now: now, calendar: cal)
        let second = try await engine.runMaintenance(now: now, calendar: cal)

        #expect(second == ScheduleEngine.Result())
        #expect(!second.didChangeAnything)
    }

    @Test("Reconciling one schedule leaves other schedules untouched")
    func engineReconcileIsScoped() async throws {
        let container = try PersistenceStore.inMemory()
        let cal = calendar()
        let now = date(2026, 7, 15, 10)
        let context = container.mainContext

        let mine = addDailyItem(named: "Mine", start: date(2026, 7, 1), context: context)
        addDailyItem(named: "Theirs", start: date(2026, 7, 1), context: context)
        try context.save()

        let engine = ScheduleEngine(modelContainer: container)
        _ = try await engine.runMaintenance(now: now, calendar: cal)

        let scheduleID = try #require(mine.schedules?.first?.id)
        _ = try await engine.reconcile(scheduleID: scheduleID, now: now, calendar: cal)

        // Both items still have a full window's worth of rows.
        let all = try context.fetch(FetchDescriptor<Occurrence>())
        let byItem = Dictionary(grouping: all) { $0.item?.name ?? "?" }
        #expect(byItem["Mine"]?.count == byItem["Theirs"]?.count)
    }
}
