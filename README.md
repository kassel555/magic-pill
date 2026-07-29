# Magic Pill

A calm, timeline-first tracker for iOS. See [BUILD_PLAN.md](BUILD_PLAN.md) for the
architecture and phased build order, and the "New magic pill" Apple Note for the
design manifesto that drives it.

## Requirements

- Xcode 26.6+ (iOS SDK 26.5)
- iOS 26.0+ deployment target
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Getting started

The `.xcodeproj` is generated and **not** meant to be edited by hand — change
`project.yml` instead and regenerate:

```sh
xcodegen generate
open MagicPill.xcodeproj
```

## Building and testing

```sh
# Build for the simulator
xcodebuild -project MagicPill.xcodeproj -scheme MagicPill \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build

# Run the unit tests (fast)
xcodebuild -project MagicPill.xcodeproj -scheme MagicPill \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:MagicPillTests test

# Run everything, including UI tests (~2 min)
xcodebuild -project MagicPill.xcodeproj -scheme MagicPill \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test
```

### UI tests

`MagicPillUITests` covers what unit tests structurally cannot: taps, swipes,
text entry, and the system notification prompt. It found a swipe-to-complete
gesture that had never worked (see conventions below), so it earns its runtime.

The app takes launch arguments to stay deterministic under test:

| Argument | Effect |
|---|---|
| `-uiTesting` | Wipes the local store before opening it |
| `-showDiagnostics` | Shows a bar with pending-notification count and auth state |
| `-skipSeeding` | Starts with an empty timeline |
| `-showOnboarding` | Forces first-run onboarding (otherwise `-uiTesting` marks it complete) |

Notifications are **not** an `XCUIProtectedResource`, so
`resetAuthorizationStatus` cannot clear them — only reinstalling returns the
prompt to "not determined". To exercise the permission flow from scratch:

```sh
xcrun simctl uninstall booted com.rahulkassel.MagicPill
```

## Signing and the App Group

`PersistenceStore` picks the best store it can actually open, in three tiers:

| Tier | Backing | When |
|---|---|---|
| `.synced` | App Group + CloudKit | Signed build with the entitlements in place |
| `.local` | App-private, on disk | Unsigned builds — persists, but no sync and the widget can't see it |
| `.memory` | Nothing on disk | Last resort; the app shows a warning banner |

Signing is set up, so normal builds run on `.synced`. If you build with
`CODE_SIGNING_ALLOWED=NO` the entitlements are stripped and the app drops to
`.local`: data still persists across launches, but it doesn't sync and **the
widgets render an "unavailable" state**, because they read through the App
Group. That's expected, not a bug.

In `DEBUG` the app seeds sample data the first time it finds an empty store —
but never into a real synced store, so nobody's iCloud account acquires a
dog-walking reminder from a debug build. UI testing is the one exception: it
wipes both stores first, so there is nothing to pollute.

### Signing

Already configured. `DEVELOPMENT_TEAM` is `BAMVK6LBVP` (Rahul Kassel) in
`project.yml`, with automatic signing. Xcode registered the App ID, the App
Group, and the iCloud container on first provisioned build.

```sh
# Device build (creates/refreshes profiles as needed)
xcodebuild -project MagicPill.xcodeproj -scheme MagicPill \
  -destination 'generic/platform=iOS' build -allowProvisioningUpdates
```

Verified present on both the app and the widget:

| Entitlement | Value |
|---|---|
| App Group | `group.com.rahulkassel.MagicPill` |
| iCloud container | `iCloud.com.rahulkassel.MagicPill` (CloudKit) |
| Push | `aps-environment: development` |

**Build *with* signing, not `CODE_SIGNING_ALLOWED=NO`.** Disabling it strips the
entitlements, which removes the App Group, which drops the app to the `.local`
tier and makes the widget useless. The commands above omit it deliberately.

### Building this yourself

The identifiers above belong to one Apple Developer account, so a fresh clone
**will not build signed** until you point it at yours. Nothing here is secret —
team IDs and bundle IDs ship inside every app on the App Store — it simply
isn't yours to sign with.

Pick a reverse-DNS prefix you control (`com.example` below) and your own
10-character team ID, which you can read straight off your signing certificate:

```sh
security find-certificate -a -c "Apple Development" -p \
  | openssl x509 -noout -subject
# → …/OU=YOURTEAMID/…    the OU field is the team ID
```

Then replace `com.rahulkassel` and `BAMVK6LBVP` throughout:

```sh
grep -rl 'com\.rahulkassel\|BAMVK6LBVP' \
  project.yml MagicPill MagicPillKit MagicPillWidget README.md \
  | xargs sed -i '' \
      -e 's/com\.rahulkassel/com.example/g' \
      -e 's/BAMVK6LBVP/YOURTEAMID/g'
xcodegen generate
```

That covers all seven places the identifiers appear, which is why a
find-and-replace beats editing by hand:

