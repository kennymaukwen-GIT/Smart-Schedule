import XCTest

/// The Control Center button's intent hands `DeepLink.compose` to the app; when no handler is installed (it ran
/// outside the app), the link waits in the App Group for the app to open it.
@MainActor
final class DeepLinkRequestsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "DeepLinkRequestsTests")
        defaults.removePersistentDomain(forName: "DeepLinkRequestsTests")
    }

    func testAWaitingLinkIsOpenedOnce() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        DeepLinkRequests.open(DeepLink.compose, defaults: defaults, now: now)
        XCTAssertEqual(DeepLinkRequests.takePending(defaults: defaults, now: now.addingTimeInterval(5)), DeepLink.compose)
        XCTAssertNil(DeepLinkRequests.takePending(defaults: defaults, now: now.addingTimeInterval(6)), "taken once")
    }

    func testAnOldLinkIsDropped() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        DeepLinkRequests.open(DeepLink.composeVoice, defaults: defaults, now: now)
        XCTAssertNil(DeepLinkRequests.takePending(defaults: defaults, now: now.addingTimeInterval(DeepLinkRequests.maxAge + 1)))
        XCTAssertNil(defaults.string(forKey: DeepLinkRequests.pendingURLKey), "and cleared")
    }

    func testNothingWaiting() {
        XCTAssertNil(DeepLinkRequests.takePending(defaults: defaults))
    }
}
