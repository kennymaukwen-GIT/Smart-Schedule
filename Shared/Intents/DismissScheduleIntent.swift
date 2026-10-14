import AppIntents

/// Island close button. Not placed on any Live Activity view yet (see docs/liveactivity-tap-baseline.md).
struct DismissScheduleIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Hide Smart Schedule"

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await LiveActivityManager.shared.dismiss()
        return .result()
    }
}
