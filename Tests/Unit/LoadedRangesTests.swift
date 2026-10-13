import XCTest

/// The bookkeeping behind on-demand loading: which ranges are cached, what a request still needs, and what the
/// cache cap may drop. London calendar, so month boundaries and DST follow `WallClock`.
final class LoadedRangesTests: XCTestCase {
    private let calendar = TestClock.clock.calendar

    private func day(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        TestClock.local(year, month, day, hour)
    }

    private func span(_ start: Date, _ end: Date) -> DateInterval {
        DateInterval(start: start, end: end)
    }

    // MARK: Merge

    func testOverlappingAndTouchingRangesMergeAndEmptyOnesAreDropped() {
        let ranges = LoadedRanges([
            span(day(2026, 3, 1), day(2026, 3, 10)),
            span(day(2026, 1, 1), day(2026, 2, 1)),
            span(day(2026, 2, 1), day(2026, 2, 15)),   // touches the January range
            span(day(2026, 3, 5), day(2026, 4, 1)),    // overlaps the March range
            span(day(2026, 5, 1), day(2026, 5, 1))     // empty
        ])
        XCTAssertEqual(ranges.intervals, [span(day(2026, 1, 1), day(2026, 2, 15)),
                                          span(day(2026, 3, 1), day(2026, 4, 1))])

        var grown = ranges
        grown.insert(span(day(2026, 2, 10), day(2026, 3, 2))) // bridges the gap
        XCTAssertEqual(grown.intervals, [span(day(2026, 1, 1), day(2026, 4, 1))])
    }

    // MARK: Missing parts

    func testMissingReturnsOnlyTheUncoveredPartsInOrder() {
        let loaded = LoadedRanges([span(day(2026, 1, 1), day(2026, 2, 1)), span(day(2026, 3, 1), day(2026, 4, 1))])

        XCTAssertEqual(loaded.missing(in: span(day(2025, 12, 15), day(2026, 4, 15))), [
            span(day(2025, 12, 15), day(2026, 1, 1)),
            span(day(2026, 2, 1), day(2026, 3, 1)),
            span(day(2026, 4, 1), day(2026, 4, 15))
        ])
        XCTAssertEqual(loaded.missing(in: span(day(2026, 1, 5), day(2026, 1, 20))), [])
        XCTAssertTrue(loaded.contains(span(day(2026, 3, 1), day(2026, 4, 1))))
        XCTAssertFalse(loaded.contains(span(day(2026, 3, 1), day(2026, 4, 2))))
        XCTAssertEqual(loaded.missing(in: span(day(2026, 5, 1), day(2026, 6, 1))), [span(day(2026, 5, 1), day(2026, 6, 1))])
        XCTAssertEqual(LoadedRanges().missing(in: span(day(2126, 1, 1), day(2126, 2, 1))),
                       [span(day(2126, 1, 1), day(2126, 2, 1))])
        XCTAssertEqual(loaded.missing(in: span(day(2026, 5, 1), day(2026, 5, 1))), [])
    }

    func testRangesInFlightCountAsCoveredUntilRemoved() {
        let cached = LoadedRanges([span(day(2026, 10, 6), day(2027, 2, 10))]) // the rolling window
        var inFlight = LoadedRanges()
        inFlight.insert(span(day(2026, 9, 1), day(2026, 10, 6)))
        inFlight.insert(span(day(2026, 8, 1), day(2026, 9, 1)))
        XCTAssertEqual(inFlight.intervals, [span(day(2026, 8, 1), day(2026, 10, 6))])
        XCTAssertEqual(cached.union(inFlight).missing(in: span(day(2026, 8, 1), day(2026, 12, 1))), [])

        // The August load finished (or failed): only September is still in flight.
        inFlight.remove(span(day(2026, 8, 1), day(2026, 9, 1)))
        XCTAssertEqual(inFlight.intervals, [span(day(2026, 9, 1), day(2026, 10, 6))])
        XCTAssertEqual(cached.union(inFlight).missing(in: span(day(2026, 7, 1), day(2026, 12, 1))),
                       [span(day(2026, 7, 1), day(2026, 9, 1))])

        var split = LoadedRanges([span(day(2026, 1, 1), day(2026, 4, 1))])
        split.remove(span(day(2026, 2, 1), day(2026, 3, 1)))
        XCTAssertEqual(split.intervals, [span(day(2026, 1, 1), day(2026, 2, 1)), span(day(2026, 3, 1), day(2026, 4, 1))])
    }

