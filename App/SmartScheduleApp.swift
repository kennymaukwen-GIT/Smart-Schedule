// AppIntents with SwiftUI loads the overlay that declares View.onAppIntentExecution (QuickCaptureSceneRouting).
import AppIntents
import os
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
        Logger.launch.notice("App init")
        // The Control Center button's intent (an `OpenIntent`, run in this process) opens Quick Capture through the
        // router at once. Should it run in the widget extension, it leaves the link in the App Group: see `.active`
        // below and `deepLinkObservation`. On iOS 26 the scene usually opened it already (`QuickCaptureSceneRouting`),
        // and this repeat is skipped.
        DeepLinkRequests.install { AppRouter.shared.handleIntentLink($0, from: "perform") }
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
                .onOpenURL { router.handle($0, from: "url") }
                // iOS 26: Quick Capture opens before the app is shown when the Control Center button launches it.
                .modifier(QuickCaptureSceneRouting())
                // The app's one scene takes every link and app intent (UIApplicationSupportsMultipleScenes is on only so
                // App Intents can reach the scene at launch), so iOS never makes a second one for them.
                .handlesExternalEvents(preferring: [], allowing: ["*"])
                .task {
                    Logger.launch.notice("First task")
                    // Cold start: a Quick Capture link the widget extension wrote before the app launched opens with
                    // the first frame (the `.active` check below finds nothing then: taken once).
                    DeepLinkRequests.routePending(to: { router.handleIntentLink($0, from: "pending at launch") })
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
                Logger.launch.notice("Scene active")
                // A Quick Capture request the intent could only leave in the App Group. The widget extension may write
                // it just after the app comes forward, so with nothing waiting the app looks once more a moment
                // later; a later write still arrives through `.deepLink` (AppDelegate). Taken once, opened once.
                if !DeepLinkRequests.routePending(to: { router.handleIntentLink($0, from: "pending on active") }) {
                    Task {
                        try? await Task.sleep(for: DeepLinkRequests.lateWriteDelay)
                        DeepLinkRequests.routePending(to: { router.handleIntentLink($0, from: "pending, late") })
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
    }
}

/// iOS 26: the Control Center button's `OpenQuickCaptureIntent` reaches this scene before the app is shown (Apple: "Your
/// closure runs before the app comes to the foreground and before the system calls the app intent's perform() method"),
/// so Quick Capture is already open on the first frame instead of after the main screen. iOS 18 has no such API and
/// opens it from `perform()`, as before.
private struct QuickCaptureSceneRouting: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.onAppIntentExecution(OpenQuickCaptureIntent.self) { _ in
                AppRouter.shared.openQuickCaptureFromScene()
            }
        } else {
            content
        }
    }
}

extension Logger {
    /// Console.app › the iPhone › subsystem com.smartschedules.app, category "Launch": when the app starts, comes forward
    /// and opens Quick Capture (and from where), to time the Control Center button without a debugger.
    static let launch = Logger(subsystem: "com.smartschedules.app", category: "Launch")
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

    struct AgendaDay: Identifiable, Equatable {
        let date: Date
        var id: Date { date }
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
    /// iOS 26: when the scene opened Quick Capture for a Control Center tap (`openQuickCaptureFromScene`), so the same
    /// tap's `perform()` doesn't open it again (`handleIntentLink`).
    @ObservationIgnored private var sceneOpenedQuickCaptureAt: Date?
    var selectedEventID: String?
    /// The day whose events are listed (`DayAgendaSheet`): a date held down in the main month grid. It closes when
    /// Quick Capture or a Settings / Accounts link opens, unless an event page is open over it (that could hold an edit).
    var agendaDay: AgendaDay?
    /// The event page open over the day list. A reminder tapped or an event link while the list is open opens here, on
    /// top of it, since the main screen can't show a second sheet then (`showEvent`).
    var agendaEventID: String?
    /// The calendar drawer (hamburger): accounts, calendars, visibility.
    var isDrawerOpen = false
    var sheet: Sheet?

    /// What the main screen shows over Quick Capture as well: the drawer, a sheet, or the event page (RootView shows it
    /// while `selectedEventID` names an event the schedule has). The mic doesn't listen under them
    /// (`ComposerBar.isCovered`).
    func coversQuickCapture(_ schedule: ScheduleViewModel) -> Bool {
        isDrawerOpen || sheet != nil || agendaDay != nil || selectedEventID.flatMap(schedule.event(id:)) != nil
    }

