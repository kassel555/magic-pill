import Foundation
import UserNotifications

/// Identifiers shared between scheduling a notification and handling its
/// response. String literals in two places is how a Skip button ends up marking
/// something taken.
public enum NotificationIDs {
    public static let category = "magicpill.occurrence"

    public static let taken = "magicpill.action.taken"
    public static let snooze = "magicpill.action.snooze"
    public static let skip = "magicpill.action.skip"

    /// Request identifiers are the occurrence's UUID, so a response maps
    /// straight back to the row it belongs to.
    public static func requestID(for occurrenceID: UUID) -> String {
        occurrenceID.uuidString
    }

    public static func occurrenceID(fromRequestID id: String) -> UUID? {
        UUID(uuidString: id)
    }
}

/// Owns the app's pending local notifications.
///
/// Kept deliberately thin: it turns a list of occurrences into
/// `UNNotificationRequest`s and reconciles them against what's already pending.
/// The interesting decision — *which* occurrences — lives in
/// `NotificationBudget`, where it can be tested without a notification centre.
public actor NotificationScheduler {

    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    // MARK: - Authorization

    public func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Requests permission. Returns whether the app may now post notifications.
    ///
    /// Only ever call this at a moment the user would understand — after they
    /// create something worth being reminded about, never on a cold first
    /// launch. A denied prompt is close to permanent; iOS will not ask twice.
    @discardableResult
    public func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            print("[MagicPill] Notification authorization failed: \(error)")
            return false
        }
    }

    /// Registers the Taken / Snooze / Skip actions.
    ///
    /// Must run before any notification is scheduled — a request naming an
    /// unregistered category is delivered as a plain banner with no buttons.
    public func registerCategories() {
        let taken = UNNotificationAction(
            identifier: NotificationIDs.taken,
            title: "Taken",
            options: []
        )
        let snooze = UNNotificationAction(
            identifier: NotificationIDs.snooze,
            title: "Snooze 15 min",
            options: []
        )
        let skip = UNNotificationAction(
            identifier: NotificationIDs.skip,
            title: "Skip",
            options: []
        )

        let category = UNNotificationCategory(
            identifier: NotificationIDs.category,
            actions: [taken, snooze, skip],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    // MARK: - Syncing

    /// The outcome of a sync, returned so callers and tests can assert on it
    /// rather than read logs.
    public struct SyncReport: Sendable, Equatable {
        public var added: Int = 0
        public var removed: Int = 0
        public var pending: Int = 0
    }

    /// Brings pending notifications in line with `occurrences`.
    ///
    /// Diffs against what's already scheduled rather than clearing and
    /// re-adding everything. A blanket `removeAllPendingNotificationRequests`
    /// followed by re-adding leaves a window — brief, but real — in which a
    /// reminder due in the next moments has been cancelled and not yet
    /// recreated.
    @discardableResult
    public func sync(
        reminders: [Reminder],
        now: Date = .now,
        limit: Int = NotificationBudget.scheduledLimit
    ) async -> SyncReport {
        let wanted = NotificationBudget.select(from: reminders, now: now, limit: limit)
        let wantedByID = Dictionary(
            uniqueKeysWithValues: wanted.map { (NotificationIDs.requestID(for: $0.id), $0) }
        )

        let existing = await center.pendingNotificationRequests()
        let existingIDs = Set(existing.map(\.identifier))

        var report = SyncReport()

        // Drop anything no longer wanted: resolved, rescheduled, or pushed out
        // of the budget by something sooner.
        let stale = existingIDs.subtracting(wantedByID.keys)
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(stale))
            report.removed = stale.count
        }

        // Add what's missing. Times can change under a fixed identifier via
        // snooze, so anything already pending is re-added rather than assumed
        // correct.
        for (id, reminder) in wantedByID {
            if existingIDs.contains(id) {
                center.removePendingNotificationRequests(withIdentifiers: [id])
            }
            guard let request = makeRequest(for: reminder, now: now) else { continue }
            do {
                try await center.add(request)
                report.added += 1
            } catch {
                print("[MagicPill] Could not schedule \(id): \(error)")
            }
        }

        report.pending = await center.pendingNotificationRequests().count
        return report
    }

    /// Cancels the notification for a single occurrence — used the moment a
    /// dose is resolved in the app, so it can't ring afterwards.
    public func cancel(occurrenceID: UUID) {
        center.removePendingNotificationRequests(
            withIdentifiers: [NotificationIDs.requestID(for: occurrenceID)]
        )
    }

    /// Diagnostics for the debug surface. The budget is invisible until it's
    /// exceeded, so it needs to be inspectable before that happens.
    public func pendingCount() async -> Int {
        await center.pendingNotificationRequests().count
    }

    // MARK: - Content

    private func makeRequest(for reminder: Reminder, now: Date) -> UNNotificationRequest? {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        content.categoryIdentifier = NotificationIDs.category
        content.userInfo = ["occurrenceID": reminder.id.uuidString]

        let interval = reminder.fireDate.timeIntervalSince(now)
        guard interval > 0 else { return nil }

        return UNNotificationRequest(
            identifier: NotificationIDs.requestID(for: reminder.id),
            content: content,
            // Interval rather than calendar trigger: the occurrence's absolute
            // time is already resolved against the user's calendar by the
            // materializer, and a time-zone change regenerates it there. Two
            // layers resolving wall-clock time would be two places to disagree.
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        )
    }
}