    // MARK: Requests

    func testRequestCoversWholeMonthsPlusOneEitherSide() {
        // The week of Sun 11 – Sat 17 Oct 2026.
        XCTAssertEqual(LoadedRanges.request(around: span(day(2026, 10, 11), day(2026, 10, 18)), calendar: calendar),
                       span(day(2026, 9, 1), day(2026, 12, 1)))
        // A week across two months.
        XCTAssertEqual(LoadedRanges.request(around: span(day(2026, 9, 27), day(2026, 10, 4)), calendar: calendar),
                       span(day(2026, 8, 1), day(2026, 12, 1)))
        // `end` is exclusive: a range ending at midnight on 1 Nov does not reach into November.
        XCTAssertEqual(LoadedRanges.request(around: span(day(2026, 10, 25), day(2026, 11, 1)), calendar: calendar),
                       span(day(2026, 9, 1), day(2026, 12, 1)))
        // Across a year boundary.
        XCTAssertEqual(LoadedRanges.request(around: span(day(2026, 12, 27), day(2027, 1, 3)), calendar: calendar),
                       span(day(2026, 11, 1), day(2027, 3, 1)))
        // A century away.
        XCTAssertEqual(LoadedRanges.request(around: span(day(2126, 6, 10), day(2126, 6, 11)), calendar: calendar),
                       span(day(2126, 5, 1), day(2126, 8, 1)))
    }

    func testOverlongRequestIsClampedToItsFirstYear() {
        let decade = span(day(2027, 1, 1), day(2037, 1, 1))
        XCTAssertEqual(LoadedRanges.request(around: decade, calendar: calendar),
                       span(day(2026, 12, 1), day(2028, 2, 1)))
    }

    // MARK: Cache cap

    func testKeepZonesWidenEachAnchorByCalendarMonths() {
        let today = span(day(2026, 10, 13), day(2026, 10, 14))
        let screen = span(day(2030, 1, 5), day(2030, 1, 12))
        let zones = LoadedRanges.keepZones(around: [today, screen], months: 12, calendar: calendar)
        XCTAssertEqual(zones.intervals, [span(day(2025, 10, 13), day(2027, 10, 14)),
                                         span(day(2029, 1, 5), day(2031, 1, 12))])
    }

    func testEvictionDropsOnlyFarEventsAndTrimsLoadedRanges() throws {
        let keep = LoadedRanges.keepZones(around: [span(day(2026, 10, 13), day(2026, 10, 14))], months: 12, calendar: calendar)
        let near = TestEvents.make(id: "near", start: day(2026, 11, 20, 9), end: day(2026, 11, 20, 10))
        let far = TestEvents.make(id: "far", start: day(2029, 3, 3, 9), end: day(2029, 3, 3, 10))
        let farDraft = TestEvents.make(id: PlanDraft.eventIDPrefix + "x_20290303", start: day(2029, 3, 3, 9), end: day(2029, 3, 3, 10))
        let farPlan = TestEvents.make(id: "plan-session", start: day(2029, 3, 4, 9), end: day(2029, 3, 4, 10), planID: "p1")
        let farLocal = TestEvents.make(id: "local-only", start: day(2029, 3, 5, 9), end: day(2029, 3, 5, 10))
        // Starts inside the zone (which ends 14 Oct 2027) and ends after it: kept whole.
        let straddling = TestEvents.make(id: "straddling", start: day(2027, 10, 10), end: day(2027, 10, 20), allDay: true)
        let events = [near, far, farDraft, farPlan, farLocal, straddling]
        let loaded = LoadedRanges([span(day(2026, 11, 1), day(2026, 12, 1)), span(day(2029, 2, 1), day(2029, 4, 1))])

        let result = try XCTUnwrap(LoadedRanges.evict(events, loaded: loaded, keep: keep, limit: 3, pendingPlanID: "p1",
                                                      isEvictable: { $0.id != "local-only" }))
        XCTAssertEqual(Set(result.events.map(\.id)), ["near", farDraft.id, "plan-session", "local-only", "straddling"])
        XCTAssertEqual(result.loaded.intervals, [span(day(2026, 11, 1), day(2026, 12, 1))])

        XCTAssertNil(LoadedRanges.evict(events, loaded: loaded, keep: keep, limit: events.count, pendingPlanID: nil))
    }
}
