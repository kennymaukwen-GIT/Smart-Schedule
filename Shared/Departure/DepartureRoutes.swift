import Foundation

// Routes from Google for 「該出發了」 (docs/SETTINGS.md §7.11), through the Smart Schedules server
// (server/worker, `POST /v1/departure/routes`): the request the app sends, what comes back, and what each answer means.
// Pure Foundation, so building and reading are tested without a network or a device; `WorkerDepartureRoutes` sends it.
//
// The server works out when to leave (it may ask Google up to three times for a drive) and keeps the free limits; the
// app only builds the request and reads the answer. Tests/fixtures/departure holds the samples both sides are tested
// against, so the two can't drift apart.
//
// Nothing here is stored or sent to Gemini: the starting point, the destination and the route stay in memory for the
// one reply (build steps G4 and G5 show them).

/// How the user travels, as the server knows it. `twoWheeler` is a scooter or motorbike (Google's TWO_WHEELER).
enum RouteMode: String, CaseIterable, Equatable, Sendable {
    case transit
    case drive
    case walk
    case twoWheeler = "two_wheeler"

    init(_ mode: TravelMode) {
        switch mode {
        case .transit: self = .transit
        case .driving: self = .drive
        case .walking: self = .walk
        case .scooter: self = .twoWheeler
        }
    }
}

extension TravelMode {
    /// The way of travelling a route from the server is for, as the app keeps it.
    init(_ mode: RouteMode) {
        switch mode {
        case .transit: self = .transit
        case .drive: self = .driving
        case .walk: self = .walking
        case .twoWheeler: self = .scooter
        }
    }
}

/// One request for a route: where from, where to, and when the user must be there.
struct DepartureRouteRequest: Equatable, Sendable {
    var mode: RouteMode
    /// The iPhone's location, or a starting point the user typed.
    var origin: TravelOrigin
    /// The event's place as the user wrote it.
    var destination: String
    /// When the user must be there (the event's start minus the minutes early). nil: leaving now ("how long").
    var arriveBy: Date?
    /// The token of an earlier answer for the same trip (same destination and arrival): a free recheck.
    var plan: String?
    /// The user's UTC offset, so the week of free plans starts on their Monday.
    var utcOffsetMinutes: Int
    /// The language of Google's text (line names, directions): "zh-TW" or "en".
    var language: String?
    /// Google's region bias, a ccTLD ("tw", "uk").
    var region: String?
    /// True only in Debug builds installed from Xcode (more plans a week for testing, and the owner's test with a typed
    /// starting point where the feature is otherwise off). Release builds always send false (the field is left out).
    var debugBuild: Bool = false

    /// The server's limits (server/worker/src/departure.ts): places of at most 200 characters (Unicode scalars, after
    /// runs of spaces are folded), an arrival at most 100 days ahead and no more than a minute ago.
    static let maxPlaceLength = 200
    static let maxAhead: TimeInterval = 100 * 86_400
    static let pastSlack: TimeInterval = 60
    /// A plan token: 32 random bytes, base64url without padding.
    static let planTokenLength = 43

    /// The request as the server checks it, or `DepartureRouteError.invalidRequest`: places folded to one line and
    /// trimmed, a real point, an arrival in range, a well-formed plan token.
    func validated(now: Date) throws -> DepartureRouteRequest {
        var checked = self
        guard let destination = Self.place(destination) else { throw DepartureRouteError.invalidRequest }
        checked.destination = destination
        switch origin {
        case let .current(point):
            guard point.isValid else { throw DepartureRouteError.invalidRequest }
        case let .typed(text):
            guard let start = Self.place(text) else { throw DepartureRouteError.invalidRequest }
            checked.origin = .typed(start)
        }
        if let arriveBy {
            let ahead = arriveBy.timeIntervalSince(now)
            guard ahead >= -Self.pastSlack, ahead <= Self.maxAhead else { throw DepartureRouteError.invalidRequest }
        }
        if let plan, !Self.isPlanToken(plan) { throw DepartureRouteError.invalidRequest }
        guard (-720...840).contains(utcOffsetMinutes) else { throw DepartureRouteError.invalidRequest }
        if let language, language.range(of: #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,2}$"#, options: .regularExpression) == nil {
            checked.language = nil
        }
        if let region, region.range(of: "^[a-z]{2}$", options: .regularExpression) == nil {
            checked.region = nil
        }
        return checked
    }

