import Foundation
import Observation

@MainActor
@Observable
final class ScheduleViewModel {
    var events: [ScheduleEvent] = []
    /// A long-term plan shown for review but not in Google Calendar yet. Its `previewEvents` are drawn as ghosts.
    var pendingPlan: PlanDraft?
    var displayedMonth: Date
    var focusDay = Date()
    /// The latest range the assistant asked to show (Quick Capture switches scope and scrolls to it).
    private(set) var focusRequest: FocusRequest?
    var isSignedIn = false
    var isRefreshing = false
    var isDemo = false
    var lastError: String?

    let clock = WallClock()

    /// A fresh `id` per request, so asking for the same range twice still reaches `onChange` observers.
    struct FocusRequest: Equatable {
        let id = UUID()
        let range: DateInterval
        /// Overrides the scope Quick Capture would pick for `range` (a plan draft always opens on WEEK).
        var scope: CalendarScope?
    }

    init() {
        displayedMonth = WallClock().calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
    }

    /// JUN … FEB around today (Artboard 5 month chips).
    var monthStrip: [Date] {
        let calendar = clock.calendar
        let current = calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
        return (-4...4).compactMap { calendar.date(byAdding: .month, value: $0, to: current) }
    }

    func bootstrap() async {
        if AppConstants.isDemoMode {
            // Copies a `-SSDemoMode YES` launch argument into the App Group so the notification extension follows.
            AppConstants.setDemoMode(true)
            isDemo = true
        } else {
            isSignedIn = await GoogleTokenProvider.shared.isSignedIn
        }
        await reloadFromCache()
        await refresh()
    }

    /// Calendar events plus the pending plan's preview occurrences, for the WEEK and MONTH cards.
    var displayEvents: [ScheduleEvent] {
        guard let preview = pendingPlan?.previewEvents, !preview.isEmpty else { return events }
        return events + preview
    }

    func reloadFromCache() async {
        events = await SharedStore.shared.snapshot().events.sorted { $0.start < $1.start }
        await reloadPendingPlan() // after `events`: ChatViewModel.syncPendingPlan looks for the plan's events
    }

    /// The draft lives in the App Group, so Siri and the notification extension can create, add or discard it too.
    func reloadPendingPlan() async {
        let plan = await SharedStore.shared.pendingPlan()
        if plan != pendingPlan { pendingPlan = plan }
    }

    func refresh() async {
        if isDemo || AppConstants.isDemoMode {
            await refreshDemo(reseed: false)
            return
        }
        guard isSignedIn, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await CalendarSync(clock: clock).refreshWindow()
            await reloadFromCache()
            await ReminderScheduler.shared.reschedule()
            await LiveActivityManager.shared.refreshIfRunning()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            if let authError = error as? AuthError, case .refreshFailed = authError { isSignedIn = false }
        }
    }

    /// "Try demo (no account)": sample data, offline assistant, Live Activity, no Google or Gemini.
    func startDemo() async {
        AppConstants.setDemoMode(true)
        await SharedStore.shared.setPendingPlan(nil) // a draft belongs to the assistant that made it
        await refreshDemo(reseed: true)
        try? await LiveActivityManager.shared.summon()
    }

    func stopDemo() async {
        AppConstants.setDemoMode(false)
        isDemo = false
        let store = SharedStore.shared
        let snapshot = await store.snapshot()
        await store.remove(ids: Set(snapshot.events.map(\.id).filter(DemoData.isDemoID)))
        for planID in Set(snapshot.nudges.map(\.planID).filter(DemoData.isDemoID)) {
            await store.removeNudges(planID: planID)
        }
        await store.setPendingPlan(nil) // a demo draft must not reach Google through the real assistant
        await reloadFromCache()
        await ReminderScheduler.shared.reschedule()
        await LiveActivityManager.shared.refreshIfRunning()
        // bootstrap() skips the keychain check in demo mode, and seeding replaced the cached Google window.
        isSignedIn = await GoogleTokenProvider.shared.isSignedIn
        if isSignedIn { await refresh() }
    }

    /// Demo replacement for the Google sync: seeds `DemoData` (once, unless `reseed`), then refreshes the
    /// same local surfaces a real sync would.
    private func refreshDemo(reseed: Bool) async {
        isDemo = true
        let store = SharedStore.shared
        let hasDemoData = await store.snapshot().events.contains { DemoData.isDemoID($0.id) }
        if reseed || !hasDemoData {
            let demo = DemoData.events(clock: clock)
            if let window = DemoData.interval(covering: demo) {
                await store.replaceWindow(window, with: demo)
            }
        }
        await reloadFromCache()
        lastError = nil
        await ReminderScheduler.shared.reschedule()
        await LiveActivityManager.shared.refreshIfRunning()
    }

    func signIn() async {
        do {
            try await GoogleSignInCoordinator().signIn()
            isSignedIn = true
            await refresh()
            try? await LiveActivityManager.shared.summon()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Includes the pending plan's ghost occurrences.
    func events(on day: Date) -> [ScheduleEvent] {
        let interval = CalendarPaging.dayInterval(containing: day, calendar: clock.calendar) // 23/25 h on DST days
        let preview = pendingPlan?.previewEvents.filter { $0.intersects(interval) } ?? []
        return (events.filter { $0.intersects(interval) } + preview)
            .sorted { lhs, rhs in
                // Multi-day bars first so they line up across cells, then by time.
                let lhsSpan = lhs.duration >= 86_400, rhsSpan = rhs.duration >= 86_400
                return lhsSpan != rhsSpan ? lhsSpan : lhs.start < rhs.start
            }
    }

    func focus(_ interval: DateInterval, scope: CalendarScope? = nil) {
        focusDay = interval.start
        displayedMonth = clock.calendar.dateInterval(of: .month, for: interval.start)?.start ?? displayedMonth
        focusRequest = FocusRequest(range: interval, scope: scope)
    }

    func event(id: String) -> ScheduleEvent? {
        events.first { $0.id == id }
    }
}
