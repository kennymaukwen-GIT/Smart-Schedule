import AppIntents
import SwiftUI
import WidgetKit

/// iOS 18 Control Center / Lock Screen / Action Button control (Artboard 3, left): opens Quick Capture.
/// Controls render only an SF Symbol (or an exported custom symbol) plus a title — export the app's clock
/// glyph as a `.symbolset` to match the icon exactly.
struct SmartScheduleControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: AppConstants.controlKind) {
            ControlWidgetButton(action: OpenQuickCaptureIntent()) {
                Label("Smart Schedule", systemImage: "clock")
            }
        }
        .displayName("Smart Schedule")
        .description("Opens Smart Schedule ready to type a plan.")
    }
}
