import AppIntents
import Foundation
import os

/// Control Center / Lock Screen / Action Button control (Artboard 3) and Siri: opens the app on Quick Capture with
/// the keyboard up, through the same deep link as the expanded Dynamic Island's Edit button (`DeepLink.compose`).
///
/// An `OpenIntent`, as Apple's "Creating controls to perform actions across the system" asks for a control that opens
/// the app on a given screen: the system brings the app to the front and runs `perform()` there, where the handler
/// the app installs at launch (`DeepLinkRequests.install`) opens Quick Capture at once. Compiled into both the app and
/// the widget extension, which the same page requires. No `openAppWhenRun` (deprecated in the iOS 26 SDK): set to
/// `true` it is an error when the intent runs in an app extension. The earlier plain intent most likely ran in the
/// widget extension whenever the app was not already running (installed without Xcode's debugger keeping it alive),
/// failed there before `perform()`, and the app opened on its main screen. Should `perform()` still run in
/// the widget extension, the link waits in the App Group and the app opens it when it comes forward
/// (`DeepLinkRequests`). Nothing here starts a Live Activity: the Dynamic Island shows only events about to start.
struct OpenQuickCaptureIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Quick Capture"
    static let description = IntentDescription("Opens Smart Schedules ready to type a plan.")

    /// The screen to open. `OpenIntent` needs one; Quick Capture is the only one.
    @Parameter(title: "Screen", default: .quickCapture)
    var target: QuickCaptureScreen

    /// The control's action: the target is set here as well as by the parameter's default, so the action the
    /// control saves always carries it (an intent waiting for a value never runs from a control).
    init() {
        self.target = .quickCapture
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkRequests.open(DeepLink.compose)
        // Which process ran it (the app, or the widget extension): Console.app, subsystem com.smartschedules.app,
        // category QuickCapture. Logged after the hand-off, so nothing can stand in its way.
        let process = Bundle.main.bundleIdentifier ?? "?"
        quickCaptureLog.notice("Open Quick Capture: perform() in \(process, privacy: .public)")
        return .result()
    }
}

/// The screens `OpenQuickCaptureIntent` opens: Quick Capture only.
enum QuickCaptureScreen: String, AppEnum {
    case quickCapture

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Smart Schedules screen"
    static let caseDisplayRepresentations: [QuickCaptureScreen: DisplayRepresentation] = [
        .quickCapture: "Quick Capture"
    ]
}

private let quickCaptureLog = Logger(subsystem: "com.smartschedules.app", category: "QuickCapture")
