import XCTest

/// The Dynamic Island shows an event only from its lead time before the start until it ends (Lock Screen until
/// 10 minutes after): which events are planned, when each appears and ends, and what a push-to-start carries.
final class ActivitySchedulerTests: XCTestCase {
    private let clock = TestClock.clock
    /// Wednesday 2026-10-14 10:00 BST.
    private let now = TestClock.local(2026, 10, 14, 10, 0)

    private func event(_ id: String, _ start: Date, hours: Double = 1, title: String = "Event") -> ScheduleEvent {
        TestEvents.make(id: id, title: title, start: start, end: start.addingTimeInterval(hours * 3_600))
    }

    // MARK: Planning

    func testOnlyEventsStartingWithinFortyEightHoursSoonestFirst() {
        let later = event("later", TestClock.local(2026, 10, 16, 9, 0))           // 47 h ahead
        let tooFar = event("far", TestClock.local(2026, 10, 16, 11, 0))           // 49 h ahead
        let soon = event("soon", TestClock.local(2026, 10, 14, 10, 20))
        let running = event("running", TestClock.local(2026, 10, 14, 9, 30))      // under way
        let over = event("over", TestClock.local(2026, 10, 14, 8, 0))             // ended at 9:00
        let items = ActivityPlanner.items(events: [later, tooFar, soon, running, over], leadMinutes: 30, now: now)
        XCTAssertEqual(items.map(\.eventID), ["running", "soon", "later"])
    }

    func testAllDayCompletedAndDraftEventsGetNone() {
        var done = event("done", TestClock.local(2026, 10, 14, 11))
        done.isCompleted = true
        let allDay = TestEvents.make(id: "allday", start: TestClock.local(2026, 10, 15), end: TestClock.local(2026, 10, 16), allDay: true)
        let draft = event("draft-ev-batch-0", TestClock.local(2026, 10, 14, 12))
        let real = event("real", TestClock.local(2026, 10, 14, 13))
        XCTAssertEqual(ActivityPlanner.items(events: [done, allDay, draft, real], leadMinutes: 30, now: now).map(\.eventID), ["real"])
    }

    func testOffPlansNothingAndTheLimitKeepsTheSoonest() {
        let events = (0..<12).map { event("e\($0)", now.addingTimeInterval(Double($0 + 1) * 3_600)) }
        XCTAssertTrue(ActivityPlanner.items(events: events, leadMinutes: nil, now: now).isEmpty)
        let limited = ActivityPlanner.items(events: events, leadMinutes: 30, now: now, limit: ActivityPlanner.maxPending)
        XCTAssertEqual(ActivityPlanner.maxPending, 8)
        XCTAssertEqual(limited.map(\.eventID), (0..<8).map { "e\($0)" })
    }

    func testTriggerIsTheLeadTimeBeforeTheStart() {
        let meeting = event("m", TestClock.local(2026, 10, 15, 14, 0))
        for lead in [30, 15, 10, 5] {
            let item = ActivityPlanner.items(events: [meeting], leadMinutes: lead, now: now)[0]
            XCTAssertEqual(item.triggerAt, TestClock.local(2026, 10, 15, 14, 0).addingTimeInterval(-Double(lead) * 60))
            XCTAssertEqual(item.end, TestClock.local(2026, 10, 15, 15, 0))
            XCTAssertEqual(item.dismissal, TestClock.local(2026, 10, 15, 15, 10), "Lock Screen until 10 minutes after the end")
        }
    }

    func testLongEventsAreCutAtEightHoursWithoutFailing() {
        let flight = event("flight", TestClock.local(2026, 10, 15, 9, 0), hours: 13)
        let item = ActivityPlanner.items(events: [flight], leadMinutes: 30, now: now)[0]
        XCTAssertEqual(item.triggerAt, TestClock.local(2026, 10, 15, 8, 30))
        XCTAssertEqual(item.end, TestClock.local(2026, 10, 15, 16, 30), "8 hours after it appears")
        XCTAssertEqual(item.dismissal, TestClock.local(2026, 10, 15, 16, 40))
        // Past that, nothing is planned for it any more.
        XCTAssertTrue(ActivityPlanner.items(events: [flight], leadMinutes: 30, now: TestClock.local(2026, 10, 15, 17)).isEmpty)
    }

