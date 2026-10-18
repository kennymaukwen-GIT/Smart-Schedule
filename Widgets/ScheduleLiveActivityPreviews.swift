#if DEBUG
import ActivityKit
import SwiftUI
import WidgetKit

// Xcode Canvas previews of the four Live Activity presentations (Artboards 2 & 3). The states are built from
// `DemoData` and `ContentState.sampleMorning()`, so no ActivityKit request, network or keychain access happens here.
// The expanded island and the Lock Screen show, in turn: the tallest layout (time and place, three "Up next" rows
// and "+1"), the demo week, "Nothing else today", and no event at all.

#Preview("Island · expanded", as: .dynamicIsland(.expanded), using: ScheduleActivityAttributes()) {
    ScheduleLiveActivity()
} contentStates: {
    ScheduleActivityAttributes.ContentState.sampleMorning()
    ScheduleActivityAttributes.ContentState.demo()
    PreviewIslandStates.nothingElseToday
    PreviewIslandStates.nothingNext
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
    ScheduleActivityAttributes.ContentState.sampleMorning()
    ScheduleActivityAttributes.ContentState.demo()
    PreviewIslandStates.nothingElseToday
    PreviewIslandStates.nothingNext
}

enum PreviewIslandStates {
    /// The sample drop-off with nothing after it that day or the next.
    static var nothingElseToday: ScheduleActivityAttributes.ContentState {
        var state = ScheduleActivityAttributes.ContentState.sampleMorning()
        state.upNext = []
        state.upNextMore = 0
        return state
    }

    /// No event coming: the headline only, no "Up next".
    static var nothingNext: ScheduleActivityAttributes.ContentState {
        LiveActivityStateBuilder.build(events: [], lastLine: nil)
    }
}
#endif
