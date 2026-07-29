# Magic Pill — Build Plan

**Source of truth for design:** the "New magic pill" Apple Note (design manifesto).
**This document:** the technical translation of that manifesto into a shippable iOS app.

## Decisions locked

| Decision | Choice |
|---|---|
| v1 scope | Medication-only surface, universal-ready data model |
| Persistence | SwiftData + CloudKit (iCloud private database) |
| v1 features | Local notifications + snooze, lock-screen & home-screen widgets |
| Minimum iOS | 26.0 |
| Toolchain | Xcode 26.6, iOS SDK 26.5, Swift 6 strict concurrency |
| Signing | Team `BAMVK6LBVP` (Rahul Kassel), automatic |
| Name | Magic Pill |

One flag on the name: the manifesto's endgame is a universal tracker ("Medication is only one template… the UI never changes"). "Magic Pill" is a medication name and will read as false advertising the day you ship plant-watering. It costs nothing to keep the display name in one place now — the plan does that — so you can rename at v2 without touching code. Proceeding with Magic Pill as specified.

---

## 1. Architecture

Single SwiftUI app target + widget extension, sharing a model framework.

```
MagicPill/
├── MagicPill/                 # app target
│   ├── App/                   # entry point, model container, app-wide config
│   ├── Features/
│   │   ├── Timeline/          # the centrepiece
│   │   ├── ItemEditor/        # add/edit a tracked item + schedule
│   │   ├── Onboarding/        # deferred to v1.1 (not selected for v1)
│   │   └── Settings/
│   └── Resources/             # assets, colour sets, fonts
├── MagicPillKit/              # shared framework — models, scheduling, design system
│   ├── Model/                 # SwiftData models
│   ├── Scheduling/            # recurrence → occurrences
│   ├── Notifications/         # scheduling, categories, actions
│   └── Design/                # tokens, materials, motion curves
├── MagicPillWidget/           # WidgetKit extension
└── MagicPillTests/
```

**Why a shared framework:** the widget needs the models, the design tokens, and the "what's next" query. Duplicating those into the extension is how widgets drift out of sync with the app.

**Concurrency:** Swift 6 language mode from the start. SwiftData's `ModelActor` for all background writes (occurrence materialization, notification reconciliation). Retrofitting strict concurrency later is materially more painful than starting with it.

---

## 2. Data model

The universal-ready core. Nothing here says "medication" — that lives in `template` and presentation.

```swift
@Model final class TrackedItem {
    var id: UUID = UUID()
    var name: String = ""
    var templateRaw: String = TemplateKind.medication.rawValue
    var detail: String = ""          // "1 Tablet"
    var note: String = ""            // "Take with breakfast"
    var colorTokenRaw: String = ColorToken.sage.rawValue
    var symbolName: String = "pills" // SF Symbol, not emoji — see §4
    var isArchived: Bool = false
    var createdAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \Schedule.item)
    var schedules: [Schedule]? = []
    @Relationship(deleteRule: .cascade, inverse: \Occurrence.item)
    var occurrences: [Occurrence]? = []
}

@Model final class Schedule {
    var id: UUID = UUID()
    var item: TrackedItem?
    var ruleRaw: Data = Data()       // encoded RecurrenceRule
    var timesOfDay: [Int] = []       // minutes from local midnight, e.g. [480, 1140]
    var startDate: Date = Date.now
    var endDate: Date?
    var isPaused: Bool = false
}

@Model final class Occurrence {
    var id: UUID = UUID()
    var item: TrackedItem?
    var scheduledAt: Date = Date.now   // absolute, resolved in user's calendar
    var stateRaw: String = OccurrenceState.pending.rawValue
    var resolvedAt: Date?              // when taken/skipped
    var snoozedUntil: Date?
    var generatedFromScheduleID: UUID?
}
```

`OccurrenceState`: `pending | taken | skipped | missed`. `missed` is derived by a sweep, not user action.

### CloudKit constraints — non-negotiable, and the #1 source of "why won't it sync"

SwiftData's CloudKit mirroring imposes hard rules. Violating them fails at container init, at runtime, in a way that reads as a generic crash:

- **Every property needs a default value or must be optional.** Note every field above has one.
- **No `@Attribute(.unique)`.** Uniqueness is enforced in code (upsert by `id`), not by the store.
- **All relationships must be optional** and must declare an inverse. Hence `[Schedule]?` rather than `[Schedule]`.
- **No `.deny` delete rules.**

Keep a `#if DEBUG` in-memory container for previews and tests so the CloudKit container isn't in the loop during development.

---

## 3. Scheduling — the actual hard part

Everything else in this app is presentation. This is where the bugs live.

### Occurrence materialization

A schedule is an infinite rule; the timeline needs concrete rows. Strategy:

1. **Materialize a rolling window** — today −7 days through today +30 days — into concrete `Occurrence` records.
2. **Extend the window** on app foreground and on `BGAppRefreshTask`.
3. **Reconcile on schedule edit:** delete future `pending` occurrences for that schedule, regenerate. Never touch past or already-resolved occurrences — the history is the user's record and must be immutable.

Materialization must be **idempotent**. Key on `(scheduleID, scheduledAt)`; generating twice must not produce doubles. Since CloudKit forbids unique constraints, dedupe explicitly in the generator.

### Time zone and DST

Compute occurrence dates with `Calendar.current` and `DateComponents` (hour/minute), never by adding 86,400 seconds. "8:00 AM daily" must stay 8:00 AM across a DST boundary and after the user flies to another time zone. Store `timesOfDay` as local minutes-from-midnight, resolve to absolute `Date` at materialization time, and re-materialize the future window on `NSSystemTimeZoneDidChange`.

### The 64-notification ceiling

iOS allows **64 pending local notifications per app**. Three medications, twice daily, is 6/day — roughly 10 days of runway. This is a real constraint, not a theoretical one, and the naive "schedule everything" approach silently drops reminders past the limit.

Approach:
- Maintain a **notification budget**: schedule only the soonest N occurrences, N ≤ 60, leaving headroom for snoozes.
- Re-fill the budget on app foreground, on `BGAppRefreshTask`, and whenever an occurrence resolves.
- Verify with `UNUserNotificationCenter.pendingNotificationRequests()` in a debug view — build this early, it pays for itself.

### Notification actions

Register a `UNNotificationCategory` with actions matching the card: **Taken**, **Snooze**, **Skip**. Handled in `UNUserNotificationCenterDelegate` so the user resolves a dose straight from the banner without opening the app. Snooze schedules a one-off request and sets `snoozedUntil`.

---

## 4. Design system — the manifesto, made concrete

All of this lives in `MagicPillKit/Design` as tokens. No magic numbers in view code.

### Colour

Five muted tokens from the note — Sage Green, Ocean Blue, Lavender, Soft Orange, Warm Grey — each defined as an **Asset Catalog color set with light and dark variants**, not a hardcoded `Color(red:green:blue:)`. Dark mode is not an afterthought in a calm app; a muted palette that wasn't tuned for dark goes muddy.

Semantic layer on top: `surface`, `surfaceElevated`, `textPrimary`, `textSecondary`, `accent`, `overdue`. Per the note, `overdue` is a soft amber, **not red**. Red is reserved for destructive confirmation only.

### Typography

Things 3's discipline: SF Pro (system) with a tight scale — `largeTitle` for the greeting, `title2` for time headers, `headline` for item names, `subheadline` for detail, `footnote` for notes. Every style uses `.dynamicTypeSize` and must survive AX3 sizing without truncation. Test this — large type is where "lots of whitespace" designs break first.

### Icons

The note sketches emoji (💊 🏃 🌱). **Use SF Symbols instead.** Emoji don't tint, don't scale with Dynamic Type properly, render inconsistently across iOS versions, and can't do the hierarchical/multicolour rendering that makes the palette cohere. Map each template to a symbol: medication → `pills.fill`, exercise → `figure.run`, water → `drop.fill`, plants → `leaf.fill`, pet → `pawprint.fill`, maintenance → `wrench.and.screwdriver.fill`, meetings → `calendar`, habits → `target`.

