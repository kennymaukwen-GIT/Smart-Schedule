import XCTest

/// The event page's edits as PATCH bodies: only what changed, notes and places cleared with "", a move keeping its
/// length, all-day ⇄ timed with the other form sent as null, reminders set, turned off or back to the defaults,
/// what "All events" can carry, and the diff of an edited copy.
final class EventEditTests: XCTestCase {
    private let mapper = CalendarEventMapper(clock: TestClock.clock)
    private let calendar = TestClock.clock.calendar

    /// Thursday 2026-10-15 14:00–15:00 BST, with notes and a place, default reminders.
    private var meeting: ScheduleEvent {
        var event = TestEvents.make(id: "e1", title: "Design review", start: TestClock.local(2026, 10, 15, 14),
                                    end: TestClock.local(2026, 10, 15, 15))
        event.notes = "Old"
        event.location = "Room 1"
        event.etag = "\"1\""
        return event
    }

    private func keys(_ body: GCalEvent) throws -> Set<String> {
        Set(try TestJSON.object(encoding: body).keys)
    }

    private func json(_ body: GCalEvent, _ key: String) throws -> [String: Any] {
        try XCTUnwrap(TestJSON.object(encoding: body)[key] as? [String: Any], key)
    }

    // MARK: Fields

    func testOnlyChangedFieldsAreSent() throws {
        XCTAssertEqual(try keys(mapper.patch(from: EventEdit(title: "Renamed"), existing: meeting)), ["summary"])
        XCTAssertEqual(try mapper.patch(from: EventEdit(title: "Renamed"), existing: meeting).summary, "Renamed")
        XCTAssertEqual(try mapper.patch(from: EventEdit(title: "   "), existing: meeting), GCalEvent())
        XCTAssertEqual(try mapper.patch(from: EventEdit(title: "Design review"), existing: meeting), GCalEvent())
        XCTAssertEqual(try mapper.patch(from: EventEdit(location: "Room 2"), existing: meeting).location, "Room 2")
        XCTAssertEqual(try mapper.patch(from: EventEdit(location: "Room 1 "), existing: meeting), GCalEvent())
        XCTAssertEqual(try mapper.patch(from: EventEdit(), existing: meeting), GCalEvent())
        XCTAssertTrue(EventEdit().isEmpty)
    }

    func testNotesNilKeepsThemAndEmptyClearsTheDescription() throws {
        XCTAssertNil(try mapper.patch(from: EventEdit(title: "Renamed"), existing: meeting).description)
        XCTAssertEqual(try mapper.patch(from: EventEdit(notes: .some(nil)), existing: meeting).description, "")
        XCTAssertEqual(try mapper.patch(from: EventEdit(notes: ""), existing: meeting).description, "")
        XCTAssertEqual(try mapper.patch(from: EventEdit(notes: "  \n"), existing: meeting).description, "")
        XCTAssertEqual(try TestJSON.object(encoding: mapper.patch(from: EventEdit(notes: ""), existing: meeting))["description"] as? String, "")
        XCTAssertEqual(try mapper.patch(from: EventEdit(notes: "Old\n"), existing: meeting), GCalEvent(), "unchanged")
        XCTAssertEqual(try mapper.patch(from: EventEdit(notes: "New\r\nlines "), existing: meeting).description, "New\nlines")
        // Nothing to clear.
        var bare = meeting
        bare.notes = nil
        XCTAssertEqual(try mapper.patch(from: EventEdit(notes: ""), existing: bare), GCalEvent())
        // A place is cleared the same way.
        XCTAssertEqual(try mapper.patch(from: EventEdit(location: .some(nil)), existing: meeting).location, "")
    }

    // MARK: Times

    func testMovingKeepsTheLength() throws {
        let body = try mapper.patch(from: EventEdit(start: TestClock.local(2026, 10, 15, 16)), existing: meeting)
        XCTAssertEqual(body.start?.dateTime, "2026-10-15T16:00:00")
        XCTAssertEqual(body.end?.dateTime, "2026-10-15T17:00:00")
        XCTAssertEqual(body.start?.timeZone, "Europe/London")
        XCTAssertEqual(try keys(body), ["start", "end"])
        // No form switch: no nulls.
        XCTAssertEqual(Set(try json(body, "start").keys), ["dateTime", "timeZone"])

        let longer = try mapper.patch(from: EventEdit(end: TestClock.local(2026, 10, 15, 16, 30)), existing: meeting)
        XCTAssertEqual(longer.start?.dateTime, "2026-10-15T14:00:00")
        XCTAssertEqual(longer.end?.dateTime, "2026-10-15T16:30:00")
    }

    func testTheEndMustBeAfterTheStart() {
        XCTAssertThrowsError(try mapper.patch(from: EventEdit(end: TestClock.local(2026, 10, 15, 13)), existing: meeting)) { error in
            XCTAssertEqual(error as? EventEditError, .endBeforeStart)
        }
        let same = TestClock.local(2026, 10, 15, 15)
        XCTAssertThrowsError(try mapper.patch(from: EventEdit(start: same, end: same), existing: meeting)) { error in
            XCTAssertEqual(error as? EventEditError, .endBeforeStart)
        }
        XCTAssertEqual(EventEditError.endBeforeStart.errorDescription, "The end must be after the start.")
    }

