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

    func testClockMinutes() {
        let start = TestClock.local(2026, 10, 20, 16, 0)
        XCTAssertEqual(DepartureTurn.clockMinutes(from: start, to: TestClock.local(2026, 10, 20, 16, 25)), 25)
        XCTAssertEqual(DepartureTurn.clockMinutes(from: start.addingTimeInterval(59), to: start.addingTimeInterval(60)), 1)
        XCTAssertEqual(DepartureTurn.clockMinutes(from: start, to: start.addingTimeInterval(59)), 0)
        XCTAssertEqual(DepartureTurn.clockMinutes(from: start, to: start.addingTimeInterval(-600)), 0, "never negative")
    }
}
