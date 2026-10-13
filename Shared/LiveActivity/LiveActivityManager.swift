import ActivityKit
import Foundation

/// Starts / refreshes / ends the "ready" Live Activity that keeps Smart Schedule in the Dynamic Island.
///
/// Lifetime facts (ActivityKit): an activity runs ≤ 8 h, then lingers on the Lock Screen ≤ 4 h.
/// Starting from the background is only allowed via a `LiveActivityIntent` (Control Center button,
/// widget/island button, Siri) or APNs push-to-start (iOS 17.2+). A truly always-on island therefore
/// needs a server that push-to-starts a fresh activity when the previous one expires.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private typealias ScheduleActivity = Activity<ScheduleActivityAttributes>

    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    private var current: ScheduleActivity? {
        ScheduleActivity.activities.first { $0.activityState == .active || $0.activityState == .stale }
    }

    /// Called by the Control Center button (via `SummonScheduleIntent`) and on app launch.
    func summon() async throws {
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
        let snapshot = await SharedStore.shared.snapshot()
        let state = LiveActivityStateBuilder.build(events: snapshot.events, lastLine: snapshot.lastAssistantLine)
        // Stale once the countdown target passes, so the system dims it instead of showing "0:00" forever.
        return ActivityContent(state: state,
                               staleDate: state.countdownTarget?.addingTimeInterval(60),
                               relevanceScore: state.isInProgress ? 100 : 50)
    }
}
