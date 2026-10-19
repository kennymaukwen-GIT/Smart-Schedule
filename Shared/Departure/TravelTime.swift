import Foundation

// Travel time for 「該出發了」 (docs/SETTINGS.md §7.11): the rules, kept pure, and the protocols that hide Apple's map
// service and Core Location. The iPhone implementations are App/Departure/AppleMapsTravelTime.swift and
// App/Departure/DeviceLocation.swift; tests use fakes, so nothing here needs a network or a device.
//
// This folder is compiled into the app and the tests only, never the widget or notification extensions
// (project.yml), and imports neither MapKit nor Core Location (scripts/validate_schema.py check 14).
//
// Nothing here is stored or sent to Gemini or the Smart Schedules server: the location, the starting point, the places
// found and the travel time stay in memory for the one reply.

/// A point on Earth in degrees. Plain numbers, so the rules stay pure; the app turns it into Core Location's type.
struct GeoPoint: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
}

/// Where a trip starts.
enum TravelOrigin: Equatable, Sendable {
    /// Where the iPhone is now (Core Location, When In Use).
    case current(GeoPoint)
    /// A starting point the user typed in the reply card's field. Only Apple's map service sees it, never Gemini.
    case typed(String)
}

/// Which end of the trip a place is.
enum TravelPlace: Equatable, Sendable {
    case destination
    case start
}

/// Why no travel time could be worked out. Each one gets its own reply (step 6).
enum TravelTimeError: Error, Equatable, Sendable {
    /// No location permission: the user said no, location is off, or it is restricted. The reply offers the
    /// starting-point field instead.
    case noPermission
    /// Apple's map service found no such place: the destination, or the starting point the user typed.
    case placeNotFound(TravelPlace)
    /// No route between the two places for this way of travelling.
    case routeUnavailable
    /// More than about 300 km apart in a straight line, or more than 24 hours of travel.
    case tooFar
    /// The map service is busy (too many requests), the network is down, or no location fix came. Try again later.
    case temporarilyUnavailable
}

/// A worked-out travel time.
struct TravelEstimate: Equatable, Sendable {
    /// Whole minutes, rounded up, within `DeparturePlanner.travelMinutesRange`.
    let minutes: Int
    /// The way of travelling the time is for: the user's, or the one chosen for them (`TravelRules.defaultMode`).
    let mode: TravelMode
    /// True when this is a stand-in: a driving time because no public-transport route was found.
    let isEstimate: Bool
    /// Apple's name for the destination it found, if it has one. Apple place data: shown only with the small Apple
    /// map, never kept in chat history, never used for the Google Maps link and never sent to Gemini.
    let placeName: String?
    /// The two ends of the trip, for the small Apple map only. Never stored and never sent anywhere else.
    let start: GeoPoint
    let destination: GeoPoint
}

/// A place Apple's map service found.
struct FoundPlace: Equatable, Sendable {
    /// Apple's name for it, if any.
    let name: String?
    let point: GeoPoint
}

/// Works out how long a trip takes. `TravelTimeService` is the real one; tests use a fake.
protocol TravelTimeProviding: Sendable {
    /// The travel time to `destination` (the text the user typed, or the event's location) from `origin`.
    /// - Parameters:
    ///   - mode: the way of travelling the user asked for, or nil when they didn't say (`TravelRules.defaultMode`).
    ///   - arriveBy: when the user wants to be there, so the estimate accounts for the traffic expected then; nil for
    ///     "how long does it take" (leaving now).
    /// - Throws: `TravelTimeError`, or `CancellationError` when the task was cancelled.
    func estimate(to destination: String, from origin: TravelOrigin, mode: TravelMode?,
                  arriveBy: Date?) async throws -> TravelEstimate
}

/// The iPhone's location. The real one asks for When In Use permission the first time; tests use a fake.
protocol LocationProviding: Sendable {
    /// Where the iPhone is now. Call it only while the app is in the foreground, when the user asked for a departure
    /// or a travel time.
    /// - Throws: `TravelTimeError.noPermission` without permission, `.temporarilyUnavailable` when no fix came.
    func currentLocation() async throws -> GeoPoint
}

