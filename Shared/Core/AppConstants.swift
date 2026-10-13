import Foundation

/// Identifiers shared by the app, the widget extension and the notification content extension.
/// Values that differ per developer account are injected through each target's Info.plist (see project.yml).
enum AppConstants {
    static let appGroupID = "group.com.smartschedule.shared"
    static let urlScheme = "smartschedule"
    static let backgroundRefreshTaskID = "com.smartschedule.refresh"
    static let controlKind = "com.smartschedule.control.summon"

    /// Keep false until APNs + a backend exist. With `.token` the Live Activity can be updated
    /// (and restarted after the 8-hour cap via push-to-start) from the server.
    static let liveActivityPushEnabled = false

    // MARK: Demo mode

    /// Demo mode runs on `DemoData` and the offline `DemoAssistant`: no Google account, no Gemini key.
    ///
    /// The flag lives in the App Group defaults so the notification content extension (its own process) sees it.
    /// `UserDefaults.standard` is the fallback because a launch argument `-SSDemoMode YES` (Xcode → Edit Scheme →
    /// Run → Arguments) only lands in the launched process's argument domain; the app copies it into the App Group
    /// on launch. While that argument is set it wins over `setDemoMode(false)` in the app process.
    static let demoModeKey = "SSDemoMode"

    static var isDemoMode: Bool {
        UserDefaults(suiteName: appGroupID)?.bool(forKey: demoModeKey) == true
            || UserDefaults.standard.bool(forKey: demoModeKey)
    }

    static func setDemoMode(_ on: Bool) {
        UserDefaults(suiteName: appGroupID)?.set(on, forKey: demoModeKey)
        UserDefaults.standard.set(on, forKey: demoModeKey)
    }

    /// `$(AppIdentifierPrefix)com.smartschedule.shared` — the team prefix is only known at build time.
    static var keychainAccessGroup: String? { infoValue("SSKeychainAccessGroup") }
    static var googleClientID: String { infoValue("SSGoogleClientID") ?? "" }
    static var googleReversedClientID: String { infoValue("SSGoogleReversedClientID") ?? "" }

    private static func infoValue(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    static func info(_ key: String) -> String? { infoValue(key) }
}

/// Deep links used by Dynamic Island / Lock Screen `Link`s. Tapping one opens the app straight
/// into the Quick Capture overlay (Artboard 4), never the full month view.
enum DeepLink {
    static let compose = URL(string: "smartschedule://compose")!
    static let composeVoice = URL(string: "smartschedule://compose?mode=voice")!

    static func event(_ id: String) -> URL {
        var components = URLComponents()
        components.scheme = AppConstants.urlScheme
        components.host = "event"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url!
    }
}
