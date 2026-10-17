import CryptoKit
import DeviceCheck
import Foundation

/// What a request to Smart Schedule's server (server/worker) carries to prove it comes from this app. A protocol so
/// tests can inject one.
protocol AttestationProviding: Sendable {
    /// Headers for a request whose body is exactly `body` (the assertion signs its SHA-256).
    func headers(for body: Data) async throws -> [String: String]
    /// The server no longer knows or accepts this app's key: forget it, so the next request attests a new one.
    func reset() async
}

enum AttestationError: LocalizedError {
    /// The device has no App Attest (the simulator, some Macs).
    case unsupported
    /// The notification extension has no session from the app yet, or it expired (the app has not run for days).
    case sessionMissing
    /// `SSGeminiBaseURL` does not point at Smart Schedule's server.
    case notConfigured
    case server(status: Int)
    /// The server refused this app's attestation (`invalid_attestation`): the build's App Attest environment, Team ID or
    /// bundle ID is not the one the server checks (the Worker log says which), or the proof is not genuine. Every new
    /// key would be refused the same way.
    case attestationRejected
    /// The server's per-minute limit for this app.
    case rateLimited
    /// A limit on the server that lasts until the next UTC day: the notification extension's replies, or new
    /// installs attesting from one network.
    case dailyLimit
    /// The server answers but is not set up yet (`server_misconfigured`: a secret such as the Apple Team ID or the
    /// Gemini key is missing). Retrying does not help until its owner fixes it.
    case serverNotReady
    /// The server no longer accepts this version's request from the notification extension (its model).
    case updateRequired
    case malformed

    var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "This device can't prove it is running Smart Schedules, so the assistant is unavailable.")
        case .sessionMissing: String(localized: "Open Smart Schedules once so the assistant can answer here.")
        case .notConfigured: "GEMINI_BASE_URL must point at the Smart Schedules server (server/worker)."
        case let .server(status): String(localized: "The Smart Schedules server didn't answer (\(status)). Try again later.")
        case .attestationRejected: String(localized: "The Smart Schedules server couldn't verify this copy of the app, so the assistant is unavailable.")
        case .rateLimited: String(localized: "Too many requests. Wait a minute and try again.")
        case .dailyLimit: NetworkSession.isAppExtension
            ? String(localized: "Today's limit for replies here is used up. Open Smart Schedules to continue, or try again tomorrow.")
            : String(localized: "Today's limit is used up. Try again tomorrow.")
        case .serverNotReady: String(localized: "The Smart Schedules server isn't ready yet. Try again later.")
        case .updateRequired: String(localized: "Update Smart Schedules to use the assistant here.")
        case .malformed: String(localized: "The Smart Schedules server sent something unexpected. Try again later.")
        }
    }
}

/// Smart Schedule's server: the origin of `SSGeminiBaseURL`. nil while that still points at Google itself, which
/// would need an API key in the app.
enum ServerEndpoint {
    static var origin: URL? { origin(of: GeminiConfig.fromBundle.baseURL) }

