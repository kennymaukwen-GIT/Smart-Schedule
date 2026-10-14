import XCTest

/// After a 412 the user's change is re-applied on top of Google's current copy: only what the user changed is
/// sent, so a newer edit made in Google is never overwritten with stale fields.
final class ConflictMergeTests: XCTestCase {
    private let mapper = CalendarEventMapper(clock: TestClock.clock)

    private func timed(_ value: String) -> GCalDateTime {
        GCalDateTime(dateTime: value, timeZone: "Europe/London")
    }

    /// Google's copy now.
    private func google(summary: String = "Team sync", start: String, end: String, location: String? = nil) -> GCalEvent {
        var event = GCalEvent()
        event.id = "e1"
        event.status = "confirmed"
        event.summary = summary
        event.location = location
        event.start = timed(start)
        event.end = timed(end)
        event.etag = "\"2\""
        return event
    }

    /// What the user saw: Thu 15 Oct 14:00–15:00.
    private var base: ScheduleEvent {
        TestEvents.make(id: "e1", title: "Team sync", start: TestClock.local(2026, 10, 15, 14),
                        end: TestClock.local(2026, 10, 15, 15))
    }

    func testOnlyTheUsersFieldsAreSentAgain() throws {
        // The user renamed it; Google meanwhile added a room.
        var change = GCalEvent()
        change.summary = "Team sync (moved)"
        let current = google(start: "2026-10-15T14:00:00", end: "2026-10-15T15:00:00", location: "Room 4")

        let rebased = try XCTUnwrap(ConflictMerge.rebase(change, base: base, onto: current, mapper: mapper))
        XCTAssertEqual(rebased.summary, "Team sync (moved)")
        XCTAssertNil(rebased.location)
        XCTAssertNil(rebased.start)
        XCTAssertNil(rebased.end)
    }

    func testAMoveKeepsTheLengthGoogleGaveItMeanwhile() throws {
        // Pushed to 16:00 here (still an hour long); Google meanwhile made it 90 minutes.
        var change = GCalEvent()
        change.start = timed("2026-10-15T16:00:00")
        change.end = timed("2026-10-15T17:00:00")
        let current = google(start: "2026-10-15T14:00:00", end: "2026-10-15T15:30:00")

        let rebased = try XCTUnwrap(ConflictMerge.rebase(change, base: base, onto: current, mapper: mapper))
        XCTAssertEqual(rebased.start?.dateTime, "2026-10-15T16:00:00")
        XCTAssertEqual(rebased.end?.dateTime, "2026-10-15T17:30:00")
        XCTAssertEqual(rebased.end?.timeZone, "Europe/London")
    }

    func testALengthChosenHereWins() throws {
        var change = GCalEvent()
        change.start = timed("2026-10-15T16:00:00")
        change.end = timed("2026-10-15T16:30:00")
        let current = google(start: "2026-10-15T14:00:00", end: "2026-10-15T15:30:00")

        let rebased = try XCTUnwrap(ConflictMerge.rebase(change, base: base, onto: current, mapper: mapper))
        XCTAssertEqual(rebased.start?.dateTime, "2026-10-15T16:00:00")
        XCTAssertEqual(rebased.end?.dateTime, "2026-10-15T16:30:00")
    }

    func testAMovedStartAlwaysCarriesItsEnd() throws {
        // A start alone (no end): Google's end would fall before it, so the end follows with Google's length.
        var change = GCalEvent()
        change.start = timed("2026-10-15T16:00:00")
        let current = google(start: "2026-10-15T14:00:00", end: "2026-10-15T15:00:00")

        let rebased = try XCTUnwrap(ConflictMerge.rebase(change, base: base, onto: current, mapper: mapper))
        XCTAssertEqual(rebased.start?.dateTime, "2026-10-15T16:00:00")
        XCTAssertEqual(rebased.end?.dateTime, "2026-10-15T17:00:00")
    }

    func testNothingIsSentWhenGoogleAlreadyHasTheChange() {
        var change = GCalEvent()
        change.summary = "Team sync"
        change.start = timed("2026-10-15T14:00:00")
        change.end = timed("2026-10-15T15:00:00")
        // Google writes the same instant with an offset.
        var current = google(start: "2026-10-15T14:00:00", end: "2026-10-15T15:00:00")
        current.start = GCalDateTime(dateTime: "2026-10-15T14:00:00+01:00", timeZone: "Europe/London")
        current.end = GCalDateTime(dateTime: "2026-10-15T15:00:00+01:00", timeZone: "Europe/London")

        XCTAssertNil(ConflictMerge.rebase(change, base: base, onto: current, mapper: mapper))
    }

    func testOnlyDifferingPrivatePropertiesAreSent() throws {
        var change = GCalEvent()
        change.extendedProperties = GCalExtendedProperties(private: [SSProperty.localReminders: "10", SSProperty.kind: "event"])
        var current = google(start: "2026-10-15T14:00:00", end: "2026-10-15T15:00:00")
        current.extendedProperties = GCalExtendedProperties(private: [SSProperty.kind: "event", SSProperty.localReminders: "default"])

        let rebased = try XCTUnwrap(ConflictMerge.rebase(change, base: base, onto: current, mapper: mapper))
        XCTAssertEqual(rebased.extendedProperties?.private, [SSProperty.localReminders: "10"])
        XCTAssertNil(rebased.summary)
    }

    func testOverlaidKeepsFieldsAndMergesPrivateProperties() {
        var first = GCalEvent()
        first.id = "ss1"
        first.summary = "Lunch"
        first.location = "Canteen"
        first.extendedProperties = GCalExtendedProperties(private: [SSProperty.kind: "event", SSProperty.localReminders: "default"])
        var patch = GCalEvent()
        patch.summary = "Lunch with Andrew"
        patch.extendedProperties = GCalExtendedProperties(private: [SSProperty.localReminders: "30"])

        let merged = first.overlaid(with: patch)
        XCTAssertEqual(merged.id, "ss1")
        XCTAssertEqual(merged.summary, "Lunch with Andrew")
        XCTAssertEqual(merged.location, "Canteen")
        XCTAssertEqual(merged.extendedProperties?.private, [SSProperty.kind: "event", SSProperty.localReminders: "30"])
    }
}
