import Foundation

enum CalendarAPIError: LocalizedError {
    case http(status: Int, reason: String, message: String)

    var errorDescription: String? {
        switch self {
        case let .http(status, reason, message): "Google Calendar \(status) \(reason): \(message)"
        }
    }

    var status: Int {
        switch self { case let .http(status, _, _): status }
    }
}

/// How requests reach Google: the network with the Keychain tokens (`GoogleTransport`), or a stand-in in unit tests.
protocol CalendarTransport: Sendable {
    func accessToken(accountID: String?, forceRefresh: Bool) async throws -> String
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct GoogleTransport: CalendarTransport {
    var tokens: GoogleTokenProvider = .shared

    func accessToken(accountID: String?, forceRefresh: Bool) async throws -> String {
        try await tokens.accessToken(accountID: accountID, forceRefresh: forceRefresh)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

/// What a failed request means for a change made on this iPhone: send it later, wait for Reconnect, or stop trying.
enum CalendarFailure: Equatable, Sendable {
    /// The network or Google did not answer: no connection, a timeout, 5xx or rate limits after the client's own
    /// retries. `offline`: the request never left the iPhone; otherwise it may have reached Google.
    case transport(offline: Bool)
    /// The sign-in: invalid_grant, a 401 after a token refresh, no token for the account.
    case auth
    /// 412: the event changed in Google since the etag the change was based on.
    case conflict
    /// 404 / 410: the event or its calendar is gone.
    case gone
    /// Any other 4xx (no permission, a bad request): sending it again would fail again.
    case rejected

    var isTransport: Bool {
        if case .transport = self { return true }
        return false
    }

    static func of(_ error: Error) -> CalendarFailure {
        if error is CancellationError { return .transport(offline: false) }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .transport(offline: true)
            default:
                return .transport(offline: false)
            }
        }
        if let error = error as? AuthError {
            switch error {
            case let .refreshFailed(reason) where reason != "invalid_grant":
                return .transport(offline: false) // the token endpoint failed, not the grant
            default:
                return .auth
            }
        }
        if case let .http(status, reason, _)? = error as? CalendarAPIError {
            switch status {
            case 0, 429, 500...599: return .transport(offline: false)
            case 401: return .auth
            case 403 where reason.hasSuffix("ateLimitExceeded"): return .transport(offline: false)
            case 404, 410: return .gone
            case 412: return .conflict
            default: return .rejected
            }
        }
        if let error = error as? RouterError {
            switch error {
            case .deletedInGoogle: return .gone
            case .changedInGoogle: return .conflict
            case .readOnly: return .rejected
            }
        }
        // A 2xx Google answered with something unreadable: the change may be in; sending it again is idempotent.
        return .transport(offline: false)
    }
}

/// Thin Calendar API v3 client (events.insert / patch / get / delete / list, calendarList.list) for one calendar
/// of one account.
struct GoogleCalendarClient: Sendable {
    /// nil: the first connected account (or, before the multi-account migration, the single legacy sign-in).
    var accountID: String? = nil
    var calendarID = "primary"
    var tokens: GoogleTokenProvider = .shared
    /// nil: the network with `tokens`.
    var transport: (any CalendarTransport)? = nil
    // Static: a private stored property would make the memberwise initializer private.
    private static let base = "https://www.googleapis.com/calendar/v3"

    /// One `events.list`, all pages unless `maxPages` stops it.
    struct Listing: Sendable {
        var items: [GCalEvent] = []
        /// The first page's `Date` header: Google's clock, the base of the next "changed since" request.
        var serverDate: Date?
        /// Stopped at `maxPages` with pages left.
        var isTruncated = false
    }

    // MARK: Writes

    /// Idempotent insert: ids are derived from stable seeds, so 409 means "already written" → fetch it.
    func insert(_ event: MappedEvent) async throws -> GCalEvent {
        try await insertReportingExisting(event).event
    }

