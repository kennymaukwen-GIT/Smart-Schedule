import XCTest

/// The rules of one departure plan (Shared/Departure/DepartureTurn.swift). The owner's rule (2026-10-20): be there by
/// the start minus the minutes early, ask Google how long the trip takes to arrive then, and that gives when to leave.
final class DepartureTurnTests: XCTestCase {
    private let clock = TestClock.clock

    private func route(departAt: Date, arriveAt: Date, late: Bool = false, estimate: Bool = false,
                       mode: RouteMode = .transit) -> DepartureRoute {
        DepartureRoute(mode: mode, departAt: departAt, arriveAt: arriveAt, late: late, estimate: estimate, plan: nil,
                       plansLeft: 1, summary: RouteSummary(warnings: [], segments: []))
    }

    // MARK: What the plan is for

    func testAnEventFromTheCalendarPassesOnlyItsId() {
        let args = PlanDepartureArgs(destination: "台北 101", arriveAtLocal: "2026-10-20T17:00", eventId: " ss101 ")
        XCTAssertEqual(DepartureTurn.target(args, newEventStarts: [], clock: clock), .existingEvent(id: "ss101"))
    }

    func testANewEventIsTheOneStartingAtTheArrivalTime() {
        let args = PlanDepartureArgs(destination: "台北 101", arriveAtLocal: "2026-10-20T17:00", createEvent: true)
        let starts: [Date?] = [TestClock.local(2026, 10, 20, 9), nil, TestClock.local(2026, 10, 20, 17)]
        XCTAssertEqual(DepartureTurn.target(args, newEventStarts: starts, clock: clock), .newEvent(index: 2))
    }

    func testOnlyCreateEventTiesThePlanToANewEvent() {
        let start = TestClock.local(2026, 10, 20, 17)
        for flag in [nil, false] as [Bool?] {
            let args = PlanDepartureArgs(destination: "台北車站", arriveAtLocal: "2026-10-20T17:00", createEvent: flag)
            XCTAssertEqual(DepartureTurn.target(args, newEventStarts: [start], clock: clock),
                           .arriveBy(destination: "台北車站", at: start), "\(String(describing: flag))")
        }
        let both = PlanDepartureArgs(arriveAtLocal: "2026-10-20T17:00", eventId: "ss101", createEvent: true)
        XCTAssertEqual(DepartureTurn.target(both, newEventStarts: [start], clock: clock), .existingEvent(id: "ss101"),
                       "an event from the calendar wins")
    }

    func testWithoutAMatchingNewEventItIsAnArrivalWithNoEvent() {
        let args = PlanDepartureArgs(destination: "台北 101", arriveAtLocal: "2026-10-20T17:00", createEvent: true)
        XCTAssertEqual(DepartureTurn.target(args, newEventStarts: [TestClock.local(2026, 10, 20, 18)], clock: clock),
                       .arriveBy(destination: "台北 101", at: TestClock.local(2026, 10, 20, 17)))
    }

    func testArrivalWithoutAnEventAndHowLong() {
        XCTAssertEqual(DepartureTurn.target(PlanDepartureArgs(destination: " 台北車站 ", arriveAtLocal: "2026-10-21T08:00"),
                                            newEventStarts: [], clock: clock),
                       .arriveBy(destination: "台北車站", at: TestClock.local(2026, 10, 21, 8)))
        XCTAssertEqual(DepartureTurn.target(PlanDepartureArgs(destination: "台北 101"), newEventStarts: [], clock: clock),
                       .howLong(destination: "台北 101"))
    }

    func testNothingToPlanWithoutAPlaceOrAnEvent() {
        XCTAssertEqual(DepartureTurn.target(PlanDepartureArgs(), newEventStarts: [], clock: clock), .none)
        XCTAssertEqual(DepartureTurn.target(PlanDepartureArgs(destination: "  ", eventId: ""), newEventStarts: [],
                                            clock: clock), .none)
        XCTAssertEqual(DepartureTurn.target(PlanDepartureArgs(arriveAtLocal: "2026-10-20T17:00"), newEventStarts: [],
                                            clock: clock), .none)
    }

