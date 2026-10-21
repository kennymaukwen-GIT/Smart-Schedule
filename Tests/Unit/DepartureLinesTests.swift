import XCTest

/// What the assistant says about a departure (Shared/Departure/DepartureLines.swift, DepartureReply.swift). These tests
/// read the English keys (Bundle.main is the test runner); LocalizationCatalogTests checks the zh-Hant wording.
final class DepartureLinesTests: XCTestCase {
    private let clock = TestClock.clock
    private let target = TestClock.local(2026, 10, 20, 16, 30)

    // MARK: Answers

    func testTheTimeToLeave() {
        let outcome = DepartureTurn.Outcome.leave(at: TestClock.local(2026, 10, 20, 15, 48),
                                                  arriveAt: TestClock.local(2026, 10, 20, 16, 28), estimate: false)
        XCTAssertEqual(DepartureLines.shown(outcome, place: "Taipei 101", target: target, fellBack: false,
                                            clock: clock),
                       "Based on being at Taipei 101 by 16:30, leave at 15:48.")
    }

    func testAnEstimateAndTheDrivingFallbackAreSaid() {
        let outcome = DepartureTurn.Outcome.leave(at: TestClock.local(2026, 10, 20, 15, 30),
                                                  arriveAt: TestClock.local(2026, 10, 20, 16, 30), estimate: true)
        XCTAssertEqual(DepartureLines.shown(outcome, place: "Taipei 101", target: target, fellBack: true,
                                            clock: clock),
                       "Based on being at Taipei 101 by 16:30, leave at 15:30. This is an estimate. "
                           + "No public transport route was found, so this is by car.")
    }

    /// Owner decision 2026-10-21 (B).
    func testLateSaysLeaveNowAndHowLate() {
        let outcome = DepartureTurn.Outcome.late(arriveAt: TestClock.local(2026, 10, 20, 16, 42), minutes: 12)
        XCTAssertEqual(DepartureLines.shown(outcome, place: "Taipei 101", target: target, fellBack: false,
                                            clock: clock),
                       "Based on being at Taipei 101 by 16:30, leave now: you'll arrive at 16:42, about 12 min late.")
    }

    func testHowLong() {
        let outcome = DepartureTurn.Outcome.trip(minutes: 95, arriveAt: TestClock.local(2026, 10, 20, 17, 35), estimate: false)
        XCTAssertEqual(DepartureLines.shown(outcome, place: "Hyde Park", target: nil, fellBack: false,
                                            clock: clock),
                       "Leaving now for Hyde Park takes about 1 hr 35 min: you'll arrive at 17:35.")
    }

    /// Google's terms allow no storing of its times: what history keeps has only the place and the user's own time.
    func testWhatHistoryKeepsHasNoTimeFromGoogle() {
        let leave = DepartureTurn.Outcome.leave(at: TestClock.local(2026, 10, 20, 15, 48),
                                                arriveAt: TestClock.local(2026, 10, 20, 16, 28), estimate: false)
        let kept = DepartureLines.kept(leave, place: "Taipei 101", target: target, clock: clock)
        XCTAssertEqual(kept, "Planned when to leave for Taipei 101 (be there by 16:30).")
        XCTAssertFalse(kept.contains("15:48"))
        XCTAssertFalse(kept.contains("16:28"))
        let late = DepartureTurn.Outcome.late(arriveAt: TestClock.local(2026, 10, 20, 16, 42), minutes: 12)
        XCTAssertEqual(DepartureLines.kept(late, place: "Taipei 101", target: target, clock: clock), kept)
        let trip = DepartureTurn.Outcome.trip(minutes: 25, arriveAt: TestClock.local(2026, 10, 20, 16, 25), estimate: false)
        XCTAssertEqual(DepartureLines.kept(trip, place: "Taipei 101", target: nil, clock: clock),
                       "Checked the travel time to Taipei 101.")
    }

    func testPlansLeftThisWeek() {
        XCTAssertEqual(DepartureLines.plansLeft(1), "You can plan 1 more this week.")
        XCTAssertEqual(DepartureLines.plansLeft(19), "You can plan 19 more this week.")
        XCTAssertEqual(DepartureLines.plansLeft(0), "That was this week's last plan.")
    }

    // MARK: When there is no answer

