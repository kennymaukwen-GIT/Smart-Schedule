import UserNotifications
import XCTest

final class NotificationPermissionTests: XCTestCase {
    func testAsksOnlyOnceThereIsACalendarAndIOSHasNotAsked() {
        XCTAssertTrue(NotificationPermission.shouldAsk(status: .notDetermined, hasCalendar: true))
        XCTAssertFalse(NotificationPermission.shouldAsk(status: .notDetermined, hasCalendar: false)) // first launch, signed out
        for status in [UNAuthorizationStatus.authorized, .denied, .provisional, .ephemeral] {
            XCTAssertFalse(NotificationPermission.shouldAsk(status: status, hasCalendar: true))
        }
    }

    func testOptionsLeaveOutTheDeprecatedTimeSensitiveOption() {
        XCTAssertEqual(NotificationPermission.options, [.alert, .sound, .badge])
    }
}