    func testAShownActivityIsNotStartedAgainButALostScheduledOneIs() {
        let item = ActivityPlanner.items(events: [event("m", TestClock.local(2026, 10, 14, 10, 20))], leadMinutes: 30, now: now)[0]
        XCTAssertTrue(ActivityPlanner.shouldStart(item, shownTrigger: nil, now: now), "never started")
        XCTAssertFalse(ActivityPlanner.shouldStart(item, shownTrigger: item.triggerAt, now: now), "shown, then swiped away")
        XCTAssertTrue(ActivityPlanner.shouldStart(item, shownTrigger: item.triggerAt.addingTimeInterval(-600), now: now),
                      "the event or the lead time changed")
        let tomorrow = ActivityPlanner.items(events: [event("t", TestClock.local(2026, 10, 15, 9))], leadMinutes: 30, now: now)[0]
        XCTAssertTrue(ActivityPlanner.shouldStart(tomorrow, shownTrigger: tomorrow.triggerAt, now: now),
                      "scheduled but gone before it could show (a restart): scheduled again")
    }

    // MARK: Content

    func testContentIsBuiltAsOfWhenTheActivityAppears() {
        let start = TestClock.local(2026, 10, 15, 9, 0) // Thursday
        let meeting = event("m", start, title: "Design review")
        let trigger = start.addingTimeInterval(-30 * 60)
        let state = LiveActivityStateBuilder.build(for: meeting, events: [meeting], lastLine: nil, asOf: trigger, clock: clock)
        XCTAssertEqual(state.headline, "Design review")
        XCTAssertEqual(state.eventID, "m")
        XCTAssertEqual(state.todayIndex, 4, "Thursday, the day it appears, not Wednesday when it was planned")
        XCTAssertEqual(state.countdownFrom, trigger)
        XCTAssertEqual(state.countdownTarget, start)
        XCTAssertEqual(state.eventStart, start)
        XCTAssertEqual(state.eventEnd, start.addingTimeInterval(3_600))
        XCTAssertFalse(state.isInProgress)
    }

    func testCountdownSwitchesToTheEndOnceTheStartHasPassed() {
        let start = TestClock.local(2026, 10, 14, 10, 30)
        let meeting = event("m", start)
        let state = LiveActivityStateBuilder.build(for: meeting, events: [meeting], lastLine: nil, asOf: now, clock: clock)
        XCTAssertEqual(state.countdownRange(isStale: false), now...start, "to the start")
        XCTAssertEqual(state.countdownRange(isStale: true), start...start.addingTimeInterval(3_600),
                       "stale at the start with no update from the app: the time left")
        let underway = LiveActivityStateBuilder.build(for: meeting, events: [meeting], lastLine: nil,
                                                      asOf: TestClock.local(2026, 10, 14, 10, 45), clock: clock)
        XCTAssertTrue(underway.isInProgress)
        XCTAssertEqual(underway.countdownRange(isStale: false), TestClock.local(2026, 10, 14, 10, 45)...start.addingTimeInterval(3_600))
    }

