import AppIntents
import Foundation
import WidgetKit

/// Marks a dose taken from a widget button, without opening the app.
///
/// Lives in the framework so the app and the widget extension resolve the same
/// intent type. Two separately-declared intents with the same identifier is a
/// silent mismatch: the button appears and does nothing.
public struct MarkTakenIntent: AppIntent {
    // `let`, not `var`: under Swift 6 a mutable static is global shared mutable
    // state and fails the concurrency check. These are constants anyway.
    public static let title: LocalizedStringResource = "Mark Taken"
    public static let description = IntentDescription("Marks a scheduled item as taken.")

    /// Not `openAppWhenRun` — the whole point is resolving from the home
    /// screen. The manifesto's premium feel dies at "tap opens app, wait, tap
    /// again".
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "Occurrence")
    public var occurrenceID: String

    public init() {
        self.occurrenceID = ""
    }

    public init(occurrenceID: UUID) {
        self.occurrenceID = occurrenceID.uuidString
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: occurrenceID) else {
            return .result()
        }

        // The widget writes through the shared App Group store — the same one
        // the app uses. Without the group container this silently no-ops, which
        // is why the widget renders an explicit unavailable state rather than
        // pretending to work.
        guard PersistenceStore.isAppGroupAvailable,
              let container = try? PersistenceStore.shared()
        else { return .result() }

        let engine = ScheduleEngine(modelContainer: container)
        _ = try? await engine.resolve(occurrenceID: id, as: .taken)

        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