### Motion

The note is explicit: smooth, slow, natural, no confetti.

- Card completion: `.spring(response: 0.45, dampingFraction: 0.85)` — settles without bounce.
- Timeline re-flow after a card leaves: same spring, driven by a keyed `withAnimation` around the model change so rows interpolate rather than jump.
- Progress ring: `.easeInOut(duration: 0.8)`.
- Honour `.accessibilityReduceMotion` — fall back to a cross-fade. Non-negotiable, and App Store reviewers do check.

### Materials

iOS 26 Liquid Glass for card surfaces and the floating add button. Use the system material APIs rather than hand-rolled blur+shadow stacks — they adapt to background content and dark mode for free, which is exactly the "premium Apple app" quality the note is asking for.

---

## 5. Screens

**Timeline (root).** Greeting header ("Good Morning Rahul" — pull the name from onboarding or the device), then today's occurrences as a vertical timeline: time gutter on the left, connecting rule, card per occurrence. Past-and-resolved rows collapse to a compact, dimmed state. A subtle "now" indicator line. Horizontal swipe or a date strip moves between days. One primary action: a floating add button.

**Card.** Time, symbol, name, detail, note. `swipeActions` for Taken (trailing, sage) and Snooze (leading, ocean). Tap opens detail. Per the note: no checkboxes.

**Item editor.** Name, template picker, detail, note, colour, schedule builder (times of day + recurrence + start/end). This is the densest screen in the app and the one most likely to feel like a medical form — keep it a sectioned `Form` with generous spacing and progressive disclosure (advanced recurrence hidden behind a disclosure row).

**Item detail.** The item, its schedule, and a calm adherence view — a soft ring plus a 30-day dot grid. Per the note, no tables and no spreadsheets.

**Settings.** Notification permissions and timing, appearance, iCloud sync status, data export.

---

## 6. Widgets

Extension shares the SwiftData store via an **App Group**; both targets point the `ModelConfiguration` at the group container URL. Get this wired on day one of widget work — retrofitting a shared container means a data migration.

- **Lock screen (`.accessoryRectangular`)**: next occurrence — time, name, and the one after it. Exactly the note's sketch.
- **Home screen (`.systemSmall`)**: next dose + today's progress ring.
- **Home screen (`.systemMedium`)**: next three occurrences with interactive complete buttons via `AppIntent`.

Reload timelines with `WidgetCenter.shared.reloadAllTimelines()` after every occurrence state change. Widget timeline entries should cover the next several occurrences so the widget stays correct even if the app never runs.

---

## 7. Build order

Each phase ends at something runnable — no phase leaves the app in a non-launching state.

**Phase 1 — Foundation. ✅ Done.** Xcode project (generated from `project.yml`), three targets, App Group, CloudKit entitlement. `MagicPillKit` with models and design tokens. In-memory container + SwiftUI previews. *Done when:* the app launches and renders a hardcoded timeline from mock data.

**Phase 2 — Timeline UI. ✅ Done.** The centrepiece, against mock data. Cards, time gutter, day strip, "now" indicator, resolved-row collapse, swipe actions, motion, dark mode, Dynamic Type through AX3. *Done when:* the feel is right. **Stop and evaluate here** — if the timeline doesn't feel calm and premium at this point, no amount of backend work fixes it, and this is the cheapest moment to iterate.

**Phase 3 — Persistence. ✅ Done.** Real SwiftData container, item editor, CRUD. *Done when:* items survive relaunch.

Store selection degrades in three tiers — App Group + CloudKit, then app-private on disk, then in-memory — and the app reports which one it landed on. The middle tier was added so unsigned development builds still persist; without it, "survives relaunch" was untestable outside a signed device build.

**Phase 4 — Scheduling engine. ✅ Done.** Recurrence rules, materialization, the rolling window, DST/time-zone correctness, reconciliation on edit. Heavily unit-tested — this is the layer where correctness is invisible until it's wrong. *Done when:* tests cover DST transitions, time-zone travel, schedule edits, and idempotent regeneration.