    // MARK: When to be there

    func testBeThereTheMinutesEarlyBeforeTheStart() {
        let start = TestClock.local(2026, 10, 20, 17, 0)
        XCTAssertEqual(DepartureTurn.arrival(start: start, arriveEarlyMinutes: 30, now: TestClock.local(2026, 10, 20, 16, 0)),
                       .by(TestClock.local(2026, 10, 20, 16, 30)))
        XCTAssertEqual(DepartureTurn.arrival(start: start, arriveEarlyMinutes: 999, now: TestClock.local(2026, 10, 20, 9, 0)),
                       .by(TestClock.local(2026, 10, 20, 14, 0)), "at most 180 minutes early")
        XCTAssertEqual(DepartureTurn.arrival(start: start, arriveEarlyMinutes: -5, now: TestClock.local(2026, 10, 20, 9, 0)),
                       .by(start))
    }

    /// Owner decision 2026-10-21: a time already passed can't be planned; nothing is sent.
    func testATimeThatHasPassedIsNotPlanned() {
        let start = TestClock.local(2026, 10, 20, 17, 0)
        XCTAssertEqual(DepartureTurn.arrival(start: start, arriveEarlyMinutes: 30, now: TestClock.local(2026, 10, 20, 16, 30)), .passed)
        XCTAssertEqual(DepartureTurn.arrival(start: start, arriveEarlyMinutes: 0, now: TestClock.local(2026, 10, 20, 17, 5)), .passed)
        XCTAssertNil(DepartureTurn.Arrival.passed.target)
        XCTAssertNil(DepartureTurn.Arrival.passed.arriveBy)
    }

    func testLessThanTwoMinutesAwayPlansLeavingNow() {
        let start = TestClock.local(2026, 10, 20, 17, 0)
        let target = TestClock.local(2026, 10, 20, 16, 30)
        let soon = DepartureTurn.arrival(start: start, arriveEarlyMinutes: 30, now: target.addingTimeInterval(-119))
        XCTAssertEqual(soon, .leaveNow(target: target))
        XCTAssertEqual(soon.target, target)
        XCTAssertNil(soon.arriveBy, "no arrival is sent: the server refuses one in the past")
        let later = DepartureTurn.arrival(start: start, arriveEarlyMinutes: 30, now: target.addingTimeInterval(-120))
        XCTAssertEqual(later, .by(target))
        XCTAssertEqual(later.arriveBy, target)
    }

    func testTheMinutesEarlyAreTheUsersElseTheEventsElseTen() {
        XCTAssertEqual(DepartureTurn.arriveEarlyMinutes(said: 30, kept: 15), 30)
        XCTAssertEqual(DepartureTurn.arriveEarlyMinutes(said: nil, kept: 15), 15)
        XCTAssertEqual(DepartureTurn.arriveEarlyMinutes(said: nil, kept: nil), 10)
        XCTAssertEqual(DepartureTurn.arriveEarlyMinutes(said: 0, kept: 15), 0, "said 0 means on time")
        XCTAssertEqual(DepartureTurn.arriveEarlyMinutes(said: 999, kept: nil), 180)
        XCTAssertEqual(DepartureTurn.arriveEarlyMinutes(said: -5, kept: nil), 0)
    }

    // MARK: How the user travels

    func testTheWayOfTravelling() {
        XCTAssertEqual(DepartureTurn.mode(said: .walking, kept: .driving), .init(mode: .walking, saidByUser: true))
        XCTAssertEqual(DepartureTurn.mode(said: nil, kept: .scooter), .init(mode: .scooter, saidByUser: true))
        XCTAssertEqual(DepartureTurn.mode(said: nil, kept: nil), .init(mode: .transit, saidByUser: false))
        XCTAssertEqual(DepartureTurn.mode(said: .transit, kept: nil), .init(mode: .transit, saidByUser: true))
    }

    /// An event keeps public transport whether the user said it or the app chose it, so planning it again may still
    /// fall back to driving.
    func testPublicTransportAnEventKeepsMayStillFallBack() {
        let choice = DepartureTurn.mode(said: nil, kept: .transit)
        XCTAssertEqual(choice, .init(mode: .transit, saidByUser: false))
        XCTAssertEqual(DepartureTurn.fallback(after: choice), .driving)
    }

