import XCTest

final class WallClockTests: XCTestCase {
    private let clock = TestClock.clock

    // MARK: Parsing

    func testDateTimeParsesMinutePrecision() {
        // 2026-10-14 is BST (UTC+1).
        XCTAssertEqual(clock.dateTime("2026-10-14T14:00"), TestClock.utc(2026, 10, 14, 13, 0))
    }

    func testDateTimeParsesSeconds() {
        XCTAssertEqual(clock.dateTime("2026-10-14T14:00:30"), TestClock.utc(2026, 10, 14, 13, 0, 30))
    }

    func testDateTimeIgnoresTrailingZoneDesignators() {
        let expected = TestClock.utc(2026, 10, 14, 13, 0)
        for raw in ["2026-10-14T14:00Z",
                    "2026-10-14T14:00:00Z",
                    "2026-10-14T14:00+05:00",
                    "2026-10-14T14:00:00-07:00",
                    " 2026-10-14T14:00 "] {
            XCTAssertEqual(clock.dateTime(raw), expected, raw)
        }
    }

    func testDateTimeRejectsInvalidStrings() {
        for raw in ["",
                    "garbage",
                    "2026-10-14",
                    "2026-10-14T",
                    "2026-13-01T10:00",
                    "2026-10-32T10:00",
                    "2026-10-14T24:00",
                    "2026-10-14T10:60",
                    "2026-10-14T10",
                    "14/10/2026T10:00",
                    "2026-10-14Tab:cd"] {
            XCTAssertNil(clock.dateTime(raw), raw)
        }
    }

    func testDateIsStartOfLocalDay() {
        XCTAssertEqual(clock.date("2026-10-14"), TestClock.utc(2026, 10, 13, 23)) // BST
        XCTAssertEqual(clock.date("2026-11-30"), TestClock.utc(2026, 11, 30))     // GMT
        XCTAssertEqual(clock.date("2026-10-14T18:30"), TestClock.utc(2026, 10, 13, 23))
        XCTAssertNil(clock.date("2026-00-10"))
        XCTAssertNil(clock.date("not a date"))
    }

    func testTimeOfDay() {
        XCTAssertEqual(clock.timeOfDay("07:30")?.hour, 7)
        XCTAssertEqual(clock.timeOfDay("07:30")?.minute, 30)
        XCTAssertEqual(clock.timeOfDay("18:05:59")?.hour, 18)
        XCTAssertEqual(clock.timeOfDay("18:05:59")?.minute, 5)
        XCTAssertNil(clock.timeOfDay("24:00"))
        XCTAssertNil(clock.timeOfDay("07:60"))
        XCTAssertNil(clock.timeOfDay("07"))
        XCTAssertNil(clock.timeOfDay("7am"))
    }

    func testCombineUsesLocalWallClock() throws {
        let day = try XCTUnwrap(clock.date("2026-10-14"))
        XCTAssertEqual(clock.combine(day: day, time: (hour: 18, minute: 30)), TestClock.utc(2026, 10, 14, 17, 30))
    }

    // MARK: Formatting

    func testWallDateTimeStringRoundTrip() throws {
        for raw in ["2026-10-14T14:00:00", "2026-12-31T23:59:59", "2027-03-28T03:15:00", "2026-10-25T00:30:00"] {
            let date = try XCTUnwrap(clock.dateTime(raw), raw)
            XCTAssertEqual(clock.wallDateTimeString(date), raw)
        }
    }

    func testPromptAndDateStrings() {
        XCTAssertEqual(clock.wallDateTimeString(TestClock.utc(2026, 10, 14, 13)), "2026-10-14T14:00:00")
        XCTAssertEqual(clock.promptDateTimeString(TestClock.utc(2026, 10, 14, 13)), "2026-10-14T14:00")
        // 23:30 UTC on the 13th is already the 14th in London.
        XCTAssertEqual(clock.dateString(TestClock.utc(2026, 10, 13, 23, 30)), "2026-10-14")
    }

    func testICSUTCString() {
        XCTAssertEqual(WallClock.icsUTCString(TestClock.utc(2027, 4, 13, 22, 59, 59)), "20270413T225959Z")
        XCTAssertEqual(WallClock.icsUTCString(TestClock.utc(2026, 1, 2, 3, 4, 5)), "20260102T030405Z")
    }

    func testRFC3339FormattingIsUTC() {
        XCTAssertEqual(WallClock.rfc3339(TestClock.utc(2026, 10, 14, 13)), "2026-10-14T13:00:00Z")
    }