    func testMakingItAllDaySendsTheTimedFormAsNull() throws {
        let body = try mapper.patch(from: EventEdit(isAllDay: true), existing: meeting)
        XCTAssertEqual(body.start?.date, "2026-10-15")
        XCTAssertEqual(body.end?.date, "2026-10-16")
        let start = try json(body, "start"), end = try json(body, "end")
        XCTAssertEqual(start["date"] as? String, "2026-10-15")
        XCTAssertTrue(start["dateTime"] is NSNull, "\(start)")
        XCTAssertTrue(end["dateTime"] is NSNull, "\(end)")
        // The defaults follow the new form: all-day reminders count from 00:00.
        XCTAssertEqual(body.reminders?.overrides?.map(\.minutes), [900])
        XCTAssertEqual(body.extendedProperties?.private, [SSProperty.localReminders: CalendarEventMapper.defaultRemindersMarker])

        // Shown at once (outbox overlay, demo mode) as an all-day event.
        let shown = OutboxOverlay.applying(body, to: meeting, clock: TestClock.clock)
        XCTAssertTrue(shown.isAllDay)
        XCTAssertEqual(shown.start, TestClock.local(2026, 10, 15))
        XCTAssertEqual(shown.end, TestClock.local(2026, 10, 16))
    }

    func testMakingItTimedSendsTheDateFormAsNull() throws {
        let holiday = TestEvents.make(id: "h1", title: "Offsite", start: TestClock.local(2026, 10, 15),
                                      end: TestClock.local(2026, 10, 16), allDay: true)
        let body = try mapper.patch(from: EventEdit(start: TestClock.local(2026, 10, 15, 9), isAllDay: false), existing: holiday)
        XCTAssertEqual(body.start?.dateTime, "2026-10-15T09:00:00")
        XCTAssertEqual(body.end?.dateTime, "2026-10-15T10:00:00", "the default length")
        XCTAssertTrue(try json(body, "start")["date"] is NSNull)
        XCTAssertTrue(try json(body, "end")["date"] is NSNull)
        XCTAssertEqual(body.reminders?.overrides?.map(\.minutes), [1440, 60, 30, 0])
    }

    func testAnAllDayMoveKeepsItsDaysAcrossTheClockChange() throws {
        // Saturday and Sunday 24–25 October; the Sunday has 25 hours.
        let weekend = TestEvents.make(id: "w1", title: "Weekend away", start: TestClock.local(2026, 10, 24),
                                      end: TestClock.local(2026, 10, 26), allDay: true)
        let moved = try mapper.patch(from: EventEdit(start: TestClock.local(2026, 10, 25)), existing: weekend)
        XCTAssertEqual(moved.start?.date, "2026-10-25")
        XCTAssertEqual(moved.end?.date, "2026-10-27")
        XCTAssertEqual(Set(try json(moved, "start").keys), ["date"])

        // A date picker's last day, made exclusive.
        let oneDay = EventEdit(end: EventEdit.allDayEnd(lastDay: TestClock.local(2026, 10, 24), calendar: calendar))
        XCTAssertEqual(try mapper.patch(from: oneDay, existing: weekend).end?.date, "2026-10-25")
        XCTAssertThrowsError(try mapper.patch(from: EventEdit(end: TestClock.local(2026, 10, 24)), existing: weekend))
    }

    func testAllDayPickerHelpers() {
        XCTAssertEqual(EventEdit.allDayEnd(lastDay: TestClock.local(2026, 10, 16, 15), calendar: calendar), TestClock.local(2026, 10, 17))
        XCTAssertEqual(EventEdit.lastDay(ofAllDayEnd: TestClock.local(2026, 10, 17), start: TestClock.local(2026, 10, 15), calendar: calendar),
                       TestClock.local(2026, 10, 16))
        XCTAssertEqual(EventEdit.lastDay(ofAllDayEnd: TestClock.local(2026, 10, 16), start: TestClock.local(2026, 10, 15), calendar: calendar),
                       TestClock.local(2026, 10, 15))
        // The 25-hour day.
        XCTAssertEqual(EventEdit.lastDay(ofAllDayEnd: TestClock.local(2026, 10, 26), start: TestClock.local(2026, 10, 25), calendar: calendar),
                       TestClock.local(2026, 10, 25))
    }

    // MARK: Reminders