| Where | What |
|---|---|
| `project.yml` | `bundleIdPrefix`, `DEVELOPMENT_TEAM`, five `PRODUCT_BUNDLE_IDENTIFIER`s, `BGTaskSchedulerPermittedIdentifiers` |
| `MagicPill/MagicPill.entitlements` | App Group, iCloud container |
| `MagicPillWidget/MagicPillWidget.entitlements` | App Group, iCloud container |
| `MagicPillKit/Model/PersistenceStore.swift` | `appGroupID` |
| `MagicPill/App/ScheduleCoordinator.swift` | `refreshTaskIdentifier` |

The App Group and iCloud container strings must match **exactly** across the
entitlements files and `PersistenceStore.appGroupID`. A mismatch doesn't fail
the build — the app quietly falls back to the `.local` tier and the widget shows
"unavailable", which looks like a widget bug and isn't.

Build once with `-allowProvisioningUpdates` (see above) and Xcode registers the
App ID, App Group, and iCloud container against your account.

Without a paid Apple Developer account you can still run everything on the
simulator and the full test suite; only device builds, real iCloud sync, and
home-screen widgets need one.

**The simulator does not enforce entitlements the way a device does.** An App
Group works there once the build is signed at all, so a working simulator build
is *not* evidence that device provisioning is correct — check
`codesign -d --entitlements :-` on a device build for that.

> **Note:** SwiftData calls `fatalError` — it does not throw — when an App Group
> named in a `ModelConfiguration` is missing from the entitlements. `PersistenceStore`
> therefore probes `isAppGroupAvailable` *before* constructing the
> configuration. Don't remove that check; without it the app hard-crashes on
> launch in any unsigned build.

## Layout

| Path | Purpose |
|---|---|
| `MagicPillKit/Model` | SwiftData models, recurrence rules, store construction |
| `MagicPillKit/Scheduling` | Occurrence generation, the rolling window, the background engine |
| `MagicPillKit/Design` | Colour, type, spacing, motion tokens and shared components |
| `MagicPill/Features` | App screens — the timeline lives here |
| `MagicPillKit/Sync` | CloudKit status monitoring and its state machine |
| `MagicPillKit/Widgets` | Widget snapshot loader and the interactive `AppIntent` |
| `MagicPillWidget` | WidgetKit extension — lock screen, small, and medium families |
| `MagicPillTests` | Unit tests |

## Conventions

- **No magic numbers in views.** Spacing, radii, type, and motion all come from
  `MagicPillKit/Design`.
- **No raw colours in views.** Use a `Palette` semantic token, or a
  `ColorToken` when expressing an item's own identity colour.
- **Animate via `.calmAnimation(_:value:)`**, which degrades to a cross-fade
  under Reduce Motion. Don't call `.animation` directly.
- **Every model property needs a default or must be optional**, and every
  relationship must be optional with an inverse — CloudKit mirroring requires
  it. See the comment at the top of `Models.swift`.
- **SF Symbols, never emoji**, for template icons.
- **Never generate occurrences into the past.** `materializationRange` runs
  today-forward only; `retentionCutoff` reaches backwards but governs *pruning*
  alone. Backfilling manufactures a record of missed doses the user was never
  reminded about. Resolved rows are never pruned — they're the adherence
  history.
- **All date arithmetic goes through `Calendar` components.** Never add
  intervals to a `Date`: 86,400 seconds is not a day across a DST boundary.
- **The timeline must stay a `List`.** `.swipeActions` is a List-only modifier —
  on a row inside a `ScrollView`/`LazyVStack` it compiles, renders nothing, and
  silently does nothing. The timeline shipped four phases that way before a UI
  test caught it. Rows are stripped back with `plainTimelineRow()`; if you're
  tempted to swap `List` for a stack to regain layout control, you are removing
  swipe-to-complete.
- **Colour has two accent tokens, and they are not interchangeable.**
  `Palette.accent` is for *fills* (buttons, rings, nodes); `Palette.accentText`
  is for coloured **text**, which needs far more contrast. Same for
  `overdue`/`overdueText`. Using the fill token as text fails the audit.
- **Never dim with `.opacity()`.** It reduces the contrast of content, not just
  chrome. Express "done" through type size, colour, and shadow.
- **Never clamp Dynamic Type.** Change the layout instead — clamping denies
  large text to the people who need it. The three
  `test*AccessibilityAudit` UI tests enforce all of this; run them after any
  visual change.
- **The app icon is generated:** `swift Tools/GenerateAppIcon.swift`. Edit the
  script, not the PNG.
- **Accessibility identifiers live in `A11y`** (`MagicPill/App/LaunchArguments.swift`),
  mirrored in the UI test bundle. A UI test matching a literal string keeps
  passing while asserting nothing once the app's string changes.
- **Adapt the layout at accessibility text sizes; don't clamp the text.** The
  timeline drops its time gutter and stacks (`DynamicTypeSize
  .prefersStackedTimeline`) rather than squeezing "6:30 AM" into a fixed
  column. `DayStrip` is the one deliberate exception — it's dense chrome whose
  content is repeated in full in the header — and it documents why inline.
  Re-check AX3 after touching any timeline layout:
  `xcrun simctl ui booted content_size accessibility-extra-large`.
- **Overdue is amber (`Palette.overdue`), never red.** `Palette.destructive` is
  reserved for genuinely destructive confirmation.