    /// The JSON body (keys sorted, absent values left out), exactly what the App Attest assertion signs.
    func body() -> Data {
        var json: [String: Any] = [
            "mode": mode.rawValue,
            "destination": ["address": destination],
            "utcOffsetMinutes": utcOffsetMinutes,
        ]
        switch origin {
        case let .current(point):
            json["origin"] = ["lat": Self.coordinate(point.latitude), "lng": Self.coordinate(point.longitude)]
        case let .typed(text):
            json["origin"] = ["address": text]
        }
        if let arriveBy { json["arriveBy"] = Self.iso(arriveBy) }
        if let plan { json["plan"] = plan }
        if let language { json["language"] = language }
        if let region { json["region"] = region }
        if debugBuild { json["debugBuild"] = true }
        // Only strings, numbers, booleans and dictionaries of them: serialization can't fail.
        return (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    // MARK: Pieces

    /// A place on one line (`DeparturePlanner.mapsText`), or nil when it is empty, too long or holds control characters.
    static func place(_ text: String) -> String? {
        let line = DeparturePlanner.mapsText(text.precomposedStringWithCanonicalMapping)
        guard !line.isEmpty, line.unicodeScalars.count <= maxPlaceLength,
              !line.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        return line
    }

    static func isPlanToken(_ text: String) -> Bool {
        text.count == planTokenLength && text.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    /// Degrees rounded to 5 decimals (about a metre): what routing needs, nothing finer.
    static func coordinate(_ degrees: Double) -> Double {
        (degrees * 100_000).rounded() / 100_000
    }

    /// ISO 8601 in UTC, whole seconds ("2026-10-15T09:00:00Z").
    static func iso(_ date: Date) -> String {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)).formatted(.iso8601)
    }

    /// The UTC offset of `zone` at `date`, in minutes, within what the server accepts.
    static func utcOffsetMinutes(_ zone: TimeZone, at date: Date) -> Int {
        min(max(zone.secondsFromGMT(for: date) / 60, -720), 840)
    }

    /// Google's language for the app's language: Traditional Chinese → "zh-TW", anything else → "en".
    static func languageCode(appLanguage: String?) -> String {
        guard let language = appLanguage?.lowercased() else { return "en" }
        return language.hasPrefix("zh") ? "zh-TW" : "en"
    }

    /// Google's region bias from the iPhone's region ("TW" → "tw"). The UK's ccTLD is "uk", not "gb".
    static func regionCode(isoRegion: String?) -> String? {
        guard let region = isoRegion, region.range(of: "^[A-Za-z]{2}$", options: .regularExpression) != nil else { return nil }
        let code = region.lowercased()
        return code == "gb" ? "uk" : code
    }
}

// MARK: - Answer

/// A route the server worked out.
struct DepartureRoute: Equatable, Sendable {
    let mode: RouteMode
    /// When to leave: always a time Google confirmed arrives in time, unless `late` or `estimate`.
    let departAt: Date
    let arriveAt: Date
    /// Even leaving now arrives after the time asked for.
    let late: Bool
    /// Google could not confirm this exact departure, or had no live traffic: say it is an estimate.
    let estimate: Bool
    /// For a free recheck of the same trip; nil when the server couldn't keep the plan.
    let plan: String?
    /// New plans left this week.
    let plansLeft: Int
    let summary: RouteSummary
}

/// What the app shows of Google's route (build step G5), read from the route as the server passes it on.
struct RouteSummary: Equatable, Sendable {
    /// Google's own text in the request's language ("25 分鐘", "5.4 公里", "NT$25").
    var durationText: String?
    var distanceText: String?
    var fareText: String?
    var durationSeconds: Int?
    var distanceMeters: Int?
    /// For a drive: the main road ("國道1號").
    var description: String?
    /// Google's warnings, shown with the route ("此路線有收費路段").
    var warnings: [String]
    var segments: [RouteSegment]
}

/// A stretch of the trip: one ride on a vehicle, or a run of walking, driving or riding.
struct RouteSegment: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case walk
        case transit(TransitRide)
        case drive
        case twoWheeler
        case bicycle
        case other
    }

    var kind: Kind
    /// Without traffic, as Google gives it for each step.
    var seconds: Int?
    var meters: Int?
    /// Google's directions for the steps, in order ("往東走信義路五段").
    var instructions: [String]
}

