import SwiftUI
import SwiftData
import MagicPillKit

/// The centrepiece. Not a list of medications — a calm timeline of the day.
///
/// Splits into two views because SwiftData's `@Query` builds its predicate in
/// `init`: the day's fetch lives in `DayTimeline`, which is re-initialised
/// whenever the selected date changes, while this view owns the chrome that
/// must not be torn down on every date change.
struct TimelineView: View {
    /// Called when the user taps a card, with the occurrence they tapped.
    var onSelect: (Occurrence) -> Void = { _ in }

    /// Called when the user taps the settings button.
    var onOpenSettings: () -> Void = {}

    @AppStorage(PreferenceKey.displayName) private var displayName = ""

    @State private var selectedDate: Date = Calendar.current.startOfDay(for: .now)
    @State private var now: Date = .now

    /// Drives the "now" indicator and the overdue state. One minute is ample
    /// precision for a calm timeline and costs essentially nothing.
    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var isShowingToday: Bool {
        Calendar.current.isDate(selectedDate, inSameDayAs: now)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.l)
                .padding(.bottom, Space.l)

            DayStrip(selectedDate: $selectedDate, today: now)
                .padding(.bottom, Space.l)

            DayTimeline(
                date: selectedDate,
                now: now,
                isToday: isShowingToday,
                onSelect: onSelect
            )
        }
        .background(Palette.surface)
        .onReceive(clock) { now = $0 }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            greetingBlock
            Spacer(minLength: Space.m)
            settingsButton
        }
    }

    private var settingsButton: some View {
        Button(action: onOpenSettings) {
            Image(systemName: "gearshape")
                .font(.title3)
                .foregroundStyle(Palette.textSecondary)
                .frame(
                    minWidth: Metrics.minimumTapTarget,
                    minHeight: Metrics.minimumTapTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
        .accessibilityIdentifier(A11y.Timeline.settingsButton)
    }

    private var greetingBlock: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            // `fixedSize` vertically so each line gets its full intrinsic
            // height. Without it the large title's descenders are clipped by a
            // point or two — invisible to the eye, caught by the audit's
            // clipped-text check, and genuinely lossy at larger text sizes.
            Text(title)
                .font(TypeScale.greeting)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .calmAnimation(Motion.subtle, value: title)

            Text(selectedDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(TypeScale.greetingDetail)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// A greeting on today, a plain date heading on any other day — greeting
    /// someone "Good Morning" while they look at next Tuesday is the kind of
    /// small wrongness that makes an app feel machine-made.
    private var title: String {
        guard isShowingToday else {
            return selectedDate.formatted(.dateTime.weekday(.wide))
        }

        let greeting = switch Calendar.current.component(.hour, from: now) {
        case 0..<12:  "Good Morning"
        case 12..<17: "Good Afternoon"
        default:      "Good Evening"
        }

        // No name is a perfectly good outcome — onboarding lets it be skipped,
        // and a trailing comma with nothing after it is worse than no name.
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? greeting : "\(greeting), \(name)"
    }
}

// MARK: - The day's timeline

private struct DayTimeline: View {
    @Environment(\.modelContext) private var context
    @Environment(ScheduleCoordinator.self) private var coordinator
    @Query private var occurrences: [Occurrence]

    let now: Date
    let isToday: Bool
    let onSelect: (Occurrence) -> Void

    private let day: Date

    init(date: Date, now: Date, isToday: Bool, onSelect: @escaping (Occurrence) -> Void) {
        self.now = now
        self.isToday = isToday
        self.onSelect = onSelect

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        self.day = start
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start

        _occurrences = Query(
            filter: #Predicate<Occurrence> { occurrence in
                occurrence.scheduledAt >= start && occurrence.scheduledAt < end
            },
            sort: \Occurrence.scheduledAt,
            order: .forward
        )
    }

    var body: some View {
        // A `List`, not a `ScrollView` + `LazyVStack`.
        //
        // `.swipeActions` is a List-only modifier: applied to a row inside a
        // stack it compiles, renders nothing, and silently does nothing. The
        // timeline spent four phases with a swipe-to-complete gesture that had
        // never once worked, which a UI test caught and no unit test could.
        //
        // Every list affordance is then stripped back so the timeline still
        // looks like a timeline rather than a settings screen.
        List {
            if occurrences.isEmpty {
                emptyState
                    .padding(.horizontal, Space.xl)
                    .padding(.top, Space.xxxl)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                summary
                    .padding(.horizontal, Space.xl)
                    .padding(.bottom, Space.l)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                ForEach(Array(occurrences.enumerated()), id: \.element.id) { index, occurrence in
                    if showsNowIndicator(before: index) {
                        NowIndicator(now: now)
                            .plainTimelineRow()
                    }

                    TimelineRow(
                        occurrence: occurrence,
                        showsTime: showsTime(at: index),
                        isFirst: index == 0,
                        isLast: index == occurrences.count - 1,
                        onResolve: { resolve(occurrence, as: $0) },
                        onSnooze: { snooze(occurrence) },
                        onSelect: { onSelect(occurrence) }
                    )
                    .plainTimelineRow()
                }

                // The indicator belongs after every row once the day's
                // last item is behind us.
                if showsNowIndicator(before: occurrences.count) {
                    NowIndicator(now: now)
                        .plainTimelineRow()
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .calmAnimation(Motion.reflow, value: occurrences.map(\.stateRaw))
        // Generate the day's rows on demand. Phase 4 replaces this with the
        // rolling-window engine that materialises ahead of time in the
        // background; until then, a day gets its rows when it's first viewed.
        .task(id: day) {
            do {
                try OccurrenceMaterializer.materialize(day: day, context: context)
            } catch {
                print("[MagicPill] Failed to materialize \(day): \(error)")
            }
        }
    }

    // MARK: Summary

    private var summary: some View {
        let remaining = occurrences.filter { !$0.isResolved }.count
        let total = occurrences.count
        let progress = total == 0 ? 0 : Double(total - remaining) / Double(total)

        return HStack(spacing: Space.m) {
            ProgressRing(progress: progress)
                .frame(width: 26, height: 26)

            Text(remaining == 0 ? "All done" : "\(remaining) of \(total) remaining")
                .font(TypeScale.greetingDetail)
                .foregroundStyle(Palette.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(A11y.Timeline.summary)
    }

    private var emptyState: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "sun.horizon")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Palette.textTertiary)
            Text("Nothing scheduled")
                .font(TypeScale.itemName)
                .foregroundStyle(Palette.textSecondary)
            Text("This day is clear.")
                .font(TypeScale.itemNote)
                .foregroundStyle(Palette.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(A11y.Timeline.emptyState)
    }

    // MARK: Layout logic

    /// Only the first occurrence at a given time shows its time label, so
    /// several items at 8:00 read as one moment rather than a repeated stamp.
    private func showsTime(at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = occurrences[index - 1].effectiveTime
        let current = occurrences[index].effectiveTime
        return !Calendar.current.isDate(previous, equalTo: current, toGranularity: .minute)
    }

    /// True when `now` falls between the previous row's time and this one's —
    /// i.e. the indicator belongs in this gap. Only ever shown on today.
    private func showsNowIndicator(before index: Int) -> Bool {
        guard isToday, !occurrences.isEmpty else { return false }

        let previousTime = index > 0 ? occurrences[index - 1].effectiveTime : Date.distantPast
        let nextTime = index < occurrences.count ? occurrences[index].effectiveTime : Date.distantFuture

        return previousTime <= now && now < nextTime
    }

    // MARK: Actions

    private func resolve(_ occurrence: Occurrence, as state: OccurrenceState) {
        let id = occurrence.id
        occurrence.state = state
        occurrence.resolvedAt = .now
        occurrence.snoozedUntil = nil
        save()

        // Cancel immediately rather than waiting for the next sync: a dose
        // taken at 07:58 must not ring at 08:00.
        Task { await coordinator.cancelNotification(for: id) }
    }

    private func snooze(_ occurrence: Occurrence) {
        occurrence.snoozedUntil = SnoozeDefaults.nextTime()
        save()

        // A full re-sync, not a single reschedule: the snoozed row re-enters
        // the budget at a new position and may displace something else.
        Task { await coordinator.syncNotifications() }
    }

    private func save() {
        do {
            try context.save()
        } catch {
            // Surfaced properly in Phase 3 alongside the editor's error handling.
            print("[MagicPill] Failed to save: \(error)")
        }
    }
}

private extension View {
    /// Strips a `List` row back to bare content: no inset, no background, no
    /// separator, no minimum height. What's left is the timeline's own layout,
    /// with native swipe actions still available.
    func plainTimelineRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

// MARK: - Now indicator

/// A hairline marking the present moment. Subtle by design — it orients, it
/// doesn't nag.
private struct NowIndicator: View {
    let now: Date

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var gutterWidth = Metrics.timeGutter

    // Deliberately no visible time.
    //
    // It used to print the current time in the gutter, and it was the single
    // element in the app the Dynamic Type audit would not pass — using the same
    // font as every other time label, flagged here and nowhere else, through
    // five attempted fixes.
    //
    // Rather than suppress the check, the label came out. It was redundant
    // chrome: the status bar shows the clock two inches above it, and this
    // indicator's job is to mark a *position* on the timeline, not to report
    // the time. What remains is a dot and a hairline — closer to the
    // manifesto's minimalism than what it replaced.
    //
    // The time is still announced to VoiceOver, where it is not redundant.
    var body: some View {
        HStack(alignment: .center, spacing: Space.s) {
            if !typeSize.prefersStackedTimeline {
                Color.clear
                    .frame(width: gutterWidth, height: 1)

                Circle()
                    .fill(Palette.accent)
                    .frame(width: 5, height: 5)
                    .frame(width: Metrics.timelineNode)
            }

            Rectangle()
                .fill(Palette.accent.opacity(0.35))
                .frame(height: 1)
                .padding(.trailing, Space.xl)
        }
        .padding(.leading, typeSize.prefersStackedTimeline ? Space.xl : 0)
        .padding(.vertical, Space.s)
        // Hidden from accessibility, not merely unlabelled.
        //
        // It used to carry a "Now, 6:25 AM" label, which made a 17pt-tall
        // hairline a focusable element — and the audit correctly flagged it as
        // a target too small to interact with. The indicator is decoration: it
        // orients the eye. Every card already announces its own time, and
        // pending/overdue state tells a VoiceOver user where the day has got
        // to, so nothing is lost by taking it out of the tree.
        .accessibilityHidden(true)
    }
}

// MARK: - Row

/// One row: the time gutter, the timeline rule, and the card.
private struct TimelineRow: View {
    let occurrence: Occurrence
    let showsTime: Bool
    let isFirst: Bool
    let isLast: Bool
    let onResolve: (OccurrenceState) -> Void
    let onSnooze: () -> Void
    let onSelect: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    /// The gutter grows with the text it holds. Without this the time wraps
    /// well before accessibility sizes are reached.
    @ScaledMetric(relativeTo: .subheadline) private var gutterWidth = Metrics.timeGutter

    var body: some View {
        if typeSize.prefersStackedTimeline {
            stackedLayout
        } else {
            gutterLayout
        }
    }

    /// The default: time gutter, rule, card.
    private var gutterLayout: some View {
        HStack(alignment: .top, spacing: Space.s) {
            timeLabel(alignment: .trailing)
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.top, occurrence.isResolved ? Space.m : Space.l)

            TimelineRule(
                token: occurrence.item?.colorToken ?? .stone,
                isResolved: occurrence.isResolved,
                showsTopSegment: !isFirst,
                showsBottomSegment: !isLast
            )

            card
                .padding(.trailing, Space.xl)
                .padding(.bottom, Space.m)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Accessibility sizes: the time sits above its card at full width. The
    /// timeline rule is dropped rather than squeezed — at these sizes it would
    /// be decoration competing for space the content needs, and it was always
    /// hidden from VoiceOver anyway.
    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            timeLabel(alignment: .leading)

            card
        }
        .padding(.horizontal, Space.xl)
        .padding(.bottom, Space.l)
    }

    private var card: some View {
        OccurrenceCard(
            occurrence: occurrence,
            onResolve: onResolve,
            onSnooze: onSnooze,
            onSelect: onSelect
        )
    }

    @ViewBuilder
    private func timeLabel(alignment: HorizontalAlignment) -> some View {
        if showsTime {
            VStack(alignment: alignment, spacing: 2) {
                Text(occurrence.effectiveTime.formatted(date: .omitted, time: .shortened))
                    .font(TypeScale.time)
                    // Was `lineLimit(1)` + `minimumScaleFactor(0.8)`, which
                    // shrinks text below the size the user asked for. The
                    // gutter is `@ScaledMetric` and the layout stacks entirely
                    // at accessibility sizes, so the time can simply be allowed
                    // its natural width.
                    .fixedSize()
                    .foregroundStyle(
                        occurrence.isResolved ? Palette.textTertiary : Palette.textSecondary
                    )

                if occurrence.snoozedUntil != nil {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(Palette.overdueText)
                }
            }
            .accessibilityHidden(true)
        } else {
            Color.clear.frame(height: 1)
        }
    }
}

#Preview {
    NavigationStack {
        TimelineView()
    }
    .modelContainer(MockData.populatedContainer())
}
