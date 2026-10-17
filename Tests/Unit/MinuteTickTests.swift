import XCTest

/// The drawer's minute clock (`MinuteTick`): it wakes at the start of each minute, as `TimelineView(.everyMinute)`
/// did, so an ended event leaves the Events section within a minute.
final class MinuteTickTests: XCTestCase {
    func testTheNextTickIsTheStartOfTheNextMinute() {
        let tick = Date(timeIntervalSinceReferenceDate: 60 * 13_000_000)
        XCTAssertEqual(MinuteTick.next(after: tick), tick.addingTimeInterval(60), "on a tick: the one after")
        XCTAssertEqual(MinuteTick.next(after: tick.addingTimeInterval(0.4)), tick.addingTimeInterval(60))
        XCTAssertEqual(MinuteTick.next(after: tick.addingTimeInterval(59.9)), tick.addingTimeInterval(60))
        XCTAssertEqual(MinuteTick.next(after: tick.addingTimeInterval(-0.1)), tick)
    }

    func testATickIsZeroSecondsOnTheWallClockInEveryTimeZone() {
        let date = Date(timeIntervalSinceReferenceDate: 813_985_234.7)
        let tick = MinuteTick.next(after: date)
        XCTAssertGreaterThan(tick.timeIntervalSince(date), 0)
        XCTAssertLessThanOrEqual(tick.timeIntervalSince(date), 60)
        for id in ["UTC", "Asia/Taipei", "Europe/London", "Asia/Kolkata", "Asia/Kathmandu", "America/St_Johns"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: id) ?? .gmt
            XCTAssertEqual(calendar.component(.second, from: tick), 0, id)
        }
    }
}
