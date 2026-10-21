import Foundation

/// What an event keeps of its departure reminders 「該出發了」 (docs/SETTINGS.md §7.11): only the user's own two choices,
/// in the event's private properties on Google Calendar (`SSProperty.arriveEarly`, `travelMode`). Never a location,
/// starting point, route, travel time or the time to leave: those come from Google, whose terms allow no storing of
/// them (owner decision 2026-10-20), so the time to leave stays on the iPhone only, for that event's reminders.
struct DepartureSettings: Codable, Hashable, Sendable {
    /// Minutes before the start the user wants to be there.
    var arriveEarlyMinutes: Int
    var travelMode: TravelMode

    /// The minutes early are kept within `DeparturePlanner.arriveEarlyRange`.
    init(arriveEarlyMinutes: Int, travelMode: TravelMode) {
        self.arriveEarlyMinutes = min(max(arriveEarlyMinutes, DeparturePlanner.arriveEarlyRange.lowerBound),
                                      DeparturePlanner.arriveEarlyRange.upperBound)
        self.travelMode = travelMode
    }

    /// When the user wants to be there for an event starting at `start`.
    func arriveBy(start: Date) -> Date {
        start.addingTimeInterval(-TimeInterval(arriveEarlyMinutes) * 60)
    }
}
