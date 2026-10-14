import XCTest

/// Google → iPhone "changed since" listings applied to the cache, and the outbox's waiting changes drawn on top of
/// a listing.
final class IncrementalChangesTests: XCTestCase {
    private let mapper = CalendarEventMapper(clock: TestClock.clock)
    private let personal = SampleAccounts.calendar("111", "kenny@example.com", email: "kenny@example.com", primary: true)
    private let school = SampleAccounts.calendar("222", "student@university.example.edu",
                                                 email: "student@university.example.edu", primary: true)
    private let horizon = TestClock.local(2027, 2, 10)

    /// An entry of `events.list` on Thu 15 Oct (or `day`), an hour long.
    private func google(_ id: String, _ title: String = "Event", day: Int = 15, hour: Int = 9,
                        status: String = "confirmed") -> GCalEvent {
        var event = GCalEvent()
        event.id = id
        event.status = status
        event.summary = title
        event.start = GCalDateTime(dateTime: String(format: "2026-10-%02dT%02d:00:00", day, hour), timeZone: "Europe/London")
        event.end = GCalDateTime(dateTime: String(format: "2026-10-%02dT%02d:00:00", day, hour + 1), timeZone: "Europe/London")
        event.etag = "\"\(id)-2\""
        return event
    }

    private func cached(_ id: String, _ calendar: CalendarInfo, title: String = "Event", day: Int = 15, hour: Int = 9,
                        seriesID: String? = nil) -> ScheduleEvent {
        TestEvents.make(id: id, title: title, start: TestClock.local(2026, 10, day, hour),
                        end: TestClock.local(2026, 10, day, hour + 1), seriesID: seriesID, calendar: calendar.id)
    }

    private func timed(_ value: String) -> GCalDateTime {
        GCalDateTime(dateTime: value, timeZone: "Europe/London")
    }

    // MARK: Changed since

    func testCancelledRemovesUpdatedReplacesAndNewIsAdded() throws {
        let events = [cached("a", personal), cached("b", personal, title: "Old"), cached("b", school, title: "Old"),
                      cached("s_1", personal, seriesID: "s"), cached("s_2", personal, day: 22, seriesID: "s")]
        let changes = [google("a", status: "cancelled"), google("b", "New title", hour: 11), google("c", "Added"),
                       google("s", status: "cancelled")]

        let result = try XCTUnwrap(IncrementalChanges.apply(changes, calendar: personal.id, known: [personal, school],
                                                            to: events, mapper: mapper))
        XCTAssertFalse(result.contains { $0.id == "a" })
        let renamed = try XCTUnwrap(result.first { $0.id == "b" && $0.calendarRef == personal.id })
        XCTAssertEqual(renamed.title, "New title")
        XCTAssertEqual(renamed.start, TestClock.local(2026, 10, 15, 11))
        XCTAssertEqual(renamed.etag, "\"b-2\"")
        // Another calendar's copy of the same meeting is left alone.
        XCTAssertEqual(result.first { $0.id == "b" && $0.calendarRef == school.id }?.title, "Old")
        XCTAssertEqual(result.first { $0.id == "c" }?.calendarRef, personal.id)
        // A cancelled series takes its instances with it.
        XCTAssertFalse(result.contains { $0.seriesID == "s" })
        XCTAssertEqual(result.count, 3)
    }

    func testUnknownCalendarOrNothingNewChangesNothing() throws {
        let events = [cached("a", personal)]
        let removed = SampleAccounts.calendar("333", "gone@example.com")
        XCTAssertNil(IncrementalChanges.apply([google("a", status: "cancelled")], calendar: removed.id, known: [personal],
                                              to: events, mapper: mapper))

        // The listing overlaps the previous pass: a copy identical to the cached one is not a change.
        let same = try XCTUnwrap(mapper.scheduleEvent(from: google("a"), in: personal))
        XCTAssertNil(IncrementalChanges.apply([google("a")], calendar: personal.id, known: [personal],
                                              to: [same], mapper: mapper))
        // A cancelled event that was never cached is not a change either.
        XCTAssertNil(IncrementalChanges.apply([google("zzz", status: "cancelled")], calendar: personal.id,
                                              known: [personal], to: [same], mapper: mapper))
    }

    func testANewInstanceOfACachedSeriesCallsForAFullListing() {
        let events = [cached("s_20261015T080000Z", personal, seriesID: "s"), cached("a", personal)]
        // Re-timed in Google: the instance comes back under a new id, the old one is not reported.
        var retimed = google("s_20261015T090000Z", hour: 10)
        retimed.recurringEventId = "s"
        XCTAssertTrue(IncrementalChanges.reshapesSeries([retimed], calendar: personal.id, cached: events))

        // An edit of an instance already cached, a one-off, or another calendar's series is not.
        var edited = google("s_20261015T080000Z", "Renamed")
        edited.recurringEventId = "s"
        XCTAssertFalse(IncrementalChanges.reshapesSeries([edited, google("b")], calendar: personal.id, cached: events))
        XCTAssertFalse(IncrementalChanges.reshapesSeries([retimed], calendar: school.id, cached: events))
    }

