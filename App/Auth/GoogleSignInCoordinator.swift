import AuthenticationServices
import CryptoKit
import UIKit

/// Who signed in and the tokens for that account. Nothing is stored yet: `AccountManager` decides whether this is
/// a new account, a reconnect, or the wrong account for a reconnect.
struct GoogleSignInResult: Sendable {
    var tokens: GoogleTokens        // accountID, email, scopes filled
    var accountID: String           // `sub` from the id_token payload
    var email: String
    var grantedScopes: [String]     // token response "scope", split on spaces
}

/// Google OAuth 2.0 for iOS with PKCE via ASWebAuthenticationSession — no GoogleSignIn SDK, so the
/// same token store works in every extension.
///
/// Setup: Google Cloud Console → enable "Google Calendar API" → OAuth consent screen (add the scopes
/// `calendar.events` and `calendar.calendarlist.readonly`) → Credentials → OAuth client ID, type **iOS**,
/// bundle id `com.smartschedule.app`. Put the client id + reversed client id into Config/Secrets.xcconfig.
@MainActor
final class GoogleSignInCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum SignInError: LocalizedError {
        case notConfigured, cancelled, noCode, tokenExchange(String), noIdentity

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Google client ID missing — set GOOGLE_IOS_CLIENT_ID in Config/Secrets.xcconfig."
            case .cancelled: "Sign-in cancelled."
            case .noCode: "Google did not return an authorization code."
            case let .tokenExchange(reason): "Token exchange failed: \(reason)"
            case .noIdentity: "Google did not say which account signed in."
            }
        }
    }

    private var session: ASWebAuthenticationSession?

    /// - Parameter loginHint: the email typed on the add page, or of the account to reconnect: Google goes straight
    ///   to that account or asks to sign in with it filled in. The user can still pick another account there, so
    ///   the caller compares the returned email with it. nil shows Google's account chooser.
    /// - Throws: `SignInError.cancelled` when the user closed Google's page; `GoogleSignInFailure` for an error
    ///   Google's page sent back or no connection.
    func signIn(loginHint: String? = nil) async throws -> GoogleSignInResult {
        let clientID = AppConstants.googleClientID
        let scheme = AppConstants.googleReversedClientID
        guard !clientID.isEmpty, !scheme.isEmpty else { throw SignInError.notConfigured }
        let redirectURI = "\(scheme):/oauth2redirect"

        let verifier = Self.randomURLSafe(bytes: 32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        let authURL = GoogleAuthorization.url(clientID: clientID, redirectURI: redirectURI, codeChallenge: challenge,
                                              loginHint: loginHint, scopes: GoogleTokenProvider.scopes)

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { url, error in
                if let url { continuation.resume(returning: url) } else {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    let failure: Error = cancelled ? SignInError.cancelled : (error ?? SignInError.noCode)
                    continuation.resume(throwing: failure)
                }
            }
            session.presentationContextProvider = self
            self.session = session
            session.start()
        }
        session = nil

        // Google's page answered with an error instead of a code (an admin's policy, a bad request).
        if GoogleSignInFailure.isDeclined(callback) { throw SignInError.cancelled }
        if let failure = GoogleSignInFailure.fromRedirect(callback) { throw failure }
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else { throw SignInError.noCode }
        return try await exchange(code: code, verifier: verifier, clientID: clientID, redirectURI: redirectURI)
    }

    private func exchange(code: String, verifier: String, clientID: String, redirectURI: String) async throws -> GoogleSignInResult {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleTokenProvider.formEncoded([
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ])
        let data: Data
        do {
            data = try await URLSession.shared.data(for: request).0
        } catch {
            if GoogleSignInFailure.isUnreachable(error) { throw GoogleSignInFailure.unreachable }
            throw error
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String,
              let expiresIn = json["expires_in"] as? Double else {
            throw SignInError.tokenExchange(json["error_description"] as? String ?? json["error"] as? String ?? "unknown")
        }
        guard let identity = (json["id_token"] as? String).flatMap(IDToken.init(jwt:)) else { throw SignInError.noIdentity }
        let email = identity.email ?? ""
        let granted = (json["scope"] as? String)?.split(separator: " ").map(String.init) ?? GoogleTokenProvider.scopes
        let tokens = GoogleTokens(accessToken: access,
                                  refreshToken: refresh,
                                  expiresAt: Date().addingTimeInterval(expiresIn),
                                  email: email,
                                  accountID: identity.subject,
                                  scopes: granted)
        return GoogleSignInResult(tokens: tokens, accountID: identity.subject, email: email, grantedScopes: granted)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
        }
    }

    private static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
