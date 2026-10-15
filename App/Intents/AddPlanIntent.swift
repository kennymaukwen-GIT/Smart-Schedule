import AppIntents

/// Zero-UI input for Siri, Spotlight, Shortcuts and the Action Button:
/// "Hey Siri, add a plan in Smart Schedule" → Siri asks "What should I schedule?" → done, app never opens.
/// A request without a clock time gets the assistant's "what time?" question, answered in the same exchange.
struct AddPlanIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Smart Schedule"
    static let description = IntentDescription("Describe an event or a goal; Smart Schedule writes it to Google Calendar. Long-term plans wait in the app until you review them and tap Add.")
    static let openAppWhenRun = false

    @Parameter(title: "Plan", requestValueDialog: "What should I schedule?")
    var text: String

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let demo = AppConstants.isDemoMode
        // Nothing may reach Gemini before the user allowed it in the app (the sheet cannot be shown from Siri).
        guard demo || AIConsentStore.current.isGranted else {
            return .result(dialog: "\(Self.consentNeeded)")
        }
        let assistant: any ScheduleAssisting = demo ? DemoAssistant() : ScheduleAssistant.shared
        var reply: ScheduleAssistant.Reply
        do {
            reply = try await assistant.handle(text, focusEventID: nil, now: Date())
            // "明天下午的「看牙醫」要排在幾點？": Siri asks and the same assistant reads the answer, so it still knows the
            // event (Gemini's conversation, the demo's draft). Twice at most.
            var rounds = 0
            while reply.needsClarification, reply.planDraft == nil, reply.pendingEvents == nil, rounds < 2 {
                let question: IntentDialog = "\(reply.text)"
                let answer = try await $text.requestValue(question)
                reply = try await assistant.handle(answer, focusEventID: nil, now: Date())
                rounds += 1
            }
        } catch GeminiError.consentRequired {
            return .result(dialog: "\(Self.consentNeeded)") // revoked meanwhile
        }
        await LiveActivityManager.shared.refreshIfRunning()
        let next = String(localized: "Open Smart Schedule to review it and tap Add.")
        if let plan = reply.planDraft {
            // The draft is already in the App Group; the app shows its card with Add / Keep editing.
            return .result(dialog: "\(plan.summary) \(next)")
        }
        if let batch = reply.pendingEvents {
            // "Ask me first": the events wait in the App Group; the app shows them with Add / Edit.
            let summary = ReplyFormatter.pendingEventsSummary(batch, clock: WallClock())
            return .result(dialog: "\(summary) \(next)")
        }
        return .result(dialog: "\(reply.text)")
    }

    private static var consentNeeded: String {
        String(localized: "Turn on AI data sharing in Smart Schedule's Settings first.")
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
            intent: OpenQuickCaptureIntent(),
            phrases: ["Open Quick Capture in \(.applicationName)"],
            shortTitle: "Quick Capture",
            systemImageName: "square.and.pencil"
        )
    }
}
