import AppIntents
import Foundation
import os

/// Control Center / Lock Screen / Action Button control (Artboard 3) and Siri: opens the app on Quick Capture with
/// the keyboard up, through the same deep link as the expanded Dynamic Island's Edit button (`DeepLink.compose`).
///
/// iOS 18: `openAppWhenRun` brings the app to the front and runs `perform()` in the app's process, which hands the
/// link to the router at once; without it a control's intent runs silently in the background. iOS 26 deprecates
/// `openAppWhenRun` for `supportedModes` and runs a control's intent in the widget extension, in the background,
/// whatever the modes say (Apple, "Configuring the runtime behavior of your app intents"): there the link waits in
/// the App Group and the app opens it when it hears `SharedChange.deepLink` or becomes active (`DeepLinkRequests`).
/// Nothing here starts a Live Activity: the Dynamic Island shows only events about to start. Compiled into both
/// the app and the widget extension because the ControlWidget references the type.
struct OpenQuickCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Quick Capture"
    static let description = IntentDescription("Opens Smart Schedules ready to type a plan.")
    /// iOS 18–25. Deprecated in the iOS 26 SDK ("Use supportedModes instead"), still allowed for back-deployment.
    static var openAppWhenRun: Bool = true

    /// iOS 26's replacement for `openAppWhenRun`: the app comes to the foreground before `perform()` runs
    /// (`.foreground` is the same mode). Apple calls the modes a suggestion; for a control the system may still run
    /// `perform()` in the widget extension, which `DeepLinkRequests` covers. Computed, so it can carry `@available`.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        // Which process ran it (app or widget extension) and, on iOS 26, in which mode: Console.app, subsystem
        // com.smartschedules.app, category QuickCapture.
        let process = Bundle.main.bundleIdentifier ?? "?"
        if #available(iOS 26.0, *) {
            let mode = String(describing: systemContext.currentMode)
            quickCaptureLog.notice("Open Quick Capture: perform() in \(process, privacy: .public), mode \(mode, privacy: .public)")
        } else {
            quickCaptureLog.notice("Open Quick Capture: perform() in \(process, privacy: .public)")
        }
        DeepLinkRequests.open(DeepLink.compose)
        return .result()
    }
}

private let quickCaptureLog = Logger(subsystem: "com.smartschedules.app", category: "QuickCapture")
