import Foundation

/// Launch arguments the UI tests use to make the app deterministic.
///
/// Kept to the smallest possible set. Every one of these is a way the tested
/// app differs from the shipped app, so each has to earn its place:
///
/// - `-uiTesting` resets the store and seeds fixtures, because a UI test that
///   depends on leftover state from the previous run is worse than no test.
/// - `-showDiagnostics` surfaces the notification budget, which is otherwise
///   invisible from the outside — the whole reason the budget needed testing.
///
/// Neither changes app *logic*; they change starting state and what's on
/// screen. Nothing here is compiled out in release, so an accidental release
/// build with these flags behaves predictably rather than mysteriously.
enum LaunchArguments {
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTesting")
    }

    /// Shows a diagnostics bar with the pending-notification count and
    /// authorization state.
    static var showsDiagnostics: Bool {
        ProcessInfo.processInfo.arguments.contains("-showDiagnostics")
    }

    /// Skips fixture seeding, for tests that need a genuinely empty timeline.
    static var skipsSeeding: Bool {
        ProcessInfo.processInfo.arguments.contains("-skipSeeding")
    }

    /// Opens the widget gallery straight away, with fixed sample data.
    ///
    /// Used to produce the widget screenshots: the widgets themselves can only
    /// be seen by adding them to a home screen, which no automation can do.
    static var showsWidgetGallery: Bool {
        ProcessInfo.processInfo.arguments.contains("-widgetGallery")
    }

    /// Forces first-run onboarding.
    ///
    /// `-uiTesting` otherwise marks onboarding complete, so that the twelve
    /// tests written before it existed don't all have to page through a
    /// welcome screen to reach the thing they're testing.
    static var forcesOnboarding: Bool {
        ProcessInfo.processInfo.arguments.contains("-showOnboarding")
    }
}

/// Accessibility identifiers shared between the app and its UI tests.
///
/// Defined in one place and referenced from both sides. A UI test that matches
/// on a literal string silently stops testing anything the moment that string
/// changes in the app — it keeps passing while asserting nothing.
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

    enum Detail {
        static let edit = "detail.edit"
    }

    enum Gallery {
        static func widget(_ layout: String) -> String { "gallery.widget.\(layout)" }
    }

    enum Diagnostics {
        static let pendingCount = "diagnostics.pendingCount"
        static let authorized = "diagnostics.authorized"
    }
}
