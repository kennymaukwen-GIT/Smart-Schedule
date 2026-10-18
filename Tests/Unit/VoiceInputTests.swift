import XCTest

/// The mic button's pure rules (Shared/Voice/VoiceInput.swift): which recognizer locale, when a recording stops by
/// itself, how the words join what was typed, what a tap leads to, and the voice deep link. The recorder itself
/// (App/Voice/VoiceTranscriber.swift) is not in this hostless bundle; scripts/validate_schema.py checks it records on
/// the iPhone only.
final class VoiceInputTests: XCTestCase {
    // MARK: Locale

    func testAutomaticFollowsTheAppLanguage() {
        XCTAssertEqual(VoiceInput.localeIdentifier(for: .automatic, appLanguage: "zh-Hant"), "zh-TW")
        XCTAssertEqual(VoiceInput.localeIdentifier(for: .automatic, appLanguage: "zh-Hant-TW"), "zh-TW")
        XCTAssertEqual(VoiceInput.localeIdentifier(for: .automatic, appLanguage: "zh-HK"), "zh-TW")
        XCTAssertEqual(VoiceInput.localeIdentifier(for: .automatic, appLanguage: "en"), "en-US")
        XCTAssertEqual(VoiceInput.localeIdentifier(for: .automatic, appLanguage: "en-GB"), "en-US")
        // Only en and zh-Hant ship; anything else reads as English.
        XCTAssertEqual(VoiceInput.localeIdentifier(for: .automatic, appLanguage: "ja"), "en-US")
        XCTAssertEqual(VoiceInput.localeIdentifier(for: .automatic, appLanguage: ""), "en-US")
    }

    func testAChosenLanguageWinsOverTheAppLanguage() {
        XCTAssertEqual(VoiceInput.localeIdentifier(for: .chineseTaiwan, appLanguage: "en"), "zh-TW")
        XCTAssertEqual(VoiceInput.localeIdentifier(for: .englishUS, appLanguage: "zh-Hant"), "en-US")
        // English (UK), from an earlier build, is recognised as US English: the two languages are zh-TW and en-US.
        XCTAssertEqual(VoiceInput.localeIdentifier(for: .englishUK, appLanguage: "zh-Hant"), "en-US")
    }

    func testSettingsOffersAutomaticChineseAndUSEnglish() {
        XCTAssertEqual(VoiceInput.offeredLanguages, [.automatic, .chineseTaiwan, .englishUS])
        XCTAssertEqual(VoiceInput.offeredLanguage(.englishUK), .englishUS)
        for language in VoiceInput.offeredLanguages {
            XCTAssertEqual(VoiceInput.offeredLanguage(language), language)
        }
        // The stored preference is the Speech language setting that was already there.
        var preferences = AppPreferences()
        preferences.speechLanguage = .chineseTaiwan
        XCTAssertEqual(VoiceInput.localeIdentifier(for: preferences), "zh-TW")
        preferences.speechLanguage = .englishUS
        XCTAssertEqual(VoiceInput.localeIdentifier(for: preferences), "en-US")
    }

    // MARK: Stopping by itself

    func testStopsAfterASilenceOnceWordsWereHeard() {
        XCTAssertNil(VoiceInput.stopReason(elapsed: 5, sinceLastWords: 0))
        XCTAssertNil(VoiceInput.stopReason(elapsed: 5, sinceLastWords: VoiceInput.silenceAfterWords - 0.5))
        XCTAssertEqual(VoiceInput.stopReason(elapsed: 5, sinceLastWords: VoiceInput.silenceAfterWords), .silence)
        // Words keep it going past the "nothing heard" limit.
        XCTAssertNil(VoiceInput.stopReason(elapsed: VoiceInput.silenceBeforeWords + 10, sinceLastWords: 1))
    }

    func testGivesUpWhenNothingIsHeard() {
        XCTAssertNil(VoiceInput.stopReason(elapsed: 0, sinceLastWords: nil))
        XCTAssertNil(VoiceInput.stopReason(elapsed: VoiceInput.silenceBeforeWords - 0.5, sinceLastWords: nil))
        XCTAssertEqual(VoiceInput.stopReason(elapsed: VoiceInput.silenceBeforeWords, sinceLastWords: nil), .nothingHeard)
    }

    func testStopsAtTheTimeLimit() {
        XCTAssertEqual(VoiceInput.stopReason(elapsed: VoiceInput.maxDuration, sinceLastWords: 0), .timeLimit)
        XCTAssertEqual(VoiceInput.stopReason(elapsed: VoiceInput.maxDuration + 1, sinceLastWords: nil), .timeLimit)
        XCTAssertLessThan(VoiceInput.silenceAfterWords, VoiceInput.silenceBeforeWords)
        XCTAssertLessThan(VoiceInput.silenceBeforeWords, VoiceInput.maxDuration)
    }

