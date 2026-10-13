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

/// Thin Calendar API v3 client (events.insert / patch / get / delete / list).
struct GoogleCalendarClient: Sendable {
    var calendarID = "primary"
    var tokens: GoogleTokenProvider = .shared
    private let base = "https://www.googleapis.com/calendar/v3"

    // MARK: Writes

    /// Idempotent insert: ids are derived from stable seeds, so 409 means "already written" → fetch it.
    func insert(_ event: MappedEvent) async throws -> GCalEvent {
        var query = [URLQueryItem(name: "sendUpdates", value: event.body.attendees == nil ? "none" : "all")]
        if event.wantsConference { query.append(URLQueryItem(name: "conferenceDataVersion", value: "1")) }
        do {
            return try await send("POST", path: eventsPath, query: query, body: try JSONEncoder().encode(event.body))
        } catch let error as CalendarAPIError where error.status == 409 {
            guard let id = event.body.id else { throw error }
            return try await get(eventID: id)
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

    func patch(eventID: String, _ body: GCalEvent) async throws -> GCalEvent {
        try await send("PATCH", path: eventPath(eventID), body: try JSONEncoder().encode(body))
    }

    func delete(eventID: String) async throws {
        do {
            let _: EmptyResponse = try await send("DELETE", path: eventPath(eventID))
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
        var all: [GCalEvent] = []
        var pageToken: String?
        repeat {
            var query = [
                URLQueryItem(name: "timeMin", value: WallClock.rfc3339(start)),
                URLQueryItem(name: "timeMax", value: WallClock.rfc3339(end)),
                URLQueryItem(name: "singleEvents", value: singleEvents ? "true" : "false"),
                URLQueryItem(name: "maxResults", value: "250")
            ]
            if singleEvents { query.append(URLQueryItem(name: "orderBy", value: "startTime")) }
            if let privateProperty {
                query.append(URLQueryItem(name: "privateExtendedProperty", value: "\(privateProperty.key)=\(privateProperty.value)"))
            }
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: GCalEventList = try await send("GET", path: eventsPath, query: query)
            all += page.items ?? []
            pageToken = page.nextPageToken
        } while pageToken != nil
        return all
    }

    // MARK: Transport

    private var eventsPath: String { "/calendars/\(encode(calendarID))/events" }
    private func eventPath(_ id: String) -> String { "\(eventsPath)/\(encode(id))" }

    private func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? component
    }

    private struct EmptyResponse: Decodable {}

    private func send<Response: Decodable>(_ method: String,
                                           path: String,
                                           query: [URLQueryItem] = [],
                                           body: Data? = nil,
                                           attempt: Int = 0,
                                           forceTokenRefresh: Bool = false) async throws -> Response {
        var components = URLComponents(string: base + path)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.httpMethod = method
        let token = try await tokens.accessToken(forceRefresh: forceTokenRefresh)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            if data.isEmpty || Response.self == EmptyResponse.self { return try JSONDecoder().decode(Response.self, from: Data("{}".utf8)) }
            return try JSONDecoder().decode(Response.self, from: data)
        case 401 where attempt == 0:
            return try await send(method, path: path, query: query, body: body, attempt: 1, forceTokenRefresh: true)
        // One combined condition: in Swift a `where` clause binds only to the last pattern of a multi-pattern case.
        case _ where attempt < 3 && isRetryable(status: status, data: data):
            let delay = pow(2.0, Double(attempt)) + Double.random(in: 0...0.5)
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return try await send(method, path: path, query: query, body: body, attempt: attempt + 1)
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
