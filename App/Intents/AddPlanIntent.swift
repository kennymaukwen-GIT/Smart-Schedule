import AppIntents

/// Zero-UI input for Siri, Spotlight, Shortcuts and the Action Button:
/// "Hey Siri, add a plan in Smart Schedule" → Siri asks "What should I schedule?" → done, app never opens.
struct AddPlanIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Smart Schedule"
    static let description = IntentDescription("Describe an event or a goal; Smart Schedule writes it to Google Calendar.")
    static let openAppWhenRun = false

    @Parameter(title: "Plan", requestValueDialog: "What should I schedule?")
    var text: String

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = try await ScheduleAssistant.shared.handle(text)
        await LiveActivityManager.shared.refreshIfRunning()
        return .result(dialog: "\(reply.text)")
    }
}

struct SmartScheduleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddPlanIntent(),
            phrases: [
                "Add a plan in \(.applicationName)",
                "Schedule something with \(.applicationName)"
            ],
            shortTitle: "Add Plan",
            systemImageName: "calendar.badge.plus"
        )
        AppShortcut(
            intent: SummonScheduleIntent(),
            phrases: ["Show my schedule in \(.applicationName)"],
            shortTitle: "Summon",
            systemImageName: "clock"
        )
    }
}
