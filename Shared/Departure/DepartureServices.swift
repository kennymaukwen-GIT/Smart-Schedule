import Foundation

/// What 「該出發了」 needs from the iPhone and the server, behind protocols so ScheduleAssistant's flow (build step G4d) is
/// tested with fakes. The app builds the real one and installs it (build step G4e); nothing installs it in the
/// extensions, so there the feature is always off.
struct DepartureServices: Sendable {
    var routing: any DepartureRouting
    var location: any LocationProviding
    /// Decided once per request, before Gemini is asked. Must answer at once: no network, no waiting for StoreKit.
    var availability: @Sendable () async -> DepartureAvailability
    var consent: DepartureConsentStore
    /// The app's language for Google's text ("zh-Hant", "en"), and the iPhone's region for Google's region bias.
    var appLanguage: String?
    var isoRegion: String?
    /// True only in Debug builds (`#if DEBUG`).
    var debugBuild: Bool
    /// Asks 「使用 Google 地圖規劃出發時間？」 and waits for the answer: true for Allow, false for Not now. Called only
    /// while `consent` is not asked yet, right before the first plan would get the location or ask Google (build step
    /// G4e shows the dialog). Unset, nothing is ever allowed.
    var askConsent: @Sendable () async -> Bool = { false }
    /// The time, read only to measure how long that first question waited for the user: the plan is then checked
    /// against the later time (the time to be there may have passed meanwhile).
    var currentTime: @Sendable () -> Date = { Date() }
}

/// Where ScheduleAssistant gets its departure services.
enum DepartureSource: Sendable {
    /// What the app installed (`DepartureHook`): nothing in the extensions and in tests.
    case installed
    /// Off.
    case none
    /// Tests.
    case given(DepartureServices)

    var services: DepartureServices? {
        switch self {
        case .installed: DepartureHook.installed
        case .none: nil
        case let .given(services): services
        }
    }
}

/// The app installs its departure services here once, at launch (build step G4e). Tests never install it, so it
/// can't leak between them; they pass `DepartureSource.given` instead.
enum DepartureHook {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: DepartureServices?

    static func install(_ services: DepartureServices) {
        lock.withLock { current = services }
    }

    static var installed: DepartureServices? {
        lock.withLock { current }
    }
}
