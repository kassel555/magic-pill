import Testing
import Foundation
import SwiftData
@testable import MagicPillKit

/// Adherence maths.
///
/// Tested carefully because the numbers here are the ones a user might repeat
/// to a doctor. Wrong-but-plausible is the worst outcome — it looks like
/// information and isn't.
@Suite("Adherence")
@MainActor
struct AdherenceTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 8) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func makeStore() throws -> (ModelContainer, ModelContext) {
        let container = try PersistenceStore.inMemory()
        return (container, container.mainContext)
    }

    private func makeItem(context: ModelContext) -> TrackedItem {
        let item = TrackedItem(name: "Vitamin D", detail: "1 Tablet")
        context.insert(item)
        return item
    }

    private func add(
        _ state: OccurrenceState,
        on when: Date,
        to item: TrackedItem,
        context: ModelContext
    ) {
        let occurrence = Occurrence(item: item, scheduledAt: when, state: state)
        context.insert(occurrence)
    }

    // MARK: - Window shape

    @Test("The window is exactly 30 days, oldest first, with no gaps")
    func windowShape() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let item = makeItem(context: context)
        let now = date(2026, 7, 30, 12)

        let summary = AdherenceCalculator.summary(for: item, now: now, calendar: calendar)

        #expect(summary.days.count == 30)
        #expect(summary.days.first?.date == date(2026, 7, 1, 0))
        #expect(summary.days.last?.date == date(2026, 7, 30, 0))
        #expect(summary.days.map(\.date) == summary.days.map(\.date).sorted())
    }

    /// Empty days must be present rather than omitted. A grid with holes in it
    /// would show a paused schedule as missing data.
    @Test("Days with nothing scheduled are present and marked unscheduled")
    func emptyDaysArePresent() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let item = makeItem(context: context)
        let now = date(2026, 7, 30, 12)

        add(.taken, on: date(2026, 7, 30), to: item, context: context)
        try context.save()

        let summary = AdherenceCalculator.summary(for: item, now: now, calendar: calendar)

        #expect(summary.days.count == 30)
        #expect(summary.days.first?.state == .unscheduled)
        #expect(summary.days.last?.state == .complete)
    }

    @Test("Occurrences outside the window are ignored")
    func windowExcludesOutside() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let item = makeItem(context: context)
        let now = date(2026, 7, 30, 12)

        add(.taken, on: date(2026, 5, 1), to: item, context: context)   // long past
        add(.taken, on: date(2026, 8, 15), to: item, context: context)  // future
        add(.taken, on: date(2026, 7, 20), to: item, context: context)  // inside
        try context.save()

        let summary = AdherenceCalculator.summary(for: item, now: now, calendar: calendar)
        #expect(summary.totalTaken == 1)
    }

    // MARK: - Rate

    /// The decision worth defending: an item with no settled doses reports nil,
    /// not 0%. Someone who has done nothing wrong should not be shown a zero.
    @Test("A brand-new item has no rate rather than a zero rate")
    func newItemHasNoRate() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let item = makeItem(context: context)
        let now = date(2026, 7, 30, 12)

        // Scheduled for later today, nothing settled.
        add(.pending, on: date(2026, 7, 30, 20), to: item, context: context)
        try context.save()

        let summary = AdherenceCalculator.summary(for: item, now: now, calendar: calendar)

        #expect(summary.rate == nil)
        #expect(!summary.hasHistory)
    }

    @Test("The rate is taken over settled doses")
    func rateOverResolved() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let item = makeItem(context: context)
        let now = date(2026, 7, 30, 12)

        add(.taken, on: date(2026, 7, 20), to: item, context: context)
        add(.taken, on: date(2026, 7, 21), to: item, context: context)
        add(.taken, on: date(2026, 7, 22), to: item, context: context)
        add(.missed, on: date(2026, 7, 23), to: item, context: context)
        try context.save()

        let summary = AdherenceCalculator.summary(for: item, now: now, calendar: calendar)
        #expect(summary.rate == 0.75)
    }

    /// Without this, the figure sags through every day and recovers each
    /// evening — which would make the number meaningless and mildly accusatory.
    @Test("Pending doses never count against the rate")
    func pendingDoesNotPenalise() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let item = makeItem(context: context)
        let now = date(2026, 7, 30, 12)

        add(.taken, on: date(2026, 7, 29), to: item, context: context)
        // Nine still to come today.
        for hour in 9...17 {
            add(.pending, on: date(2026, 7, 30, hour), to: item, context: context)
        }
        try context.save()

        let summary = AdherenceCalculator.summary(for: item, now: now, calendar: calendar)
        #expect(summary.rate == 1.0)
    }

    @Test("Skipped doses count as settled but not as taken")
    func skippedCountsAgainst() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let item = makeItem(context: context)
        let now = date(2026, 7, 30, 12)

        add(.taken, on: date(2026, 7, 28), to: item, context: context)
        add(.skipped, on: date(2026, 7, 29), to: item, context: context)
        try context.save()

        let summary = AdherenceCalculator.summary(for: item, now: now, calendar: calendar)
        #expect(summary.rate == 0.5)
        #expect(summary.totalSkipped == 1)
    }

    // MARK: - Day state

    @Test("A day is complete only when everything scheduled was taken")
    func dayStates() {
        #expect(DayAdherence(date: .now, taken: 2, skipped: 0, missed: 0, pending: 0).state == .complete)
        #expect(DayAdherence(date: .now, taken: 1, skipped: 0, missed: 1, pending: 0).state == .partial)
        #expect(DayAdherence(date: .now, taken: 0, skipped: 0, missed: 2, pending: 0).state == .missed)
        #expect(DayAdherence(date: .now, taken: 0, skipped: 2, missed: 0, pending: 0).state == .skipped)
        #expect(DayAdherence(date: .now, taken: 0, skipped: 0, missed: 0, pending: 2).state == .upcoming)
        #expect(DayAdherence(date: .now, taken: 0, skipped: 0, missed: 0, pending: 0).state == .unscheduled)
    }

    /// A day part-done is `partial`, not `upcoming` — progress already made
    /// should be visible rather than hidden until the day closes.
    @Test("A day with some doses taken and some still pending reads as partial")
    func partiallyDoneDay() {
        let day = DayAdherence(date: .now, taken: 1, skipped: 0, missed: 0, pending: 1)
        #expect(day.state == .partial)
    }

    // MARK: - Streak

    @Test("A streak counts consecutive complete days ending now")
    func streakCounts() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let item = makeItem(context: context)
        let now = date(2026, 7, 30, 23)

        for day in 26...30 {
            add(.taken, on: date(2026, 7, day), to: item, context: context)
        }
        add(.missed, on: date(2026, 7, 25), to: item, context: context)
        try context.save()

        let summary = AdherenceCalculator.summary(for: item, now: now, calendar: calendar)
        #expect(summary.currentStreak == 5)
    }

    /// A day with nothing scheduled is not a lapse; it simply isn't part of the
    /// streak. Breaking a streak on a rest day would punish the schedule the
    /// user chose.
    @Test("Unscheduled days don't break a streak")
    func unscheduledDaysDoNotBreakStreak() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let item = makeItem(context: context)
        let now = date(2026, 7, 30, 23)

        add(.taken, on: date(2026, 7, 30), to: item, context: context)
        // Nothing on the 29th at all.
        add(.taken, on: date(2026, 7, 28), to: item, context: context)
        try context.save()

        let summary = AdherenceCalculator.summary(for: item, now: now, calendar: calendar)
        #expect(summary.currentStreak == 2)
    }

    /// An unfinished day must not read as a broken streak — otherwise the count
    /// collapses every morning and rebuilds every night.
    @Test("Today still pending doesn't break yesterday's streak")
    func pendingTodayPreservesStreak() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let item = makeItem(context: context)
        let now = date(2026, 7, 30, 7)

        add(.taken, on: date(2026, 7, 28), to: item, context: context)
        add(.taken, on: date(2026, 7, 29), to: item, context: context)
        add(.pending, on: date(2026, 7, 30, 20), to: item, context: context)
        try context.save()

        let summary = AdherenceCalculator.summary(for: item, now: now, calendar: calendar)
        #expect(summary.currentStreak == 2)
    }

    @Test("A missed day ends the streak")
    func missedEndsStreak() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let item = makeItem(context: context)
        let now = date(2026, 7, 30, 23)

        add(.taken, on: date(2026, 7, 30), to: item, context: context)
        add(.missed, on: date(2026, 7, 29), to: item, context: context)
        add(.taken, on: date(2026, 7, 28), to: item, context: context)
        try context.save()

        let summary = AdherenceCalculator.summary(for: item, now: now, calendar: calendar)
        #expect(summary.currentStreak == 1)
    }

    @Test("One item's history never leaks into another's")
    func summaryIsScopedToItem() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let now = date(2026, 7, 30, 12)

        let mine = makeItem(context: context)
        let theirs = TrackedItem(name: "Thyroid")
        context.insert(theirs)

        add(.taken, on: date(2026, 7, 29), to: mine, context: context)
        for day in 20...28 {
            add(.missed, on: date(2026, 7, day), to: theirs, context: context)
        }
        try context.save()

        let summary = AdherenceCalculator.summary(for: mine, now: now, calendar: calendar)
        #expect(summary.totalTaken == 1)
        #expect(summary.totalMissed == 0)
        #expect(summary.rate == 1.0)
    }
}
