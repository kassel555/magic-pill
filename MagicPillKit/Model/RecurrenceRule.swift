import Foundation

/// How a schedule repeats.
///
/// Stored on `Schedule` as encoded `Data` rather than as separate SwiftData
/// properties: CloudKit mirroring cannot express a sum type, and flattening
/// this into a pile of optional columns invites states that don't mean anything
/// (a weekday set on a monthly rule). Encoding keeps the invalid states
/// unrepresentable.
public enum RecurrenceRule: Sendable, Codable, Hashable {
    /// Every `interval` days. `interval: 1` is the common daily case.
    case daily(interval: Int)

    /// Every `interval` weeks on the given weekdays.
    /// Weekdays are `Calendar` numbering: 1 = Sunday … 7 = Saturday.
    case weekly(interval: Int, weekdays: Set<Int>)

    /// On the given days of the month (1–31). Days past the end of a short
    /// month are skipped rather than clamped — "the 31st" means the 31st.
    case monthly(days: Set<Int>)

    /// No schedule; the user logs it when it happens. Generates no occurrences
    /// and no notifications.
    case asNeeded

    public static let everyDay = RecurrenceRule.daily(interval: 1)

    public var generatesOccurrences: Bool {
        if case .asNeeded = self { return false }
        return true
    }

    public var summary: String {
        switch self {
        case .daily(let interval):
            interval == 1 ? "Every day" : "Every \(interval) days"

        case .weekly(let interval, let weekdays):
            weeklySummary(interval: interval, weekdays: weekdays)

        case .monthly(let days):
            days.count == 1
                ? "Monthly on the \(Self.ordinal(days.first ?? 1))"
                : "Monthly on \(days.sorted().map(Self.ordinal).formatted(.list(type: .and)))"

        case .asNeeded:
            "As needed"
        }
    }

    private func weeklySummary(interval: Int, weekdays: Set<Int>) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        let names = weekdays.sorted().compactMap { weekday -> String? in
            guard (1...7).contains(weekday) else { return nil }
            return symbols[weekday - 1]
        }
        let list = names.formatted(.list(type: .and))
        return interval == 1 ? "Every \(list)" : "Every \(interval) weeks on \(list)"
    }

    private static func ordinal(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    // MARK: - Evaluation

    /// Whether this rule fires on the given day.
    ///
    /// All arithmetic goes through `Calendar` components rather than adding
    /// intervals to a `Date`. Adding 86,400 seconds is *not* a day: across a
    /// DST boundary it drifts by an hour and eventually lands the user's 8:00
    /// AM dose on the wrong day.
    public func occurs(
        on day: Date,
        startDate: Date,
        endDate: Date? = nil,
        calendar: Calendar = .current
    ) -> Bool {
        let dayStart = calendar.startOfDay(for: day)
        let start = calendar.startOfDay(for: startDate)

        guard dayStart >= start else { return false }
        if let endDate, dayStart > calendar.startOfDay(for: endDate) { return false }

        switch self {
        case .daily(let interval):
            guard interval > 0 else { return false }
            let elapsed = calendar.dateComponents([.day], from: start, to: dayStart).day ?? 0
            return elapsed % interval == 0

        case .weekly(let interval, let weekdays):
            guard interval > 0 else { return false }
            guard weekdays.contains(calendar.component(.weekday, from: dayStart)) else {
                return false
            }
            // Compare week boundaries, not raw day counts, so an every-2-weeks
            // rule stays aligned regardless of which weekday it started on.
            let startWeek = calendar.dateInterval(of: .weekOfYear, for: start)?.start ?? start
            let dayWeek = calendar.dateInterval(of: .weekOfYear, for: dayStart)?.start ?? dayStart
            let elapsed = calendar.dateComponents(
                [.weekOfYear], from: startWeek, to: dayWeek
            ).weekOfYear ?? 0
            return elapsed % interval == 0

        case .monthly(let days):
            // Days past the end of a short month are skipped, not clamped:
            // "the 31st" means the 31st, and silently moving a dose to the 28th
            // is a decision the app has no business making.
            return days.contains(calendar.component(.day, from: dayStart))

        case .asNeeded:
            return false
        }
    }

    // MARK: - Storage

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    /// Decodes a stored rule, falling back to a daily rule if the data is
    /// missing or unreadable. A schedule that fails to decode should still
    /// produce a usable item rather than vanishing from the timeline.
    public static func decoded(from data: Data) -> RecurrenceRule {
        guard !data.isEmpty,
              let rule = try? JSONDecoder().decode(RecurrenceRule.self, from: data)
        else { return .everyDay }
        return rule
    }
}
