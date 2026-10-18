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

    // MARK: Updates of a running activity

    /// Every pass rebuilds the content; a running activity is updated only when what it shows changed: its event or
    /// what comes after it ("Up next", the place), not the build time, the assistant's line or the week digest.
    func testRunningActivityIsUpdatedOnlyWhenWhatItShowsChanges() {
        let meeting = event("m", TestClock.local(2026, 10, 14, 10, 30), title: "Design review")
        let lunch = event("lunch", TestClock.local(2026, 10, 14, 12), title: "Lunch")
        let call = event("call", TestClock.local(2026, 10, 14, 13), title: "Call Ann")
        let review = event("review", TestClock.local(2026, 10, 14, 14), title: "Review")
        let gym = event("gym", TestClock.local(2026, 10, 14, 18), title: "Gym")
        let friday = event("friday", TestClock.local(2026, 10, 16, 9), title: "Dentist")
        let events = [meeting, lunch, call, review, gym, friday]
        let now = self.now
        let clock = self.clock
        func state(_ events: [ScheduleEvent], at time: Date? = nil, lastLine: String? = "Added: Lunch") -> ScheduleActivityAttributes.ContentState {
            LiveActivityStateBuilder.build(for: meeting, events: events, lastLine: lastLine, asOf: time ?? now, clock: clock)
        }
        let shown = state(events, at: now.addingTimeInterval(-300))
        func needsUpdate(_ fresh: ScheduleActivityAttributes.ContentState, staleDate: Date? = nil) -> Bool {
            ActivityPlanner.needsUpdate(shown: shown, shownStaleDate: meeting.start,
                                        fresh: fresh, freshStaleDate: staleDate ?? meeting.start)
        }
        XCTAssertEqual(shown.upNext?.map(\.title), ["Lunch", "Call Ann", "Review"])
        XCTAssertEqual(shown.upNextMore, 1)

        XCTAssertFalse(needsUpdate(state(events)), "built again five minutes later: only the build time differs")
        XCTAssertFalse(needsUpdate(state(events, lastLine: "Added: Gym")), "the assistant's line is not shown")
        var movedFriday = friday
        movedFriday.title = "Dentist (moved)"
        XCTAssertFalse(needsUpdate(state([meeting, lunch, call, review, gym, movedFriday])), "only in the week digest")
        var renamedGym = gym
        renamedGym.title = "Evening gym"
        XCTAssertFalse(needsUpdate(state([meeting, lunch, call, review, renamedGym, friday])), "counted in +1, not shown")

        let added = event("dentist", TestClock.local(2026, 10, 14, 15), title: "Dentist")
        XCTAssertTrue(needsUpdate(state(events + [added])), "a new event later today: +2")
        var renamedLunch = lunch
        renamedLunch.title = "Lunch with Andrew"
        XCTAssertTrue(needsUpdate(state([meeting, renamedLunch, call, review, gym, friday])), "a shown row renamed")
        XCTAssertTrue(needsUpdate(state([meeting, call, review, gym, friday])), "a shown row deleted")
        var placed = meeting
        placed.location = "Room 4"
        XCTAssertTrue(needsUpdate(LiveActivityStateBuilder.build(for: placed, events: events, lastLine: nil, asOf: now, clock: clock)),
                      "the place under the headline")
        XCTAssertTrue(needsUpdate(state(events), staleDate: meeting.end), "the stale date moved")
        let underway = state(events, at: TestClock.local(2026, 10, 14, 10, 45))
        XCTAssertTrue(needsUpdate(underway), "under way: counts to the end")
    }

    /// A scheduled (iOS 26 pending) activity cannot be updated: it is replaced when "Up next" or the place it was
    /// scheduled with (as of its trigger) no longer matches, and kept otherwise.
    func testScheduledActivityComparesWhatComesAfterTheEvent() {
        let clock = self.clock
        let meeting = event("m", TestClock.local(2026, 10, 15, 9), title: "Design review")
        let lunch = event("lunch", TestClock.local(2026, 10, 15, 12), title: "Lunch")
        let item = ActivityPlanner.items(events: [meeting, lunch], leadMinutes: 30, now: now)[0]
        let scheduled = LiveActivityStateBuilder.build(for: meeting, events: [meeting, lunch], lastLine: nil,
                                                       asOf: item.triggerAt, clock: clock)
        func planned(_ events: [ScheduleEvent], lastLine: String? = nil) -> ScheduleActivityAttributes.ContentState {
            LiveActivityStateBuilder.build(for: meeting, events: events, lastLine: lastLine, asOf: item.triggerAt, clock: clock)
        }
        XCTAssertTrue(scheduled.hasSameUpNext(as: planned([meeting, lunch], lastLine: "Added: Lunch")))
        XCTAssertFalse(scheduled.hasSameUpNext(as: planned([meeting, lunch, event("gym", TestClock.local(2026, 10, 15, 18))])))
        XCTAssertFalse(scheduled.hasSameUpNext(as: planned([meeting])), "Lunch deleted: \"Nothing else today\"")
        let taipei = WallClock(timeZone: TimeZone(identifier: "Asia/Taipei")!)
        XCTAssertFalse(scheduled.hasSameUpNext(as: LiveActivityStateBuilder.build(for: meeting, events: [meeting, lunch], lastLine: nil,
                                                                                 asOf: item.triggerAt, clock: taipei)),
                       "times shown in another zone")
    }

    // MARK: Push-to-start (iOS 18)

    /// Off (version 1.0, `AppConstants.pushToStartEnabled`): a pass asks iOS for no push-to-start token and registers,
    /// uploads or clears nothing, on iOS 18 and 26 alike. On: iOS 18 registers, iOS 26 only clears what an iOS 18
    /// registration left on the server.
    func testPushToStartOffAsksForNoTokenAndSendsNothing() {
        XCTAssertEqual(ActivityPlanner.pushToStartStep(enabled: false, schedulesOnDevice: false), .off)
        XCTAssertEqual(ActivityPlanner.pushToStartStep(enabled: false, schedulesOnDevice: true), .off)
        XCTAssertEqual(ActivityPlanner.pushToStartStep(enabled: true, schedulesOnDevice: false), .register)
        XCTAssertEqual(ActivityPlanner.pushToStartStep(enabled: true, schedulesOnDevice: true), .clearServer)
    }

    func testPushToStartCarriesWhatActivityKitDecodesAndNothingElse() throws {
        var trip = event("ev1", TestClock.local(2026, 10, 15, 9), title: "Flight to Tokyo")
        trip.location = "Terminal 2"
        trip.notes = "Bring passport"
        let item = ActivityPlanner.items(events: [trip], leadMinutes: 15, now: now)[0]
        // Even when handed the assistant's last reply, the registration never carries it to the server.
        var state = LiveActivityStateBuilder.build(for: trip, events: [trip], lastLine: "Added: Dentist · Fri 10:00",
                                                   asOf: item.triggerAt, clock: clock)
        XCTAssertEqual(state.location, "Terminal 2", "the island shows the place")
        let entry = try PushToStartRegistrar.event(for: item, attributes: ScheduleActivityAttributes(eventID: "ev1"), state: state)
        XCTAssertFalse(entry.contentStateJSON.contains("Dentist"), entry.contentStateJSON)
        // Neither the place nor the time zone (roughly where the person is) goes to the server.
        state.lastAssistantLine = nil
        state.location = nil
        state.timeZoneIdentifier = nil
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
        XCTAssertFalse(everything.contains("London"), "no time zone")
    }

    /// "Up next" titles are short, but a character can be many Unicode scalars: capped like the headline.
    func testPushToStartCapsUpNextTitles() throws {
        let meeting = event("m", TestClock.local(2026, 10, 15, 9))
        // 28 characters of 11 scalars each: 308 scalars.
        let stacked = String(repeating: "e" + String(repeating: "\u{301}", count: 10), count: 28)
        let later = event("later", TestClock.local(2026, 10, 15, 11), title: stacked)
        let item = ActivityPlanner.items(events: [meeting, later], leadMinutes: 30, now: now)[0]
        let state = LiveActivityStateBuilder.build(for: meeting, events: [meeting, later], lastLine: nil, asOf: item.triggerAt, clock: clock)
        XCTAssertEqual(state.upNext?.first?.title.unicodeScalars.count, 308)
        let entry = try PushToStartRegistrar.event(for: item, attributes: ScheduleActivityAttributes(eventID: "m"), state: state)
        let decoded = try JSONDecoder().decode(ScheduleActivityAttributes.ContentState.self, from: Data(entry.contentStateJSON.utf8))
        XCTAssertEqual(decoded.upNext?.first?.title.unicodeScalars.count, PushToStartRegistrar.maxTitleScalars)
        XCTAssertEqual(decoded.upNext?.first?.start, TestClock.local(2026, 10, 15, 11))
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
        XCTAssertEqual(decoded.headline, state.headline, "the pushed headline is the island's, already cut to 80 characters")
        XCTAssertEqual(decoded.headline.count, LiveActivityStateBuilder.headlineLength)
        // Counted in Unicode scalars, as the server counts (JavaScript's Array.from): an emoji family is five.
        let families = String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 50)
        XCTAssertEqual(PushToStartRegistrar.capped(families).unicodeScalars.count, 200)
        // 80 characters of five scalars each are still more than the server takes: the pushed headline is cut too.
        let family = event("f", TestClock.local(2026, 10, 15, 9), title: families + families)
        let familyItem = ActivityPlanner.items(events: [family], leadMinutes: 30, now: now)[0]
        let familyState = LiveActivityStateBuilder.build(for: family, events: [family], lastLine: nil,
                                                         asOf: familyItem.triggerAt, clock: clock)
        let familyEntry = try PushToStartRegistrar.event(for: familyItem, attributes: ScheduleActivityAttributes(eventID: "f"),
                                                         state: familyState)
        let pushed = try JSONDecoder().decode(ScheduleActivityAttributes.ContentState.self,
                                              from: Data(familyEntry.contentStateJSON.utf8))
        XCTAssertEqual(pushed.headline.unicodeScalars.count, PushToStartRegistrar.maxTitleScalars)
        XCTAssertTrue(familyState.headline.hasPrefix(pushed.headline))
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
        expected.location = nil
        expected.timeZoneIdentifier = nil
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
