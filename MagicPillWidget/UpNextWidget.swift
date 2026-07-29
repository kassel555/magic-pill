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
    let snapshot: WidgetSnapshot
    /// Distinguishes "nothing scheduled" from "cannot read the store".
    let isStoreAvailable: Bool

    var upcoming: [Reminder] {
        // Entries are generated ahead of time; by the moment an entry is shown,
        // reminders earlier than its own date have already passed.
        snapshot.upcoming.filter { $0.fireDate >= date }
    }
}

// MARK: - Provider

struct UpNextProvider: @preconcurrency TimelineProvider {

    @MainActor
    func placeholder(in context: Context) -> UpNextEntry {
        UpNextEntry(date: .now, snapshot: .placeholder(), isStoreAvailable: true)
    }

    @MainActor
    func getSnapshot(in context: Context, completion: @escaping (UpNextEntry) -> Void) {
        // The gallery preview must always look inviting, never empty.
        if context.isPreview {
            completion(UpNextEntry(date: .now, snapshot: .placeholder(), isStoreAvailable: true))
            return
        }
        completion(currentEntry())
    }

    @MainActor
    func getTimeline(in context: Context, completion: @escaping (Timeline<UpNextEntry>) -> Void) {
        let now = Date.now
        guard let snapshot = WidgetStore.snapshot(now: now) else {
            completion(Timeline(
                entries: [UpNextEntry(date: now, snapshot: .empty(), isStoreAvailable: false)],
                policy: .after(now.addingTimeInterval(3600))
            ))
            return
        }

        // One entry now, then one at each upcoming reminder time. This is what
        // lets the widget advance to the next dose on its own, without the app
        // ever running — a widget that only refreshes when the app opens is
        // wrong precisely when it matters most.
        var entries = [UpNextEntry(date: now, snapshot: snapshot, isStoreAvailable: true)]
        for reminder in snapshot.upcoming where reminder.fireDate > now {
            entries.append(UpNextEntry(
                date: reminder.fireDate,
                snapshot: snapshot,
                isStoreAvailable: true
            ))
        }

        // `.atEnd` rather than a fixed interval: the last entry's date is the
        // last reminder we know about, which is exactly when a fresh read is
        // needed.
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    @MainActor
    private func currentEntry() -> UpNextEntry {
        guard let snapshot = WidgetStore.snapshot() else {
            return UpNextEntry(date: .now, snapshot: .empty(), isStoreAvailable: false)
        }
        return UpNextEntry(date: .now, snapshot: snapshot, isStoreAvailable: true)
    }
}

// MARK: - Widget

struct UpNextWidget: Widget {
    let kind = "UpNextWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UpNextProvider()) { entry in
            UpNextView(entry: entry)
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

// MARK: - Views

struct UpNextView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UpNextEntry

    var body: some View {
        switch family {
        case .accessoryRectangular: RectangularView(entry: entry)
        case .accessoryCircular:    CircularView(entry: entry)
        case .systemMedium:         MediumView(entry: entry)
        default:                    SmallView(entry: entry)
        }
    }
}

/// The manifesto's lock-screen sketch: time, name, then what's after it.
/// Rendered monochrome by the system, so it leans on hierarchy, not colour.
private struct RectangularView: View {
    let entry: UpNextEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !entry.isStoreAvailable {
                Text("Unavailable").font(.headline)
                Text("Open Magic Pill").font(.caption)
            } else if let next = entry.upcoming.first {
                Text(next.fireDate, style: .time)
                    .font(.caption)
                    .widgetAccentable()
                Text(next.title)
                    .font(.headline)
                    .lineLimit(1)

                if let following = entry.upcoming.dropFirst().first {
                    Text("Next \(following.fireDate.formatted(date: .omitted, time: .shortened)) · \(following.title)")
                        .font(.caption2)
                        .lineLimit(1)
                } else if entry.snapshot.totalToday > 0 {
                    Text("Nothing else today").font(.caption2)
                }
            } else {
                Text("All done").font(.headline)
                Text("Nothing scheduled").font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CircularView: View {
    let entry: UpNextEntry

    var body: some View {
        Gauge(value: entry.snapshot.progress) {
            Image(systemName: "pills.fill")
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }
}

private struct SmallView: View {
    let entry: UpNextEntry

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                ProgressRing(progress: entry.snapshot.progress, lineWidth: 4)
                    .frame(width: 22, height: 22)
                Spacer()
                if entry.snapshot.totalToday > 0 {
                    Text("\(entry.snapshot.remainingToday)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Palette.textSecondary)
                }
            }

            Spacer(minLength: 0)

            if !entry.isStoreAvailable {
                Text("Unavailable")
                    .font(TypeScale.itemName)
                    .foregroundStyle(Palette.textSecondary)
                Text("Open Magic Pill")
                    .font(.caption2)
                    .foregroundStyle(Palette.textTertiary)
            } else if let next = entry.upcoming.first {
                Text(next.fireDate, style: .time)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(Palette.textSecondary)
                Text(next.title)
                    .font(TypeScale.itemName)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
            } else {
                Text("All done")
                    .font(TypeScale.itemName)
                    .foregroundStyle(Palette.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Three rows, each completable in place.
private struct MediumView: View {
    let entry: UpNextEntry

    private var rows: [Reminder] { Array(entry.upcoming.prefix(3)) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            header

            if !entry.isStoreAvailable {
                Text("Open Magic Pill to set this up.")
                    .font(.caption)
                    .foregroundStyle(Palette.textTertiary)
            } else if rows.isEmpty {
                Text("Nothing left today.")
                    .font(.caption)
                    .foregroundStyle(Palette.textTertiary)
            } else {
                ForEach(rows) { reminder in
                    row(reminder)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: Space.s) {
            ProgressRing(progress: entry.snapshot.progress, lineWidth: 4)
                .frame(width: 18, height: 18)
            Text(entry.snapshot.isDayComplete
                 ? "All done"
                 : "\(entry.snapshot.remainingToday) remaining")
                .font(.caption.weight(.medium))
                .foregroundStyle(Palette.textSecondary)
        }
    }

    private func row(_ reminder: Reminder) -> some View {
        HStack(spacing: Space.s) {
            Text(reminder.fireDate, style: .time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 58, alignment: .leading)

            Text(reminder.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)

            Spacer(minLength: Space.xs)

            // Interactive: resolves in place, no app launch.
            Button(intent: MarkTakenIntent(occurrenceID: reminder.id)) {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(ColorToken.sage.wash))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark \(reminder.title) taken")
        }
    }
}
