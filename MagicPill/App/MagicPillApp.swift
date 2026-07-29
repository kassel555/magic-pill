import SwiftUI
import SwiftData
import MagicPillKit

@main
struct MagicPillApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let container: ModelContainer
    private let storeMode: PersistenceStore.Mode
    @State private var coordinator: ScheduleCoordinator

    @Environment(\.scenePhase) private var scenePhase

    init() {
        container = AppEnvironment.container
        storeMode = AppEnvironment.storeMode
        _coordinator = State(initialValue: ScheduleCoordinator(
            engine: AppEnvironment.engine,
            notifications: AppEnvironment.notifications
        ))
        let result = (container: container, mode: storeMode)

        // Seed sample data only into a store that is genuinely empty, and never
        // into a *real* synced store — nobody's iCloud account should acquire a
        // dog-walking reminder because they installed a debug build.
        //
        // UI testing is the exception: it wipes the store first, including the
        // App Group one, so there is no real data to pollute. Without this,
        // signing the build silently emptied every fixture-dependent test.
        #if DEBUG
        let maySeed = LaunchArguments.isUITesting || result.mode != .synced
        if maySeed && !LaunchArguments.skipsSeeding {
            MainActor.assumeIsolated {
                seedIfEmpty(container: container)
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(storeMode: storeMode)
                .environment(coordinator)
                .task {
                    // Launch pass. Also runs on every cold start after a
                    // background kill, which is the common case for an app
                    // people open once a day.
                    await coordinator.runMaintenance()
                    ScheduleCoordinator.scheduleBackgroundRefresh()
                }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            // The window may have been open across a date boundary — a phone
            // left on the nightstand crosses midnight without ever relaunching.
            guard phase == .active else { return }
            Task { await coordinator.runMaintenance() }
        }
        .backgroundTask(.appRefresh(ScheduleCoordinator.refreshTaskIdentifier)) {
            await ScheduleCoordinator.runBackgroundMaintenance(container: container)
            // One-shot request: not re-submitting means this never fires again.
            ScheduleCoordinator.scheduleBackgroundRefresh()
        }
    }

    #if DEBUG
    @MainActor
    private func seedIfEmpty(container: ModelContainer) {
        let context = container.mainContext
        let existing = (try? context.fetchCount(FetchDescriptor<TrackedItem>())) ?? 0
        guard existing == 0 else { return }
        MockData.populate(context: context)
    }
    #endif
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(ScheduleCoordinator.self) private var coordinator
    let storeMode: PersistenceStore.Mode

    @AppStorage(PreferenceKey.hasCompletedOnboarding) private var hasCompletedOnboarding = false

    @State private var isAddingItem = false
    @State private var isShowingSettings = false
    @State private var editingItem: TrackedItem?

    var body: some View {
        NavigationStack {
            TimelineView(
                onSelect: { editingItem = $0.item },
                onOpenSettings: { isShowingSettings = true }
            )
                .toolbar(.hidden, for: .navigationBar)
                .overlay(alignment: .bottomTrailing) { addButton }
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 0) {
                        if LaunchArguments.showsDiagnostics {
                            diagnosticsBar
                        }
                        if !storeMode.persists {
                            storeBanner
                        }
                    }
                }
        }
        .tint(Palette.accentText)
        .sheet(isPresented: $isAddingItem) {
            ItemEditorView()
        }
        .sheet(item: $editingItem) { item in
            ItemEditorView(item: item)
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(
                storeMode: storeMode,
                syncMonitor: AppEnvironment.syncMonitor
            )
        }
        // `fullScreenCover`, not a sheet: onboarding is not dismissible by
        // dragging, and a half-height card would let the user swipe past the
        // one screen that explains what the app is.
        .fullScreenCover(isPresented: .constant(!hasCompletedOnboarding)) {
            OnboardingView()
        }
    }

    /// The manifesto's "one primary action per screen", floating clear of the
    /// timeline rather than competing with it in a navigation bar.
    private var addButton: some View {
        Button {
            isAddingItem = true
        } label: {
            Image(systemName: "plus")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.surfaceElevated)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Palette.accent))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        }
        .padding(.trailing, Space.xl)
        .padding(.bottom, Space.xl)
        .accessibilityLabel("Add item")
        .accessibilityIdentifier(A11y.Timeline.addButton)
    }

    /// Surfaces the notification budget, which is otherwise invisible from
    /// outside the app — no API lets a UI test inspect another process's
    /// pending requests. Shown only under `-showDiagnostics`.
    private var diagnosticsBar: some View {
        HStack(spacing: Space.m) {
            Text("pending: \(coordinator.pendingNotificationCount)")
                .accessibilityIdentifier(A11y.Diagnostics.pendingCount)
            Text("auth: \(coordinator.notificationsAuthorized ? "yes" : "no")")
                .accessibilityIdentifier(A11y.Diagnostics.authorized)
        }
        .font(.caption.monospaced())
        .foregroundStyle(Palette.textSecondary)
        .padding(.vertical, Space.s)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
    }

    /// Data loss is the one thing this app must never do silently. If we're on
    /// a store that doesn't persist, say so plainly rather than letting the
    /// user enter data that will vanish.
    private var storeBanner: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "exclamationmark.icloud")
            Text("Running on temporary storage — changes won't be saved.")
                .font(.footnote)
        }
        .foregroundStyle(Palette.overdue)
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
        .accessibilityElement(children: .combine)
    }
}

extension TrackedItem: @retroactive Identifiable {}