    // MARK: Waiting changes drawn over a listing

    func testQueuedChangesAreDrawnOverAListing() throws {
        let listing = [cached("e1", personal, title: "Team sync", hour: 14), cached("gone", personal, hour: 10),
                       cached("s_1", personal, hour: 18, seriesID: "s"), cached("e1", school, title: "Team sync", hour: 14)]
        var insertBody = GCalEvent()
        insertBody.id = "sslunch"
        insertBody.summary = "Lunch"
        insertBody.start = timed("2026-10-15T13:00:00")
        insertBody.end = timed("2026-10-15T14:00:00")
        var rename = GCalEvent()
        rename.summary = "Team sync (room 4)"
        rename.start = timed("2026-10-15T16:00:00")
        rename.end = timed("2026-10-15T17:00:00")
        let items = [
            OutboxItem(kind: .insert, calendar: personal.id, eventID: "sslunch", body: insertBody, title: "Lunch"),
            OutboxItem(kind: .patch, calendar: personal.id, eventID: "e1", body: rename, title: "Team sync"),
            OutboxItem(kind: .delete, calendar: personal.id, eventID: "gone", title: "Gone"),
            OutboxItem(kind: .patchSeries, calendar: personal.id, eventID: "s",
                       seriesTime: OutboxItem.SeriesTime(newStart: TestClock.local(2026, 10, 15, 7), duration: 3600),
                       title: "Gym")
        ]

        let drawn = OutboxOverlay.apply(items, to: listing, mapper: mapper, horizon: horizon)
        let lunch = try XCTUnwrap(drawn.first { $0.id == "sslunch" })
        XCTAssertTrue(lunch.isWaitingToSync)
        XCTAssertEqual(lunch.calendarRef, personal.id)
        XCTAssertEqual(lunch.start, TestClock.local(2026, 10, 15, 13))
        let renamed = try XCTUnwrap(drawn.first { $0.id == "e1" && $0.calendarRef == personal.id })
        XCTAssertEqual(renamed.title, "Team sync (room 4)")
        XCTAssertEqual(renamed.start, TestClock.local(2026, 10, 15, 16))
        XCTAssertEqual(renamed.end, TestClock.local(2026, 10, 15, 17))
        XCTAssertTrue(renamed.isWaitingToSync)
        let schoolCopy = try XCTUnwrap(drawn.first { $0.id == "e1" && $0.calendarRef == school.id })
        XCTAssertEqual(schoolCopy.title, "Team sync")
        XCTAssertFalse(schoolCopy.isWaitingToSync)
        XCTAssertFalse(drawn.contains { $0.id == "gone" })
        let gym = try XCTUnwrap(drawn.first { $0.id == "s_1" })
        XCTAssertEqual(gym.start, TestClock.local(2026, 10, 15, 7))
        XCTAssertEqual(gym.end, TestClock.local(2026, 10, 15, 8))
        XCTAssertTrue(gym.isWaitingToSync)

        // It runs after every listing: drawing it again changes nothing.
        XCTAssertEqual(OutboxOverlay.apply(items, to: drawn, mapper: mapper, horizon: horizon), drawn)

        // A change Google refused is not drawn, so the next listing rolls it back.
        var refused = items[1]
        refused.failure = "No"
        XCTAssertEqual(OutboxOverlay.apply([refused], to: listing, mapper: mapper, horizon: horizon), listing)
    }

    func testAQueuedWeeklySeriesIsExpandedLikeGoogleWould() {
        var series = GCalEvent()
        series.id = "ssgym"
        series.summary = "Gym"
        series.start = timed("2026-10-14T18:30:00")
        series.end = timed("2026-10-14T19:30:00")
        series.recurrence = ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;UNTIL=20261030T225959Z"]
        let item = OutboxItem(kind: .insert, calendar: personal.id, eventID: "ssgym", body: series, title: "Gym")

        let drawn = OutboxOverlay.apply([item], to: [], mapper: mapper, horizon: horizon)
        // Wed 14, Fri 16, Mon 19, Wed 21, Fri 23, Mon 26, Wed 28, Fri 30 October.
        XCTAssertEqual(drawn.count, 8)
        XCTAssertTrue(drawn.allSatisfy { $0.seriesID == "ssgym" && $0.isWaitingToSync && $0.calendarRef == personal.id })
        XCTAssertEqual(drawn.first?.start, TestClock.local(2026, 10, 14, 18, 30))
    }
}
