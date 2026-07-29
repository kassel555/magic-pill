import XCTest

/// End-to-end tests for the interactions unit tests can't reach: taps, swipes,
/// text entry, and the system notification prompt.
///
/// These exist because everything below them was already covered. The unit
/// suite proves the budget rule, the save path, and every engine path a banner
/// action takes; what it cannot prove is that a finger on a card resolves a
/// dose, or that `UNUserNotificationCenter` actually accepts the requests once
/// permission is granted.
final class TimelineUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// A freshly-reset app with deterministic fixtures.
    /// Note there is no permission reset here. Notifications are not an
    /// `XCUIProtectedResource`, so `resetAuthorizationStatus` cannot clear
    /// them; only reinstalling the app returns the prompt to "not determined".
    /// The notification test therefore tolerates permission already being
    /// granted, and the run script uninstalls first to exercise the prompt.
    private func launchApp(
        extraArguments: [String] = [],
        showDiagnostics: Bool = true
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
            + (showDiagnostics ? ["-showDiagnostics"] : [])
            + extraArguments
        app.launch()
        return app
    }

    // MARK: - Timeline

    func testTimelineShowsSeededItems() {
        let app = launchApp()

        XCTAssertTrue(
            app.staticTexts["Vitamin D"].waitForExistence(timeout: 10),
            "The seeded timeline should show Vitamin D"
        )
        XCTAssertTrue(app.staticTexts["Walk the Dog"].exists)
    }

    func testEmptyStateWhenNothingScheduled() {
        let app = launchApp(extraArguments: ["-skipSeeding"])

        XCTAssertTrue(
            app.staticTexts["Nothing scheduled"].waitForExistence(timeout: 10),
            "With no items, the timeline should show its empty state"
        )
    }

    // MARK: - Creating an item
    //
    // The flow Phase 3 built but could not drive: tap the button, type, save,
    // and confirm the row reaches the timeline.

    func testCreateItemAppearsOnTimeline() {
        let app = launchApp(extraArguments: ["-skipSeeding"])

        app.buttons[A11y.Timeline.addButton].tap()

        let nameField = app.textFields[A11y.Editor.name]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "The editor should open")
        nameField.tap()
        nameField.typeText("Ibuprofen")

        let detailField = app.textFields[A11y.Editor.detail]
        detailField.tap()
        detailField.typeText("2 Tablets")

        app.buttons[A11y.Editor.save].tap()
        dismissNotificationPromptIfPresent()

        XCTAssertTrue(
            app.staticTexts["Ibuprofen"].waitForExistence(timeout: 10),
            "A saved item should appear on the timeline"
        )
    }

    func testCancelDiscardsTheDraft() {
        let app = launchApp(extraArguments: ["-skipSeeding"])

        app.buttons[A11y.Timeline.addButton].tap()

        let nameField = app.textFields[A11y.Editor.name]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Should Not Persist")

        app.buttons[A11y.Editor.cancel].tap()

        XCTAssertTrue(
            app.staticTexts["Nothing scheduled"].waitForExistence(timeout: 5),
            "Cancelling must not write the draft to the store"
        )
        XCTAssertFalse(app.staticTexts["Should Not Persist"].exists)
    }

    func testSaveIsDisabledWithoutAName() {
        let app = launchApp(extraArguments: ["-skipSeeding"])

        app.buttons[A11y.Timeline.addButton].tap()

        let save = app.buttons[A11y.Editor.save]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled, "An unnamed item cannot be saved")
    }

    // MARK: - Swipe actions
    //
    // Wired since Phase 2 and never once exercised by a finger.

    func testSwipeMarksDoseTaken() {
        let app = launchApp()

        // Pick whichever row is still unresolved rather than naming one.
        // Fixtures are seeded relative to the current time — anything already
        // past is marked taken — so a hardcoded row passes in the morning and
        // fails in the afternoon.
        //
        // Cards carry the `.isButton` trait, so they surface as buttons.
        let anyCard = app.buttons[A11y.Timeline.card("Evening Pills")]
        XCTAssertTrue(anyCard.waitForExistence(timeout: 10), "The timeline should have loaded")

        let pending = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND NOT (label CONTAINS %@)",
                "timeline.card.", "Taken"
            )
        )
        XCTAssertGreaterThan(pending.count, 0, "Precondition: at least one row must be pending")

        let card = pending.element(boundBy: 0)
        let name = card.identifier

        // A trailing swipe reveals Taken and Skip.
        card.swipeLeft()

        let taken = app.buttons["Taken"]
        XCTAssertTrue(
            taken.waitForExistence(timeout: 5),
            "Swiping a card should reveal the Taken action"
        )
        taken.tap()

        // Assert on *this* card's label, not on any "Taken" text: other seeded
        // rows are already resolved, so a bare text query would pass whether or
        // not the swipe did anything.
        let resolvedCard = app.buttons[name]
        let resolved = NSPredicate(format: "label CONTAINS %@", "Taken")
        let expectation = expectation(for: resolved, evaluatedWith: resolvedCard)
        wait(for: [expectation], timeout: 10)
    }

    // MARK: - Notifications
    //
    // The Phase 5 gate. `simctl privacy` has no notifications service, so this
    // is the only way to grant permission and confirm requests are accepted.

    func testGrantingPermissionSchedulesNotifications() {
        let app = launchApp()

        // The prompt appears after the first save, by design.
        app.buttons[A11y.Timeline.addButton].tap()

        let nameField = app.textFields[A11y.Editor.name]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Evening Tablet")
        app.buttons[A11y.Editor.save].tap()

        allowNotifications()

        // Diagnostics report the coordinator's view of the notification centre.
        let authorized = app.staticTexts[A11y.Diagnostics.authorized]
        XCTAssertTrue(authorized.waitForExistence(timeout: 10))

        let expectation = expectation(
            for: NSPredicate(format: "label == %@", "auth: yes"),
            evaluatedWith: authorized
        )
        wait(for: [expectation], timeout: 20)

        // The real assertion: requests were accepted, and stayed under the cap.
        let pending = app.staticTexts[A11y.Diagnostics.pendingCount]
        XCTAssertTrue(pending.exists)

        let count = Self.number(fromLabel: pending.label)
        XCTAssertNotNil(count, "Diagnostics should report a pending count")
        XCTAssertGreaterThan(count ?? 0, 0, "Granting permission should schedule reminders")
        XCTAssertLessThanOrEqual(
            count ?? .max, 64,
            "Pending requests must never exceed the iOS limit — past 64 they are silently dropped"
        )
    }

    // MARK: - Onboarding

    func testOnboardingCollectsNameAndGreetsWithIt() {
        let app = launchApp(extraArguments: ["-showOnboarding"])

        let primary = app.buttons[A11y.Onboarding.primaryButton]
        XCTAssertTrue(primary.waitForExistence(timeout: 10), "Onboarding should appear on first run")
        XCTAssertTrue(app.staticTexts["A calm timeline"].exists)

        primary.tap()

        let nameField = app.textFields[A11y.Onboarding.nameField]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Rahul")

        primary.tap()
        XCTAssertTrue(app.staticTexts["Gentle reminders"].waitForExistence(timeout: 5))

        primary.tap()
        dismissNotificationPromptIfPresent()

        // The point of collecting the name at all.
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "Rahul")
            ).firstMatch.waitForExistence(timeout: 10),
            "The greeting should use the name given during onboarding"
        )
    }

    /// Skipping must be genuinely skippable — including the name, which is
    /// optional by design.
    func testOnboardingCanBeSkipped() {
        let app = launchApp(extraArguments: ["-showOnboarding"])

        let skip = app.buttons[A11y.Onboarding.skipButton]
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        skip.tap()

        XCTAssertTrue(
            app.staticTexts["Vitamin D"].waitForExistence(timeout: 10),
            "Skipping should land on the timeline"
        )
        // No name given, so no trailing comma dangling off the greeting.
        XCTAssertFalse(app.staticTexts["Good Morning,"].exists)
    }

    func testOnboardingDoesNotReappearOnRelaunch() {
        let app = launchApp(extraArguments: ["-showOnboarding"])

        let skip = app.buttons[A11y.Onboarding.skipButton]
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        skip.tap()
        XCTAssertTrue(app.staticTexts["Vitamin D"].waitForExistence(timeout: 10))

        // Relaunch *without* the force flag, as a returning user.
        app.terminate()
        let returning = XCUIApplication()
        returning.launchArguments = ["-uiTesting"]
        returning.launch()

        XCTAssertTrue(returning.staticTexts["Vitamin D"].waitForExistence(timeout: 10))
        XCTAssertFalse(
            returning.buttons[A11y.Onboarding.primaryButton].exists,
            "Onboarding must not reappear once completed"
        )
    }

    func testOnboardingAccessibilityAudit() throws {
        let app = launchApp(extraArguments: ["-showOnboarding"], showDiagnostics: false)
        XCTAssertTrue(
            app.buttons[A11y.Onboarding.primaryButton].waitForExistence(timeout: 10)
        )

        try app.performAccessibilityAudit { issue in
            let isUnresolvableSystemNode =
                issue.detailedDescription.contains("SwiftUI.AccessibilityNode")
            if !isUnresolvableSystemNode {
                print("A11Y-ISSUE: \(issue.auditType) | \(issue.detailedDescription)")
            }
            return isUnresolvableSystemNode
        }
    }

    // MARK: - Settings

    func testSettingsReportsSyncAndStorageState() {
        let app = launchApp()

        app.buttons[A11y.Timeline.settingsButton].tap()

        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 5),
            "The settings sheet should open"
        )

        // Asserts the *invariant*, not one configuration's strings. Whether the
        // build is signed decides which tier the app runs on, and this test
        // must hold either way — an earlier version hardcoded the unsigned
        // strings and broke the moment signing was set up.
        //
        // Matched by substring: the sync row combines its accessibility
        // children into one label, and `LabeledContent` prefixes its own.
        func hasText(_ needle: String) -> Bool {
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", needle)
            ).firstMatch.exists
        }

        let saysLocal = hasText("This device")
        let saysCloud = hasText("iCloud")
        XCTAssertTrue(saysLocal || saysCloud, "Settings must report where data is stored")

        // The invariant that actually matters: never imply data is in iCloud
        // when it is sitting on one device. Claiming safety the app can't
        // deliver is the failure mode worth a test.
        if saysLocal {
            XCTAssertTrue(
                hasText("Not syncing"),
                "Local-only storage must be reported as not syncing"
            )
        }

        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Vitamin D"].waitForExistence(timeout: 5))
    }

    func testSettingsAccessibilityAudit() throws {
        let app = launchApp(showDiagnostics: false)

        app.buttons[A11y.Timeline.settingsButton].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        try app.performAccessibilityAudit { issue in
            let isUnresolvableSystemNode =
                issue.detailedDescription.contains("SwiftUI.AccessibilityNode")
            if !isUnresolvableSystemNode {
                print("A11Y-ISSUE: \(issue.auditType) | \(issue.detailedDescription)")
            }
            return isUnresolvableSystemNode
        }
    }

    // MARK: - Accessibility
    //
    // `performAccessibilityAudit` runs Apple's own checks against the live
    // view hierarchy: contrast, hit-region size, clipped text, missing element
    // descriptions, traits. It catches the class of defect that survives code
    // review precisely because everything looks right on a 6.9" screen at
    // default type.

    func testTimelineAccessibilityAudit() throws {
        let app = launchApp(showDiagnostics: false)
        XCTAssertTrue(app.staticTexts["Vitamin D"].waitForExistence(timeout: 10))

        try app.performAccessibilityAudit { issue in
            // Logged rather than swallowed: the audit's own failure message
            // names the check but not the element, which makes a bare failure
            // nearly impossible to act on.
            print("A11Y-ISSUE: \(issue.auditType) | \(issue.element?.debugDescription ?? "?") | \(issue.detailedDescription)")
            return false
        }
    }

    func testEditorAccessibilityAudit() throws {
        let app = launchApp(extraArguments: ["-skipSeeding"], showDiagnostics: false)

        app.buttons[A11y.Timeline.addButton].tap()
        XCTAssertTrue(app.textFields[A11y.Editor.name].waitForExistence(timeout: 5))

        try app.performAccessibilityAudit { issue in
            let element = issue.element

            // Two system-owned false positives, suppressed as narrowly as the
            // API allows:
            //
            // 1. The Save button starts disabled (no name entered yet) and the
            //    system dims disabled controls by design. WCAG exempts disabled
            //    controls from contrast minimums.
            //
            // 2. Issues on an unresolvable `SwiftUI.AccessibilityNode` — no
            //    identifier, no queryable element, no way to attribute them to
            //    a view. These are `Form`'s own chrome (section headers, field
            //    placeholders), and they reproduce with app code removed.
            //
            //    This is the weakest suppression here and worth revisiting: it
            //    would also hide a genuine issue in an app view that SwiftUI
            //    declines to expose. The real instances of this class that
            //    *were* attributable — fixed-size frames in the weekday and
            //    month-date pickers — have been fixed rather than suppressed.
            //
            // Every element the app actually owns is still audited.
            let isDisabledSaveButton = element?.identifier == A11y.Editor.save
                && element?.isEnabled == false
            // Matched on the description rather than `element == nil`: these
            // issues carry a non-nil element that resolves to nothing
            // queryable, so a nil check does not catch them.
            let isUnresolvableSystemNode =
                issue.detailedDescription.contains("SwiftUI.AccessibilityNode")

            let shouldSuppress = isDisabledSaveButton || isUnresolvableSystemNode
            if !shouldSuppress {
                print("A11Y-ISSUE: \(issue.auditType) | \(issue.detailedDescription)")
            }
            return shouldSuppress
        }
    }

    /// The timeline abandons its gutter and stacks at accessibility sizes.
    /// That layout has been eyeballed but never audited.
    func testTimelineAccessibilityAuditAtLargeText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launchEnvironment["UIPreferredContentSizeCategoryName"] =
            "UICTContentSizeCategoryAccessibilityXL"
        app.launch()

        XCTAssertTrue(app.staticTexts["Vitamin D"].waitForExistence(timeout: 10))

        try app.performAccessibilityAudit { issue in
            print("A11Y-ISSUE: \(issue.auditType) | \(issue.element?.debugDescription ?? "?")")
            return false
        }
    }

    // MARK: - Helpers

    /// Taps Allow on the system notification prompt.
    ///
    /// Driven through Springboard rather than `addUIInterruptionMonitor`, which
    /// only fires when the test next interacts with the app and so races with
    /// assertions made immediately after the prompt.
    private func allowNotifications() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 10) {
            allow.tap()
        }
    }

    /// Dismisses the prompt when a test doesn't care about notifications.
    private func dismissNotificationPromptIfPresent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Don't Allow", "Allow"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 3) {
                button.tap()
                return
            }
        }
    }

    private static func number(fromLabel label: String) -> Int? {
        let digits = label.filter(\.isNumber)
        return Int(digits)
    }
}

/// Mirrors the app's identifiers.
///
/// Duplicated deliberately: a UI test bundle cannot import the app target, and
/// depending on `MagicPillKit` just to share strings would drag the whole
/// persistence layer into the test process. Kept byte-identical to
/// `MagicPill/App/LaunchArguments.swift`.
enum A11y {
    enum Timeline {
        static let addButton = "timeline.addButton"
        static let greeting = "timeline.greeting"
        static let summary = "timeline.summary"
        static let emptyState = "timeline.emptyState"
        static let settingsButton = "timeline.settingsButton"
        static func card(_ name: String) -> String { "timeline.card.\(name)" }
    }

    enum Editor {
        static let name = "editor.name"
        static let detail = "editor.detail"
        static let note = "editor.note"
        static let save = "editor.save"
        static let cancel = "editor.cancel"
        static let delete = "editor.delete"
        static let addTime = "editor.addTime"
    }

    enum Onboarding {
        static let nameField = "onboarding.nameField"
        static let primaryButton = "onboarding.primaryButton"
        static let skipButton = "onboarding.skipButton"
    }

    enum Diagnostics {
        static let pendingCount = "diagnostics.pendingCount"
        static let authorized = "diagnostics.authorized"
    }
}
