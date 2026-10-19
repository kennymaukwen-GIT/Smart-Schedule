import Foundation

/// Hands a deep link from an App Intent to the app's router (`AppRouter.handle`).
///
/// The Control Center button's `OpenQuickCaptureIntent` is an `OpenIntent`: the system brings the app to the front
/// and runs it in the app's process, where the app installs `handler` at launch, and the link is handled at once.
/// Should the intent run in the widget extension instead (Apple: "For WidgetKit controls in a Widget extension, the
/// system runs the control's app intent from the extension in the background"), `handler` is nil there: the link
/// waits in the App Group, recent for `maxAge`, and `SharedChange.deepLink` is posted. The app comes forward before
/// or after that write, so it looks at cold start (the app's `.task`), on becoming active, once more
/// `lateWriteDelay` later, and on hearing `.deepLink` while not in the background (`routePending`). Taking the link
/// removes it, so whichever finds it first opens Quick Capture, once.
@MainActor
enum DeepLinkRequests {
    private static var handler: (@MainActor (URL) -> Void)?
    static let pendingURLKey = "deepLink.pendingURL"
    static let pendingDateKey = "deepLink.pendingDate"
    /// A link older than this was not meant for the app that is opening now.
    static let maxAge: TimeInterval = 60
    /// With nothing waiting on becoming active, the app looks once more this much later: the extension's write can
    /// land just after the app comes forward.
    static let lateWriteDelay: Duration = .milliseconds(500)

    /// iOS 26: after the scene opened Quick Capture for a Control Center tap, the same tap's `perform()` (or its App Group
    /// hand-off) arrives within this many seconds and is skipped once (`isSceneEcho`).
    nonisolated static let sceneEchoWindow: TimeInterval = 10

    /// Whether `url`, arriving from the Control Center intent's `perform()` or its App Group hand-off, repeats the Quick
    /// Capture the scene already opened at `sceneOpenedAt` for the same tap. Only plain `DeepLink.compose` counts: the
    /// control never sends the voice link, and the island's links don't come this way.
    nonisolated static func isSceneEcho(_ url: URL, sceneOpenedAt: Date?, now: Date) -> Bool {
        guard let sceneOpenedAt, url == DeepLink.compose else { return false }
        let age = now.timeIntervalSince(sceneOpenedAt)
        return age >= 0 && age < sceneEchoWindow
    }

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
        guard let defaults else { return }
        // Date first: whoever sees the URL (the key takePending checks) also sees its date.
        defaults.set(now.timeIntervalSince1970, forKey: pendingDateKey)
        defaults.set(url.absoluteString, forKey: pendingURLKey)
        // Written through before the post, so the app finds the link when it hears about it. The widget extension
        // may be stopped as soon as the intent returns.
        defaults.synchronize()
        SharedChangeNotifier.post(.deepLink)
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

    /// Hands the waiting link (`takePending`) to `route` and says whether there was one. The app calls it on
    /// becoming active, `lateWriteDelay` after that, and on `.deepLink`: the first call takes the link, the others
    /// find nothing, so Quick Capture opens once.
    @discardableResult
    static func routePending(defaults: UserDefaults? = UserDefaults(suiteName: AppConstants.appGroupID),
                             now: Date = Date(),
                             to route: (URL) -> Void) -> Bool {
        guard let url = takePending(defaults: defaults, now: now) else { return false }
        route(url)
        return true
    }
}