/// One ride on public transport.
struct TransitRide: Equatable, Sendable {
    var lineName: String?
    /// The line's number or short name ("R", "307").
    var lineShortName: String?
    /// Google's vehicle type ("SUBWAY", "BUS", "HIGH_SPEED_TRAIN") and its own name for it ("捷運").
    var vehicleType: String?
    var vehicleName: String?
    /// Where the vehicle is heading ("象山").
    var headsign: String?
    var agency: String?
    /// The line's colours ("#e3002c").
    var color: String?
    var textColor: String?
    var departureStop: String?
    var arrivalStop: String?
    var departureTime: Date?
    var arrivalTime: Date?
    /// Google's local time text ("下午4:36").
    var departureTimeText: String?
    var arrivalTimeText: String?
    /// Stops ridden, the arrival stop included.
    var stopCount: Int?
}

enum DepartureRouteResult: Equatable, Sendable {
    case route(DepartureRoute)
    /// Google found both places but no way there by this mode (or none from here by scooter).
    case noRoute(plansLeft: Int)
    /// Google could not find the starting point the user typed, or the destination.
    case placeNotFound(TravelPlace, plansLeft: Int)
}

/// Why there is no answer. Each one gets its own reply (build step G4).
enum DepartureRouteError: Error, Equatable, Sendable {
    /// Not offered here: the EEA, Switzerland or the UK, or a network whose country can't be told.
    case regionUnavailable
    /// This week's free plans are used up; they come back on the user's Monday.
    case weeklyLimit(retryAfter: TimeInterval?)
    /// This trip was rechecked as often as it may be.
    case recheckLimit
    /// The plan token is unknown, expired or for another trip: plan it afresh.
    case invalidPlan
    /// Today's free routes for everyone are used up (「今天的規劃額度已用完，明天再試」).
    case dailyCapacity(retryAfter: TimeInterval?)
    /// This user's share of today's routes is used up.
    case userDailyLimit(retryAfter: TimeInterval?)
    /// Too many requests for a moment, or the server's counts were busy: try again shortly.
    case busy(retryAfter: TimeInterval?)
    /// The server or Google could not answer, the network failed, or the answer made no sense.
    case unavailable
    /// The server isn't set up for routes yet (no server, an older server, no Google key).
    case notReady
    /// The server couldn't verify this copy of the app (App Attest).
    case unverified
    /// The request was wrong (an empty place, a time out of range).
    case invalidRequest
}

/// Every case bridges to the same `NSError` (one domain, code 0), so an error's text can't reveal a reason to Gemini
/// ("not available here" says where the user is). Build step G4 answers each case itself.
extension DepartureRouteError: CustomNSError {
    static var errorDomain: String { "SmartSchedule.DepartureRoutes" }
    var errorCode: Int { 0 }
}

/// Reads the server's answers. Pure: a status, a body and a Retry-After in, a result or an error out.
enum DepartureRouteReader {
    static func result(status: Int, body: Data, retryAfter: TimeInterval?) throws -> DepartureRouteResult {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        guard (200..<300).contains(status) else {
            throw error(status: status, code: json?["error"] as? String, retryAfter: retryAfter)
        }
        guard let json else { throw DepartureRouteError.unavailable }
        return try answer(json)
    }

