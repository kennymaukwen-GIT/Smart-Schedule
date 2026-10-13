import SwiftUI
import UserNotifications

@main
struct SmartScheduleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var router = AppRouter.shared
    @State private var schedule: ScheduleViewModel
    @State private var chat: ChatViewModel

    init() {
        let schedule = ScheduleViewModel()
        _schedule = State(initialValue: schedule)
        _chat = State(initialValue: ChatViewModel(schedule: schedule))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(router)
                .environment(schedule)
                .environment(chat)
                .preferredColorScheme(.dark)
                .onOpenURL { router.handle($0) }
                .task { await schedule.bootstrap() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task {
                    // Events before the draft (reloadFromCache's order): a plan added from Siri or a notification
                    // must already be in `events` when its card is settled. refresh() skips this while signed out.
                    await schedule.reloadFromCache()
                    await schedule.refresh()
                }
            case .background: AppRefresh.schedule()
            default: break
            }
        }
        .backgroundTask(.appRefresh(AppConstants.backgroundRefreshTaskID)) {
            await AppRefresh.run()
        }
    }
}

/// Deep-link router: island / lock-screen links land here.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    struct QuickCapture: Equatable {
        var startsWithVoice: Bool
    }

    var quickCapture: QuickCapture?
    var selectedEventID: String?

    func handle(_ url: URL) {
        guard url.scheme == AppConstants.urlScheme else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host {
        case "compose":
            quickCapture = QuickCapture(startsWithVoice: items.first { $0.name == "mode" }?.value == "voice")
        case "event":
            selectedEventID = items.first { $0.name == "id" }?.value
        default:
            break
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationIDs.registerCategories()
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive])
        }
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// Replies sent from a *collapsed* banner (content extension not loaded) arrive here with the app
    /// launched in the background. Run the same pipeline and answer with a follow-up notification.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        let eventID = content.userInfo[NotificationIDs.UserInfo.eventID] as? String

        switch response.actionIdentifier {
        case NotificationIDs.Action.reply:
            guard let text = (response as? UNTextInputNotificationResponse)?.userText else { return }
            var answer: String
            var planID: String?
            let assistant: any ScheduleAssisting = AppConstants.isDemoMode ? DemoAssistant() : ScheduleAssistant.shared
            do {
                let reply = try await assistant.handle(text, focusEventID: eventID, now: Date())
                answer = reply.text
                if let plan = reply.planDraft {
                    // Nothing is written yet. Expanding the follow-up shows the plan card (Add / Keep editing).
                    answer = plan.summary + "\n" + String(localized: "Press and hold to review it, then tap Add.")
                    planID = plan.id
                }
            } catch {
                answer = error.localizedDescription
            }
            await Self.postFollowUp(answer, planID: planID)
            await LiveActivityManager.shared.refreshIfRunning()

        case NotificationIDs.Action.snooze10:
            await ReminderScheduler.snooze(content, minutes: 10)

        case UNNotificationDefaultActionIdentifier:
            if let eventID { await MainActor.run { AppRouter.shared.selectedEventID = eventID } }

        default:
            break
        }
    }

    /// `planID`: the draft plan this follow-up presents; the content extension shows its card while it is pending.
    private static func postFollowUp(_ text: String, planID: String? = nil) async {
        let content = UNMutableNotificationContent()
        content.title = "Smart Schedule"
        content.body = text
        content.categoryIdentifier = NotificationIDs.Category.compose // keep the conversation going in place
        if let planID { content.userInfo = [NotificationIDs.UserInfo.planID: planID] }
        let request = UNNotificationRequest(identifier: "ss.followup.\(UUID().uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
