import Foundation

/// An immutable snapshot of an occurrence, sufficient to schedule a
/// notification for it.
///
/// SwiftData models are not `Sendable` — they belong to the context that
/// created them and must not cross an actor boundary. Rather than fight that,
/// `ScheduleEngine` reads what's needed inside its own isolation and hands out
/// these plain values.
///
/// The result is that `NotificationScheduler` and `NotificationBudget` have no
/// dependency on the persistence layer at all, which is what makes the budget
/// rule testable without standing up a store.
public struct Reminder: Sendable, Equatable, Identifiable {
    /// The occurrence this came from. Doubles as the notification request's
    /// identifier, so a response maps straight back.
    public let id: UUID

    /// When it should fire — the occurrence's effective time, snooze included.
    public let fireDate: Date

    /// The item's name.
    public let title: String

    /// Dosage and instruction, already joined for display.
    public let body: String

    public init(id: UUID, fireDate: Date, title: String, body: String) {
        self.id = id
        self.fireDate = fireDate
        self.title = title
        self.body = body
    }
}

public extension Reminder {
    /// Builds a snapshot from an occurrence. Returns nil for rows that must
    /// never ring: no item, or already resolved.
    ///
    /// Call only from the context that owns `occurrence`.
    init?(occurrence: Occurrence) {
        guard let item = occurrence.item, !occurrence.isResolved else { return nil }

        self.init(
            id: occurrence.id,
            fireDate: occurrence.effectiveTime,
            title: item.name,
            body: [item.detail, item.note]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        )
    }
}