    func testParseRFC3339WithoutFractionalSeconds() {
        XCTAssertEqual(WallClock.parseRFC3339("2026-10-14T14:00:00+01:00"), TestClock.utc(2026, 10, 14, 13))
        XCTAssertEqual(WallClock.parseRFC3339("2026-10-14T13:00:00Z"), TestClock.utc(2026, 10, 14, 13))
        XCTAssertEqual(WallClock.parseRFC3339("2026-12-01T18:30:00-08:00"), TestClock.utc(2026, 12, 2, 2, 30))
    }

    func testParseRFC3339WithFractionalSeconds() throws {
        let parsed = try XCTUnwrap(WallClock.parseRFC3339("2026-10-14T13:00:00.250Z"))
        XCTAssertEqual(parsed.timeIntervalSince(TestClock.utc(2026, 10, 14, 13)), 0.25, accuracy: 0.001)
        let offset = try XCTUnwrap(WallClock.parseRFC3339("2026-10-14T14:00:00.000+01:00"))
        XCTAssertEqual(offset.timeIntervalSince(TestClock.utc(2026, 10, 14, 13)), 0, accuracy: 0.001)
    }

    func testParseRFC3339RejectsGarbage() {
        XCTAssertNil(WallClock.parseRFC3339("garbage"))
        XCTAssertNil(WallClock.parseRFC3339("2026-10-14"))
    }

    // MARK: DST (Europe/London)

    func testAutumnBoundary20261025() throws {
        // 02:00 BST falls back to 01:00 GMT, so the local day is 25 hours long.
        let dayStart = try XCTUnwrap(clock.date("2026-10-25"))
        let nextDay = try XCTUnwrap(clock.date("2026-10-26"))
        XCTAssertEqual(dayStart, TestClock.utc(2026, 10, 24, 23))
        XCTAssertEqual(nextDay, TestClock.utc(2026, 10, 26, 0))
        XCTAssertEqual(nextDay.timeIntervalSince(dayStart), 25 * 3600)

        XCTAssertEqual(clock.dateTime("2026-10-25T00:30"), TestClock.utc(2026, 10, 24, 23, 30))
        XCTAssertEqual(clock.dateTime("2026-10-25T02:30"), TestClock.utc(2026, 10, 25, 2, 30))

        // 01:30 happens twice; either occurrence is acceptable, but it must read back as 01:30.
        let ambiguous = try XCTUnwrap(clock.dateTime("2026-10-25T01:30"))
        XCTAssertTrue([TestClock.utc(2026, 10, 25, 0, 30), TestClock.utc(2026, 10, 25, 1, 30)].contains(ambiguous))
        XCTAssertEqual(clock.wallDateTimeString(ambiguous), "2026-10-25T01:30:00")

        // A 07:00 session keeps its wall-clock time on both sides of the change.
        let saturday = try XCTUnwrap(clock.date("2026-10-24"))
        let monday = try XCTUnwrap(clock.date("2026-10-26"))
        XCTAssertEqual(clock.combine(day: saturday, time: (hour: 7, minute: 0)), TestClock.utc(2026, 10, 24, 6))
        XCTAssertEqual(clock.combine(day: monday, time: (hour: 7, minute: 0)), TestClock.utc(2026, 10, 26, 7))
    }

    func testSpringBoundary20270328() throws {
        // 01:00 GMT jumps to 02:00 BST, so the local day is 23 hours long.
        let dayStart = try XCTUnwrap(clock.date("2027-03-28"))
        let nextDay = try XCTUnwrap(clock.date("2027-03-29"))
        XCTAssertEqual(dayStart, TestClock.utc(2027, 3, 28, 0))
        XCTAssertEqual(nextDay, TestClock.utc(2027, 3, 28, 23))
        XCTAssertEqual(nextDay.timeIntervalSince(dayStart), 23 * 3600)

        XCTAssertEqual(clock.dateTime("2027-03-28T00:30"), TestClock.utc(2027, 3, 28, 0, 30))
        XCTAssertEqual(clock.dateTime("2027-03-28T03:00"), TestClock.utc(2027, 3, 28, 2, 0))

        // 01:30 does not exist that day: it must resolve forward into BST (02:00–02:30 local), never fail or go back.
        let skipped = try XCTUnwrap(clock.dateTime("2027-03-28T01:30"))
        XCTAssertGreaterThanOrEqual(skipped, TestClock.utc(2027, 3, 28, 1, 0))
        XCTAssertLessThanOrEqual(skipped, TestClock.utc(2027, 3, 28, 1, 30))
        XCTAssertEqual(clock.calendar.component(.hour, from: skipped), 2)
    }
}
