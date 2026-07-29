import SwiftUI

/// Spacing scale. Generous by default — "lots of whitespace" is a manifesto
/// requirement, so the scale starts where a denser app would already be at its
/// second step.
public enum Space {
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let xxxl: CGFloat = 48
}

public enum Radius {
    public static let card: CGFloat = 20
    public static let well: CGFloat = 12
    public static let pill: CGFloat = 999
}

/// Fixed layout dimensions shared between the timeline and the widgets.
public enum Metrics {
    /// Width of the time gutter down the left of the timeline.
    ///
    /// Sized for the *widest* time string — a two-digit 12-hour time with a
    /// meridiem, "10:49 AM" — not the typical one. At 62pt it fitted "6:30 AM"
    /// and overflowed anything longer, which the accessibility audit caught as
    /// clipped text at the left edge.
    public static let timeGutter: CGFloat = 72
    /// Diameter of the node dot on the timeline rule.
    public static let timelineNode: CGFloat = 9
    /// Width of the timeline rule itself.
    public static let timelineRule: CGFloat = 1.5
    /// Size of the symbol well on a card.
    public static let symbolWell: CGFloat = 40
    /// Minimum tap target. The manifesto calls out "no tiny buttons"; this is
    /// the Apple HIG floor and nothing interactive may go below it.
    public static let minimumTapTarget: CGFloat = 44
}

/// Typography. Things 3's discipline: a tight scale, all of it Dynamic Type
/// aware. Nothing in the app uses a fixed point size.
public enum TypeScale {
    /// "Good Morning Rahul"
    public static let greeting = Font.largeTitle.weight(.semibold)
    /// Date subtitle under the greeting.
    public static let greetingDetail = Font.subheadline.weight(.medium)
    /// Time labels in the gutter.
    public static let time = Font.subheadline.weight(.medium).monospacedDigit()
    /// Item name on a card.
    public static let itemName = Font.headline.weight(.semibold)
    /// "1 Tablet"
    public static let itemDetail = Font.subheadline
    /// "Take with breakfast"
    public static let itemNote = Font.footnote
    /// Section headers.
    public static let sectionHeader = Font.title3.weight(.semibold)
}

public extension DynamicTypeSize {
    /// At accessibility text sizes the timeline abandons its time gutter and
    /// stacks instead: a fixed-width gutter cannot hold "6:30 AM" once the text
    /// is three times its normal size, and forcing it to produces a column of
    /// single characters.
    ///
    /// This is a layout change, not a type-size clamp — the text stays as large
    /// as the user asked for.
    var prefersStackedTimeline: Bool { isAccessibilitySize }
}

/// Motion. The manifesto is explicit: smooth, slow, natural, and no confetti.
///
/// Every animation here must be routed through `Motion.respectingReduceMotion`
/// so Reduce Motion degrades to a cross-fade rather than being ignored.
public enum Motion {
    /// Card completion and removal. Settles without visible bounce.
    public static let completion = Animation.spring(response: 0.45, dampingFraction: 0.85)
    /// Timeline re-flow after a row leaves.
    public static let reflow = Animation.spring(response: 0.5, dampingFraction: 0.9)
    /// Progress ring fill.
    public static let progress = Animation.easeInOut(duration: 0.8)
    /// Small state changes — a chevron, a colour shift.
    public static let subtle = Animation.easeInOut(duration: 0.22)

    /// The Reduce Motion fallback: no movement, just a gentle fade.
    public static let reduced = Animation.easeInOut(duration: 0.2)

    public static func respectingReduceMotion(
        _ animation: Animation,
        reduceMotion: Bool
    ) -> Animation {
        reduceMotion ? reduced : animation
    }
}

public extension View {
    /// Applies an animation that automatically degrades under Reduce Motion.
    func calmAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(CalmAnimation(animation: animation, value: value))
    }
}

private struct CalmAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(
            Motion.respectingReduceMotion(animation, reduceMotion: reduceMotion),
            value: value
        )
    }
}
