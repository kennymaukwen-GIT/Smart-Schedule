import ActivityKit
import Foundation
import os

/// Which events get a Live Activity and when (pure; unit-tested). A Live Activity stands for one event about to
/// start or under way: it appears `leadMinutes` (Settings › Dynamic Island, 30 / 15 / 10 / 5) before the start and
/// leaves the Lock Screen 10 minutes after the end.
enum ActivityPlanner {
    /// Rolling window: activities are planned for events starting within the next 48 hours.
    static let horizon: TimeInterval = 48 * 3_600
    /// ActivityKit ends an activity 8 hours after it starts.
    static let maxDuration: TimeInterval = 8 * 3_600
    /// How long the ended activity stays on the Lock Screen.
    static let lingerAfterEnd: TimeInterval = 10 * 60
    /// Scheduled plus running activities at most: scheduled ones count toward the system's limit on simultaneous
    /// activities. Fill in from device testing: the count at which `ActivityAuthorizationError` is thrown, minus 2.
    static let maxPending = 8
    /// The server sends a push-to-start at or after the trigger, but its clock and the iPhone's differ: an activity
    /// that starts up to this much before the trigger by the iPhone's clock is not "moved later".
    static let earlyStartTolerance: TimeInterval = 180

    /// iOS 26 and later schedule an activity to start at its trigger time (`Activity.request(…, start:)`), which iOS
    /// starts even with the app closed. iOS 18 cannot: an app starts one only while it is in front (or a server does,
    /// with push-to-start).
    static var schedulesOnDevice: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// What a pass does about push-to-start.
    enum PushToStartStep: Equatable {
        /// Nothing: no push-to-start token is asked for or observed, nothing is registered, uploaded or cleared, so
        /// nothing about events or tokens leaves the iPhone (version 1.0, `AppConstants.pushToStartEnabled` false).
        case off
        /// iOS 26 schedules the activities on the iPhone: titles the server kept while this iPhone ran iOS 18 are
        /// cleared (a request only when an earlier upload left some there).
        case clearServer
        /// iOS 18: observe the push-to-start token, register the planned events and upload them with AI consent.
        case register
    }

    static func pushToStartStep(enabled: Bool, schedulesOnDevice: Bool) -> PushToStartStep {
        guard enabled else { return .off }
        return schedulesOnDevice ? .clearServer : .register
    }

    /// iOS 18: what to register for push-to-start. Events still to come, and events due within the server's retry
    /// window that are not showing and were not shown for this trigger: a push that failed is tried again for two
    /// minutes, and the server's record of what it sent keeps one it delivered from starting twice.
    static func pushToStartItems(_ items: [Item], now: Date, showing: Set<String>, shownTriggers: [String: Double]) -> [Item] {
        items.filter { item in
            item.triggerAt > now
                || (item.triggerAt > now.addingTimeInterval(-PushToStartRegistrar.retryWindow)
                    && !showing.contains(item.eventID)
                    && shownTriggers[item.eventID] != item.triggerAt.timeIntervalSince1970)
        }
    }

    struct Item: Equatable {
        let event: ScheduleEvent
        let leadMinutes: Int

        var eventID: String { event.id }
        /// When the activity appears.
        var triggerAt: Date { event.start.addingTimeInterval(-TimeInterval(leadMinutes) * 60) }
        /// When it stops counting: the event's end, cut at 8 hours after it appears (an activity cannot run longer).
        var end: Date { min(event.end, triggerAt.addingTimeInterval(ActivityPlanner.maxDuration)) }
        /// When the ended activity leaves the Lock Screen.
        var dismissal: Date { end.addingTimeInterval(ActivityPlanner.lingerAfterEnd) }
    }

    /// Timed, booked, unfinished events whose activity has not run its course and that start within `horizon`,
    /// soonest first, at most `limit`. nil lead (Off) = none.
    static func items(events: [ScheduleEvent],
                      leadMinutes: Int?,
                      now: Date,
                      horizon: TimeInterval = ActivityPlanner.horizon,
                      limit: Int = .max) -> [Item] {
        guard let leadMinutes, limit > 0 else { return [] }
        var seen = Set<String>()
        return events
            .filter { !$0.isAllDay && !$0.isCompleted && !$0.isDraft && $0.end > $0.start }
            .filter { $0.start <= now.addingTimeInterval(horizon) }
            .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
            .filter { seen.insert($0.id).inserted }
            .map { Item(event: $0, leadMinutes: leadMinutes) }
            .filter { $0.end > now }
            .prefix(limit)
            .map { $0 }
    }

