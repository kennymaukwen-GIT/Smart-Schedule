import XCTest

final class CalendarEventMapperTests: XCTestCase {
    private let mapper = CalendarEventMapper(clock: TestClock.clock, policy: ReminderPolicy())

    private func draft(_ json: String) throws -> EventDraft {
        try TestJSON.decode(EventDraft.self, json: json)
    }

    // MARK: create_events

    func testSingleEventFixture() throws {
        let name = "create_events.single.json"
        let args = try Fixtures.args(CreateEventsArgs.self, from: name)
        let utterance = try Fixtures.utterance(name)
        let eventDraft = try XCTUnwrap(args.events.first)

        let mapped = try mapper.event(from: eventDraft, seed: "s", utterance: utterance)
        let body = mapped.body

        XCTAssertEqual(body.id, "ss0gt731rkolpbr2h5lmvb3fudbg")
        XCTAssertEqual(body.summary, "與Joe開會")
        XCTAssertTrue(body.description?.hasPrefix("由 Smart Schedule 智慧助理自動排程：") == true)
        XCTAssertEqual(body.description, CalendarEventMapper.provenancePrefix + utterance)

        XCTAssertEqual(body.start?.dateTime, "2026-10-14T14:00:00")
        XCTAssertEqual(body.start?.timeZone, "Europe/London")
        XCTAssertNil(body.start?.date)
        XCTAssertEqual(body.end?.dateTime, "2026-10-14T15:00:00")
        XCTAssertEqual(body.end?.timeZone, "Europe/London")

        XCTAssertEqual(body.reminders?.useDefault, false)
        XCTAssertEqual(body.reminders?.overrides?.map(\.minutes), [1440, 60, 30, 0])
        XCTAssertEqual(Set(body.reminders?.overrides?.map(\.method) ?? []), ["popup"])

        XCTAssertTrue(mapped.wantsConference)
        XCTAssertEqual(body.conferenceData?.createRequest?.conferenceSolutionKey.type, "hangoutsMeet")
        XCTAssertEqual(body.conferenceData?.createRequest?.requestId, body.id)

        XCTAssertEqual(body.extendedProperties?.private?["ssKind"], "event")
        XCTAssertEqual(body.extendedProperties?.private?["ssSource"], "smart-schedule")
        XCTAssertEqual(body.extendedProperties?.private?["ssSchema"], CalendarEventMapper.schemaVersion)
        XCTAssertNil(body.extendedProperties?.private?["ssPlanId"])
        XCTAssertNil(body.colorId) // plain events inherit the calendar colour

        let json = try TestJSON.object(encoding: body)
        XCTAssertNil(json["recurrence"])
        XCTAssertNil(json["colorId"])
        XCTAssertNil(json["attendees"])
        XCTAssertNotNil(json["conferenceData"])
    }

    func testMultiEventFixtureUsesKindDefaults() throws {
        let name = "create_events.multi.json"
        let args = try Fixtures.args(CreateEventsArgs.self, from: name)
        XCTAssertEqual(args.events.count, 2)
        let meeting = try mapper.event(from: args.events[0], seed: "m|0", utterance: "u")
        let bills = try mapper.event(from: args.events[1], seed: "m|1", utterance: "u")

        XCTAssertNotEqual(meeting.body.id, bills.body.id)
        XCTAssertEqual(meeting.body.start?.dateTime, "2026-10-15T13:00:00")
        XCTAssertEqual(meeting.body.end?.dateTime, "2026-10-15T14:00:00") // 60 min default for events
        XCTAssertFalse(meeting.wantsConference)
        XCTAssertNil(meeting.body.conferenceData)

        XCTAssertEqual(bills.body.start?.dateTime, "2026-10-16T09:00:00")
        XCTAssertEqual(bills.body.end?.dateTime, "2026-10-16T09:30:00")
        XCTAssertEqual(bills.body.colorId, "5")
        XCTAssertEqual(bills.body.reminders?.overrides?.map(\.minutes), [60])
        XCTAssertEqual(bills.body.extendedProperties?.private?["ssKind"], "task")
    }

