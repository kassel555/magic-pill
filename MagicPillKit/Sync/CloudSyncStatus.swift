import Foundation

/// What iCloud sync is currently doing, in terms a person can act on.
///
/// Deliberately coarse. A sync UI that narrates every import and export teaches
/// users to watch it; this one exists to answer two questions — is my data
/// safe, and if not, why not.
public enum CloudSyncStatus: Sendable, Equatable {
    /// Sync isn't configured — an unsigned build, a missing entitlement, or no
    /// iCloud account. Data stays on this device.
    case unavailable(reason: String)

    /// Configured, nothing observed yet.
    case idle

    /// A setup, import, or export is in flight.
    case syncing

    /// Last operation completed successfully.
    case upToDate(at: Date)

    /// Last operation failed. The message is the user-facing explanation.
    case failed(message: String, at: Date)

    public var isHealthy: Bool {
        switch self {
        case .idle, .syncing, .upToDate: true
        case .unavailable, .failed: false
        }
    }

    public var title: String {
        switch self {
        case .unavailable: "Not syncing"
        case .idle:        "Waiting to sync"
        case .syncing:     "Syncing…"
        case .upToDate:    "Up to date"
        case .failed:      "Sync problem"
        }
    }

    public var detail: String {
        switch self {
        case .unavailable(let reason):
            reason
        case .idle:
            "Changes will sync when iCloud is ready."
        case .syncing:
            "Bringing this device up to date."
        case .upToDate(let date):
            "Last synced \(Self.relative(date))."
        case .failed(let message, let date):
            "\(message) (\(Self.relative(date)))"
        }
    }

    public var symbolName: String {
        switch self {
        case .unavailable: "icloud.slash"
        case .idle:        "icloud"
        case .syncing:     "arrow.triangle.2.circlepath.icloud"
        case .upToDate:    "checkmark.icloud"
        case .failed:      "exclamationmark.icloud"
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}

/// A plain-value mirror of `NSPersistentCloudKitContainer.Event`.
///
/// That type cannot be constructed outside Core Data, which would make the
/// status logic untestable. The monitor maps real events into this; everything
/// downstream — including every test — works on these.
public struct CloudSyncEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case setup
        /// Backticked: `import` is a Swift keyword.
        case `import`
        case export
    }

    public let kind: Kind
    /// Nil while the operation is still running.
    public let endDate: Date?
    public let succeeded: Bool
    public let errorDescription: String?

    public init(
        kind: Kind,
        endDate: Date?,
        succeeded: Bool,
        errorDescription: String? = nil
    ) {
        self.kind = kind
        self.endDate = endDate
        self.succeeded = succeeded
        self.errorDescription = errorDescription
    }

    public var isFinished: Bool { endDate != nil }
}

public extension CloudSyncStatus {
    /// Derives the next status from an event and what came before it.
    ///
    /// The previous status matters: a finished export that succeeded must not
    /// erase a failure reported by the import just before it. A sync UI that
    /// flickers back to "Up to date" while something is genuinely broken is
    /// worse than no UI, because it is actively reassuring.
    static func next(after previous: CloudSyncStatus, event: CloudSyncEvent) -> CloudSyncStatus {
        // Never override "unavailable" — that's a configuration fact, not the
        // outcome of an operation.
        if case .unavailable = previous { return previous }

        guard let endDate = event.endDate else {
            return .syncing
        }

        if event.succeeded {
            return .upToDate(at: endDate)
        }

        return .failed(
            message: event.errorDescription ?? "iCloud couldn't complete the last sync.",
            at: endDate
        )
    }
}