    func testRemindersCanBeSetTurnedOffOrResetToTheDefaults() throws {
        let set = try mapper.patch(from: EventEdit(reminderMinutes: .some([10])), existing: meeting)
        XCTAssertEqual(set.reminders?.overrides?.map(\.minutes), [10])
        XCTAssertEqual(set.extendedProperties?.private, [SSProperty.localReminders: "10"])

        let off = try mapper.patch(from: EventEdit(reminderMinutes: .some([])), existing: meeting)
        XCTAssertEqual(off.reminders, GCalReminders(useDefault: false, overrides: []))
        XCTAssertEqual(off.extendedProperties?.private, [SSProperty.localReminders: CalendarEventMapper.noRemindersMarker])
        XCTAssertEqual(CalendarEventMapper.reminderMinutes(of: off), [])
        XCTAssertEqual(OutboxOverlay.applying(off, to: meeting, clock: TestClock.clock).reminderMinutes, [])

        var custom = meeting
        custom.reminderMinutes = [10]
        let reset = try mapper.patch(from: EventEdit(reminderMinutes: .some(nil)), existing: custom)
        XCTAssertEqual(reset.reminders?.overrides?.map(\.minutes), [1440, 60, 30, 0])
        XCTAssertEqual(reset.extendedProperties?.private, [SSProperty.localReminders: CalendarEventMapper.defaultRemindersMarker])
        XCTAssertNil(CalendarEventMapper.reminderMinutes(of: reset))
        // Already the defaults: nothing to send.
        XCTAssertEqual(try mapper.patch(from: EventEdit(reminderMinutes: .some(nil)), existing: meeting), GCalEvent())
    }

    // MARK: "All events"

    func testWhatAllEventsCanCarry() throws {
        var yoga = meeting
        yoga.id = "series1_20261015T130000Z"
        yoga.seriesID = "series1"

        let moved = try mapper.seriesPatch(from: EventEdit(title: "Morning yoga", start: TestClock.local(2026, 10, 15, 15),
                                                           end: TestClock.local(2026, 10, 15, 16, 30)), existing: yoga)
        XCTAssertEqual(moved.body.summary, "Morning yoga")
        XCTAssertNil(moved.body.start, "the time goes on the master's own date when it is sent")
        XCTAssertEqual(moved.newStart, TestClock.local(2026, 10, 15, 15))
        XCTAssertEqual(moved.duration, 5_400)

        let notesOnly = try mapper.seriesPatch(from: EventEdit(notes: "Bring a mat"), existing: yoga)
        XCTAssertEqual(notesOnly.body.description, "Bring a mat")
        XCTAssertNil(notesOnly.newStart)

        XCTAssertThrowsError(try mapper.seriesPatch(from: EventEdit(start: TestClock.local(2026, 10, 16, 14)), existing: yoga)) { error in
            XCTAssertEqual(error as? EventEditError, .seriesDayChange)
        }
        XCTAssertThrowsError(try mapper.seriesPatch(from: EventEdit(isAllDay: true), existing: yoga)) { error in
            XCTAssertEqual(error as? EventEditError, .seriesAllDayChange)
        }
    }

    // MARK: The page's edited copy

    func testChangesFromAnEditedCopy() {
        XCTAssertTrue(EventEdit.changes(from: meeting, to: meeting).isEmpty)

        var edited = meeting
        edited.title = "  Renamed "
        edited.notes = "Old\nBring slides"
        edited.reminderMinutes = [15]
        edited.location = "Room 1  "
        let edit = EventEdit.changes(from: meeting, to: edited)
        XCTAssertEqual(edit.title, "Renamed")
        XCTAssertEqual(edit.notes, .some("Old\nBring slides"))
        XCTAssertEqual(edit.reminderMinutes, .some([15]))
        XCTAssertTrue(edit.location == nil, "the same place")
        XCTAssertNil(edit.start)
        XCTAssertNil(edit.isAllDay)

        var cleared = meeting
        cleared.notes = "  "
        cleared.location = nil
        let clearing = EventEdit.changes(from: meeting, to: cleared)
        XCTAssertTrue(clearing.notes == .some(nil))
        XCTAssertTrue(clearing.location == .some(nil))

        var allDay = meeting
        allDay.isAllDay = true
        let toggled = EventEdit.changes(from: meeting, to: allDay)
        XCTAssertEqual(toggled.isAllDay, true)
        XCTAssertEqual(toggled.start, meeting.start)
        XCTAssertEqual(toggled.end, meeting.end)
    }

    // MARK: The null in the outbox file

    func testTheOtherFormsNullSurvivesTheOutboxFile() throws {
        let flagged = GCalDateTime(date: "2026-10-15", clearsOtherForm: true)
        let data = try JSONEncoder().encode(flagged)
        let object = try TestJSON.object(data)
        XCTAssertTrue(object["dateTime"] is NSNull)
        XCTAssertNil(object["timeZone"])
        XCTAssertEqual(try JSONDecoder().decode(GCalDateTime.self, from: data), flagged)

        let google = try JSONDecoder().decode(GCalDateTime.self, from: Data(#"{"dateTime": "2026-10-15T14:00:00+01:00"}"#.utf8))
        XCTAssertFalse(google.clearsOtherForm)
        XCTAssertEqual(Set(try TestJSON.object(JSONEncoder().encode(google)).keys), ["dateTime"])
    }
}
