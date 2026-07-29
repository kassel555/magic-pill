import WidgetKit
import SwiftUI
import SwiftData
import AppIntents
import MagicPillKit

/// The store, opened once per extension process rather than per timeline
/// refresh. Building a `ModelContainer` is expensive and WidgetKit calls the
/// provider often.
///
/// Nil when the App Group is unavailable — an unsigned build, or missing
/// entitlements. The widget says so plainly instead of rendering an empty
/// timeline that looks like "you have nothing scheduled".
@MainActor
enum WidgetStore {
    static let container: ModelContainer? = {
        guard PersistenceStore.isAppGroupAvailable else { return nil }
        return try? PersistenceStore.shared()
    }()

    static func snapshot(now: Date = .now) -> WidgetSnapshot? {
        guard let container else { return nil }
        return try? WidgetSnapshotLoader.load(context: container.mainContext, now: now)
    }
}

// MARK: - Entry

struct UpNextEntry: TimelineEntry {
    let date: Date
    let content: UpNextContent
}

// MARK: - Provider

struct UpNextProvider: @preconcurrency TimelineProvider {

    @MainActor
    func placeholder(in context: Context) -> UpNextEntry {
        UpNextEntry(date: .now, content: .preview())
    }

    @MainActor
    func getSnapshot(in context: Context, completion: @escaping (UpNextEntry) -> Void) {
        // The gallery preview must always look inviting, never empty.
        if context.isPreview {
            completion(UpNextEntry(date: .now, content: .preview()))
            return
        }
        completion(currentEntry())
    }

    @MainActor
    func getTimeline(in context: Context, completion: @escaping (Timeline<UpNextEntry>) -> Void) {
        let now = Date.now
        guard let snapshot = WidgetStore.snapshot(now: now) else {
            let unavailable = UpNextEntry(
                date: now,
                content: UpNextContent(date: now, snapshot: .empty(), isStoreAvailable: false)
            )
            completion(Timeline(
                entries: [unavailable],
                policy: .after(now.addingTimeInterval(3600))
            ))
            return
        }

        // One entry now, then one at each upcoming reminder time. This is what
        // lets the widget advance to the next dose on its own, without the app
        // ever running — a widget that only refreshes when the app opens is
        // wrong precisely when it matters most.
        var entries = [UpNextEntry(
            date: now,
            content: UpNextContent(date: now, snapshot: snapshot, isStoreAvailable: true)
        )]
        for reminder in snapshot.upcoming where reminder.fireDate > now {
            entries.append(UpNextEntry(
                date: reminder.fireDate,
                content: UpNextContent(
                    date: reminder.fireDate,
                    snapshot: snapshot,
                    isStoreAvailable: true
                )
            ))
        }

        // `.atEnd` rather than a fixed interval: the last entry's date is the
        // last reminder we know about, which is exactly when a fresh read is
        // needed.
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    @MainActor
    private func currentEntry() -> UpNextEntry {
        let now = Date.now
        guard let snapshot = WidgetStore.snapshot(now: now) else {
            return UpNextEntry(
                date: now,
                content: UpNextContent(date: now, snapshot: .empty(), isStoreAvailable: false)
            )
        }
        return UpNextEntry(
            date: now,
            content: UpNextContent(date: now, snapshot: snapshot, isStoreAvailable: true)
        )
    }
}

// MARK: - Widget

struct UpNextWidget: Widget {
    let kind = "UpNextWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UpNextProvider()) { entry in
            WidgetBody(entry: entry)
                .containerBackground(Palette.surface, for: .widget)
        }
        .configurationDisplayName("Up Next")
        .description("Your next scheduled item and today's progress.")
        .supportedFamilies([
            .accessoryRectangular,
            .accessoryCircular,
            .systemSmall,
            .systemMedium,
        ])
    }
}

/// Maps WidgetKit's family onto the shared, renderable-anywhere layout, and
/// supplies the one piece the gallery can't have: a real `AppIntent` button.
private struct WidgetBody: View {
    @Environment(\.widgetFamily) private var family
    let entry: UpNextEntry

    var body: some View {
        switch family {
        case .systemMedium:
            MediumView(content: entry.content) { reminder in
                Button(intent: MarkTakenIntent(occurrenceID: reminder.id)) {
                    CompleteButtonLabel()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mark \(reminder.title) taken")
            }
        default:
            UpNextView(layout: layout, content: entry.content)
        }
    }

    private var layout: WidgetLayout {
        switch family {
        case .accessoryRectangular: .accessoryRectangular
        case .accessoryCircular:    .accessoryCircular
        case .systemMedium:         .systemMedium
        default:                    .systemSmall
        }
    }
}
