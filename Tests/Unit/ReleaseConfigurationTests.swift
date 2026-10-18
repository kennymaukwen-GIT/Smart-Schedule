import XCTest

/// Version 1.0 owner decisions the build must keep (docs/SETTINGS.md §16). App/ is not in this hostless bundle, so
/// scripts/validate_schema.py checks that every Swift file reaching StoreKit or showing subscription copy reads the
/// flag.
final class ReleaseConfigurationTests: XCTestCase {
    /// 1.0 sells no subscription: the account sheet has no Smart Schedules Pro section, the avatar is "Accounts", the
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

    /// The app's own voice input (owner decision 2026-10-18): free, Traditional Chinese (Taiwan) and US English, speech
    /// recognised on the iPhone only. App/ is not in this bundle, so scripts/validate_schema.py (check 9) checks the
    /// recorder: microphone and speech code only in App/Voice, every recognition request with
    /// requiresOnDeviceRecognition = true, no audio file or network request there, and the usage descriptions in the
    /// app target only. The consent text names the mic button and says only the text is sent;
    /// `DeepLink.composeVoice` opens Quick Capture and asks for the mic.
    func testVoiceInputIsOnDeviceOnly() {
        XCTAssertEqual(VoiceInput.localeIdentifiers, ["zh-TW", "en-US"])
        for language in SpeechLanguage.allCases {
            for appLanguage in ["zh-Hant", "en"] {
                XCTAssertTrue(VoiceInput.localeIdentifiers.contains(VoiceInput.localeIdentifier(for: language, appLanguage: appLanguage)),
                              "\(language) in \(appLanguage)")
            }
        }
        let note = AIConsentDisclosure.speechNote
        XCTAssertTrue(note.contains("microphone button"), note)
        XCTAssertTrue(note.contains("on your iPhone"), note)
        XCTAssertTrue(note.contains("Smart Schedules sends only the text, never audio"), note)
        XCTAssertFalse(note.contains("On-device recognition"), "no such setting any more: \(note)")
        XCTAssertEqual(DeepLink.composeVoice.host, DeepLink.compose.host)
        XCTAssertTrue(DeepLink.startsVoiceInput(DeepLink.composeVoice))
        XCTAssertFalse(DeepLink.startsVoiceInput(DeepLink.compose))
    }
}
