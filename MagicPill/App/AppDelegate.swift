import UIKit
import SwiftData
import UserNotifications
import MagicPillKit

/// The single owner of the app's container and long-lived services.
///
/// A `struct App`'s `init` can run more than once, and the notification
/// delegate has to exist before launch completes to catch a cold start from a
/// banner tap. Both need the same container, and building it twice would open
/// two stores over one file.
@MainActor
enum AppEnvironment {
    static let store: (container: ModelContainer, mode: PersistenceStore.Mode) = {
        // Wipe before opening, never after: deleting store files out from under
        // a live container corrupts it.
        if LaunchArguments.isUITesting {
            PersistenceStore.destroyLocalStore()

            // Preferences survive an app reinstall, so they need clearing too —
            // otherwise "first run" depends on whatever the last run left.
            if LaunchArguments.forcesOnboarding {
                UserDefaults.resetOnboarding()
            } else {
                UserDefaults.markOnboardingComplete()
            }
        }
        return PersistenceStore.production()
    }()
    static var container: ModelContainer { store.container }
    static var storeMode: PersistenceStore.Mode { store.mode }

    static let notifications = NotificationScheduler()
    static let engine = ScheduleEngine(modelContainer: store.container)

    static let syncMonitor = CloudSyncMonitor(
        isSyncEnabled: store.mode == .synced,
        unavailableReason: Self.syncUnavailableReason
    )

    /// Says *why* sync is off, in terms that point at a fix. "Not syncing" with
    /// no explanation is the kind of silence that makes people distrust an app
    /// holding their medical data.
    private static var syncUnavailableReason: String {
        switch store.mode {
        case .synced:
            ""
        case .local:
            "iCloud isn't set up for this build, so data stays on this device."
        case .memory:
            "Storage is temporary — changes won't be kept."
        }
    }
}

/// Handles notification responses.
///
/// Registered as the `UNUserNotificationCenter` delegate during
/// `didFinishLaunching` — set it any later and a launch caused by tapping a
/// notification arrives before anyone is listening, and the tap is lost.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {

    /// A banner while the app is open, but no sound.
    ///
    /// The timeline is already on screen showing the same information; ringing
    /// at someone who is looking at the app is the kind of nagging the design
    /// manifesto rejects.
    /// `nonisolated` because `UNNotification` and friends are not `Sendable`
    /// and so cannot cross into the main actor that `UIApplicationDelegate`
    /// otherwise imposes. Everything needed is read out here as plain values
    /// before any hop.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    /// Resolve a dose straight from the banner, without opening the app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Read the non-Sendable response down to two strings immediately.
        let requestID = response.notification.request.identifier
        let actionID = response.actionIdentifier

        guard let occurrenceID = NotificationIDs.occurrenceID(fromRequestID: requestID) else {
            return
        }

        let engine = await AppEnvironment.engine
        let notifications = await AppEnvironment.notifications

        do {
            switch actionID {
            case NotificationIDs.taken:
                try await engine.resolve(occurrenceID: occurrenceID, as: .taken)
                await notifications.cancel(occurrenceID: occurrenceID)

            case NotificationIDs.skip:
                try await engine.resolve(occurrenceID: occurrenceID, as: .skipped)
                await notifications.cancel(occurrenceID: occurrenceID)

            case NotificationIDs.snooze:
                let until = SnoozeDefaults.nextTime()
                try await engine.snooze(occurrenceID: occurrenceID, until: until)
                // Re-sync rather than hand-rolling a request: the snoozed row
                // has to re-enter the budget in its new position, which may
                // push something else out.
                await resync(engine: engine, notifications: notifications)

            default:
                // A plain tap opens the app. The timeline is already showing
                // this occurrence, so there is nothing further to do.
                break
            }
        } catch {
            print("[MagicPill] Notification action failed: \(error)")
        }
    }

    nonisolated private func resync(
        engine: ScheduleEngine,
        notifications: NotificationScheduler
    ) async {
        do {
            let reminders = try await engine.reminders()
            await notifications.sync(reminders: reminders)
        } catch {
            print("[MagicPill] Notification resync failed: \(error)")
        }
    }
}