    // MARK: The text field

    func testWordsFollowWhatWasTyped() {
        XCTAssertEqual(VoiceInput.combined(typed: "", spoken: "明天下午兩點開會"), "明天下午兩點開會")
        XCTAssertEqual(VoiceInput.combined(typed: "Lunch with Andrew", spoken: "tomorrow at 1"), "Lunch with Andrew tomorrow at 1")
        XCTAssertEqual(VoiceInput.combined(typed: "Lunch ", spoken: "tomorrow"), "Lunch tomorrow")
        XCTAssertEqual(VoiceInput.combined(typed: "明天", spoken: "下午兩點開會"), "明天下午兩點開會")
        XCTAssertEqual(VoiceInput.combined(typed: "明天，", spoken: "開會"), "明天，開會")
        XCTAssertEqual(VoiceInput.combined(typed: "Joe", spoken: "明天開會"), "Joe明天開會")
        // Nothing heard yet: the field keeps what was typed.
        XCTAssertEqual(VoiceInput.combined(typed: "Lunch", spoken: ""), "Lunch")
    }

    func testCJKCharacters() {
        for character: Character in ["明", "，", "。", "あ", "한", "Ａ"] {
            XCTAssertTrue(VoiceInput.isCJK(character), String(character))
        }
        for character: Character in ["a", "1", " ", ",", "é"] {
            XCTAssertFalse(VoiceInput.isCJK(character), String(character))
        }
    }

    // MARK: Permissions

    func testATapAsksOnlyWhatWasNeverAsked() {
        XCTAssertEqual(VoiceInput.access(microphone: .granted, speechRecognition: .granted), .ready)
        XCTAssertEqual(VoiceInput.access(microphone: .notDetermined, speechRecognition: .notDetermined), .ask)
        XCTAssertEqual(VoiceInput.access(microphone: .notDetermined, speechRecognition: .granted), .ask)
        XCTAssertEqual(VoiceInput.access(microphone: .granted, speechRecognition: .notDetermined), .ask)
        XCTAssertNil(VoiceInput.Access.ready.message)
        XCTAssertNil(VoiceInput.Access.ask.message)
    }

    func testARefusalSaysWhichSwitchAndOpensSettings() throws {
        XCTAssertEqual(VoiceInput.access(microphone: .denied, speechRecognition: .granted),
                       .denied(microphone: true, speechRecognition: false))
        XCTAssertEqual(VoiceInput.access(microphone: .notDetermined, speechRecognition: .denied),
                       .denied(microphone: false, speechRecognition: true))
        XCTAssertEqual(VoiceInput.access(microphone: .denied, speechRecognition: .denied),
                       .denied(microphone: true, speechRecognition: true))

        let microphone = try XCTUnwrap(VoiceInput.Access.denied(microphone: true, speechRecognition: false).message)
        XCTAssertTrue(microphone.contains("allow Microphone for Smart Schedules in Settings"), microphone)
        let speech = try XCTUnwrap(VoiceInput.Access.denied(microphone: false, speechRecognition: true).message)
        XCTAssertTrue(speech.contains("allow Speech Recognition for Smart Schedules in Settings"), speech)
        let both = try XCTUnwrap(VoiceInput.Access.denied(microphone: true, speechRecognition: true).message)
        XCTAssertTrue(both.contains("Microphone and Speech Recognition"), both)
        XCTAssertTrue(VoiceInput.Access.denied(microphone: true, speechRecognition: false).opensSettings)
    }

    func testRestrictedCantBeFixedFromTheAppsSettings() throws {
        XCTAssertEqual(VoiceInput.access(microphone: .granted, speechRecognition: .restricted), .restricted)
        XCTAssertEqual(VoiceInput.access(microphone: .denied, speechRecognition: .restricted), .restricted)
        XCTAssertFalse(VoiceInput.Access.restricted.opensSettings)
        let message = try XCTUnwrap(VoiceInput.Access.restricted.message)
        XCTAssertTrue(message.contains("You can still type"), message)
    }

    // MARK: Deep link

    func testComposeVoiceAsksForTheMic() throws {
        XCTAssertTrue(DeepLink.startsVoiceInput(DeepLink.composeVoice))
        XCTAssertFalse(DeepLink.startsVoiceInput(DeepLink.compose))
        XCTAssertFalse(DeepLink.startsVoiceInput(DeepLink.event("abc")))
        XCTAssertFalse(DeepLink.startsVoiceInput(try XCTUnwrap(URL(string: "smartschedule://compose?mode=text"))))
        XCTAssertFalse(DeepLink.startsVoiceInput(try XCTUnwrap(URL(string: "https://example.com/compose?mode=voice"))))
        XCTAssertFalse(DeepLink.startsVoiceInput(try XCTUnwrap(URL(string: "smartschedule://event?mode=voice"))))
    }
}
