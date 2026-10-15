import ActivityKit
import Foundation

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
    /// A server's push-to-start may arrive this much before the trigger (it sends up to a minute ahead, and clocks
    /// differ): such an activity is not "moved later".
    static let earlyStartTolerance: TimeInterval = 180

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
}

/// Keeps the Live Activities in step with the calendar. Called when the app becomes active
/// (`LiveActivityManager.summonIfDue`) and after every change and background refresh (`refreshIfRunning`).
///
/// • iOS 26 and later: each planned event gets an activity scheduled to start at its trigger time
///   (`Activity.request(…, start:)`, state `.pending`), which iOS starts even with the app closed.
/// • iOS 18: only APNs push-to-start can start an activity in the background; the planned events, with their
///   attributes and content already encoded, go to `PushToStartRegistrar` for a server to send.
/// • Both: an event already due when the app is in front starts at once; a changed scheduled activity is replaced
///   (the old one ends only once the new one is requested); a deleted event's activity ends; an ended event's
///   activity ends and leaves the Lock Screen 10 minutes after the end.
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
        let enabled = lead != nil && ActivityAuthorizationInfo().areActivitiesEnabled
        let plan = enabled ? ActivityPlanner.items(events: events, leadMinutes: lead, now: now, limit: ActivityPlanner.maxPending) : []
        let planned = Dictionary(plan.map { ($0.eventID, $0) }, uniquingKeysWith: { first, _ in first })
        let known = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        observeActivities()
        var started = Self.startedTriggers()
        var covered = Set<String>()
        for activity in ScheduleActivity.activities where Self.isLive(activity) {
            guard let id = activity.attributes.eventID, !covered.contains(id) else {
                // An older build's always-on activity, or a second one for the same event.
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
                await activity.end(finalContent(item, events: events, lastLine: lastLine, now: now), dismissalPolicy: dismissal)
            } else {
                // Deleted, moved past the window, completed, or the Dynamic Island turned off.
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

        if #unavailable(iOS 26.0) {
            observePushToStartTokens()
            let upcoming = enabled
                ? ActivityPlanner.items(events: events, leadMinutes: lead, now: now, limit: PushToStartRegistrar.maxEvents)
                    .filter { $0.triggerAt > now }
                : []
            // What the server stores: only the registered events (the week strip shows just those) and no assistant
            // reply. The app fills in the rest with its first update once the activity is running.
            let registered = upcoming.map(\.event)
            let entries = upcoming.compactMap { item in
                try? PushToStartRegistrar.event(for: item,
                                                 attributes: ScheduleActivityAttributes(eventID: item.eventID),
                                                 state: LiveActivityStateBuilder.build(for: item.event, events: registered,
                                                                                       lastLine: nil, asOf: item.triggerAt))
            }
            await PushToStartRegistrar.sync(token: pushToStartToken ?? ScheduleActivity.pushToStartToken, upcomingEvents: entries)
        }
    }

    /// What to do with `activity`, which stands for `item`'s event; a running one is brought up to date here.
    private func keep(_ activity: ScheduleActivity, as item: ActivityPlanner.Item,
                      events: [ScheduleEvent], lastLine: String?, now: Date) async -> Decision {
        let shown = activity.content.state
        let sameEvent = shown.headline == item.event.title && shown.eventStart == item.event.start
            && shown.eventEnd == item.event.end
        if #available(iOS 26.0, *), activity.activityState == .pending {
            // A scheduled activity cannot be changed: a new time, title or lead time needs a new one. Unchanged, it
            // stays even past its trigger (iOS is about to start it).
            return sameEvent && shown.countdownFrom == item.triggerAt ? .keep : .replace
        }
        if item.triggerAt > now.addingTimeInterval(ActivityPlanner.earlyStartTolerance) {
            // Moved later: no longer about to start. Planned again below.
            await activity.end(nil, dismissalPolicy: .immediate)
            return .ended
        }
        await activity.update(content(item, events: events, lastLine: lastLine, asOf: now))
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
            return (try? ScheduleActivity.request(attributes: attributes,
                                                  content: content(item, events: events, lastLine: lastLine, asOf: now),
                                                  pushType: pushType)) != nil
        }
        if #available(iOS 26.0, *) {
            let running = ScheduleActivity.activities.filter(Self.isLive).count
            guard running < ActivityPlanner.maxPending + (replacing ? 1 : 0) else { return false }
            return (try? ScheduleActivity.request(attributes: attributes,
                                                  content: content(item, events: events, lastLine: lastLine, asOf: item.triggerAt),
                                                  pushType: pushType,
                                                  style: .standard,
                                                  alertConfiguration: Self.startAlert(item),
                                                  start: item.triggerAt)) != nil
        }
        return false
    }

    private static func startedTriggers() -> [String: Double] {
        UserDefaults(suiteName: AppConstants.appGroupID)?.dictionary(forKey: startedKey) as? [String: Double] ?? [:]
    }

    private static func storeStartedTriggers(_ started: [String: Double]) {
        UserDefaults(suiteName: AppConstants.appGroupID)?.set(started, forKey: startedKey)
    }

    /// iOS 26 requires an alert when a scheduled activity starts: the event and how soon it begins.
    @available(iOS 26.0, *)
    private static func startAlert(_ item: ActivityPlanner.Item) -> AlertConfiguration {
        AlertConfiguration(title: LocalizedStringResource(stringLiteral: item.event.title),
                           body: "Starts in \(item.leadMinutes) min",
                           sound: .default)
    }

    /// The content as of `asOf`. Stale at the start, so the island switches to the time left without an update
    /// from the app; once under way, stale a minute after the end.
    private func content(_ item: ActivityPlanner.Item, events: [ScheduleEvent], lastLine: String?,
                         asOf: Date) -> ActivityContent<ScheduleActivityAttributes.ContentState> {
        let state = LiveActivityStateBuilder.build(for: item.event, events: events, lastLine: lastLine, asOf: asOf)
        let staleDate = state.isInProgress ? item.end.addingTimeInterval(60) : item.event.start
        return ActivityContent(state: state, staleDate: staleDate, relevanceScore: state.isInProgress ? 100 : 50)
    }

    /// The ended activity's last look: no countdown.
    private func finalContent(_ item: ActivityPlanner.Item, events: [ScheduleEvent], lastLine: String?,
                              now: Date) -> ActivityContent<ScheduleActivityAttributes.ContentState> {
        var state = LiveActivityStateBuilder.build(for: item.event, events: events, lastLine: lastLine, asOf: now)
        state.isInProgress = false
        state.countdownTarget = nil
        state.eventEnd = nil
        return ActivityContent(state: state, staleDate: nil)
    }

    /// Scheduled, running or stale: still taking a place.
    private static func isLive(_ activity: ScheduleActivity) -> Bool {
        if #available(iOS 26.0, *), activity.activityState == .pending { return true }
        return activity.activityState == .active || activity.activityState == .stale
    }

    /// An activity started outside this pass (iOS 18 push-to-start, which also gives the app background time; an
    /// iOS 26 scheduled one starting) is reconciled at once, which records it as shown: swiped away later, it is not
    /// started again for the same trigger.
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

    /// iOS 18: a new push-to-start token re-registers the planned events (observed while the app runs).
    private func observePushToStartTokens() {
        guard !isObservingPushToStart else { return }
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
