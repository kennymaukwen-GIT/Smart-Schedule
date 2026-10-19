import Security
import XCTest

/// Only the keychain's "not while locked" answer means locked; anything else fails open, so a keychain problem never
/// disables the card. `isLocked()` itself is not called: the keychain of a hostless test bundle can answer -34018
/// (errSecMissingEntitlement).
final class DeviceLockTests: XCTestCase {
    func testOnlyInteractionNotAllowedMeansLocked() {
        XCTAssertTrue(DeviceLock.meansLocked(errSecInteractionNotAllowed))
    }

    func testEveryOtherAnswerCountsAsUnlocked() {
        for status in [errSecSuccess, errSecItemNotFound, errSecDuplicateItem, errSecMissingEntitlement, errSecAuthFailed] {
            XCTAssertFalse(DeviceLock.meansLocked(status), "OSStatus \(status)")
        }
    }
}
