import ActivityKit
import Foundation

/// Entry points for the Live Activities, one per event about to start or under way (`ActivityScheduler`).
///
/// Lifetime facts (ActivityKit): an activity runs ≤ 8 h, then lingers on the Lock Screen ≤ 4 h. An app can start
/// one only while it is in front; from the background only iOS 26's scheduled start (`Activity.request(…, start:)`)
/// or APNs push-to-start (iOS 17.2+) can. The Control Center button opens Quick Capture instead
/// (`OpenQuickCaptureIntent`): the island never stays up without an event coming.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private typealias ScheduleActivity = Activity<ScheduleActivityAttributes>

    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// After any write (chat, Siri, sync, background refresh): plans, updates and ends activities to match.
    func refreshIfRunning() async {
        await ActivityScheduler.shared.reconcile()
    }

    /// When the app becomes active: the same, and an event already within the lead time starts at once.
    func summonIfDue(now: Date = Date()) async {
        await ActivityScheduler.shared.reconcile(now: now)
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
}