    /// Whether to request an activity for `item`, which has none taking a place. `shownTrigger` is the trigger time
    /// of the activity already started for this event (`ActivityScheduler` records it), if any. One that was shown
    /// and is gone (swiped away, or ended by iOS after 8 hours) is not started again for the same time; one gone
    /// before it could show (a scheduled activity lost in a restart) is.
    static func shouldStart(_ item: Item, shownTrigger: Date?, now: Date) -> Bool {
        guard let shownTrigger, shownTrigger == item.triggerAt else { return true }
        return now < item.triggerAt
    }

    /// Whether a running activity showing `shown` (stale at `shownStaleDate`) needs `fresh`: only when something on
    /// screen changes (`ContentState.looksTheSame`: the headline, its time and place, the countdown and where its
    /// bar starts) or the stale date moves (the start or end changed, or the event got under way). A pass that
    /// changes nothing visible sends no update; neither does a change to what comes after the event, which no view
    /// shows since the countdown bar replaced "Up next".
    static func needsUpdate(shown: ScheduleActivityAttributes.ContentState, shownStaleDate: Date?,
                            fresh: ScheduleActivityAttributes.ContentState, freshStaleDate: Date?) -> Bool {
        !shown.looksTheSame(as: fresh) || shownStaleDate != freshStaleDate
    }

    /// Whether a scheduled (iOS 26 pending) activity, which cannot be updated, still shows what `planned` (its
    /// content rebuilt as of its trigger) would; otherwise it is replaced. Compares what is on screen: the headline
    /// as the builder makes it (a very long title is cut, so comparing the event's own title would replace it on
    /// every pass), the line under it (`hasSameDetailLine`: start, end, place, time zone) and the trigger it was
    /// scheduled with (`countdownFrom`; a new lead time needs a new one). The countdown bar starts at that trigger
    /// too: from `progressStart`, or, in one scheduled by an earlier build without it, from `countdownFrom`, the same
    /// time, so that one is kept. What comes after the event is not shown, so a change there replaces nothing.
    static func scheduledActivityMatches(_ scheduled: ScheduleActivityAttributes.ContentState,
                                         planned: ScheduleActivityAttributes.ContentState) -> Bool {
        scheduled.headline == planned.headline && scheduled.countdownFrom == planned.countdownFrom
            && scheduled.hasSameDetailLine(as: planned)
    }

    /// When a scheduled (iOS 26 pending) activity starts: its content is built as of its trigger, so the bar's start
    /// (`progressStart`) is the trigger, and so is the build time (`countdownFrom`) in one scheduled by an earlier
    /// build without it. Recorded for the reminders (`ScheduledActivityStarts`).
    static func scheduledStart(of state: ScheduleActivityAttributes.ContentState) -> Date {
        state.progressStart ?? state.countdownFrom
    }

    /// The content of `item`'s activity as of `asOf` (`LiveActivityStateBuilder.build(for:…)`), with the start of
    /// its countdown bar (`ContentState.progressStart`): `progressStart` when given (a running activity's own,
    /// `keptProgressStart(for:shown:now:)`), otherwise the trigger, when the activity appears.
    static func state(for item: Item, events: [ScheduleEvent], lastLine: String?, asOf: Date,
                      clock: WallClock = WallClock(),
                      progressStart: Date? = nil) -> ScheduleActivityAttributes.ContentState {
        var state = LiveActivityStateBuilder.build(for: item.event, events: events, lastLine: lastLine, asOf: asOf,
                                                   clock: clock)
        state.progressStart = progressStart ?? item.triggerAt
        return state
    }

    /// Where a running activity's countdown bar starts after a pass. The bar's full width is the lead time from the
    /// trigger (also for an activity that appeared late, on iOS 18 when the app was opened inside the lead time: its
    /// bar is already partly filled, beside the time left). Once shown, the start stays (`shown`) while it is before
    /// the event's start, so a new lead time or a move within the 3-minute tolerance neither moves the bar back
    /// (towards empty) nor holds it empty while the capsule counts; otherwise (an activity from an earlier build
    /// without one, or an event moved earlier than it) the trigger. Never after `now`: a bar starting later stands
    /// empty and still.
    static func keptProgressStart(for item: Item, shown: Date?, now: Date) -> Date {
        let kept = shown.flatMap { $0 < item.event.start ? $0 : nil } ?? item.triggerAt
        return min(kept, now)
    }
}