    /// https only; plain http only for a Worker on this Mac (`npm run dev`, which ATS allows).
    static func origin(of baseURL: String) -> URL? {
        guard var components = URLComponents(string: baseURL), let host = components.host?.lowercased(), !host.isEmpty,
              components.scheme == "https" || (components.scheme == "http" && ["localhost", "127.0.0.1"].contains(host)),
              host != "googleapis.com", !host.hasSuffix(".googleapis.com") else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

/// The notification extension's credential. App Attest does not work in iOS app extensions (Apple: `generateKey`
/// fails in an app extension whatever `isSupported` says; only watchOS extensions support it), so the attested app
/// asks the server for a short-lived token bound to its key (`POST /session`) and keeps it in the Keychain access
/// group the extension shares. The server accepts it only for Gemini requests.
struct ServerSession: Codable, Equatable, Sendable {
    var token: String
    var expiresAt: Date
}

protocol SessionStoring: Sendable {
    func load() -> ServerSession?
    func save(_ session: ServerSession?)
}

struct KeychainSessionStore: SessionStoring {
    static let key = "appattest.session"
    func load() -> ServerSession? { KeychainStore.load(ServerSession.self, key: Self.key) }
    func save(_ session: ServerSession?) {
        if let session { try? KeychainStore.save(session, key: Self.key) } else { KeychainStore.delete(key: Self.key) }
    }
}

/// App Attest (`DCAppAttestService`): the Secure Enclave key that proves requests come from this app on a real
/// device, so the server's Gemini key is not a free public endpoint.
///
/// In the app, once per key: `generateKey`, a one-time challenge from `GET /attest/challenge`, `attestKey` over its
/// SHA-256, and `POST /attest`; the key ID then lives in the Keychain. Every request: an assertion over the SHA-256 of
/// its body, sent as `Authorization: Bearer base64(key ID bytes ‖ assertion)`. The app also keeps a `ServerSession`
/// fresh (`refreshSessionIfNeeded`), which the notification extension sends as `Authorization: Session <token>`.
///
/// Debug builds on a device without App Attest (the simulator) send `X-Dev-Token: SSDevToken` instead, or nothing
/// when it is empty; Release builds have no such path. Needs no `UIApplication`.
actor AppAttestClient: AttestationProviding {
    static let shared = AppAttestClient()

    /// The extension's token is renewed when it has less than this left; the server issues it for 7 days.
    static let sessionRenewal: TimeInterval = 3 * 86_400

    private let origin: URL?
    private let session: URLSession
    private let bundleID: String
    private let isExtension: Bool
    private let sessions: SessionStoring
    private let now: @Sendable () -> Date
    private var keyID: String?
    private var attesting: Task<String, Error>?

    init(origin: URL? = ServerEndpoint.origin,
         session: URLSession = NetworkSession.shared,
         bundleID: String = Bundle.main.bundleIdentifier ?? "com.smartschedules.app",
         isExtension: Bool = NetworkSession.isAppExtension,
         sessions: SessionStoring = KeychainSessionStore(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.origin = origin
        self.session = session
        self.bundleID = bundleID
        self.isExtension = isExtension
        self.sessions = sessions
        self.now = now
    }

    private var keychainKey: String { "appattest.keyID.\(bundleID)" }

    func headers(for body: Data) async throws -> [String: String] {
        if isExtension { return try extensionHeaders() }
        let service = DCAppAttestService.shared
        guard service.isSupported else {
            #if DEBUG
            if let token = AppConstants.info("SSDevToken") { return ["X-Dev-Token": token] }
            return [:]
            #else
            throw AttestationError.unsupported
            #endif
        }
        let keyID = try await attestedKeyID()
        let clientDataHash = Data(SHA256.hash(data: body))
        let assertion: Data
        do {
            assertion = try await service.generateAssertion(keyID, clientDataHash: clientDataHash)
        } catch let error as DCError where error.code == .invalidKey {
            // The Secure Enclave dropped the key (a restore to another device): attest a new one.
            reset()
            return try await headers(for: body)
        }
        guard let token = Self.bearerToken(keyID: keyID, assertion: assertion) else { throw AttestationError.malformed }
        return ["Authorization": "Bearer \(token)"]
    }

    func reset() {
        if isExtension {
            // The server refused the session: the app gets a new one when it next runs.
            sessions.save(nil)
            return
        }
        keyID = nil
        KeychainStore.delete(key: keychainKey)
    }

    /// The app (never the extension) renews the extension's session when it is missing or has less than
    /// `sessionRenewal` left. Best effort: a failure leaves the old one, and the next foreground or background run
    /// tries again. Only with AI consent, like every other request to the server.
    func refreshSessionIfNeeded(consented: Bool = AIConsentStore.current.isGranted) async {
        guard !isExtension, consented, let origin else { return }
        if let current = sessions.load(), current.expiresAt.timeIntervalSince(now()) > Self.sessionRenewal { return }
        var request = URLRequest(url: origin.appendingPathComponent("session"), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await AttestedRequest.send(request, body: Data("{}".utf8), attestation: self,
                                                                     session: session),
              let status = response?.statusCode, (200..<300).contains(status),
              let issued = try? Self.sessionDecoder.decode(ServerSession.self, from: data) else { return }
        sessions.save(issued)
    }

    /// Forgets the key and the extension's session ("Erase all data").
    func forgetAll() {
        keyID = nil
        KeychainStore.delete(key: keychainKey)
        sessions.save(nil)
    }

    /// The extension never attests: it sends the session the app got for it.
    private func extensionHeaders() throws -> [String: String] {
        if let current = sessions.load(), current.expiresAt > now() {
            return ["Authorization": "Session \(current.token)"]
        }
        #if DEBUG
        if let token = AppConstants.info("SSDevToken") { return ["X-Dev-Token": token] }
        return [:]
        #else
        throw AttestationError.sessionMissing
        #endif
    }

    private static var sessionDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// base64(the 32 key ID bytes ‖ assertion): what the server splits back apart.
    static func bearerToken(keyID: String, assertion: Data) -> String? {
        guard let raw = Data(base64Encoded: keyID), raw.count == 32 else { return nil }
        return (raw + assertion).base64EncodedString()
    }

    // MARK: Attestation

    private func attestedKeyID() async throws -> String {
        if let keyID { return keyID }
        if let stored = KeychainStore.load(String.self, key: keychainKey) {
            keyID = stored
            return stored
        }
        if let attesting { return try await attesting.value }
        let task = Task { try await self.attestNewKey() }
        attesting = task
        defer { attesting = nil }
        let id = try await task.value
        try? KeychainStore.save(id, key: keychainKey)
        keyID = id
        return id
    }

    /// - Parameter challengeRetried: the server already refused one challenge (`invalid_challenge`: it expired while
    ///   Apple attested the key, or was used up). That round is tried once more with a new challenge and a new key,
    ///   since Apple attests a key only once.
    private func attestNewKey(challengeRetried: Bool = false) async throws -> String {
        guard let origin else { throw AttestationError.notConfigured }
        let service = DCAppAttestService.shared

        var challengeRequest = URLRequest(url: origin.appendingPathComponent("attest/challenge"), timeoutInterval: 20)
        challengeRequest.httpMethod = "GET"
        let (challengeData, challengeResponse) = try await session.data(for: challengeRequest)
        try Self.requireOK(challengeData, challengeResponse)
        guard let challenge = (try? JSONDecoder().decode(Challenge.self, from: challengeData))?.challenge,
              let challengeBytes = Data(base64Encoded: challenge) else { throw AttestationError.malformed }

        let keyID = try await service.generateKey()
        let clientDataHash = Data(SHA256.hash(data: challengeBytes))
        let attestation: Data
        do {
            attestation = try await service.attestKey(keyID, clientDataHash: clientDataHash)
        } catch let error as DCError where error.code == .serverUnavailable {
            // Apple's attestation service did not answer: Apple's advice is to try again with the same key.
            try await Task.sleep(nanoseconds: 1_000_000_000)
            attestation = try await service.attestKey(keyID, clientDataHash: clientDataHash)
        }

        var request = URLRequest(url: origin.appendingPathComponent("attest"), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Attestation(keyId: keyID, attestation: attestation.base64EncodedString(),
                                                                challenge: challenge, bundleId: bundleID))
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !challengeRetried, status == 401, AttestedRequest.errorCode(data) == "invalid_challenge" {
            return try await attestNewKey(challengeRetried: true)
        }
        try Self.requireOK(data, response)
        return keyID
    }

    private static func requireOK(_ data: Data, _ response: URLResponse) throws {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AttestedRequest.failure(status: status, data: data, response: http) ?? AttestationError.server(status: status)
        }
    }

    private struct Challenge: Decodable { let challenge: String }
    private struct Attestation: Encodable { let keyId, attestation, challenge, bundleId: String }
}

/// One request to Smart Schedule's server with the attestation headers. When the server answers 401 because the
/// key is unknown or the assertion is rejected, it is sent once more with a fresh assertion (after forgetting the
/// key, so a new one is attested); `stale_counter` (two requests crossed) only needs the fresh assertion. In the
/// extension, `invalid_session` forgets the session, so the retry explains that the app has to run once.
enum AttestedRequest {
    static func send(_ request: URLRequest,
                     body: Data,
                     attestation: AttestationProviding,
                     session: URLSession) async throws -> (Data, HTTPURLResponse?) {
        var retried = false
        while true {
            var signed = request
            signed.httpBody = body
            for (field, value) in try await attestation.headers(for: body) {
                signed.setValue(value, forHTTPHeaderField: field)
            }
            let (data, response) = try await session.data(for: signed)
            let http = response as? HTTPURLResponse
            guard http?.statusCode == 401, !retried, let code = errorCode(data),
                  ["unknown_key", "invalid_assertion", "stale_counter", "invalid_session"].contains(code) else {
                return (data, http)
            }
            retried = true
            if code != "stale_counter" { await attestation.reset() }
        }
    }

    /// The server's `{"error":"<code>"}`.
    static func errorCode(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
    }

    /// The server's `Retry-After`, in seconds.
    static func retryAfter(_ response: HTTPURLResponse?) -> TimeInterval? {
        response?.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// What an error the server answered for itself (`{"error":"<code>"}`) means for the user. Nil for a success and
    /// for Google's own errors, which pass through as `{"error":{…}}`.
    static func failure(status: Int, data: Data, response: HTTPURLResponse?) -> AttestationError? {
        guard !(200..<300).contains(status), let code = errorCode(data) else { return nil }
        switch code {
        // Until the next minute, or until the next UTC day for the daily limits.
        case "rate_limited": return (retryAfter(response) ?? 0) > 120 ? .dailyLimit : .rateLimited
        case "server_misconfigured": return .serverNotReady
        // The notification extension's model is not one the server accepts for it any more.
        case "session_scope": return .updateRequired
        // No credential the server accepts: the extension has no session yet, or a Debug build on the simulator
        // sends no X-Dev-Token (SS_DEV_TOKEN unset, or GEMINI_BASE_URL is not the development Worker).
        case "attestation_required": return NetworkSession.isAppExtension ? .sessionMissing : .unsupported
        // POST /attest refused the key (it answered: this is not "didn't answer").
        case "invalid_attestation": return .attestationRejected
        default: return .server(status: status)
        }
    }
}

/// Smart Schedule's own endpoints (everything but Gemini, which `GeminiClient` sends through `AttestedRequest`).
struct ServerClient: Sendable {
    static let shared = ServerClient()

    var origin: URL? = ServerEndpoint.origin
    var attestation: AttestationProviding = AppAttestClient.shared
    var session: URLSession = NetworkSession.shared

    /// POSTs JSON to `path` ("devices/push-to-start", only with `AppConstants.pushToStartEnabled`, so not in version
    /// 1.0); the response body on 2xx.
    func post(_ path: String, json body: Data) async throws -> Data {
        guard let origin else { throw AttestationError.notConfigured }
        var request = URLRequest(url: origin.appendingPathComponent(path), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await AttestedRequest.send(request, body: body, attestation: attestation, session: session)
        let status = response?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AttestedRequest.failure(status: status, data: data, response: response) ?? AttestationError.server(status: status)
        }
        return data
    }
}
