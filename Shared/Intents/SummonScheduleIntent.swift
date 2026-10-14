import AppIntents

/// Control Center button (Artboard 3, red circle) → Live Activity appears in the Dynamic Island.
///
/// Conforming to `LiveActivityIntent` makes the system run `perform()` in the *app* process, launched in
/// the background — so the activity starts without opening the app. Compiled into both the app and the
/// widget extension because the ControlWidget references the type.
struct SummonScheduleIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Summon Smart Schedule"
    static let description = IntentDescription("Shows your next event and this week in the Dynamic Island.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        try await LiveActivityManager.shared.summon()
        // Then ask Google for changes; the app's sync hook refreshes the island if anything moved.
        Task { await SyncRequests.request("summon") }
        return .result()
    }
}

/// Island close button.
struct DismissScheduleIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Hide Smart Schedule"

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await LiveActivityManager.shared.dismiss()
        return .result()
    }
}
