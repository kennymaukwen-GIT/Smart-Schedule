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

    // MARK: From preferences

    func testDefaultPreferencesGiveTheBuiltInPolicy() {
        let fromPreferences = ReminderPolicy(preferences: AppPreferences())
        for kind in ScheduleEvent.Kind.allCases {
            XCTAssertEqual(fromPreferences.defaults(for: kind), policy.defaults(for: kind), kind.rawValue)
            XCTAssertEqual(fromPreferences.minutes(for: kind, requested: nil), policy.minutes(for: kind, requested: nil))
        }
        XCTAssertEqual(fromPreferences.allDayDefaults, [900])
        XCTAssertEqual(policy.allDayDefaults, [900])
        XCTAssertTrue(fromPreferences.writesGooglePopups)
        XCTAssertTrue(policy.writesGooglePopups)
    }

    func testPreferenceListsReplaceTheDefaultsWithoutAnExtraStartPing() {
        var preferences = AppPreferences()
        preferences.eventReminders = [60]
        preferences.routineReminders = [120, 15]
        preferences.taskReminders = []
        let custom = ReminderPolicy(preferences: preferences)
        XCTAssertEqual(custom.defaults(for: .event), [60])
        XCTAssertEqual(custom.minutes(for: .routine, requested: nil), [120, 15])
        XCTAssertEqual(custom.minutes(for: .task, requested: nil), [])
        XCTAssertEqual(custom.minutes(for: .task, requested: [5]), [5])
        XCTAssertEqual(custom.googleReminders(for: .task, requested: nil).overrides?.count, 0)
    }

    func testAllDayMinutes() {
        XCTAssertEqual(policy.allDayMinutes(requested: nil), [900])
        XCTAssertEqual(policy.allDayMinutes(requested: []), [900])
        XCTAssertEqual(policy.allDayMinutes(requested: [600, 600, -1, 50_000]), [40_320, 600, 0])
        XCTAssertEqual(policy.googleAllDayReminders(requested: [1440]).overrides?.map(\.minutes), [1440])
        XCTAssertEqual(policy.googleAllDayReminders(requested: nil).overrides?.map(\.method), ["popup"])

        var preferences = AppPreferences()
        preferences.allDayReminderMinutes = nil
        let none = ReminderPolicy(preferences: preferences)
        XCTAssertEqual(none.allDayDefaults, [])
        XCTAssertEqual(none.allDayMinutes(requested: nil), [])
        XCTAssertEqual(none.googleAllDayReminders(requested: nil).overrides?.count, 0)
        preferences.allDayReminderMinutes = 1080
        XCTAssertEqual(ReminderPolicy(preferences: preferences).allDayMinutes(requested: nil), [1080])
    }

    /// "Smart Schedules only": Google gets `useDefault: false` with no overrides, so other devices stay quiet, while
    /// the intended list is still computed for Smart Schedule's own reminders.
    func testSmartScheduleOnlyWritesNoGooglePopups() {
        var preferences = AppPreferences()
        preferences.reminderSource = .smartSchedule
        let local = ReminderPolicy(preferences: preferences)
        XCTAssertFalse(local.writesGooglePopups)
        for reminders in [local.googleReminders(for: .event, requested: nil),
                          local.googleReminders(for: .task, requested: [10]),
                          local.googleAllDayReminders(requested: nil)] {
            XCTAssertFalse(reminders.useDefault)
            XCTAssertEqual(reminders.overrides?.count, 0)
        }
        XCTAssertEqual(local.minutes(for: .event, requested: nil), [1440, 60, 30, 0])
        XCTAssertEqual(local.allDayMinutes(requested: nil), [900])
    }

    // MARK: Same-day reminders

    /// The app's calendar (Europe/London), and Tuesday 2026-10-13 10:15 BST as the moment of creation.
    private var london: Calendar { TestClock.clock.calendar }
    private var morning: Date { TestClock.local(2026, 10, 13, 10, 15) }

    func testSameDayDefaultsAreTenMinutesBeforeAndTheStart() {
        XCTAssertEqual(policy.sameDayDefaults, [10, 0])
        var preferences = AppPreferences()
        preferences.eventReminders = [60]
        XCTAssertEqual(ReminderPolicy(preferences: preferences).sameDayDefaults, [10, 0], "not a setting")
        XCTAssertEqual(ReminderPolicy(preferences: AppPreferences()).sameDayDefaults, [10, 0])
    }

    func testLaterTodayGetsTenMinutesBeforeAndTheStart() {
        let later = TestClock.local(2026, 10, 13, 15, 0)
        for kind in [ScheduleEvent.Kind.event, .deadline, .task] {
            XCTAssertEqual(policy.sameDayMinutes(for: kind, start: later, createdAt: morning, calendar: london), [10, 0],
                           kind.rawValue)
        }
        // In 5 minutes: both; the one already past is never scheduled (ReminderPlanner skips fire times <= now).
        XCTAssertEqual(policy.sameDayMinutes(for: .event, start: morning.addingTimeInterval(300), createdAt: morning,
                                             calendar: london), [10, 0])
        let fromPreferences = ReminderPolicy(preferences: AppPreferences())
        XCTAssertEqual(fromPreferences.sameDayMinutes(for: .task, start: later, createdAt: morning, calendar: london), [10, 0])
    }

    func testTomorrowAndLaterKeepTheKindsDefaults() {
        XCTAssertNil(policy.sameDayMinutes(for: .event, start: TestClock.local(2026, 10, 14, 9, 0), createdAt: morning,
                                           calendar: london))
        XCTAssertNil(policy.sameDayMinutes(for: .task, start: TestClock.local(2026, 10, 20, 15, 0), createdAt: morning,
                                           calendar: london))
    }

    func testAnItemThatHasStartedKeepsTheKindsDefaults() {
        XCTAssertNil(policy.sameDayMinutes(for: .event, start: TestClock.local(2026, 10, 13, 9, 0), createdAt: morning,
                                           calendar: london))
        XCTAssertNil(policy.sameDayMinutes(for: .event, start: morning, createdAt: morning, calendar: london), "starts now")
    }

    func testRoutinesKeepTheirDefaults() {
        XCTAssertNil(policy.sameDayMinutes(for: .routine, start: TestClock.local(2026, 10, 13, 18, 0), createdAt: morning,
                                           calendar: london))
    }

    /// "None" in Settings stays none: no reminders are added for that kind.
    func testAKindWithoutDefaultsGetsNone() {
        var preferences = AppPreferences()
        preferences.taskReminders = []
        preferences.eventReminders = []
        let quiet = ReminderPolicy(preferences: preferences)
        let later = TestClock.local(2026, 10, 13, 15, 0)
        XCTAssertNil(quiet.sameDayMinutes(for: .task, start: later, createdAt: morning, calendar: london))
        XCTAssertNil(quiet.sameDayMinutes(for: .event, start: later, createdAt: morning, calendar: london))
        XCTAssertEqual(quiet.sameDayMinutes(for: .deadline, start: later, createdAt: morning, calendar: london), [10, 0])
    }

    /// The day is the one of the calendar passed in (the app's time zone), not UTC's or the iPhone's.
    func testTheDayEndsAtMidnightInTheAppsTimeZone() {
        let late = TestClock.local(2026, 10, 13, 23, 30)
        XCTAssertEqual(policy.sameDayMinutes(for: .event, start: TestClock.local(2026, 10, 13, 23, 50), createdAt: late,
                                             calendar: london), [10, 0])
        XCTAssertNil(policy.sameDayMinutes(for: .event, start: TestClock.local(2026, 10, 14, 0, 10), createdAt: late,
                                           calendar: london))
        // The same instants are 07:30 and 08:10 on 14 October in Tokyo: one day there.
        let tokyo = WallClock(timeZone: TimeZone(identifier: "Asia/Tokyo")!).calendar
        XCTAssertEqual(policy.sameDayMinutes(for: .event, start: TestClock.local(2026, 10, 14, 0, 10), createdAt: late,
                                             calendar: tokyo), [10, 0])
    }

    func testSameDayDefaultsAreCleanedLikeEveryList() {
        var custom = ReminderPolicy()
        custom.sameDayDefaults = [0, 15, 15, -5]
        let later = TestClock.local(2026, 10, 13, 15, 0)
        XCTAssertEqual(custom.sameDayMinutes(for: .event, start: later, createdAt: morning, calendar: london), [15, 0])
        custom.sameDayDefaults = []
        XCTAssertNil(custom.sameDayMinutes(for: .event, start: later, createdAt: morning, calendar: london))
    }

    func testBothAndGoogleOnlyKeepWritingPopups() {
        for source in [ReminderSource.both, .google] {
            var preferences = AppPreferences()
            preferences.reminderSource = source
            let reminders = ReminderPolicy(preferences: preferences).googleReminders(for: .event, requested: nil)
            XCTAssertEqual(reminders.overrides?.map(\.minutes), [1440, 60, 30, 0], source.rawValue)
        }
    }
}
