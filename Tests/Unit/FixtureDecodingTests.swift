import XCTest

/// Every example call in Tests/fixtures must decode into the typed args the orchestrator uses, with the same
/// snake_case decoding as `GeminiFunctionCall.decode`. scripts/validate_schema.py checks the same files
/// against the JSON schema, so together they pin schema ⇄ Swift types.
final class FixtureDecodingTests: XCTestCase {
    func testEveryFixtureDecodesIntoItsArgsType() throws {
        let names = try Fixtures.allNames()
        XCTAssertGreaterThanOrEqual(names.count, 5)
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

    func testModifyEvent() throws {
        let args = try Fixtures.args(ModifyEventArgs.self, from: "modify_event.push.json")
        XCTAssertEqual(args.eventId, "ss0k3p")
        XCTAssertNil(args.scope)
        XCTAssertEqual(args.changes.start, "2026-10-13T16:00")
        XCTAssertNil(args.changes.end)
        XCTAssertNil(args.changes.title)
    }

    func testQuerySchedule() throws {
        let args = try Fixtures.args(QueryScheduleArgs.self, from: "query_schedule.today.json")
        XCTAssertEqual(args.rangeStart, "2026-10-15")
        XCTAssertNil(args.rangeEnd)
        XCTAssertEqual(args.view, "day")
    }
}
