import SwiftUI
import SwiftData
import MagicPillKit

/// One item: what it is, when it recurs, and how it's been going.
///
/// The last screen from the original spec, and the payoff for everything the
/// scheduling engine protects — resolved occurrences have been treated as
/// immutable history since Phase 4 specifically so this view could exist.
/// Until now the app recorded adherence faithfully and gave the user no way to
/// see it.
struct ItemDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let item: TrackedItem

    @State private var isEditing = false
    @State private var now: Date = .now

    private var summary: AdherenceSummary {
        AdherenceCalculator.summary(for: item, now: now)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                header
                scheduleSection
                adherenceSection
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.surface)
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Edit") { isEditing = true }
                    .accessibilityIdentifier(A11y.Detail.edit)
            }
        }
        .sheet(isPresented: $isEditing) {
            ItemEditorView(item: item)
        }
        // Recompute after an edit or a resolved dose, without a timer.
        .onChange(of: item.occurrences?.count) { _, _ in now = .now }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: Space.l) {
            SymbolWell(symbolName: item.symbolName, token: item.colorToken)
                .scaleEffect(1.2, anchor: .topLeading)
                .frame(width: Metrics.symbolWell * 1.2, height: Metrics.symbolWell * 1.2)

            VStack(alignment: .leading, spacing: Space.xs) {
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(TypeScale.itemName)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !item.note.isEmpty {
                    Text(item.note)
                        .font(TypeScale.itemDetail)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if item.detail.isEmpty && item.note.isEmpty {
                    Text(item.template.displayName)
                        .font(TypeScale.itemDetail)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Schedule

    private var scheduleSection: some View {
        section("Schedule") {
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(item.schedules ?? []) { schedule in
                    HStack(spacing: Space.s) {
                        Image(systemName: schedule.isPaused ? "pause.circle" : "clock")
                            .foregroundStyle(Palette.textTertiary)
                        Text(schedule.summary)
                            .font(TypeScale.itemDetail)
                            .foregroundStyle(Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }

                if (item.schedules ?? []).isEmpty {
                    Text("No schedule yet.")
                        .font(TypeScale.itemDetail)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
    }

    // MARK: - Adherence

    private var adherenceSection: some View {
        section("Last 30 Days") {
            VStack(alignment: .leading, spacing: Space.l) {
                if summary.hasHistory {
                    adherenceHeadline
                } else {
                    // A new item has nothing to report. Saying so is kinder and
                    // more accurate than rendering 0%.
                    Text("Nothing recorded yet. This fills in as you go.")
                        .font(TypeScale.itemDetail)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                AdherenceGrid(summary: summary)
            }
        }
    }

    private var adherenceHeadline: some View {
        HStack(spacing: Space.l) {
            if let rate = summary.rate {
                HStack(spacing: Space.m) {
                    // Sage, not the item's own colour. Adherence is a universal
                    // measure, and a stone-grey item rendered a *full* ring that
                    // read as an empty one — the fill was indistinguishable from
                    // the track. Identity colour belongs on the symbol well.
                    ProgressRing(progress: rate, token: .sage, lineWidth: 5)
                        .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(rate.formatted(.percent.precision(.fractionLength(0))))
                            .font(TypeScale.itemName)
                            .foregroundStyle(Palette.textPrimary)
                        Text("taken")
                            .font(.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(rate.formatted(.percent.precision(.fractionLength(0)))) taken"
                )
            }

            if summary.currentStreak > 1 {
                Divider().frame(height: 32)

                VStack(alignment: .leading, spacing: 0) {
                    Text("\(summary.currentStreak)")
                        .font(TypeScale.itemName)
                        .foregroundStyle(Palette.textPrimary)
                        .monospacedDigit()
                    Text("day streak")
                        .font(.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(summary.currentStreak) day streak")
            }
        }
    }

    // MARK: - Chrome

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(title)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
