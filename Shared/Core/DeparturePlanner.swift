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

    /// What the event keeps of `plan` for an event starting at `start` (the plan's minutes early and its departure,
    /// both counted back from the start). Never the travel time itself.
    static func settings(for plan: DeparturePlan, start: Date) -> DepartureSettings {
        DepartureSettings(arriveEarlyMinutes: wholeMinutes(start.timeIntervalSince(plan.arriveBy)),
                          travelMode: plan.travelMode,
                          leaveMinutesBeforeStart: wholeMinutes(start.timeIntervalSince(plan.departAt)))
    }

    /// When 「準備出門」 fires: `leadMinutes` before departure.
    static func readyReminder(for plan: DeparturePlan, leadMinutes: Int = DeparturePlanner.defaultReadyLeadMinutes) -> Date {
        plan.departAt.addingTimeInterval(-seconds(clamp(leadMinutes, to: readyLeadRange)))
    }

    // MARK: Google Maps

    /// Google's limit for a Maps URL: "URLs are limited to 2,048 characters for each request."
    static let googleMapsURLLimit = 2_048

    /// What a query value keeps as it is (RFC 3986 "unreserved"). Everything else is percent-encoded as UTF-8, so a space,
    /// & # + = ? / , ' or a Chinese place name can't split or end the destination.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    /// C0 and C1 control characters (tabs included). Not `.controlCharacters`, which also holds the joiners inside
    /// emoji such as 👨‍👩‍👧.
    private static let controls = CharacterSet(charactersIn: Unicode.Scalar(UInt8(0x00))...Unicode.Scalar(UInt8(0x1F)))
        .union(CharacterSet(charactersIn: Unicode.Scalar(UInt8(0x7F))...Unicode.Scalar(UInt8(0x9F))))

    /// Directions in Google Maps (the app when installed, otherwise the website) to `destination`: the text as the user
    /// typed it or as the event's location has it, put on one line (`mapsText`) and, past Google's 2,048-character
    /// limit, cut short at a whole character. Never coordinates, Apple's place data or a starting point
    /// (docs/SETTINGS.md §7.11), so there is no `origin`: Google Maps usually starts from the device's location and
    /// otherwise asks for a starting point. `dir_action=navigate` starts turn-by-turn navigation right away (owner
    /// decision 2026-10-19: 「出發」 starts navigating); Google shows the route instead where navigation isn't available
    /// ("in those cases this parameter will be ignored"), for example in a browser or on some transit routes. Callers
    /// pass a non-empty place; an empty one opens an empty directions form.
    /// Google's format: https://www.google.com/maps/dir/?api=1&destination=…&travelmode=…&dir_action=navigate
    static func googleMapsURL(destination: String, mode: TravelMode) -> URL {
        let prefix = "https://www.google.com/maps/dir/?api=1&destination="
        let suffix = "&travelmode=\(mode.rawValue)&dir_action=navigate"
        let budget = googleMapsURLLimit - prefix.count - suffix.count
        var encoded = ""
        var length = 0
        for character in mapsText(destination) {
            // Percent-encoding works character by character, so the pieces add up to the whole.
            let piece = String(character).addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
            guard length + piece.count <= budget else { break }
            encoded += piece
            length += piece.count
        }
        // Only unreserved ASCII and %XX escapes go in, so the string is always a valid URL.
        return URL(string: prefix + encoded + suffix)!
    }

    /// A place as one line for Google Maps: each line trimmed, empty lines dropped, lines joined with ", " (calendar
    /// locations are often "Name" and "Address" on two lines), and every other run of spaces, tabs or control
    /// characters made one space. Nothing else changes.
    static func mapsText(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { line in
                line.components(separatedBy: CharacterSet.whitespaces.union(controls))
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func wholeMinutes(_ interval: TimeInterval) -> Int {
        Int((interval / 60).rounded())
    }

    private static func seconds(_ minutes: Int) -> TimeInterval {
        TimeInterval(minutes) * 60
    }
}
