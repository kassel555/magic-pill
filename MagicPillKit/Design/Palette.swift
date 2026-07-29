import SwiftUI

/// The colour system from the design manifesto: restrained, muted, never clinical.
///
/// Defined in code rather than an asset catalog so every light/dark pair is
/// visible and reviewable in one place. Each token resolves through a dynamic
/// `UIColor`, so it adapts to the trait environment exactly as an asset colour
/// would — including in widgets.
public enum ColorToken: String, CaseIterable, Sendable, Codable {
    case sage
    case ocean
    case lavender
    case apricot
    case stone

    public var color: Color { Color(uiColor: uiColor) }

    public var uiColor: UIColor {
        switch self {
        case .sage:     Palette.dynamic(light: 0x7C9A80, dark: 0x8FB093)
        case .ocean:    Palette.dynamic(light: 0x6B8CAE, dark: 0x82A3C4)
        case .lavender: Palette.dynamic(light: 0x9186B0, dark: 0xA79CC4)
        case .apricot:  Palette.dynamic(light: 0xC99A6B, dark: 0xD9AC7E)
        case .stone:    Palette.dynamic(light: 0x8A8580, dark: 0x9C9691)
        }
    }

    /// A very low-contrast wash of the token, for card backgrounds and symbol wells.
    public var wash: Color {
        Color(uiColor: Palette.resolving { traits in
            let base = uiColor.resolvedColor(with: traits)
            let alpha = traits.userInterfaceStyle == .dark ? 0.18 : 0.10
            return base.withAlphaComponent(alpha)
        })
    }

    public var displayName: String {
        switch self {
        case .sage:     "Sage"
        case .ocean:    "Ocean"
        case .lavender: "Lavender"
        case .apricot:  "Apricot"
        case .stone:    "Stone"
        }
    }
}

/// Semantic colours. Views use these; they never reach for a `ColorToken` directly
/// except to express an item's own identity colour.
public enum Palette {

    /// The page behind everything. Warm off-white, not pure white — pure white
    /// reads as clinical, which the manifesto explicitly rejects.
    public static let surface = Color(uiColor: dynamic(light: 0xFBFAF8, dark: 0x121110))

    /// Cards and raised surfaces.
    public static let surfaceElevated = Color(uiColor: dynamic(light: 0xFFFFFF, dark: 0x1E1C1A))

    // Text tokens are tuned to clear 4.5:1 against their surface in both
    // appearances — verified by `performAccessibilityAudit` in the UI tests,
    // which failed on the original, prettier values.
    //
    // "Muted" in the design manifesto means low *saturation*, not low
    // contrast. Grey-on-grey that a designer reads as restraint is simply
    // unreadable to anyone with reduced vision, and this app's whole job is
    // telling people when to take medication.
    public static let textPrimary = Color(uiColor: dynamic(light: 0x1F1D1B, dark: 0xF2F0ED))
    public static let textSecondary = Color(uiColor: dynamic(light: 0x5F5B56, dark: 0xA9A29B))
    public static let textTertiary = Color(uiColor: dynamic(light: 0x767169, dark: 0x8E8882))

    /// Hairlines and the timeline rule.
    public static let separator = Color(uiColor: dynamic(light: 0xE5E1DB, dark: 0x2C2A27))

    /// The accent for *fills* — buttons, rings, timeline nodes — where the
    /// colour sits under white or stands alone.
    public static let accent = ColorToken.sage.color

    /// The accent for coloured **text**, which needs far more contrast than a
    /// fill does. Sage at its display value is about 3:1 on the light surface:
    /// fine behind a white glyph, unreadable as small type.
    public static let accentText = Color(uiColor: dynamic(light: 0x4F6B54, dark: 0x9FBFA3))

    /// Overdue is a soft amber. The manifesto says no bright reds — this is the
    /// token that enforces it, so "overdue" can never quietly become red.
    public static let overdue = ColorToken.apricot.color

    /// Overdue as text. Apricot is ~2.5:1 on the light surface; this is the
    /// same hue taken down until it's legible.
    public static let overdueText = Color(uiColor: dynamic(light: 0x8A5E30, dark: 0xE0B98F))

    /// The single genuine red in the app, reserved for destructive confirmation.
    public static let destructive = Color(uiColor: dynamic(light: 0xC0554D, dark: 0xD4695F))

    // MARK: - Construction

    static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        resolving { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        }
    }

    static func resolving(_ body: @escaping @Sendable (UITraitCollection) -> UIColor) -> UIColor {
        UIColor { traits in body(traits) }
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
