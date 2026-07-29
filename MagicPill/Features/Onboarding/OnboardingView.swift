import SwiftUI
import MagicPillKit

/// First run.
///
/// Three screens, and it asks for exactly one thing. The manifesto wants
/// "polished consumer onboarding", which is easy to misread as a five-page
/// carousel selling features the user has already decided to try — they
/// installed the app. What earns its place here is a name for the greeting, and
/// an honest explanation of reminders *before* the system prompt, since a
/// denied prompt is close to permanent.
struct OnboardingView: View {
    @Environment(ScheduleCoordinator.self) private var coordinator
    @AppStorage(PreferenceKey.hasCompletedOnboarding) private var hasCompleted = false
    @AppStorage(PreferenceKey.displayName) private var displayName = ""

    @State private var page: Page = .welcome
    @State private var name: String = ""
    @FocusState private var isNameFocused: Bool

    enum Page: Int, CaseIterable {
        case welcome
        case name
        case reminders
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            content
                .padding(.horizontal, Space.xl)
                .frame(maxWidth: .infinity)

            Spacer(minLength: 0)

            pageIndicator
                .padding(.bottom, Space.xl)

            actions
                .padding(.horizontal, Space.xl)
                .padding(.bottom, Space.xxl)
        }
        .background(Palette.surface)
        .calmAnimation(Motion.completion, value: page)
    }

    // MARK: - Pages

    @ViewBuilder
    private var content: some View {
        switch page {
        case .welcome:  welcomePage
        case .name:     namePage
        case .reminders: remindersPage
        }
    }

    private var welcomePage: some View {
        pageBody(
            symbol: "circle.and.line.horizontal",
            title: "A calm timeline",
            body: """
            Magic Pill shows your day as one quiet timeline — medications, and \
            anything else worth remembering.
            """
        )
    }

    private var namePage: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            symbolMark("hand.wave")

            Text("What should we call you?")
                .font(TypeScale.greeting)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Used only to say hello at the top of your timeline.")
                .font(TypeScale.itemDetail)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Your name", text: $name)
                .textInputAutocapitalization(.words)
                .textContentType(.givenName)
                .submitLabel(.continue)
                .focused($isNameFocused)
                .onSubmit(advance)
                .padding(Space.l)
                .background(
                    RoundedRectangle(cornerRadius: Radius.well, style: .continuous)
                        .fill(Palette.surfaceElevated)
                )
                .accessibilityIdentifier(A11y.Onboarding.nameField)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { isNameFocused = true }
    }

    private var remindersPage: some View {
        pageBody(
            symbol: "bell.badge",
            title: "Gentle reminders",
            body: """
            Magic Pill can remind you when something is due, and let you mark it \
            taken straight from the notification. You can change this any time \
            in Settings.
            """
        )
    }

    private func pageBody(symbol: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            symbolMark(symbol)

            Text(title)
                .font(TypeScale.greeting)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(body)
                .font(TypeScale.itemDetail)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func symbolMark(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 34, weight: .light))
            .foregroundStyle(Palette.accentText)
            .frame(width: 64, height: 64)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(ColorToken.sage.wash)
            )
            .accessibilityHidden(true)
    }

    // MARK: - Chrome

    private var pageIndicator: some View {
        HStack(spacing: Space.s) {
            ForEach(Page.allCases, id: \.rawValue) { candidate in
                Capsule()
                    .fill(candidate == page ? Palette.accent : Palette.separator)
                    .frame(width: candidate == page ? 20 : 6, height: 6)
            }
        }
        .calmAnimation(Motion.subtle, value: page)
        .accessibilityHidden(true)
    }

    private var actions: some View {
        VStack(spacing: Space.m) {
            Button(action: advance) {
                Text(primaryTitle)
                    .font(.headline)
                    .foregroundStyle(Palette.surfaceElevated)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Metrics.minimumTapTarget)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.well, style: .continuous)
                            .fill(Palette.accent)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11y.Onboarding.primaryButton)

            // Present on every page, not just the last: someone who wants to
            // get to their timeline should never have to page through an
            // introduction to reach it.
            Button("Skip") { finish(requestNotifications: false) }
                .font(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .frame(minHeight: Metrics.minimumTapTarget)
                .accessibilityIdentifier(A11y.Onboarding.skipButton)
        }
    }

    private var primaryTitle: String {
        switch page {
        case .welcome:   "Get Started"
        case .name:      name.trimmed.isEmpty ? "Skip for now" : "Continue"
        case .reminders: "Turn On Reminders"
        }
    }

    // MARK: - Flow

    private func advance() {
        switch page {
        case .welcome:
            page = .name
        case .name:
            isNameFocused = false
            page = .reminders
        case .reminders:
            finish(requestNotifications: true)
        }
    }

    private func finish(requestNotifications: Bool) {
        displayName = name.trimmed
        hasCompleted = true

        // The system prompt fires after onboarding dismisses, so the
        // explanation the user just read is the last thing they saw.
        if requestNotifications {
            Task { await coordinator.requestNotificationPermissionIfNeeded() }
        }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
