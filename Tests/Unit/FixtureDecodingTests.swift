import XCTest

/// Every example call in Tests/fixtures must decode into the typed args the orchestrator uses, with the same
/// snake_case decoding as `GeminiFunctionCall.decode`. scripts/validate_schema.py checks the same files
/// against the JSON schema, so together they pin schema ⇄ Swift types.
final class FixtureDecodingTests: XCTestCase {
    func testEveryFixtureDecodesIntoItsArgsType() throws {
        let names = try Fixtures.allNames()
        XCTAssertGreaterThanOrEqual(names.count, 11)
        for name in names {
            for call in try [Fixtures.call(name)] + Fixtures.alsoCalls(name) {
                try assertDecodes(call, fixture: name)
            }
            for function in try Fixtures.mustNotCall(name) {
                XCTAssertNotNil(AssistantFunction(rawValue: function), "\(name): must_not_call names unknown \(function)")
            }
        }
    }

    private func assertDecodes(_ call: (name: String, args: Data), fixture name: String) throws {
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
        case .planDeparture:
            XCTAssertNoThrow(try TestJSON.decode(PlanDepartureArgs.self, data: call.args), name)
        case .suggestEventNotes:
            XCTAssertNoThrow(try TestJSON.decode(SuggestEventNotesArgs.self, data: call.args), name)
        }
    }

    // MARK: plan_departure (prompt rule 13)

    /// The calls of a fixture's turn: `expected_call` first, then `also_calls`.
    private func turn(_ name: String) throws -> [String] {
        try ([Fixtures.call(name)] + Fixtures.alsoCalls(name)).map(\.name)
    }

    func testDepartureFixturesCoverTheOwnersExamples() throws {
        let names = try Fixtures.allNames()
        let departures = try names.filter { try turn($0).contains("plan_departure") }
        let withNewEvent = try departures.filter { try Fixtures.args(PlanDepartureArgs.self, from: $0).createEvent == true }
        XCTAssertGreaterThanOrEqual(departures.count - withNewEvent.count, 3, "asking how long or when to leave")
        XCTAssertGreaterThanOrEqual(withNewEvent.count, 3, "being somewhere at a time, with a new event")
        let ordinary = try names.filter { try Fixtures.mustNotCall($0).contains("plan_departure") }
        XCTAssertGreaterThanOrEqual(ordinary.count, 3, "ordinary events that must not plan a departure")
        for name in ordinary {
            XCTAssertFalse(try turn(name).contains("plan_departure"), name)
        }
    }

    func testHowLongIsTheDestinationOnly() throws {
        let args = try Fixtures.args(PlanDepartureArgs.self, from: "plan_departure.how_long.json")
        XCTAssertEqual(args.destination, "台北 101")
        XCTAssertNil(args.arriveAtLocal, "only how long: no time to arrive")
        XCTAssertNil(args.eventId)
        XCTAssertNil(args.createEvent)
        XCTAssertNil(args.mode, "the app chooses the way of travelling")
        XCTAssertTrue(try Fixtures.alsoCalls("plan_departure.how_long.json").isEmpty)
    }

    func testAnExistingEventPassesItsIdOnly() throws {
        // Gemini never sees an event's place (consent v7, docs/SETTINGS.md §7.11): the app reads it (owner, 2026-10-19).
        let name = "plan_departure.existing_event.json"
        let args = try Fixtures.args(PlanDepartureArgs.self, from: name)
        XCTAssertEqual(args.eventId, "ssd3nt1st")
        XCTAssertNil(args.destination)
        XCTAssertNil(args.arriveAtLocal, "the app knows the event's start")
        let upcoming = try XCTUnwrap(Fixtures.root(name)["upcoming"] as? String)
        XCTAssertTrue(upcoming.hasPrefix("ssd3nt1st | Dentist |"), upcoming)
    }

    func testANewEventToLeaveForComesWithItsCreateEvents() throws {
        let name = "plan_departure.new_meeting.json"
        let args = try Fixtures.args(PlanDepartureArgs.self, from: name)
        XCTAssertEqual(args.destination, "台北 101")
        XCTAssertEqual(args.arriveAtLocal, "2026-10-13T17:00", "the event's start, not 30 minutes earlier")
        XCTAssertEqual(args.arriveEarlyMinutes, 30)
        XCTAssertEqual(args.createEvent, true)
        let companions = try Fixtures.alsoCalls(name)
        XCTAssertEqual(companions.map(\.name), ["create_events"])
        let events = try TestJSON.decode(CreateEventsArgs.self, data: try XCTUnwrap(companions.first).args).events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.start, args.arriveAtLocal)
        XCTAssertEqual(events.first?.location, "台北 101")
        XCTAssertEqual(events.first?.durationMinutes, 60, "the length the user said")
        XCTAssertNil(events.first?.reminderMinutes, "提早 30 分鐘到 is when to arrive, not a reminder")
    }

    func testTheAnswerToTheLengthQuestionMakesBothCalls() throws {
        // The owner's example 1: the assistant asked how long the meeting lasts; 「1 小時」 completes the request, keeping
        // the place and the minutes early from the first message.
        let name = "plan_departure.after_length.json"
        XCTAssertEqual(try Fixtures.utterance(name), "1 小時")
        let earlier = try XCTUnwrap(Fixtures.root(name)["earlier_utterances"] as? [String])
        XCTAssertTrue(earlier.first?.contains("想提早 30 分鐘到") == true, "\(earlier)")
        let args = try Fixtures.args(PlanDepartureArgs.self, from: name)
        XCTAssertEqual(args.destination, "台北 101")
        XCTAssertEqual(args.arriveEarlyMinutes, 30)
        XCTAssertEqual(args.createEvent, true)
        let events = try TestJSON.decode(CreateEventsArgs.self,
                                         data: try XCTUnwrap(Fixtures.alsoCalls(name).first).args).events
        XCTAssertEqual(events.map(\.durationMinutes), [60])
    }

    func testOtherNewEventsGoInTheSameCreateEventsCall() throws {
        let name = "plan_departure.with_other_event.json"
        let args = try Fixtures.args(PlanDepartureArgs.self, from: name)
        let companions = try Fixtures.alsoCalls(name)
        XCTAssertEqual(companions.map(\.name), ["create_events"])
        let events = try TestJSON.decode(CreateEventsArgs.self, data: try XCTUnwrap(companions.first).args).events
        XCTAssertEqual(events.count, 2, "the dinner is created too")
        // The event to leave for is the one that starts at arrive_at_local.
        let leaving = events.filter { $0.start == args.arriveAtLocal }
        XCTAssertEqual(leaving.count, 1)
        XCTAssertEqual(leaving.first?.location, args.destination)
    }

    func testAStartingPointTheUserSaidIsPassedAsWritten() throws {
        let name = "plan_departure.from_station.json"
        let args = try Fixtures.args(PlanDepartureArgs.self, from: name)
        XCTAssertEqual(args.startingPoint, "台北車站")
        XCTAssertTrue(try Fixtures.utterance(name).contains("台北車站"))
    }

    func testANewDepartureEventWithoutALengthAsksFirst() throws {
        let name = "reply_to_user.departure_length.json"
        let args = try Fixtures.args(ReplyToUserArgs.self, from: name)
        XCTAssertEqual(args.needsClarification, true)
        XCTAssertEqual(args.suggestedReplies?.count, 3)
        XCTAssertEqual(Set(try Fixtures.mustNotCall(name)), ["plan_departure", "create_events"])
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

    func testCreateEventsWithSuggestedNotes() throws {
        let args = try Fixtures.args(CreateEventsArgs.self, from: "create_events.suggested_notes.json")
        let event = try XCTUnwrap(args.events.first)
        XCTAssertEqual(event.title, "飛東京")
        XCTAssertEqual(event.suggestedNotes, ["帶護照", "提早 2-3 小時到機場", "準備日圓現金"])
        XCTAssertNil(event.notes, "suggestions are not notes")
        // Optional: the other create_events fixtures have none.
        XCTAssertNil(try Fixtures.args(CreateEventsArgs.self, from: "create_events.single.json").events.first?.suggestedNotes)
    }

    func testSuggestEventNotes() throws {
        let tokyo = try Fixtures.args(SuggestEventNotesArgs.self, from: "suggest_event_notes.tokyo.json")
        XCTAssertEqual(tokyo.items, ["Yen cash", "IC transit card", "Visit Japan Web entry QR", "eSIM or pocket Wi-Fi"])
        XCTAssertNotNil(tokyo.reason)
        let hiking = try Fixtures.args(SuggestEventNotesArgs.self, from: "suggest_event_notes.hiking.json")
        XCTAssertEqual(hiking.items, ["保暖外套", "防曬乳和帽子", "登山杖", "垃圾袋"])
        // Tolerant: no items, or one string.
        XCTAssertEqual(try TestJSON.decode(SuggestEventNotesArgs.self, json: "{}").items, [])
        XCTAssertEqual(try TestJSON.decode(SuggestEventNotesArgs.self, json: #"{"items": "Passport"}"#).items, ["Passport"])
    }

    func testCreateEventsMulti() throws {
        let args = try Fixtures.args(CreateEventsArgs.self, from: "create_events.multi.json")
        XCTAssertEqual(args.events.map(\.title), ["Meeting", "Pay bills"])
        XCTAssertEqual(args.events[1].kind, "task")
        XCTAssertEqual(args.events[1].durationMinutes, 30)
    }

    func testTimeCountedFromNow() throws {
        // "1個小時後買蛋給 Jocelyn" at 22:50: one task at 23:50, the phrase out of the title, no reminder_minutes (created
        // for later the same day, it is reminded 10 minutes before and at the start).
        let name = "create_events.relative_time.json"
        let root = try Fixtures.root(name)
        let minutes = try XCTUnwrap(root["relative_minutes"] as? Int, name)
        let nowLocal = try XCTUnwrap(root["now_local"] as? String, name)
        let now = try XCTUnwrap(TestClock.clock.dateTime(nowLocal), nowLocal)
        let args = try Fixtures.args(CreateEventsArgs.self, from: name)
        XCTAssertEqual(args.events.count, 1)
        let draft = try XCTUnwrap(args.events.first)
        XCTAssertEqual(draft.title, "買蛋給 Jocelyn")
        XCTAssertNil(draft.end)
        XCTAssertNil(draft.reminderMinutes, "left out: the app works out the reminders")

        let mapper = CalendarEventMapper(clock: TestClock.clock, policy: ReminderPolicy())
        let mapped = try mapper.event(from: draft, seed: "s|0", utterance: Fixtures.utterance(name), createdAt: now)
        let event = try XCTUnwrap(mapper.scheduleEvent(from: mapped.body))
        XCTAssertEqual(event.title, "買蛋給 Jocelyn")
        XCTAssertEqual(event.kind, .task)
        XCTAssertEqual(event.start, TestClock.local(2026, 10, 13, 23, 50))
        XCTAssertEqual(event.start, now.addingTimeInterval(TimeInterval(minutes * 60)))
        XCTAssertEqual(event.end, TestClock.local(2026, 10, 14, 0, 20), "the task default of 30 minutes, past midnight")
        // Created at 22:50 for later the same day: 10 minutes before and at the start, not the task default (60
        // minutes before), the same list in Google and on this iPhone.
        XCTAssertEqual(CalendarEventMapper.reminderMinutes(of: mapped.body), [10, 0])
        XCTAssertEqual(mapped.body.extendedProperties?.private?[SSProperty.localReminders], "10,0")
        XCTAssertEqual(event.reminderMinutes, [10, 0])
        XCTAssertEqual(mapped.body.reminders?.overrides?.map(\.minutes), [10, 0])
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
        XCTAssertEqual(value, "My calendar | Account 2")
        let calendars = try XCTUnwrap(Fixtures.root(name)["calendars"] as? String)
        XCTAssertTrue(calendars.components(separatedBy: "\n").contains("- \(value)"), calendars)
        XCTAssertFalse(calendars.contains("@"), "CALENDARS shows no account email")
        // The same label the demo's school calendar shows in CALENDARS, and it maps back to that calendar.
        let demoCalendars = DemoData.accounts.flatMap(\.calendars)
        let aliases = CalendarAliases(calendars: demoCalendars)
        XCTAssertEqual(aliases.writableCalendar(matching: value)?.id, DemoData.schoolCalendar)
        let school = try XCTUnwrap(demoCalendars.first { $0.id == DemoData.schoolCalendar })
        XCTAssertEqual(aliases.label(of: school), value)
        XCTAssertEqual(demoCalendars.filter(\.isWritable).map { "- " + aliases.label(of: $0) },
                       calendars.components(separatedBy: "\n").map { $0.replacingOccurrences(of: " (default)", with: "") })
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
