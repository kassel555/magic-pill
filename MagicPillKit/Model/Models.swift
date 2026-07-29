import Foundation
import SwiftData

// MARK: - CloudKit compliance
//
// Every model below obeys SwiftData's CloudKit mirroring rules. These are hard
// requirements, not style preferences — violating any one of them fails at
// container initialisation with an error that reads like a generic crash:
//
//   1. Every stored property has a default value or is optional.
//   2. No @Attribute(.unique) anywhere. Uniqueness is enforced in code.
//   3. Every relationship is optional and declares an inverse.
//   4. No .deny delete rules.
//
// If you add a property, give it a default. If you add a relationship, make it
// optional.

/// A thing the user tracks. Deliberately generic — nothing here says
/// "medication". A medication is a `TrackedItem` whose template is
/// `.medication`, which is what lets the app grow into the universal tracker
/// without a migration.
@Model
public final class TrackedItem {
    public var id: UUID = UUID()
    public var name: String = ""

    /// Backing store for `template`. Raw strings rather than the enum because
    /// an unknown future value must decode to *something* rather than fail.
    public var templateRaw: String = TemplateKind.medication.rawValue

    /// Dosage or amount, e.g. "1 Tablet".
    public var detail: String = ""

    /// Freeform instruction, e.g. "Take with breakfast".
    public var note: String = ""

    public var colorTokenRaw: String = ColorToken.sage.rawValue

    /// Overrides the template's symbol when non-empty.
    public var symbolNameOverride: String = ""

    /// Archived items keep their history but generate no new occurrences.
    public var isArchived: Bool = false

    public var createdAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \Schedule.item)
    public var schedules: [Schedule]? = []

    @Relationship(deleteRule: .cascade, inverse: \Occurrence.item)
    public var occurrences: [Occurrence]? = []

    public init(
        id: UUID = UUID(),
        name: String,
        template: TemplateKind = .medication,
        detail: String = "",
        note: String = "",
        color: ColorToken? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.templateRaw = template.rawValue
        self.detail = detail
        self.note = note
        self.colorTokenRaw = (color ?? template.defaultColor).rawValue
        self.symbolNameOverride = ""
        self.isArchived = false
        self.createdAt = createdAt
        self.schedules = []
        self.occurrences = []
    }

    // MARK: Typed accessors
    //
    // Views and logic use these, never the raw strings. An unrecognised stored
    // value degrades to a sensible default instead of crashing.

    public var template: TemplateKind {
        get { TemplateKind(rawValue: templateRaw) ?? .medication }
        set { templateRaw = newValue.rawValue }
    }

    public var colorToken: ColorToken {
        get { ColorToken(rawValue: colorTokenRaw) ?? .sage }
        set { colorTokenRaw = newValue.rawValue }
    }

    public var symbolName: String {
        symbolNameOverride.isEmpty ? template.symbolName : symbolNameOverride
    }

    public var activeSchedules: [Schedule] {
        (schedules ?? []).filter { !$0.isPaused }
    }
}

/// When a `TrackedItem` recurs. An item may have several — "twice daily on
/// weekdays, once on weekends" is two schedules, not one baroque rule.
@Model
public final class Schedule {
    public var id: UUID = UUID()
    public var item: TrackedItem?

    /// Encoded `RecurrenceRule`. See that type for why it's stored this way.
    public var ruleData: Data = RecurrenceRule.everyDay.encoded()

    /// Times of day as minutes from local midnight, e.g. `[480, 1140]` for
    /// 8:00 AM and 7:00 PM.
    ///
    /// Stored as local wall-clock minutes rather than absolute dates so that
    /// "8:00 AM" stays 8:00 AM across DST boundaries and time-zone travel.
    /// Resolution to an absolute `Date` happens at materialisation time.
    public var timesOfDay: [Int] = [480]

    public var startDate: Date = Date.now
    public var endDate: Date?
    public var isPaused: Bool = false

    public init(
        id: UUID = UUID(),
        rule: RecurrenceRule = .everyDay,
        timesOfDay: [Int] = [480],
        startDate: Date = .now,
        endDate: Date? = nil,
        isPaused: Bool = false
    ) {
        self.id = id
        self.ruleData = rule.encoded()
        self.timesOfDay = timesOfDay.sorted()
        self.startDate = startDate
        self.endDate = endDate
        self.isPaused = isPaused
    }

    public var rule: RecurrenceRule {
        get { RecurrenceRule.decoded(from: ruleData) }
        set { ruleData = newValue.encoded() }
    }

    public var summary: String {
        let times = timesOfDay.sorted().map { TimeOfDay.format($0) }.formatted(.list(type: .and))
        return timesOfDay.isEmpty ? rule.summary : "\(rule.summary) at \(times)"
    }
}

/// One concrete, dated instance of a `TrackedItem` — a single row on the
/// timeline. Generated from a `Schedule` by the materialiser, or created
/// directly for an as-needed log.
@Model
public final class Occurrence {
    public var id: UUID = UUID()
    public var item: TrackedItem?

    /// The absolute moment this is due, resolved from the schedule's local
    /// wall-clock time at materialisation.
    public var scheduledAt: Date = Date.now

    public var stateRaw: String = OccurrenceState.pending.rawValue

    /// When the user resolved it. Nil while pending.
    public var resolvedAt: Date?

    public var snoozedUntil: Date?

    /// Which schedule produced this. Used to reconcile future occurrences when
    /// a schedule is edited, without touching resolved history.
    public var generatedFromScheduleID: UUID?

    public init(
        id: UUID = UUID(),
        item: TrackedItem? = nil,
        scheduledAt: Date,
        state: OccurrenceState = .pending,
        generatedFromScheduleID: UUID? = nil
    ) {
        self.id = id
        self.item = item
        self.scheduledAt = scheduledAt
        self.stateRaw = state.rawValue
        self.generatedFromScheduleID = generatedFromScheduleID
    }

    public var state: OccurrenceState {
        get { OccurrenceState(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue }
    }

    /// The time this should appear at, accounting for a snooze.
    public var effectiveTime: Date {
        snoozedUntil ?? scheduledAt
    }

    public var isResolved: Bool { state.isResolved }

    /// Pending and more than a grace period past due.
    ///
    /// `missed` is derived here rather than being a stored state the user sets:
    /// nothing in the app should ever write "you missed this" as an action.
    public func isOverdue(now: Date = .now, grace: TimeInterval = 30 * 60) -> Bool {
        state == .pending && effectiveTime.addingTimeInterval(grace) < now
    }
}

public enum OccurrenceState: String, Sendable, Codable, CaseIterable {
    case pending
    case taken
    case skipped
    /// Derived by a sweep, never chosen by the user.
    case missed

    public var isResolved: Bool { self != .pending }

    public var displayName: String {
        switch self {
        case .pending: "Pending"
        case .taken:   "Taken"
        case .skipped: "Skipped"
        case .missed:  "Missed"
        }
    }
}

/// Helpers for the minutes-from-midnight representation used by `Schedule`.
public enum TimeOfDay {
    public static func minutes(hour: Int, minute: Int = 0) -> Int {
        hour * 60 + minute
    }

    public static func components(from minutes: Int) -> (hour: Int, minute: Int) {
        (hour: minutes / 60, minute: minutes % 60)
    }

    /// Formats using the user's locale, so 12-hour and 24-hour regions both
    /// read naturally.
    public static func format(_ minutes: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let parts = components(from: minutes)
        var components = DateComponents()
        components.hour = parts.hour
        components.minute = parts.minute
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(.dateTime.hour().minute().locale(locale))
    }
}
