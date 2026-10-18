import DeviceCheck
import XCTest

/// Deleting the app leaves its App Attest key ID in the Keychain, but the key itself is gone after the reinstall:
/// iOS refuses it (`invalidKey`, or `invalidInput` as seen on an iPhone on 2026-10-18) and the app attests a new key,
/// once. Whatever still fails reads as a plain message, not "com.apple.devicecheck.error error 2".
final class AppAttestRecoveryTests: XCTestCase {
    func testAKeyFromAnEarlierLaunchThatIOSRefusesIsReplaced() {
        XCTAssertTrue(AppAttestClient.startsOver(after: DCError(.invalidKey), keyFromEarlierLaunch: true))
        XCTAssertTrue(AppAttestClient.startsOver(after: DCError(.invalidInput), keyFromEarlierLaunch: true))
    }

    func testAKeyAttestedSinceThisLaunchIsNotReplacedAgain() {
        XCTAssertFalse(AppAttestClient.startsOver(after: DCError(.invalidKey), keyFromEarlierLaunch: false))
        XCTAssertFalse(AppAttestClient.startsOver(after: DCError(.invalidInput), keyFromEarlierLaunch: false))
    }

    func testOtherFailuresKeepTheKey() {
        for code in [DCError.Code.serverUnavailable, .unknownSystemFailure, .featureUnsupported] {
            XCTAssertFalse(AppAttestClient.startsOver(after: DCError(code), keyFromEarlierLaunch: true), "\(code)")
        }
    }

    func testTheUserReadsAPlainMessage() {
        let error = AppAttestClient.userFacing(DCError(.invalidInput))
        guard case .deviceCheck(code: 2) = error else { return XCTFail("\(error)") }
        XCTAssertEqual(error.errorDescription,
                       "This iPhone couldn't verify Smart Schedules just now (App Attest error 2). Try again in a moment; if it keeps happening, restart the iPhone.")
        XCTAssertFalse(error.localizedDescription.contains("com.apple.devicecheck"))
    }

    func testADeviceWithoutAppAttestSaysSo() {
        guard case .unsupported = AppAttestClient.userFacing(DCError(.featureUnsupported)) else {
            return XCTFail("featureUnsupported should read as .unsupported")
        }
    }
}
