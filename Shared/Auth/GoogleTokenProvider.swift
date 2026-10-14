import Foundation

enum AuthError: LocalizedError {
    case signedOut
    case refreshFailed(String)
    /// One account's refresh token stopped working (`invalid_grant`); the others keep syncing.
    case reconnectNeeded(email: String)

    var errorDescription: String? {
        switch self {
        case .signedOut: String(localized: "Connect Google Calendar in Smart Schedule first.")
        case let .refreshFailed(reason): String(localized: "Google sign-in expired (\(reason)). Open Smart Schedule to reconnect.")
        case let .reconnectNeeded(email): String(localized: "Google sign-in for \(email) expired. Open Smart Schedule to reconnect.")
        }
    }
}

struct GoogleTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var email: String?
    /// OpenID `sub`. Optional so items saved by the single-account version still decode.
    var accountID: String? = nil
    var scopes: [String]? = nil
}

/// Returns a valid OAuth access token for any connected account, from any process (app or extension).
/// Refresh is a plain form POST — no Google SDK needed, which keeps the notification extension small.
///
/// One Keychain item per account (`google.oauth.<sub>`). The single-account version stored one item under
/// `google.oauth`; until `AccountManager.migrateLegacyAccountIfNeeded()` has moved it, a request without an
/// account falls back to it, so nothing breaks in between.
///
/// Facts that bite in practice:
/// • iOS OAuth clients have no client secret; refresh with client_id + refresh_token only.
/// • While the OAuth consent screen is in "Testing", refresh tokens expire after 7 days → `invalid_grant`.
/// • `calendar.events` and `calendar.calendarlist.readonly` are *sensitive* scopes: production needs Google's
///   app verification.
actor GoogleTokenProvider {
    static let shared = GoogleTokenProvider()
    /// `calendar.calendarlist.readonly` is the narrowest scope that lists the user's calendars; `calendar.events`
    /// already reads and writes events in every calendar the user can access.
    static let scopes = ["openid", "email", "https://www.googleapis.com/auth/calendar.events",
                         GoogleAccount.calendarListScope]
    /// What the single-account version asked for: no calendar list.
    static let legacyScopes = ["openid", "email", "https://www.googleapis.com/auth/calendar.events"]
    static let legacyKeychainKey = "google.oauth"
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    private static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    static func keychainKey(accountID: String) -> String { "\(legacyKeychainKey).\(accountID)" }

    private let accounts: AccountStore
    /// One refresh in flight per Keychain item, shared by concurrent callers.
    private var refreshTasks: [String: Task<String, Error>] = [:]

    init(accounts: AccountStore = .shared) {
        self.accounts = accounts
    }

    /// Any connected account, or the single-account version's sign-in that has not been migrated yet.
    var isSignedIn: Bool {
        get async {
            if !(await accounts.connectedAccounts()).isEmpty { return true }
            return hasLegacyTokens
        }
    }

    nonisolated var hasLegacyTokens: Bool {
        KeychainStore.load(GoogleTokens.self, key: Self.legacyKeychainKey) != nil
    }

    /// - Parameter accountID: nil = the first connected account, else the legacy item.
    func accessToken(accountID: String? = nil, forceRefresh: Bool = false) async throws -> String {
        var accountID = accountID
        if accountID == nil { accountID = await accounts.connectedAccounts().first?.id }
        let key = accountID.map { Self.keychainKey(accountID: $0) } ?? Self.legacyKeychainKey

        guard let tokens = KeychainStore.load(GoogleTokens.self, key: key) else {
            // The account is still listed but its token was dropped after invalid_grant.
            if let accountID, let account = await accounts.connectedAccount(id: accountID) {
                throw AuthError.reconnectNeeded(email: account.email)
            }
            throw AuthError.signedOut
        }
        if !forceRefresh, tokens.expiresAt.timeIntervalSinceNow > 120 { return tokens.accessToken }
        if let running = refreshTasks[key] { return try await running.value }

        let task = Task { try await Self.refresh(tokens, key: key) }
        refreshTasks[key] = task
        defer { refreshTasks[key] = nil }
        do {
            return try await task.value
        } catch AuthError.refreshFailed(let reason) where reason == "invalid_grant" {
            // The legacy item is simply gone (the UI shows Connect again).
            guard let accountID else { throw AuthError.refreshFailed(reason) }
            // Only this account: its cached events stay, the others keep syncing.
            await accounts.setNeedsReconnect(true, accountID: accountID)
            let email = await accounts.connectedAccount(id: accountID)?.email ?? tokens.email ?? accountID
            throw AuthError.reconnectNeeded(email: email)
        }
    }

    func store(_ tokens: GoogleTokens, accountID: String) throws {
        var tokens = tokens
        tokens.accountID = accountID
        try KeychainStore.save(tokens, key: Self.keychainKey(accountID: accountID))
    }

    func signOut(accountID: String) {
        KeychainStore.delete(key: Self.keychainKey(accountID: accountID))
    }

    /// Every token item, the legacy one included.
    func signOutAll() {
        KeychainStore.deleteAll()
    }

    /// Revokes the account's grant at Google (best effort, 10 s), so the refresh token stops working even if a copy
    /// survives somewhere. Leaves the Keychain item to `signOut(accountID:)`.
    func revoke(accountID: String) async {
        guard let tokens = KeychainStore.load(GoogleTokens.self, key: Self.keychainKey(accountID: accountID)) else { return }
        await Self.revoke(token: tokens.refreshToken)
    }

    /// Every connected account and the legacy item (erase).
    func revokeAll() async {
        for account in await accounts.connectedAccounts() { await revoke(accountID: account.id) }
        if let legacy = KeychainStore.load(GoogleTokens.self, key: Self.legacyKeychainKey) {
            await Self.revoke(token: legacy.refreshToken)
        }
    }

    /// Revokes one refresh token (best effort, 10 s): also a sign-in that was not kept, such as "Cancel" after
    /// Google signed in another account than the one typed. Revoking ends the account's whole grant to this app.
    static func revoke(token: String) async {
        var request = URLRequest(url: revokeEndpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded(["token": token])
        _ = try? await NetworkSession.data(for: request)
    }

    private static func refresh(_ tokens: GoogleTokens, key: String) async throws -> String {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded([
            "client_id": AppConstants.googleClientID,
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken
        ])
        let (data, response) = try await NetworkSession.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let access = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Double else {
            let reason = json["error"] as? String ?? "unknown"
            if reason == "invalid_grant" { KeychainStore.delete(key: key) }
            throw AuthError.refreshFailed(reason)
        }
        var updated = tokens
        updated.accessToken = access
        updated.expiresAt = Date().addingTimeInterval(expiresIn)
        try KeychainStore.save(updated, key: key)
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
