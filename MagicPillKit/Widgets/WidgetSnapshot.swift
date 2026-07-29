import Foundation
import SwiftData

/// Everything a widget needs to render, as plain values.
///
/// The widget process cannot hold SwiftData models across a timeline entry —
/// entries are archived and replayed by WidgetKit long after the context that
/// produced them is gone. So the store is read once, flattened to this, and
/// nothing model-shaped escapes.
public struct WidgetSnapshot: Sendable, Equatable {
    /// When this was read. Lets a stale widget say so rather than lie.
    public let generatedAt: Date

    /// The soonest unresolved reminders, earliest first.
    public let upcoming: [Reminder]

    public let completedToday: Int
    public let totalToday: Int

    public init(
        generatedAt: Date,
        upcoming: [Reminder],
        completedToday: Int,
        totalToday: Int
    ) {
        self.generatedAt = generatedAt
        self.upcoming = upcoming
        self.completedToday = completedToday
        self.totalToday = totalToday
    }

    public var next: Reminder? { upcoming.first }

    public var remainingToday: Int { max(totalToday - completedToday, 0) }

    /// 0…1. A day with nothing scheduled reads as complete rather than as a
    /// zeroed-out ring, which would look like failure.
    public var progress: Double {
        guard totalToday > 0 else { return 1 }
        return Double(completedToday) / Double(totalToday)
    }

    public var isDayComplete: Bool { remainingToday == 0 }

    /// Shown in the widget gallery and while the real store is loading.
    public static func placeholder(now: Date = .now) -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: now,
            upcoming: [
                Reminder(
                    id: UUID(),
                    fireDate: now.addingTimeInterval(1800),
                    title: "Vitamin D",
                    body: "1 Tablet"
                ),
                Reminder(
                    id: UUID(),
                    fireDate: now.addingTimeInterval(7200),
                    title: "Walk the Dog",
                    body: "30 minutes"
                ),
                Reminder(
                    id: UUID(),
                    fireDate: now.addingTimeInterval(14_400),
                    title: "Evening Pills",
                    body: "2 Tablets"
                ),
            ],
            completedToday: 2,
            totalToday: 5
        )
    }

    /// The honest empty state: reachable, and rendered as calm rather than
    /// broken.
    public static func empty(now: Date = .now) -> WidgetSnapshot {
        WidgetSnapshot(generatedAt: now, upcoming: [], completedToday: 0, totalToday: 0)
    }
}

/// Reads a `WidgetSnapshot` out of the store.
public enum WidgetSnapshotLoader {

    /// How many upcoming reminders to carry. Enough for the largest widget
    /// family plus a few timeline entries beyond it.
    public static let upcomingLimit = 8

    public static func load(
        context: ModelContext,
        now: Date = .now,
        calendar: Calendar = .current,
        limit: Int = upcomingLimit
    ) throws -> WidgetSnapshot {
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        let today = try context.fetch(
            FetchDescriptor<Occurrence>(
                predicate: #Predicate { $0.scheduledAt >= dayStart && $0.scheduledAt < dayEnd }
            )
        )

        // Upcoming is deliberately *not* limited to today. At 11pm the useful
        // answer is tomorrow morning's dose, not an empty widget.
        let pending = OccurrenceState.pending.rawValue
        var descriptor = FetchDescriptor<Occurrence>(
            predicate: #Predicate<Occurrence> { occurrence in
                occurrence.stateRaw == pending && occurrence.scheduledAt > now
            },
            sortBy: [SortDescriptor(\.scheduledAt, order: .forward)]
        )
        descriptor.fetchLimit = limit * 2

        let upcoming = try context.fetch(descriptor)
            .compactMap(Reminder.init(occurrence:))
            .sorted { $0.fireDate < $1.fireDate }
            .prefix(limit)

        return WidgetSnapshot(
            generatedAt: now,
            upcoming: Array(upcoming),
            completedToday: today.filter(\.isResolved).count,
            totalToday: today.count
        )
    }
}