    /// What a refusal means. Codes from server/worker/src/departure.ts, auth.ts and ratelimit.ts.
    static func error(status: Int, code: String?, retryAfter: TimeInterval?) -> DepartureRouteError {
        switch code {
        case "region_unavailable": return .regionUnavailable
        case "weekly_limit": return .weeklyLimit(retryAfter: retryAfter)
        case "recheck_limit": return .recheckLimit
        case "invalid_plan": return .invalidPlan
        case "capacity_reached": return .dailyCapacity(retryAfter: retryAfter)
        case "user_daily_limit": return .userDailyLimit(retryAfter: retryAfter)
        case "rate_limited", "server_busy": return .busy(retryAfter: retryAfter)
        case "server_misconfigured": return .notReady
        case "invalid_request", "payload_too_large": return .invalidRequest
        case "attestation_required", "unknown_key", "invalid_assertion", "stale_counter", "invalid_attestation",
             "invalid_session":
            return .unverified
        case "upstream_unavailable": return .unavailable
        default:
            // An older server without the route answers 404 not_found (or 405): it isn't set up for routes yet.
            if status == 404 || status == 405 { return .notReady }
            if status == 429 || status == 503 { return .busy(retryAfter: retryAfter) }
            return .unavailable
        }
    }

    /// What a failure to reach the server or to prove the app means (`AttestedRequest` throws `AttestationError`).
    static func error(attestation: AttestationError) -> DepartureRouteError {
        switch attestation {
        case .unsupported, .attestationRejected, .deviceCheck, .sessionMissing: .unverified
        case .notConfigured, .serverNotReady, .updateRequired: .notReady
        case .rateLimited: .busy(retryAfter: nil)
        // Only the server's daily cap on new installs attesting from one network: until the next UTC day.
        case .dailyLimit: .userDailyLimit(retryAfter: nil)
        case .server, .malformed: .unavailable
        }
    }

    /// A 200 answer.
    static func answer(_ json: [String: Any]) throws -> DepartureRouteResult {
        let plansLeft = int(json["plansLeft"]) ?? 0
        switch json["result"] as? String {
        case "no_route":
            return .noRoute(plansLeft: plansLeft)
        case "place_not_found":
            return .placeNotFound(json["place"] as? String == "origin" ? .start : .destination, plansLeft: plansLeft)
        case "ok":
            guard let mode = (json["mode"] as? String).flatMap(RouteMode.init(rawValue:)),
                  let departAt = date(json["departAt"]), let arriveAt = date(json["arriveAt"]) else {
                throw DepartureRouteError.unavailable
            }
            let plan = (json["plan"] as? String).flatMap { DepartureRouteRequest.isPlanToken($0) ? $0 : nil }
            return .route(DepartureRoute(mode: mode, departAt: departAt, arriveAt: arriveAt,
                                         late: json["late"] as? Bool ?? false,
                                         estimate: json["estimate"] as? Bool ?? false,
                                         plan: plan, plansLeft: plansLeft,
                                         summary: summary(json["route"] as? [String: Any] ?? [:])))
        default:
            throw DepartureRouteError.unavailable
        }
    }

    /// Google's route (ComputeRoutesResponse.routes[0], camelCase JSON). Every field may be missing.
    static func summary(_ route: [String: Any]) -> RouteSummary {
        let localized = route["localizedValues"] as? [String: Any]
        let steps = (route["legs"] as? [[String: Any]] ?? []).flatMap { $0["steps"] as? [[String: Any]] ?? [] }
        return RouteSummary(durationText: text(localized?["duration"]),
                            distanceText: text(localized?["distance"]),
                            fareText: text(localized?["transitFare"]),
                            durationSeconds: seconds(route["duration"]),
                            distanceMeters: int(route["distanceMeters"]),
                            description: nonEmpty(route["description"] as? String),
                            warnings: (route["warnings"] as? [Any] ?? []).compactMap { nonEmpty($0 as? String) },
                            segments: segments(steps))
    }

