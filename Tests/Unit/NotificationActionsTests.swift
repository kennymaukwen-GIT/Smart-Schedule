import UserNotifications
import XCTest

/// A reply can add, move or delete events, so a locked iPhone asks for Face ID or the passcode before it
/// (`.authenticationRequired`); snooze only schedules a local copy and works while locked. Reads
/// `NotificationIDs.categories()`: `registerCategories()` needs `UNUserNotificationCenter.current()`, which is not
/// safe in this hostless test bundle.
final class NotificationActionsTests: XCTestCase {
    private let categories = NotificationIDs.categories()

    private func actions(_ identifier: String) -> [UNNotificationAction] {
        categories.flatMap { $0.actions }.filter { $0.identifier == identifier }
    }

    func testTheReminderAndComposeCategories() {
        XCTAssertEqual(Set(categories.map(\.identifier)),
                       [NotificationIDs.Category.eventReminder, NotificationIDs.Category.compose])
    }

    func testBothReplyActionsAskToUnlockFirst() {
        let replies = actions(NotificationIDs.Action.reply)
        XCTAssertEqual(replies.count, 2) // the reminder's and the compose notification's
        for reply in replies {
            XCTAssertTrue(reply is UNTextInputNotificationAction)
            XCTAssertTrue(reply.options.contains(.authenticationRequired))
        }
    }

    func testSnoozeWorksWhileLocked() throws {
        let snoozes = actions(NotificationIDs.Action.snooze10)
        XCTAssertEqual(snoozes.count, 1)
        let snooze = try XCTUnwrap(snoozes.first)
        XCTAssertFalse(snooze.options.contains(.authenticationRequired))
        XCTAssertFalse(snooze.options.contains(.foreground))
    }
}
