import Foundation

/// The OpenID Connect ID token Google's token endpoint returns with `openid email`: which account just signed in.
///
/// Only the payload is decoded, without checking the signature: the token comes straight from Google's token
/// endpoint over TLS in exchange for our own authorization code, so it is not attacker-supplied.
struct IDToken: Equatable, Sendable {
    var subject: String             // `sub`: stable account id, the key of everything per account
    var email: String?

    init(subject: String, email: String?) {
        self.subject = subject
        self.email = email
    }

    /// nil unless `jwt` is three dot-separated parts whose middle part is base64url JSON with a `sub`.
    init?(jwt: String) {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let data = Self.base64URLDecoded(String(parts[1])),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let subject = payload["sub"] as? String, !subject.isEmpty else { return nil }
        self.subject = subject
        email = payload["email"] as? String
    }

    /// base64url (RFC 4648 §5) without padding, as JWTs use it.
    static func base64URLDecoded(_ text: String) -> Data? {
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}
