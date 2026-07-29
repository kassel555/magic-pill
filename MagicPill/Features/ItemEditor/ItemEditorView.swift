import SwiftUI
import SwiftData
import MagicPillKit

/// Add or edit a tracked item and its schedule.
///
/// This is the densest screen in the app and the one most at risk of feeling
/// like a medical form — the thing the manifesto explicitly rejects. It stays
/// calm by keeping the first section to just a name, and hiding repeat
/// configuration behind a picker that most users will never change off "Every
/// day".
struct ItemEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(ScheduleCoordinator.self) private var coordinator

    /// Nil when adding. Editing works on a draft and commits on save, so
    /// cancelling genuinely discards.
    private let existingItem: TrackedItem?

    @State private var draft: ItemDraft
    @State private var showingDeleteConfirmation = false
    @State private var saveError: String?

    init(item: TrackedItem? = nil) {
        self.existingItem = item
        _draft = State(initialValue: ItemDraft(item: item))
    }

    private var isEditing: Bool { existingItem != nil }

    var body: some View {
        NavigationStack {
            Form {
                detailsSection
                appearanceSection
                ScheduleEditor(draft: $draft)
                if isEditing { deleteSection }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.surface)
            .navigationTitle(isEditing ? "Edit Item" : "New Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier(A11y.Editor.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!draft.isValid)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier(A11y.Editor.save)
                }
            }
            .tint(Palette.accentText)
            .alert(
                "Couldn't save",
                isPresented: .init(
                    get: { saveError != nil },
                    set: { if !$0 { saveError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .confirmationDialog(
                "Delete this item?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its history will be removed too. This can't be undone.")
            }
        }
    }

    // MARK: - Sections

    private var detailsSection: some View {
        Section {
            // All three fields wrap rather than staying on one line. A
            // single-line `TextField` clips its own text at larger Dynamic Type
            // sizes — the accessibility audit says so explicitly — and a
            // medication name the user cannot read back is worse than a row
            // that grew a little.
            TextField("Name", text: $draft.name, axis: .vertical)
                .lineLimit(1...2)
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier(A11y.Editor.name)

            TextField("Amount, e.g. 1 Tablet", text: $draft.detail, axis: .vertical)
                .lineLimit(1...2)
                .textInputAutocapitalization(.sentences)
                .accessibilityIdentifier(A11y.Editor.detail)

            TextField("Note, e.g. Take with breakfast", text: $draft.note, axis: .vertical)
                .lineLimit(1...3)
                .textInputAutocapitalization(.sentences)
                .accessibilityIdentifier(A11y.Editor.note)
        } header: {
            Text("Details")
        }
    }

    @ViewBuilder
    private var appearanceSection: some View {
        Section {
            // v1 surfaces medication only. The picker appears automatically the
            // day `TemplateKind.available` returns more than one — no other
            // change is needed here to become the universal tracker.
            if TemplateKind.available.count > 1 {
                Picker("Type", selection: $draft.template) {
                    ForEach(TemplateKind.available) { template in
                        Label(template.displayName, systemImage: template.symbolName)
                            .tag(template)
                    }
                }
            }

            ColorTokenPicker(selection: $draft.colorToken)
        } header: {
            Text("Appearance")
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Text("Delete Item")
                    .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier(A11y.Editor.delete)
        }
    }

    // MARK: - Actions

    private func save() {
        do {
            try draft.commit(existing: existingItem, context: context)
            dismiss()

            // Ask for notification permission here rather than at launch. The
            // user has just created something they want to be reminded about,
            // so the prompt makes sense; asked cold on first launch it gets
            // denied, and iOS never asks again.
            Task { await coordinator.requestNotificationPermissionIfNeeded() }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func delete() {
        guard let existingItem else { return }
        context.delete(existingItem)
        do {
            try context.save()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

// MARK: - Colour picker

private struct ColorTokenPicker: View {
    @Binding var selection: ColorToken

    var body: some View {
        HStack(spacing: Space.m) {
            ForEach(ColorToken.allCases, id: \.self) { token in
                Button {
                    selection = token
                } label: {
                    Circle()
                        .fill(token.color)
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle()
                                .stroke(Palette.textPrimary, lineWidth: 2)
                                .padding(-4)
                                .opacity(selection == token ? 1 : 0)
                        )
                        // The swatch is 26pt but the tap target is not.
                        .frame(
                            width: Metrics.minimumTapTarget,
                            height: Metrics.minimumTapTarget
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(token.displayName)
                .accessibilityAddTraits(selection == token ? [.isSelected, .isButton] : .isButton)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .calmAnimation(Motion.subtle, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Colour")
    }
}

#Preview {
    ItemEditorView()
        .modelContainer(MockData.populatedContainer())
}
