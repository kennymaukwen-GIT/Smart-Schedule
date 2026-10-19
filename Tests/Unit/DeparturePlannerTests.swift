import XCTest

final class DeparturePlannerTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!

    /// Wall-clock time in `zone`. Only used for times that exist exactly once there.
    private func time(_ zone: TimeZone, _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func wallClock(_ date: Date, in zone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    // MARK: The owner's example

    func testFivePmInTaipeiThirtyMinutesEarlyLeavesAt1558() {
        let start = time(taipei, 2026, 10, 19, 17, 0)
        let plan = DeparturePlanner.plan(start: start, arriveEarlyMinutes: 30, travelMinutes: 22, bufferMinutes: 10,
                                         travelMode: .transit, isEstimate: false)
        XCTAssertEqual(plan.arriveBy, time(taipei, 2026, 10, 19, 16, 30))
        XCTAssertEqual(plan.departAt, time(taipei, 2026, 10, 19, 15, 58))
        XCTAssertEqual(DeparturePlanner.readyReminder(for: plan), time(taipei, 2026, 10, 19, 15, 48))
        XCTAssertEqual(plan.travelMinutes, 22)
        XCTAssertEqual(plan.travelMode, .transit)
        XCTAssertFalse(plan.isEstimate)
    }

    func testTheMarginIsTenMinutesUnlessGiven() {
        let start = time(taipei, 2026, 10, 19, 17, 0)
        let plan = DeparturePlanner.plan(start: start, arriveEarlyMinutes: 30, travelMinutes: 22,
                                         travelMode: .transit, isEstimate: false)
        XCTAssertEqual(DeparturePlanner.defaultBufferMinutes, 10)
        XCTAssertEqual(DeparturePlanner.defaultReadyLeadMinutes, 10)
        XCTAssertEqual(plan.departAt, time(taipei, 2026, 10, 19, 15, 58))
    }

    func testNoMinutesEarlyArrivesAtTheStart() {
        let start = time(taipei, 2026, 10, 19, 17, 0)
        let plan = DeparturePlanner.plan(start: start, arriveEarlyMinutes: 0, travelMinutes: 22, bufferMinutes: 10,
                                         travelMode: .transit, isEstimate: false)
        XCTAssertEqual(plan.arriveBy, start)
        XCTAssertEqual(plan.departAt, time(taipei, 2026, 10, 19, 16, 28))
        XCTAssertEqual(DeparturePlanner.readyReminder(for: plan), time(taipei, 2026, 10, 19, 16, 18))
    }

    func testAShortLeadIsHonoured() {
        let start = time(taipei, 2026, 10, 19, 17, 0)
        let plan = DeparturePlanner.plan(start: start, arriveEarlyMinutes: 0, travelMinutes: 22, bufferMinutes: 10,
                                         travelMode: .transit, isEstimate: false)
        XCTAssertEqual(DeparturePlanner.readyReminder(for: plan, leadMinutes: 5), time(taipei, 2026, 10, 19, 16, 23))
    }

    /// The spec's campsite example: there by 15:00, a 90-minute drive → leave 13:20, get ready 13:10.
    func testCampsiteNinetyMinuteDriveLeavesAt1320() {
        let start = time(taipei, 2026, 10, 24, 15, 0)
        let plan = DeparturePlanner.plan(start: start, arriveEarlyMinutes: 0, travelMinutes: 90, bufferMinutes: 10,
                                         travelMode: .driving, isEstimate: false)
        XCTAssertEqual(plan.departAt, time(taipei, 2026, 10, 24, 13, 20))
        XCTAssertEqual(DeparturePlanner.readyReminder(for: plan), time(taipei, 2026, 10, 24, 13, 10))
    }

    // MARK: Midnight and clock changes

    func testA0020StartLeavesTheEveningBefore() {
        let start = time(taipei, 2026, 10, 20, 0, 20)
        let plan = DeparturePlanner.plan(start: start, arriveEarlyMinutes: 0, travelMinutes: 22, bufferMinutes: 10,
                                         travelMode: .driving, isEstimate: false)
        XCTAssertEqual(plan.departAt, time(taipei, 2026, 10, 19, 23, 48))
        XCTAssertEqual(DeparturePlanner.readyReminder(for: plan), time(taipei, 2026, 10, 19, 23, 38))
        XCTAssertEqual(wallClock(plan.departAt, in: taipei).day, 19)
    }

    /// London's clocks go back at 02:00 BST on 25 Oct 2026, so 01:00–02:00 happens twice. A 01:30 GMT start
    /// (the second 01:30) leaves 62 real minutes earlier, at 00:28 UTC, which reads 01:28 BST: two minutes earlier
    /// on the clock, 62 minutes earlier in fact.
    func testUKClocksGoingBackKeepTheRealGap() {
        let london = TestClock.zone
        let start = TestClock.utc(2026, 10, 25, 1, 30)
        let plan = DeparturePlanner.plan(start: start, arriveEarlyMinutes: 30, travelMinutes: 22, bufferMinutes: 10,
                                         travelMode: .transit, isEstimate: false)
        XCTAssertEqual(start.timeIntervalSince(plan.departAt), 62 * 60)
        XCTAssertEqual(plan.departAt, TestClock.utc(2026, 10, 25, 0, 28))
        XCTAssertTrue(london.isDaylightSavingTime(for: plan.departAt))
        XCTAssertFalse(london.isDaylightSavingTime(for: start))
        let leave = wallClock(plan.departAt, in: london)
        XCTAssertEqual([leave.hour, leave.minute], [1, 28])
        XCTAssertEqual(DeparturePlanner.readyReminder(for: plan), TestClock.utc(2026, 10, 25, 0, 18))
    }

    /// The same day at a normal hour: 09:00 GMT, 30 early, 22 travel → 07:58 and 07:48 on the clock.
    func testUKClockChangeDayAtANormalHour() {
        let start = TestClock.local(2026, 10, 25, 9, 0)
        let plan = DeparturePlanner.plan(start: start, arriveEarlyMinutes: 30, travelMinutes: 22, bufferMinutes: 10,
                                         travelMode: .transit, isEstimate: false)
        XCTAssertEqual(plan.departAt, TestClock.local(2026, 10, 25, 7, 58))
        XCTAssertEqual(DeparturePlanner.readyReminder(for: plan), TestClock.local(2026, 10, 25, 7, 48))
    }

    /// Clocks go forward at 01:00 GMT on 29 Mar 2026: a 02:40 BST start leaves at 00:38 GMT, 62 real minutes earlier.
    func testUKClocksGoingForwardKeepTheRealGap() {
        let start = TestClock.utc(2026, 3, 29, 1, 40)
        let plan = DeparturePlanner.plan(start: start, arriveEarlyMinutes: 30, travelMinutes: 22, bufferMinutes: 10,
                                         travelMode: .transit, isEstimate: false)
        XCTAssertEqual(start.timeIntervalSince(plan.departAt), 62 * 60)
        let leave = wallClock(plan.departAt, in: TestClock.zone)
        XCTAssertEqual([leave.hour, leave.minute], [0, 38])
    }

    // MARK: Out-of-range input

    func testNegativeInputCountsAsZero() {
        let start = time(taipei, 2026, 10, 19, 17, 0)
        let plan = DeparturePlanner.plan(start: start, arriveEarlyMinutes: -30, travelMinutes: -22, bufferMinutes: -10,
                                         travelMode: .walking, isEstimate: false)
        XCTAssertEqual(plan.arriveBy, start)
        XCTAssertEqual(plan.departAt, start)
        XCTAssertEqual(plan.travelMinutes, 0)
        XCTAssertEqual(DeparturePlanner.readyReminder(for: plan, leadMinutes: -5), start)
    }

    func testHugeInputStopsAtTheLimits() {
        let start = time(taipei, 2026, 10, 19, 17, 0)
        let plan = DeparturePlanner.plan(start: start, arriveEarlyMinutes: 10_000, travelMinutes: 100_000,
                                         bufferMinutes: 9_999, travelMode: .driving, isEstimate: true)
        XCTAssertEqual(plan.arriveBy, start.addingTimeInterval(-180 * 60))
        XCTAssertEqual(plan.departAt, start.addingTimeInterval(-(180 + 1_440 + 180) * 60))
        XCTAssertEqual(plan.travelMinutes, 1_440)
        XCTAssertEqual(DeparturePlanner.readyReminder(for: plan, leadMinutes: 9_999),
                       plan.departAt.addingTimeInterval(-180 * 60))
    }

    func testIntExtremesDoNotCrash() {
        let start = time(taipei, 2026, 10, 19, 17, 0)
        let high = DeparturePlanner.plan(start: start, arriveEarlyMinutes: .max, travelMinutes: .max,
                                         bufferMinutes: .max, travelMode: .transit, isEstimate: false)
        XCTAssertEqual(high.departAt, start.addingTimeInterval(-(180 + 1_440 + 180) * 60))
        XCTAssertEqual(DeparturePlanner.readyReminder(for: high, leadMinutes: .max),
                       high.departAt.addingTimeInterval(-180 * 60))
        let low = DeparturePlanner.plan(start: start, arriveEarlyMinutes: .min, travelMinutes: .min,
                                        bufferMinutes: .min, travelMode: .transit, isEstimate: false)
        XCTAssertEqual(low.departAt, start)
        XCTAssertEqual(DeparturePlanner.readyReminder(for: low, leadMinutes: .min), start)
    }

    func testLimitsMatchTheOwnerDecision() {
        XCTAssertEqual(DeparturePlanner.arriveEarlyRange, 0...180)
        XCTAssertEqual(DeparturePlanner.travelMinutesRange, 0...1_440)
    }

    // MARK: What the plan carries

    func testModeAndEstimateAreCarriedThrough() {
        let start = time(taipei, 2026, 10, 19, 17, 0)
        let plan = DeparturePlanner.plan(start: start, arriveEarlyMinutes: 0, travelMinutes: 90, bufferMinutes: 10,
                                         travelMode: .driving, isEstimate: true)
        XCTAssertEqual(plan.travelMode, .driving)
        XCTAssertTrue(plan.isEstimate)
        XCTAssertEqual(plan.travelMinutes, 90)
    }

    // MARK: Google Maps link

    private func queryItems(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testTaipei101IsPercentEncodedAsUTF8() {
        let url = DeparturePlanner.googleMapsURL(destination: "台北101", mode: .transit)
        XCTAssertEqual(url.absoluteString,
                       "https://www.google.com/maps/dir/?api=1&destination=%E5%8F%B0%E5%8C%97101&travelmode=transit")
    }

    func testAnApostropheAndSpacesAreEncoded() {
        let url = DeparturePlanner.googleMapsURL(destination: "St Mary's School", mode: .driving)
        XCTAssertEqual(url.absoluteString,
                       "https://www.google.com/maps/dir/?api=1&destination=St%20Mary%27s%20School&travelmode=driving")
    }

    func testAmpersandAndHashCannotSplitTheLink() {
        let url = DeparturePlanner.googleMapsURL(destination: "Smith & Sons, 12 High St #3", mode: .walking)
        XCTAssertEqual(url.absoluteString,
                       "https://www.google.com/maps/dir/?api=1&destination=Smith%20%26%20Sons%2C%2012%20High%20St%20%233&travelmode=walking")
        XCTAssertNil(url.fragment)
        XCTAssertEqual(queryItems(url), ["api": "1", "destination": "Smith & Sons, 12 High St #3", "travelmode": "walking"])
    }

    func testOtherReservedCharactersAreEncoded() {
        let url = DeparturePlanner.googleMapsURL(destination: "C++ Café, Level 2/3? a=b; x:y @z", mode: .transit)
        XCTAssertEqual(url.absoluteString,
                       "https://www.google.com/maps/dir/?api=1&destination=C%2B%2B%20Caf%C3%A9%2C%20Level%202%2F3%3F%20a%3Db%3B%20x%3Ay%20%40z&travelmode=transit")
    }

    func testEveryPlaceComesBackExactly() {
        for place in ["台北101", "St Mary's School", "Smith & Sons, 12 High St #3", "C++ Café, Level 2/3? a=b; x:y @z",
                      "露營地 😀", "100% Gym"] {
            let url = DeparturePlanner.googleMapsURL(destination: place, mode: .transit)
            XCTAssertEqual(queryItems(url)["destination"], place, place)
        }
    }

    func testEachModeIsGooglesTravelMode() {
        XCTAssertEqual(DeparturePlanner.googleMapsURL(destination: "台北101", mode: .transit).absoluteString.hasSuffix("&travelmode=transit"), true)
        XCTAssertEqual(DeparturePlanner.googleMapsURL(destination: "台北101", mode: .driving).absoluteString.hasSuffix("&travelmode=driving"), true)
        XCTAssertEqual(DeparturePlanner.googleMapsURL(destination: "台北101", mode: .walking).absoluteString.hasSuffix("&travelmode=walking"), true)
    }

    func testOnlyTheDestinationIsSent() {
        let url = DeparturePlanner.googleMapsURL(destination: "台北101", mode: .transit)
        XCTAssertEqual(Set(queryItems(url).keys), ["api", "destination", "travelmode"], "no origin, no coordinates")
        XCTAssertTrue(url.absoluteString.hasPrefix("https://www.google.com/maps/dir/?api=1&destination="))
    }

    func testOnlySurroundingSpaceIsTrimmed() {
        let url = DeparturePlanner.googleMapsURL(destination: "  台北 101 \n", mode: .transit)
        XCTAssertEqual(queryItems(url)["destination"], "台北 101")
    }

    func testTwoLineLocationsBecomeOneLine() {
        let url = DeparturePlanner.googleMapsURL(destination: "台北101\n信義路五段7號", mode: .transit)
        XCTAssertEqual(queryItems(url)["destination"], "台北101, 信義路五段7號")
        XCTAssertFalse(url.absoluteString.contains("%0A"))
        XCTAssertEqual(DeparturePlanner.mapsText("Taipei 101\r\n\r\n  7 Xinyi Rd\tSec. 5  \u{2028}Taipei"),
                       "Taipei 101, 7 Xinyi Rd Sec. 5, Taipei")
    }

    func testEmojiJoinersAreKept() {
        XCTAssertEqual(DeparturePlanner.mapsText("👨‍👩‍👧 Park"), "👨‍👩‍👧 Park")
    }

    func testAnEmptyPlaceGivesAnEmptyDestination() {
        // Callers don't offer directions without a place; this pins what the link would be.
        XCTAssertEqual(DeparturePlanner.googleMapsURL(destination: " \n ", mode: .transit).absoluteString,
                       "https://www.google.com/maps/dir/?api=1&destination=&travelmode=transit")
    }

    /// Google: "URLs are limited to 2,048 characters". 51 characters before the place and 19 after leave 1,978.
    func testALongPlaceIsCutAtGooglesLimit() {
        let fits = String(repeating: "a", count: 1_978)
        let exact = DeparturePlanner.googleMapsURL(destination: fits, mode: .driving)
        XCTAssertEqual(exact.absoluteString.count, DeparturePlanner.googleMapsURLLimit)
        XCTAssertEqual(queryItems(exact)["destination"], fits, "a place that fits is kept whole")

        let cut = DeparturePlanner.googleMapsURL(destination: fits + "b", mode: .driving)
        XCTAssertEqual(queryItems(cut)["destination"], fits)

        // 台 takes 9 characters encoded: 219 of them fit (1,971), the 220th does not.
        let chinese = String(repeating: "台", count: 300)
        let url = DeparturePlanner.googleMapsURL(destination: chinese, mode: .transit)
        XCTAssertLessThanOrEqual(url.absoluteString.count, DeparturePlanner.googleMapsURLLimit)
        XCTAssertEqual(queryItems(url)["destination"], String(repeating: "台", count: 219), "never half a character")
        XCTAssertTrue(url.absoluteString.hasSuffix("&travelmode=transit"))
    }

    func testTravelModeRawValuesMatchGoogleMaps() {
        XCTAssertEqual(TravelMode.allCases.map(\.rawValue), ["transit", "driving", "walking"])
    }
}
