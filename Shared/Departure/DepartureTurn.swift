import Foundation

/// The rules of one departure plan for 「該出發了」 (docs/SETTINGS.md §7.11), pure so every case is tested without a
/// network, a location or a clock. The owner's rule (2026-10-20): be there by the start minus the minutes early; ask
/// Google how long the trip takes to arrive then, with that time of day's traffic; that gives when to leave. The reply
/// gives only that time; the route is seen in Google Maps.
///
/// ScheduleAssistant (build step G4d) runs these around one `plan_departure` call: what the plan is for, when to be
/// there, how the user travels, the request, and what Google's answer means.
enum DepartureTurn {
    /// Closer than this, no arrival time is sent and Google plans leaving now. The server refuses an arrival more than
    /// a minute in the past, and the iPhone's clock and the server's may differ a little.
    static let leaveNowWithin: TimeInterval = 120
    /// A trip longer than this is shown but sets no departure reminders (`DeparturePlanner.travelMinutesRange`).
    static let longestTripForReminders: TimeInterval = TimeInterval(DeparturePlanner.travelMinutesRange.upperBound) * 60
    /// Google's arrival may be this much after the time asked for and still count as on time (whole-minute rounding).
    static let onTimeSlack: TimeInterval = 60

    // MARK: What the plan is for

    enum Target: Equatable, Sendable {
        /// An event in UPCOMING or FOCUS: the app reads its place and start (owner decision 1A).
        case existingEvent(id: String)
        /// The event at this index of the turn's create_events call, the one that starts at `arrive_at_local`.
        case newEvent(index: Int)
        /// Be at a place by a time, with no event ("8 點要到台北車站，幾點出門？").
        case arriveBy(destination: String, at: Date)
        /// "How long does it take": leaving now.
        case howLong(destination: String)
        /// Nothing to plan: no event and no place.
        case none
    }

    /// - Parameter newEventStarts: the start of each event in the turn's create_events call, nil for an all-day one,
    ///   in the call's order (empty when the turn creates nothing).
    static func target(_ args: PlanDepartureArgs, newEventStarts: [Date?], clock: WallClock) -> Target {
        if let id = nonBlank(args.eventId) { return .existingEvent(id: id) }
        let arrive = args.arriveAtLocal.flatMap(clock.dateTime)
        if args.createEvent == true, let arrive, let index = newEventStarts.firstIndex(where: { $0 == arrive }) {
            return .newEvent(index: index)
        }
        guard let destination = nonBlank(args.destination) else { return .none }
        if let arrive { return .arriveBy(destination: destination, at: arrive) }
        return .howLong(destination: destination)
    }

    // MARK: When to be there

    enum Arrival: Equatable, Sendable {
        /// The time to be there has passed: nothing is sent and no plan is used.
        case passed
        /// Less than two minutes away: plan leaving now, with no arrival sent, and say how late that arrives.
        case leaveNow(target: Date)
        /// Ask Google to arrive by this time.
        case by(Date)

        /// The time to be there, nil when it has passed.
        var target: Date? {
            switch self {
            case .passed: nil
            case let .leaveNow(target): target
            case let .by(target): target
            }
        }

        /// What the request sends as its arrival: nil to leave now.
        var arriveBy: Date? {
            if case let .by(date) = self { return date }
            return nil
        }
    }

    /// Be there `arriveEarlyMinutes` before `start`.
    static func arrival(start: Date, arriveEarlyMinutes: Int, now: Date) -> Arrival {
        let early = min(max(arriveEarlyMinutes, DeparturePlanner.arriveEarlyRange.lowerBound),
                        DeparturePlanner.arriveEarlyRange.upperBound)
        let target = start.addingTimeInterval(-TimeInterval(early) * 60)
        if target <= now { return .passed }
        if target.timeIntervalSince(now) < leaveNowWithin { return .leaveNow(target: target) }
        return .by(target)
    }

    /// The minutes early the user said this time, else the ones the event keeps, else 10 (owner decision 2026-10-20).
    static func arriveEarlyMinutes(said: Int?, kept: Int?) -> Int {
        let minutes = said ?? kept ?? DeparturePlanner.defaultArriveEarlyMinutes
        return min(max(minutes, DeparturePlanner.arriveEarlyRange.lowerBound), DeparturePlanner.arriveEarlyRange.upperBound)
    }

    // MARK: How the user travels

    struct ModeChoice: Equatable, Sendable {
        let mode: TravelMode
        /// The user chose it. False when the app chose public transport.
        let saidByUser: Bool
    }

    /// The way of travelling the user said, else the one the event keeps, else public transport. An event keeps
    /// public transport both when the user said it and when the app chose it, and can't tell which, so a kept public
    /// transport counts as the app's choice: it may still fall back to driving.
    static func mode(said: TravelMode?, kept: TravelMode?) -> ModeChoice {
        if let said { return ModeChoice(mode: said, saidByUser: true) }
        if let kept { return ModeChoice(mode: kept, saidByUser: kept != .transit) }
        return ModeChoice(mode: .transit, saidByUser: false)
    }