/// Apple's map service, reduced to the two questions the feature asks. The real one is MapKit
/// (App/Departure/AppleMapsTravelTime.swift); tests use a fake.
protocol MapsLookup: Sendable {
    /// The best match for `query`, preferring places near `near` when given.
    /// - Throws: `TravelTimeError.placeNotFound(place)` when nothing matches, `.temporarilyUnavailable` otherwise.
    func findPlace(_ query: String, near: GeoPoint?, place: TravelPlace) async throws -> FoundPlace
    /// Seconds of travel from `start` to `destination`, arriving by `arriveBy` (nil: leaving now).
    /// - Throws: `TravelTimeError.routeUnavailable` when there is no route, `.temporarilyUnavailable` otherwise.
    func travelSeconds(from start: GeoPoint, to destination: GeoPoint, mode: TravelMode,
                       arriveBy: Date?) async throws -> TimeInterval
}

/// The travel-time steps on top of a `MapsLookup`:
/// 1. A typed starting point is looked up first; the destination is then looked up near the start.
/// 2. More than about 300 km apart in a straight line → `tooFar`, without asking for a route.
/// 3. The way of travelling is the user's, or public transport, or driving beyond 40 km (`TravelRules.defaultMode`).
/// 4. When the user didn't say and no public-transport route is found, the driving time is used instead and marked
///    as an estimate. A way of travelling the user asked for is never swapped.
/// 5. Seconds become whole minutes, rounded up; more than 24 hours → `tooFar`.
struct TravelTimeService: TravelTimeProviding {
    let maps: any MapsLookup
    var now: @Sendable () -> Date = { Date() }

    func estimate(to destination: String, from origin: TravelOrigin, mode: TravelMode?,
                  arriveBy: Date?) async throws -> TravelEstimate {
        do {
            return try await work(to: destination, from: origin, mode: mode, arriveBy: arriveBy)
        } catch {
            throw TravelRules.normalized(error)
        }
    }

    private func work(to destination: String, from origin: TravelOrigin, mode requested: TravelMode?,
                      arriveBy: Date?) async throws -> TravelEstimate {
        let destinationText = DeparturePlanner.mapsText(destination)
        guard !destinationText.isEmpty else { throw TravelTimeError.placeNotFound(.destination) }

        let start: GeoPoint
        switch origin {
        case .current(let point):
            start = point
        case .typed(let text):
            let startText = DeparturePlanner.mapsText(text)
            guard !startText.isEmpty else { throw TravelTimeError.placeNotFound(.start) }
            start = try await maps.findPlace(startText, near: nil, place: .start).point
        }

        let found = try await maps.findPlace(destinationText, near: start, place: .destination)
        let distance = TravelRules.distanceMeters(start, found.point)
        guard distance <= TravelRules.tooFarMeters else { throw TravelTimeError.tooFar }

        var mode = requested ?? TravelRules.defaultMode(distanceMeters: distance)
        var isEstimate = false
        let arrival = TravelRules.arrivalDate(arriveBy, now: now())
        let seconds: TimeInterval
        do {
            seconds = try await maps.travelSeconds(from: start, to: found.point, mode: mode, arriveBy: arrival)
        } catch TravelTimeError.routeUnavailable where requested == nil && mode == .transit {
            seconds = try await maps.travelSeconds(from: start, to: found.point, mode: .driving, arriveBy: arrival)
            mode = .driving
            isEstimate = true
        }

        guard let minutes = TravelRules.wholeMinutes(seconds: seconds) else {
            throw TravelTimeError.temporarilyUnavailable
        }
        guard minutes <= DeparturePlanner.travelMinutesRange.upperBound else { throw TravelTimeError.tooFar }
        return TravelEstimate(minutes: minutes, mode: mode, isEstimate: isEstimate, placeName: found.name,
                              start: start, destination: found.point)
    }
}

