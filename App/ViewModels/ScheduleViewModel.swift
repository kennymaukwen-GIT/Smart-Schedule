import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class ScheduleViewModel {
    /// Visible events (`SharedStore.visibleEvents`): hidden and Focus-filtered calendars left out, one copy per
    /// meeting seen in several accounts.
    var events: [ScheduleEvent] = []
    /// A long-term plan shown for review but not in Google Calendar yet. Its `previewEvents` are drawn as ghosts.
    var pendingPlan: PlanDraft?
    /// "Ask me first": single events waiting for Add. Their `previewEvents` are drawn as ghosts too.
    var pendingEvents: PendingEventBatch?
    var displayedMonth: Date
    var focusDay = Date()
    /// The latest range the assistant asked to show (Quick Capture switches scope and scrolls to it).
    private(set) var focusRequest: FocusRequest?
    /// Connected Google accounts in connection order; the sample accounts in demo mode.
    var accounts: [GoogleAccount] = []
    /// Where new events go (Settings › Calendar & new events, or the first account's primary calendar).
    var defaultWriteTarget: CalendarRef?
    /// Any Google account connected (one needing reconnection included), demo mode or not.
    var isSignedIn = false
    var isRefreshing = false
    var isDemo = false
    /// Account and connection problems shown over the calendar (Add account, Reconnect). Sync problems are on the
    /// drawer's status line instead (`syncStatus`), so a 60 s tick while offline never pops anything up.
    var lastError: String?
    /// Outbox, failures and the last successful sync per account: the drawer's status line, its failed list and the
    /// header's indicator. Written by `SyncEngine` in any process.
    var syncStatus: SyncStatus = SyncStatusStore.current
    /// The network path is down: shown at once, before a sync has noticed.
    var isNetworkOffline = false
    /// A short confirmation over the main screen and the account sheet ("Connected …", "Removed …"); clears itself.
    var notice: Notice?
    /// The account whose queued changes "Sync first" is sending before it is removed: its row shows progress.
    private(set) var syncingBeforeRemoval: String?
    /// Failed changes being retried or discarded from the drawer: their rows wait or disappear right away.
    private(set) var retryingChangeIDs: Set<UUID> = []
    private(set) var discardedChangeIDs: Set<UUID> = []
    /// True while `ensureEvents(covering:)` is loading a range the cache did not hold (a subtle progress hint).
    private(set) var isLoadingRange = false

    /// Follows Settings › "Time zone" and "Week starts on"; rebuilt when preferences change.
    private(set) var clock = WallClock()

    /// Cache cap: past this many cached events, ranges more than `keepMonths` from both today and the range last
    /// on screen are dropped (and listed again if they come back). About 1 MB of App Group JSON.
    static let maxCachedEvents = 2_000
    private static let keepMonths = 12
    /// `ensureEvents` waits this long after the last call, so a fling loads only where it settles.
    private static let rangeDebounce: Duration = .milliseconds(300)
    /// Xcode Previews keep their in-memory sample events and accounts; a load would swap them for the preview
    /// sandbox's empty App Group.
    private static let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    private static let loadsRangesOnDemand = !isPreview
    /// Settings changes (a stepper, a run of toggles) and account edits arrive in bursts: react once they settle.
    private static let changeDebounce: Duration = .milliseconds(400)
    /// While the app is in front, Google is asked for changes this often (`SyncTrigger.timer`).
    static let foregroundSyncInterval: Duration = .seconds(60)

    @ObservationIgnored private var rangeDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRanges: [DateInterval] = []
    @ObservationIgnored private var rangesInFlight = LoadedRanges()
    /// What the calendars last asked for (or `focus` jumped to): re-listed after a rolling refresh, kept by the cap.
    @ObservationIgnored private var lastRequestedRange: DateInterval?
    @ObservationIgnored private var observations: [SharedChangeObservation] = []
    @ObservationIgnored private var preferencesTask: Task<Void, Never>?
    @ObservationIgnored private var accountsTask: Task<Void, Never>?
    @ObservationIgnored private var syncStatusTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundSyncTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Asked for while a sync was running; runs once that one is done.
    @ObservationIgnored private var queuedTrigger: SyncTrigger?
    @ObservationIgnored private let connectivity = ConnectivityMonitor()

    /// "Connected example@gmail.com", "Removed example@gmail.com" with "New events now go to …" under it.
    struct Notice: Equatable, Identifiable {
        let id = UUID()
        var text: String
        var detail: String?
    }

    /// The "Remove account" confirmation: the account and how many of its changes have not reached Google.
    struct AccountRemoval: Equatable, Identifiable {
        var account: GoogleAccount
        var unsentChanges: Int

        var id: String { account.id }
    }

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

    /// Launch: moves a single-account sign-in to per-account storage first, then accounts, the cache, a sync.
    func bootstrap() async {
        startObserving()
        await AccountManager.shared.migrateLegacyAccountIfNeeded()
        if AppConstants.isDemoMode {
            // Copies a `-SSDemoMode YES` launch argument into the App Group so the notification extension follows.
            AppConstants.setDemoMode(true)
            isDemo = true
        }
        await reloadAccounts()
        await reloadFromCache()
        await refresh(.foreground)
        let hasCalendar = isSignedIn || isDemo
        Task { await requestNotificationPermissionIfNeeded(hasCalendar: hasCalendar) }
    }

    /// The notification prompt, in context: when "Try without signing in" starts the sample calendar (asked before
    /// it is seeded, so its reminders are scheduled after the answer), after connecting a Google account, and at launch
    /// for someone who has either but was never asked. Returns once answered (at once when iOS already has an answer).
    /// iOS refused reminders added before the answer (UNError.notificationsNotAllowed): "Allow" schedules them again.
    func requestNotificationPermissionIfNeeded(hasCalendar: Bool) async {
        guard !Self.isPreview else { return }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard NotificationPermission.shouldAsk(status: status, hasCalendar: hasCalendar) else { return }
        let granted = (try? await center.requestAuthorization(options: NotificationPermission.options)) ?? false
        if granted { await ReminderScheduler.shared.reschedule() }
    }

    /// Calendar events plus the ghost previews of the pending plan and of "Ask me first" events, for the WEEK and
    /// MONTH cards.
    var displayEvents: [ScheduleEvent] {
        let previews = previewEvents
        return previews.isEmpty ? events : events + previews
    }

    private var previewEvents: [ScheduleEvent] {
        (pendingPlan?.previewEvents ?? []) + (pendingEvents?.previewEvents ?? [])
    }

    /// Changes whenever the calendars must be laid out again from scratch (time zone or first weekday).
    var clockID: String {
        "\(clock.timeZone.identifier)|\(clock.firstWeekday)"
    }

    /// The first account's initial for the header avatar; nil (a person glyph) when signed out or in demo mode.
    var avatarInitial: String? {
        guard !isDemo, let account = accounts.first else { return nil }
        return account.initial
    }

    func reloadFromCache() async {
        await reloadEvents()
        await reloadPendingPlan() // after `events`: ChatViewModel.syncPendingPlan looks for the plan's events
        await reloadPendingEvents()
        // A rolling refresh (here, in the background or in another process) forgets the on-demand ranges, so
        // the one on screen is listed again. A no-op when it is still loaded.
        if let lastRequestedRange { ensureEvents(covering: lastRequestedRange) }
    }

    private func reloadEvents() async {
        // Previews keep their in-memory sample events: the preview sandbox is not in demo mode, so its cached
        // demo events would not be visible.
        guard !Self.isPreview else { return }
        events = await SharedStore.shared.visibleEvents()
    }

    /// The draft lives in the App Group, so Siri and the notification extension can create, add or discard it too.
    func reloadPendingPlan() async {
        let plan = await SharedStore.shared.pendingPlan()
        if plan != pendingPlan { pendingPlan = plan }
    }

    /// The "Ask me first" batch is a single App Group slot, shared with Siri and the notification extension.
    func reloadPendingEvents() async {
        let batch = await SharedStore.shared.pendingEventBatch()
        if batch != pendingEvents { pendingEvents = batch }
    }

    // MARK: Accounts

    func reloadAccounts() async {
        guard !Self.isPreview else { return }
        let store = AccountStore.shared
        let loaded = await store.accounts()
        if loaded != accounts { accounts = loaded }
        defaultWriteTarget = await store.defaultWriteTarget()?.id
        isSignedIn = await GoogleTokenProvider.shared.isSignedIn
    }

    /// The add page ("Add Google account" / "Connect Google Calendar"): signs in with `email` as Google's login
    /// hint (nil: Google's account chooser) and syncs the new account's calendars, unless Google signed in another
    /// account than typed (`.mismatch`: nothing stored yet). Errors are for the page to show.
    func addAccount(email: String?) async throws -> AccountManager.AddOutcome {
        let wasSignedIn = isSignedIn
        let outcome = try await AccountManager.shared.addAccount(email: email)
        await finishAdding(outcome, wasSignedIn: wasSignedIn)
        return outcome
    }

    /// "Add <signed-in email>" after a mismatch.
    func addPendingAccount(_ pending: GoogleSignInResult) async -> AccountManager.AddOutcome {
        let wasSignedIn = isSignedIn
        let outcome = await AccountManager.shared.addPending(pending)
        await finishAdding(outcome, wasSignedIn: wasSignedIn)
        return outcome
    }

    /// "Cancel" after a mismatch: the sign-in Google returned is revoked, not kept.
    func discardPendingAccount(_ pending: GoogleSignInResult) async {
        await AccountManager.shared.discardPending(pending)
    }

    private func finishAdding(_ outcome: AccountManager.AddOutcome, wasSignedIn: Bool) async {
        let notice: Notice
        switch outcome {
        case let .connected(account):
            notice = Notice(text: String(localized: "Connected \(account.email)"))
        case let .alreadyConnected(account):
            notice = Notice(text: String(localized: "\(account.email) is already connected."))
        case .mismatch, .cancelled:
            return
        }
        lastError = nil
        await reloadAccounts()
        await reloadFromCache()
        // Once its calendars are in the drawer, and before the add page closes.
        show(notice)
        // The first connection shows the island at once when an event is about to start (within the lead time).
        if !wasSignedIn && !isDemo { await LiveActivityManager.shared.summonIfDue() }
        // Not awaited: the add page closes at once, with the alert over it.
        let hasCalendar = isSignedIn
        Task { await requestNotificationPermissionIfNeeded(hasCalendar: hasCalendar) }
    }

    func reconnect(accountID: String) async {
        do {
            try await AccountManager.shared.reconnect(accountID: accountID)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await reloadAccounts()
        await reloadFromCache()
    }

    /// "Remove account": what its confirmation says, counted now (changes Google has not received are lost).
    func prepareRemoval(of account: GoogleAccount) async -> AccountRemoval {
        let unsent = await SyncOutbox.shared.unsentCount(accountID: account.id)
        return AccountRemoval(account: account, unsentChanges: unsent)
    }

    /// "Sync first": sends what the outbox holds, then counts again for the confirmation that follows. Offline,
    /// the same changes are still waiting.
    func syncBeforeRemoving(_ account: GoogleAccount) async -> AccountRemoval {
        syncingBeforeRemoval = account.id
        await SyncEngine.shared.flushOutbox()
        syncStatus = SyncStatusStore.current
        await reloadFromCache()
        syncingBeforeRemoval = nil
        return await prepareRemoval(of: account)
    }

    /// Revokes the grant and removes the account, its calendars, cached events and queued changes from this iPhone
    /// (Google keeps everything), then says so, and where new events go now if that changed. Without accounts left,
    /// the app is back at its welcome state.
    func removeAccount(_ account: GoogleAccount) async {
        let store = AccountStore.shared
        let targetBefore = await store.defaultWriteTarget()
        await AccountManager.shared.disconnect(accountID: account.id)
        await reloadAccounts()
        await reloadFromCache()
        syncStatus = SyncStatusStore.current
        lastError = nil
        let targetAfter = await store.defaultWriteTarget()
        let moved = AccountRemovalEffects.newEventsTarget(before: targetBefore, after: targetAfter,
                                                          removedAccountID: account.id)
        let detail = moved.map { String(localized: "New events now go to “\(AccountRemovalEffects.label($0))”.") }
        show(Notice(text: String(localized: "Removed \(account.email)"), detail: detail))
    }

    /// Shows `notice` for a few seconds (a newer one replaces it).
    func show(_ notice: Notice) {
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
    }

    /// The drawer's colour square: shows or hides a calendar at once; the store's `.accounts` change then reloads
    /// events and reminders.
    func setVisible(_ visible: Bool, calendar ref: CalendarRef) {
        updateCalendar(ref) { $0.isVisible = visible }
        Task { await AccountStore.shared.setVisible(visible, calendar: ref) }
    }

    func setColorOverride(_ hex: String?, calendar ref: CalendarRef) {
        updateCalendar(ref) { $0.colorOverrideHex = hex }
        Task { await AccountStore.shared.setColorOverride(hex, calendar: ref) }
    }

    func setNotificationsEnabled(_ enabled: Bool, calendar ref: CalendarRef) {
        updateCalendar(ref) { $0.notificationsEnabled = enabled }
        Task { await AccountStore.shared.setNotificationsEnabled(enabled, calendar: ref) }
    }

    /// Calendar details › "Use for new events".
    func setDefaultCalendar(_ calendar: CalendarInfo?) {
        defaultWriteTarget = calendar?.id ?? accounts.first?.primaryCalendar?.id
        let ref = calendar?.id
        let label = calendar?.promptLabel
        Task {
            await PreferencesStore.shared.update(source: .settings) { preferences in
                if let ref {
                    preferences.defaultCalendar = ref
                    preferences.defaultCalendarLabel = label
                } else {
                    preferences.reset(.defaultCalendar)
                }
            }
            await reloadAccounts()
        }
    }

    func calendar(_ ref: CalendarRef) -> CalendarInfo? {
        accounts.lazy.flatMap(\.calendars).first { $0.id == ref }
    }

    /// Answers the toggle before the store has written it.
    private func updateCalendar(_ ref: CalendarRef, _ change: (inout CalendarInfo) -> Void) {
        for accountIndex in accounts.indices {
            guard let index = accounts[accountIndex].calendars.firstIndex(where: { $0.id == ref }) else { continue }
            change(&accounts[accountIndex].calendars[index])
            return
        }
    }

    // MARK: Changes from other processes and from Settings

    /// Preferences change the clock (time zone, first weekday) and every reminder; accounts change what is visible
    /// and reminded. Each process posts its writes, this one included.
    private func startObserving() {
        guard observations.isEmpty, !Self.isPreview else { return }
        observations = [
            SharedChangeNotifier.observe(.preferences) { [weak self] in
                Task { @MainActor [weak self] in self?.preferencesChanged() }
            },
            SharedChangeNotifier.observe(.accounts) { [weak self] in
                Task { @MainActor [weak self] in self?.accountsChanged() }
            },
            // The outbox drained or filled (here, in Siri or in the notification extension).
            SharedChangeNotifier.observe(.syncStatus) { [weak self] in
                Task { @MainActor [weak self] in self?.syncStatusChanged() }
            }
        ]
        connectivity.start { [weak self] isOnline, cameBack in
            guard let self else { return }
            self.isNetworkOffline = !isOnline
            if cameBack { Task { await self.refresh(.network) } }
        }
    }

    private func preferencesChanged() {
        preferencesTask?.cancel()
        preferencesTask = Task { [weak self] in
            try? await Task.sleep(for: Self.changeDebounce)
            guard !Task.isCancelled, let self else { return }
            let latest = WallClock()
            if latest.timeZone != self.clock.timeZone || latest.firstWeekday != self.clock.firstWeekday {
                self.clock = latest
                self.displayedMonth = CalendarPaging.monthStart(containing: self.displayedMonth,
                                                                calendar: latest.calendar)
            }
            self.defaultWriteTarget = await AccountStore.shared.defaultWriteTarget()?.id
            await ReminderScheduler.shared.reschedule()
            await LiveActivityManager.shared.refreshIfRunning()
        }
    }

    /// Pending glyphs come and go with the outbox, so the events are read again too. A change written by the
    /// notification extension (which cannot reach the Live Activities) also reaches them here.
    private func syncStatusChanged() {
        syncStatusTask?.cancel()
        syncStatusTask = Task { [weak self] in
            try? await Task.sleep(for: Self.changeDebounce)
            guard !Task.isCancelled, let self else { return }
            self.syncStatus = SyncStatusStore.current
            await self.reloadEvents()
            await LiveActivityManager.shared.refreshIfRunning()
        }
    }

    private func accountsChanged() {
        accountsTask?.cancel()
        accountsTask = Task { [weak self] in
            try? await Task.sleep(for: Self.changeDebounce)
            guard !Task.isCancelled, let self else { return }
            await self.reloadAccounts()
            await self.reloadEvents()
            await ReminderScheduler.shared.reschedule()
            await LiveActivityManager.shared.refreshIfRunning()
        }
    }

    // MARK: Sync with Google

    /// Sends what the outbox holds and brings in what changed in Google (`SyncEngine`), then shows the cache.
    /// When the cache changed, the engine's change handler (`AppRefresh.installSyncHooks`) has already rescheduled
    /// reminders and refreshed the Live Activity; foreground and `.pull` (a tap on the drawer's status line) do it
    /// regardless.
    /// Demo mode has no Google: the seeded data is shown again instead (timer and network ticks do nothing).
    func refresh(_ trigger: SyncTrigger = .pull) async {
        if isDemo || AppConstants.isDemoMode {
            guard trigger != .timer, trigger != .network else { return }
            await refreshDemo(reseed: false)
            return
        }
        guard isSignedIn else { return }
        guard !isRefreshing else {
            // A tick can wait for the next one; anything else (back online, pull, retry) runs right after.
            if trigger != .timer { queuedTrigger = trigger }
            return
        }
        isRefreshing = true
        let report = await SyncEngine.shared.sync(trigger, now: Date())
        syncStatus = SyncStatusStore.current
        await reloadFromCache()
        if trigger == .foreground || trigger == .pull {
            await ReminderScheduler.shared.reschedule()
            await LiveActivityManager.shared.refreshIfRunning()
        }
        // One account's expired sign-in marks only that account (the drawer offers Reconnect); the others keep
        // syncing. Reloading picks up which accounts need it, and signs out only when none is left.
        if !report.errors.isEmpty { await reloadAccounts() }
        isRefreshing = false
        if let next = queuedTrigger {
            queuedTrigger = nil
            await refresh(next)
        }
    }

    /// The scene came to the front: Google is asked again every `foregroundSyncInterval` until it leaves.
    func startForegroundSync() {
        guard foregroundSyncTask == nil, !Self.isPreview else { return }
        foregroundSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.foregroundSyncInterval)
                guard !Task.isCancelled, let self else { return }
                await self.refresh(.timer)
            }
        }
    }

    func stopForegroundSync() {
        foregroundSyncTask?.cancel()
        foregroundSyncTask = nil
    }

    /// "Retry" on a change Google refused.
    func retryFailedChange(_ id: UUID) {
        guard !retryingChangeIDs.contains(id) else { return }
        retryingChangeIDs.insert(id)
        Task {
            await SyncEngine.shared.retry(id)
            retryingChangeIDs.remove(id)
            syncStatus = SyncStatusStore.current
            await reloadFromCache()
        }
    }

    /// "Discard": the change is dropped and its calendar listed again, so Google's version replaces it here.
    func discardFailedChange(_ id: UUID) {
        discardedChangeIDs.insert(id)
        Task {
            await SyncEngine.shared.discard(id)
            syncStatus = SyncStatusStore.current
            discardedChangeIDs.remove(id)
            await reloadFromCache()
        }
    }

    /// The drawer's failed list, without rows already discarded.
    var failedChanges: [FailedChange] {
        syncStatus.failed.filter { !discardedChangeIDs.contains($0.id) }
    }

    /// "Try without signing in": sample data and accounts, Live Activity, no Google account. The chat's assistant
    /// (`DemoModeAssistant`) is Gemini on the sample calendars once AI data sharing is allowed, offline rules otherwise.
    func startDemo() async {
        // First: the sample reminders (Joe's within a minute) are scheduled after the answer, not refused before it.
        await requestNotificationPermissionIfNeeded(hasCalendar: true)
        AppConstants.setDemoMode(true)
        // A draft or batch belongs to the assistant that made it.
        await SharedStore.shared.setPendingPlan(nil)
        await SharedStore.shared.setPendingEventBatch(nil)
        await reloadAccounts() // the sample accounts
        await refreshDemo(reseed: true)
        await LiveActivityManager.shared.summonIfDue()
    }

    func stopDemo() async {
        AppConstants.setDemoMode(false)
        isDemo = false
        let store = SharedStore.shared
        let snapshot = await store.snapshot()
        await store.remove(ids: Set(snapshot.events.map(\.id).filter(DemoData.isDemoID)))
        await store.resetLoadedRanges() // they held demo events
        // The offline rules' plans have demo- ids; a plan the AI added to the sample calendars has a Google-style id,
        // so its nudges are found through its (demo-) events.
        let demoPlans = Set(snapshot.events.filter { DemoData.isDemoID($0.id) }.compactMap(\.planID))
        for planID in Set(snapshot.nudges.map(\.planID)).filter({ DemoData.isDemoID($0) || demoPlans.contains($0) }) {
            await store.removeNudges(planID: planID)
        }
        // A demo draft or batch must not reach Google through the real assistant.
        await store.setPendingPlan(nil)
        await store.setPendingEventBatch(nil)
        await reloadAccounts() // the real accounts again
        await reloadFromCache()
        await ReminderScheduler.shared.reschedule()
        await LiveActivityManager.shared.refreshIfRunning()
        // Seeding replaced the cached Google window.
        if isSignedIn { await refresh(.foreground) }
    }

    /// After Settings › Data › "Erase all data on this device": back to the signed-out welcome state.
    func resetAfterErase() async {
        isDemo = false
        isSignedIn = false
        accounts = []
        defaultWriteTarget = nil
        events = []
        pendingPlan = nil
        pendingEvents = nil
        lastError = nil
        syncStatus = SyncStatusStore.current
        retryingChangeIDs = []
        discardedChangeIDs = []
        queuedTrigger = nil
        rangesInFlight = LoadedRanges()
        lastRequestedRange = nil
        clock = WallClock()
        focusDay = Date()
        displayedMonth = CalendarPaging.monthStart(containing: Date(), calendar: clock.calendar)
        await reloadAccounts()
        await reloadFromCache()
    }

    /// Demo replacement for the Google sync: seeds `DemoData` (once, unless `reseed`), then refreshes the
    /// same local surfaces a real sync would. Other dates get the weekly series from `ensureEvents`.
    private func refreshDemo(reseed: Bool) async {
        isDemo = true
        let store = SharedStore.shared
        let hasDemoData = await store.snapshot().events.contains { DemoData.isDemoID($0.id) }
        if reseed || !hasDemoData {
            let now = Date()
            await store.replaceWindow(DemoData.seedWindow(now: now, clock: clock),
                                      with: DemoData.events(now: now, clock: clock))
        }
        await reloadFromCache()
        lastError = nil
        await ReminderScheduler.shared.reschedule()
        await LiveActivityManager.shared.refreshIfRunning()
    }

    /// Includes the ghost occurrences of the pending plan and of "Ask me first" events.
    func events(on day: Date) -> [ScheduleEvent] {
        let interval = CalendarPaging.dayInterval(containing: day, calendar: clock.calendar) // 23/25 h on DST days
        let preview = previewEvents.filter { $0.intersects(interval) }
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
        ensureEvents(covering: interval) // starts before the calendars finish scrolling there, however far
    }

    // MARK: Ranges on demand

    /// Makes sure the cache holds events for `range` plus a month either side (whole months), so the calendars
    /// can scroll to any date. Google: `events.list` per missing range; demo: the weekly demo series.
    ///
    /// Cheap enough to call whenever scrolling settles: calls are debounced (`rangeDebounce` after the last one),
    /// ranges already loaded or in flight are skipped, and loading runs in its own task, so scrolling never
    /// waits. A failure keeps what is cached; the range is tried again the next time it is asked for.
    func ensureEvents(covering range: DateInterval) {
        lastRequestedRange = range
        // Two calendars can ask within one debounce (the main grid and Quick Capture): keep the latest few.
        pendingRanges.removeAll { $0 == range }
        pendingRanges.append(range)
        if pendingRanges.count > 3 { pendingRanges.removeFirst(pendingRanges.count - 3) }
        rangeDebounceTask?.cancel()
        rangeDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.rangeDebounce)
            guard !Task.isCancelled, let self else { return }
            let ranges = self.pendingRanges
            self.pendingRanges = []
            // A task of its own: the next call cancels the debounce, never a fetch already under way.
            Task {
                for range in ranges.reversed() { await self.loadMissing(around: range) }
            }
        }
    }

    private func loadMissing(around range: DateInterval) async {
        let demo = isDemo || AppConstants.isDemoMode
        guard Self.loadsRangesOnDemand, demo || isSignedIn else { return }
        let store = SharedStore.shared
        let request = LoadedRanges.request(around: range, padMonths: 1, calendar: clock.calendar)
        let cached = await store.coverage()
        // Read after the await, so two loads that start together cannot both claim the same months.
        let missing = cached.union(rangesInFlight).missing(in: request)
        guard !missing.isEmpty else { return }
        for piece in missing { rangesInFlight.insert(piece) }
        isLoadingRange = true

        var loadedAny = false
        var authFailed = false
        for piece in missing {
            do {
                if demo {
                    // Skipped if the demo ended meanwhile: stopDemo has already cleared demo events.
                    guard isDemo || AppConstants.isDemoMode else { break }
                    await store.mergeRange(piece, with: DemoData.recurringEvents(in: piece, clock: clock),
                                           replacingCached: false)
                } else {
                    try await CalendarSync(clock: clock).load(piece)
                }
                loadedAny = true
            } catch {
                if error is AuthError { authFailed = true }
                // Anything else is left for the next request of this range; the cache keeps what it had.
            }
        }
        for piece in missing { rangesInFlight.remove(piece) }
        isLoadingRange = !rangesInFlight.isEmpty
        if authFailed { await reloadAccounts() } // which accounts need Reconnect

        guard loadedAny else { return }
        await capCache()
        await reloadEvents()
    }

    /// Drops on-demand ranges far from today, from the range on screen and from the plan under review once the
    /// cache is over `maxCachedEvents`. The store never drops the rolling window, drafts or the pending plan.
    private func capCache() async {
        let calendar = clock.calendar
        var anchors = [CalendarPaging.dayInterval(containing: Date(), calendar: calendar)]
        if let lastRequestedRange { anchors.append(lastRequestedRange) }
        if let pendingPlan {
            anchors.append(DateInterval(start: pendingPlan.startDate, end: max(pendingPlan.startDate, pendingPlan.endDate)))
        }
        let keep = LoadedRanges.keepZones(around: anchors, months: Self.keepMonths, calendar: calendar)
        // Demo events other than the weekly series exist only in the cache, so they are never dropped.
        let isEvictable: @Sendable (ScheduleEvent) -> Bool
        if isDemo || AppConstants.isDemoMode {
            isEvictable = { DemoData.isRecurringOccurrence($0) }
        } else {
            isEvictable = { _ in true }
        }
        await SharedStore.shared.evictEvents(outside: keep, whenCountExceeds: Self.maxCachedEvents,
                                             isEvictable: isEvictable)
    }

    func event(id: String) -> ScheduleEvent? {
        events.first { $0.id == id }
    }
}
