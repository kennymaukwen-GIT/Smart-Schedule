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
}
