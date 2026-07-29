import Testing
import Foundation
import SwiftData
@testable import MagicPillKit

/// Tests for recurrence evaluation and day materialisation.
///
/// A fixed calendar and time zone are used throughout: a scheduling test that
/// depends on where the machine running it happens to be is not a test.
@Suite("Scheduling")
struct SchedulingTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour
        ))!
    }

    // MARK: - Daily

    @Test("Daily fires every day from the start date")
    func dailyEveryDay() {
        let rule = RecurrenceRule.everyDay
        let start = date(2026, 7, 1)

        #expect(rule.occurs(on: date(2026, 7, 1), startDate: start, calendar: calendar))
        #expect(rule.occurs(on: date(2026, 7, 2), startDate: start, calendar: calendar))
        #expect(rule.occurs(on: date(2026, 12, 25), startDate: start, calendar: calendar))
    }

    @Test("Nothing fires before the start date")
    func nothingBeforeStart() {
        let start = date(2026, 7, 10)
        #expect(!RecurrenceRule.everyDay.occurs(
            on: date(2026, 7, 9), startDate: start, calendar: calendar
        ))
    }

    @Test("Nothing fires after the end date")
    func nothingAfterEnd() {
        let start = date(2026, 7, 1)
        let end = date(2026, 7, 5)
        let rule = RecurrenceRule.everyDay

        #expect(rule.occurs(on: date(2026, 7, 5), startDate: start, endDate: end, calendar: calendar))
        #expect(!rule.occurs(on: date(2026, 7, 6), startDate: start, endDate: end, calendar: calendar))
    }

    @Test("Every-N-days counts from the start date")
    func everyThreeDays() {
        let rule = RecurrenceRule.daily(interval: 3)
        let start = date(2026, 7, 1)

        #expect(rule.occurs(on: date(2026, 7, 1), startDate: start, calendar: calendar))
        #expect(!rule.occurs(on: date(2026, 7, 2), startDate: start, calendar: calendar))
        #expect(!rule.occurs(on: date(2026, 7, 3), startDate: start, calendar: calendar))
        #expect(rule.occurs(on: date(2026, 7, 4), startDate: start, calendar: calendar))
    }

    @Test("A zero or negative interval never fires rather than dividing by zero")
    func degenerateInterval() {
        let start = date(2026, 7, 1)
        #expect(!RecurrenceRule.daily(interval: 0).occurs(
            on: date(2026, 7, 1), startDate: start, calendar: calendar
        ))
        #expect(!RecurrenceRule.weekly(interval: 0, weekdays: [4]).occurs(
            on: date(2026, 7, 1), startDate: start, calendar: calendar
        ))
    }

    // MARK: - DST

    /// The reason all the arithmetic goes through `Calendar`. US DST ends on
    /// 1 November 2026; a rule built by adding 86,400 seconds drifts an hour
    /// here and eventually fires on the wrong day entirely.
    @Test("Daily rules stay aligned across a DST boundary")
    func dailyAcrossDST() {
        let rule = RecurrenceRule.everyDay
        let start = date(2026, 10, 30)

        for day in 30...31 {
            #expect(rule.occurs(on: date(2026, 10, day), startDate: start, calendar: calendar))
        }
        for day in 1...3 {
            #expect(rule.occurs(on: date(2026, 11, day), startDate: start, calendar: calendar))
        }
    }

    @Test("Every-other-day stays in phase across a DST boundary")
    func alternatingAcrossDST() {
        let rule = RecurrenceRule.daily(interval: 2)
        let start = date(2026, 10, 30)

        #expect(rule.occurs(on: date(2026, 10, 30), startDate: start, calendar: calendar))
        #expect(!rule.occurs(on: date(2026, 10, 31), startDate: start, calendar: calendar))
        #expect(rule.occurs(on: date(2026, 11, 1), startDate: start, calendar: calendar))
        #expect(!rule.occurs(on: date(2026, 11, 2), startDate: start, calendar: calendar))
        #expect(rule.occurs(on: date(2026, 11, 3), startDate: start, calendar: calendar))
    }

    // MARK: - Weekly

    @Test("Weekly fires only on its chosen weekdays")
    func weeklyWeekdays() {
        // 2026-07-01 is a Wednesday (weekday 4).
        let rule = RecurrenceRule.weekly(interval: 1, weekdays: [4])
        let start = date(2026, 7, 1)

        #expect(rule.occurs(on: date(2026, 7, 1), startDate: start, calendar: calendar))
        #expect(!rule.occurs(on: date(2026, 7, 2), startDate: start, calendar: calendar))
        #expect(rule.occurs(on: date(2026, 7, 8), startDate: start, calendar: calendar))
    }

    @Test("Every-other-week skips the intervening week")
    func biweekly() {
        let rule = RecurrenceRule.weekly(interval: 2, weekdays: [4])
        let start = date(2026, 7, 1)

        #expect(rule.occurs(on: date(2026, 7, 1), startDate: start, calendar: calendar))
        #expect(!rule.occurs(on: date(2026, 7, 8), startDate: start, calendar: calendar))
        #expect(rule.occurs(on: date(2026, 7, 15), startDate: start, calendar: calendar))
    }

    // MARK: - Monthly

    @Test("Monthly fires on its chosen dates")
    func monthlyDates() {
        let rule = RecurrenceRule.monthly(days: [1, 15])
        let start = date(2026, 1, 1)

        #expect(rule.occurs(on: date(2026, 7, 1), startDate: start, calendar: calendar))
        #expect(rule.occurs(on: date(2026, 7, 15), startDate: start, calendar: calendar))
        #expect(!rule.occurs(on: date(2026, 7, 16), startDate: start, calendar: calendar))
    }

    /// "The 31st" means the 31st. Silently moving a dose to the 28th is a
    /// clinical decision the app has no business making on its own.
    @Test("Monthly on the 31st skips short months rather than clamping")
    func monthlySkipsShortMonths() {
        let rule = RecurrenceRule.monthly(days: [31])
        let start = date(2026, 1, 1)

        #expect(rule.occurs(on: date(2026, 7, 31), startDate: start, calendar: calendar))
        #expect(!rule.occurs(on: date(2026, 6, 30), startDate: start, calendar: calendar))
        #expect(!rule.occurs(on: date(2026, 2, 28), startDate: start, calendar: calendar))
    }

    @Test("As-needed never fires")
    func asNeededNeverFires() {
        #expect(!RecurrenceRule.asNeeded.occurs(
            on: date(2026, 7, 1), startDate: date(2026, 7, 1), calendar: calendar
        ))
    }

    // MARK: - Materialisation

    /// Returns the container alongside the context. Returning only the context
    /// lets the container deallocate immediately, and the orphaned context then
    /// crashes the test process rather than failing an assertion.
    @MainActor
    private func makeStore() throws -> (ModelContainer, ModelContext) {
        let container = try PersistenceStore.inMemory()
        return (container, container.mainContext)
    }

    @Test("Materialising creates one occurrence per scheduled time")
    @MainActor
    func materializeCreatesRows() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let item = TrackedItem(name: "Vitamin D")
        context.insert(item)

        let schedule = Schedule(
            rule: .everyDay,
            timesOfDay: [TimeOfDay.minutes(hour: 8), TimeOfDay.minutes(hour: 20)],
            startDate: date(2026, 7, 1)
        )
        schedule.item = item
        context.insert(schedule)
        try context.save()

        let created = try OccurrenceMaterializer.materialize(
            day: date(2026, 7, 10), context: context, calendar: calendar
        )
        #expect(created == 2)
    }

    /// The property that matters most. The rolling-window engine in Phase 4
    /// will run this repeatedly over overlapping ranges; if it isn't idempotent
    /// the user sees their morning dose twice.
    @Test("Materialising twice creates nothing the second time")
    @MainActor
    func materializeIsIdempotent() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let item = TrackedItem(name: "Vitamin D")
        context.insert(item)

        let schedule = Schedule(
            rule: .everyDay,
            timesOfDay: [TimeOfDay.minutes(hour: 8)],
            startDate: date(2026, 7, 1)
        )
        schedule.item = item
        context.insert(schedule)
        try context.save()

        let day = date(2026, 7, 10)
        let first = try OccurrenceMaterializer.materialize(day: day, context: context, calendar: calendar)
        let second = try OccurrenceMaterializer.materialize(day: day, context: context, calendar: calendar)
        let third = try OccurrenceMaterializer.materialize(day: day, context: context, calendar: calendar)

        #expect(first == 1)
        #expect(second == 0)
        #expect(third == 0)
        #expect(try context.fetchCount(FetchDescriptor<Occurrence>()) == 1)
    }

    @Test("Archived items generate nothing")
    @MainActor
    func archivedItemsSkipped() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let item = TrackedItem(name: "Old Prescription")
        item.isArchived = true
        context.insert(item)

        let schedule = Schedule(timesOfDay: [TimeOfDay.minutes(hour: 8)], startDate: date(2026, 7, 1))
        schedule.item = item
        context.insert(schedule)
        try context.save()

        let created = try OccurrenceMaterializer.materialize(
            day: date(2026, 7, 10), context: context, calendar: calendar
        )
        #expect(created == 0)
    }

    @Test("Paused schedules generate nothing")
    @MainActor
    func pausedSchedulesSkipped() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let item = TrackedItem(name: "Vitamin D")
        context.insert(item)

        let schedule = Schedule(
            timesOfDay: [TimeOfDay.minutes(hour: 8)],
            startDate: date(2026, 7, 1),
            isPaused: true
        )
        schedule.item = item
        context.insert(schedule)
        try context.save()

        let created = try OccurrenceMaterializer.materialize(
            day: date(2026, 7, 10), context: context, calendar: calendar
        )
        #expect(created == 0)
    }

    /// Reconciliation must never rewrite history. Changing a schedule's time
    /// cannot retroactively alter the record of doses already taken.
    @Test("Reconciliation removes future pending rows but never resolved history")
    @MainActor
    func reconciliationPreservesHistory() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let item = TrackedItem(name: "Vitamin D")
        context.insert(item)
        let scheduleID = UUID()
        let now = date(2026, 7, 10, 12)

        let past = Occurrence(
            item: item,
            scheduledAt: date(2026, 7, 9, 8),
            state: .taken,
            generatedFromScheduleID: scheduleID
        )
        let futureResolved = Occurrence(
            item: item,
            scheduledAt: date(2026, 7, 11, 8),
            state: .skipped,
            generatedFromScheduleID: scheduleID
        )
        let futurePending = Occurrence(
            item: item,
            scheduledAt: date(2026, 7, 12, 8),
            state: .pending,
            generatedFromScheduleID: scheduleID
        )
        for occurrence in [past, futureResolved, futurePending] {
            context.insert(occurrence)
        }
        try context.save()

        try OccurrenceMaterializer.removeFuturePending(
            scheduleID: scheduleID, after: now, context: context
        )

        let remaining = try context.fetch(FetchDescriptor<Occurrence>())
        let states = Set(remaining.map(\.state))
        #expect(remaining.count == 2)
        #expect(states == [.taken, .skipped])
    }

    @Test("Reconciliation leaves other schedules alone")
    @MainActor
    func reconciliationIsScoped() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let item = TrackedItem(name: "Vitamin D")
        context.insert(item)

        let mine = UUID()
        let theirs = UUID()
        let now = date(2026, 7, 10, 12)

        context.insert(Occurrence(
            item: item, scheduledAt: date(2026, 7, 12, 8), generatedFromScheduleID: mine
        ))
        context.insert(Occurrence(
            item: item, scheduledAt: date(2026, 7, 12, 9), generatedFromScheduleID: theirs
        ))
        try context.save()

        try OccurrenceMaterializer.removeFuturePending(
            scheduleID: mine, after: now, context: context
        )

        let remaining = try context.fetch(FetchDescriptor<Occurrence>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.generatedFromScheduleID == theirs)
    }
}
