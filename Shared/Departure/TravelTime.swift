import Foundation

// The trip's ends and the iPhone's location for 「該出發了」 (docs/SETTINGS.md §7.11): plain types and the protocol that
// hides Core Location. The iPhone implementation is App/Departure/DeviceLocation.swift; tests use a fake, so nothing
// here needs a device. Travel times come from Google through the Smart Schedules server (DepartureRoutes.swift).
//
// This folder is compiled into the app and the tests only, never the widget or notification extensions
// (project.yml), and imports neither MapKit nor Core Location (scripts/validate_schema.py check 14).
//
// Nothing here is stored or sent to Gemini: the location and the starting point stay in memory for the one request.

/// A point on Earth in degrees. Plain numbers, so the rules stay pure; the app turns Core Location's type into it.
struct GeoPoint: Equatable, Sendable {
    var latitude: Double
    var longitude: Double

    /// A real place: finite degrees, latitude within ±90 and longitude within ±180.
    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180
    }
}

/// Where a trip starts.
enum TravelOrigin: Equatable, Sendable {
    /// Where the iPhone is now (Core Location, When In Use).
    case current(GeoPoint)
    /// A starting point the user gave as text. It goes to Google through the Smart Schedules server, never to Gemini
    /// from the app.
    case typed(String)
}

/// Which end of the trip a place is.
enum TravelPlace: Equatable, Sendable {
    case destination
    case start
}

/// Why the iPhone's location could not be used.
enum TravelTimeError: Error, Equatable, Sendable {
    /// No location permission: the user said no, location is off, or it is restricted.
    case noPermission
    /// No location fix came in time. Try again later.
    case temporarilyUnavailable
}

/// Every case bridges to the same `NSError` (one domain, code 0), so a generic error message can't tell the reasons
/// apart. ScheduleAssistant's catch-all sends `localizedDescription` to Gemini, and Gemini must never learn why a
/// departure couldn't be worked out (docs/SETTINGS.md §7.11). The assistant answers each case itself.
extension TravelTimeError: CustomNSError {
    static var errorDomain: String { "SmartSchedule.TravelTime" }
    var errorCode: Int { 0 }
}

/// The iPhone's location. The real one asks for When In Use permission the first time; tests use a fake.
protocol LocationProviding: Sendable {
    /// Where the iPhone is now. Call it only while the app is in the foreground, when the user asked for a departure
    /// or a travel time.
    /// - Throws: `TravelTimeError.noPermission` without permission, `.temporarilyUnavailable` when no fix came.
    func currentLocation() async throws -> GeoPoint
}

/// The pure location rules (docs/SETTINGS.md §7.11).
enum TravelRules {
    /// A location the iPhone already has is used when it is at most this old…
    static let recentLocationSeconds: TimeInterval = 120
    /// …and at least this accurate.
    static let recentLocationAccuracyMeters: Double = 1_000
    /// How long to wait for a location fix before giving up (`temporarilyUnavailable`).
    static let locationTimeoutSeconds: TimeInterval = 15

    /// Whether a location the iPhone already has is fresh and accurate enough to use without asking for a new fix.
    /// A negative accuracy means the location is not valid.
    static func isRecent(ageSeconds: TimeInterval, accuracyMeters: Double) -> Bool {
        ageSeconds >= 0 && ageSeconds <= recentLocationSeconds
            && accuracyMeters >= 0 && accuracyMeters <= recentLocationAccuracyMeters
    }

    /// The error for a Core Location failure (`CLError.Code`): denied (1) means no permission; anything else, such as
    /// no fix (0) or no network (2), means try again later.
    static func locationError(coreLocationCode: Int?) -> TravelTimeError {
        coreLocationCode == 1 ? .noPermission : .temporarilyUnavailable
    }
}