    func testOnlyThePublicTransportTheAppChoseFallsBackToDriving() {
        XCTAssertEqual(DepartureTurn.fallback(after: .init(mode: .transit, saidByUser: false)), .driving)
        XCTAssertNil(DepartureTurn.fallback(after: .init(mode: .transit, saidByUser: true)), "never swap the user's mode")
        XCTAssertNil(DepartureTurn.fallback(after: .init(mode: .scooter, saidByUser: true)))
    }

    // MARK: Where from

    func testTheStartingPoint() {
        XCTAssertEqual(DepartureTurn.start(startingPoint: " 台北車站 ", availability: .on), .typed("台北車站"))
        XCTAssertEqual(DepartureTurn.start(startingPoint: nil, availability: .on), .currentLocation)
        XCTAssertEqual(DepartureTurn.start(startingPoint: "  ", availability: .on), .currentLocation)
        XCTAssertEqual(DepartureTurn.start(startingPoint: nil, availability: .typedStartOnly), .needsTypedStart,
                       "the Debug switch never uses the current location")
        XCTAssertEqual(DepartureTurn.start(startingPoint: "台北車站", availability: .typedStartOnly), .typed("台北車站"))
    }

    // MARK: The request

    func testTheRequest() {
        let now = TestClock.local(2026, 10, 20, 15, 0)
        let request = DepartureTurn.request(mode: .scooter, origin: .typed("台北車站"), destination: "台北 101",
                                            arrival: .by(TestClock.local(2026, 10, 20, 16, 50)), now: now,
                                            timeZone: TimeZone(identifier: "Asia/Taipei")!, appLanguage: "zh-Hant",
                                            isoRegion: "TW", debugBuild: true)
        XCTAssertEqual(request.mode, .twoWheeler)
        XCTAssertEqual(request.origin, .typed("台北車站"))
        XCTAssertEqual(request.destination, "台北 101")
        XCTAssertEqual(request.arriveBy, TestClock.local(2026, 10, 20, 16, 50))
        XCTAssertNil(request.plan)
        XCTAssertEqual(request.utcOffsetMinutes, 480)
        XCTAssertEqual(request.language, "zh-TW")
        XCTAssertEqual(request.region, "tw")
        XCTAssertTrue(request.debugBuild)

        let leaveNow = DepartureTurn.request(mode: .transit, origin: .current(GeoPoint(latitude: 51.5, longitude: -0.12)),
                                             destination: "Hyde Park", arrival: .leaveNow(target: now), now: now,
                                             timeZone: TestClock.zone, appLanguage: "en", isoRegion: "GB", debugBuild: false)
        XCTAssertNil(leaveNow.arriveBy)
        XCTAssertEqual(leaveNow.region, "uk")
        XCTAssertEqual(leaveNow.language, "en")
        XCTAssertFalse(leaveNow.debugBuild)
    }

    // MARK: What Google's answer means

    func testOnTimeGivesTheTimeToLeave() {
        let now = TestClock.local(2026, 10, 20, 15, 0)
        let target = TestClock.local(2026, 10, 20, 16, 30)
        let answer = route(departAt: TestClock.local(2026, 10, 20, 16, 8), arriveAt: TestClock.local(2026, 10, 20, 16, 29))
        XCTAssertEqual(DepartureTurn.outcome(answer, target: target, now: now),
                       .leave(at: TestClock.local(2026, 10, 20, 16, 8), arriveAt: TestClock.local(2026, 10, 20, 16, 29),
                              estimate: false))
        let roundedUp = route(departAt: TestClock.local(2026, 10, 20, 16, 8), arriveAt: target.addingTimeInterval(60))
        XCTAssertEqual(DepartureTurn.outcome(roundedUp, target: target, now: now),
                       .leave(at: TestClock.local(2026, 10, 20, 16, 8), arriveAt: target.addingTimeInterval(60),
                              estimate: false), "a minute's rounding is still on time")
        let estimate = route(departAt: TestClock.local(2026, 10, 20, 16, 0), arriveAt: target, estimate: true)
        XCTAssertEqual(DepartureTurn.outcome(estimate, target: target, now: now),
                       .leave(at: TestClock.local(2026, 10, 20, 16, 0), arriveAt: target, estimate: true))
    }

