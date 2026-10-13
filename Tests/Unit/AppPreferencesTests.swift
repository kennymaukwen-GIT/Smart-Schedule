import XCTest

final class AppPreferencesTests: XCTestCase {
    private func decode(_ json: String) throws -> AppPreferences {
        try JSONDecoder().decode(AppPreferences.self, from: Data(json.utf8))
    }

    private func assertRejected(_ value: String, for key: PreferenceKey, in preferences: AppPreferences = AppPreferences(),
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try preferences.normalized(value, for: key), "\(key.rawValue) = \(value)", file: file, line: line) {
            guard case .invalid(let reason)? = $0 as? PreferenceValueError else {
                return XCTFail("unexpected error \($0)", file: file, line: line)
            }
            XCTAssertTrue(reason.hasPrefix(key.rawValue), reason, file: file, line: line)
        }
    }

    // MARK: Defaults

    func testDefaultsKeepTheBehaviourBeforeSettings() {
        let preferences = AppPreferences()
        XCTAssertEqual(preferences.reminderSource, .both)
        XCTAssertTrue(preferences.localRemindersEnabled)
        XCTAssertTrue(preferences.writesGooglePopups)
        XCTAssertEqual(preferences.eventReminders, [1440, 60, 30, 0])
        XCTAssertEqual(preferences.deadlineReminders, [1440, 60])
        XCTAssertEqual(preferences.taskReminders, [60])
        XCTAssertEqual(preferences.routineReminders, [30])
        XCTAssertEqual(preferences.allDayReminderMinutes, 900)
        XCTAssertEqual(ScheduleEvent.Kind.allCases.map(preferences.urgency(for:)), [.automatic, .automatic, .automatic, .automatic])
        XCTAssertFalse(preferences.quietHours.isEnabled)
        XCTAssertEqual(preferences.quietHours.startMinute, 22 * 60)
        XCTAssertEqual(preferences.quietHours.endMinute, 7 * 60)
        XCTAssertEqual(preferences.morningBriefing, DailyTime(isEnabled: true, minuteOfDay: 7 * 60 + 30))
        XCTAssertEqual(preferences.eveningPreview, DailyTime(isEnabled: false, minuteOfDay: 21 * 60))
        XCTAssertNil(preferences.dailyReminderCap)
        XCTAssertEqual(preferences.liveActivityLeadMinutes, 30)
        XCTAssertNil(preferences.defaultCalendar)
        XCTAssertEqual(preferences.defaultEventMinutes, 60)
        XCTAssertEqual(preferences.weekStart, .sunday)
        XCTAssertEqual(preferences.firstWeekday, 1)
        XCTAssertEqual(preferences.timeZone, TimeZone.current)
        XCTAssertEqual(preferences.replyLanguage, .matchInput)
        XCTAssertEqual(preferences.speechLanguage, .automatic)
        XCTAssertNil(preferences.speechLanguage.localeIdentifier)
        XCTAssertTrue(preferences.speechOnDevice)
        XCTAssertEqual(preferences.autonomy, .addDirectly)
        XCTAssertEqual(preferences.chatRetention, .month)
        XCTAssertEqual(preferences.chatRetention.maxAge, 30 * 86_400)
        XCTAssertNil(ChatRetention.forever.maxAge)
    }

    func testDefaultRemindersMatchTheBuiltInPolicy() {
        let preferences = AppPreferences()
        let policy = ReminderPolicy()
        for kind in ScheduleEvent.Kind.allCases {
            XCTAssertEqual(preferences.reminders(for: kind), policy.defaults(for: kind), kind.rawValue)
        }
    }

    func testDerivedValues() {
        var preferences = AppPreferences()
        preferences.reminderSource = .google
        XCTAssertFalse(preferences.localRemindersEnabled)
        XCTAssertTrue(preferences.writesGooglePopups)
        preferences.reminderSource = .smartSchedule
        XCTAssertTrue(preferences.localRemindersEnabled)
        XCTAssertFalse(preferences.writesGooglePopups)
        preferences.weekStart = .monday
        XCTAssertEqual(preferences.firstWeekday, 2)
        preferences.timeZoneIdentifier = "Asia/Taipei"
        XCTAssertEqual(preferences.timeZone.identifier, "Asia/Taipei")
        XCTAssertEqual(SpeechLanguage.chineseTaiwan.localeIdentifier, "zh-TW")
    }

    func testSetRemindersSanitises() {
        var preferences = AppPreferences()
        preferences.setReminders([30, 30, -5, 50_000, 1, 2, 3, 4], for: .task)
        XCTAssertEqual(preferences.taskReminders, [40_320, 30, 4, 3, 2])
        preferences.setReminders([], for: .routine)
        XCTAssertEqual(preferences.reminders(for: .routine), [])
        preferences.setUrgency(.quiet, for: .deadline)
        XCTAssertEqual(preferences.deadlineUrgency, .quiet)
    }

    // MARK: Quiet hours

    func testQuietHoursAcrossMidnight() {
        let quiet = QuietHours(isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        XCTAssertTrue(quiet.contains(minuteOfDay: 22 * 60))
        XCTAssertTrue(quiet.contains(minuteOfDay: 23 * 60 + 59))
        XCTAssertTrue(quiet.contains(minuteOfDay: 0))
        XCTAssertTrue(quiet.contains(minuteOfDay: 6 * 60 + 59))
        XCTAssertFalse(quiet.contains(minuteOfDay: 7 * 60))
        XCTAssertFalse(quiet.contains(minuteOfDay: 21 * 60 + 59))
        XCTAssertFalse(quiet.contains(minuteOfDay: 12 * 60))
    }

    func testQuietHoursWithinOneDayDisabledOrEmpty() {
        let lunch = QuietHours(isEnabled: true, startMinute: 13 * 60, endMinute: 14 * 60)
        XCTAssertTrue(lunch.contains(minuteOfDay: 13 * 60 + 30))
        XCTAssertFalse(lunch.contains(minuteOfDay: 14 * 60))
        XCTAssertFalse(lunch.contains(minuteOfDay: 12 * 60 + 59))
        XCTAssertFalse(QuietHours(isEnabled: false, startMinute: 0, endMinute: 1439).contains(minuteOfDay: 600))
        XCTAssertFalse(QuietHours(isEnabled: true, startMinute: 600, endMinute: 600).contains(minuteOfDay: 600))
    }

    // MARK: Tolerant decoding

    func testEmptyObjectDecodesToDefaults() throws {
        XCTAssertEqual(try decode("{}"), AppPreferences())
    }

    func testUnknownEnumValuesFallBackToTheirDefaults() throws {
        let preferences = try decode(#"""
        {"reminderSource":"pigeon","eventUrgency":"loud","taskUrgency":"quiet","weekStart":"friday",
         "replyLanguage":"fr","speechLanguage":"de-DE","autonomy":"yolo","chatRetention":"1y"}
        """#)
        XCTAssertEqual(preferences.reminderSource, .both)
        XCTAssertEqual(preferences.eventUrgency, .automatic)
        XCTAssertEqual(preferences.taskUrgency, .quiet)
        XCTAssertEqual(preferences.weekStart, .sunday)
        XCTAssertEqual(preferences.replyLanguage, .matchInput)
        XCTAssertEqual(preferences.speechLanguage, .automatic)
        XCTAssertEqual(preferences.autonomy, .addDirectly)
        XCTAssertEqual(preferences.chatRetention, .month)
    }

    func testFutureVersionStillReadsKnownKeys() throws {
        let preferences = try decode(#"{"version":7,"reminderSource":"google","somethingNew":{"a":1},"defaultEventMinutes":30}"#)
        XCTAssertEqual(preferences.version, 7)
        XCTAssertEqual(preferences.reminderSource, .google)
        XCTAssertEqual(preferences.defaultEventMinutes, 30)
    }

    func testWrongTypesFallBackOneByOne() throws {
        let preferences = try decode(#"""
        {"eventReminders":"lots","defaultEventMinutes":"sixty","speechOnDevice":false,
         "quietHours":{"isEnabled":true,"startMinute":"late"},"morningBriefing":{"isEnabled":false,"minuteOfDay":400}}
        """#)
        XCTAssertEqual(preferences.eventReminders, [1440, 60, 30, 0])
        XCTAssertEqual(preferences.defaultEventMinutes, 60)
        XCTAssertFalse(preferences.speechOnDevice)
        XCTAssertEqual(preferences.quietHours, QuietHours(isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60))
        XCTAssertEqual(preferences.morningBriefing, DailyTime(isEnabled: false, minuteOfDay: 400))
    }

    func testDecodedValuesAreClampedIntoRange() throws {
        let preferences = try decode(#"""
        {"eventReminders":[30,30,-5,99999,1,2,3,4],"dailyReminderCap":500,"defaultEventMinutes":1,
         "allDayReminderMinutes":5000,"timeZoneIdentifier":"Mars/Olympus","quietHours":{"isEnabled":true,"startMinute":-3,"endMinute":9000}}
        """#)
        XCTAssertEqual(preferences.eventReminders, [40_320, 30, 4, 3, 2])
        XCTAssertEqual(preferences.dailyReminderCap, 50)
        XCTAssertEqual(preferences.defaultEventMinutes, 5)
        XCTAssertEqual(preferences.allDayReminderMinutes, 1440)
        XCTAssertNil(preferences.timeZoneIdentifier)
        XCTAssertEqual(preferences.quietHours.startMinute, 0)
        XCTAssertEqual(preferences.quietHours.endMinute, 1439)
    }

    func testExplicitNullMeansOffButMissingMeansDefault() throws {
        let preferences = try decode(#"{"allDayReminderMinutes":null,"liveActivityLeadMinutes":null}"#)
        XCTAssertNil(preferences.allDayReminderMinutes)
        XCTAssertNil(preferences.liveActivityLeadMinutes)
        XCTAssertEqual(try decode("{}").allDayReminderMinutes, 900)
        XCTAssertEqual(try decode("{}").liveActivityLeadMinutes, 30)
    }

    func testEncodeDecodeRoundTripKeepsNils() throws {
        var preferences = AppPreferences()
        preferences.allDayReminderMinutes = nil
        preferences.liveActivityLeadMinutes = nil
        preferences.dailyReminderCap = 12
        preferences.defaultCalendar = CalendarRef(accountID: "acct", calendarID: "student@university.example.edu")
        preferences.defaultCalendarLabel = "My calendar | student@university.example.edu"
        preferences.timeZoneIdentifier = "Asia/Taipei"
        preferences.quietHours = QuietHours(isEnabled: true, startMinute: 23 * 60, endMinute: 8 * 60)
        preferences.reminderSource = .smartSchedule
        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: data), preferences)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""allDayReminderMinutes":null"#))
    }

    // MARK: Normalising model values

    func testRemindersNormalise() throws {
        let preferences = AppPreferences()
        XCTAssertEqual(try preferences.normalized("1440,60,30,0", for: .eventReminders), "1440,60,30,0")
        XCTAssertEqual(try preferences.normalized("120", for: .routineReminders), "120")
        XCTAssertEqual(try preferences.normalized(" 10, 1440 、60 ", for: .taskReminders), "1440,60,10")
        XCTAssertEqual(try preferences.normalized("60,60", for: .deadlineReminders), "60")
        XCTAssertEqual(try preferences.normalized("none", for: .eventReminders), "none")
        XCTAssertEqual(try preferences.normalized("0", for: .eventReminders), "0")
        for bad in ["", "abc", "-5", "40321", "1,2,3,4,5,6", "1 hour"] {
            assertRejected(bad, for: .eventReminders)
        }
    }

    func testAllDayReminderNormalises() throws {
        let preferences = AppPreferences()
        XCTAssertEqual(try preferences.normalized("09:00", for: .allDayReminder), "900")
        XCTAssertEqual(try preferences.normalized("00:00", for: .allDayReminder), "1440")
        XCTAssertEqual(try preferences.normalized("23:30", for: .allDayReminder), "30")
        XCTAssertEqual(try preferences.normalized("none", for: .allDayReminder), "none")
        for bad in ["9am", "25:00", "09:60", ""] {
            assertRejected(bad, for: .allDayReminder)
        }
    }

    func testUrgencyNormalises() throws {
        let preferences = AppPreferences()
        XCTAssertEqual(try preferences.normalized("time_sensitive", for: .eventUrgency), "time_sensitive")
        XCTAssertEqual(try preferences.normalized("Time-Sensitive", for: .deadlineUrgency), "time_sensitive")
        XCTAssertEqual(try preferences.normalized("QUIET", for: .taskUrgency), "quiet")
        XCTAssertEqual(try preferences.normalized("automatic", for: .routineUrgency), "automatic")
        assertRejected("loud", for: .eventUrgency)
    }

    func testQuietHoursNormalise() throws {
        var preferences = AppPreferences()
        XCTAssertEqual(try preferences.normalized("22:00-08:00", for: .quietHours), "on 22:00-08:00")
        XCTAssertEqual(try preferences.normalized("23:00–7:00", for: .quietHours), "on 23:00-07:00")
        XCTAssertEqual(try preferences.normalized("off", for: .quietHours), "off 22:00-07:00")
        XCTAssertEqual(try preferences.normalized("on", for: .quietHours), "on 22:00-07:00")
        preferences.quietHours = QuietHours(isEnabled: true, startMinute: 23 * 60, endMinute: 6 * 60)
        XCTAssertEqual(try preferences.normalized("OFF", for: .quietHours), "off 23:00-06:00")
        for bad in ["22:00", "08:00-08:00", "late", "22-08"] {
            assertRejected(bad, for: .quietHours)
        }
    }

    func testBriefingsNormalise() throws {
        let preferences = AppPreferences()
        XCTAssertEqual(try preferences.normalized("07:00", for: .morningBriefing), "on 07:00")
        XCTAssertEqual(try preferences.normalized("off", for: .morningBriefing), "off 07:30")
        XCTAssertEqual(try preferences.normalized("on", for: .eveningPreview), "on 21:00")
        XCTAssertEqual(try preferences.normalized("20:45", for: .eveningPreview), "on 20:45")
        assertRejected("7", for: .morningBriefing)
        assertRejected("evening", for: .eveningPreview)
    }

    func testCapDurationWeekLanguageAutonomyNormalise() throws {
        let preferences = AppPreferences()
        XCTAssertEqual(try preferences.normalized("10", for: .dailyReminderCap), "10")
        XCTAssertEqual(try preferences.normalized("off", for: .dailyReminderCap), "off")
        XCTAssertEqual(try preferences.normalized("30", for: .defaultDuration), "30")
        XCTAssertEqual(try preferences.normalized("Monday", for: .weekStart), "monday")
        XCTAssertEqual(try preferences.normalized("zh-Hant", for: .replyLanguage), "zh-Hant")
        XCTAssertEqual(try preferences.normalized("zh_TW", for: .replyLanguage), "zh-Hant")
        XCTAssertEqual(try preferences.normalized("EN", for: .replyLanguage), "en")
        XCTAssertEqual(try preferences.normalized("match", for: .replyLanguage), "match")
        XCTAssertEqual(try preferences.normalized("ask_first", for: .autonomy), "ask_first")
        XCTAssertEqual(try preferences.normalized("automatic", for: .defaultCalendar), "automatic")
        for bad in ["0", "51", "ten"] { assertRejected(bad, for: .dailyReminderCap) }
        for bad in ["4", "481", "half an hour"] { assertRejected(bad, for: .defaultDuration) }
        assertRejected("friday", for: .weekStart)
        assertRejected("fr", for: .replyLanguage)
        assertRejected("maybe", for: .autonomy)
        assertRejected("My calendar | student@university.example.edu", for: .defaultCalendar)
    }

    func testRejectionReasonsAreReadableEnglish() {
        XCTAssertThrowsError(try AppPreferences().normalized("22:00", for: .quietHours)) {
            XCTAssertEqual($0 as? PreferenceValueError, .invalid("quiet_hours must be HH:mm-HH:mm or off"))
        }
        XCTAssertThrowsError(try AppPreferences().normalized("08:00-08:00", for: .quietHours)) {
            XCTAssertEqual($0 as? PreferenceValueError, .invalid("quiet_hours must start and end at different times"))
        }
    }

    // MARK: Canonical, prompt and display values

    private func customised() -> AppPreferences {
        var preferences = AppPreferences()
        preferences.eventReminders = [120, 0]
        preferences.deadlineReminders = []
        preferences.taskReminders = [15]
        preferences.routineReminders = [1440, 60]
        preferences.allDayReminderMinutes = nil
        preferences.eventUrgency = .timeSensitive
        preferences.deadlineUrgency = .normal
        preferences.taskUrgency = .quiet
        preferences.quietHours = QuietHours(isEnabled: false, startMinute: 23 * 60, endMinute: 6 * 60 + 30)
        preferences.morningBriefing = DailyTime(isEnabled: false, minuteOfDay: 8 * 60)
        preferences.eveningPreview = DailyTime(isEnabled: true, minuteOfDay: 20 * 60 + 15)
        preferences.dailyReminderCap = 8
        preferences.defaultCalendar = CalendarRef(accountID: "demo-school", calendarID: "student@university.example.edu")
        preferences.defaultCalendarLabel = "My calendar | student@university.example.edu"
        preferences.defaultEventMinutes = 45
        preferences.weekStart = .monday
        preferences.replyLanguage = .english
        preferences.autonomy = .askFirst
        return preferences
    }

    func testCanonicalValuesRoundTripForEveryKey() throws {
        for source in [AppPreferences(), customised()] {
            for key in PreferenceKey.allCases {
                let canonical = source.canonicalValue(for: key)
                var target = source == AppPreferences() ? customised() : AppPreferences()
                try target.apply(canonical: canonical, for: key)
                XCTAssertEqual(target.canonicalValue(for: key), canonical, key.rawValue)
            }
        }
        var rebuilt = AppPreferences()
        for key in PreferenceKey.allCases {
            try rebuilt.apply(canonical: customised().canonicalValue(for: key), for: key)
        }
        XCTAssertEqual(rebuilt, customised())
    }

    func testCanonicalFormsAreStable() {
        let preferences = customised()
        XCTAssertEqual(preferences.canonicalValue(for: .deadlineReminders), "none")
        XCTAssertEqual(preferences.canonicalValue(for: .allDayReminder), "none")
        XCTAssertEqual(preferences.canonicalValue(for: .quietHours), "off 23:00-06:30")
        XCTAssertEqual(preferences.canonicalValue(for: .morningBriefing), "off 08:00")
        XCTAssertEqual(preferences.canonicalValue(for: .defaultCalendar),
                       "demo-school/student@university.example.edu|My calendar | student@university.example.edu")
        XCTAssertEqual(AppPreferences().canonicalValue(for: .allDayReminder), "900")
        XCTAssertEqual(AppPreferences().canonicalValue(for: .defaultCalendar), "automatic")
    }

    func testApplyRejectsUnreadableCanonicalValues() {
        var preferences = AppPreferences()
        XCTAssertThrowsError(try preferences.apply(canonical: "soon", for: .quietHours))
        XCTAssertThrowsError(try preferences.apply(canonical: "a,b", for: .eventReminders))
        XCTAssertThrowsError(try preferences.apply(canonical: "no-separator", for: .defaultCalendar))
        XCTAssertEqual(preferences, AppPreferences())
    }

    func testPromptValues() {
        let defaults = AppPreferences()
        let expected: [PreferenceKey: String] = [
            .eventReminders: "1440,60,30,0", .deadlineReminders: "1440,60", .taskReminders: "60", .routineReminders: "30",
            .allDayReminder: "09:00", .eventUrgency: "automatic", .deadlineUrgency: "automatic",
            .taskUrgency: "automatic", .routineUrgency: "automatic", .quietHours: "off", .morningBriefing: "07:30",
            .eveningPreview: "off", .dailyReminderCap: "off", .defaultCalendar: "automatic", .defaultDuration: "60",
            .weekStart: "sunday", .replyLanguage: "match", .autonomy: "add_directly"
        ]
        for key in PreferenceKey.allCases {
            XCTAssertEqual(defaults.promptValue(for: key), expected[key], key.rawValue)
        }
        let custom = customised()
        XCTAssertEqual(custom.promptValue(for: .deadlineReminders), "none")
        XCTAssertEqual(custom.promptValue(for: .allDayReminder), "none")
        XCTAssertEqual(custom.promptValue(for: .eveningPreview), "20:15")
        XCTAssertEqual(custom.promptValue(for: .defaultCalendar), "My calendar | student@university.example.edu")
        XCTAssertEqual(custom.promptValue(for: .eventUrgency), "time_sensitive")
        var quiet = AppPreferences()
        quiet.quietHours.isEnabled = true
        XCTAssertEqual(quiet.promptValue(for: .quietHours), "22:00-07:00")
    }

    /// Bundle.main is the test runner, so these are the English source strings.
    func testDisplayValues() {
        let defaults = AppPreferences()
        XCTAssertEqual(defaults.displayValue(for: .eventReminders), "1 day, 1 h, 30 min, at start")
        XCTAssertEqual(defaults.displayValue(for: .allDayReminder), "The day before at 09:00")
        XCTAssertEqual(defaults.displayValue(for: .eventUrgency), "Automatic")
        XCTAssertEqual(defaults.displayValue(for: .quietHours), "Off")
        XCTAssertEqual(defaults.displayValue(for: .morningBriefing), "07:30")
        XCTAssertEqual(defaults.displayValue(for: .dailyReminderCap), "Off")
        XCTAssertEqual(defaults.displayValue(for: .defaultCalendar), "Automatic")
        XCTAssertEqual(defaults.displayValue(for: .defaultDuration), "60 min")
        XCTAssertEqual(defaults.displayValue(for: .weekStart), "Sunday")
        XCTAssertEqual(defaults.displayValue(for: .replyLanguage), "Match what I type")
        XCTAssertEqual(defaults.displayValue(for: .autonomy), "Add directly")

        let custom = customised()
        XCTAssertEqual(custom.displayValue(for: .deadlineReminders), "None")
        XCTAssertEqual(custom.displayValue(for: .routineReminders), "1 day, 1 h")
        XCTAssertEqual(custom.displayValue(for: .taskReminders), "15 min")
        XCTAssertEqual(custom.displayValue(for: .allDayReminder), "None")
        XCTAssertEqual(custom.displayValue(for: .eventUrgency), "Time Sensitive")
        XCTAssertEqual(custom.displayValue(for: .deadlineUrgency), "Normal")
        XCTAssertEqual(custom.displayValue(for: .taskUrgency), "Quiet")
        XCTAssertEqual(custom.displayValue(for: .dailyReminderCap), "8 a day")
        XCTAssertEqual(custom.displayValue(for: .defaultCalendar), "My calendar · student@university.example.edu")
        XCTAssertEqual(custom.displayValue(for: .weekStart), "Monday")
        XCTAssertEqual(custom.displayValue(for: .replyLanguage), "English")
        XCTAssertEqual(custom.displayValue(for: .autonomy), "Ask me first")
        var on = AppPreferences()
        on.quietHours = QuietHours(isEnabled: true, startMinute: 22 * 60, endMinute: 8 * 60)
        on.replyLanguage = .traditionalChinese
        XCTAssertEqual(on.displayValue(for: .quietHours), "22:00–08:00")
        XCTAssertEqual(on.displayValue(for: .replyLanguage), "繁體中文")
    }

    func testPromptValueOfACanonicalValue() {
        XCTAssertEqual(AppPreferences.promptValue(canonical: "off 23:00-06:00", for: .quietHours), "off")
        XCTAssertEqual(AppPreferences.promptValue(canonical: "on 23:00-06:00", for: .quietHours), "23:00-06:00")
        XCTAssertEqual(AppPreferences.promptValue(canonical: "900", for: .allDayReminder), "09:00")
        XCTAssertEqual(AppPreferences.promptValue(canonical: "a/b|My calendar | b", for: .defaultCalendar), "My calendar | b")
        XCTAssertEqual(AppPreferences.promptValue(canonical: "garbage", for: .weekStart), "garbage")
    }

    func testResetRestoresTheDefaultOfOneKey() {
        var preferences = customised()
        preferences.reset(.defaultCalendar)
        XCTAssertNil(preferences.defaultCalendar)
        XCTAssertNil(preferences.defaultCalendarLabel)
        preferences.reset(.allDayReminder)
        XCTAssertEqual(preferences.allDayReminderMinutes, 900)
        preferences.reset(.quietHours)
        XCTAssertEqual(preferences.quietHours, QuietHours())
        XCTAssertEqual(preferences.weekStart, .monday, "other keys untouched")
    }

    func testEveryKeyHasATitleAndItsFunctionName() {
        XCTAssertEqual(PreferenceKey.allCases.count, 18)
        XCTAssertEqual(PreferenceKey.quietHours.rawValue, "quiet_hours")
        XCTAssertEqual(PreferenceKey.quietHours.title, "Quiet hours")
        XCTAssertEqual(PreferenceKey.autonomy.title, "Adding events")
        XCTAssertTrue(PreferenceKey.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(PreferenceKey.quietHours.affectsNotifications)
        XCTAssertFalse(PreferenceKey.defaultDuration.affectsNotifications)
    }

    // MARK: Reminder wording

    func testReminderText() {
        XCTAssertEqual(ReminderText.offset(0), "At start")
        XCTAssertEqual(ReminderText.offset(10), "10 minutes before")
        XCTAssertEqual(ReminderText.offset(60), "1 hour before")
        XCTAssertEqual(ReminderText.offset(120), "2 hours before")
        XCTAssertEqual(ReminderText.offset(1440), "1 day before")
        XCTAssertEqual(ReminderText.offset(2880), "2 days before")
        XCTAssertEqual(ReminderText.offset(900, allDay: true), "The day before at 09:00")
        XCTAssertEqual(ReminderText.offset(0, allDay: true), "On the day at 00:00")
        XCTAssertEqual(ReminderText.offset(1500, allDay: true), "2 days before at 23:00")
        XCTAssertEqual(ReminderText.list([2880, 1440, 90, 120, 0]), "2 days, 1 day, 90 min, 2 h, at start")
        XCTAssertEqual(ReminderText.list([]), "None")
        XCTAssertEqual(ReminderText.clock(7 * 60 + 5), "07:05")
    }
}
