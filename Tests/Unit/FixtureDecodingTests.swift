import XCTest

/// Every example call in Tests/fixtures must decode into the typed args the orchestrator uses, with the same
/// snake_case decoding as `GeminiFunctionCall.decode`. scripts/validate_schema.py checks the same files
/// against the JSON schema, so together they pin schema ⇄ Swift types.
final class FixtureDecodingTests: XCTestCase {
    func testEveryFixtureDecodesIntoItsArgsType() throws {
        let names = try Fixtures.allNames()
        XCTAssertGreaterThanOrEqual(names.count, 11)
        for name in names {
            let call = try Fixtures.call(name)
            let function = try XCTUnwrap(AssistantFunction(rawValue: call.name), "\(name): unknown function \(call.name)")
            switch function {
            case .createEvents:
                XCTAssertNoThrow(try TestJSON.decode(CreateEventsArgs.self, data: call.args), name)
            case .createLongTermPlan:
                XCTAssertNoThrow(try TestJSON.decode(LongTermPlanArgs.self, data: call.args), name)
            case .modifyEvent:
                XCTAssertNoThrow(try TestJSON.decode(ModifyEventArgs.self, data: call.args), name)
            case .deleteEvents:
                XCTAssertNoThrow(try TestJSON.decode(DeleteEventsArgs.self, data: call.args), name)
            case .querySchedule:
                XCTAssertNoThrow(try TestJSON.decode(QueryScheduleArgs.self, data: call.args), name)
            case .replyToUser:
                XCTAssertNoThrow(try TestJSON.decode(ReplyToUserArgs.self, data: call.args), name)
            case .confirmPlan:
                XCTAssertNoThrow(try TestJSON.decode(ConfirmPlanArgs.self, data: call.args), name)
            case .updatePreferences:
                XCTAssertNoThrow(try TestJSON.decode(UpdatePreferencesArgs.self, data: call.args), name)
            }
        }
    }

    func testFixturesUseLondonWallClock() throws {
        for name in try Fixtures.allNames() {
            let root = try Fixtures.root(name)
            let zone = try XCTUnwrap(root["time_zone"] as? String, name)
            XCTAssertEqual(zone, "Europe/London", name)
            XCTAssertNotNil(TimeZone(identifier: zone), name)
            let now = try XCTUnwrap(root["now_local"] as? String, name)
            XCTAssertNotNil(TestClock.clock.dateTime(now), name)
        }
    }

    func testCreateEventsSingle() throws {
        let args = try Fixtures.args(CreateEventsArgs.self, from: "create_events.single.json")
        XCTAssertEqual(args.events.count, 1)
        let event = try XCTUnwrap(args.events.first)
        XCTAssertEqual(event.start, "2026-10-14T14:00")
        XCTAssertEqual(event.durationMinutes, 60)
        XCTAssertEqual(event.kind, "event")
        XCTAssertEqual(event.addVideoConference, true)
        XCTAssertNil(event.recurrence)
    }

    func testCreateEventsMulti() throws {
        let args = try Fixtures.args(CreateEventsArgs.self, from: "create_events.multi.json")
        XCTAssertEqual(args.events.map(\.title), ["Meeting", "Pay bills"])
        XCTAssertEqual(args.events[1].kind, "task")
        XCTAssertEqual(args.events[1].durationMinutes, 30)
    }

    func testLongTermPlan() throws {
        let plan = try Fixtures.args(LongTermPlanArgs.self, from: "create_long_term_plan.muscle.json")
        XCTAssertEqual(plan.planTitle, "Muscle 6M")
        XCTAssertEqual(plan.startDate, "2026-10-14")
        XCTAssertEqual(plan.endDate, "2027-04-13")
        XCTAssertEqual(plan.phases.count, 3)
        XCTAssertEqual(plan.sessions.count, 6)
        XCTAssertEqual(plan.sessions.map(\.phaseIndex), [0, 0, 1, 1, 2, 2])
        XCTAssertEqual(plan.sessions.first?.weekdays, ["MO", "TH"])
        XCTAssertEqual(plan.sessions.first?.startTime, "18:30")
        XCTAssertEqual(plan.dailyNudge?.time, "07:30")
        XCTAssertEqual(plan.milestones?.count, 6)
        XCTAssertEqual(plan.assumptions?.count, 2)
    }

    func testLongTermPlanRevisionIsCompleteAndKeepsItsTitle() throws {
        let name = "create_long_term_plan.revision.json"
        XCTAssertEqual(try Fixtures.root(name)["revises"] as? String, "create_long_term_plan.muscle.json")
        let original = try Fixtures.args(LongTermPlanArgs.self, from: "create_long_term_plan.muscle.json")
        let revised = try Fixtures.args(LongTermPlanArgs.self, from: name)

        // A revision restates the whole plan; only what the user asked for changes.
        XCTAssertEqual(revised.planTitle, original.planTitle)
        XCTAssertEqual(revised.startDate, original.startDate)
        XCTAssertEqual(revised.endDate, original.endDate)
        XCTAssertEqual(revised.phases.map(\.name), original.phases.map(\.name))
        XCTAssertEqual(revised.sessions.map(\.title), original.sessions.map(\.title))
        XCTAssertEqual(revised.sessions.map(\.weekdays), original.sessions.map(\.weekdays))
        XCTAssertEqual(revised.sessions.map(\.durationMinutes), original.sessions.map(\.durationMinutes))
        XCTAssertEqual(revised.milestones?.map(\.date), original.milestones?.map(\.date))
        XCTAssertEqual(Set(revised.sessions.map(\.startTime)), ["07:00"])
        XCTAssertEqual(revised.dailyNudge?.time, "06:15")
    }