    func testPayloadsWithoutEventStartStillDecode() throws {
        let meeting = event("m", TestClock.local(2026, 10, 14, 10, 30))
        var object = try TestJSON.object(encoding: LiveActivityStateBuilder.build(events: [meeting], lastLine: nil, now: now, clock: clock))
        object.removeValue(forKey: "eventStart")
        object.removeValue(forKey: "eventEnd")
        let state = try JSONDecoder().decode(ScheduleActivityAttributes.ContentState.self,
                                             from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(state.eventStart, TestClock.local(2026, 10, 14, 10, 30), "the countdown target")
        XCTAssertNil(state.eventEnd)
        let attributes = try JSONDecoder().decode(ScheduleActivityAttributes.self, from: Data("{}".utf8))
        XCTAssertNil(attributes.eventID, "an older build's activity, which the scheduler ends")
    }

    // MARK: Push-to-start (iOS 18)

    func testPushToStartCarriesWhatActivityKitDecodesAndNothingElse() throws {
        var trip = event("ev1", TestClock.local(2026, 10, 15, 9), title: "Flight to Tokyo")
        trip.location = "Terminal 2"
        trip.notes = "Bring passport"
        let item = ActivityPlanner.items(events: [trip], leadMinutes: 15, now: now)[0]
        // Even when handed the assistant's last reply, the registration never carries it to the server.
        var state = LiveActivityStateBuilder.build(for: trip, events: [trip], lastLine: "Added: Dentist · Fri 10:00",
                                                   asOf: item.triggerAt, clock: clock)
        let entry = try PushToStartRegistrar.event(for: item, attributes: ScheduleActivityAttributes(eventID: "ev1"), state: state)
        XCTAssertFalse(entry.contentStateJSON.contains("Dentist"), entry.contentStateJSON)
        state.lastAssistantLine = nil
        XCTAssertEqual(entry.eventID, "ev1")
        XCTAssertEqual(entry.title, "Flight to Tokyo")
        XCTAssertEqual(entry.eventStart, TestClock.local(2026, 10, 15, 9))
        XCTAssertEqual(entry.leadTime, 15)
        XCTAssertEqual(entry.triggerAt, TestClock.local(2026, 10, 15, 8, 45))
        // Default strategies on both sides, as ActivityKit decodes a push.
        let decoded = try JSONDecoder().decode(ScheduleActivityAttributes.ContentState.self, from: Data(entry.contentStateJSON.utf8))
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(try JSONDecoder().decode(ScheduleActivityAttributes.self, from: Data(entry.attributesJSON.utf8)).eventID, "ev1")
        let everything = entry.attributesJSON + entry.contentStateJSON
        XCTAssertFalse(everything.contains("Terminal 2") || everything.contains("passport"), "no places or notes")
    }

    func testLongTitlesAreCutToWhatTheServerTakes() throws {
        let title = String(repeating: "Planning ", count: 40) // 360 characters
        let meeting = event("m", TestClock.local(2026, 10, 15, 9), title: title)
        let item = ActivityPlanner.items(events: [meeting], leadMinutes: 30, now: now)[0]
        let state = LiveActivityStateBuilder.build(for: meeting, events: [meeting], lastLine: nil, asOf: item.triggerAt, clock: clock)
        let entry = try PushToStartRegistrar.event(for: item, attributes: ScheduleActivityAttributes(eventID: "m"), state: state)
        XCTAssertEqual(entry.title.unicodeScalars.count, PushToStartRegistrar.maxTitleScalars)
        XCTAssertTrue(title.hasPrefix(entry.title))
        let decoded = try JSONDecoder().decode(ScheduleActivityAttributes.ContentState.self, from: Data(entry.contentStateJSON.utf8))
        XCTAssertEqual(decoded.headline, entry.title, "the pushed headline too")
        // Counted in Unicode scalars, as the server counts (JavaScript's Array.from): an emoji family is five.
        let families = String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 50)
        XCTAssertEqual(PushToStartRegistrar.capped(families).unicodeScalars.count, 200)
        XCTAssertEqual(PushToStartRegistrar.capped("Dentist"), "Dentist")
    }

    /// The same content always encodes to the same text: otherwise every pass in a new process would count as a
    /// change and upload the registration again.
    func testEmbeddedJSONHasSortedKeys() throws {
        let meeting = event("m", TestClock.local(2026, 10, 15, 9))
        let item = ActivityPlanner.items(events: [meeting], leadMinutes: 30, now: now)[0]
        let state = LiveActivityStateBuilder.build(for: meeting, events: [meeting], lastLine: nil, asOf: item.triggerAt, clock: clock)
        let entry = try PushToStartRegistrar.event(for: item, attributes: ScheduleActivityAttributes(eventID: "m"), state: state)
        let sorted = JSONEncoder()
        sorted.outputFormatting = [.sortedKeys]
        var expected = state
        expected.lastAssistantLine = nil
        XCTAssertEqual(entry.contentStateJSON, String(decoding: try sorted.encode(expected), as: UTF8.self))
        XCTAssertEqual(entry.attributesJSON, String(decoding: try sorted.encode(ScheduleActivityAttributes(eventID: "m")), as: UTF8.self))
    }

