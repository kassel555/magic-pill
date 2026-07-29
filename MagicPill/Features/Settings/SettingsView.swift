import SwiftUI
import SwiftData
import UserNotifications
import MagicPillKit

/// Sync status, reminder status, and what's stored.
///
/// Deliberately a status screen rather than a preferences screen. There is
/// almost nothing here to configure — the app's behaviour is defined by the
/// items the user creates — but there is a great deal worth *reporting*, and
/// silence about whether data is safe is the one thing this app must not do.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ScheduleCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var context

    let storeMode: PersistenceStore.Mode
    let syncMonitor: CloudSyncMonitor

    @Query private var items: [TrackedItem]
    @Query private var occurrences: [Occurrence]

    var body: some View {
        NavigationStack {
            Form {
                syncSection
                remindersSection
                storageSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Palette.surface)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .tint(Palette.accentText)
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        Section {
            HStack(alignment: .top, spacing: Space.m) {
                Image(systemName: syncMonitor.status.symbolName)
                    .font(.title3)
                    .foregroundStyle(
                        syncMonitor.status.isHealthy ? Palette.accentText : Palette.overdueText
                    )
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(syncMonitor.status.title)
                        .font(.headline)
                        .foregroundStyle(Palette.textPrimary)
                    Text(syncMonitor.status.detail)
                        .font(.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, Space.xs)
            .accessibilityElement(children: .combine)
        } header: {
            Text("iCloud")
        } footer: {
            // States the actual privacy position rather than a reassuring
            // slogan. Everything here is verifiable in the code.
            Text("""
            Your data stays on your devices and in your own private iCloud \
            account. Magic Pill has no server and no account to sign in to, \
            so nothing is ever sent anywhere else.
            """)
        }
    }

    // MARK: - Reminders

    private var remindersSection: some View {
        Section {
            LabeledContent("Status") {
                Text(coordinator.notificationsAuthorized ? "On" : "Off")
                    .foregroundStyle(Palette.textSecondary)
            }

            LabeledContent("Scheduled") {
                Text("\(coordinator.pendingNotificationCount)")
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
            }

            if !coordinator.notificationsAuthorized {
                Button("Open iOS Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
        } header: {
            Text("Reminders")
        } footer: {
            if coordinator.notificationsAuthorized {
                // Explains a real, invisible constraint rather than hiding it.
                // iOS allows 64 pending notifications per app; the app schedules
                // the soonest handful and refills as they fire.
                Text("""
                iOS limits every app to a fixed number of pending reminders, so \
                Magic Pill schedules the soonest ones and adds more as they \
                arrive.
                """)
            } else {
                Text("Reminders are off, so Magic Pill won't notify you when something is due.")
            }
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section {
            LabeledContent("Items") {
                Text("\(items.count)")
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
            }
            LabeledContent("Scheduled entries") {
                Text("\(occurrences.count)")
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
            }
            LabeledContent("Storage") {
                Text(storeDescription)
                    .foregroundStyle(Palette.textSecondary)
            }
        } header: {
            Text("Storage")
        }
    }

    private var storeDescription: String {
        switch storeMode {
        case .synced: "iCloud"
        case .local:  "This device"
        case .memory: "Temporary"
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version") {
                Text(versionString)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}