    /// `existed`: Google already had the id (an earlier attempt got through), so `event` is Google's copy, which
    /// may predate edits folded into `event.body` since.
    func insertReportingExisting(_ event: MappedEvent) async throws -> (event: GCalEvent, existed: Bool) {
        var query = [URLQueryItem(name: "sendUpdates", value: event.body.attendees == nil ? "none" : "all")]
        if event.wantsConference { query.append(URLQueryItem(name: "conferenceDataVersion", value: "1")) }
        do {
            let saved: GCalEvent = try await send("POST", path: eventsPath, query: query,
                                                  body: try JSONEncoder().encode(event.body))
            return (saved, false)
        } catch let error as CalendarAPIError where error.status == 409 {
            guard let id = event.body.id else { throw error }
            return (try await get(eventID: id), true)
        }
    }

    /// Bounded-concurrency fan-out for plans. Results keep input order.
    func insertAll(_ events: [MappedEvent], maxConcurrent: Int = 4) async throws -> [GCalEvent] {
        guard !events.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, GCalEvent).self) { group in
            var results = [GCalEvent?](repeating: nil, count: events.count)
            var next = 0
            for _ in 0..<min(maxConcurrent, events.count) {
                let index = next
                next += 1
                group.addTask {
                    let saved = try await self.insert(events[index])
                    return (index, saved)
                }
            }
            while let (index, saved) = try await group.next() {
                results[index] = saved
                if next < events.count {
                    let queued = next
                    next += 1
                    group.addTask {
                        let saved = try await self.insert(events[queued])
                        return (queued, saved)
                    }
                }
            }
            return results.compactMap { $0 }
        }
    }

    /// - Parameter etag: the version the change is based on (If-Match); Google answers 412 when the event changed
    ///   since. nil sends it unconditionally.
    func patch(eventID: String, _ body: GCalEvent, ifMatch etag: String? = nil) async throws -> GCalEvent {
        try await send("PATCH", path: eventPath(eventID), body: try JSONEncoder().encode(body), headers: Self.ifMatch(etag))
    }

    func delete(eventID: String, ifMatch etag: String? = nil) async throws {
        do {
            let _: EmptyResponse = try await send("DELETE", path: eventPath(eventID), headers: Self.ifMatch(etag))
        } catch let error as CalendarAPIError where error.status == 410 || error.status == 404 {
            return // already gone — deleting is idempotent from the user's point of view
        }
    }

    // MARK: Reads

    func get(eventID: String) async throws -> GCalEvent {
        try await send("GET", path: eventPath(eventID))
    }

    /// `singleEvents=true` expands recurring series into instances (what the month grid needs).
    func list(from start: Date, to end: Date,
              singleEvents: Bool = true,
              privateProperty: (key: String, value: String)? = nil) async throws -> [GCalEvent] {
        try await listing(from: start, to: end, singleEvents: singleEvents, privateProperty: privateProperty).items
    }

    /// - Parameters:
    ///   - updatedMin: only events changed since then. Google then always includes deleted entries
    ///     (`status == "cancelled"`); `showDeleted=true` says so explicitly. Unlike `syncToken`, it may be combined
    ///     with `timeMin` / `timeMax`.
    ///   - maxPages: stop after this many pages and report `isTruncated`; nil lists every page.
    func listing(from start: Date, to end: Date,
                 singleEvents: Bool = true,
                 privateProperty: (key: String, value: String)? = nil,
                 updatedMin: Date? = nil,
                 maxPages: Int? = nil) async throws -> Listing {
        var listing = Listing()
        var pageToken: String?
        var pages = 0
        repeat {
            if let maxPages, pages >= maxPages {
                listing.isTruncated = true
                break
            }
            var query = [
                URLQueryItem(name: "timeMin", value: WallClock.rfc3339(start)),
                URLQueryItem(name: "timeMax", value: WallClock.rfc3339(end)),
                URLQueryItem(name: "singleEvents", value: singleEvents ? "true" : "false"),
                URLQueryItem(name: "maxResults", value: "250")
            ]
            if let updatedMin {
                query.append(URLQueryItem(name: "updatedMin", value: WallClock.rfc3339(updatedMin)))
                query.append(URLQueryItem(name: "showDeleted", value: "true"))
            } else if singleEvents {
                query.append(URLQueryItem(name: "orderBy", value: "startTime"))
            }
            if let privateProperty {
                query.append(URLQueryItem(name: "privateExtendedProperty", value: "\(privateProperty.key)=\(privateProperty.value)"))
            }
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let (data, response) = try await perform("GET", path: eventsPath, query: query)
            if pages == 0 { listing.serverDate = Self.serverDate(response) }
            let page = try JSONDecoder().decode(GCalEventList.self, from: data)
            listing.items += page.items ?? []
            pageToken = page.nextPageToken
            pages += 1
        } while pageToken != nil
        return listing
    }

    /// Every calendar the account can read (`minAccessRole=reader`), minus ones Google marks hidden or deleted.
    /// Needs `GoogleAccount.calendarListScope`; without it Google answers 403.
    func listCalendars() async throws -> [GCalCalendarListEntry] {
        var all: [GCalCalendarListEntry] = []
        var pageToken: String?
        repeat {
            var query = [
                URLQueryItem(name: "minAccessRole", value: "reader"),
                URLQueryItem(name: "maxResults", value: "250")
            ]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: GCalCalendarList = try await send("GET", path: "/users/me/calendarList", query: query)
            all += page.items ?? []
            pageToken = page.nextPageToken
        } while pageToken != nil
        return all.filter { $0.hidden != true && $0.deleted != true }
    }

    // MARK: Transport

    private var eventsPath: String { "/calendars/\(encode(calendarID))/events" }
    private func eventPath(_ id: String) -> String { "\(eventsPath)/\(encode(id))" }

    private func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? component
    }

    private var link: any CalendarTransport { transport ?? GoogleTransport(tokens: tokens) }

    private static func ifMatch(_ etag: String?) -> [String: String] {
        guard let etag, !etag.isEmpty else { return [:] }
        return ["If-Match": etag]
    }

    /// The HTTP `Date` header ("Wed, 14 Oct 2026 09:41:07 GMT").
    static func serverDate(_ response: HTTPURLResponse?) -> Date? {
        guard let value = response?.value(forHTTPHeaderField: "Date") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }

    private struct EmptyResponse: Decodable {}

    private func send<Response: Decodable>(_ method: String,
                                           path: String,
                                           query: [URLQueryItem] = [],
                                           body: Data? = nil,
                                           headers: [String: String] = [:]) async throws -> Response {
        let (data, _) = try await perform(method, path: path, query: query, body: body, headers: headers)
        if data.isEmpty || Response.self == EmptyResponse.self { return try JSONDecoder().decode(Response.self, from: Data("{}".utf8)) }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func perform(_ method: String,
                         path: String,
                         query: [URLQueryItem] = [],
                         body: Data? = nil,
                         headers: [String: String] = [:],
                         attempt: Int = 0,
                         forceTokenRefresh: Bool = false) async throws -> (Data, HTTPURLResponse?) {
        var components = URLComponents(string: Self.base + path)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.httpMethod = method
        let link = self.link
        let token = try await link.accessToken(accountID: accountID, forceRefresh: forceTokenRefresh)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let (data, response) = try await link.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        switch status {
        case 200..<300:
            return (data, http)
        case 401 where attempt == 0:
            return try await perform(method, path: path, query: query, body: body, headers: headers,
                                     attempt: 1, forceTokenRefresh: true)
        // One combined condition: in Swift a `where` clause binds only to the last pattern of a multi-pattern case.
        case _ where attempt < 3 && isRetryable(status: status, data: data):
            let delay = pow(2.0, Double(attempt)) + Double.random(in: 0...0.5)
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return try await perform(method, path: path, query: query, body: body, headers: headers, attempt: attempt + 1)
        default:
            let error = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? [String: Any]
            let reason = ((error?["errors"] as? [[String: Any]])?.first?["reason"] as? String) ?? "error"
            throw CalendarAPIError.http(status: status, reason: reason, message: error?["message"] as? String ?? "")
        }
    }

    /// 429 and 5xx are transient. 403 only for rate limits (rateLimitExceeded / userRateLimitExceeded), not permissions.
    private func isRetryable(status: Int, data: Data) -> Bool {
        if status == 429 || (500...599).contains(status) { return true }
        guard status == 403 else { return false }
        let text = String(decoding: data, as: UTF8.self)
        return text.contains("RateLimitExceeded") || text.contains("rateLimitExceeded")
    }
}
