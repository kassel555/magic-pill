import Testing
import Foundation
@testable import MagicPillKit

/// Phase 7: the sync status state machine.
///
/// CloudKit itself can't be exercised without signing and two devices, but the
/// logic deciding *what to tell the user* can be — and that logic is where the
/// damage would be done. A sync indicator that says "Up to date" while data is
/// stranded is worse than having no indicator at all: it converts a recoverable
/// problem into a silent one.
@Suite("Cloud sync")
struct CloudSyncTests {

    private let moment = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(
        _ kind: CloudSyncEvent.Kind = .export,
        finished: Bool = true,
        succeeded: Bool = true,
        error: String? = nil
    ) -> CloudSyncEvent {
        CloudSyncEvent(
            kind: kind,
            endDate: finished ? moment : nil,
            succeeded: succeeded,
            errorDescription: error
        )
    }

    // MARK: - Transitions

    @Test("An unfinished event means syncing")
    func inFlightIsSyncing() {
        let status = CloudSyncStatus.next(after: .idle, event: event(finished: false))
        #expect(status == .syncing)
    }

    @Test("A finished, successful event means up to date")
    func successIsUpToDate() {
        let status = CloudSyncStatus.next(after: .syncing, event: event())
        #expect(status == .upToDate(at: moment))
    }

    @Test("A failed event surfaces the error text")
    func failureCarriesMessage() {
        let status = CloudSyncStatus.next(
            after: .syncing,
            event: event(succeeded: false, error: "You're not signed in to iCloud.")
        )
        #expect(status == .failed(message: "You're not signed in to iCloud.", at: moment))
    }

    @Test("A failure without an error string still says something useful")
    func failureWithoutMessage() {
        let status = CloudSyncStatus.next(after: .idle, event: event(succeeded: false))

        guard case .failed(let message, _) = status else {
            Issue.record("Expected a failure status")
            return
        }
        #expect(!message.isEmpty)
    }

    /// `unavailable` is a statement about configuration, not the outcome of an
    /// operation. Nothing CloudKit reports should override it — otherwise a
    /// local-only build could claim to be syncing.
    @Test("Unavailable is never overridden by an event")
    func unavailableIsSticky() {
        let unavailable = CloudSyncStatus.unavailable(reason: "No iCloud account.")

        #expect(CloudSyncStatus.next(after: unavailable, event: event()) == unavailable)
        #expect(CloudSyncStatus.next(
            after: unavailable, event: event(finished: false)
        ) == unavailable)
        #expect(CloudSyncStatus.next(
            after: unavailable, event: event(succeeded: false, error: "boom")
        ) == unavailable)
    }

    @Test("Recovery is possible: a success after a failure clears it")
    func recoveryClearsFailure() {
        let failed = CloudSyncStatus.failed(message: "Network unavailable.", at: moment)
        let later = moment.addingTimeInterval(60)

        let status = CloudSyncStatus.next(
            after: failed,
            event: CloudSyncEvent(kind: .import, endDate: later, succeeded: true)
        )
        #expect(status == .upToDate(at: later))
    }

    // MARK: - Presentation

    @Test("Only genuinely fine states report as healthy")
    func healthiness() {
        #expect(CloudSyncStatus.idle.isHealthy)
        #expect(CloudSyncStatus.syncing.isHealthy)
        #expect(CloudSyncStatus.upToDate(at: moment).isHealthy)

        #expect(!CloudSyncStatus.unavailable(reason: "x").isHealthy)
        #expect(!CloudSyncStatus.failed(message: "x", at: moment).isHealthy)
    }

    @Test("Every status has a title, a detail, and a symbol")
    func everyStatusIsPresentable() {
        let all: [CloudSyncStatus] = [
            .unavailable(reason: "Local only."),
            .idle,
            .syncing,
            .upToDate(at: moment),
            .failed(message: "Something went wrong.", at: moment),
        ]

        for status in all {
            #expect(!status.title.isEmpty)
            #expect(!status.detail.isEmpty)
            #expect(!status.symbolName.isEmpty)
        }
    }

    @Test("The unavailable reason is shown, not swallowed")
    func unavailableExplainsItself() {
        let status = CloudSyncStatus.unavailable(reason: "You're not signed in to iCloud.")
        #expect(status.detail.contains("not signed in"))
    }

    // MARK: - Monitor

    @Test("A monitor without sync pins itself to unavailable")
    @MainActor
    func disabledMonitorIsUnavailable() {
        let monitor = CloudSyncMonitor(
            isSyncEnabled: false,
            unavailableReason: "Data stays on this device."
        )

        #expect(monitor.status == .unavailable(reason: "Data stays on this device."))

        // Even if events somehow arrive, the status holds.
        monitor.apply(event())
        #expect(!monitor.status.isHealthy)
    }

    @Test("A monitor with sync starts idle and follows events")
    @MainActor
    func enabledMonitorTracksEvents() {
        let monitor = CloudSyncMonitor(isSyncEnabled: true)
        #expect(monitor.status == .idle)

        monitor.apply(event(.setup, finished: false))
        #expect(monitor.status == .syncing)

        monitor.apply(event(.import))
        #expect(monitor.status == .upToDate(at: moment))
    }

    @Test("Recent events are newest-first and bounded")
    @MainActor
    func recentEventsAreBounded() {
        let monitor = CloudSyncMonitor(isSyncEnabled: true)

        for index in 0..<25 {
            monitor.apply(CloudSyncEvent(
                kind: .export,
                endDate: moment.addingTimeInterval(Double(index)),
                succeeded: true
            ))
        }

        #expect(monitor.recentEvents.count <= 10)
        #expect(monitor.recentEvents.first?.endDate == moment.addingTimeInterval(24))
    }
}
