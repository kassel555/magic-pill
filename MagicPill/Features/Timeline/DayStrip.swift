import SwiftUI
import MagicPillKit

/// A quiet horizontal day selector.
///
/// Deliberately not a calendar: the manifesto's centrepiece is *today*, and a
/// month grid would pull attention into planning. This shows a rolling window
/// around the selected day and nothing more.
struct DayStrip: View {
    @Binding var selectedDate: Date
    let today: Date

    @Environment(\.dynamicTypeSize) private var typeSize

    /// Days either side of today that can be reached by scrolling.
    private let range = -14...14

    var body: some View {
        // Seven date cells on one line stop being a usable control at
        // accessibility sizes — a single cell fills the screen.
        //
        // This used to clamp Dynamic Type instead, which the accessibility
        // audit correctly flagged: clamping means someone who needs large text
        // simply doesn't get it. Stepper navigation carries the same
        // information at any size.
        if typeSize.isAccessibilitySize {
            steppedNavigation
        } else {
            strip
        }
    }

    /// Previous / next day, with the selected date spelled out between them.
    private var steppedNavigation: some View {
        HStack(spacing: Space.m) {
            stepButton(days: -1, symbol: "chevron.left", label: "Previous day")

            VStack(spacing: 2) {
                Text(selectedDate.formatted(.dateTime.weekday(.wide)))
                    .font(.headline)
                    .foregroundStyle(Palette.textPrimary)
                Text(selectedDate.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)

            stepButton(days: 1, symbol: "chevron.right", label: "Next day")
        }
        .padding(.horizontal, Space.xl)
    }

    private func stepButton(days: Int, symbol: String, label: String) -> some View {
        Button {
            if let moved = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) {
                selectedDate = moved
            }
        } label: {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.accentText)
                .frame(
                    minWidth: Metrics.minimumTapTarget,
                    minHeight: Metrics.minimumTapTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var days: [Date] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: today)
        return range.compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s) {
                    ForEach(days, id: \.self) { day in
                        DayCell(
                            date: day,
                            isSelected: Calendar.current.isDate(day, inSameDayAs: selectedDate),
                            isToday: Calendar.current.isDate(day, inSameDayAs: today)
                        )
                        .id(day)
                        .onTapGesture {
                            selectedDate = day
                        }
                    }
                }
                .padding(.horizontal, Space.xl)
            }
            .onAppear {
                proxy.scrollTo(Calendar.current.startOfDay(for: selectedDate), anchor: .center)
            }
            .onChange(of: selectedDate) { _, newValue in
                withAnimation {
                    proxy.scrollTo(Calendar.current.startOfDay(for: newValue), anchor: .center)
                }
            }
        }
        .accessibilityLabel("Day selector")
    }
}

private struct DayCell: View {
    let date: Date
    let isSelected: Bool
    let isToday: Bool

    private var weekday: String {
        date.formatted(.dateTime.weekday(.abbreviated))
    }

    private var dayNumber: String {
        date.formatted(.dateTime.day())
    }

    var body: some View {
        VStack(spacing: Space.xs) {
            Text(weekday)
                .font(.caption2.weight(.medium))
                .textCase(.uppercase)
                .foregroundStyle(isSelected ? Palette.textPrimary : Palette.textTertiary)

            Text(dayNumber)
                .font(.body.weight(isSelected ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Palette.textPrimary : Palette.textSecondary)

            // Today keeps a marker even when another day is selected, so the
            // user never loses their anchor.
            Circle()
                .fill(isToday ? Palette.accent : Color.clear)
                .frame(width: 4, height: 4)
        }
        .frame(minWidth: Metrics.minimumTapTarget)
        .padding(.vertical, Space.s)
        .background(
            RoundedRectangle(cornerRadius: Radius.well, style: .continuous)
                .fill(isSelected ? Palette.surfaceElevated : Color.clear)
                .shadow(
                    color: .black.opacity(isSelected ? 0.05 : 0),
                    radius: 6,
                    y: 2
                )
        )
        .contentShape(Rectangle())
        .calmAnimation(Motion.subtle, value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
