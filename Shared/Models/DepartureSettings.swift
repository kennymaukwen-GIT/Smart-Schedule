import Foundation

/// What an event keeps of its departure reminders 「該出發了」 (docs/SETTINGS.md §7.11): exactly the three values the
/// privacy policy names, in the event's private properties on Google Calendar (`SSProperty.arriveEarly`, `travelMode`,
/// `leaveBefore`). Never a location, starting point, route or separate travel time.
///
/// The departure is kept relative to the start, so when the event moves, its reminders move with it.
struct DepartureSettings: Codable, Hashable, Sendable {
    /// Minutes before the start the user wants to be there.
    var arriveEarlyMinutes: Int
    var travelMode: TravelMode
    /// Minutes before the start to leave: minutes early + travel + margin.
    var leaveMinutesBeforeStart: Int

    /// The longest a departure can be before the start: the most minutes early, travel and margin together.
    static let leaveRange = 0...(DeparturePlanner.arriveEarlyRange.upperBound
                                 + DeparturePlanner.travelMinutesRange.upperBound
                                 + DeparturePlanner.bufferRange.upperBound)

    /// Values are kept in range: minutes early within `DeparturePlanner.arriveEarlyRange`, and leaving no later than
    /// arriving (`leaveMinutesBeforeStart` at least `arriveEarlyMinutes`) and within `leaveRange`.
    init(arriveEarlyMinutes: Int, travelMode: TravelMode, leaveMinutesBeforeStart: Int) {
        let early = min(max(arriveEarlyMinutes, DeparturePlanner.arriveEarlyRange.lowerBound),
                        DeparturePlanner.arriveEarlyRange.upperBound)
        self.arriveEarlyMinutes = early
        self.travelMode = travelMode
        self.leaveMinutesBeforeStart = min(max(leaveMinutesBeforeStart, early), Self.leaveRange.upperBound)
    }

    /// When to leave for an event starting at `start`.
    func departAt(start: Date) -> Date {
        start.addingTimeInterval(-TimeInterval(leaveMinutesBeforeStart) * 60)
    }
}
