import SwiftUI
import MagicPillKit

/// A single occurrence, as the premium card from the manifesto:
///
///     8:00 AM
///     ───────────────
///     💊 Vitamin D
///     1 Tablet
///     Take with breakfast
///
/// Completion is by swipe, never a checkbox. Resolved cards collapse to a
/// quiet, dimmed state rather than disappearing — the day should still read as
/// a whole once it's over.
struct OccurrenceCard: View {
    let occurrence: Occurrence
    let onResolve: (OccurrenceState) -> Void
    let onSnooze: () -> Void
    var onSelect: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    private var nameText: some View {
        Text(item?.name ?? "Untitled")
            .font(isResolved ? TypeScale.itemDetail : TypeScale.itemName)
            .foregroundStyle(isResolved ? Palette.textSecondary : Palette.textPrimary)
            .strikethrough(occurrence.state == .skipped, color: Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            // Wins space against the status label beside it. Without this the
            // status's own width claim squeezed the name until it couldn't grow
            // with Dynamic Type — which the accessibility audit flagged on
            // resolved rows with longer names.
            .layoutPriority(1)
    }

    private var item: TrackedItem? { occurrence.item }
    private var token: ColorToken { item?.colorToken ?? .stone }
    private var isResolved: Bool { occurrence.isResolved }
    private var isOverdue: Bool { occurrence.isOverdue() }

    var body: some View {
        // Resolved rows collapse to a single quiet line. The day still reads as
        // a whole once it's over — the manifesto's "timeline compresses
        // beautifully" — without spending vertical space on work already done.
        HStack(alignment: isResolved ? .center : .top, spacing: Space.m) {
            SymbolWell(
                symbolName: item?.symbolName ?? "circle",
                token: token,
                isDimmed: isResolved
            )
            .scaleEffect(isResolved ? 0.78 : 1, anchor: .center)
            .frame(
                width: isResolved ? Metrics.symbolWell * 0.78 : Metrics.symbolWell,
                height: isResolved ? Metrics.symbolWell * 0.78 : Metrics.symbolWell
            )

            VStack(alignment: .leading, spacing: Space.xs) {
                // At accessibility sizes the name and its status can't share a
                // line without both wrapping to shreds, so they stack.
                if isResolved && typeSize.isAccessibilitySize {
                    nameText
                    statusLabel
                } else {
                    HStack(spacing: Space.s) {
                        nameText

                        if isResolved {
                            Spacer(minLength: 0)
                            statusLabel
                        }
                    }
                }

                if !isResolved {
                    if let detail = item?.detail, !detail.isEmpty {
                        Text(detail)
                            .font(TypeScale.itemDetail)
                            .foregroundStyle(Palette.textSecondary)
                    }

                    if let note = item?.note, !note.isEmpty {
                        Text(note)
                            .font(TypeScale.itemNote)
                            .foregroundStyle(Palette.textTertiary)
                    }

                    if isOverdue {
                        statusLabel
                            .padding(.top, Space.xs)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, isResolved ? Space.m : Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .onTapGesture(perform: onSelect)
        // No blanket opacity on resolved rows. Fading the whole card to 62%
        // dropped its text to roughly 2.5:1 — the accessibility audit caught
        // it. Alpha is a tempting way to say "done" and a bad one: it dims the
        // content along with the chrome.
        //
        // The quiet comes from smaller type, a secondary text colour, a shrunk
        // symbol well, and a flatter shadow — all of which stay legible.
        .calmAnimation(Motion.completion, value: occurrence.stateRaw)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !isResolved {
                Button {
                    onResolve(.taken)
                } label: {
                    Label("Taken", systemImage: "checkmark")
                }
                .tint(ColorToken.sage.color)

                Button {
                    onResolve(.skipped)
                } label: {
                    Label("Skip", systemImage: "minus.circle")
                }
                .tint(ColorToken.stone.color)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !isResolved {
                Button(action: onSnooze) {
                    Label("Snooze", systemImage: "clock")
                }
                .tint(ColorToken.ocean.color)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(A11y.Timeline.card(item?.name ?? "Untitled"))
        // Swipe actions are unreachable by VoiceOver gesture, so every one of
        // them is also published as a custom action.
        .accessibilityAddTraits(.isButton)
        .accessibilityActions {
            Button("Edit") { onSelect() }
            if !isResolved {
                Button("Mark taken") { onResolve(.taken) }
                Button("Skip") { onResolve(.skipped) }
                Button("Snooze") { onSnooze() }
            }
        }
    }

    private var statusLabel: some View {
        Group {
            switch occurrence.state {
            case .taken:
                label("Taken", systemImage: "checkmark.circle.fill", color: Palette.accentText)
            case .skipped:
                label("Skipped", systemImage: "minus.circle.fill", color: Palette.textTertiary)
            case .missed:
                label("Missed", systemImage: "clock.badge.exclamationmark", color: Palette.overdueText)
            case .pending:
                // Overdue, but deliberately amber and softly worded. Never red,
                // never an alarm.
                label("Overdue", systemImage: "clock", color: Palette.overdueText)
            }
        }
    }

    private func label(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: Space.xs) {
            Image(systemName: systemImage)
            Text(text)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        // Yields to the item name rather than claiming width from it. A status
        // is two words and can afford to be the thing that gives.
        .layoutPriority(0)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(Palette.surfaceElevated)
            .shadow(
                color: .black.opacity(isResolved ? 0.02 : 0.05),
                radius: isResolved ? 3 : 10,
                y: isResolved ? 1 : 3
            )
    }

    private var accessibilityLabel: String {
        var parts: [String] = [
            occurrence.effectiveTime.formatted(date: .omitted, time: .shortened),
            item?.name ?? "Untitled",
        ]
        if let detail = item?.detail, !detail.isEmpty { parts.append(detail) }
        if let note = item?.note, !note.isEmpty, !isResolved { parts.append(note) }
        if isResolved {
            parts.append(occurrence.state.displayName)
        } else if isOverdue {
            parts.append("Overdue")
        }
        return parts.joined(separator: ", ")
    }
}