    /// Steps grouped for display: every vehicle ride is its own segment; a run of steps of the same other kind
    /// (walking, driving, riding) becomes one, with its time and distance added up.
    static func segments(_ steps: [[String: Any]]) -> [RouteSegment] {
        var result: [RouteSegment] = []
        for step in steps {
            let instruction = nonEmpty((step["navigationInstruction"] as? [String: Any])?["instructions"] as? String)
            let kind = Self.kind(of: step)
            let segment = RouteSegment(kind: kind, seconds: seconds(step["staticDuration"]),
                                       meters: int(step["distanceMeters"]), instructions: instruction.map { [$0] } ?? [])
            if case .transit = kind {
                result.append(segment)
                continue
            }
            if var last = result.last, last.kind == kind {
                last.seconds = sum(last.seconds, segment.seconds)
                last.meters = sum(last.meters, segment.meters)
                last.instructions += segment.instructions
                result[result.count - 1] = last
            } else {
                result.append(segment)
            }
        }
        return result
    }

    private static func kind(of step: [String: Any]) -> RouteSegment.Kind {
        switch step["travelMode"] as? String {
        case "WALK": return .walk
        case "DRIVE": return .drive
        case "TWO_WHEELER": return .twoWheeler
        case "BICYCLE": return .bicycle
        case "TRANSIT": return .transit(ride(step["transitDetails"] as? [String: Any] ?? [:]))
        default: return .other
        }
    }

    private static func ride(_ details: [String: Any]) -> TransitRide {
        let stops = details["stopDetails"] as? [String: Any]
        let times = details["localizedValues"] as? [String: Any]
        let line = details["transitLine"] as? [String: Any]
        let vehicle = line?["vehicle"] as? [String: Any]
        let agencies = line?["agencies"] as? [[String: Any]]
        return TransitRide(lineName: nonEmpty(line?["name"] as? String),
                           lineShortName: nonEmpty(line?["nameShort"] as? String),
                           vehicleType: nonEmpty(vehicle?["type"] as? String),
                           vehicleName: text(vehicle?["name"]),
                           headsign: nonEmpty(details["headsign"] as? String),
                           agency: nonEmpty(agencies?.first?["name"] as? String),
                           color: nonEmpty(line?["color"] as? String),
                           textColor: nonEmpty(line?["textColor"] as? String),
                           departureStop: nonEmpty((stops?["departureStop"] as? [String: Any])?["name"] as? String),
                           arrivalStop: nonEmpty((stops?["arrivalStop"] as? [String: Any])?["name"] as? String),
                           departureTime: date(stops?["departureTime"]),
                           arrivalTime: date(stops?["arrivalTime"]),
                           departureTimeText: text((times?["departureTime"] as? [String: Any])?["time"]),
                           arrivalTimeText: text((times?["arrivalTime"] as? [String: Any])?["time"]),
                           stopCount: int(details["stopCount"]))
    }

    // MARK: Values

    /// Google's LocalizedText: {"text": "…", "languageCode": "…"}.
    private static func text(_ value: Any?) -> String? {
        nonEmpty((value as? [String: Any])?["text"] as? String)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// A whole, non-negative number (JSON numbers arrive as NSNumber; Google writes int64 values as strings).
    static func int(_ value: Any?) -> Int? {
        if let string = value as? String, let n = Int(string), n >= 0 { return n }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double.rounded() == double, double <= Double(Int32.max) else { return nil }
        return Int(double)
    }

    /// Seconds of a protobuf Duration as JSON ("1234s", "12.5s").
    static func seconds(_ value: Any?) -> Int? {
        guard let text = value as? String, text.hasSuffix("s"), let seconds = Double(text.dropLast()),
              seconds.isFinite, seconds >= 0, seconds <= Double(Int32.max) else { return nil }
        return Int(seconds.rounded(.down))
    }

    /// RFC 3339 / ISO 8601, with or without fractional seconds.
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return (try? Date.ISO8601FormatStyle().parse(text))
            ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
    }

    private static func sum(_ a: Int?, _ b: Int?) -> Int? {
        switch (a, b) {
        case let (a?, b?): a + b
        case let (a?, nil): a
        case let (nil, b?): b
        case (nil, nil): nil
        }
    }
}
