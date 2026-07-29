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
        for (item, schedule) in sampleItems() {
            context.insert(item)
            schedule.item = item
            context.insert(schedule)

            for occurrence in occurrences(for: item, schedule: schedule) {
                occurrence.item = item
                context.insert(occurrence)
            }
        }
        try? context.save()
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
