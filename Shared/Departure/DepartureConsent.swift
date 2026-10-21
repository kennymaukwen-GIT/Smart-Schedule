import Foundation

/// The user's answer to 「使用 Google 地圖規劃出發時間？」 (docs/SETTINGS.md §7.11, owner decision 2026-10-20), asked in
/// the chat before anything goes to Google for the first time: what is sent (the starting point, the destination and
/// the time to arrive) and to whom. Google's user data policy, App Store Review Guideline 5.1.2(i) and Google Maps
/// Platform terms §4.4(c)(iii) all need an affirmative answer first. Not now turns the feature off (owner decision 3A);
/// the switch in Settings › Assistant changes the answer later.
enum DepartureConsent: String, Sendable, CaseIterable {
    /// Not asked yet: the assistant may plan, and the app asks before the first request goes out.
    case notAsked
    case allowed
    /// Not now, or the switch turned off: the assistant behaves exactly as without the feature.
    case declined
}

/// Where the answer is kept: one key in the app's own UserDefaults (only the app plans departures), erased with the
/// app's other data. Never sent anywhere.
struct DepartureConsentStore: Sendable {
    static let key = "departureConsent"
    /// nil = `UserDefaults.standard`; tests pass their own suite.
    var suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    func read() -> DepartureConsent {
        defaults.string(forKey: Self.key).flatMap(DepartureConsent.init(rawValue:)) ?? .notAsked
    }

    func write(_ consent: DepartureConsent) {
        defaults.set(consent.rawValue, forKey: Self.key)
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}
