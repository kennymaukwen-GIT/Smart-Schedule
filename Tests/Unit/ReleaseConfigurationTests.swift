import XCTest

/// Version 1.0 owner decisions the build must keep (docs/SETTINGS.md §16). App/ is not in this hostless bundle, so
/// scripts/validate_schema.py checks that every Swift file reaching StoreKit or showing subscription copy reads the
/// flag.
final class ReleaseConfigurationTests: XCTestCase {
    /// 1.0 sells no subscription: the account sheet has no Smart Schedule Pro section, the avatar is "Accounts", the
    /// erase message does not mention subscriptions and StoreKit is never called. Turn it on only together with the
    /// products in App Store Connect, the reviewed Pro copy, the support FAQ and privacy policy §7, and this test.
    func testVersionOneSellsNoSubscription() {
        XCTAssertFalse(AppConstants.subscriptionsEnabled)
    }

    /// 1.0 uses no iOS 18 Live Activity push-to-start and no APNs at all: no push token is asked for or uploaded,
    /// nothing about events is kept on the server, the consent text says nothing about it, and the app has no
    /// aps-environment entitlement (scripts/validate_schema.py checks project.yml and that every file reaching
    /// push-to-start reads the flag). iOS 26 still schedules the Live Activities on the iPhone. Turn it on only together
    /// with everything `AppConstants.pushToStartEnabled` lists, and this test.
    func testVersionOneUsesNoPush() {
        XCTAssertFalse(AppConstants.pushToStartEnabled)
        XCTAssertFalse(AppConstants.liveActivityPushEnabled)
        XCTAssertNil(AIConsentDisclosure.serverNote(beforeIOS26: true), "no server storage to disclose")
        XCTAssertEqual(ActivityPlanner.pushToStartStep(enabled: AppConstants.pushToStartEnabled, schedulesOnDevice: false), .off)
        XCTAssertEqual(ActivityPlanner.pushToStartStep(enabled: AppConstants.pushToStartEnabled, schedulesOnDevice: true), .off)
    }
}