    /// iOS 26: the Control Center button's intent reached the scene before the app is shown (`QuickCaptureSceneRouting`).
    func openQuickCaptureFromScene(now: Date = Date()) {
        sceneOpenedQuickCaptureAt = now
        handle(DeepLink.compose, from: "scene")
    }

    /// A link from the Control Center intent's `perform()` or its App Group hand-off. Skipped once when the scene already
    /// opened Quick Capture for the same tap, so a Quick Capture the user has just closed doesn't come back.
    func handleIntentLink(_ url: URL, from source: String, now: Date = Date()) {
        if DeepLinkRequests.isSceneEcho(url, sceneOpenedAt: sceneOpenedQuickCaptureAt, now: now) {
            sceneOpenedQuickCaptureAt = nil
            Logger.launch.notice("Quick Capture already open from the scene; \(source, privacy: .public) skipped")
            return
        }
        handle(url, from: source)
    }

    /// `source` only labels the log line: Console.app › subsystem com.smartschedules.app › category Launch.
    /// Opens an event page wherever one can show now: over the day list when it is open, otherwise from the main screen.
    func showEvent(_ id: String) {
        if agendaDay != nil {
            agendaEventID = id
        } else {
            selectedEventID = id
        }
    }

    func handle(_ url: URL, from source: String = "url") {
        guard url.scheme == AppConstants.urlScheme else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host {
        case "compose":
            Logger.launch.notice("Open Quick Capture (from \(source, privacy: .public))")
            // The drawer closes (as for `openSheet`), and so does the day list unless an event page is open over it.
            // A sheet or the event page stays, since closing it could lose an edit; Quick Capture opens under it and
            // its composer brings the keyboard up instead of the mic (`ComposerBar.isCovered`), so nothing records out
            // of sight.
            isDrawerOpen = false
            if agendaEventID == nil { agendaDay = nil }
            quickCapture = QuickCapture(startsWithVoice: DeepLink.startsVoiceInput(url))
        case "event":
            if let id = items.first(where: { $0.name == "id" })?.value { showEvent(id) }
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
        if agendaEventID == nil { agendaDay = nil }
        self.sheet = sheet
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var consentObservation: SharedChangeObservation?
    private var deepLinkObservation: SharedChangeObservation?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Before launch finishes, every time: also when iOS launches the app for an App Intent (AppRefresh).
        AppRefresh.registerHandler()
        Logger.launch.notice("didFinishLaunching")
        // Neither needs permission; it is asked in context (ScheduleViewModel.requestNotificationPermissionIfNeeded).
        UNUserNotificationCenter.current().delegate = self
        NotificationIDs.registerCategories()
        // Every sync that changes the cache reschedules reminders and refreshes the Live Activity.
        AppRefresh.installSyncHooks()
        // iOS 26: a scheduled Live Activity alerts when it starts, so the reminder due then is left out; reminders
        // follow changes. Every caller reschedules them before the Live Activity pass, so this one runs after it, and the
        // pass waits for it (no half-rescheduled reminders when the app is suspended in the background).
        ActivityScheduler.shared.scheduledStartsChanged = { await ReminderScheduler.shared.reschedule() }
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
        // The Control Center button's link, left in the App Group when its intent ran in the widget extension: Quick
        // Capture opens as soon as it is written. Not while in the background: it waits for `.active`.
        deepLinkObservation = SharedChangeNotifier.observe(.deepLink) {
            Task { @MainActor in
                guard UIApplication.shared.applicationState != .background else { return }
                DeepLinkRequests.routePending(to: { AppRouter.shared.handleIntentLink($0, from: "pending, darwin") })
            }
        }
        // Finishes transactions that arrived while the app was closed and keeps `isPro` current. Version 1.0 sells
        // nothing (AppConstants.subscriptionsEnabled), so StoreKit is not touched at all.
        if AppConstants.subscriptionsEnabled {
            Task { @MainActor in SubscriptionStore.shared.start() }
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
            if let eventID { await MainActor.run { AppRouter.shared.showEvent(eventID) } }
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