/// Keeps the Live Activities in step with the calendar. Called when the app becomes active
/// (`LiveActivityManager.summonIfDue`) and after every change and background refresh (`refreshIfRunning`).
///
/// • iOS 26 and later: each planned event gets an activity scheduled to start at its trigger time
///   (`Activity.request(…, start:)`, state `.pending`), which iOS starts even with the app closed. Its start alert
///   stands in for the reminder due then: every pass records the scheduled starts (`ScheduledActivityStarts`) and,
///   when they changed, the app reschedules the reminders (`scheduledStartsChanged`).
/// • iOS 18: only APNs push-to-start can start an activity in the background. With `AppConstants.pushToStartEnabled`
///   the planned events, with their attributes and content already encoded, go to `PushToStartRegistrar` for a server
///   to send. Version 1.0 has it off (`ActivityPlanner.pushToStartStep`): no token is asked for and nothing leaves the
///   iPhone, so an activity appears only once the app runs within the lead time (it then starts at once). While the
///   app keeps running, a pass at the next trigger time (`dueWake`) starts that one on time.
/// • Both: an event already due when the app is in front starts at once; a changed scheduled activity is replaced
///   (the old one ends only once the new one is requested); a running one is updated when what it shows changed
///   (its title, time or place, or its countdown; not what comes after it, which no view shows); a deleted event's
///   activity ends; an ended event's activity ends and leaves the Lock Screen 10 minutes after the end.
///
/// Starting an activity (scheduled or not) only works while the app is in front; from the background the request
/// fails and the next foreground pass makes it. Updating and ending work from the background too. Nothing can end an
/// activity on time while the app does not run (ActivityKit has no end date, and update pushes are not used): then
/// iOS ends it at its 8-hour limit.
@MainActor
final class ActivityScheduler {
    static let shared = ActivityScheduler()

    private typealias ScheduleActivity = Activity<ScheduleActivityAttributes>

    /// eventID → trigger time (seconds since 1970) of the activity started for it, in the App Group.
    private static let startedKey = "liveActivity.startedTriggers"

    private var isReconciling = false
    private var needsAnotherPass = false
    private var isObservingPushToStart = false
    private var isObservingActivities = false
    private var pushToStartToken: Data?
    /// iOS 18 without push-to-start: a pass at the next trigger time while the app keeps running, so the activity
    /// appears then instead of at the next change or return to the front. Only while the process runs; from the
    /// background the request fails harmlessly and the pass when the app becomes active starts it.
    private var dueWake: Task<Void, Never>?
    /// "Erase all data" is under way: passes plan nothing, whatever started them (a consent change, a sync, the
    /// app returning to the front), so nothing is scheduled again from the cache that is about to go.
    private var isSuspended = false
    /// Set by the app (AppDelegate): reschedules the reminders when the scheduled starts change
    /// (`ScheduledActivityStarts`). The pass waits for it, so a background caller (a refresh, Siri, a notification
    /// reply) never returns with the reminders half rescheduled. Nil in the widget extension.
    var scheduledStartsChanged: (() async -> Void)?

    /// Called by "Erase all data" before it ends the activities; `resume()` once the data is gone.
    func suspend() { isSuspended = true }

    func resume() { isSuspended = false }

    private enum Decision {
        /// Still right: brought up to date.
        case keep
        /// A scheduled activity for an older version of the event: request the new one, then end this one.
        case replace
        /// No longer about to start (moved later): ended, planned again.
        case ended
    }

    func reconcile(now: Date? = nil) async {
        if isReconciling {
            needsAnotherPass = true
            return
        }
        isReconciling = true
        defer { isReconciling = false }
        var passNow = now ?? Date()
        repeat {
            needsAnotherPass = false
            await pass(now: passNow)
            passNow = Date()
        } while needsAnotherPass
    }

