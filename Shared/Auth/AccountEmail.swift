import Foundation

/// The email typed on the "Add Google account" page: whether it is worth sending to Google as a `login_hint`, and
/// whether the account Google signed in is the one typed.
///
/// OAuth cannot link an account from an email alone: the email only preselects or prefills the account on Google's
/// page, the user still signs in and consents there, and the ID token then says which account it really was.
enum AccountEmail {
    /// Characters a local part may hold besides letters and digits (RFC 5322 atext and the dot).
    private static let localSymbols = Set(".!#$%&'*+/=?^_`{|}~-")

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A complete address: one "@", a local part, and a domain with at least two labels whose last one is not
    /// a number (so "example@gmail" or "example@192.168.0.1" are not). Surrounding spaces are ignored.
    static func isValid(_ text: String) -> Bool {
        let email = trimmed(text)
        guard email.count <= 254, !email.contains(where: \.isWhitespace) else { return false }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = parts[0], domain = parts[1]

        guard !local.isEmpty, local.count <= 64, local.first != ".", local.last != ".", !local.contains(".."),
              local.allSatisfy({ $0.isLetter || $0.isNumber || localSymbols.contains($0) }) else { return false }

        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= 63, label.first != "-", label.last != "-",
                  label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return false }
        }
        guard let topLevel = labels.last, topLevel.count >= 2, !topLevel.allSatisfy(\.isNumber) else { return false }
        return true
    }

    /// Trimmed and lowercased. Gmail ignores dots and "+tags" in the local part and treats googlemail.com as
    /// gmail.com, so "Ex.Ample+work@googlemail.com" is "example@gmail.com". Other domains (Google Workspace) keep
    /// their dots and tags.
    static func normalized(_ email: String) -> String {
        let lowered = trimmed(email).lowercased()
        guard let at = lowered.lastIndex(of: "@") else { return lowered }
        var local = String(lowered[..<at])
        var domain = String(lowered[lowered.index(after: at)...])
        if domain == "gmail.com" || domain == "googlemail.com" {
            if let plus = local.firstIndex(of: "+") { local = String(local[..<plus]) }
            local.removeAll { $0 == "." }
            domain = "gmail.com"
        }
        return "\(local)@\(domain)"
    }

    /// The account Google returned is the one the user typed.
    static func sameAccount(typed: String, returned: String) -> Bool {
        normalized(typed) == normalized(returned)
    }
}

/// What to do with a finished Google sign-in from the add page (pure, unit-tested).
enum AddAccountDecision: Equatable, Sendable {
    /// A new account: store it.
    case connect
    /// That Google account (same `sub`) is connected already: refresh its tokens and calendars, no duplicate.
    case alreadyConnected
    /// Google signed in another account than the one typed: store nothing until the user picks "Add <signedIn>".
    case mismatch(signedIn: String, typed: String)
    /// The calendar permission was left unticked on Google's consent screen: nothing to store.
    case calendarAccessMissing

    /// - Parameters:
    ///   - typed: the email typed on the page; nil when the user chose from Google's account list.
    ///   - signedInEmail: the ID token's `email` (empty when Google did not send one: nothing to compare).
    ///   - signedInAccountID: the ID token's `sub`.
    static func decide(typed: String?,
                       signedInEmail: String,
                       signedInAccountID: String,
                       grantedScopes: [String],
                       connectedAccountIDs: Set<String>) -> AddAccountDecision {
        guard GoogleAuthorization.grantsCalendarAccess(grantedScopes) else { return .calendarAccessMissing }
        if let typed {
            let typed = AccountEmail.trimmed(typed)
            if !typed.isEmpty, !signedInEmail.isEmpty, !AccountEmail.sameAccount(typed: typed, returned: signedInEmail) {
                return .mismatch(signedIn: signedInEmail, typed: typed)
            }
        }
        return connectedAccountIDs.contains(signedInAccountID) ? .alreadyConnected : .connect
    }
}
