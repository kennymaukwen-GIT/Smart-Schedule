import Foundation

enum AuthError: LocalizedError {
    case signedOut
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: "Connect Google Calendar in Smart Schedule first."
        case let .refreshFailed(reason): "Google sign-in expired (\(reason)). Open Smart Schedule to reconnect."
        }
    }
}

struct GoogleTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var email: String?
}

/// Returns a valid OAuth access token from any process (app or extension).
/// Refresh is a plain form POST — no Google SDK needed, which keeps the notification extension small.
///
/// Facts that bite in practice:
/// • iOS OAuth clients have no client secret; refresh with client_id + refresh_token only.
/// • While the OAuth consent screen is in "Testing", refresh tokens expire after 7 days → `invalid_grant`.
/// • `calendar.events` is a *sensitive* scope: production needs Google's app verification.
actor GoogleTokenProvider {
    static let shared = GoogleTokenProvider()
    static let scopes = ["openid", "email", "https://www.googleapis.com/auth/calendar.events"]
    private static let keychainKey = "google.oauth"
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    private var refreshTask: Task<String, Error>?

    var isSignedIn: Bool { KeychainStore.load(GoogleTokens.self, key: Self.keychainKey) != nil }

    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let tokens = KeychainStore.load(GoogleTokens.self, key: Self.keychainKey) else { throw AuthError.signedOut }
        if !forceRefresh, tokens.expiresAt.timeIntervalSinceNow > 120 { return tokens.accessToken }
        if let refreshTask { return try await refreshTask.value }

        let task = Task { try await Self.refresh(tokens) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    func store(_ tokens: GoogleTokens) throws {
        try KeychainStore.save(tokens, key: Self.keychainKey)
    }

    func signOut() {
        KeychainStore.delete(key: Self.keychainKey)
    }

    private static func refresh(_ tokens: GoogleTokens) async throws -> String {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded([
            "client_id": AppConstants.googleClientID,
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let access = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Double else {
            let reason = json["error"] as? String ?? "unknown"
            if reason == "invalid_grant" { KeychainStore.delete(key: keychainKey) }
            throw AuthError.refreshFailed(reason)
        }
        var updated = tokens
        updated.accessToken = access
        updated.expiresAt = Date().addingTimeInterval(expiresIn)
        try KeychainStore.save(updated, key: keychainKey)
        return access
    }

    static func formEncoded(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
    }
}
