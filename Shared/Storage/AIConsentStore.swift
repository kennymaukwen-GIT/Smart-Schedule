import Foundation

/// The user's answer to "Use the AI assistant?" (App Store guideline 5.1.2(i): disclose what is sent to a
/// third-party AI and get permission first). Nothing personal reaches Gemini unless `isGranted`.
struct AIConsent: Codable, Hashable, Sendable {
    enum Status: String, Codable, Sendable { case notAsked, granted, declined, revoked }
    /// Bump when the disclosure (`AIConsentDisclosure`) changes materially: everyone is asked again.
    static let disclosureVersion = 1

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
        String(localized: "To understand your requests, Smart Schedule sends them to Google's Gemini API. This includes:")
    }

    static var items: [String] {
        [String(localized: "What you type or say to the assistant"),
         String(localized: "Titles, times and locations of your events in the days the request is about (the next two weeks by default)"),
         String(localized: "The names of your calendars and your assistant settings"),
         String(localized: "Your time zone and language")]
    }

    static var recipient: String { String(localized: "Recipient: Google, through the Gemini API.") }

    static var footnote: String {
        String(localized: "Nothing is sent until you tap Allow. You can stop sharing any time in Settings › AI & privacy. Demo mode works without sharing anything.")
    }
}
