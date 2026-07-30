import Foundation
import SwiftData

/// Sample data for previews, the widget gallery, and Phase 1/2 development.
///
/// Mirrors the manifesto's dashboard sketch — a mixed day of medications and
/// ordinary life, because the timeline is the point, not the pills.
public enum MockData {

    @MainActor
    public static func populatedContainer() -> ModelContainer {
        let container: ModelContainer
        do {
            container = try PersistenceStore.inMemory()
        } catch {
            fatalError("Could not create preview container: \(error)")
        }
        populate(context: container.mainContext)
        return container
    }

    @MainActor
    public static func populate(context: ModelContext) {
        var allOccurrences: [Occurrence] = []

        for (item, schedule) in sampleItems() {
            context.insert(item)
            schedule.item = item
            context.insert(schedule)

            for occurrence in occurrences(for: item, schedule: schedule) {
                occurrence.item = item
                context.insert(occurrence)
                allOccurrences.append(occurrence)
            }
        }

        guaranteeAPendingOccurrence(among: allOccurrences)
        seedPastHistory(context: context)
        try? context.save()
    }

    /// Seeds a week of settled history for the medication items.
    ///
    /// Without it the adherence view has nothing to show — and just after
    /// midnight, when every one of today's rows is still in the future, neither
    /// does anything else. Real history also makes the 30-day grid legible
    /// instead of one lone dot.
    ///
    /// Mostly taken with a couple of lapses, because a fixture that is 100%
    /// perfect never exercises the partial or missed states.
    @MainActor
    private static func seedPastHistory(context: ModelContext) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        let items = (try? context.fetch(
            FetchDescriptor<TrackedItem>(
                predicate: #Predicate { !$0.isArchived }
            )
        )) ?? []

        for item in items where item.template == .medication {
            guard let schedule = item.schedules?.first else { continue }

            for daysAgo in 1...7 {
                guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) else {
                    continue
                }

                for minutes in schedule.timesOfDay {
                    let parts = TimeOfDay.components(from: minutes)
                    guard let scheduledAt = calendar.date(
                        bySettingHour: parts.hour, minute: parts.minute, second: 0, of: day
                    ) else { continue }

                    // Two deliberate lapses in the week, so the grid shows more
                    // than a wall of green.
                    let state: OccurrenceState = (daysAgo == 3 || daysAgo == 6)
                        ? .missed
                        : .taken

                    let occurrence = Occurrence(
                        item: item,
                        scheduledAt: scheduledAt,
                        state: state,
                        generatedFromScheduleID: schedule.id
                    )
                    if state == .taken {
                        occurrence.resolvedAt = scheduledAt.addingTimeInterval(300)
                    }
                    context.insert(occurrence)
                }
            }
        }
    }

    /// Ensures at least one row is still pending, whatever time it is.
    ///
    /// Fixtures are seeded relative to `now` and anything past is marked taken,
    /// so after the last scheduled time of day — 7pm — every row was resolved
    /// and any test needing something to complete failed. It broke twice, in
    /// two different tests, before being fixed here rather than in each test.
    @MainActor
    private static func guaranteeAPendingOccurrence(among occurrences: [Occurrence]) {
        guard !occurrences.isEmpty else { return }
        guard occurrences.allSatisfy(\.isResolved) else { return }

        // Reopen the latest row and push it an hour out, so it is genuinely
        // pending rather than merely relabelled.
        guard let latest = occurrences.max(by: { $0.scheduledAt < $1.scheduledAt }) else { return }
        latest.state = .pending
        latest.resolvedAt = nil
        latest.scheduledAt = Date.now.addingTimeInterval(3600)
    }

    // MARK: - Fixtures

    /// Built by appending rather than as one array literal: a literal of this
    /// many tuples pushes the type checker into exponential inference and shows
    /// up as "unable to type-check in reasonable time" in the editor long
    /// before it fails an actual build.
    public static func sampleItems() -> [(TrackedItem, Schedule)] {
        var items: [(TrackedItem, Schedule)] = []

        func add(
            _ name: String,
            _ template: TemplateKind,
            detail: String,
            note: String = "",
            color: ColorToken,
            rule: RecurrenceRule = .everyDay,
            at times: [Int]
        ) {
            let item = TrackedItem(
                name: name,
                template: template,
                detail: detail,
                note: note,
                color: color
            )
            items.append((item, Schedule(rule: rule, timesOfDay: times)))
        }

        // Early items so development builds always show resolved rows and the
        // "now" indicator, whatever time of day it happens to be.
        add("Morning Stretch", .exercise, detail: "10 minutes", color: .apricot,
            at: [TimeOfDay.minutes(hour: 6, minute: 30)])

        add("Thyroid", .medication, detail: "1 Tablet", note: "On an empty stomach",
            color: .lavender, at: [TimeOfDay.minutes(hour: 7)])

        add("Vitamin D", .medication, detail: "1 Tablet", note: "Take with breakfast",
            color: .apricot, at: [TimeOfDay.minutes(hour: 8)])

        add("Blood Pressure", .medication, detail: "1 Capsule", note: "With water",
            color: .ocean,
            at: [TimeOfDay.minutes(hour: 8), TimeOfDay.minutes(hour: 19)])

        add("Walk the Dog", .petCare, detail: "30 minutes", color: .lavender,
            at: [TimeOfDay.minutes(hour: 9, minute: 30)])

        add("Water Plants", .plants, detail: "Living room + balcony", color: .sage,
            rule: .weekly(interval: 1, weekdays: [2, 5]),
            at: [TimeOfDay.minutes(hour: 14)])

        add("Evening Pills", .medication, detail: "2 Tablets", note: "After dinner",
            color: .stone, at: [TimeOfDay.minutes(hour: 19)])

        return items
    }

    /// Builds today's occurrences at each of the schedule's times, marking those
    /// already past as taken so the timeline shows resolved rows, pending rows,
    /// and the "now" indicator between them — without needing the scheduling
    /// engine (Phase 4).
    static func occurrences(for item: TrackedItem, schedule: Schedule) -> [Occurrence] {
        let calendar = Calendar.current
        let now = Date.now

        return schedule.timesOfDay.compactMap { minutes -> Occurrence? in
            let parts = TimeOfDay.components(from: minutes)
            guard let date = calendar.date(
                bySettingHour: parts.hour,
                minute: parts.minute,
                second: 0,
                of: now
            ) else { return nil }

            let occurrence = Occurrence(
                scheduledAt: date,
                state: date < now ? .taken : .pending,
                generatedFromScheduleID: schedule.id
            )
            if occurrence.state == .taken {
                occurrence.resolvedAt = date.addingTimeInterval(120)
            }
            return occurrence
        }
    }
}
