import Foundation

/// Decides which occurrences get a scheduled notification.
///
/// **iOS allows 64 pending local notifications per app.** Requests past the
/// limit are silently dropped — no error, no callback, the reminder simply
/// never arrives. Three medications twice daily is six a day, so a naive
/// "schedule everything in the window" approach runs out in about ten days and
/// then quietly stops reminding the person it exists to remind.
///
/// This type is pure so the rule can be tested. The scheduler around it does
/// the `UNUserNotificationCenter` I/O.
public enum NotificationBudget {

    /// The hard system limit.
    public static let systemLimit = 64

    /// What this app will actually schedule ahead.
    ///
    /// The gap below `systemLimit` is deliberate headroom: every snooze creates
    /// an additional one-shot request, and a user who snoozes five reminders in
    /// a morning must not push the sixth off the end of the queue.
    public static let scheduledLimit = 56

    /// The soonest `limit` reminders, earliest first.
    ///
    /// Reminders whose time has already passed are dropped: a notification
    /// scheduled for the past never fires, and would burn a slot from a budget
    /// that exists precisely because slots are scarce.
    ///
    /// (Resolved occurrences never become `Reminder`s in the first place — see
    /// `Reminder.init?(occurrence:)`.)
    public static func select(
        from reminders: [Reminder],
        now: Date = .now,
        limit: Int = scheduledLimit
    ) -> [Reminder] {
        guard limit > 0 else { return [] }

        return reminders
            .filter { $0.fireDate > now }
            .sorted { $0.fireDate < $1.fireDate }
            .prefix(limit)
            .map { $0 }
    }
}

/// How long a snooze lasts.
///
/// Defined once so the timeline's swipe, the notification action, and any
/// future settings screen cannot drift apart.
public enum SnoozeDefaults {
    public static let interval: TimeInterval = 15 * 60

    public static func nextTime(from now: Date = .now) -> Date {
        now.addingTimeInterval(interval)
    }
}