    private func pass(now: Date) async {
        let lead = PreferencesStore.shared.current().liveActivityLeadMinutes
        let store = SharedStore.shared
        // Hidden and Focus-filtered calendars stay out of the island, like everywhere else on screen.
        let events = await store.visibleEvents(audience: .display)
        let lastLine = await store.snapshot().lastAssistantLine
        let enabled = !isSuspended && lead != nil && ActivityAuthorizationInfo().areActivitiesEnabled
        let plan = enabled ? ActivityPlanner.items(events: events, leadMinutes: lead, now: now, limit: ActivityPlanner.maxPending) : []
        let planned = Dictionary(plan.map { ($0.eventID, $0) }, uniquingKeysWith: { first, _ in first })
        let known = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        observeActivities()
        var started = Self.startedTriggers()
        var covered = Set<String>()
        for activity in ScheduleActivity.activities where Self.isLive(activity) {
            guard let id = activity.attributes.eventID, !covered.contains(id) else {
                // An older build's always-on activity, or a second one for the same event.
                Logger.liveActivity.notice("end now: older or duplicate activity id=\(activity.attributes.eventID ?? "nil", privacy: .public)")
                await activity.end(nil, dismissalPolicy: .immediate)
                continue
            }
            if let item = planned[id] {
                switch await keep(activity, as: item, events: events, lastLine: lastLine, now: now) {
                case .keep:
                    covered.insert(id)
                    started[id] = item.triggerAt.timeIntervalSince1970
                case .replace:
                    // The old one stays unless the new one is requested (that fails from the background).
                    covered.insert(id)
                    if start(item, events: events, lastLine: lastLine, now: now, replacing: true) {
                        Logger.liveActivity.notice("replaced id=\(id, privacy: .public)")
                        await activity.end(nil, dismissalPolicy: .immediate)
                        started[id] = item.triggerAt.timeIntervalSince1970
                    }
                case .ended:
                    break
                }
            } else if let event = known[id], event.end <= now, let lead {
                // Over: the final content stays on the Lock Screen until 10 minutes after the end.
                let item = ActivityPlanner.Item(event: event, leadMinutes: lead)
                let dismissal: ActivityUIDismissalPolicy = item.dismissal > now ? .after(item.dismissal) : .immediate
                Logger.liveActivity.notice("over: final content id=\(id, privacy: .public) start=\(event.start, privacy: .public) end=\(event.end, privacy: .public) now=\(now, privacy: .public) leaves=\(item.dismissal, privacy: .public)")
                await activity.end(finalContent(item, events: events, lastLine: lastLine, now: now), dismissalPolicy: dismissal)
            } else {
                // Deleted, moved past the window, completed, or the Dynamic Island turned off.
                Logger.liveActivity.notice("end now: not planned (deleted, moved, completed, hidden or off) id=\(id, privacy: .public) cached=\(known[id] != nil, privacy: .public)")
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }

        for item in plan where !covered.contains(item.eventID) {
            let shown = started[item.eventID].map(Date.init(timeIntervalSince1970:))
            guard ActivityPlanner.shouldStart(item, shownTrigger: shown, now: now) else { continue }
            if start(item, events: events, lastLine: lastLine, now: now) {
                started[item.eventID] = item.triggerAt.timeIntervalSince1970
            }
        }
        Self.storeStartedTriggers(started.filter { planned[$0.key] != nil })
        // iOS 26: each scheduled activity alerts when it starts; the reminder due then is left out, so reminders follow
        // any change here. Not while "Erase all data" runs (it removes every reminder itself).
        if ScheduledActivityStarts.store(Self.scheduledStarts()), !isSuspended { await scheduledStartsChanged?() }

        switch ActivityPlanner.pushToStartStep(enabled: AppConstants.pushToStartEnabled,
                                               schedulesOnDevice: ActivityPlanner.schedulesOnDevice) {
        case .off:
            // Version 1.0: no push-to-start token is asked for, and nothing about events is registered or uploaded.
            // iOS 26 scheduled the activities above; on iOS 18 the ones already due were started above, and the next
            // one starts in a pass at its trigger time if the app is still running then.
            dueWake?.cancel()
            dueWake = nil
            if !ActivityPlanner.schedulesOnDevice,
               let next = plan.filter({ !covered.contains($0.eventID) && $0.triggerAt > now }).map(\.triggerAt).min() {
                dueWake = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow + 1)))
                    guard !Task.isCancelled, let self else { return }
                    // This pass sets the next wake; it must not cancel the task running it.
                    self.dueWake = nil
                    await self.reconcile()
                }
            }
        case .clearServer:
            // The iPhone schedules them itself: titles the server kept while this iPhone ran iOS 18 are cleared.
            await PushToStartRegistrar.uploadIfNeeded(changed: false, consented: false)
        case .register:
            observePushToStartTokens()
            let upcoming = enabled
                ? ActivityPlanner.pushToStartItems(
                    ActivityPlanner.items(events: events, leadMinutes: lead, now: now, limit: PushToStartRegistrar.maxEvents),
                    now: now, showing: covered, shownTriggers: started)
                : []
            // What the server stores: only the registered events (the content's "Up next", which no view shows,
            // holds just those), no assistant reply and no place. The app fills in the rest with its first update
            // once the activity is running.
            let registered = upcoming.map(\.event)
            let entries = upcoming.compactMap { item in
                try? PushToStartRegistrar.event(for: item,
                                                 attributes: ScheduleActivityAttributes(eventID: item.eventID),
                                                 state: ActivityPlanner.state(for: item, events: registered,
                                                                              lastLine: nil, asOf: item.triggerAt))
            }
            let changed = await PushToStartRegistrar.sync(token: pushToStartToken ?? ScheduleActivity.pushToStartToken,
                                                          upcomingEvents: entries)
            await PushToStartRegistrar.uploadIfNeeded(changed: changed, consented: AIConsentStore.current.isGranted)
        }
    }

    /// What to do with `activity`, which stands for `item`'s event; a running one is brought up to date here.
    ///
    /// Every pass rebuilds the content from the events (each write and sync runs one). A running activity is updated
    /// only when what it shows differs (`ContentState.looksTheSame`: the headline, its time and place, the countdown
    /// and where its bar starts, which stays as shown unless the event moved before it; not the build time, "Up
    /// next", the week digest or the assistant's line, which no view shows) or its stale date moved, so a pass that
    /// changes nothing on screen sends no update.
    private func keep(_ activity: ScheduleActivity, as item: ActivityPlanner.Item,
                      events: [ScheduleEvent], lastLine: String?, now: Date) async -> Decision {
        let shown = activity.content.state
        if #available(iOS 26.0, *), activity.activityState == .pending {
            // A scheduled activity cannot be changed: a new title, time, place or lead time needs a new one
            // (`ActivityPlanner.scheduledActivityMatches`); the content is the one it was scheduled with, as of its
            // trigger. A change after the event replaces nothing: no view shows it. Unchanged, it stays even past its
            // trigger (iOS is about to start it).
            let planned = content(item, events: events, lastLine: lastLine, asOf: item.triggerAt).state
            return ActivityPlanner.scheduledActivityMatches(shown, planned: planned) ? .keep : .replace
        }
        if item.triggerAt > now.addingTimeInterval(ActivityPlanner.earlyStartTolerance) {
            // Moved later: no longer about to start. Planned again below.
            await activity.end(nil, dismissalPolicy: .immediate)
            return .ended
        }
        // The bar keeps the start it shows (`ActivityPlanner.keptProgressStart`): a new lead time sends no update.
        let barStart = ActivityPlanner.keptProgressStart(for: item, shown: shown.progressStart, now: now)
        let fresh = content(item, events: events, lastLine: lastLine, asOf: now, progressStart: barStart)
        if ActivityPlanner.needsUpdate(shown: shown, shownStaleDate: activity.content.staleDate,
                                       fresh: fresh.state, freshStaleDate: fresh.staleDate) {
            await activity.update(fresh)
        }
        return .keep
    }

    /// Requests the activity: now when already due, otherwise scheduled (iOS 26). false when nothing was started.
    /// `replacing`: an older scheduled one for the same event still takes a place until this succeeds.
    private func start(_ item: ActivityPlanner.Item, events: [ScheduleEvent], lastLine: String?, now: Date,
                       replacing: Bool = false) -> Bool {
        let attributes = ScheduleActivityAttributes(eventID: item.eventID)
        let pushType: PushType? = AppConstants.liveActivityPushEnabled ? .token : nil
        if item.triggerAt <= now {
            // Already due: only possible while the app is in front.
            do {
                _ = try ScheduleActivity.request(attributes: attributes,
                                                 content: content(item, events: events, lastLine: lastLine, asOf: now),
                                                 pushType: pushType)
                return true
            } catch {
                // Usually the app is in the background; the next pass with the app in front starts it.
                Logger.liveActivity.error("start failed (due now) id=\(item.eventID, privacy: .public): \(String(describing: error), privacy: .public)")
                return false
            }
        }
        if #available(iOS 26.0, *) {
            let running = ScheduleActivity.activities.filter(Self.isLive).count
            guard running < ActivityPlanner.maxPending + (replacing ? 1 : 0) else { return false }
            do {
                _ = try ScheduleActivity.request(attributes: attributes,
                                                 content: content(item, events: events, lastLine: lastLine, asOf: item.triggerAt),
                                                 pushType: pushType,
                                                 style: .standard,
                                                 alertConfiguration: Self.startAlert(item),
                                                 start: item.triggerAt)
                return true
            } catch {
                Logger.liveActivity.error("schedule failed id=\(item.eventID, privacy: .public) at=\(item.triggerAt, privacy: .public): \(String(describing: error), privacy: .public)")
                return false
            }
        }
        return false
    }

    private static func startedTriggers() -> [String: Double] {
        UserDefaults(suiteName: AppConstants.appGroupID)?.dictionary(forKey: startedKey) as? [String: Double] ?? [:]
    }

    private static func storeStartedTriggers(_ started: [String: Double]) {
        UserDefaults(suiteName: AppConstants.appGroupID)?.set(started, forKey: startedKey)
    }

    /// iOS 26: event ID → when its scheduled (`.pending`) activity starts, read back from ActivityKit, so the record
    /// holds what iOS will start, not what this pass meant to (a request from the background fails). [:] on iOS 18.
    private static func scheduledStarts() -> [String: Date] {
        guard #available(iOS 26.0, *) else { return [:] }
        var starts: [String: Date] = [:]
        for activity in ScheduleActivity.activities where activity.activityState == .pending {
            guard let id = activity.attributes.eventID else { continue }
            starts[id] = ActivityPlanner.scheduledStart(of: activity.content.state)
        }
        return starts
    }

    /// iOS 26 requires an alert when a scheduled activity starts: the event and how soon it begins.
    @available(iOS 26.0, *)
    private static func startAlert(_ item: ActivityPlanner.Item) -> AlertConfiguration {
        AlertConfiguration(title: LocalizedStringResource(stringLiteral: item.event.title),
                           body: "Starts in \(item.leadMinutes) min",
                           sound: .default)
    }

    /// The content as of `asOf`, its countdown bar starting at `progressStart`, else the trigger
    /// (`ActivityPlanner.state`). Stale at the start, so the island switches to the time left without an update from
    /// the app; once under way, stale a minute after the end.
    private func content(_ item: ActivityPlanner.Item, events: [ScheduleEvent], lastLine: String?,
                         asOf: Date, progressStart: Date? = nil) -> ActivityContent<ScheduleActivityAttributes.ContentState> {
        let state = ActivityPlanner.state(for: item, events: events, lastLine: lastLine, asOf: asOf,
                                          progressStart: progressStart)
        let staleDate = state.isInProgress ? item.end.addingTimeInterval(60) : item.event.start
        return ActivityContent(state: state, staleDate: staleDate, relevanceScore: state.isInProgress ? 100 : 50)
    }

    /// The ended activity's last look: no countdown and no bar ("Ended").
    private func finalContent(_ item: ActivityPlanner.Item, events: [ScheduleEvent], lastLine: String?,
                              now: Date) -> ActivityContent<ScheduleActivityAttributes.ContentState> {
        var state = ActivityPlanner.state(for: item, events: events, lastLine: lastLine, asOf: now)
        state.isInProgress = false
        state.countdownTarget = nil
        state.eventEnd = nil
        state.hasEnded = true
        return ActivityContent(state: state, staleDate: nil)
    }

    /// Scheduled, running or stale: still taking a place.
    private static func isLive(_ activity: ScheduleActivity) -> Bool {
        if #available(iOS 26.0, *), activity.activityState == .pending { return true }
        return activity.activityState == .active || activity.activityState == .stale
    }

    /// An activity started outside this pass (an iOS 26 scheduled one starting; with push-to-start, an iOS 18 push,
    /// which also gives the app background time) is reconciled at once, which records it as shown: swiped away later,
    /// it is not started again for the same trigger.
    private func observeActivities() {
        guard !isObservingActivities else { return }
        isObservingActivities = true
        Task { [weak self] in
            for await activity in ScheduleActivity.activityUpdates where activity.attributes.eventID != nil {
                guard let self else { return }
                await self.reconcile()
            }
        }
    }

    /// iOS 18: a new push-to-start token re-registers the planned events (observed while the app runs). Only with
    /// `AppConstants.pushToStartEnabled` (`PushToStartStep.register`): version 1.0 never asks iOS for a token.
    private func observePushToStartTokens() {
        guard AppConstants.pushToStartEnabled, !isObservingPushToStart else { return }
        isObservingPushToStart = true
        Task { [weak self] in
            for await token in ScheduleActivity.pushToStartTokenUpdates {
                guard let self else { return }
                self.pushToStartToken = token
                await self.reconcile()
            }
        }
    }
}

extension Logger {
    /// Console.app › the iPhone › search "LiveActivity": why a card ended, or why one could not start.
    static let liveActivity = Logger(subsystem: "com.smartschedules.app", category: "LiveActivity")
}
