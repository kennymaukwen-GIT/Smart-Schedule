import Foundation

/// The app's own voice input: the mic button in the chat composer and Quick Capture (`ComposerBar`), recorded by
/// App/Voice/VoiceTranscriber.swift. Owner decision 2026-10-18: speech is recognised on this iPhone only
/// (`requiresOnDeviceRecognition`, never Apple's servers), in Traditional Chinese (Taiwan) or US English. No audio is
/// written to disk or sent anywhere; the words fill the text field and nothing is sent until Send. Free: no
/// subscription involved. Only the app target has a microphone (this folder is not compiled into the widget or
/// notification extensions); scripts/validate_schema.py (check 9) keeps it that way.
///
/// These are its pure rules, tested hostless (VoiceInputTests).
enum VoiceInput {
    /// The recognizer locales voice input uses: Traditional Chinese (Taiwan) and US English.
    static let localeIdentifiers = ["zh-TW", "en-US"]

    /// What Settings › Assistant › Speech language offers.
    static let offeredLanguages: [SpeechLanguage] = [.automatic, .chineseTaiwan, .englishUS]

    /// The recognizer locale for Settings › Assistant › Speech language. Automatic follows the language of the app's
    /// screens (`appLanguage`, "zh-Hant" or "en"); English (UK), which an earlier build offered, is read as English (US).
    static func localeIdentifier(for language: SpeechLanguage, appLanguage: String) -> String {
        switch language {
        case .chineseTaiwan: "zh-TW"
        case .englishUS, .englishUK: "en-US"
        case .automatic: appLanguage.lowercased().hasPrefix("zh") ? "zh-TW" : "en-US"
        }
    }

    /// The recognizer locale for these preferences in this app.
    static func localeIdentifier(for preferences: AppPreferences) -> String {
        localeIdentifier(for: preferences.speechLanguage, appLanguage: appLanguage)
    }

    /// The language the app's screens are in (the String Catalog has en and zh-Hant).
    static var appLanguage: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    /// The picker's choice for a stored language (English (UK) from an earlier build shows as English (US)).
    static func offeredLanguage(_ language: SpeechLanguage) -> SpeechLanguage {
        language == .englishUK ? .englishUS : language
    }

    // MARK: When a recording stops by itself

    /// Once words were heard, this many seconds without new ones end the recording.
    static let silenceAfterWords: TimeInterval = 3
    /// With nothing heard yet, the recording gives up after this many seconds.
    static let silenceBeforeWords: TimeInterval = 8
    /// One recording lasts at most this long.
    static let maxDuration: TimeInterval = 60

    enum StopReason: Equatable, Sendable {
        case silence, nothingHeard, timeLimit
    }

    /// Why a recording that has run for `elapsed` seconds should stop now, or nil to keep listening.
    /// `sinceLastWords`: seconds since the words last changed; nil while nothing has been heard.
    static func stopReason(elapsed: TimeInterval, sinceLastWords: TimeInterval?) -> StopReason? {
        if elapsed >= maxDuration { return .timeLimit }
        if let sinceLastWords { return sinceLastWords >= silenceAfterWords ? .silence : nil }
        return elapsed >= silenceBeforeWords ? .nothingHeard : nil
    }

    // MARK: The text field

    /// What the field shows while recording: the text typed before the mic was tapped, then the words heard so far.
    /// A space separates them unless the typed text ends in whitespace or either side is Chinese (or Japanese or
    /// Korean), which is written without spaces.
    static func combined(typed: String, spoken: String) -> String {
        guard !spoken.isEmpty else { return typed }
        guard let last = typed.last else { return spoken }
        if last.isWhitespace || isCJK(last) || spoken.first.map(isCJK) == true { return typed + spoken }
        return typed + " " + spoken
    }

    /// CJK ideographs and punctuation, kana, Hangul and full-width forms.
    static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        return (0x2E80...0x9FFF).contains(scalar) || (0xAC00...0xD7AF).contains(scalar)
            || (0xF900...0xFAFF).contains(scalar) || (0xFF00...0xFFEF).contains(scalar)
            || (0x20000...0x3FFFF).contains(scalar)
    }

    // MARK: Permissions

    /// One of the two permissions voice input needs (microphone, speech recognition), as iOS reports it.
    enum Permission: Equatable, Sendable {
        case notDetermined, denied, restricted, granted
    }

    /// What a tap on the mic leads to. iOS asks for the permissions only on that tap, never earlier.
    enum Access: Equatable, Sendable {
        /// Both granted: recording starts.
        case ready
        /// At least one was never asked (and none refused): iOS asks now.
        case ask
        /// Refused in iOS's prompt or in Settings: an alert says which and opens the app's page in Settings.
        case denied(microphone: Bool, speechRecognition: Bool)
        /// Blocked by Screen Time or a device profile; the app's Settings page can't change it.
        case restricted
    }

    static func access(microphone: Permission, speechRecognition: Permission) -> Access {
        if microphone == .restricted || speechRecognition == .restricted { return .restricted }
        if microphone == .denied || speechRecognition == .denied {
            return .denied(microphone: microphone == .denied, speechRecognition: speechRecognition == .denied)
        }
        if microphone == .notDetermined || speechRecognition == .notDetermined { return .ask }
        return .ready
    }
}

extension VoiceInput.Access {
    /// The alert's text when the mic can't be used; nil when it can (`.ready`) or iOS is about to ask (`.ask`).
    var message: String? {
        switch self {
        case .ready, .ask:
            return nil
        case .denied(microphone: true, speechRecognition: true):
            return String(localized: "To speak instead of typing, allow Microphone and Speech Recognition for Smart Schedules in Settings.")
        case .denied(microphone: true, speechRecognition: false):
            return String(localized: "To speak instead of typing, allow Microphone for Smart Schedules in Settings.")
        case .denied:
            return String(localized: "To speak instead of typing, allow Speech Recognition for Smart Schedules in Settings.")
        case .restricted:
            return String(localized: "Voice input is restricted on this iPhone. You can still type your plan.")
        }
    }

    /// Whether the alert offers "Open Settings" (the app's page there has both switches).
    var opensSettings: Bool {
        if case .denied = self { return true }
        return false
    }
}
