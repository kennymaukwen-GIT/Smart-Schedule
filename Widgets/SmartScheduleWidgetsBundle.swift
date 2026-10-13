import SwiftUI
import WidgetKit

@main
struct SmartScheduleWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ScheduleLiveActivity()
        SmartScheduleControl()
    }
}