**Correction to this plan's own design.** The window was specified above as "today −7 days through today +30". That was wrong, and building it surfaced why: generating rows for days already past invents history. Add an item this morning and the next sweep declares a week of doses "missed" that nobody was ever reminded about — fabricated non-adherence, in a medication app.

The two bounds serve different purposes and are now separate:

- **`materializationRange`** — today through +30 days. Generation never runs backwards. A past occurrence exists only because that day was once today.
- **`retentionCutoff`** — today −7 days. Governs *pruning* only. Unresolved rows older than this are deleted; resolved rows are kept forever, since they're the adherence history.

`ScheduleEngine` is a `@ModelActor` running sweep → prune → materialize in that order (materializing first would generate rows the prune then deletes). Triggered on foreground, on `BGAppRefreshTask`, and on `NSSystemTimeZoneDidChange`.

**Phase 5 — Notifications. ✅ Code complete; runtime delivery unverified.** Permission flow, scheduling with budget management, actionable categories, snooze, background refresh. *Done when:* a dose can be resolved entirely from a banner and the pending-request count never exceeds budget.

Budget: `systemLimit` 64 (the iOS cap), `scheduledLimit` 56. The 8-slot gap is headroom so a morning of snoozes — each one an extra one-shot request — can't push a real reminder off the end of the queue.

`Reminder` is a `Sendable` snapshot of an occurrence. SwiftData models can't cross an actor boundary, so `ScheduleEngine` maps to plain values inside its own isolation. This also leaves `NotificationScheduler` and `NotificationBudget` with no dependency on the persistence layer, which is what makes the budget rule testable without a store.

**Verified by UI test.** `testGrantingPermissionSchedulesNotifications` taps through the real system prompt via Springboard, then asserts through the diagnostics bar that requests were accepted and the pending count stayed under 64.

**Phase 5a — UI test target. ✅ Done.** `MagicPillUITests`, 7 tests: timeline loads, empty state, create-item flow, cancel discards the draft, save disabled without a name, swipe-to-complete, and the notification permission gate.

It immediately earned itself. **`.swipeActions` is a `List`-only modifier** — the timeline was a `ScrollView` + `LazyVStack`, so swipe-to-complete compiled, rendered nothing, and had never worked since Phase 2. No unit test could have caught it; the modifier was applied exactly as documented, to a container that ignores it. The timeline is now a `List` with rows stripped back via `plainTimelineRow()`.

**Phase 6 — Widgets. ✅ Code complete; on-device rendering unverified.** Shared container, widget families, interactive intent, reload wiring.

