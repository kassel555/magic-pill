import Foundation
import CoreData
import Observation

/// Watches CloudKit mirroring and publishes a status the Settings screen can
/// show.
///
/// SwiftData has no sync-status API of its own, but it is built on
/// `NSPersistentCloudKitContainer`, which posts every setup, import, and export
/// as a notification. That is the only supported way to know whether a user's
/// data is actually reaching iCloud — and "is my data safe" is a question this
/// app owes an honest answer to.
@MainActor
@Observable
public final class CloudSyncMonitor {

    public private(set) var status: CloudSyncStatus

    /// Kept for the diagnostics view: the most recent events, newest first.
    public private(set) var recentEvents: [CloudSyncEvent] = []

    /// Written once in `init` on the main actor, read only in `deinit`, which
    /// Swift 6 runs without isolation. There is no window in which both touch
    /// it, and removing the observer is worth the annotation.
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    private let maximumRecentEvents = 10

    /// - Parameter isSyncEnabled: false when the store isn't CloudKit-backed,
    ///   which pins the status to `.unavailable` rather than leaving it looking
    ///   like sync is merely quiet.
    public init(isSyncEnabled: Bool, unavailableReason: String = "") {
        if isSyncEnabled {
            status = .idle
            observeCloudKitEvents()
        } else {
            status = .unavailable(
                reason: unavailableReason.isEmpty
                    ? "This device is storing data locally."
                    : unavailableReason
            )
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func observeCloudKitEvents() {
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            ] as? NSPersistentCloudKitContainer.Event else { return }

            let mapped = CloudSyncEvent(event)
            MainActor.assumeIsolated {
                self?.apply(mapped)
            }
        }
    }

    /// Exposed so tests can drive the state machine without Core Data.
    public func apply(_ event: CloudSyncEvent) {
        status = .next(after: status, event: event)

        recentEvents.insert(event, at: 0)
        if recentEvents.count > maximumRecentEvents {
            recentEvents.removeLast(recentEvents.count - maximumRecentEvents)
        }
    }
}

extension CloudSyncEvent {
    init(_ event: NSPersistentCloudKitContainer.Event) {
        let kind: Kind = switch event.type {
        case .setup:  .setup
        case .import: .import
        case .export: .export
        @unknown default: .setup
        }

        self.init(
            kind: kind,
            endDate: event.endDate,
            succeeded: event.succeeded,
            // `localizedDescription` on a CloudKit error is usually the
            // account-level problem the user can actually act on ("not signed
            // in", "storage full") rather than an internal code.
            errorDescription: event.error?.localizedDescription
        )
    }
}