    func testConfirmPlanAdd() throws {
        let name = "confirm_plan.add.json"
        XCTAssertEqual(try Fixtures.args(ConfirmPlanArgs.self, from: name).decision, "add")
        // confirm_plan only exists while a draft is on screen.
        XCTAssertNotNil(try Fixtures.root(name)["draft_plan"] as? String)
    }

    func testModifyEvent() throws {
        let args = try Fixtures.args(ModifyEventArgs.self, from: "modify_event.push.json")
        XCTAssertEqual(args.eventId, "ss0k3p")
        XCTAssertNil(args.scope)
        XCTAssertEqual(args.changes.start, "2026-10-13T16:00")
        XCTAssertNil(args.changes.end)
        XCTAssertNil(args.changes.title)
    }

    func testOneOffReminderStaysOnTheEvent() throws {
        // "remind me an hour before tomorrow's dentist" is about one event, not a lasting preference.
        let name = "modify_event.one_off_reminder.json"
        let args = try Fixtures.args(ModifyEventArgs.self, from: name)
        XCTAssertEqual(args.eventId, "ssd3nt1st")
        XCTAssertEqual(args.changes.reminderMinutes, [60])
        XCTAssertNil(args.changes.start)
        let upcoming = try XCTUnwrap(Fixtures.root(name)["upcoming"] as? String)
        XCTAssertTrue(upcoming.hasPrefix("ssd3nt1st | Dentist |"), upcoming)
    }

    // MARK: update_preferences

    func testQuietHoursPreference() throws {
        let args = try Fixtures.args(UpdatePreferencesArgs.self, from: "update_preferences.quiet_hours.json")
        XCTAssertEqual(args.changes.map(\.key), ["quiet_hours"])
        XCTAssertEqual(args.changes.first?.value, "22:00-08:00")
        XCTAssertEqual(args.summaryForUser, "以後 08:00 前的提醒會靜音送達。")
        // The value is one the app's normaliser accepts, starting from quiet hours being off.
        var preferences = AppPreferences()
        try preferences.apply(canonical: preferences.normalized("22:00-08:00", for: .quietHours), for: .quietHours)
        XCTAssertEqual(preferences.quietHours, QuietHours(isEnabled: true, startMinute: 22 * 60, endMinute: 8 * 60))
    }

    func testRoutineRemindersPreference() throws {
        let args = try Fixtures.args(UpdatePreferencesArgs.self, from: "update_preferences.routine_reminders.json")
        XCTAssertEqual(args.changes.map(\.key), ["routine_reminders"])
        XCTAssertEqual(args.changes.first?.value, "120")
        var preferences = AppPreferences()
        try preferences.apply(canonical: preferences.normalized("120", for: .routineReminders), for: .routineReminders)
        XCTAssertEqual(preferences.routineReminders, [120])
    }

    func testDefaultCalendarPreferenceNamesACalendarsLine() throws {
        let name = "update_preferences.default_calendar.json"
        let args = try Fixtures.args(UpdatePreferencesArgs.self, from: name)
        XCTAssertEqual(args.changes.map(\.key), ["default_calendar"])
        let value = try XCTUnwrap(args.changes.first?.value)
        XCTAssertEqual(value, "My calendar | example@yourmail.com")
        let calendars = try XCTUnwrap(Fixtures.root(name)["calendars"] as? String)
        XCTAssertTrue(calendars.components(separatedBy: "\n").contains("- \(value)"), calendars)
        // The same label the demo's school calendar shows in CALENDARS.
        XCTAssertTrue(DemoData.accounts.flatMap(\.calendars).contains { $0.promptLabel == value })
    }

    func testEveryPreferenceFixtureUsesKnownKeys() throws {
        for name in try Fixtures.allNames() where name.hasPrefix("update_preferences.") {
            let args = try Fixtures.args(UpdatePreferencesArgs.self, from: name)
            XCTAssertFalse(args.changes.isEmpty, name)
            for change in args.changes {
                XCTAssertNotNil(PreferenceKey(rawValue: change.key), "\(name): \(change.key)")
            }
            XCTAssertFalse(args.summaryForUser.isEmpty, name)
        }
    }

    func testUpdatePreferencesDecodingIsTolerant() throws {
        // A number where the schema says string, and an unknown key: both decode; the key is rejected later.
        let args = try TestJSON.decode(UpdatePreferencesArgs.self, json: """
        {"changes": [{"key": "default_duration", "value": 30}, {"key": "theme", "value": "dark"}],
         "summary_for_user": "OK."}
        """)
        XCTAssertEqual(args.changes.map(\.value), ["30", "dark"])
        XCTAssertNil(PreferenceKey(rawValue: args.changes[1].key))
    }

    func testQuerySchedule() throws {
        let args = try Fixtures.args(QueryScheduleArgs.self, from: "query_schedule.today.json")
        XCTAssertEqual(args.rangeStart, "2026-10-15")
        XCTAssertNil(args.rangeEnd)
        XCTAssertEqual(args.view, "day")
    }
}
