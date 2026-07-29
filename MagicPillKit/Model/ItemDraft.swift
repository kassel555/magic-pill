import Foundation
import SwiftData

/// A plain-value mirror of the item being edited.
///
/// Editing SwiftData models directly writes straight through to the store,
/// which makes a "Cancel" button a lie — the changes are already saved. The
/// draft is what makes cancelling genuinely discard.
///
/// It lives in the framework rather than beside the editor view so the whole
/// save path is testable without standing up SwiftUI. The view is then thin
/// enough to be obviously correct: collect fields, call `commit`.
public struct ItemDraft: Sendable, Equatable {
    public var name: String = ""
    public var detail: String = ""
    public var note: String = ""
    public var template: TemplateKind = .medication
    public var colorToken: ColorToken = .sage

    public var timesOfDay: [Int] = [TimeOfDay.minutes(hour: 8)]
    public var rule: RecurrenceRule = .everyDay
    public var startDate: Date = .now
    public var endDate: Date?

    public init() {}

    public init(item: TrackedItem?) {
        guard let item else { return }
        name = item.name
        detail = item.detail
        note = item.note
        template = item.template
        colorToken = item.colorToken

        guard let schedule = item.schedules?.first else { return }
        timesOfDay = schedule.timesOfDay.sorted()
        rule = schedule.rule
        startDate = schedule.startDate
        endDate = schedule.endDate
    }

    public var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A draft with no name, or with nothing to schedule, would sit in the
    /// store generating nothing and read as a bug rather than a choice.
    public var isValid: Bool {
        !trimmedName.isEmpty && !timesOfDay.isEmpty
    }

    // MARK: - Commit

    /// Writes the draft into the store, creating the item when `existing` is
    /// nil, and brings the day's occurrences back in line with the new
    /// schedule.
    ///
    /// Reconciliation is deliberately narrow: future *pending* rows from this
    /// schedule are dropped and regenerated, while past rows and anything
    /// already resolved are untouched. Changing "8:00 AM" to "9:00 AM" must not
    /// rewrite the record of doses already taken at 8:00.
    @discardableResult
    @MainActor
    public func commit(
        existing: TrackedItem? = nil,
        context: ModelContext,
        calendar: Calendar = .current,
        now: Date = .now
    ) throws -> TrackedItem {
        let item = existing ?? TrackedItem(name: trimmedName)
        if existing == nil { context.insert(item) }

        item.name = trimmedName
        item.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        item.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        item.template = template
        item.colorToken = colorToken

        // One schedule per item for now. The model supports several; the editor
        // grows into that when the UI can express it calmly.
        let schedule: Schedule
        if let first = item.schedules?.first {
            schedule = first
        } else {
            schedule = Schedule()
            schedule.item = item
            context.insert(schedule)
        }

        schedule.timesOfDay = timesOfDay.sorted()
        schedule.rule = rule
        schedule.startDate = startDate
        schedule.endDate = endDate

        try context.save()

        try OccurrenceMaterializer.removeFuturePending(
            scheduleID: schedule.id,
            after: now,
            context: context
        )
        try OccurrenceMaterializer.materialize(day: now, context: context, calendar: calendar)

        return item
    }
}
