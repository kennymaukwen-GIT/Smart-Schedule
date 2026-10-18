import Foundation

/// The user's answer to "Use the AI assistant?" (App Store guideline 5.1.2(i): disclose what is sent to a
/// third-party AI and get permission first). Nothing personal reaches Gemini unless `isGranted`.
struct AIConsent: Codable, Hashable, Sendable {
    enum Status: String, Codable, Sendable { case notAsked, granted, declined, revoked }
    /// Bump when the disclosure (`AIConsentDisclosure`) changes materially: everyone is asked again.
    /// 2: names the transcript of spoken requests, and on iOS 18 the event titles and times kept on the server.
    /// 3: requests pass through Smart Schedule's server; on iOS 18 the end times and calendar colours are kept too.
    /// 4: no Google account email address reaches Gemini (calendars are "Account 1", "Account 2"); names the 14-day /
    /// 40-event window, Google event IDs, locations only for AI suggestions, Apple's push service on iOS 18 and Apple
    /// speech recognition.
    /// 5: version 1.0 has no Live Activity push-to-start (`AppConstants.pushToStartEnabled` false), so the iOS 18 note
    /// on event titles kept on Smart Schedule's server and sent through Apple's push service is gone
    /// (`AIConsentDisclosure.serverNote`). Turning push-to-start on brings that note back: bump again then.
    /// Still 5 after the app's own microphone was removed before 1.0 shipped (2026-10-16): only `speechNote` changed
    /// (Siri and the keyboard's dictation instead of the On-device recognition setting); the lead, the five items and
    /// the recipient, quoted word for word in the privacy policy's section 4, are unchanged.
    /// Still 5 after the app's own voice input came back, recognised on the iPhone only, before 1.0 shipped (2026-10-18):
    /// only `speechNote` changed again (it adds the microphone button); the lead, the five items and the recipient are
    /// unchanged.
    /// Still 5 after demo mode started using the AI before 1.0 shipped (2026-10-17): only `footnote` changed (demo mode
    /// sends the sample calendars and events instead of never contacting the AI); the lead, the five items and the
    /// recipient quoted in the policy's section 4 are unchanged.
    /// 6: names photo and PDF attachments ("A photo or PDF you attach (only when you attach one and send)", the second
    /// item, quoted word for word in the privacy policy's section 4). Everyone who allowed version 5 on TestFlight is
    /// asked again, as the policy's section 18 promises when what is sent changes.
    /// 7: version 1.0 has no photo or PDF attachments (they move to 1.1), so the attachment item is gone and the five
    /// items quoted in the privacy policy's section 4 are back; everyone who allowed version 6 on TestFlight is asked
    /// again. 1.1 brings the item back with version 8.
    static let disclosureVersion = 7

    var status: Status = .notAsked
    var version = 0                 // disclosure version the decision applies to
    var decidedAt: Date?

    var isGranted: Bool { status == .granted && version >= Self.disclosureVersion }

    init(status: Status = .notAsked, version: Int = 0, decidedAt: Date? = nil) {
        self.status = status
        self.version = version
        self.decidedAt = decidedAt
    }

    /// Tolerant: an unreadable status (a newer build's) reads as not asked, so the user is simply asked again.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? c.decodeIfPresent(Status.self, forKey: .status)) ?? .notAsked
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 0
        decidedAt = try? c.decodeIfPresent(Date.self, forKey: .decidedAt)
    }
}

/// App Group `UserDefaults` key "SSAIConsent" (JSON), so the app, Siri and the notification extension read the same
/// answer synchronously. Every write posts `SharedChange.consent`.
enum AIConsentStore {
    static let defaultsKey = "SSAIConsent"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: AppConstants.appGroupID) }

    static var current: AIConsent { current(in: defaults) }
    static func grant() { record(.granted, in: defaults) }
    static func decline() { record(.declined, in: defaults) }
    static func revoke() { record(.revoked, in: defaults) }

    /// Erase all data: back to not asked.
    static func reset() { reset(in: defaults) }

    // Explicit defaults for unit tests (a hostless test bundle has no App Group).

    static func current(in defaults: UserDefaults?) -> AIConsent {
        guard let data = defaults?.data(forKey: defaultsKey) else { return AIConsent() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(AIConsent.self, from: data)) ?? AIConsent()
    }

    static func record(_ status: AIConsent.Status, in defaults: UserDefaults?, now: Date = Date()) {
        let consent = AIConsent(status: status, version: AIConsent.disclosureVersion, decidedAt: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(consent) else { return }
        defaults?.set(data, forKey: defaultsKey)
        SharedChangeNotifier.post(.consent)
    }

    static func reset(in defaults: UserDefaults?) {
        defaults?.removeObject(forKey: defaultsKey)
        SharedChangeNotifier.post(.consent)
    }
}

