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
        // The Control Center button's intent, when it runs in this process (iOS 18), opens Quick Capture through the
        // router at once. Run in the widget extension (iOS 26), it leaves the link in the App Group: see `.active`
        // below and `deepLinkObservation`.
        DeepLinkRequests.install { AppRouter.shared.handle($0) }
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
                .task {
                    // Cold start: a Quick Capture link the widget extension wrote before the app launched opens with
                    // the first frame (the `.active` check below finds nothing then: taken once).
                    DeepLinkRequests.routePending(to: { router.handle($0) })
                    // History first: cards for a draft or batch found in the App Group are matched against it.
                    await chat.loadHistory()
                    await schedule.bootstrap()
                    chat.syncPendingPlan(schedule.pendingPlan)
                    chat.syncPendingEvents(schedule.pendingEvents)
                    await chat.appendLearnedSuggestions()
                    await LiveActivityManager.shared.summonIfDue()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // A Quick Capture request the intent could only leave in the App Group. The widget extension may write
                // it just after the app comes forward, so with nothing waiting the app looks once more a moment
                // later; a later write still arrives through `.deepLink` (AppDelegate). Taken once, opened once.
                if !DeepLinkRequests.routePending(to: { router.handle($0) }) {
                    Task {
                        try? await Task.sleep(for: DeepLinkRequests.lateWriteDelay)
                        DeepLinkRequests.routePending(to: { router.handle($0) })
                    }
                }
                Task {
                    // Events before the draft (reloadFromCache's order): a plan added from Siri or a notification
                    // must already be in `events` when its card is settled. refresh() skips this while signed out.
                    await schedule.reloadAccounts()
                    await schedule.reloadFromCache()
                    chat.refreshConsent()
                    await chat.appendLearnedSuggestions()
                    await schedule.refresh(.foreground)
                    await LiveActivityManager.shared.summonIfDue()
                    await AppAttestClient.shared.refreshSessionIfNeeded()
                }
                Task {
                    // Lists older than 6 h; new calendars show up through the `.accounts` change.
                    await AccountManager.shared.refreshCalendarLists()
                }
                // Changes made in Google show up within a minute while the app is in front.
                schedule.startForegroundSync()
            case .background:
                schedule.stopForegroundSync()
                AppRefresh.schedule()
            default: break
            }
        }
        .backgroundTask(.appRefresh(AppConstants.backgroundRefreshTaskID)) {
            await AppRefresh.run()
        }
    }
}