    /// Owner decision 2026-10-21 (B): when even leaving now is late, say leave now and how late.
    func testLateSaysHowManyMinutes() {
        let now = TestClock.local(2026, 10, 20, 16, 20)
        let target = TestClock.local(2026, 10, 20, 16, 30)
        XCTAssertEqual(DepartureTurn.outcome(route(departAt: now, arriveAt: TestClock.local(2026, 10, 20, 16, 42)),
                                             target: target, now: now),
                       .late(arriveAt: TestClock.local(2026, 10, 20, 16, 42), minutes: 12))
        XCTAssertEqual(DepartureTurn.outcome(route(departAt: now, arriveAt: target.addingTimeInterval(30), late: true),
                                             target: target, now: now),
                       .late(arriveAt: target.addingTimeInterval(30), minutes: 1), "the server's late flag counts")
        XCTAssertEqual(DepartureTurn.outcome(route(departAt: now, arriveAt: target.addingTimeInterval(-60), late: true),
                                             target: target, now: now),
                       .late(arriveAt: target.addingTimeInterval(-60), minutes: 1), "never 0 minutes late")
        XCTAssertEqual(DepartureTurn.outcome(route(departAt: now, arriveAt: target.addingTimeInterval(61)),
                                             target: target, now: now),
                       .late(arriveAt: target.addingTimeInterval(61), minutes: 1), "past a minute's rounding is late")
    }

    /// The minutes agree with the clock times the reply shows: 16:41:47 shows as 16:41, 11 minutes after 16:30.
    func testTheMinutesMatchTheTimesShown() {
        let target = TestClock.local(2026, 10, 20, 16, 30)
        let arrive = TestClock.local(2026, 10, 20, 16, 41).addingTimeInterval(47)
        XCTAssertEqual(DepartureTurn.outcome(route(departAt: TestClock.local(2026, 10, 20, 16, 20), arriveAt: arrive),
                                             target: target, now: TestClock.local(2026, 10, 20, 16, 20)),
                       .late(arriveAt: arrive, minutes: 11))
        let now = TestClock.local(2026, 10, 20, 16, 0).addingTimeInterval(10)
        let at = TestClock.local(2026, 10, 20, 16, 25).addingTimeInterval(50)
        XCTAssertEqual(DepartureTurn.outcome(route(departAt: now, arriveAt: at), target: nil, now: now),
                       .trip(minutes: 25, arriveAt: at, estimate: false), "16:00 to 16:25")
    }

    func testATimeToLeaveAlreadyPastBecomesNow() {
        let now = TestClock.local(2026, 10, 20, 16, 10)
        let answer = route(departAt: TestClock.local(2026, 10, 20, 16, 9), arriveAt: TestClock.local(2026, 10, 20, 16, 29))
        XCTAssertEqual(DepartureTurn.outcome(answer, target: TestClock.local(2026, 10, 20, 16, 30), now: now),
                       .leave(at: now, arriveAt: TestClock.local(2026, 10, 20, 16, 29), estimate: false))
    }

    func testHowLongCountsFromNow() {
        let now = TestClock.local(2026, 10, 20, 16, 0)
        let answer = route(departAt: TestClock.local(2026, 10, 20, 16, 4), arriveAt: TestClock.local(2026, 10, 20, 16, 25),
                           estimate: true)
        XCTAssertEqual(DepartureTurn.outcome(answer, target: nil, now: now),
                       .trip(minutes: 25, arriveAt: TestClock.local(2026, 10, 20, 16, 25), estimate: true),
                       "waiting for the next train counts")
    }