/// The wording of the consent sheet and of Settings › AI & privacy › "What is sent": the single source, so both say
/// the same. Never claim that Google does not use the data for training: that is only true on Gemini's paid tier.
enum AIConsentDisclosure {
    static var title: String { String(localized: "Use the AI assistant?") }

    static var lead: String {
        String(localized: "To understand your requests, Smart Schedules sends them to Google's Gemini API. This includes:")
    }

    /// Exactly what `AssistantPrompt` and `NoteSuggestionPrompt` send (docs/GEMINI_FUNCTION_CALLING.md §10.6): no
    /// account email address, since calendars are named through `CalendarAliases`. The five items are quoted word for
    /// word in the privacy policy's section 4 (docs/SETTINGS.md §8.2).
    static var items: [String] {
        [String(localized: "What you type or say to the assistant (spoken requests as text), including any names or email addresses you mention"),
         String(localized: "Titles, times, notes and Google event IDs of up to 40 events in the 14 days from today, and of the event whose reminder you reply to"),
         String(localized: "For AI suggestions on an event: that event only, including its location"),
         String(localized: "Your calendar names and assistant settings, but not your Google account email addresses"),
         String(localized: "Your time zone and language")]
    }

    static var recipient: String {
        String(localized: "Recipient: Google, through the Gemini API. Requests pass through the Smart Schedules server, which doesn't keep them.")
    }

    /// iOS 18 cannot start a Live Activity on its own, so with push-to-start a server does it; on iOS 26 the iPhone
    /// schedules them itself. nil in version 1.0 on every iOS: push-to-start is off (`AppConstants.pushToStartEnabled`)
    /// and nothing about events is kept on the server.
    static var serverNote: String? {
        if #available(iOS 26.0, *) { return serverNote(beforeIOS26: false) }
        return serverNote(beforeIOS26: true)
    }

    static func serverNote(beforeIOS26: Bool) -> String? {
        serverNote(beforeIOS26: beforeIOS26, pushToStart: AppConstants.pushToStartEnabled)
    }

    /// `pushToStart`: `AppConstants.pushToStartEnabled`, a parameter so tests can check the wording kept for a later
    /// version that turns it on (which also bumps `AIConsent.disclosureVersion`).
    static func serverNote(beforeIOS26: Bool, pushToStart: Bool) -> String? {
        guard beforeIOS26, pushToStart else { return nil }
        return String(localized: "On iOS 18, the titles, start and end times, event IDs and calendar colours of your events in the next 48 hours are also kept on the Smart Schedules server and sent through Apple's push service, so each one can appear in the Dynamic Island before it starts. Notes and places are not stored.")
    }

    /// Spoken requests reach the assistant only as text: Siri (the App Intents) and the keyboard's dictation are Apple's;
    /// the app's microphone button (App/Voice/VoiceTranscriber) recognises speech on the iPhone only and keeps no audio.
    static var speechNote: String {
        String(localized: "If you speak to Siri or use the keyboard's dictation, Apple turns your speech into text. The microphone button in Smart Schedules does it on your iPhone. Smart Schedules sends only the text, never audio.")
    }

    /// Demo mode asks the same way (`DemoModeAssistant`); what it sends are the fictional sample calendars and events.
    static var footnote: String {
        String(localized: "Nothing is sent to the AI until you tap Allow. You can stop sharing any time in Settings › AI & privacy. Demo mode sends the sample calendars and events instead of your Google Calendar.")
    }
}