`UpNextWidget` supports `.accessoryRectangular` (the manifesto's lock-screen sketch), `.accessoryCircular`, `.systemSmall`, and `.systemMedium` with per-row `MarkTakenIntent` buttons that resolve a dose without opening the app.

Two decisions worth keeping:

- **The timeline emits one entry per upcoming reminder, with `.atEnd`.** A widget that only refreshes when the app runs is stale exactly when it matters — for the person who hasn't opened the app all day. Entries at each fire date let it advance on its own.
- **"Store unavailable" is a distinct state from "nothing scheduled."** Without the App Group the widget renders an explicit prompt rather than an empty timeline that reads as "you're all done".

**Not verified:** the App Group requires signing, so an unsigned build renders the unavailable state. Nothing has drawn real data on a home screen, and `MarkTakenIntent` has never been tapped. The snapshot loader behind it all is unit-tested (10 tests); the WidgetKit surface is not. Needs a signed device build.

**Phase 7 — iCloud. ✅ Status surface done; sync itself unverified.** Enable CloudKit mirroring, test two-device sync, handle conflicts, sync status in Settings.

CloudKit mirroring has been configured since Phase 1 (`cloudKitDatabase: .automatic` on the App Group store). What Phase 7 adds is the honest reporting around it.

**`CloudSyncMonitor`** observes `NSPersistentCloudKitContainer.eventChangedNotification` — SwiftData exposes no sync-status API, but it is built on that container, and those notifications are the only supported way to know whether a user's data is actually reaching iCloud.

Two rules the state machine enforces, both tested:

- **`unavailable` is sticky.** It describes configuration, not an operation, so no CloudKit event can override it. Without this, a local-only build could claim to be syncing.
- **A success clears a prior failure, but a stale success never masks a live one.** A sync indicator that flickers back to "Up to date" while something is broken is worse than no indicator: it is actively reassuring.

**Settings** — finally built, the last screen from §5. Sync status, reminder status and pending count, storage tier, item counts, version. Deliberately a *status* screen, not a preferences screen.

**Conflicts:** last-writer-wins, which is CloudKit's default for SwiftData mirroring and correct for this data. Two devices resolving the same dose both mean "taken"; the loser of the race is not a lost edit.

**Not verified:** actual sync. That needs signing, an iCloud account, and two devices. The status logic has 12 tests; CloudKit itself has run zero times.

**Phase 8 — Polish. ✅ Mostly done.** Accessibility audit, app icon, privacy manifest.

**The accessibility audit found six real defects.** `performAccessibilityAudit` runs Apple's own checks against the live hierarchy, and every one of these had survived four visual reviews:

1. **Text tokens failed contrast.** `textTertiary` was ~2.1:1 on the warm surface. "Muted" in the manifesto means low *saturation*, not low contrast.
2. **Coloured text failed contrast.** Sage and apricot are ~3:1 as text. Split into `accent`/`accentText` and `overdue`/`overdueText` — fills and text have different requirements.
3. **Resolved cards used `.opacity(0.62)`**, dragging their text to ~2.5:1. Alpha dims content along with chrome; the quiet now comes from type size, colour, and shadow.
4. **The day strip clamped Dynamic Type.** Clamping means someone who needs large text doesn't get it. It now switches to stepper navigation at accessibility sizes.
5. **The header clipped its own descenders.** Invisible by eye, lossy at large sizes.
6. **Text fields clipped their contents** at larger Dynamic Type. They wrap now.

Two suppressions remain, both documented inline: the disabled Save button (WCAG exempts disabled controls) and issues on unattributable `SwiftUI.AccessibilityNode`s inside `Form`. The second is the weaker of the two and worth revisiting.

**Remaining for ship:** App Store screenshots and listing copy, which need decisions only you can make. Signing also still gates Phases 6 and 7.

HealthKit was not selected for v1.

**Onboarding. ✅ Done** (pulled forward from v1.1). Three screens, asking for exactly one thing: a name for the greeting, plus an honest explanation of reminders *before* the system prompt — a denied prompt is close to permanent, so the rationale has to come first. Skippable from every screen, and the name is optional.

The name lives in `UserDefaults`, not SwiftData: it's a device-local preference, not content. Putting it in the synced store would mean a CloudKit schema change for a greeting, and a name typed on one device silently overwriting the other. The cost is that it doesn't follow the user to a new device.

That choice made `UserDefaults` a required-reason API, so `PrivacyInfo.xcprivacy` now declares `NSPrivacyAccessedAPICategoryUserDefaults` with reason CA92.1 — exactly what the manifest's own comment said to do when app code first touched it.

---

## 8. Risks

| Risk | Mitigation |
|---|---|
| 64-notification ceiling silently drops reminders | Budget manager + debug inspector, built in Phase 5 |
| CloudKit model rules crash at container init | All properties defaulted/optional, all relationships optional — encoded in §2 |
| DST/time-zone drift moves doses | Calendar-component arithmetic only; re-materialize on time-zone change; explicit tests |
| Timeline feels clinical despite the tokens | Phase 2 gate — evaluate the feel before building anything behind it |
| Health data in App Review | No HealthKit in v1 keeps this light; privacy manifest still required, data stays in the user's private CloudKit DB |

---

## 9. Open questions for later

- Does the greeting name come from onboarding, or the device's contact card?
- Adherence history: how far back does the item detail view show?
- Refill tracking (pill counts, "3 days left") — v2 or never? It pulls toward the clinical feel the manifesto rejects.
- Export format for the user's data — CSV is the obvious answer but is exactly the spreadsheet the note warns against; PDF summary may fit better.