    func testOnlyATimeToLeaveStillAheadSetsReminders() {
        let now = TestClock.local(2026, 10, 20, 15, 0)
        let arrive = TestClock.local(2026, 10, 20, 16, 30)
        XCTAssertTrue(DepartureTurn.setsReminders(.leave(at: TestClock.local(2026, 10, 20, 16, 8), arriveAt: arrive,
                                                         estimate: false), now: now))
        XCTAssertFalse(DepartureTurn.setsReminders(.leave(at: now, arriveAt: arrive, estimate: false), now: now))
        XCTAssertFalse(DepartureTurn.setsReminders(.late(arriveAt: arrive, minutes: 5), now: now))
        XCTAssertFalse(DepartureTurn.setsReminders(.trip(minutes: 25, arriveAt: arrive, estimate: false), now: now))
    }

    func testATripOver24HoursIsShownButSetsNoReminders() {
        let now = TestClock.local(2026, 10, 20, 9, 0)
        let leave = TestClock.local(2026, 10, 20, 10, 0)
        let long = DepartureTurn.Outcome.leave(at: leave, arriveAt: leave.addingTimeInterval(24 * 3_600 + 60), estimate: false)
        XCTAssertFalse(DepartureTurn.setsReminders(long, now: now))
        XCTAssertTrue(DepartureTurn.isTooLongForReminders(long))
        let day = DepartureTurn.Outcome.leave(at: leave, arriveAt: leave.addingTimeInterval(24 * 3_600), estimate: false)
        XCTAssertTrue(DepartureTurn.setsReminders(day, now: now))
        XCTAssertFalse(DepartureTurn.isTooLongForReminders(day))
    }

    // MARK: What Gemini gets

    func testGeminiGetsOnlyFixedValues() throws {
        for saved in DepartureTurn.Saved.allCases {
            let result = DepartureTurn.functionResult(saved)
            XCTAssertEqual(Set(result.keys), ["ok", "departure_reminders"])
            XCTAssertEqual(result["ok"] as? Bool, true)
            XCTAssertEqual(result["departure_reminders"] as? String, saved.rawValue)
        }
        XCTAssertEqual(DepartureTurn.Saved.allCases.map(\.rawValue), ["set", "awaiting_user_approval", "not_set"])
    }

    /// The time to be there, and how it stands at a later time (after a first 「使用 Google 地圖規劃出發時間？」).
    func testTheTimeToBeThereSeenAgainLater() {
        let start = TestClock.local(2026, 10, 20, 16, 40)
        let target = DepartureTurn.target(start: start, arriveEarlyMinutes: 10)
        XCTAssertEqual(target, TestClock.local(2026, 10, 20, 16, 30))
        XCTAssertEqual(DepartureTurn.target(start: start, arriveEarlyMinutes: -5), start, "kept within range")
        XCTAssertEqual(DepartureTurn.arrival(by: target, now: TestClock.local(2026, 10, 20, 14, 0)), .by(target))
        XCTAssertEqual(DepartureTurn.arrival(by: target, now: target.addingTimeInterval(-119)), .leaveNow(target: target))
        XCTAssertEqual(DepartureTurn.arrival(by: target, now: target.addingTimeInterval(-120)), .by(target))
        XCTAssertEqual(DepartureTurn.arrival(by: target, now: target), .passed)
        for minutes in [0, 10, 45] {
            let now = TestClock.local(2026, 10, 20, 16, 0)
            XCTAssertEqual(DepartureTurn.arrival(start: start, arriveEarlyMinutes: minutes, now: now),
                           DepartureTurn.arrival(by: DepartureTurn.target(start: start, arriveEarlyMinutes: minutes), now: now))
        }
    }

