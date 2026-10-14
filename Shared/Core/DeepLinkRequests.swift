import Foundation

/// Hands a deep link from an App Intent to the app's router (`AppRouter.handle`).
///
/// An intent with `openAppWhenRun` (the Control Center button's `OpenQuickCaptureIntent`) runs in the app's process,
/// where the app installs `handler` at launch. Should it run anywhere else (the widget extension, which compiles the
/// intent too), the link waits in the App Group and the app opens it when it next becomes active, if it is recent.
@MainActor
enum DeepLinkRequests {
    private static var handler: (@MainActor (URL) -> Void)?
    static let pendingURLKey = "deepLink.pendingURL"
    static let pendingDateKey = "deepLink.pendingDate"
    /// A link older than this was not meant for the app that is opening now.
    static let maxAge: TimeInterval = 60

    static func install(_ newHandler: @escaping @MainActor (URL) -> Void) {
        handler = newHandler
    }

    static func open(_ url: URL,
                     defaults: UserDefaults? = UserDefaults(suiteName: AppConstants.appGroupID),
                     now: Date = Date()) {
        if let handler {
            handler(url)
            return
        }
        defaults?.set(url.absoluteString, forKey: pendingURLKey)
        defaults?.set(now.timeIntervalSince1970, forKey: pendingDateKey)
    }

    /// The waiting link, once: nil when there is none or it is older than `maxAge`.
    static func takePending(defaults: UserDefaults? = UserDefaults(suiteName: AppConstants.appGroupID),
                            now: Date = Date()) -> URL? {
        guard let defaults, let text = defaults.string(forKey: pendingURLKey) else { return nil }
        let sent = defaults.double(forKey: pendingDateKey)
        defaults.removeObject(forKey: pendingURLKey)
        defaults.removeObject(forKey: pendingDateKey)
        let age = now.timeIntervalSince1970 - sent
        guard age >= 0, age <= maxAge else { return nil }
        return URL(string: text)
    }
}
