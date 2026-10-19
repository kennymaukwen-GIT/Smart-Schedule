import XCTest

/// The Control Center button's intent hands `DeepLink.compose` to the app; when no handler is installed (it ran
/// outside the app, as on iOS 26 in the widget extension), the link waits in the App Group, `.deepLink` is posted,
/// and the app opens it once, whichever of its checks finds it first.
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

    // MARK: iOS 26 scene route (OpenQuickCaptureIntent reaches the scene before perform())

    func testPerformAfterTheSceneOpenedQuickCaptureIsAnEcho() {
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(DeepLinkRequests.isSceneEcho(DeepLink.compose, sceneOpenedAt: opened, now: opened.addingTimeInterval(1.7)))
        XCTAssertTrue(DeepLinkRequests.isSceneEcho(DeepLink.compose, sceneOpenedAt: opened, now: opened))
    }

    func testALaterTapIsNotAnEcho() {
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        let window = DeepLinkRequests.sceneEchoWindow
        XCTAssertEqual(window, 10)
        XCTAssertTrue(DeepLinkRequests.isSceneEcho(DeepLink.compose, sceneOpenedAt: opened, now: opened.addingTimeInterval(window - 0.1)))
        XCTAssertFalse(DeepLinkRequests.isSceneEcho(DeepLink.compose, sceneOpenedAt: opened, now: opened.addingTimeInterval(window)))
    }

    func testWithoutASceneRouteNothingIsSkipped() {
        XCTAssertFalse(DeepLinkRequests.isSceneEcho(DeepLink.compose, sceneOpenedAt: nil, now: Date()))
    }

    func testOnlyThePlainComposeLinkCounts() {
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        let soon = opened.addingTimeInterval(1)
        XCTAssertFalse(DeepLinkRequests.isSceneEcho(DeepLink.composeVoice, sceneOpenedAt: opened, now: soon))
        XCTAssertFalse(DeepLinkRequests.isSceneEcho(DeepLink.event("abc"), sceneOpenedAt: opened, now: soon))
    }

    func testAClockThatWentBackIsNotAnEcho() {
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(DeepLinkRequests.isSceneEcho(DeepLink.compose, sceneOpenedAt: opened, now: opened.addingTimeInterval(-1)))
    }

    func testNothingWaiting() {
        XCTAssertNil(DeepLinkRequests.takePending(defaults: defaults))
    }

    func testALinkFromTheFutureIsDropped() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        DeepLinkRequests.open(DeepLink.compose, defaults: defaults, now: now)
        XCTAssertNil(DeepLinkRequests.takePending(defaults: defaults, now: now.addingTimeInterval(-1)))
        XCTAssertNil(defaults.string(forKey: DeepLinkRequests.pendingURLKey), "and cleared")
    }

    func testALinkAtMaxAgeIsStillOpened() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        DeepLinkRequests.open(DeepLink.compose, defaults: defaults, now: now)
        XCTAssertEqual(DeepLinkRequests.takePending(defaults: defaults, now: now.addingTimeInterval(DeepLinkRequests.maxAge)),
                       DeepLink.compose)
    }

    /// The app's three checks (becoming active, the late re-check, `.deepLink`) all call `routePending`: only the
    /// first one that finds the link opens Quick Capture.
    func testRoutePendingHandsTheLinkOverOnce() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var routed: [URL] = []
        XCTAssertFalse(DeepLinkRequests.routePending(defaults: defaults, now: now) { routed.append($0) },
                       "nothing written yet: the app becomes active before the extension writes")
        DeepLinkRequests.open(DeepLink.compose, defaults: defaults, now: now)
        XCTAssertTrue(DeepLinkRequests.routePending(defaults: defaults, now: now.addingTimeInterval(0.5)) { routed.append($0) })
        XCTAssertFalse(DeepLinkRequests.routePending(defaults: defaults, now: now.addingTimeInterval(0.6)) { routed.append($0) })
        XCTAssertEqual(routed, [DeepLink.compose])
    }

    func testRoutePendingIgnoresAnOldLink() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        DeepLinkRequests.open(DeepLink.compose, defaults: defaults, now: now)
        var routed: [URL] = []
        XCTAssertFalse(DeepLinkRequests.routePending(defaults: defaults,
                                                     now: now.addingTimeInterval(DeepLinkRequests.maxAge + 1)) { routed.append($0) })
        XCTAssertTrue(routed.isEmpty)
    }

    /// With no handler (the intent ran outside the app), `open` posts `.deepLink` after the link is written, so a
    /// running app opens it without waiting to become active again.
    func testALinkLeftInTheAppGroupPostsDeepLink() async {
        let posted = expectation(description: ".deepLink delivered")
        posted.assertForOverFulfill = false
        let observation = SharedChangeNotifier.observe(.deepLink) { posted.fulfill() }
        let now = Date()
        DeepLinkRequests.open(DeepLink.compose, defaults: defaults, now: now)
        await fulfillment(of: [posted], timeout: 5)
        XCTAssertEqual(DeepLinkRequests.takePending(defaults: defaults, now: now), DeepLink.compose, "written before the post")
        withExtendedLifetime(observation) {}
    }

    func testDeepLinkNotificationName() {
        XCTAssertEqual(SharedChange.deepLink.darwinName, "com.smartschedule.changed.deepLink")
        // The names other processes already observe are unchanged.
        XCTAssertEqual(SharedChange.preferences.darwinName, "com.smartschedule.changed.preferences")
        XCTAssertEqual(SharedChange.accounts.darwinName, "com.smartschedule.changed.accounts")
        XCTAssertEqual(SharedChange.consent.darwinName, "com.smartschedule.changed.consent")
        XCTAssertEqual(SharedChange.syncStatus.darwinName, "com.smartschedule.changed.syncStatus")
    }
}
