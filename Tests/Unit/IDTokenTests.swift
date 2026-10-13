import XCTest

/// Which Google account signed in: the `sub` and `email` claims of the id_token payload (base64url, unpadded).
final class IDTokenTests: XCTestCase {
    private let header = "eyJhbGciOiJSUzI1NiIsImtpZCI6ImFiYyIsInR5cCI6IkpXVCJ9"
    private let signature = "c2lnbmF0dXJl"

    func testReadsSubjectAndEmail() throws {
        // {"iss":"https://accounts.google.com","sub":"110169484474386276334","email":"kenny@example.com",...}
        let payload = "eyJpc3MiOiJodHRwczovL2FjY291bnRzLmdvb2dsZS5jb20iLCJzdWIiOiIxMTAxNjk0ODQ0NzQzODYyNzYzMzQiLCJlbWFpbCI6Imtlbm55QGV4YW1wbGUuY29tIiwiZW1haWxfdmVyaWZpZWQiOnRydWUsImF1ZCI6InguYXBwcy5nb29nbGV1c2VyY29udGVudC5jb20ifQ"
        let token = try XCTUnwrap(IDToken(jwt: "\(header).\(payload).\(signature)"))
        XCTAssertEqual(token.subject, "110169484474386276334")
        XCTAssertEqual(token.email, "kenny@example.com")
    }

    func testBase64URLAlphabetAndMissingPadding() throws {
        // {"sub":"42","email":"zz??>>>@example.com"}: contains "-" and "_", length a multiple of 4.
        let urlAlphabet = try XCTUnwrap(IDToken(jwt: "\(header).eyJzdWIiOiI0MiIsImVtYWlsIjoieno_Pz4-PkBleGFtcGxlLmNvbSJ9.\(signature)"))
        XCTAssertEqual(urlAlphabet.email, "zz??>>>@example.com")
        // {"sub":"42","email":"測試?>>@example.com"}: needs one "=" of padding.
        let unpadded = try XCTUnwrap(IDToken(jwt: "\(header).eyJzdWIiOiI0MiIsImVtYWlsIjoi5ris6KmmPz4-QGV4YW1wbGUuY29tIn0.\(signature)"))
        XCTAssertEqual(unpadded.subject, "42")
        XCTAssertEqual(unpadded.email, "測試?>>@example.com")
        // {"sub":"42","email":"a~~~~~>?@example.com"}: needs "==".
        let twoPads = try XCTUnwrap(IDToken(jwt: "\(header).eyJzdWIiOiI0MiIsImVtYWlsIjoiYX5-fn5-Pj9AZXhhbXBsZS5jb20ifQ.\(signature)"))
        XCTAssertEqual(twoPads.email, "a~~~~~>?@example.com")
    }

    func testRejectsTokensWithoutASubject() {
        // {"email":"no-sub@example.com"}
        XCTAssertNil(IDToken(jwt: "\(header).eyJlbWFpbCI6Im5vLXN1YkBleGFtcGxlLmNvbSJ9.\(signature)"))
        XCTAssertNil(IDToken(jwt: "not a jwt"))
        XCTAssertNil(IDToken(jwt: "\(header).\(signature)"))
        XCTAssertNil(IDToken(jwt: "\(header).%%%.\(signature)"))
        XCTAssertNil(IDToken(jwt: "\(header)..\(signature)"))
    }

    func testBase64URLDecoding() {
        XCTAssertEqual(IDToken.base64URLDecoded("aGk"), Data("hi".utf8))
        XCTAssertEqual(IDToken.base64URLDecoded("aGk="), Data("hi".utf8))
        XCTAssertNil(IDToken.base64URLDecoded("a"))
    }
}
