import XCTest

final class ReminderPolicyTests: XCTestCase {
    private let policy = ReminderPolicy()

    func testDefaultsPerKind() {
        XCTAssertEqual(policy.defaults(for: .event), [1440, 60, 30, 0])
        XCTAssertEqual(policy.defaults(for: .deadline), [1440, 60])
        XCTAssertEqual(policy.defaults(for: .task), [60])
        XCTAssertEqual(policy.defaults(for: .routine), [30])
    }

    func testStartPingCanBeDisabled() {
        var quiet = ReminderPolicy()
        quiet.includeStartPing = false
        XCTAssertEqual(quiet.defaults(for: .event), [1440, 60, 30])
        XCTAssertEqual(quiet.minutes(for: .event, requested: nil), [1440, 60, 30])
    }

    func testNilOrEmptyRequestFallsBackToDefaults() {
        XCTAssertEqual(policy.minutes(for: .event, requested: nil), [1440, 60, 30, 0])
        XCTAssertEqual(policy.minutes(for: .event, requested: []), [1440, 60, 30, 0])
        XCTAssertEqual(policy.minutes(for: .routine, requested: []), [30])
    }

    func testClampsToGoogleRange() {
        XCTAssertEqual(policy.minutes(for: .event, requested: [-5, 50_000, 30]), [40_320, 30, 0])
        XCTAssertEqual(policy.minutes(for: .task, requested: [40_320, 40_321]), [40_320])
    }

    func testDeduplicatesAndSortsDescending() {
        XCTAssertEqual(policy.minutes(for: .event, requested: [10, 30, 10, 0, 30]), [30, 10, 0])
        XCTAssertEqual(policy.minutes(for: .event, requested: [5, 1440, 60]), [1440, 60, 5])
    }

    func testKeepsAtMostFiveLargestOffsets() {
        XCTAssertEqual(policy.minutes(for: .event, requested: [1, 2, 3, 4, 5, 6, 7]), [7, 6, 5, 4, 3])
        XCTAssertEqual(ReminderPolicy.googleMaxOverrides, 5)
        XCTAssertEqual(ReminderPolicy.googleMaxMinutes, 40_320)
    }

    func testGoogleRemindersArePopupOverrides() {
        let reminders = policy.googleReminders(for: .deadline, requested: nil)
        XCTAssertFalse(reminders.useDefault)
        XCTAssertEqual(reminders.overrides?.map(\.minutes), [1440, 60])
        XCTAssertEqual(reminders.overrides?.map(\.method), ["popup", "popup"])
    }
}
