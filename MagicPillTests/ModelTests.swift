import Testing
import Foundation
import SwiftData
@testable import MagicPillKit

/// Phase 1 tests: the model layer holds together and the CloudKit-compliant
/// schema actually initialises. The scheduling engine's tests — DST, time-zone
/// travel, idempotent regeneration — land with Phase 4.
@Suite("Model")
struct ModelTests {

    @Test("Schema initialises")
    func schemaInitialises() throws {
        // Catches CloudKit-rule violations (non-optional relationships, missing
        // defaults) at test time rather than on a user's device at launch.
        let container = try PersistenceStore.inMemory()
        #expect(container.schema.entities.count == 3)
    }

    @Test("Item round-trips through the store")
    @MainActor
    func itemRoundTrip() throws {
        let container = try PersistenceStore.inMemory()
        let context = container.mainContext

        let item = TrackedItem(name: "Vitamin D", template: .medication, detail: "1 Tablet")
        context.insert(item)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<TrackedItem>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.name == "Vitamin D")
        #expect(fetched.first?.template == .medication)
        #expect(fetched.first?.symbolName == "pills.fill")
    }

    @Test("Unknown raw values degrade to defaults rather than crashing")
    func unknownRawValues() {
        let item = TrackedItem(name: "Legacy")
        item.templateRaw = "something-from-a-future-version"
        item.colorTokenRaw = "chartreuse"

        #expect(item.template == .medication)
        #expect(item.colorToken == .sage)
    }

    @Test("Recurrence rules survive encoding")
    func recurrenceRoundTrip() {
        let rules: [RecurrenceRule] = [
            .daily(interval: 1),
            .daily(interval: 3),
            .weekly(interval: 2, weekdays: [2, 4, 6]),
            .monthly(days: [1, 15]),
            .asNeeded,
        ]

        for rule in rules {
            #expect(RecurrenceRule.decoded(from: rule.encoded()) == rule)
        }
    }

    @Test("Corrupt rule data falls back to daily")
    func corruptRuleData() {
        #expect(RecurrenceRule.decoded(from: Data()) == .everyDay)
        #expect(RecurrenceRule.decoded(from: Data([0x00, 0x01])) == .everyDay)
    }

    @Test("As-needed generates no occurrences")
    func asNeededGeneratesNothing() {
        #expect(RecurrenceRule.asNeeded.generatesOccurrences == false)
        #expect(RecurrenceRule.everyDay.generatesOccurrences == true)
    }

    @Test("Overdue respects the grace period and never applies to resolved items")
    func overdueLogic() {
        let now = Date.now
        let occurrence = Occurrence(scheduledAt: now.addingTimeInterval(-60 * 60))

        #expect(occurrence.isOverdue(now: now) == true)
        // Within grace.
        #expect(occurrence.isOverdue(now: now, grace: 90 * 60) == false)

        occurrence.state = .taken
        #expect(occurrence.isOverdue(now: now) == false)
    }

    @Test("Snooze moves the effective time without losing the scheduled time")
    func snoozeKeepsHistory() {
        let scheduled = Date.now
        let occurrence = Occurrence(scheduledAt: scheduled)
        let later = scheduled.addingTimeInterval(15 * 60)
        occurrence.snoozedUntil = later

        #expect(occurrence.effectiveTime == later)
        #expect(occurrence.scheduledAt == scheduled)
    }

    @Test("Times of day convert symmetrically")
    func timeOfDayConversion() {
        #expect(TimeOfDay.minutes(hour: 8) == 480)
        #expect(TimeOfDay.minutes(hour: 19, minute: 30) == 1170)

        let parts = TimeOfDay.components(from: 1170)
        #expect(parts.hour == 19)
        #expect(parts.minute == 30)
    }

    @Test("Every template has a distinct, non-empty symbol")
    func templateSymbols() {
        let symbols = TemplateKind.allCases.map(\.symbolName)
        #expect(symbols.allSatisfy { !$0.isEmpty })
        #expect(Set(symbols).count == TemplateKind.allCases.count)
    }
}