    func testTaskWithoutEndDefaultsToThirtyMinutes() throws {
        let body = try mapper.event(from: draft(#"{"title": "Reply to Ann", "start": "2026-10-14T09:00", "kind": "task"}"#),
                                    seed: "t", utterance: "u").body
        XCTAssertEqual(body.end?.dateTime, "2026-10-14T09:30:00")
    }

    func testAttendeesKeepOnlyEmailAddresses() throws {
        let body = try mapper.event(from: draft("""
        {"title": "Sync", "start": "2026-10-14T09:00", "attendees": ["joe@example.com", "not an email", "Bob", "a b@c.d"]}
        """), seed: "a", utterance: "u").body
        XCTAssertEqual(body.attendees?.map(\.email), ["joe@example.com"])
    }

    func testInvalidStartThrows() throws {
        let bad = try draft(#"{"title": "X", "start": "2026-10-14T99:00"}"#)
        XCTAssertThrowsError(try mapper.event(from: bad, seed: "x", utterance: "u")) { error in
            guard case .invalidDate? = error as? MappingError else { return XCTFail("unexpected \(error)") }
        }
    }

    // MARK: All-day

    func testAllDayEndIsExclusiveNextDay() throws {
        let body = try mapper.event(from: draft(#"{"title": "Conference", "start": "2026-10-20", "all_day": true}"#),
                                    seed: "d", utterance: "u").body
        XCTAssertEqual(body.start?.date, "2026-10-20")
        XCTAssertEqual(body.end?.date, "2026-10-21")
        XCTAssertNil(body.start?.dateTime)
        XCTAssertNil(body.start?.timeZone)
        XCTAssertEqual(body.reminders?.overrides?.map(\.minutes), CalendarEventMapper.allDayReminder)
        XCTAssertNil(try TestJSON.object(encoding: body)["recurrence"])
    }

    func testMultiDayAllDayDraftEndIsInclusive() throws {
        // A date-only start is all-day even without all_day.
        let body = try mapper.event(from: draft(#"{"title": "Trip", "start": "2026-10-20", "end": "2026-10-22"}"#),
                                    seed: "d", utterance: "u").body
        XCTAssertEqual(body.start?.date, "2026-10-20")
        XCTAssertEqual(body.end?.date, "2026-10-23")
    }

    func testAllDayEndBeforeStartIsClampedToOneDay() throws {
        let body = try mapper.event(from: draft(#"{"title": "Oops", "start": "2026-10-20", "end": "2026-10-18"}"#),
                                    seed: "d", utterance: "u").body
        XCTAssertEqual(body.end?.date, "2026-10-21")
    }

    func testAllDayAcrossAutumnDSTChange() throws {
        let body = try mapper.event(from: draft(#"{"title": "Weekend", "start": "2026-10-24", "end": "2026-10-25"}"#),
                                    seed: "d", utterance: "u").body
        XCTAssertEqual(body.start?.date, "2026-10-24")
        XCTAssertEqual(body.end?.date, "2026-10-26")
    }

    func testRecurringAllDayEventCarriesTimeZone() throws {
        let body = try mapper.event(from: draft("""
        {"title": "Bin day", "start": "2026-10-15", "recurrence": {"frequency": "WEEKLY", "by_weekday": ["TH"]}}
        """), seed: "bin", utterance: "u").body
        XCTAssertEqual(body.start?.date, "2026-10-15")
        XCTAssertEqual(body.start?.timeZone, "Europe/London")
        XCTAssertEqual(body.end?.timeZone, "Europe/London")
        XCTAssertEqual(body.recurrence, ["RRULE:FREQ=WEEKLY;BYDAY=TH"])
    }

    // MARK: Timed edge cases

    func testOvernightEndRollsToNextDay() throws {
        let body = try mapper.event(from: draft(#"{"title": "Night shift", "start": "2026-10-14T22:00", "end": "2026-10-14T01:00"}"#),
                                    seed: "n", utterance: "u").body
        XCTAssertEqual(body.start?.dateTime, "2026-10-14T22:00:00")
        XCTAssertEqual(body.end?.dateTime, "2026-10-15T01:00:00")
    }

    func testWeeklyRecurrenceIsAlignedToFirstMatchingWeekday() throws {
        // 2026-10-13 is a Tuesday; RFC 5545 would otherwise count it as an extra first instance.
        let mapped = try mapper.event(from: draft("""
        {"title": "Gym", "start": "2026-10-13T07:00", "duration_minutes": 45,
         "recurrence": {"frequency": "weekly", "by_weekday": ["FR", "MO", "WE"], "until": "2026-11-30"}}
        """), seed: "g", utterance: "u")
        XCTAssertEqual(mapped.body.start?.dateTime, "2026-10-14T07:00:00")
        XCTAssertEqual(mapped.body.end?.dateTime, "2026-10-14T07:45:00")
        XCTAssertEqual(mapped.body.start?.timeZone, "Europe/London")
        XCTAssertEqual(mapped.body.recurrence, ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;UNTIL=20261130T235959Z"])
    }

    func testWeeklyAlignmentKeepsWallClockAcrossDST() throws {
        // Saturday in BST → Monday in GMT; the session must stay at 07:00 local.
        let body = try mapper.event(from: draft("""
        {"title": "Swim", "start": "2026-10-24T07:00", "recurrence": {"frequency": "WEEKLY", "by_weekday": ["MO"]}}
        """), seed: "w", utterance: "u").body
        XCTAssertEqual(body.start?.dateTime, "2026-10-26T07:00:00")
        XCTAssertEqual(body.end?.dateTime, "2026-10-26T08:00:00")
    }

    func testWeeklyStartOnMatchingDayIsNotMoved() throws {
        let body = try mapper.event(from: draft("""
        {"title": "Run", "start": "2026-10-14T06:30", "recurrence": {"frequency": "WEEKLY", "by_weekday": ["WE"]}}
        """), seed: "r", utterance: "u").body
        XCTAssertEqual(body.start?.dateTime, "2026-10-14T06:30:00")
    }

    // MARK: create_long_term_plan

    private struct SeriesReference {
        let id: String
        let summary: String
        let start: String
        let end: String
        let rule: String
    }

    /// Output of `python3 -I scripts/validate_schema.py --print-payloads` (plan id "demoplan", so ids match too).
    private let musclePlanReference: [SeriesReference] = [
        .init(id: "ssguk2q4a7um9cmol1tbfm0brns0", summary: "Muscle 6M · Full body A",
              start: "2026-10-15T18:30:00", end: "2026-10-15T19:30:00",
              rule: "RRULE:FREQ=WEEKLY;BYDAY=MO,TH;UNTIL=20261130T235959Z"),
        .init(id: "ss0hufnu25tsnsq2oijnqo313edg", summary: "Muscle 6M · Full body B",
              start: "2026-10-16T18:30:00", end: "2026-10-16T19:30:00",
              rule: "RRULE:FREQ=WEEKLY;BYDAY=TU,FR;UNTIL=20261130T235959Z"),
        .init(id: "ss916dtu207i0dmb1nkopmqgrln0", summary: "Muscle 6M · Upper",
              start: "2026-12-03T18:30:00", end: "2026-12-03T19:30:00",
              rule: "RRULE:FREQ=WEEKLY;BYDAY=MO,TH;UNTIL=20270228T235959Z"),
        .init(id: "sseh0p31681qet9vs232qr0k3iog", summary: "Muscle 6M · Lower",
              start: "2026-12-01T18:30:00", end: "2026-12-01T19:30:00",
              rule: "RRULE:FREQ=WEEKLY;BYDAY=TU,FR;UNTIL=20270228T235959Z"),
        .init(id: "ssav3idcg30pscidk5ecm603cuhg", summary: "Muscle 6M · Strength upper",
              start: "2027-03-01T18:30:00", end: "2027-03-01T19:40:00",
              rule: "RRULE:FREQ=WEEKLY;BYDAY=MO,TH;UNTIL=20270413T225959Z"),
        .init(id: "ss6t3atbopbt0f8711qk3ivcg3cg", summary: "Muscle 6M · Strength lower",
              start: "2027-03-02T18:30:00", end: "2027-03-02T19:40:00",
              rule: "RRULE:FREQ=WEEKLY;BYDAY=TU,FR;UNTIL=20270413T225959Z")
    ]

    func testMusclePlanMatchesPythonReference() throws {
        let name = "create_long_term_plan.muscle.json"
        let plan = try Fixtures.args(LongTermPlanArgs.self, from: name)
        let mapped = try mapper.events(fromPlan: plan, planID: "demoplan", utterance: Fixtures.utterance(name))

        XCTAssertEqual(mapped.count, 12)
        let series = mapped.filter { $0.body.recurrence != nil }
        let milestones = mapped.filter { $0.body.recurrence == nil }
        XCTAssertEqual(series.count, 6)
        XCTAssertEqual(milestones.count, 6)

        XCTAssertEqual(series.count, musclePlanReference.count)
        for (event, reference) in zip(series, musclePlanReference) {
            let body = event.body
            XCTAssertEqual(body.id, reference.id)
            XCTAssertEqual(body.summary, reference.summary)
            XCTAssertEqual(body.start?.dateTime, reference.start, reference.summary)
            XCTAssertEqual(body.end?.dateTime, reference.end, reference.summary)
            XCTAssertEqual(body.start?.timeZone, "Europe/London")
            XCTAssertEqual(body.end?.timeZone, "Europe/London")
            XCTAssertEqual(body.recurrence, [reference.rule], reference.summary)
            XCTAssertEqual(body.colorId, "10")
            XCTAssertEqual(body.reminders?.useDefault, false)
            XCTAssertEqual(body.reminders?.overrides?.map(\.minutes), [30])
            XCTAssertEqual(body.extendedProperties?.private?["ssKind"], "routine")
            XCTAssertEqual(body.extendedProperties?.private?["ssPlanId"], "demoplan")
            XCTAssertFalse(event.wantsConference)
        }
        let firstDescription = try XCTUnwrap(series.first?.body.description)
        XCTAssertTrue(firstDescription.hasPrefix(CalendarEventMapper.provenancePrefix))
        XCTAssertTrue(firstDescription.contains("🎯 Gain visible muscle mass"))
        XCTAssertTrue(firstDescription.contains("Phase 1: Foundation — Technique"))
        XCTAssertTrue(firstDescription.contains("Squat 3x10"))

        let milestoneDays: [String?] = ["2026-11-14", "2026-12-14", "2027-01-14", "2027-02-14", "2027-03-14", "2027-04-13"]
        let milestoneEnds: [String?] = ["2026-11-15", "2026-12-15", "2027-01-15", "2027-02-15", "2027-03-15", "2027-04-14"]
        XCTAssertEqual(milestones.map { $0.body.start?.date }, milestoneDays)
        XCTAssertEqual(milestones.map { $0.body.end?.date }, milestoneEnds)
        XCTAssertEqual(milestones.first?.body.id, "ss5hkgrblhs8k8lht0gmho4ludn0")
        for milestone in milestones {
            let body = milestone.body
            XCTAssertNil(body.start?.dateTime)
            XCTAssertEqual(body.reminders?.overrides?.map(\.minutes), [900])
            XCTAssertEqual(body.colorId, "6")
            XCTAssertEqual(body.extendedProperties?.private?["ssKind"], "deadline")
            XCTAssertEqual(body.extendedProperties?.private?["ssPlanId"], "demoplan")
        }
    }

    func testMusclePlanNudge() throws {
        let plan = try Fixtures.args(LongTermPlanArgs.self, from: "create_long_term_plan.muscle.json")
        let nudge = try XCTUnwrap(mapper.nudge(from: plan, planID: "demoplan"))
        XCTAssertEqual(nudge.planID, "demoplan")
        XCTAssertEqual(nudge.hour, 7)
        XCTAssertEqual(nudge.minute, 30)
        XCTAssertEqual(nudge.endsOn, TestClock.utc(2027, 4, 13, 23)) // 00:00 BST the day after end_date
        XCTAssertTrue(nudge.message.hasPrefix("Protein"))
    }

    func testPlanSessionDurationIsClamped() throws {
        let plan = try TestJSON.decode(LongTermPlanArgs.self, json: """
        {"goal": "g", "plan_title": "P", "start_date": "2026-10-14", "end_date": "2026-11-30", "summary_for_user": "s",
         "phases": [{"name": "A", "start_date": "2026-10-14", "end_date": "2026-11-30"}],
         "sessions": [
           {"phase_index": 0, "title": "Short", "weekdays": ["WE"], "start_time": "07:00", "duration_minutes": 5},
           {"phase_index": 0, "title": "Long", "weekdays": ["WE"], "start_time": "07:00", "duration_minutes": 600}
         ]}
        """)
        let mapped = try mapper.events(fromPlan: plan, planID: "p", utterance: "u")
        XCTAssertEqual(mapped.map { $0.body.end?.dateTime }, ["2026-10-14T07:10:00", "2026-10-14T11:00:00"])
    }

    func testPlanWithoutSchedulableSessionsThrows() throws {
        let plan = try TestJSON.decode(LongTermPlanArgs.self, json: """
        {"goal": "g", "plan_title": "P", "start_date": "2026-10-14", "end_date": "2026-10-20", "summary_for_user": "s",
         "phases": [{"name": "A", "start_date": "2026-10-14", "end_date": "2026-10-20"}],
         "sessions": [{"phase_index": 3, "title": "x", "weekdays": ["MO"], "start_time": "07:00", "duration_minutes": 30}],
         "milestones": [{"date": "2026-10-20", "title": "Done"}]}
        """)
        XCTAssertThrowsError(try mapper.events(fromPlan: plan, planID: "p", utterance: "u")) { error in
            guard case .emptyPlan? = error as? MappingError else { return XCTFail("unexpected \(error)") }
        }
    }

    // MARK: modify_event

    private var pushedMeeting: ScheduleEvent {
        TestEvents.make(id: "ss0k3p", title: "Online meeting with Joe",
                        start: TestClock.local(2026, 10, 13, 15, 30), end: TestClock.local(2026, 10, 13, 16, 30))
    }

    func testPatchFromFixtureOnlyMovesTime() throws {
        let args = try Fixtures.args(ModifyEventArgs.self, from: "modify_event.push.json")
        let patch = mapper.patch(from: args.changes, existing: pushedMeeting)
        XCTAssertEqual(patch.start?.dateTime, "2026-10-13T16:00:00")
        XCTAssertEqual(patch.start?.timeZone, "Europe/London")
        XCTAssertEqual(patch.end?.dateTime, "2026-10-13T17:00:00") // keeps the existing 1 h duration
        XCTAssertEqual(try Set(TestJSON.object(encoding: patch).keys), ["start", "end"])
    }

    func testPatchTitleOnly() throws {
        let changes = try TestJSON.decode(EventChangesDraft.self, json: #"{"title": "Renamed"}"#)
        let patch = mapper.patch(from: changes, existing: pushedMeeting)
        XCTAssertEqual(patch.summary, "Renamed")
        XCTAssertEqual(try Set(TestJSON.object(encoding: patch).keys), ["summary"])
    }

    func testPatchBlankTitleChangesNothing() throws {
        let changes = try TestJSON.decode(EventChangesDraft.self, json: #"{"title": "   "}"#)
        XCTAssertEqual(try TestJSON.object(encoding: mapper.patch(from: changes, existing: pushedMeeting)).count, 0)
    }

    func testPatchDurationOnlyMovesEnd() throws {
        let changes = try TestJSON.decode(EventChangesDraft.self, json: #"{"duration_minutes": 90}"#)
        let patch = mapper.patch(from: changes, existing: pushedMeeting)
        XCTAssertEqual(patch.end?.dateTime, "2026-10-13T17:00:00")
        XCTAssertEqual(try Set(TestJSON.object(encoding: patch).keys), ["end"])
    }

    func testPatchRemindersAndNotes() throws {
        let changes = try TestJSON.decode(EventChangesDraft.self, json: #"{"reminder_minutes": [15, 15, 5], "notes": "Bring slides"}"#)
        let patch = mapper.patch(from: changes, existing: pushedMeeting)
        XCTAssertEqual(patch.reminders?.overrides?.map(\.minutes), [15, 5])
        XCTAssertEqual(patch.description, "Bring slides")
        // Only Smart Schedule's own reminder list among the private properties: PATCH merges that object's keys.
        XCTAssertEqual(patch.extendedProperties?.private, ["ssReminders": "15,5"])
        XCTAssertEqual(try Set(TestJSON.object(encoding: patch).keys), ["reminders", "description", "extendedProperties"])
    }

    func testPatchEndBeforeNewStartIsPushedOut() throws {
        let changes = try TestJSON.decode(EventChangesDraft.self, json: #"{"start": "2026-10-13T16:00", "end": "2026-10-13T15:00"}"#)
        let patch = mapper.patch(from: changes, existing: pushedMeeting)
        XCTAssertEqual(patch.end?.dateTime, "2026-10-13T16:05:00")
    }

    func testSeriesTimePatchKeepsMasterDate() throws {
        let master = try JSONDecoder().decode(GCalEvent.self, from: Data("""
        {"id": "series1", "start": {"dateTime": "2026-10-15T18:30:00+01:00", "timeZone": "Europe/London"},
         "end": {"dateTime": "2026-10-15T19:30:00+01:00", "timeZone": "Europe/London"}}
        """.utf8))
        let patch = try XCTUnwrap(mapper.seriesTimePatch(master: master,
                                                         newStart: TestClock.local(2026, 10, 20, 19, 0),
                                                         duration: 3600))
        XCTAssertEqual(patch.start?.dateTime, "2026-10-15T19:00:00")
        XCTAssertEqual(patch.end?.dateTime, "2026-10-15T20:00:00")
    }

    // MARK: Google → ScheduleEvent

    private func gcal(_ json: String) throws -> GCalEvent {
        try JSONDecoder().decode(GCalEvent.self, from: Data(json.utf8))
    }

    func testScheduleEventFromTimedGoogleEvent() throws {
        let event = try XCTUnwrap(mapper.scheduleEvent(from: gcal("""
        {
          "id": "abc123_20261014T130000Z",
          "status": "confirmed",
          "summary": "Design review",
          "colorId": "10",
          "recurringEventId": "abc123",
          "start": {"dateTime": "2026-10-14T14:00:00+01:00", "timeZone": "Europe/London"},
          "end": {"dateTime": "2026-10-14T15:30:00+01:00", "timeZone": "Europe/London"},
          "hangoutLink": "https://meet.google.com/abc-defg-hij",
          "htmlLink": "https://www.google.com/calendar/event?eid=abc",
          "reminders": {"useDefault": false, "overrides": [{"method": "popup", "minutes": 10}]},
          "extendedProperties": {"private": {"ssPlanId": "plan42", "ssKind": "routine", "ssSource": "smart-schedule"}}
        }
        """)))
        XCTAssertEqual(event.id, "abc123_20261014T130000Z")
        XCTAssertEqual(event.seriesID, "abc123")
        XCTAssertEqual(event.title, "Design review")
        XCTAssertEqual(event.start, TestClock.utc(2026, 10, 14, 13))
        XCTAssertEqual(event.end, TestClock.utc(2026, 10, 14, 14, 30))
        XCTAssertFalse(event.isAllDay)
        XCTAssertEqual(event.kind, .routine)
        XCTAssertEqual(event.colorHex, "#0B8043")
        XCTAssertEqual(event.meetURL, URL(string: "https://meet.google.com/abc-defg-hij"))
        XCTAssertEqual(event.planID, "plan42")
        XCTAssertEqual(event.reminderMinutes, [10])
        XCTAssertEqual(event.htmlLink, URL(string: "https://www.google.com/calendar/event?eid=abc"))
    }

    func testScheduleEventFromUTCWithFractionalSeconds() throws {
        let event = try XCTUnwrap(mapper.scheduleEvent(from: gcal("""
        {"id": "z1", "summary": "Standup",
         "start": {"dateTime": "2026-10-14T08:00:00.000Z"}, "end": {"dateTime": "2026-10-14T08:15:00.000Z"},
         "reminders": {"useDefault": true}}
        """)))
        XCTAssertEqual(event.start, TestClock.utc(2026, 10, 14, 8))
        XCTAssertEqual(event.end, TestClock.utc(2026, 10, 14, 8, 15))
        XCTAssertEqual(event.kind, .event)
        XCTAssertEqual(event.colorHex, GoogleColor.calendarDefault)
        XCTAssertNil(event.meetURL)
        XCTAssertNil(event.planID)
        XCTAssertNil(event.reminderMinutes)
    }

    func testScheduleEventFromWallClockDateTime() throws {
        let event = try XCTUnwrap(mapper.scheduleEvent(from: gcal("""
        {"id": "w1", "summary": "Lunch",
         "start": {"dateTime": "2026-10-14T12:30:00", "timeZone": "Europe/London"},
         "end": {"dateTime": "2026-10-14T13:30:00", "timeZone": "Europe/London"}}
        """)))
        XCTAssertEqual(event.start, TestClock.utc(2026, 10, 14, 11, 30))
    }

    func testScheduleEventUsesVideoEntryPointWhenNoHangoutLink() throws {
        let event = try XCTUnwrap(mapper.scheduleEvent(from: gcal("""
        {"id": "c1", "summary": "Call",
         "start": {"dateTime": "2026-10-14T09:00:00Z"}, "end": {"dateTime": "2026-10-14T09:30:00Z"},
         "conferenceData": {"entryPoints": [{"entryPointType": "phone", "uri": "tel:+44-20-0000-0000"},
                                            {"entryPointType": "video", "uri": "https://meet.google.com/xyz-abcd-efg"}]}}
        """)))
        XCTAssertEqual(event.meetURL, URL(string: "https://meet.google.com/xyz-abcd-efg"))
    }

    func testScheduleEventFromAllDayGoogleEvent() throws {
        let event = try XCTUnwrap(mapper.scheduleEvent(from: gcal("""
        {"id": "d1", "summary": "Project deadline", "start": {"date": "2026-10-20"}, "end": {"date": "2026-10-21"}}
        """)))
        XCTAssertTrue(event.isAllDay)
        XCTAssertEqual(event.start, TestClock.utc(2026, 10, 19, 23))
        XCTAssertEqual(event.end, TestClock.utc(2026, 10, 20, 23))
        XCTAssertEqual(event.kind, .deadline) // inferred from the title
    }

    func testCancelledOrIncompleteGoogleEventsAreDropped() throws {
        XCTAssertNil(mapper.scheduleEvent(from: try gcal("""
        {"id": "x1", "status": "cancelled", "summary": "Gone",
         "start": {"dateTime": "2026-10-14T09:00:00Z"}, "end": {"dateTime": "2026-10-14T10:00:00Z"}}
        """)))
        XCTAssertNil(mapper.scheduleEvent(from: try gcal("""
        {"summary": "No id", "start": {"dateTime": "2026-10-14T09:00:00Z"}, "end": {"dateTime": "2026-10-14T10:00:00Z"}}
        """)))
        XCTAssertNil(mapper.scheduleEvent(from: try gcal(#"{"id": "x2", "status": "cancelled"}"#)))
        XCTAssertNil(mapper.scheduleEvent(from: try gcal(#"{"id": "x3", "start": {"dateTime": "nonsense"}, "end": {}}"#)))
    }

    // MARK: Smart Schedule's own reminders (ssReminders)

    func testCreatedEventsRecordWhetherTheKindsDefaultsApply() throws {
        let plain = try mapper.event(from: draft(#"{"title": "Sync", "start": "2026-10-14T09:00"}"#), seed: "a", utterance: "u").body
        XCTAssertEqual(plain.extendedProperties?.private?["ssReminders"], "default")
        let explicit = try mapper.event(from: draft(#"{"title": "Sync", "start": "2026-10-14T09:00", "reminder_minutes": [10, 60, 10]}"#),
                                        seed: "b", utterance: "u").body
        XCTAssertEqual(explicit.extendedProperties?.private?["ssReminders"], "60,10")
        XCTAssertEqual(explicit.reminders?.overrides?.map(\.minutes), [60, 10])
        let allDay = try mapper.event(from: draft(#"{"title": "Trip", "start": "2026-10-20", "reminder_minutes": [2340]}"#),
                                      seed: "c", utterance: "u").body
        XCTAssertEqual(allDay.extendedProperties?.private?["ssReminders"], "2340")
        XCTAssertEqual(allDay.reminders?.overrides?.map(\.minutes), [2340])

        let plan = try Fixtures.args(LongTermPlanArgs.self, from: "create_long_term_plan.muscle.json")
        let planEvents = try mapper.events(fromPlan: plan, planID: "demoplan", utterance: "u")
        XCTAssertEqual(Set(planEvents.compactMap { $0.body.extendedProperties?.private?["ssReminders"] }), ["default"])
    }

    func testSmartScheduleOnlyWritesNoGooglePopupsButKeepsItsOwnList() throws {
        var policy = ReminderPolicy()
        policy.writesGooglePopups = false
        let quiet = CalendarEventMapper(clock: TestClock.clock, policy: policy)
        let body = try quiet.event(from: draft(#"{"title": "Sync", "start": "2026-10-14T09:00", "reminder_minutes": [45]}"#),
                                   seed: "q", utterance: "u").body
        XCTAssertEqual(body.reminders?.useDefault, false)
        XCTAssertEqual(body.reminders?.overrides?.count, 0)
        XCTAssertEqual(body.extendedProperties?.private?["ssReminders"], "45")

        // Read back from Google: Smart Schedule still reminds 45 minutes before, although Google shows nothing.
        let listed = try gcal(#"""
        {"id": "q1", "summary": "Sync", "start": {"dateTime": "2026-10-14T09:00:00+01:00"}, "end": {"dateTime": "2026-10-14T10:00:00+01:00"},
         "reminders": {"useDefault": false, "overrides": []}, "extendedProperties": {"private": {"ssReminders": "45"}}}
        """#)
        XCTAssertEqual(mapper.scheduleEvent(from: listed)?.reminderMinutes, [45])
    }

    func testReadingReminderMinutes() throws {
        func minutes(_ reminders: String, _ marker: String? = nil) throws -> [Int]? {
            let properties = marker.map { #", "extendedProperties": {"private": {"ssReminders": "\#($0)"}}"# } ?? ""
            let event = try gcal(#"{"id": "r", "start": {"dateTime": "2026-10-14T09:00:00Z"}, "end": {"dateTime": "2026-10-14T10:00:00Z"}"#
                                 + reminders + properties + "}")
            return try XCTUnwrap(mapper.scheduleEvent(from: event)).reminderMinutes
        }
        XCTAssertNil(try minutes(""))                                                    // Google's defaults
        XCTAssertNil(try minutes(#", "reminders": {"useDefault": true}"#))
        XCTAssertEqual(try minutes(#", "reminders": {"useDefault": false}"#), [])         // turned off in Google
        XCTAssertEqual(try minutes(#", "reminders": {"useDefault": false, "overrides": [{"method": "popup", "minutes": 5}]}"#), [5])
        XCTAssertNil(try minutes(#", "reminders": {"useDefault": false, "overrides": []}"#, "default")) // the kind's defaults
        XCTAssertEqual(try minutes(#", "reminders": {"useDefault": true}"#, "60,10"), [60, 10])
        XCTAssertEqual(try minutes(#", "reminders": {"useDefault": false, "overrides": [{"method": "popup", "minutes": 5}]}"#, "x,1"), [5])
    }

    func testDefaultLengthOfEventsAndRoutinesComesFromPreferences() throws {
        let short = CalendarEventMapper(clock: TestClock.clock, policy: ReminderPolicy(), defaultEventMinutes: 30)
        let meeting = try short.event(from: draft(#"{"title": "Sync", "start": "2026-10-14T09:00"}"#), seed: "m", utterance: "u").body
        XCTAssertEqual(meeting.end?.dateTime, "2026-10-14T09:30:00")
        let routine = try short.event(from: draft(#"{"title": "Run", "start": "2026-10-14T07:00", "kind": "routine"}"#),
                                      seed: "r", utterance: "u").body
        XCTAssertEqual(routine.end?.dateTime, "2026-10-14T07:30:00")
        let long = CalendarEventMapper(clock: TestClock.clock, policy: ReminderPolicy(), defaultEventMinutes: 90)
        let task = try long.event(from: draft(#"{"title": "Reply to Ann", "start": "2026-10-14T09:00", "kind": "task"}"#),
                                  seed: "t", utterance: "u").body
        XCTAssertEqual(task.end?.dateTime, "2026-10-14T09:30:00") // tasks and deadlines keep 30 min
    }

    // MARK: Listings of a connected calendar

    func testCalendarListingsAreStampedWithTheirCalendar() throws {
        let school = SampleAccounts.calendar("222", "example@yourmail.com", primary: true, hex: "#7986CB")
        let plain = try XCTUnwrap(mapper.scheduleEvent(from: gcal(#"""
        {"id": "m1", "iCalUID": "m1@google.com", "summary": "Seminar", "organizer": {"email": "prof@university.example.edu"},
         "start": {"dateTime": "2026-10-14T09:00:00Z"}, "end": {"dateTime": "2026-10-14T10:00:00Z"}}
        """#), in: school))
        XCTAssertEqual(plain.calendarRef, school.id)
        XCTAssertEqual(plain.ref, EventRef(accountID: "222", calendarID: "example@yourmail.com", eventID: "m1"))
        XCTAssertEqual(plain.iCalUID, "m1@google.com")
        XCTAssertEqual(plain.isOrganizer, false)
        XCTAssertEqual(plain.usesCalendarColor, true)
        XCTAssertEqual(plain.colorHex, "#7986CB")

        let own = try XCTUnwrap(mapper.scheduleEvent(from: gcal(#"""
        {"id": "g1", "summary": "Gym", "colorId": "10", "organizer": {"email": "example@yourmail.com", "self": true},
         "start": {"dateTime": "2026-10-14T18:00:00Z"}, "end": {"dateTime": "2026-10-14T19:00:00Z"}}
        """#), in: school))
        XCTAssertEqual(own.isOrganizer, true)
        XCTAssertEqual(own.usesCalendarColor, false)
        XCTAssertEqual(own.colorHex, "#0B8043")
        XCTAssertNil(own.iCalUID)

        // The plain overload stays calendar-less (plan previews, demo).
        let unscoped = try XCTUnwrap(mapper.scheduleEvent(from: gcal(#"{"id": "u", "start": {"date": "2026-10-20"}, "end": {"date": "2026-10-21"}}"#)))
        XCTAssertNil(unscoped.calendarRef)
        XCTAssertNil(unscoped.usesCalendarColor)
    }

    func testCalendarListEntries() throws {
        let list = try JSONDecoder().decode(GCalCalendarList.self, from: Data(#"""
        {"items": [
          {"id": "kenny@example.com", "summary": "kenny@example.com", "backgroundColor": "#9fe1e7", "accessRole": "owner",
           "primary": true, "timeZone": "Europe/London"},
          {"id": "gym@group.calendar.google.com", "summary": "Gym", "summaryOverride": "Gym 🏋️", "backgroundColor": "#16a765",
           "accessRole": "owner", "selected": true},
          {"id": "en.uk#holiday@group.v.calendar.google.com", "summary": "Holidays", "accessRole": "reader"},
          {"id": "old@group.calendar.google.com", "summary": "Old", "accessRole": "owner", "deleted": true},
          {"summary": "No id"}
        ]}
        """#.utf8))
        let calendars = (list.items ?? []).compactMap { $0.calendarInfo(accountID: "111", accountEmail: "kenny@example.com") }
        XCTAssertEqual(calendars.map(\.name), ["kenny@example.com", "Gym 🏋️", "Holidays"])
        XCTAssertEqual(calendars.map(\.isVisible), [true, true, false]) // Google's `selected`; the primary always
        XCTAssertEqual(calendars.map(\.googleColorHex), ["#9FE1E7", "#16A765", CalendarInfo.defaultColorHex])
        XCTAssertEqual(calendars.map(\.isWritable), [true, true, false])
        XCTAssertEqual(calendars.first?.timeZone, "Europe/London")
        XCTAssertTrue(calendars.allSatisfy { $0.notificationsEnabled && $0.colorOverrideHex == nil })
        XCTAssertNil(GCalCalendarListEntry.normalizedHex("teal"))
    }

    func testInferKind() {
        XCTAssertEqual(CalendarEventMapper.inferKind("Deadline for Plan 5008"), .deadline)
        XCTAssertEqual(CalendarEventMapper.inferKind("報告截止"), .deadline)
        XCTAssertEqual(CalendarEventMapper.inferKind("Reply to Joe"), .task)
        XCTAssertEqual(CalendarEventMapper.inferKind("Pay bills"), .task)
        XCTAssertEqual(CalendarEventMapper.inferKind("Lunch"), .event)
        XCTAssertEqual(CalendarEventMapper.inferKind(nil), .event)
    }
}