    /// "Ask me first" revised: a new event takes the departure of the earlier preview with its title or its place, each
    /// earlier one at most once; all-day events and previews without a departure take and give none.
    func testARevisedProposalKeepsDeparturesForTheSameEvents() {
        func draft(_ title: String, _ start: String, place: String? = nil) -> EventDraft {
            EventDraft(title: title, start: start, location: place)
        }
        func preview(_ id: String, _ title: String, place: String?, departure: DepartureSettings?,
                     allDay: Bool = false) -> ScheduleEvent {
            var event = TestEvents.make(id: id, title: title, start: TestClock.local(2026, 10, 20, 16, 40),
                                        end: TestClock.local(2026, 10, 20, 17, 40), allDay: allDay)
            event.location = place
            event.departure = departure
            return event
        }
        let transit = DepartureSettings(arriveEarlyMinutes: 10, travelMode: .transit)
        let scooter = DepartureSettings(arriveEarlyMinutes: 20, travelMode: .scooter)
        let previews = [preview("p0", "Meeting", place: "Taipei 101", departure: transit),
                        preview("p1", "Dinner", place: "Din Tai Fung", departure: nil),
                        preview("p2", "Class", place: "NTU", departure: scooter)]

        let carried = ScheduleAssistant.carriedDepartures([
            draft("meeting", "2026-10-20T17:00", place: "Taipei 101"),     // same title, another time
            draft("Dinner", "2026-10-20T19:00", place: "Din Tai Fung"),    // its preview had none
            draft("Seminar", "2026-10-21T09:00", place: " ntu "),          // same place, new title
            draft("Class", "2026-10-22T09:00", place: "NTU"),              // NTU's departure already taken
            draft("Meeting", "2026-10-23", place: "Taipei 101"),           // all day
        ], from: previews)
        XCTAssertEqual(carried, [0: transit, 2: scooter])
        XCTAssertTrue(ScheduleAssistant.carriedDepartures([draft("Lunch", "2026-10-21T12:30", place: "Borough Market")],
                                                          from: previews).isEmpty)
        XCTAssertTrue(ScheduleAssistant.carriedDepartures([draft("Meeting", "2026-10-20T17:00")],
                                                          from: [preview("p", "Meeting", place: nil, departure: transit,
                                                                         allDay: true)]).isEmpty)
    }

    // MARK: Earlier turns, for a request without the feature

