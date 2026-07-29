import SwiftUI

/// Which widget layout to render.
///
/// A plain enum rather than WidgetKit's `WidgetFamily`, so these views can be
/// rendered anywhere — SwiftUI previews, the in-app gallery that produces the
/// screenshots, and eventually snapshot tests. Reading `@Environment(\.widgetFamily)`
/// works only inside a real widget, which made the widget the one part of the
/// app nobody could look at without adding it to a home screen.
public enum WidgetLayout: String, CaseIterable, Sendable {
    case accessoryRectangular
    case accessoryCircular
    case systemSmall
    case systemMedium

    /// Point size on a 402pt-wide iPhone. Used by the gallery to render each
    /// layout at the size it will actually occupy.
    public var previewSize: CGSize {
        switch self {
        case .accessoryRectangular: CGSize(width: 172, height: 76)
        case .accessoryCircular:    CGSize(width: 76, height: 76)
        case .systemSmall:          CGSize(width: 158, height: 158)
        case .systemMedium:         CGSize(width: 338, height: 158)
        }
    }

    public var displayName: String {
        switch self {
        case .accessoryRectangular: "Lock Screen"
        case .accessoryCircular:    "Circular"
        case .systemSmall:          "Small"
        case .systemMedium:         "Medium"
        }
    }
}

/// What a widget renders from.
///
/// Distinguishes "nothing scheduled" from "cannot read the store" — an empty
/// widget that means the latter would tell someone their day is clear when the
/// app simply can't see its data.
public struct UpNextContent: Sendable, Equatable {
    public let date: Date
    public let snapshot: WidgetSnapshot
    public let isStoreAvailable: Bool

    public init(date: Date, snapshot: WidgetSnapshot, isStoreAvailable: Bool) {
        self.date = date
        self.snapshot = snapshot
        self.isStoreAvailable = isStoreAvailable
    }

    /// Reminders still ahead of this entry's own date. Entries are generated in
    /// advance, so by the time one is shown the earlier ones have passed.
    public var upcoming: [Reminder] {
        snapshot.upcoming.filter { $0.fireDate >= date }
    }

    public static func preview(now: Date = .now) -> UpNextContent {
        UpNextContent(date: now, snapshot: .placeholder(now: now), isStoreAvailable: true)
    }
}

// MARK: - Root

public struct UpNextView: View {
    private let layout: WidgetLayout
    private let content: UpNextContent

    public init(layout: WidgetLayout, content: UpNextContent) {
        self.layout = layout
        self.content = content
    }

    public var body: some View {
        switch layout {
        case .accessoryRectangular: RectangularView(content: content)
        case .accessoryCircular:    CircularView(content: content)
        case .systemSmall:          SmallView(content: content)
        case .systemMedium:         MediumView(content: content)
        }
    }
}

/// The manifesto's lock-screen sketch: time, name, then what's after it.
/// Rendered monochrome by the system, so it leans on hierarchy, not colour.
struct RectangularView: View {
    let content: UpNextContent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !content.isStoreAvailable {
                Text("Unavailable").font(.headline)
                Text("Open Magic Pill").font(.caption)
            } else if let next = content.upcoming.first {
                Text(next.fireDate, style: .time)
                    .font(.caption)
                Text(next.title)
                    .font(.headline)
                    .lineLimit(1)

                if let following = content.upcoming.dropFirst().first {
                    Text("Next \(following.fireDate.formatted(date: .omitted, time: .shortened)) · \(following.title)")
                        .font(.caption2)
                        .lineLimit(1)
                } else if content.snapshot.totalToday > 0 {
                    Text("Nothing else today").font(.caption2)
                }
            } else {
                Text("All done").font(.headline)
                Text("Nothing scheduled").font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct CircularView: View {
    let content: UpNextContent

    var body: some View {
        Gauge(value: content.snapshot.progress) {
            Image(systemName: "pills.fill")
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }
}

struct SmallView: View {
    let content: UpNextContent

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                ProgressRing(progress: content.snapshot.progress, lineWidth: 4)
                    .frame(width: 22, height: 22)
                Spacer()
                if content.snapshot.totalToday > 0 {
                    Text("\(content.snapshot.remainingToday)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Palette.textSecondary)
                }
            }

            Spacer(minLength: 0)

            if !content.isStoreAvailable {
                Text("Unavailable")
                    .font(TypeScale.itemName)
                    .foregroundStyle(Palette.textSecondary)
                Text("Open Magic Pill")
                    .font(.caption2)
                    .foregroundStyle(Palette.textTertiary)
            } else if let next = content.upcoming.first {
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

/// Three rows. In the real widget each carries a complete button; the gallery
/// renders them inert, since `Button(intent:)` needs a widget context.
public struct MediumView<Trailing: View>: View {
    let content: UpNextContent
    private let trailing: (Reminder) -> Trailing

    /// Public so the widget target can supply a real `AppIntent` button, which
    /// only functions inside a widget process.
    public init(content: UpNextContent, @ViewBuilder trailing: @escaping (Reminder) -> Trailing) {
        self.content = content
        self.trailing = trailing
    }

    private var rows: [Reminder] { Array(content.upcoming.prefix(3)) }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            header

            if !content.isStoreAvailable {
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
            ProgressRing(progress: content.snapshot.progress, lineWidth: 4)
                .frame(width: 18, height: 18)
            Text(content.snapshot.isDayComplete
                 ? "All done"
                 : "\(content.snapshot.remainingToday) remaining")
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

            trailing(reminder)
        }
    }
}

public extension MediumView where Trailing == CompleteButtonPlaceholder {
    /// The non-interactive form, for previews and the gallery.
    init(content: UpNextContent) {
        self.init(content: content) { _ in CompleteButtonPlaceholder() }
    }
}

/// Looks exactly like the real complete button but does nothing — so a gallery
/// screenshot shows the widget as the user will see it.
public struct CompleteButtonPlaceholder: View {
    public init() {}

    public var body: some View {
        CompleteButtonLabel()
    }
}

/// The shared appearance of the medium widget's complete button.
public struct CompleteButtonLabel: View {
    public init() {}

    public var body: some View {
        Image(systemName: "checkmark")
            .font(.caption2.weight(.bold))
            .foregroundStyle(Palette.accentText)
            .frame(width: 24, height: 24)
            .background(Circle().fill(ColorToken.sage.wash))
    }
}
