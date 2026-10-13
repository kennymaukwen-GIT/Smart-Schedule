import UserNotifications
import XCTest

final class ReminderEngagementTests: XCTestCase {
    private func userInfo(kind: String = "event", offset: Int = 1440, allDay: Bool = false,
                          fromDefaults: Bool? = true) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            NotificationIDs.UserInfo.eventID: "m",
            NotificationIDs.UserInfo.kind: kind,
            NotificationIDs.UserInfo.offset: offset,
            NotificationIDs.UserInfo.allDay: allDay
        ]
        if let fromDefaults { info[NotificationIDs.UserInfo.fromDefaults] = fromDefaults }
        return info
    }

    private func outcome(identifier: String = "ss.reminder.m.1440",
                         category: String = NotificationIDs.Category.eventReminder,
                         userInfo: [AnyHashable: Any]? = nil,
                         action: String = UNNotificationDismissActionIdentifier) -> ReminderEngagement.Outcome? {
        ReminderEngagement.outcome(identifier: identifier, categoryIdentifier: category,
                                   userInfo: userInfo ?? self.userInfo(), actionIdentifier: action)
    }

    func testDismissalCounts() {
        XCTAssertEqual(outcome(), ReminderEngagement.Outcome(kind: .event, offsetMinutes: 1440, isAllDay: false, dismissed: true))
    }

    func testOpeningSnoozingAndReplyingAreEngagement() {
        for action in [UNNotificationDefaultActionIdentifier, NotificationIDs.Action.snooze10, NotificationIDs.Action.reply] {
            XCTAssertEqual(outcome(action: action)?.dismissed, false, action)
        }
    }

    func testAllDayAndKindsAreRead() {
        let result = outcome(identifier: "ss.reminder.h.900", userInfo: userInfo(kind: "deadline", offset: 900, allDay: true))
        XCTAssertEqual(result, ReminderEngagement.Outcome(kind: .deadline, offsetMinutes: 900, isAllDay: true, dismissed: true))
    }

    func testOnlyDefaultOffsetReminderResponsesCount() {
        XCTAssertNil(outcome(userInfo: userInfo(fromDefaults: false)), "an offset the user asked for")
        XCTAssertNil(outcome(userInfo: userInfo(fromDefaults: nil)), "reminders scheduled before this version")
        XCTAssertNil(outcome(userInfo: userInfo(kind: "meeting")))
        XCTAssertNil(outcome(identifier: "ss.reminder.snooze.ABC"), "a snoozed copy was already engaged with")
        XCTAssertNil(outcome(identifier: "ss.briefing.morning.2026-10-15", category: NotificationIDs.Category.compose))
        XCTAssertNil(outcome(identifier: "ss.nudge.plan", category: NotificationIDs.Category.compose))
        XCTAssertNil(outcome(userInfo: [NotificationIDs.UserInfo.eventID: "m"]))
    }

    /// The scheduler's userInfo is exactly what the engagement reader expects.
    func testSchedulerAndEngagementAgree() throws {
        let start = TestClock.local(2026, 10, 15, 14)
        let event = TestEvents.make(id: "m", start: start, end: start.addingTimeInterval(3600))
        let reminder = PlannedReminder(event: event, minutes: 60, isAllDay: false, fromDefaults: true,
                                       fire: start.addingTimeInterval(-3600), level: .active)
        let request = ReminderScheduler.request(for: reminder, clock: TestClock.clock)
        let result = ReminderEngagement.outcome(identifier: request.identifier,
                                                categoryIdentifier: request.content.categoryIdentifier,
                                                userInfo: request.content.userInfo,
                                                actionIdentifier: UNNotificationDismissActionIdentifier)
        XCTAssertEqual(result, ReminderEngagement.Outcome(kind: .event, offsetMinutes: 60, isAllDay: false, dismissed: true))
    }

    func testReminderCategoryReportsDismissals() {
        // Registered at launch; the option is what makes swipe-away responses reach the app.
        XCTAssertEqual(NotificationIDs.Category.eventReminder, "SS_EVENT_REMINDER")
        XCTAssertEqual(NotificationIDs.UserInfo.fromDefaults, "ssFromDefaults")
        XCTAssertEqual(NotificationIDs.briefingPrefix, "ss.briefing.")
    }
}
