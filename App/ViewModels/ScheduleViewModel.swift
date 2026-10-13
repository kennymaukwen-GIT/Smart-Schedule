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
    /// True while `ensureEvents(covering:)` is loading a range the cache did not hold (a subtle progress hint).
    private(set) var isLoadingRange = false

    let clock = WallClock()

    /// Cache cap: past this many cached events, ranges more than `keepMonths` from both today and the range last
    /// on screen are dropped (and listed again if they come back). About 1 MB of App Group JSON.
    static let maxCachedEvents = 2_000
    private static let keepMonths = 12
    /// `ensureEvents` waits this long after the last call, so a fling loads only where it settles.
    private static let rangeDebounce: Duration = .milliseconds(300)
    /// Xcode Previews keep their in-memory sample events; a load would swap them for the preview sandbox's cache.
    private static let loadsRangesOnDemand = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1"

    @ObservationIgnored private var rangeDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRanges: [DateInterval] = []
    @ObservationIgnored private var rangesInFlight = LoadedRanges()
    /// What the calendars last asked for (or `focus` jumped to): re-listed after a rolling refresh, kept by the cap.
    @ObservationIgnored private var lastRequestedRange: DateInterval?

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
        await reloadEvents()
        await reloadPendingPlan() // after `events`: ChatViewModel.syncPendingPlan looks for the plan's events
        // A rolling refresh (here, in the background or in another process) forgets the on-demand ranges, so
        // the one on screen is listed again. A no-op when it is still loaded.
        if let lastRequestedRange { ensureEvents(covering: lastRequestedRange) }
    }

    private func reloadEvents() async {
        events = await SharedStore.shared.snapshot().events.sorted { $0.start < $1.start }
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
        await store.resetLoadedRanges() // they held demo events
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
                if let authError = error as? AuthError, case .refreshFailed = authError { isSignedIn = false }
                // Anything else is left for the next request of this range; the cache keeps what it had.
            }
        }
        for piece in missing { rangesInFlight.remove(piece) }
        isLoadingRange = !rangesInFlight.isEmpty

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