    /// The one retry when Google finds no route: driving, when the app chose public transport. A way of travelling
    /// the user said is never swapped.
    static func fallback(after choice: ModeChoice) -> TravelMode? {
        !choice.saidByUser && choice.mode == .transit ? .driving : nil
    }

    // MARK: Where from

    enum Start: Equatable, Sendable {
        /// The starting point the user said, as written.
        case typed(String)
        /// The iPhone's location.
        case currentLocation
        /// Debug builds where the feature is otherwise off: only a starting point said in the sentence may be used.
        case needsTypedStart
    }

    static func start(startingPoint: String?, availability: DepartureAvailability) -> Start {
        if let text = nonBlank(startingPoint) { return .typed(text) }
        return availability == .typedStartOnly ? .needsTypedStart : .currentLocation
    }

    // MARK: The request

    static func request(mode: TravelMode, origin: TravelOrigin, destination: String, arrival: Arrival, now: Date,
                        timeZone: TimeZone, appLanguage: String?, isoRegion: String?,
                        debugBuild: Bool) -> DepartureRouteRequest {
        DepartureRouteRequest(mode: RouteMode(mode), origin: origin, destination: destination,
                              arriveBy: arrival.arriveBy, plan: nil,
                              utcOffsetMinutes: DepartureRouteRequest.utcOffsetMinutes(timeZone, at: now),
                              language: DepartureRouteRequest.languageCode(appLanguage: appLanguage),
                              region: DepartureRouteRequest.regionCode(isoRegion: isoRegion), debugBuild: debugBuild)
    }

    // MARK: What Google's answer means

    enum Outcome: Equatable, Sendable {
        /// Leave at this time to be there by the time asked for.
        case leave(at: Date, arriveAt: Date, estimate: Bool)
        /// Even leaving now arrives this many minutes late (owner decision 2026-10-21, B): shown, nothing set.
        case late(arriveAt: Date, minutes: Int)
        /// "How long": leaving now takes this many minutes.
        case trip(minutes: Int, arriveAt: Date, estimate: Bool)
    }

    /// The minutes match the clock times the reply shows (whole minutes, as `ReplyFormatter.clockTime` writes them):
    /// arriving at 16:41:47 for 16:30 is "16:41, about 11 min late".
    /// - Parameter target: the time to be there, nil for "how long".
    static func outcome(_ route: DepartureRoute, target: Date?, now: Date) -> Outcome {
        guard let target else {
            return .trip(minutes: clockMinutes(from: now, to: route.arriveAt), arriveAt: route.arriveAt,
                         estimate: route.estimate)
        }
        if route.late || route.arriveAt.timeIntervalSince(target) > onTimeSlack {
            return .late(arriveAt: route.arriveAt, minutes: max(1, clockMinutes(from: target, to: route.arriveAt)))
        }
        return .leave(at: max(route.departAt, now), arriveAt: route.arriveAt, estimate: route.estimate)
    }

    /// Whether a plan may set departure reminders on an event: a time to leave still ahead, for a trip of at most
    /// 24 hours. Late plans, "how long" and longer trips are only shown.
    static func setsReminders(_ outcome: Outcome, now: Date) -> Bool {
        guard case let .leave(leaveAt, arriveAt, _) = outcome else { return false }
        return leaveAt > now && arriveAt.timeIntervalSince(leaveAt) <= longestTripForReminders
    }

    /// True for a trip too long for reminders (more than 24 hours).
    static func isTooLongForReminders(_ outcome: Outcome) -> Bool {
        guard case let .leave(leaveAt, arriveAt, _) = outcome else { return false }
        return arriveAt.timeIntervalSince(leaveAt) > longestTripForReminders
    }

    // MARK: What Gemini gets

    /// The only answers `plan_departure` gives Gemini: never a place, a time, a travel time, a route or a reason.
    enum Saved: String, Sendable, CaseIterable {
        /// Saved on the event (or queued to be).
        case set
        /// Saved when the user taps Add ("Ask me first").
        case awaitingApproval = "awaiting_user_approval"
        case notSet = "not_set"
    }

    static func functionResult(_ saved: Saved) -> [String: Any] {
        ["ok": true, "departure_reminders": saved.rawValue]
    }

    // MARK: Helpers

    /// Minutes between the two clock times as a reply shows them ("16:00" to "16:25" is 25); never negative.
    static func clockMinutes(from start: Date, to end: Date) -> Int {
        let minutes = (end.timeIntervalSince1970 / 60).rounded(.down) - (start.timeIntervalSince1970 / 60).rounded(.down)
        guard minutes.isFinite else { return 0 }
        return Int(min(max(minutes, 0), Double(Int32.max)))
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
