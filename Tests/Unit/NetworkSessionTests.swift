import XCTest

/// The notification extension's requests: an ephemeral session, at most 30 seconds each. The app (and this test
/// bundle) keeps URLSession.shared.
final class NetworkSessionTests: XCTestCase {
    func testTheExtensionSessionIsEphemeralWithAThirtySecondTimeout() {
        let session = NetworkSession.makeExtensionSession()
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(session.configuration.urlCache?.diskCapacity ?? 0, 0, "no disk cache")
        XCTAssertFalse(NetworkSession.isAppExtension, "the test runner is not an extension")
        XCTAssertTrue(NetworkSession.shared === URLSession.shared)
    }

    func testRequestsWaitAtMostThirtySecondsInTheExtension() {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        XCTAssertEqual(NetworkSession.capped(URLRequest(url: url), inExtension: true).timeoutInterval, 30, "60 s by default")
        XCTAssertEqual(NetworkSession.capped(URLRequest(url: url, timeoutInterval: 20), inExtension: true).timeoutInterval, 20)
        XCTAssertEqual(NetworkSession.capped(URLRequest(url: url), inExtension: false).timeoutInterval, 60, "the app is unchanged")
    }
}
