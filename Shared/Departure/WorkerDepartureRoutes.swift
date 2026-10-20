import Foundation

/// Asks for a route. `WorkerDepartureRoutes` is the real one; tests use a fake.
protocol DepartureRouting: Sendable {
    /// - Throws: `DepartureRouteError` (each case gets its own reply), or `CancellationError` when the task is
    ///   cancelled before the answer arrives.
    func route(_ request: DepartureRouteRequest) async throws -> DepartureRouteResult
}

/// `POST /v1/departure/routes` on the Smart Schedules server, signed with App Attest like every request to it
/// (`AttestedRequest`: one retry with a fresh assertion when the server forgot the key). Only the app calls it, never an
/// extension: the server refuses session tokens here. Nothing is sent when the request is invalid or no server is set.
struct WorkerDepartureRoutes: DepartureRouting {
    static let path = "v1/departure/routes"
    /// The server may ask Google up to three times (10 s each at most) and counts in its ledger before and after.
    static let timeout: TimeInterval = 45

    var origin: URL? = ServerEndpoint.origin
    var attestation: AttestationProviding = AppAttestClient.shared
    var session: URLSession = NetworkSession.shared
    var now: @Sendable () -> Date = { Date() }

    func route(_ request: DepartureRouteRequest) async throws -> DepartureRouteResult {
        let checked = try request.validated(now: now())
        guard let origin else { throw DepartureRouteError.notReady }
        try Task.checkCancellation()
        var urlRequest = URLRequest(url: origin.appendingPathComponent(Self.path), timeoutInterval: Self.timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data: Data
        let response: HTTPURLResponse?
        do {
            (data, response) = try await AttestedRequest.send(urlRequest, body: checked.body(), attestation: attestation,
                                                              session: session)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as AttestationError {
            throw DepartureRouteReader.error(attestation: error)
        } catch {
            // Offline, timed out, or the connection dropped.
            throw DepartureRouteError.unavailable
        }
        return try DepartureRouteReader.result(status: response?.statusCode ?? 0, body: data,
                                               retryAfter: AttestedRequest.retryAfter(response))
    }
}
