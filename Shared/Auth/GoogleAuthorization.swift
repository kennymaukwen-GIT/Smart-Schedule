import Foundation

/// The parts of Google's OAuth sign-in that need no UI: the authorization URL, what the redirect back says, and
/// whether the granted scopes are enough (pure, unit-tested; `GoogleSignInCoordinator` runs the flow).
enum GoogleAuthorization {
    static let endpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let eventsScope = "https://www.googleapis.com/auth/calendar.events"
    /// The full calendar scope; an older grant may hold it instead of `calendar.events`.
    static let calendarScope = "https://www.googleapis.com/auth/calendar"

    /// The authorization request. With `loginHint` (the email typed on the add page, or the account being
    /// reconnected) Google goes straight to that account, or asks to sign in with the address filled in. Without
    /// it, `select_account` shows the account chooser even when one Google account is signed in, so a second one
    /// can be added. `consent` returns a refresh token every time.
    static func url(clientID: String, redirectURI: String, codeChallenge: String, loginHint: String?,
                    scopes: [String]) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        let hint = loginHint.map(AccountEmail.trimmed).flatMap { $0.isEmpty ? nil : $0 }
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: hint == nil ? "consent select_account" : "consent"),
            URLQueryItem(name: "include_granted_scopes", value: "true")
        ]
        if let hint { items.append(URLQueryItem(name: "login_hint", value: hint)) }
        components.queryItems = items
        // URLComponents leaves "+" as is, which Google reads as a space: "example+cal@gmail.com" must stay itself.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// Smart Schedule cannot read or write events without `calendar.events` (or the full calendar scope). The
    /// calendar-list scope is optional: without it only the primary calendar is synced ("Show all calendars").
    static func grantsCalendarAccess(_ scopes: [String]) -> Bool {
        scopes.contains(eventsScope) || scopes.contains(calendarScope)
    }
}

/// Why adding (or reconnecting) a Google account did not work, in plain words for the add page.
enum GoogleSignInFailure: LocalizedError, Equatable, Sendable {
    /// `admin_policy_enforced` or `org_internal` from Google's page: a Google Workspace admin keeps this app away
    /// from the account's calendar. (A plain `access_denied` is the user tapping Cancel or Deny: see `isDeclined`.)
    case blockedByAdmin
    /// The calendar permission was left unticked on the consent screen (no `calendar.events` in the grant).
    case calendarAccessMissing
    /// No connection, or Google's token endpoint did not answer.
    case unreachable
    /// Any other error code Google's page sent back (`invalid_request`, `server_error`, …).
    case refused(code: String)

    var errorDescription: String? {
        switch self {
        case .blockedByAdmin:
            String(localized: "Your school or company doesn't allow this app to use Google Calendar. Ask your admin, or use another account.")
        case .calendarAccessMissing:
            String(localized: "Smart Schedule needs access to your Google Calendar. Try again and leave the calendar permission ticked on Google's page.")
        case .unreachable:
            String(localized: "Can't reach Google. Check your connection.")
        case let .refused(code):
            String(localized: "Google sign-in didn't finish (\(code)). Try again.")
        }
    }

    /// "Try again" makes sense: the user can change something on Google's page or wait for the network. An
    /// admin's block stays until the admin changes it (another account can be typed instead).
    var canRetry: Bool { self != .blockedByAdmin }

    /// The error in the redirect back from Google's page (`…:/oauth2redirect?error=access_denied`); nil when it
    /// carries no error (an authorization code).
    static func fromRedirect(_ url: URL) -> GoogleSignInFailure? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            guard let value = items.first(where: { $0.name == name })?.value, !value.isEmpty else { return nil }
            return value
        }
        guard let error = value("error") else { return nil }
        let codes = [error, value("error_subtype")].compactMap { $0?.lowercased() }
        if codes.contains(where: { ["admin_policy_enforced", "org_internal"].contains($0) }) {
            return .blockedByAdmin
        }
        return .refused(code: error)
    }

    /// The user tapped Cancel or Deny on Google's consent screen: Google answers a plain `access_denied` (no admin
    /// subtype). The add page treats it like closing Google's page and says nothing.
    static func isDeclined(_ url: URL) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let error = items.first(where: { $0.name == "error" })?.value?.lowercased()
        return error == "access_denied" && fromRedirect(url) != .blockedByAdmin
    }

    /// A failed request to Google (the token exchange): no connection, a timeout, a host that cannot be found.
    static func isUnreachable(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return error.code != .cancelled
    }
}
