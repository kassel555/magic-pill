import SwiftUI
import MagicPillKit

/// Thirty days as a grid of dots.
///
/// The manifesto rules out tables and spreadsheets, which is most of what a
/// medication app would normally show here. A dot per day carries the same
/// information at a glance and reads as a pattern rather than a report card —
/// and a pattern is what's actually useful ("I keep missing weekends").
struct AdherenceGrid: View {
    let summary: AdherenceSummary

    @Environment(\.dynamicTypeSize) private var typeSize

    /// One column per weekday, so weeks line up vertically and a weekend gap is
    /// visible as a column rather than hidden in a run of dots.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    private var calendar: Calendar { .current }

    /// Blank cells before the first day, so column position means weekday.
    private var leadingBlanks: Int {
        guard let first = summary.days.first else { return 0 }
        let weekday = calendar.component(.weekday, from: first.date)
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            weekdayHeader

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(0..<leadingBlanks, id: \.self) { _ in
                    Color.clear.frame(height: dotSize)
                }
                ForEach(summary.days) { day in
                    dot(for: day)
                }
            }

            legend
                .padding(.top, Space.xs)
        }
        // The grid is decorative detail; the summary above it already states
        // the numbers, and 30 individually-swipeable dots would be a worse
        // VoiceOver experience than one sentence.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var dotSize: CGFloat {
        typeSize.isAccessibilitySize ? 20 : 14
    }

    private var weekdayHeader: some View {
        HStack(spacing: 6) {
            ForEach(orderedWeekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption2)
                    .foregroundStyle(Palette.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private var orderedWeekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return (0..<7).map { symbols[(first + $0) % 7] }
    }

    private func dot(for day: DayAdherence) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color(for: day.state))
            .frame(height: dotSize)
            .overlay {
                // Today gets a ring rather than a different fill, so "today"
                // and "how today went" stay independent signals.
                if calendar.isDateInToday(day.date) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Palette.textPrimary.opacity(0.45), lineWidth: 1.5)
                }
            }
    }

    private func color(for state: DayAdherence.State) -> Color {
        switch state {
        case .complete:    Palette.accent
        case .partial:     Palette.accent.opacity(0.45)
        // Amber, never red. A missed dose is information, not an alarm.
        case .missed:      Palette.overdue.opacity(0.75)
        case .skipped:     Palette.textTertiary.opacity(0.4)
        case .upcoming:    Palette.separator.opacity(0.7)
        case .unscheduled: Palette.separator.opacity(0.35)
        }
    }

    private var legend: some View {
        HStack(spacing: Space.m) {
            legendItem("Taken", color: Palette.accent)
            legendItem("Some", color: Palette.accent.opacity(0.45))
            legendItem("Missed", color: Palette.overdue.opacity(0.75))
        }
        .accessibilityHidden(true)
    }

    private func legendItem(_ label: String, color: Color) -> some View {
        HStack(spacing: Space.xs) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessibilityLabel: String {
        let complete = summary.days.filter { $0.state == .complete }.count
        let missed = summary.days.filter { $0.state == .missed }.count
        let partial = summary.days.filter { $0.state == .partial }.count

        var parts = ["Last \(summary.days.count) days"]
        parts.append("\(complete) fully taken")
        if partial > 0 { parts.append("\(partial) partly taken") }
        if missed > 0 { parts.append("\(missed) missed") }
        return parts.joined(separator: ", ")
    }
}
