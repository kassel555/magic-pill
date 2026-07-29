import SwiftUI
import SwiftData
import MagicPillKit

/// Renders every widget layout at its real size, against live data.
///
/// Exists because a widget is otherwise the one part of the app nobody can
/// look at without a device and a long-press on the home screen — which made
/// it the only screen that shipped six phases without ever being seen. This is
/// how the widget screenshots are produced, and how a layout regression gets
/// noticed before someone adds the widget for real.
///
/// It is not the widget: `containerBackground`, `widgetAccentable`, and
/// interactive `AppIntent` buttons only work inside a real widget process. The
/// backgrounds and the inert complete button here approximate what WidgetKit
/// draws around the same views.
struct WidgetGalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    /// Set by the screenshot harness so output is identical run to run.
    var usesFixedSampleData = false

    @State private var content: UpNextContent = .preview()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xxl) {
                    ForEach(WidgetLayout.allCases, id: \.rawValue) { layout in
                        section(for: layout)
                    }
                }
                .padding(Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Palette.surface)
            .navigationTitle("Widgets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .tint(Palette.accentText)
        }
        .task { load() }
    }

    private func section(for layout: WidgetLayout) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(layout.displayName)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            UpNextView(layout: layout, content: content)
                .padding(padding(for: layout))
                .frame(width: layout.previewSize.width, height: layout.previewSize.height)
                .background(background(for: layout))
                .accessibilityIdentifier(A11y.Gallery.widget(layout.rawValue))
        }
    }

    /// Accessory widgets are drawn by the system on the lock screen with a
    /// translucent backing; home-screen widgets get the app's own surface.
    @ViewBuilder
    private func background(for layout: WidgetLayout) -> some View {
        switch layout {
        case .accessoryRectangular, .accessoryCircular:
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.textPrimary.opacity(0.12))
        case .systemSmall, .systemMedium:
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.surfaceElevated)
                .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
        }
    }

    private func padding(for layout: WidgetLayout) -> CGFloat {
        switch layout {
        case .accessoryCircular: 0
        default: Space.l
        }
    }

    private func load() {
        let now = Date.now

        // Fixed data for screenshots; live data otherwise, so the gallery
        // doubles as a way to see what the widget will actually show.
        guard !usesFixedSampleData else {
            content = .preview(now: now)
            return
        }

        if let snapshot = try? WidgetSnapshotLoader.load(context: context, now: now) {
            content = UpNextContent(date: now, snapshot: snapshot, isStoreAvailable: true)
        }
    }
}
