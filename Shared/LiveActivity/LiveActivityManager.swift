import ActivityKit
import Foundation

/// Starts / refreshes / ends the Live Activity that shows the next event in the Dynamic Island.
///
/// Lifetime facts (ActivityKit): an activity runs ≤ 8 h, then lingers on the Lock Screen ≤ 4 h.
/// Starting from the background is only allowed via a `LiveActivityIntent` or APNs push-to-start (iOS 17.2+).
/// It is started only for an event about to start (`summonIfDue`); the Control Center button opens Quick Capture
/// instead (`OpenQuickCaptureIntent`).
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private typealias ScheduleActivity = Activity<ScheduleActivityAttributes>

    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    private var current: ScheduleActivity? {
        ScheduleActivity.activities.first { $0.activityState == .active || $0.activityState == .stale }
    }

    /// Starts the activity, or updates the running one.
    private func start() async throws {
        let content = await makeContent()
        if let current {
            await current.update(content)
        } else {
            _ = try ScheduleActivity.request(
                attributes: ScheduleActivityAttributes(),
                content: content,
                pushType: AppConstants.liveActivityPushEnabled ? .token : nil
            )
        }
    }

    /// After any write (chat, Siri, BG refresh). No-op when no activity is running.
    func refreshIfRunning() async {
        guard let current else { return }
        await current.update(await makeContent())
    }

    /// When the app becomes active: refreshes a running activity, otherwise starts one if Settings › Dynamic Island
    /// "Show next event" is on and the next timed event is in progress or starts within that lead time (≤ 30 min).
    ///
    /// Starting it on its own before every event, with the app closed, would need APNs push-to-start from a
    /// server, which Smart Schedule does not have.
    func summonIfDue(now: Date = Date()) async {
        if current != nil {
            await refreshIfRunning()
            return
        }
        let lead = PreferencesStore.shared.current().liveActivityLeadMinutes
        guard lead != nil, isAvailable else { return }
        let events = await SharedStore.shared.visibleEvents(audience: .display)
        guard LiveActivityStateBuilder.isNextEventDue(events: events, leadMinutes: lead, now: now) else { return }
        try? await start()
    }

    func dismiss() async {
        for activity in ScheduleActivity.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Upload these to your backend to update (token) or start (push-to-start token) activities remotely.
    func observePushTokens(upload: @escaping @Sendable (_ kind: String, _ token: String) async -> Void) {
        guard AppConstants.liveActivityPushEnabled else { return }
        Task {
            for await data in ScheduleActivity.pushToStartTokenUpdates {
                await upload("push-to-start", data.map { String(format: "%02x", $0) }.joined())
            }
        }
        Task {
            for await activity in ScheduleActivity.activityUpdates {
                for await data in activity.pushTokenUpdates {
                    await upload("update", data.map { String(format: "%02x", $0) }.joined())
                }
            }
        }
    }

    private func makeContent() async -> ActivityContent<ScheduleActivityAttributes.ContentState> {
        let store = SharedStore.shared
        let lastLine = await store.snapshot().lastAssistantLine
        // Hidden and Focus-filtered calendars stay out of the island, like everywhere else on screen.
        let events = await store.visibleEvents(audience: .display)
        let state = LiveActivityStateBuilder.build(events: events, lastLine: lastLine)
        // Stale once the countdown target passes, so the system dims it instead of showing "0:00" forever.
        return ActivityContent(state: state,
                               staleDate: state.countdownTarget?.addingTimeInterval(60),
                               relevanceScore: state.isInProgress ? 100 : 50)
    }
}
