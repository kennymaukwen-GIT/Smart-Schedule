import Foundation

/// Identifiers shared by the app, the widget extension and the notification content extension.
/// Values that differ per developer account are injected through each target's Info.plist (see project.yml).
enum AppConstants {
    static let appGroupID = "group.com.smartschedule.shared"
    static let urlScheme = "smartschedule"
    static let backgroundRefreshTaskID = "com.smartschedule.refresh"
    static let controlKind = "com.smartschedule.control.summon"

    /// Per-activity update tokens (`.token`): the Worker has no route for them yet, so keep false. Independent of
    /// `pushToStartEnabled`, but like it needs the aps-environment entitlement, which version 1.0 does not have
    /// (project.yml; scripts/validate_schema.py checks the two agree).
    static let liveActivityPushEnabled = false

    /// iOS 18 Live Activity push-to-start: `ActivityScheduler` registers the planned events with
    /// `PushToStartRegistrar`, the app uploads them (POST /devices/push-to-start) and the Worker's cron sends an APNs
    /// push at each trigger time. Version 1.0 does not use it, so this stays false: no push-to-start token is asked
    /// for or observed, no registration is written or uploaded, nothing about events is kept on Smart Schedule's
    /// server and the app has no APNs entitlement. iOS 26 still schedules each Live Activity on the iPhone
    /// (`Activity.request(…, start:)`); on iOS 18 one appears only when the app runs within the lead time or while the
    /// event is under way (it then stays after the app closes). The consent text
    /// (`AIConsentDisclosure.serverNote`) and the Dynamic Island footer in Settings follow it; "Erase all data" then
    /// only removes what an earlier build may have left on the iPhone, with no request
    /// (`PushToStartRegistrar.forgetLocally`). A build-time constant on purpose. Turning it on takes, besides a new
    /// build and App Review: aps-environment, APS_ENVIRONMENT and the remote-notification background mode back in
    /// project.yml, the APNs secrets and `crons = ["* * * * *"]` in server/worker/wrangler.toml, a new
    /// `AIConsent.disclosureVersion`, and the privacy policy, privacy manifests and App Privacy answers.
    /// scripts/validate_schema.py and ReleaseConfigurationTests fail while it is true.
    static let pushToStartEnabled = false

    /// Smart Schedules Pro (StoreKit 2, App/Store). Version 1.0 sells nothing, so this stays false: the account sheet
    /// has no Pro section, the avatar is "Accounts", the erase message does not mention subscriptions, and StoreKit is
    /// never called (no transaction listener, no product request, no entitlement check). A build-time constant on
    /// purpose: turning it on takes a new build and App Review. scripts/validate_schema.py and
    /// ReleaseConfigurationTests fail while it is true.
    static let subscriptionsEnabled = false

    // MARK: Demo mode

    /// Demo mode runs on `DemoData`'s sample calendars, without a Google account. Its assistant (`DemoModeAssistant`)
    /// is Gemini on those samples once AI data sharing is allowed, and the offline `DemoAssistant` rules otherwise.
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
    /// Kept for compatibility (Shared API, links already out there): 1.0 has no in-app speech input, so it opens
    /// Quick Capture exactly like `compose`, keyboard up (`AppRouter.handle` ignores `mode`).
    static let composeVoice = URL(string: "smartschedule://compose?mode=voice")!

    static func event(_ id: String) -> URL {
        var components = URLComponents()
        components.scheme = AppConstants.urlScheme
        components.host = "event"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url!
    }
}