    func testEveryServerRefusalHasItsLine() {
        XCTAssertEqual(DepartureLines.reason(.regionUnavailable), .region)
        XCTAssertEqual(DepartureLines.reason(.weeklyLimit(retryAfter: 60)), .weeklyLimit)
        XCTAssertEqual(DepartureLines.reason(.dailyCapacity(retryAfter: nil)), .dailyCapacity)
        XCTAssertEqual(DepartureLines.reason(.userDailyLimit(retryAfter: nil)), .userDailyLimit)
        XCTAssertEqual(DepartureLines.reason(.busy(retryAfter: 5)), .busy)
        for error: DepartureRouteError in [.recheckLimit, .invalidPlan, .unavailable, .notReady, .unverified, .invalidRequest] {
            XCTAssertEqual(DepartureLines.reason(error), .unavailable, "\(error)")
        }
        XCTAssertEqual(DepartureLines.reason(TravelTimeError.noPermission), .noPermission)
        XCTAssertEqual(DepartureLines.reason(TravelTimeError.temporarilyUnavailable), .noLocation)
    }

    func testEveryReasonSaysSomethingDifferent() {
        let reasons: [DepartureLines.Reason] = [
            .passed, .allDay, .noPlace, .destinationNotFound(forEvent: true), .destinationNotFound(forEvent: false),
            .startNotFound, .noRoute(.transit), .noRoute(.scooter), .noPermission, .noLocation, .needsTypedStart, .declined,
            .region,
            .weeklyLimit, .dailyCapacity, .userDailyLimit, .busy, .unavailable,
        ]
        let lines = reasons.map(DepartureLines.failure)
        XCTAssertEqual(Set(lines).count, reasons.count)
        XCTAssertFalse(lines.contains(where: \.isEmpty))
        XCTAssertEqual(DepartureLines.failure(.noRoute(.scooter)), "No route there by scooter.")
        XCTAssertEqual(DepartureLines.failure(.passed), "That time has already passed, so there's no departure to plan.")
        XCTAssertEqual(DepartureLines.failure(.noPlace), "This event has no place yet. Add one to the event first.")
        XCTAssertEqual(DepartureLines.failure(.declined),
                       "OK. Departure planning stays off. You can turn it on in Settings › Assistant.")
    }

    // MARK: Pieces

    func testDurations() {
        XCTAssertEqual(DepartureLines.duration(minutes: 25), "25 min")
        XCTAssertEqual(DepartureLines.duration(minutes: 60), "1 hr")
        XCTAssertEqual(DepartureLines.duration(minutes: 125), "2 hr 5 min")
        XCTAssertEqual(DepartureLines.duration(minutes: -3), "0 min")
    }

    func testEveryWayOfTravellingHasAName() {
        XCTAssertEqual(TravelMode.allCases.map(DepartureLines.modeName),
                       ["by public transport", "by car", "on foot", "by scooter"])
    }

    func testAPlaceInAChineseSentenceIsSpacedNextToLatinLetters() {
        XCTAssertEqual(DepartureLines.inSentence("台北 101", chinese: true), "台北 101 ")
        XCTAssertEqual(DepartureLines.inSentence("Dishoom", chinese: true), " Dishoom ")
        XCTAssertEqual(DepartureLines.inSentence("台中車站", chinese: true), "台中車站")
        XCTAssertEqual(DepartureLines.inSentence("台北 101", chinese: false), "台北 101")
        XCTAssertEqual(DepartureLines.inSentence("", chinese: true), "")
        XCTAssertEqual(DepartureLines.joined("A。", "B。", chinese: true), "A。B。")
        XCTAssertEqual(DepartureLines.joined("A.", "B.", chinese: false), "A. B.")
    }

    func testTheAttributionIsGoogleMapsUnchanged() {
        XCTAssertEqual(DepartureLines.attribution, "Google Maps")
    }

    // MARK: The reply

    func testTheChatShowsGooglesTimeWhileHistoryKeepsTheOtherLine() {
        let reply = DepartureReply(shown: "Based on being at Taipei 101 by 16:30, leave at 15:48.",
                                   kept: "Planned when to leave for Taipei 101 (be there by 16:30).",
                                   destination: "Taipei 101", mode: .transit, planToken: nil)
        let text = "Added: Meeting · Tue, Oct 20 · 17:00–18:00\nPlanned when to leave for Taipei 101 (be there by 16:30)."
        XCTAssertEqual(DepartureReply.displayText(text, departure: reply),
                       "Added: Meeting · Tue, Oct 20 · 17:00–18:00\nBased on being at Taipei 101 by 16:30, leave at 15:48.")
        XCTAssertEqual(DepartureReply.displayText(text, departure: nil), text)
        XCTAssertEqual(DepartureReply.displayText("Something else", departure: reply), "Something else")
    }
}
