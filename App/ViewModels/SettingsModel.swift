import Foundation
import Observation
import SwiftUI

/// What Settings shows and edits: the preferences, "What the assistant remembers", learned suggestions and AI
/// consent. Reads are synchronous snapshots refreshed whenever any process posts a change; every write goes
/// through `PreferencesStore.update(source: .settings)`, which also keeps the ledger.
@MainActor
@Observable
final class SettingsModel {
    private(set) var preferences: AppPreferences
    private(set) var ledger: [LedgerEntry] = []
    private(set) var pendingSuggestions: [LearnedSuggestion] = []
    private(set) var consent: AIConsent

    @ObservationIgnored private let store: PreferencesStore
    @ObservationIgnored private var observations: [SharedChangeObservation] = []
    /// Writes are queued so a quick run of changes (a stepper) lands in order.
    @ObservationIgnored private var lastWrite: Task<Void, Never>?

    init(store: PreferencesStore = .shared) {
        self.store = store
        preferences = store.current()
        consent = AIConsentStore.current
    }

    /// Previews: fixed values, nothing is read or written.
    init(preview preferences: AppPreferences, ledger: [LedgerEntry] = [], suggestions: [LearnedSuggestion] = [],
         consent: AIConsent = AIConsent()) {
        store = PreferencesStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-preview-\(UUID().uuidString).json"))
        self.preferences = preferences
        self.ledger = ledger
        pendingSuggestions = suggestions
        self.consent = consent
    }

    /// Starts following changes from every process; call when Settings appears.
    func start() async {
        if observations.isEmpty {
            observations = [
                SharedChangeNotifier.observe(.preferences) { [weak self] in
                    Task { @MainActor [weak self] in await self?.reload() }
                },
                SharedChangeNotifier.observe(.consent) { [weak self] in
                    Task { @MainActor [weak self] in self?.consent = AIConsentStore.current }
                }
            ]
        }
        await reload()
    }

    func reload() async {
        preferences = store.current()
        ledger = await store.ledger()
        pendingSuggestions = await store.pendingSuggestions()
        consent = AIConsentStore.current
    }

    // MARK: Writing

    /// Applies `change` at once on screen and saves it with ledger source "Changed in Settings".
    func update(_ change: @escaping @Sendable (inout AppPreferences) -> Void) {
        change(&preferences)
        let previous = lastWrite
        let store = store
        lastWrite = Task { [weak self] in
            await previous?.value
            await store.update(source: .settings, change)
            await self?.reloadLedger()
        }
    }

    /// A binding that reads the current value and writes through `update`.
    func binding<Value: Sendable>(_ keyPath: WritableKeyPath<AppPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { self.preferences[keyPath: keyPath] },
            set: { value in self.update { $0[keyPath: keyPath] = value } }
        )
    }

    func reminders(for kind: ScheduleEvent.Kind) -> [Int] {
        preferences.reminders(for: kind)
    }

    func setReminders(_ minutes: [Int], for kind: ScheduleEvent.Kind) {
        update { $0.setReminders(minutes, for: kind) }
    }

    func setUrgency(_ urgency: ReminderUrgency, for kind: ScheduleEvent.Kind) {
        update { $0.setUrgency(urgency, for: kind) }
    }

    func deleteLedgerEntries(_ ids: [UUID]) {
        ledger.removeAll { ids.contains($0.id) }
        let store = store
        Task { [weak self] in
            for id in ids { await store.deleteLedgerEntry(id: id) }
            await self?.reload()
        }
    }

    /// "Stop it" / "Keep" on a suggestion in Settings › Notifications.
    func resolveSuggestion(_ suggestion: LearnedSuggestion, accept: Bool) {
        pendingSuggestions.removeAll { $0.id == suggestion.id }
        let store = store
        Task { [weak self] in
            await store.resolveSuggestion(id: suggestion.id, accept: accept)
            await self?.reload()
        }
    }

    // MARK: AI consent

    func allowAI() {
        AIConsentStore.grant()
        consent = AIConsentStore.current
    }

    func stopSharingAI() {
        AIConsentStore.revoke()
        consent = AIConsentStore.current
    }

    private func reloadLedger() async {
        ledger = await store.ledger()
    }
}

// MARK: - Display helpers shared by the Settings pages

extension ScheduleEvent.Kind {
    /// Settings rows: "Events", "Deadlines", "Tasks", "Routines".
    var settingsTitle: LocalizedStringKey {
        switch self {
        case .event: "Events"
        case .deadline: "Deadlines"
        case .task: "Tasks"
        case .routine: "Routines"
        }
    }

    var remindersKey: PreferenceKey {
        switch self {
        case .event: .eventReminders
        case .deadline: .deadlineReminders
        case .task: .taskReminders
        case .routine: .routineReminders
        }
    }

    var urgencyKey: PreferenceKey {
        switch self {
        case .event: .eventUrgency
        case .deadline: .deadlineUrgency
        case .task: .taskUrgency
        case .routine: .routineUrgency
        }
    }

    /// The order Settings lists them in.
    static let settingsOrder: [ScheduleEvent.Kind] = [.event, .deadline, .task, .routine]
}

/// Minute of the day ↔ the `Date` a time picker edits. A fixed day in UTC (the pickers show UTC too), so daylight
/// saving never moves a time.
enum SettingsTime {
    private static let utc = TimeZone(identifier: "UTC")!
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }
    private static let referenceDay = Date(timeIntervalSinceReferenceDate: 0) // 2001-01-01 00:00 UTC

    static var timeZone: TimeZone { utc }

    static func date(minuteOfDay: Int) -> Date {
        referenceDay.addingTimeInterval(TimeInterval(min(max(minuteOfDay, 0), 1439) * 60))
    }

    static func minuteOfDay(_ date: Date) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
