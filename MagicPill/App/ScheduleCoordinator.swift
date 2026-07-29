import Foundation
import SwiftData
import SwiftUI
import BackgroundTasks
import WidgetKit
import MagicPillKit

/// Decides *when* the schedule engine runs. The engine decides what it does.
///
/// Three triggers, each covering a gap the others leave:
///
/// - **Foreground** — the reliable one. Covers the overwhelmingly common case
///   of someone opening the app.
/// - **Background refresh** — opportunistic. iOS grants it at its own
///   discretion and may never grant it at all, so nothing may *depend* on it;
///   it only keeps the window warm for a user who hasn't opened the app in
///   days.
/// - **Time-zone change** — mandatory. Without it, every future occurrence
///   stays pinned to the wall-clock of the zone the user left.
@MainActor
@Observable
final class ScheduleCoordinator {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    /// `nonisolated` so the background-refresh handler, which runs off the main
    /// actor, can name the task it is handling.
    nonisolated static let refreshTaskIdentifier = "com.rahulkassel.MagicPill.refresh"

    private let engine: ScheduleEngine
    private let notifications: NotificationScheduler

    /// Written once during `init` on the main actor and read only in `deinit`,
    /// which Swift 6 runs without isolation. There is no window in which both
    /// can touch it, so the unchecked access is safe — and removing the
    /// observer matters more than the annotation costs.
    nonisolated(unsafe) private var timeZoneObserver: NSObjectProtocol?

    /// Last maintenance result, for the debug surface in Settings.
    private(set) var lastResult: ScheduleEngine.Result?
    private(set) var lastError: String?

    /// Diagnostics for the notification budget, which is invisible until it's
    /// exceeded.
    private(set) var pendingNotificationCount: Int = 0
    private(set) var notificationsAuthorized = false

    init(
        engine: ScheduleEngine,
        notifications: NotificationScheduler
    ) {
        self.engine = engine
        self.notifications = notifications
        observeTimeZoneChanges()
    }

    deinit {
        if let timeZoneObserver {
            NotificationCenter.default.removeObserver(timeZoneObserver)
        }
    }

    /// Run on launch and whenever the app comes back to the foreground.
    func runMaintenance() async {
        do {
            lastResult = try await engine.runMaintenance()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            print("[MagicPill] Maintenance failed: \(error)")
        }
        await syncNotifications()
    }

    /// Regenerate future rows after a schedule edit, then re-sync reminders.
    func reconcile(scheduleID: UUID) async {
        do {
            try await engine.reconcile(scheduleID: scheduleID)
        } catch {
            print("[MagicPill] Reconcile failed: \(error)")
        }
        await syncNotifications()
    }

    // MARK: - Notifications

    /// Brings pending notifications in line with the store.
    ///
    /// Cheap and idempotent, so it runs after anything that could change what
    /// should ring: maintenance, an edit, a resolved dose.
    func syncNotifications() async {
        await notifications.registerCategories()

        // Widgets refresh regardless of notification permission — the home
        // screen still has to be right for someone who declined reminders.
        defer { reloadWidgets() }

        guard await notifications.authorizationStatus() == .authorized else {
            notificationsAuthorized = false
            return
        }
        notificationsAuthorized = true

        do {
            let reminders = try await engine.reminders()
            let report = await notifications.sync(reminders: reminders)
            pendingNotificationCount = report.pending

            // The budget exists precisely so this cannot happen; if it ever
            // does, iOS is silently dropping reminders and the user gets no
            // indication at all.
            assert(
                report.pending <= NotificationBudget.systemLimit,
                "Pending notifications (\(report.pending)) exceeded the system limit"
            )
        } catch {
            print("[MagicPill] Notification sync failed: \(error)")
        }
    }

    /// Asks for notification permission, then syncs.
    ///
    /// Called after the user saves their first item — never on a cold first
    /// launch. A prompt before the app has done anything gets denied, and iOS
    /// does not ask a second time.
    func requestNotificationPermissionIfNeeded() async {
        let status = await notifications.authorizationStatus()
        guard status == .notDetermined else {
            await syncNotifications()
            return
        }
        await notifications.requestAuthorization()
        await syncNotifications()
    }

    /// Cancels a reminder the moment its dose is resolved in the app, so it
    /// can't ring afterwards.
    func cancelNotification(for occurrenceID: UUID) async {
        await notifications.cancel(occurrenceID: occurrenceID)
        reloadWidgets()
    }

    /// Pushes fresh data to the widgets.
    ///
    /// WidgetKit will not notice a store write on its own — without this the
    /// home screen keeps showing a dose the user took an hour ago, which is
    /// worse than showing nothing.
    nonisolated func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Time zone

    private func observeTimeZoneChanges() {
        timeZoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The notification can arrive before `Calendar.current` reflects
            // the new zone, so the work is hopped to the next turn of the run
            // loop rather than done inline.
            Task { @MainActor [weak self] in
                await self?.handleTimeZoneChange()
            }
        }
    }

    private func handleTimeZoneChange() async {
        do {
            let created = try await engine.handleTimeZoneChange()
            print("[MagicPill] Time zone changed; regenerated \(created) occurrences")
        } catch {
            print("[MagicPill] Time-zone rematerialisation failed: \(error)")
        }
    }

    // MARK: - Background refresh

    /// Runs a maintenance pass from the background-refresh handler.
    ///
    /// Static, and building its own engine from the container, because
    /// `.backgroundTask` executes outside the main actor and so cannot touch
    /// the `@State`-held coordinator. `ModelContainer` is `Sendable`; the
    /// engine is an actor. Nothing main-isolated is involved.
    static func runBackgroundMaintenance(container: ModelContainer) async {
        let engine = ScheduleEngine(modelContainer: container)
        let notifications = NotificationScheduler()
        do {
            let result = try await engine.runMaintenance()
            print("[MagicPill] Background maintenance: \(result)")

            // The whole point of the background pass: top the notification
            // queue back up for someone who hasn't opened the app in days and
            // whose scheduled reminders have been draining away.
            let reminders = try await engine.reminders()
            let report = await notifications.sync(reminders: reminders)
            print("[MagicPill] Background notification sync: \(report)")
        } catch {
            print("[MagicPill] Background maintenance failed: \(error)")
        }
    }

    /// Ask iOS for another refresh window. Called after each background run —
    /// a `BGAppRefreshTaskRequest` is one-shot, so not re-submitting means it
    /// never fires again.
    nonisolated static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        // Roughly daily. The system treats this as the earliest acceptable
        // time, not a promise, and will drift it based on usage patterns.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[MagicPill] Could not schedule background refresh: \(error)")
        }
    }
}
