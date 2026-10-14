import XCTest

/// Google's sign-in page: the request the add page sends (the typed email as `login_hint`), and what the redirect
/// back or a failed token exchange means for the user.
final class GoogleAuthorizationTests: XCTestCase {
    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    private func authorizationURL(hint: String?) -> URL {
        GoogleAuthorization.url(clientID: "123.apps.googleusercontent.com",
                                redirectURI: "com.googleusercontent.apps.123:/oauth2redirect",
                                codeChallenge: "challenge", loginHint: hint, scopes: GoogleTokenProvider.scopes)
    }

    func testTheTypedEmailBecomesTheLoginHint() {
        let url = authorizationURL(hint: "  example@gmail.com ")
        XCTAssertTrue(url.absoluteString.hasPrefix("https://accounts.google.com/o/oauth2/v2/auth?"), url.absoluteString)
        let items = query(url)
        XCTAssertEqual(items["login_hint"], "example@gmail.com")
        XCTAssertEqual(items["prompt"], "consent", "straight to the typed account")
        XCTAssertEqual(items["client_id"], "123.apps.googleusercontent.com")
        XCTAssertEqual(items["redirect_uri"], "com.googleusercontent.apps.123:/oauth2redirect")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["code_challenge"], "challenge")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["access_type"], "offline")
        XCTAssertEqual(items["include_granted_scopes"], "true")
        XCTAssertEqual(items["scope"]?.split(separator: " ").map(String.init), GoogleTokenProvider.scopes)
    }

    func testWithoutAnEmailGoogleShowsItsAccountList() {
        for hint in [nil, "", "   "] as [String?] {
            let items = query(authorizationURL(hint: hint))
            XCTAssertNil(items["login_hint"])
            XCTAssertEqual(items["prompt"], "consent select_account")
        }
    }

    func testAPlusTagSurvivesTheQueryEncoding() {
        let url = authorizationURL(hint: "example+cal@gmail.com")
        XCTAssertEqual(query(url)["login_hint"], "example+cal@gmail.com")
        // Sent as %2B: a bare "+" in a query reads as a space on Google's side.
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        XCTAssertTrue(raw.contains("login_hint=example%2Bcal@gmail.com"), raw)
        XCTAssertFalse(raw.contains("+"), raw)
    }

    // MARK: The redirect back

    private func redirect(_ query: String) -> URL {
        URL(string: "com.googleusercontent.apps.123:/oauth2redirect?\(query)")!
    }

    func testACodeIsNoError() {
        XCTAssertNil(GoogleSignInFailure.fromRedirect(redirect("code=4/abc&scope=email")))
        XCTAssertNil(GoogleSignInFailure.fromRedirect(redirect("error=&code=4/abc")))
    }

    func testAnAdminsBlockIsSaidPlainly() {
        // A plain access_denied is the user declining on the consent screen, not an admin's block.
        XCTAssertEqual(GoogleSignInFailure.fromRedirect(redirect("error=access_denied")), .refused(code: "access_denied"))
        XCTAssertTrue(GoogleSignInFailure.isDeclined(redirect("error=access_denied")))
        XCTAssertFalse(GoogleSignInFailure.isDeclined(redirect("error=access_denied&error_subtype=admin_policy_enforced")))
        XCTAssertFalse(GoogleSignInFailure.isDeclined(redirect("error=admin_policy_enforced")))
        XCTAssertFalse(GoogleSignInFailure.isDeclined(redirect("code=4%2F0Ab")))
        XCTAssertEqual(GoogleSignInFailure.fromRedirect(redirect("error=admin_policy_enforced")), .blockedByAdmin)
        XCTAssertEqual(GoogleSignInFailure.fromRedirect(redirect("error=org_internal")), .blockedByAdmin)
        XCTAssertEqual(GoogleSignInFailure.fromRedirect(redirect("error=invalid_request&error_subtype=admin_policy_enforced")),
                       .blockedByAdmin)
        XCTAssertFalse(GoogleSignInFailure.blockedByAdmin.canRetry)
        XCTAssertEqual(GoogleSignInFailure.blockedByAdmin.errorDescription,
                       "Your school or company doesn't allow this app to use Google Calendar. Ask your admin, or use another account.")
    }

    func testOtherErrorsOfferTryAgain() {
        XCTAssertEqual(GoogleSignInFailure.fromRedirect(redirect("error=server_error")), .refused(code: "server_error"))
        XCTAssertTrue(GoogleSignInFailure.refused(code: "server_error").canRetry)
        XCTAssertEqual(GoogleSignInFailure.refused(code: "server_error").errorDescription,
                       "Google sign-in didn't finish (server_error). Try again.")
        XCTAssertTrue(GoogleSignInFailure.calendarAccessMissing.canRetry)
        XCTAssertTrue(GoogleSignInFailure.unreachable.canRetry)
        XCTAssertEqual(GoogleSignInFailure.unreachable.errorDescription, "Can't reach Google. Check your connection.")
    }

    func testNetworkFailuresMeanGoogleCannotBeReached() {
        XCTAssertTrue(GoogleSignInFailure.isUnreachable(URLError(.notConnectedToInternet)))
        XCTAssertTrue(GoogleSignInFailure.isUnreachable(URLError(.timedOut)))
        XCTAssertTrue(GoogleSignInFailure.isUnreachable(URLError(.cannotFindHost)))
        XCTAssertFalse(GoogleSignInFailure.isUnreachable(URLError(.cancelled)))
        XCTAssertFalse(GoogleSignInFailure.isUnreachable(CancellationError()))
    }

    func testCalendarAccessNeedsTheEventsScope() {
        XCTAssertTrue(GoogleAuthorization.grantsCalendarAccess(GoogleTokenProvider.scopes))
        XCTAssertTrue(GoogleAuthorization.grantsCalendarAccess(GoogleTokenProvider.legacyScopes))
        XCTAssertFalse(GoogleAuthorization.grantsCalendarAccess(["openid", "email", GoogleAccount.calendarListScope]))
        XCTAssertFalse(GoogleAuthorization.grantsCalendarAccess([]))
    }
}
