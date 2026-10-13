import XCTest

final class ScheduleEventTests: XCTestCase {
    private func timed(_ id: String, _ startHour: Int, _ startMinute: Int, _ endHour: Int, _ endMinute: Int) -> ScheduleEvent {
        TestEvents.make(id: id,
                        start: TestClock.local(2026, 10, 14, startHour, startMinute),
                        end: TestClock.local(2026, 10, 14, endHour, endMinute))
    }

    func testBackToBackEventsDoNotOverlap() {
        let first = timed("a", 10, 0, 11, 0)
        let second = timed("b", 11, 0, 12, 0)
        XCTAssertFalse(first.overlaps(second))
        XCTAssertFalse(second.overlaps(first))
    }

    func testPartialOverlapIsSymmetric() {
        let first = timed("a", 10, 0, 11, 0)
        let second = timed("b", 10, 30, 11, 30)
        XCTAssertTrue(first.overlaps(second))
        XCTAssertTrue(second.overlaps(first))
    }

    func testContainedEventOverlaps() {
        let outer = timed("a", 9, 0, 17, 0)
        let inner = timed("b", 12, 0, 12, 15)
        XCTAssertTrue(outer.overlaps(inner))
        XCTAssertTrue(inner.overlaps(outer))
    }

    func testAnEventNeverOverlapsItself() {
        let event = timed("a", 10, 0, 11, 0)
        XCTAssertFalse(event.overlaps(event))
        // Same id (e.g. a refreshed copy) is treated as the same event.
        XCTAssertFalse(event.overlaps(timed("a", 10, 30, 11, 30)))
    }

    func testAllDayNeverOverlaps() {
        let holiday = TestEvents.make(id: "h", start: TestClock.local(2026, 10, 14), end: TestClock.local(2026, 10, 15), allDay: true)
        let meeting = timed("m", 10, 0, 11, 0)
        let otherAllDay = TestEvents.make(id: "h2", start: TestClock.local(2026, 10, 14), end: TestClock.local(2026, 10, 16), allDay: true)
        XCTAssertFalse(holiday.overlaps(meeting))
        XCTAssertFalse(meeting.overlaps(holiday))
        XCTAssertFalse(holiday.overlaps(otherAllDay))
    }

    func testIntersectsUsesHalfOpenInterval() {
        let window = DateInterval(start: TestClock.local(2026, 10, 14, 10), end: TestClock.local(2026, 10, 14, 11))
        XCTAssertFalse(timed("before", 9, 0, 10, 0).intersects(window))
        XCTAssertFalse(timed("after", 11, 0, 12, 0).intersects(window))
        XCTAssertTrue(timed("tail", 9, 30, 10, 1).intersects(window))
        XCTAssertTrue(timed("head", 10, 59, 11, 30).intersects(window))
        XCTAssertTrue(timed("around", 8, 0, 12, 0).intersects(window))
    }

    func testAllDayEventIntersectsItsDay() {
        let holiday = TestEvents.make(id: "h", start: TestClock.local(2026, 10, 14), end: TestClock.local(2026, 10, 15), allDay: true)
        let day = DateInterval(start: TestClock.local(2026, 10, 14), end: TestClock.local(2026, 10, 15))
        let nextDay = DateInterval(start: TestClock.local(2026, 10, 15), end: TestClock.local(2026, 10, 16))
        XCTAssertTrue(holiday.intersects(day))
        XCTAssertFalse(holiday.intersects(nextDay))
    }

    func testDuration() {
        XCTAssertEqual(timed("a", 10, 0, 11, 30).duration, 5400)
    }
}
