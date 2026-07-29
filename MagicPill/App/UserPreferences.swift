import Foundation
import SwiftUI

/// The handful of scalars that aren't tracked data.
///
/// Deliberately *not* SwiftData. These are device-local preferences, not
/// content: putting them in the synced store would push a CloudKit schema
/// change for a greeting, and mean a name typed on one device silently
/// overwrites the other. The tradeoff is that the name doesn't follow the user
/// to a new device — they retype four characters once.
///
/// Keys live here rather than as scattered `@AppStorage` string literals: a
/// typo in one call site creates a second, silently-empty preference.
enum PreferenceKey {
    static let hasCompletedOnboarding = "hasCompletedOnboarding"
    static let displayName = "displayName"
}

extension UserDefaults {
    /// Used by UI tests to put the app in a known first-run state.
    static func resetOnboarding() {
        standard.removeObject(forKey: PreferenceKey.hasCompletedOnboarding)
        standard.removeObject(forKey: PreferenceKey.displayName)
    }

    static func markOnboardingComplete() {
        standard.set(true, forKey: PreferenceKey.hasCompletedOnboarding)
    }
}
