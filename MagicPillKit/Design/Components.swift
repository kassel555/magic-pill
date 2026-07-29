import SwiftUI

/// The symbol well on a card: the item's SF Symbol on a wash of its own colour.
/// This is the only place an item's identity colour appears at any weight —
/// keeping colour concentrated here is what stops the timeline turning into a
/// fruit salad.
public struct SymbolWell: View {
    private let symbolName: String
    private let token: ColorToken
    private let isDimmed: Bool

    public init(symbolName: String, token: ColorToken, isDimmed: Bool = false) {
        self.symbolName = symbolName
        self.token = token
        self.isDimmed = isDimmed
    }

    public var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(isDimmed ? Palette.textTertiary : token.color)
            .frame(width: Metrics.symbolWell, height: Metrics.symbolWell)
            .background(
                RoundedRectangle(cornerRadius: Radius.well, style: .continuous)
                    .fill(isDimmed ? Color.clear : token.wash)
            )
            .accessibilityHidden(true)
    }
}

/// A soft progress ring. Used for the day's completion and, later, adherence.
/// No percentage label by default — the manifesto asks for calm, not statistics.
public struct ProgressRing: View {
    private let progress: Double
    private let token: ColorToken
    private let lineWidth: CGFloat

    public init(progress: Double, token: ColorToken = .sage, lineWidth: CGFloat = 5) {
        self.progress = min(max(progress, 0), 1)
        self.token = token
        self.lineWidth = lineWidth
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.separator, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    token.color,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .calmAnimation(Motion.progress, value: progress)
        .accessibilityHidden(true)
    }
}

/// The vertical rule and node that make the timeline a timeline rather than a
/// list. Drawn per row so rows can be added and removed without the rule
/// needing to know the whole collection.
public struct TimelineRule: View {
    private let token: ColorToken
    private let isResolved: Bool
    private let showsTopSegment: Bool
    private let showsBottomSegment: Bool

    public init(
        token: ColorToken,
        isResolved: Bool,
        showsTopSegment: Bool,
        showsBottomSegment: Bool
    ) {
        self.token = token
        self.isResolved = isResolved
        self.showsTopSegment = showsTopSegment
        self.showsBottomSegment = showsBottomSegment
    }

    public var body: some View {
        VStack(spacing: 0) {
            segment(visible: showsTopSegment)
                .frame(height: Space.l)

            node

            segment(visible: showsBottomSegment)
                .frame(maxHeight: .infinity)
        }
        .frame(width: Metrics.timelineNode)
        .accessibilityHidden(true)
    }

    private var node: some View {
        Circle()
            .fill(isResolved ? Palette.separator : token.color)
            .frame(width: Metrics.timelineNode, height: Metrics.timelineNode)
    }

    private func segment(visible: Bool) -> some View {
        Rectangle()
            .fill(visible ? Palette.separator : Color.clear)
            .frame(width: Metrics.timelineRule)
    }
}
