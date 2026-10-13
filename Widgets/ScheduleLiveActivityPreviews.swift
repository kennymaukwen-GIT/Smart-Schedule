#if DEBUG
import ActivityKit
import SwiftUI
import WidgetKit

// Xcode Canvas previews of the four Live Activity presentations (Artboards 2 & 3). `ContentState.demo()` is built
// from `DemoData`, so no ActivityKit request, network or keychain access happens here.

#Preview("Island · expanded", as: .dynamicIsland(.expanded), using: ScheduleActivityAttributes()) {
    ScheduleLiveActivity()
} contentStates: {
    ScheduleActivityAttributes.ContentState.demo()
}

#Preview("Island · compact", as: .dynamicIsland(.compact), using: ScheduleActivityAttributes()) {
    ScheduleLiveActivity()
} contentStates: {
    ScheduleActivityAttributes.ContentState.demo()
}

#Preview("Island · minimal", as: .dynamicIsland(.minimal), using: ScheduleActivityAttributes()) {
    ScheduleLiveActivity()
} contentStates: {
    ScheduleActivityAttributes.ContentState.demo()
}

#Preview("Lock Screen", as: .content, using: ScheduleActivityAttributes()) {
    ScheduleLiveActivity()
} contentStates: {
    ScheduleActivityAttributes.ContentState.demo()
}
#endif
