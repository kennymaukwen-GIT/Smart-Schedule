import AuthenticationServices
import CryptoKit
import UIKit

/// Google OAuth 2.0 for iOS with PKCE via ASWebAuthenticationSession — no GoogleSignIn SDK, so the
/// same token store works in every extension.
///
/// Setup: Google Cloud Console → enable "Google Calendar API" → OAuth consent screen (add scope
/// `calendar.events`) → Credentials → OAuth client ID, type **iOS**, bundle id `com.smartschedule.app`.
/// Put the client id + reversed client id into Config/Secrets.xcconfig.
@MainActor
final class GoogleSignInCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum SignInError: LocalizedError {
        case notConfigured, cancelled, noCode, tokenExchange(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Google client ID missing — set GOOGLE_IOS_CLIENT_ID in Config/Secrets.xcconfig."
            case .cancelled: "Sign-in cancelled."
            case .noCode: "Google did not return an authorization code."
            case let .tokenExchange(reason): "Token exchange failed: \(reason)"
            }
        }
    }

    private var session: ASWebAuthenticationSession?

    func signIn() async throws {
        let clientID = AppConstants.googleClientID
        let scheme = AppConstants.googleReversedClientID
        guard !clientID.isEmpty, !scheme.isEmpty else { throw SignInError.notConfigured }
        let redirectURI = "\(scheme):/oauth2redirect"

        let verifier = Self.randomURLSafe(bytes: 32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleTokenProvider.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: scheme) { url, error in
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

        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else { throw SignInError.noCode }
        try await exchange(code: code, verifier: verifier, clientID: clientID, redirectURI: redirectURI)
    }

    private func exchange(code: String, verifier: String, clientID: String, redirectURI: String) async throws {
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
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String,
              let expiresIn = json["expires_in"] as? Double else {
            throw SignInError.tokenExchange(json["error_description"] as? String ?? json["error"] as? String ?? "unknown")
        }
        try await GoogleTokenProvider.shared.store(GoogleTokens(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn),
            email: nil
        ))
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