/// Deep-link router (island / lock-screen links) and what the main screen presents.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    /// Quick Capture is open. `startsWithVoice`: opened by `DeepLink.composeVoice` (`?mode=voice`), so the mic starts
    /// when it can without a permission prompt (recognised on this iPhone); otherwise the keyboard comes up as for
    /// `DeepLink.compose`.
    struct QuickCapture: Equatable {
        var startsWithVoice = false
        /// New for every compose link, so a second `?mode=voice` while Quick Capture is still open starts the mic
        /// again.
        var id = UUID()
    }

    /// The sheets the main screen presents.
    enum Sheet: String, Identifiable {
        /// The avatar: Google accounts (and Smart Schedules Pro when `AppConstants.subscriptionsEnabled`).
        case accounts
        /// The drawer's General row.
        case settings
        /// "Add Google account" / "Connect Google Calendar" from the drawer and the welcome state (the account
        /// sheet pushes the same page instead).
        case addAccount

        var id: String { rawValue }
    }

    var quickCapture: QuickCapture?
    var selectedEventID: String?
    /// The calendar drawer (hamburger): accounts, calendars, visibility.
    var isDrawerOpen = false
    var sheet: Sheet?

    /// What the main screen shows over Quick Capture as well: the drawer, a sheet, or the event page (RootView shows it
    /// while `selectedEventID` names an event the schedule has). The mic doesn't listen under them
    /// (`ComposerBar.isCovered`).
    func coversQuickCapture(_ schedule: ScheduleViewModel) -> Bool {
        isDrawerOpen || sheet != nil || selectedEventID.flatMap(schedule.event(id:)) != nil
    }

    func handle(_ url: URL) {
        guard url.scheme == AppConstants.urlScheme else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host {
        case "compose":
            // The drawer closes (as for `openSheet`). A sheet or the event page stays, since closing it could lose an
            // edit; Quick Capture opens under it and its composer brings the keyboard up instead of the mic
            // (`ComposerBar.isCovered`), so nothing records out of sight.
            isDrawerOpen = false
            quickCapture = QuickCapture(startsWithVoice: DeepLink.startsVoiceInput(url))
        case "event":
            selectedEventID = items.first { $0.name == "id" }?.value
        case "settings":
            openSheet(.settings)
        case "accounts":
            openSheet(.accounts)
        default:
            break
        }
    }

    /// Closes the drawer and Quick Capture first, so the sheet is the only thing on top.
    func openSheet(_ sheet: Sheet) {
        isDrawerOpen = false
        quickCapture = nil
        self.sheet = sheet
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var consentObservation: SharedChangeObservation?
    private var deepLinkObservation: SharedChangeObservation?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationIDs.registerCategories()
        // Every sync that changes the cache reschedules reminders and refreshes the Live Activity.
        AppRefresh.installSyncHooks()
        // iOS 18 push-to-start, off in version 1.0 (AppConstants.pushToStartEnabled): the registration would go to
        // Smart Schedule's server (App Attest), which starts each event's Live Activity on time. Off, no uploader is
        // installed, so nothing about events or push tokens can leave the iPhone.
        PushToStartRegistrar.install(enabled: AppConstants.pushToStartEnabled) { registration in
            guard let body = try? PushToStartRegistrar.encoder.encode(registration) else { return false }
            return (try? await ServerClient.shared.post("devices/push-to-start", json: body)) != nil
        }
        // Consent given or withdrawn (here or in the notification extension): the extension gets its session, and
        // with push-to-start on the server gets the events or forgets them (a Live Activity pass). Off, consent
        // changes nothing about the Live Activities, which then stay on the iPhone.
        consentObservation = SharedChangeNotifier.observe(.consent) {
            Task { @MainActor in
                if AppConstants.pushToStartEnabled {
                    await LiveActivityManager.shared.refreshIfRunning()
                }
                await AppAttestClient.shared.refreshSessionIfNeeded()
            }
        }
        // The Control Center button's link, left in the App Group by the widget extension (iOS 26) after the app came
        // forward: Quick Capture opens as soon as it is written. Not while in the background: it waits for `.active`.
        deepLinkObservation = SharedChangeNotifier.observe(.deepLink) {
            Task { @MainActor in
                guard UIApplication.shared.applicationState != .background else { return }
                DeepLinkRequests.routePending(to: { AppRouter.shared.handle($0) })
            }
        }
        // Finishes transactions that arrived while the app was closed and keeps `isPro` current. Version 1.0 sells
        // nothing (AppConstants.subscriptionsEnabled), so StoreKit is not touched at all.
        if AppConstants.subscriptionsEnabled {
            Task { @MainActor in SubscriptionStore.shared.start() }
        }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive])
        }
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Quiet reminders (Quiet urgency, quiet hours) stay silent while the app is open too.
        notification.request.content.interruptionLevel == .passive ? [.list] : [.banner, .list, .sound]
    }

    /// Replies sent from a *collapsed* banner (content extension not loaded) arrive here with the app
    /// launched in the background. Run the same pipeline and answer with a follow-up notification.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        // Every response, a swipe-away included (`.customDismissAction`), feeds the learned suggestions.
        await ReminderEngagement.record(response)

        let content = response.notification.request.content
        let eventID = content.userInfo[NotificationIDs.UserInfo.eventID] as? String

        switch response.actionIdentifier {
        case NotificationIDs.Action.reply:
            guard let text = (response as? UNTextInputNotificationResponse)?.userText else { return }
            var answer: String
            var planID: String?
            var batchID: String?
            // Demo mode: the AI on the sample data with consent, its offline rules without (it never refuses).
            let assistant: any ScheduleAssisting = AppConstants.isDemoMode ? DemoModeAssistant() : ScheduleAssistant.shared
            do {
                let reply = try await assistant.handle(text, focusEventID: eventID, now: Date())
                answer = reply.text
                if let plan = reply.planDraft {
                    // Nothing is written yet. Expanding the follow-up shows the plan card (Add / Keep editing).
                    answer = plan.summary + "\n" + String(localized: "Press and hold to review it, then tap Add.")
                    planID = plan.id
                } else if let batch = reply.pendingEvents {
                    // "Ask me first": the expanded follow-up shows the events with Add / Edit.
                    let summary = reply.text.replacingOccurrences(of: ReplyFormatter.pendingEventsPrompt, with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    answer = summary + "\n" + String(localized: "Press and hold to review it, then tap Add.")
                    batchID = batch.id
                }
            } catch GeminiError.consentRequired {
                answer = String(localized: "Turn on AI data sharing in Smart Schedules › Settings › AI & privacy to reply here.")
            } catch {
                answer = error.localizedDescription
            }
            await Self.postFollowUp(answer, planID: planID, batchID: batchID)
            await LiveActivityManager.shared.refreshIfRunning()

        case NotificationIDs.Action.snooze10:
            await ReminderScheduler.snooze(content, minutes: 10)

        case UNNotificationDefaultActionIdentifier:
            if let eventID { await MainActor.run { AppRouter.shared.selectedEventID = eventID } }
            await LiveActivityManager.shared.refreshIfRunning()

        default:
            // UNNotificationDismissActionIdentifier. The long-press card may have changed or deleted events (the
            // extension cannot reach the Live Activities), so they are brought in line now.
            await LiveActivityManager.shared.refreshIfRunning()
        }
    }

    /// `planID` / `batchID`: the draft plan or "Ask me first" batch this follow-up presents; the content extension
    /// shows its card while it is still the pending one.
    private static func postFollowUp(_ text: String, planID: String? = nil, batchID: String? = nil) async {
        let content = UNMutableNotificationContent()
        content.title = "Smart Schedules"
        content.body = text
        content.categoryIdentifier = NotificationIDs.Category.compose // keep the conversation going in place
        var userInfo: [AnyHashable: Any] = [:]
        if let planID { userInfo[NotificationIDs.UserInfo.planID] = planID }
        if let batchID { userInfo[NotificationIDs.UserInfo.pendingBatchID] = batchID }
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: "ss.followup.\(UUID().uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
