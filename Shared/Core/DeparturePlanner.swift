import Foundation

/// How the user gets to a departure reminder's destination. The raw value is Google Maps' `travelmode` and what
/// the event's private properties keep.
enum TravelMode: String, CaseIterable, Codable, Sendable {
    case transit
    case driving
    case walking
}

/// One worked-out departure for 「該出發了」: when to be there, when to leave and how long the trip takes.
struct DeparturePlan: Equatable, Sendable {
    /// When the user wants to be there: the event's start minus the minutes early.
    let arriveBy: Date
    /// When to leave: `arriveBy` minus the travel time minus the safety margin.
    let departAt: Date
    /// Whole minutes of travel, within `DeparturePlanner.travelMinutesRange`.
    let travelMinutes: Int
    let travelMode: TravelMode
    /// True when the time is a stand-in, for example a driving estimate because no transit time was found.
    let isEstimate: Bool
}

/// Pure departure arithmetic (docs/SETTINGS.md §7.11). No clock, location or map calls: those sit behind
/// protocols elsewhere, so this runs the same in tests as on the iPhone.
///
/// - arriveBy = start − minutes early
/// - departAt = arriveBy − travel minutes − margin
/// - 「準備出門」 = departAt − lead
///
/// All of it is absolute time. When the clocks change between leaving and arriving (London, 25 Oct 2026), the real
/// gap stays right, even though the two wall-clock times then look closer together or further apart. Every input is
/// clamped first, so a negative or huge number (even `Int.min` or `Int.max`) gives a sensible date and never crashes.
enum DeparturePlanner {
    /// Minutes early: up to 3 hours (owner decision, 2026-10-19).
    static let arriveEarlyRange = 0...180
    /// Travel time: up to 24 hours (owner decision, 2026-10-19).
    static let travelMinutesRange = 0...1_440
    /// The safety margin before leaving. Phase 1 always uses `defaultBufferMinutes`.
    static let bufferRange = 0...180
    static let defaultBufferMinutes = 10
    /// 「準備出門」 comes this many minutes before departure.
    static let readyLeadRange = 0...180
    static let defaultReadyLeadMinutes = 10

    static func plan(start: Date,
                     arriveEarlyMinutes: Int,
                     travelMinutes: Int,
                     bufferMinutes: Int = DeparturePlanner.defaultBufferMinutes,
                     travelMode: TravelMode,
                     isEstimate: Bool) -> DeparturePlan {
        let early = clamp(arriveEarlyMinutes, to: arriveEarlyRange)
        let travel = clamp(travelMinutes, to: travelMinutesRange)
        let buffer = clamp(bufferMinutes, to: bufferRange)
        let arriveBy = start.addingTimeInterval(-seconds(early))
        let departAt = arriveBy.addingTimeInterval(-seconds(travel + buffer))
        return DeparturePlan(arriveBy: arriveBy, departAt: departAt, travelMinutes: travel,
                             travelMode: travelMode, isEstimate: isEstimate)
    }

    /// When 「準備出門」 fires: `leadMinutes` before departure.
    static func readyReminder(for plan: DeparturePlan, leadMinutes: Int = DeparturePlanner.defaultReadyLeadMinutes) -> Date {
        plan.departAt.addingTimeInterval(-seconds(clamp(leadMinutes, to: readyLeadRange)))
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func seconds(_ minutes: Int) -> TimeInterval {
        TimeInterval(minutes) * 60
    }
}
