import AppIntents
import Foundation

/// Control Center / Lock Screen / Action Button control (Artboard 3) and Siri: opens the app on Quick Capture with
/// the keyboard up, through the same deep link as the Live Activity's input pill (`DeepLink.compose`).
///
/// `openAppWhenRun` brings the app to the front; without it a control's intent runs silently in the background.
/// Nothing here starts a Live Activity: the Dynamic Island shows only events about to start. Compiled into both
/// the app and the widget extension because the ControlWidget references the type.
struct OpenQuickCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Quick Capture"
    static let description = IntentDescription("Opens Smart Schedules ready to type a plan.")
    static var openAppWhenRun: Bool = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkRequests.open(DeepLink.compose)
        return .result()
    }
}
