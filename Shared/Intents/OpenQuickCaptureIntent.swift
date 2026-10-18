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
/// `true` it is an error when the intent runs in an app extension, and on iOS 26 a control's intent ran in the
/// widget extension, so `perform()` never ran and the app opened on its main screen. Should `perform()` still run in
/// the widget extension, the link waits in the App Group and the app opens it when it comes forward
/// (`DeepLinkRequests`). Nothing here starts a Live Activity: the Dynamic Island shows only events about to start.
struct OpenQuickCaptureIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Quick Capture"
    static let description = IntentDescription("Opens Smart Schedules ready to type a plan.")

    /// The screen to open. `OpenIntent` needs one; Quick Capture is the only one.
    @Parameter(title: "Screen", default: .quickCapture)
    var target: QuickCaptureScreen

    init() {}

    init(target: QuickCaptureScreen) {
        self.target = target
    }

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

/// The screens `OpenQuickCaptureIntent` opens: Quick Capture only.
enum QuickCaptureScreen: String, AppEnum {
    case quickCapture

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Smart Schedules screen"
    static let caseDisplayRepresentations: [QuickCaptureScreen: DisplayRepresentation] = [
        .quickCapture: "Quick Capture"
    ]
}

private let quickCaptureLog = Logger(subsystem: "com.smartschedules.app", category: "QuickCapture")
