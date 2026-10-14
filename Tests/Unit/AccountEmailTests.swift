import XCTest

/// The "Add Google account" page: which typed addresses are complete, when the account Google signed in is the one
/// typed (Gmail ignores dots and +tags), and what happens with the sign-in Google returns.
final class AccountEmailTests: XCTestCase {
    private let eventsScope = "https://www.googleapis.com/auth/calendar.events"
    private let allScopes = GoogleTokenProvider.scopes

    // MARK: Validation

    func testCompleteAddressesAreValid() {
        for email in ["example@gmail.com", "example@yourmail.com", " Example@Gmail.com\n", "first.last+cal@school.edu.hk",
                      "o'brien@work.example.co.uk", "a_b-c@sub-domain.example.org", "x@xn--fiqs8s.com"] {
            XCTAssertTrue(AccountEmail.isValid(email), email)
        }
    }

    func testIncompleteAddressesAreNot() {
        for email in ["", "   ", "example", "example@", "@gmail.com", "example@gmail", "example@gmail.", "example@.com",
                      "exa mple@gmail.com", "a@b@gmail.com", ".example@gmail.com", "example.@gmail.com",
                      "ex..ample@gmail.com", "example@-gmail.com", "example@gmail-.com", "example@gmail..com",
                      "example@gmail.c", "example@192.168.0.1", "example@gm ail.com", "<example@gmail.com>",
                      "example@gmail.com,", "example(at)gmail.com"] {
            XCTAssertFalse(AccountEmail.isValid(email), email)
        }
        XCTAssertFalse(AccountEmail.isValid(String(repeating: "a", count: 65) + "@gmail.com"), "local part over 64")
    }

    // MARK: Normalising and comparing

    func testGmailIgnoresDotsTagsAndCase() {
        XCTAssertEqual(AccountEmail.normalized(" Ex.Ample+Work@Gmail.com "), "example@gmail.com")
        XCTAssertEqual(AccountEmail.normalized("e.x.a.m.p.l.e@googlemail.com"), "example@gmail.com")
        XCTAssertTrue(AccountEmail.sameAccount(typed: "Ex.ample+cal@gmail.com", returned: "example@gmail.com"))
        XCTAssertTrue(AccountEmail.sameAccount(typed: "example@googlemail.com", returned: "example@gmail.com"))
        XCTAssertFalse(AccountEmail.sameAccount(typed: "example@gmail.com", returned: "example2@gmail.com"))
    }

    func testOtherDomainsKeepDotsAndTags() {
        XCTAssertEqual(AccountEmail.normalized("First.Last+x@YourMail.com"), "first.last+x@yourmail.com")
        XCTAssertTrue(AccountEmail.sameAccount(typed: " EXAMPLE@yourmail.com", returned: "example@yourmail.com"))
        XCTAssertFalse(AccountEmail.sameAccount(typed: "ex.ample@yourmail.com", returned: "example@yourmail.com"))
        XCTAssertFalse(AccountEmail.sameAccount(typed: "example+cal@yourmail.com", returned: "example@yourmail.com"))
        XCTAssertFalse(AccountEmail.sameAccount(typed: "example@gmail.com", returned: "example@yourmail.com"))
    }

    // MARK: What to do with the sign-in

    private func decide(typed: String?, signedIn: String = "example@gmail.com", accountID: String = "111",
                        scopes: [String]? = nil, connected: Set<String> = []) -> AddAccountDecision {
        AddAccountDecision.decide(typed: typed, signedInEmail: signedIn, signedInAccountID: accountID,
                                  grantedScopes: scopes ?? allScopes, connectedAccountIDs: connected)
    }

    func testTheTypedAccountIsConnected() {
        XCTAssertEqual(decide(typed: "example@gmail.com"), .connect)
        XCTAssertEqual(decide(typed: "Ex.Ample@gmail.com "), .connect, "Gmail's dots and case")
        XCTAssertEqual(decide(typed: nil), .connect, "chosen from Google's list: nothing to compare")
        XCTAssertEqual(decide(typed: "  "), .connect)
        XCTAssertEqual(decide(typed: "example@gmail.com", signedIn: ""), .connect, "no email in the ID token")
    }

    func testAnotherAccountIsNotStored() {
        XCTAssertEqual(decide(typed: " example@gmail.com ", signedIn: "example@yourmail.com"),
                       .mismatch(signedIn: "example@yourmail.com", typed: "example@gmail.com"))
        // Already connected or not, the user decides first.
        XCTAssertEqual(decide(typed: "example@gmail.com", signedIn: "example@yourmail.com", connected: ["111"]),
                       .mismatch(signedIn: "example@yourmail.com", typed: "example@gmail.com"))
    }

    func testAnAccountAlreadyConnectedIsRefreshedNotDuplicated() {
        XCTAssertEqual(decide(typed: "example@gmail.com", connected: ["111", "222"]), .alreadyConnected)
        XCTAssertEqual(decide(typed: nil, accountID: "222", connected: ["111", "222"]), .alreadyConnected)
        XCTAssertEqual(decide(typed: nil, accountID: "333", connected: ["111", "222"]), .connect)
    }

    func testCalendarAccessIsRequired() {
        XCTAssertEqual(decide(typed: "example@gmail.com", scopes: ["openid", "email"]), .calendarAccessMissing)
        XCTAssertEqual(decide(typed: "example@gmail.com", signedIn: "example@yourmail.com",
                              scopes: ["openid", "email", GoogleAccount.calendarListScope]), .calendarAccessMissing)
        // The calendar list is optional (only the primary calendar then), and an older full-calendar grant counts.
        XCTAssertEqual(decide(typed: nil, scopes: ["openid", "email", eventsScope]), .connect)
        XCTAssertEqual(decide(typed: nil, scopes: ["openid", "email", "https://www.googleapis.com/auth/calendar"]), .connect)
    }
}