    /// Siri after a chat that planned, or the chat after Not now: the history Gemini gets has no call to, or answer
    /// from, a function the request doesn't declare. Everything else passes byte for byte.
    func testEarlierDepartureCallsLeaveTheHistoryOfARequestWithoutTheFeature() throws {
        let user = GeminiTurn.user("明天 3 點去台北 101 開會")
        let model = GeminiTurn(json: Data(#"""
        {"role":"model","parts":[{"functionCall":{"name":"create_events","args":{}},"thoughtSignature":"sig"},
        {"functionCall":{"name":"plan_departure","args":{"create_event":true}}}]}
        """#.utf8))
        let answers = GeminiTurn.functionResponses([
            .init(name: "create_events", id: nil, responseJSON: Data(#"{"ok":true}"#.utf8)),
            .init(name: "plan_departure", id: nil, responseJSON: Data(#"{"ok":true,"departure_reminders":"set"}"#.utf8)),
        ])
        let onlyDeparture = GeminiTurn(json: Data(#"""
        {"role":"model","parts":[{"functionCall":{"name":"plan_departure","args":{"destination":"台北 101"}}}]}
        """#.utf8))
        let onlyAnswer = GeminiTurn.functionResponses([
            .init(name: "plan_departure", id: "c1", responseJSON: Data(#"{"ok":true,"departure_reminders":"not_set"}"#.utf8)),
        ])
        let other = GeminiTurn(json: Data(#"""
        {"role":"model","parts":[{"functionCall":{"name":"reply_to_user","args":{"message":"plan_departure"}}}]}
        """#.utf8))

        let kept = DepartureTurn.withoutDepartureCalls([user, model, answers, onlyDeparture, onlyAnswer, other])
        XCTAssertEqual(kept.count, 5, "an answer turn left empty is dropped")
        XCTAssertEqual(kept[0].json, user.json)
        XCTAssertEqual(kept[4].json, other.json, "the word in a message is not a call")

        let modelParts = try XCTUnwrap(TestJSON.object(kept[1].json)["parts"] as? [[String: Any]])
        XCTAssertEqual(modelParts.count, 1)
        XCTAssertEqual((modelParts[0]["functionCall"] as? [String: Any])?["name"] as? String, "create_events")
        XCTAssertEqual(modelParts[0]["thoughtSignature"] as? String, "sig", "the other call keeps its signature")
        let answerParts = try XCTUnwrap(TestJSON.object(kept[2].json)["parts"] as? [[String: Any]])
        XCTAssertEqual(answerParts.count, 1)
        XCTAssertEqual((answerParts[0]["functionResponse"] as? [String: Any])?["name"] as? String, "create_events")
        XCTAssertEqual(try TestJSON.object(kept[2].json)["role"] as? String, "user")

        // A model turn left with nothing says "OK.", so the turns still alternate.
        let emptied = try TestJSON.object(kept[3].json)
        XCTAssertEqual(emptied["role"] as? String, "model")
        let emptiedParts = try XCTUnwrap(emptied["parts"] as? [[String: Any]])
        XCTAssertEqual(emptiedParts.count, 1)
        XCTAssertEqual(emptiedParts[0]["text"] as? String, "OK.")

        for turn in kept {
            for part in try XCTUnwrap(TestJSON.object(turn.json)["parts"] as? [[String: Any]]) {
                XCTAssertNotEqual((part["functionCall"] as? [String: Any])?["name"] as? String, "plan_departure")
                XCTAssertNotEqual((part["functionResponse"] as? [String: Any])?["name"] as? String, "plan_departure")
            }
        }
        XCTAssertTrue(DepartureTurn.withoutDepartureCalls([]).isEmpty)
        let untouched = DepartureTurn.withoutDepartureCalls([user, other])
        XCTAssertEqual(untouched.map(\.json), [user.json, other.json])
    }

    // MARK: Who may plan

    /// Only the chat and Quick Capture may plan (owner decision 3A). An assistant without the feature (demo mode, the
    /// offline rules) answers the chat's request as it answers any other.
    func testAnAssistantWithoutTheFeatureAnswersTheChatAsBefore() async throws {
        let assistant = HandleOnlyAssistant()
        let now = TestClock.local(2026, 10, 20, 9, 0)
        let reply = try await assistant.handleFromChat("去台北 101 要多久？", now: now)
        XCTAssertEqual(reply.text, "handled")
        let calls = await assistant.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.utterance, "去台北 101 要多久？")
        XCTAssertNil(calls.first?.focusEventID)
        XCTAssertEqual(calls.first?.now, now)
    }

    func testClockMinutes() {
        let start = TestClock.local(2026, 10, 20, 16, 0)
        XCTAssertEqual(DepartureTurn.clockMinutes(from: start, to: TestClock.local(2026, 10, 20, 16, 25)), 25)
        XCTAssertEqual(DepartureTurn.clockMinutes(from: start.addingTimeInterval(59), to: start.addingTimeInterval(60)), 1)
        XCTAssertEqual(DepartureTurn.clockMinutes(from: start, to: start.addingTimeInterval(59)), 0)
        XCTAssertEqual(DepartureTurn.clockMinutes(from: start, to: start.addingTimeInterval(-600)), 0, "never negative")
    }
}

/// An assistant with only `handle`, as demo mode's and the offline rules' are for the chat.
private actor HandleOnlyAssistant: ScheduleAssisting {
    struct Call: Sendable {
        let utterance: String
        let focusEventID: String?
        let now: Date
    }

    private(set) var calls: [Call] = []

    func handle(_ utterance: String, focusEventID: String?, now: Date) async throws -> ScheduleAssistant.Reply {
        calls.append(Call(utterance: utterance, focusEventID: focusEventID, now: now))
        var reply = ScheduleAssistant.Reply()
        reply.text = "handled"
        return reply
    }

    func confirm(_ pending: ScheduleAssistant.PendingDeletion) async throws -> ScheduleAssistant.Reply { .init() }
    func commitPlan(_ draft: PlanDraft) async throws -> ScheduleAssistant.Reply { .init() }
    func discardPlan(_ draft: PlanDraft) async -> ScheduleAssistant.Reply { .init() }
    func commitPendingEvents(_ batch: PendingEventBatch) async throws -> ScheduleAssistant.Reply { .init() }
    func discardPendingEvents(_ batch: PendingEventBatch) async -> ScheduleAssistant.Reply { .init() }
}
