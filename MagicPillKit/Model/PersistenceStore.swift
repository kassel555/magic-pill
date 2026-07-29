import Foundation
import SwiftData

/// Model container construction for both the app and the widget extension.
///
/// The store lives in a shared App Group container from day one. Retrofitting a
/// shared container after the app has real user data means writing a migration,
/// so the widget's storage path is settled before the widget exists.
public enum PersistenceStore {

    /// Must match the App Group capability on both the app and widget targets.
    public static let appGroupID = "group.com.rahulkassel.MagicPill"

    public static let schema = Schema([
        TrackedItem.self,
        Schedule.self,
        Occurrence.self,
    ])

    /// Whether the App Group container is actually reachable.
    ///
    /// This check is not optional politeness. If the App Group is absent from
    /// the entitlements, SwiftData calls `fatalError` inside
    /// `ModelConfiguration` — it does *not* throw — so a `do/catch` around the
    /// container never runs and the app traps on launch. Probing the container
    /// URL first is the only way to detect this without crashing.
    ///
    /// In practice this is nil for unsigned simulator builds, which is exactly
    /// when a developer least wants a hard crash.
    public static var isAppGroupAvailable: Bool {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil
    }

    /// The real store: shared App Group container, mirrored to the user's
    /// private CloudKit database.
    public static func shared() throws -> ModelContainer {
        guard isAppGroupAvailable else {
            throw StoreError.appGroupUnavailable(appGroupID)
        }
        let configuration = ModelConfiguration(
            schema: schema,
            groupContainer: .identifier(appGroupID),
            cloudKitDatabase: .automatic
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    public enum StoreError: LocalizedError {
        case appGroupUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .appGroupUnavailable(let id):
                "App Group '\(id)' is not available. Check the App Group capability "
                    + "on both the app and widget targets, and that the build is signed."
            }
        }
    }

    /// An on-disk store in the app's own container, with no App Group and no
    /// CloudKit. This is what unsigned development builds run on: data still
    /// persists across launches, it simply doesn't sync and isn't visible to
    /// the widget.
    public static func local() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    /// Deletes the on-disk local store and its sidecar files.
    ///
    /// For UI tests, which need a known starting state. A test that depends on
    /// whatever the previous run left behind passes and fails for reasons
    /// unrelated to the change being tested.
    ///
    /// Only ever touches the app-private `.local` store — never the App Group
    /// container, and never anything CloudKit has synced. Call before the
    /// container is opened; deleting files out from under a live store corrupts
    /// it.
    public static func destroyLocalStore() {
        let fileManager = FileManager.default
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return }

        removeStoreFiles(in: support)

        // The App Group store too. Wiping only the app-private store was
        // correct exactly until signing was set up — at which point the app
        // moved to the shared container, UI tests stopped resetting anything,
        // and seven of them failed on stale data from the previous run.
        if let group = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) {
            removeStoreFiles(in: group.appendingPathComponent("Library/Application Support"))
        }
    }

    /// SwiftData's default store, plus the SQLite write-ahead log and shared
    /// memory files. Leaving the sidecars behind resurrects deleted rows.
    private static func removeStoreFiles(in directory: URL) {
        for name in ["default.store", "default.store-wal", "default.store-shm"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// An ephemeral store for previews and tests. Keeps CloudKit entirely out
    /// of the loop during development, where its constraints and latency only
    /// add noise.
    public static func inMemory() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    /// How the running app's store is actually backed.
    public enum Mode: Sendable {
        /// App Group + CloudKit. The real thing.
        case synced
        /// On-disk, app-private. Persists, but no sync and no widget access.
        case local
        /// Nothing is being written to disk at all.
        case memory

        public var persists: Bool { self != .memory }
    }

    /// The container the app runs against, degrading one step at a time.
    ///
    /// Each fallback is strictly worse than the one above, so the app reports
    /// which tier it landed on rather than pretending. Silently behaving like a
    /// lesser store is how a reminder app loses someone's data without ever
    /// showing an error.
    public static func production() -> (container: ModelContainer, mode: Mode) {
        do {
            return (try shared(), .synced)
        } catch {
            // Intentionally not fatalError: a launch crash is the worst
            // possible failure mode for a reminder app.
            print("[MagicPill] Synced store unavailable, falling back to local: \(error)")
        }

        do {
            return (try local(), .local)
        } catch {
            print("[MagicPill] Local store unavailable, falling back to memory: \(error)")
        }

        do {
            return (try inMemory(), .memory)
        } catch {
            fatalError("Could not create any model container: \(error)")
        }
    }
}