    /// iOS 18: events due within the server's retry window stay registered unless they are showing or were shown.
    func testRecentlyDueEventsStayRegisteredForTheServersRetry() {
        let soon = event("soon", TestClock.local(2026, 10, 14, 10, 40))        // trigger 10:10, still to come
        let failed = event("failed", TestClock.local(2026, 10, 14, 10, 29))    // trigger 9:59, push not arrived
        let showing = event("showing", TestClock.local(2026, 10, 14, 10, 29))  // trigger 9:59, on screen
        let swiped = event("swiped", TestClock.local(2026, 10, 14, 10, 29))    // trigger 9:59, shown then swiped away
        let old = event("old", TestClock.local(2026, 10, 14, 10, 25))          // trigger 9:55, past the window
        let items = ActivityPlanner.items(events: [soon, failed, showing, swiped, old], leadMinutes: 30, now: now)
        let kept = ActivityPlanner.pushToStartItems(
            items, now: now, showing: ["showing"],
            shownTriggers: ["swiped": TestClock.local(2026, 10, 14, 9, 59).timeIntervalSince1970])
        XCTAssertEqual(Set(kept.map(\.eventID)), ["soon", "failed"])
    }

    func testRegistrationIsReplacedWhole() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("push-to-start-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "ActivitySchedulerTests")!
        defaults.removePersistentDomain(forName: "ActivitySchedulerTests")
        defer { try? FileManager.default.removeItem(at: file) }
        let items = ActivityPlanner.items(events: [event("a", TestClock.local(2026, 10, 14, 12)), event("b", TestClock.local(2026, 10, 14, 15))],
                                          leadMinutes: 30, now: now)
        let entries = try items.map { item in
            try PushToStartRegistrar.event(for: item, attributes: ScheduleActivityAttributes(eventID: item.eventID),
                                           state: LiveActivityStateBuilder.build(for: item.event, events: [], lastLine: nil, asOf: item.triggerAt, clock: clock))
        }
        let token = Data([0xAB, 0x01])
        let first = await PushToStartRegistrar.sync(token: token, upcomingEvents: entries, fileURL: file, defaults: defaults)
        XCTAssertTrue(first)
        let unchanged = await PushToStartRegistrar.sync(token: token, upcomingEvents: entries, fileURL: file, defaults: defaults)
        XCTAssertFalse(unchanged)
        let registration = try XCTUnwrap(PushToStartRegistrar.pending(fileURL: file))
        XCTAssertEqual(registration.token, "ab01")
        XCTAssertEqual(registration.events.map(\.eventID), ["a", "b"])
        // "b" deleted: the registration no longer holds it, so the server cannot start it.
        let replaced = await PushToStartRegistrar.sync(token: token, upcomingEvents: [entries[0]], fileURL: file, defaults: defaults)
        XCTAssertTrue(replaced)
        XCTAssertEqual(PushToStartRegistrar.pending(fileURL: file)?.events.map(\.eventID), ["a"])
        XCTAssertEqual(PushToStartRegistrar.pending(fileURL: file)?.deviceID, registration.deviceID, "same install, same ID")

        // A new process that has not read iOS's token yet keeps the registered one (no clearing upload).
        let tokenNotReadYet = await PushToStartRegistrar.sync(token: nil, upcomingEvents: [entries[0]], fileURL: file, defaults: defaults)
        XCTAssertFalse(tokenNotReadYet)
        XCTAssertEqual(PushToStartRegistrar.pending(fileURL: file)?.token, "ab01")

        // Never restored onto another iPhone with a backup: that phone would take this one's ID.
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
}
