import SwiftUI
import MagicPillKit

/// Times of day and repeat rule.
///
/// Progressive disclosure is doing real work here: the repeat picker defaults
/// to "Every day" and the weekday and monthly controls only appear when they're
/// relevant. A user adding a once-daily tablet sees two rows, not twelve.
struct ScheduleEditor: View {
    @Binding var draft: ItemDraft

    @State private var showingTimePicker = false
    @State private var newTime = Date.now
    @State private var hasEndDate = false

    var body: some View {
        Section {
            ForEach(draft.timesOfDay.sorted(), id: \.self) { minutes in
                HStack {
                    Label(
                        TimeOfDay.format(minutes),
                        systemImage: "clock"
                    )
                    .foregroundStyle(Palette.textPrimary)

                    Spacer()

                    // Never let the user delete the last time — an item with no
                    // times would sit in the store generating nothing, looking
                    // broken rather than intentional.
                    if draft.timesOfDay.count > 1 {
                        Button {
                            draft.timesOfDay.removeAll { $0 == minutes }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(Palette.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(TimeOfDay.format(minutes))")
                    }
                }
            }

            Button {
                newTime = .now
                showingTimePicker = true
            } label: {
                Label("Add a time", systemImage: "plus.circle")
            }
        } header: {
            Text("Times")
        } footer: {
            if draft.timesOfDay.count > 1 {
                Text("\(draft.timesOfDay.count) times a day.")
            }
        }

        Section {
            Picker("Repeat", selection: repeatKindBinding) {
                ForEach(RepeatKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }

            switch draft.rule {
            case .daily(let interval):
                if interval > 1 {
                    Stepper(
                        "Every \(interval) days",
                        value: dailyIntervalBinding,
                        in: 2...30
                    )
                }

            case .weekly:
                WeekdayPicker(rule: $draft.rule)

            case .monthly(let days):
                Text(days.isEmpty ? "Pick a day below" : "On the \(sortedDayList(days))")
                    .font(TypeScale.itemNote)
                    .foregroundStyle(Palette.textSecondary)
                MonthDayPicker(rule: $draft.rule)

            case .asNeeded:
                Text("No reminders. You log this when it happens.")
                    .font(TypeScale.itemNote)
                    .foregroundStyle(Palette.textSecondary)
            }
        } header: {
            Text("Repeat")
        }

        Section {
            DatePicker("Starts", selection: $draft.startDate, displayedComponents: .date)

            Toggle("Has an end date", isOn: $hasEndDate)

            if hasEndDate {
                DatePicker(
                    "Ends",
                    selection: .init(
                        get: { draft.endDate ?? draft.startDate },
                        set: { draft.endDate = $0 }
                    ),
                    in: draft.startDate...,
                    displayedComponents: .date
                )
            }
        } header: {
            Text("Dates")
        }
        .onAppear { hasEndDate = draft.endDate != nil }
        .onChange(of: hasEndDate) { _, isOn in
            draft.endDate = isOn ? (draft.endDate ?? draft.startDate) : nil
        }
        .sheet(isPresented: $showingTimePicker) {
            TimeAdditionSheet(time: $newTime) { minutes in
                if !draft.timesOfDay.contains(minutes) {
                    draft.timesOfDay.append(minutes)
                    draft.timesOfDay.sort()
                }
            }
        }
    }

    // MARK: - Bindings

    /// Maps the rule's case to the picker without losing the configuration of
    /// the case being switched away from any more than necessary.
    private var repeatKindBinding: Binding<RepeatKind> {
        Binding(
            get: { RepeatKind(rule: draft.rule) },
            set: { kind in
                switch kind {
                case .daily:
                    draft.rule = .everyDay
                case .everyNDays:
                    draft.rule = .daily(interval: 2)
                case .weekly:
                    let weekday = Calendar.current.component(.weekday, from: draft.startDate)
                    draft.rule = .weekly(interval: 1, weekdays: [weekday])
                case .monthly:
                    let day = Calendar.current.component(.day, from: draft.startDate)
                    draft.rule = .monthly(days: [day])
                case .asNeeded:
                    draft.rule = .asNeeded
                }
            }
        )
    }

    private var dailyIntervalBinding: Binding<Int> {
        Binding(
            get: {
                if case .daily(let interval) = draft.rule { return interval }
                return 1
            },
            set: { draft.rule = .daily(interval: $0) }
        )
    }

    private func sortedDayList(_ days: Set<Int>) -> String {
        days.sorted().map(String.init).formatted(.list(type: .and))
    }
}

// MARK: - Repeat kinds

private enum RepeatKind: CaseIterable {
    case daily
    case everyNDays
    case weekly
    case monthly
    case asNeeded

    init(rule: RecurrenceRule) {
        switch rule {
        case .daily(let interval): self = interval == 1 ? .daily : .everyNDays
        case .weekly:              self = .weekly
        case .monthly:             self = .monthly
        case .asNeeded:            self = .asNeeded
        }
    }

    var displayName: String {
        switch self {
        case .daily:      "Every day"
        case .everyNDays: "Every few days"
        case .weekly:     "Certain weekdays"
        case .monthly:    "Certain dates"
        case .asNeeded:   "As needed"
        }
    }
}

// MARK: - Weekday picker

private struct WeekdayPicker: View {
    @Binding var rule: RecurrenceRule

    private var weekdays: Set<Int> {
        if case .weekly(_, let days) = rule { return days }
        return []
    }

    private var interval: Int {
        if case .weekly(let interval, _) = rule { return interval }
        return 1
    }

    /// Ordered by the user's locale, so weeks start on Monday or Sunday as
    /// their region expects.
    private var orderedWeekdays: [Int] {
        let calendar = Calendar.current
        let first = calendar.firstWeekday
        return (0..<7).map { ((first - 1 + $0) % 7) + 1 }
    }

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(orderedWeekdays, id: \.self) { weekday in
                let isOn = weekdays.contains(weekday)
                Button {
                    toggle(weekday)
                } label: {
                    // `minWidth`/`minHeight`, not fixed: a hard 36×36 frame
                    // stops the label growing with Dynamic Type, which the
                    // accessibility audit flags as unchangeable font size.
                    Text(Calendar.current.veryShortWeekdaySymbols[weekday - 1])
                        .font(.footnote.weight(isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? Color.white : Palette.textSecondary)
                        .padding(Space.s)
                        .frame(minWidth: 36, minHeight: 36)
                        .background(
                            Circle().fill(isOn ? Palette.accent : Palette.separator.opacity(0.5))
                        )
                        .frame(minHeight: Metrics.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Calendar.current.weekdaySymbols[weekday - 1])
                .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
            }
        }
        .frame(maxWidth: .infinity)
        .calmAnimation(Motion.subtle, value: weekdays)
    }

    private func toggle(_ weekday: Int) {
        var updated = weekdays
        if updated.contains(weekday) {
            // Refuse to empty the set: a weekly rule with no weekdays fires
            // never, which looks like a bug rather than a choice.
            guard updated.count > 1 else { return }
            updated.remove(weekday)
        } else {
            updated.insert(weekday)
        }
        rule = .weekly(interval: interval, weekdays: updated)
    }
}

// MARK: - Month day picker

private struct MonthDayPicker: View {
    @Binding var rule: RecurrenceRule

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Space.xs), count: 7)

    private var days: Set<Int> {
        if case .monthly(let days) = rule { return days }
        return []
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: Space.xs) {
            ForEach(1...31, id: \.self) { day in
                let isOn = days.contains(day)
                Button {
                    toggle(day)
                } label: {
                    Text("\(day)")
                        .font(.footnote.weight(isOn ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(isOn ? Color.white : Palette.textSecondary)
                        .padding(.vertical, Space.xs)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.well * 0.6, style: .continuous)
                                .fill(isOn ? Palette.accent : Palette.separator.opacity(0.4))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Day \(day)")
                .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(.vertical, Space.xs)
        .calmAnimation(Motion.subtle, value: days)
    }

    private func toggle(_ day: Int) {
        var updated = days
        if updated.contains(day) {
            guard updated.count > 1 else { return }
            updated.remove(day)
        } else {
            updated.insert(day)
        }
        rule = .monthly(days: updated)
    }
}

// MARK: - Time addition

private struct TimeAdditionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var time: Date
    let onAdd: (Int) -> Void

    var body: some View {
        NavigationStack {
            VStack {
                DatePicker(
                    "Time",
                    selection: $time,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.wheel)
                .labelsHidden()

                Spacer()
            }
            .padding(.top, Space.xl)
            .background(Palette.surface)
            .navigationTitle("Add a Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                        onAdd(TimeOfDay.minutes(
                            hour: parts.hour ?? 8,
                            minute: parts.minute ?? 0
                        ))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .tint(Palette.accentText)
        }
        .presentationDetents([.medium])
    }
}