/// The pure travel-time rules (docs/SETTINGS.md §7.11).
enum TravelRules {
    /// No departure plan beyond this straight-line distance (owner decision 2026-10-19: about 300 km).
    static let tooFarMeters: Double = 300_000
    /// When the user didn't say how they travel: public transport up to this straight-line distance, driving beyond.
    static let drivingBeyondMeters: Double = 40_000
    /// How wide an area around the start the destination search prefers.
    static let searchRegionMeters: Double = 50_000
    /// A location the iPhone already has is used when it is at most this old…
    static let recentLocationSeconds: TimeInterval = 120
    /// …and at least this accurate.
    static let recentLocationAccuracyMeters: Double = 1_000
    /// How long to wait for a location fix before giving up (`temporarilyUnavailable`).
    static let locationTimeoutSeconds: TimeInterval = 15

    /// Mean Earth radius (IUGG), for the straight-line distance.
    private static let earthRadiusMeters = 6_371_008.8

    /// Straight-line (great-circle) distance in metres.
    static func distanceMeters(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusMeters * asin(min(1, sqrt(max(0, h))))
    }

    /// Public transport, or driving when the places are more than 40 km apart.
    static func defaultMode(distanceMeters: Double) -> TravelMode {
        distanceMeters > drivingBeyondMeters ? .driving : .transit
    }

    /// Travel seconds as whole minutes, rounded up (21 min 1 s → 22); a negative time counts as 0. Nil when the
    /// number is not a time at all (NaN or infinite).
    static func wholeMinutes(seconds: TimeInterval) -> Int? {
        guard seconds.isFinite else { return nil }
        let minutes = (max(seconds, 0) / 60).rounded(.up)
        return minutes > Double(Int32.max) ? Int(Int32.max) : Int(minutes)
    }

    /// The arrival time to ask the map service about: `arriveBy` when it is still ahead, otherwise nil (leaving now).
    static func arrivalDate(_ arriveBy: Date?, now: Date) -> Date? {
        guard let arriveBy, arriveBy > now else { return nil }
        return arriveBy
    }

    /// Whether a location the iPhone already has is fresh and accurate enough to use without asking for a new fix.
    /// A negative accuracy means the location is not valid.
    static func isRecent(ageSeconds: TimeInterval, accuracyMeters: Double) -> Bool {
        ageSeconds >= 0 && ageSeconds <= recentLocationSeconds
            && accuracyMeters >= 0 && accuracyMeters <= recentLocationAccuracyMeters
    }

    /// What the map service was doing when it failed.
    enum MapsStep: Equatable, Sendable {
        case search(TravelPlace)
        case directions
    }

    /// The error for a MapKit failure (`MKError.Code`; nil when the error is not MapKit's, for example no network).
    /// placemarkNotFound (4) and directionsNotFound (5) mean no such place, or no route; unknown (1),
    /// serverFailure (2), loadingThrottled (3), decodingFailed (6) and anything else mean try again later.
    static func error(mapKitCode: Int?, during step: MapsStep) -> TravelTimeError {
        switch (mapKitCode, step) {
        case (4?, .search(let place)), (5?, .search(let place)): .placeNotFound(place)
        case (4?, .directions), (5?, .directions): .routeUnavailable
        default: .temporarilyUnavailable
        }
    }

    /// The error for a Core Location failure (`CLError.Code`): denied (1) means no permission; anything else, such as
    /// no fix (0) or no network (2), means try again later.
    static func locationError(coreLocationCode: Int?) -> TravelTimeError {
        coreLocationCode == 1 ? .noPermission : .temporarilyUnavailable
    }

    /// Every failure as a `TravelTimeError`, except cancellation, which stays as it is.
    static func normalized(_ error: Error) -> Error {
        if error is TravelTimeError || error is CancellationError { return error }
        return TravelTimeError.temporarilyUnavailable
    }
}
