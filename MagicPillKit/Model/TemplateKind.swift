import Foundation

/// The universal-tracker templates from the manifesto.
///
/// "The UI never changes. Only the icon changes." — a template contributes a
/// symbol, a default colour, and default vocabulary. It contributes no layout
/// and no behaviour, which is what keeps the app from fragmenting as templates
/// are added.
///
/// v1 surfaces only `.medication`. The rest are defined now so the data model
/// never needs a migration to reach them.
public enum TemplateKind: String, CaseIterable, Sendable, Codable, Identifiable {
    case medication
    case exercise
    case water
    case plants
    case petCare
    case maintenance
    case meetings
    case habits

    public var id: String { rawValue }

    /// SF Symbol, deliberately not emoji: symbols tint with the item's colour,
    /// scale with Dynamic Type, and render consistently across OS versions.
    public var symbolName: String {
        switch self {
        case .medication:  "pills.fill"
        case .exercise:    "figure.run"
        case .water:       "drop.fill"
        case .plants:      "leaf.fill"
        case .petCare:     "pawprint.fill"
        case .maintenance: "wrench.and.screwdriver.fill"
        case .meetings:    "calendar"
        case .habits:      "target"
        }
    }

    public var displayName: String {
        switch self {
        case .medication:  "Medication"
        case .exercise:    "Exercise"
        case .water:       "Water"
        case .plants:      "Plants"
        case .petCare:     "Pet Care"
        case .maintenance: "Maintenance"
        case .meetings:    "Meetings"
        case .habits:      "Habits"
        }
    }

    public var defaultColor: ColorToken {
        switch self {
        case .medication:  .sage
        case .exercise:    .apricot
        case .water:       .ocean
        case .plants:      .sage
        case .petCare:     .lavender
        case .maintenance: .stone
        case .meetings:    .ocean
        case .habits:      .lavender
        }
    }

    /// The word used for a single completion, e.g. "dose" for medication.
    /// Presentation vocabulary only — never a behavioural branch.
    public var occurrenceNoun: String {
        switch self {
        case .medication: "dose"
        case .meetings:   "meeting"
        default:          "task"
        }
    }

    /// Templates offered in v1's UI.
    public static var available: [TemplateKind] { [.medication] }
}
