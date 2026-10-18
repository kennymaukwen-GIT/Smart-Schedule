#if DEBUG
import ActivityKit
import SwiftUI
import WidgetKit

// Xcode Canvas previews of the four Live Activity presentations (Artboards 2 & 3). The states are built from
// `DemoData` and `ContentState.sampleMorning()`, so no ActivityKit request, network or keychain access happens here.
// The expanded island and the Lock Screen show, in turn: the tallest layout (time and place; built for the next
// 07:55 still to come, so its bar and capsule usually stand still), the bar a third full before the start (built
// around the canvas's clock, so it fills and agrees with the capsule), the bar full under way (the capsule counting
// to the end), the demo
// week's next event, its "Ended" last look (no bar), and no event at all (no bar).

#Preview("Island · expanded", as: .dynamicIsland(.expanded), using: ScheduleActivityAttributes()) {
    ScheduleLiveActivity()
} contentStates: {
    ScheduleActivityAttributes.ContentState.sampleMorning()
    PreviewIslandStates.beforeStart
    PreviewIslandStates.underWay
    ScheduleActivityAttributes.ContentState.demo()
    PreviewIslandStates.ended
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
    PreviewIslandStates.beforeStart
    PreviewIslandStates.underWay
    ScheduleActivityAttributes.ContentState.demo()
    PreviewIslandStates.ended
    PreviewIslandStates.nothingNext
}

enum PreviewIslandStates {
    /// The sample drop-off 20 minutes before its start, its activity shown 10 minutes ago: the bar a third full,
    /// beside "20:00" counting to the start. Built around the canvas's clock, as the island is built around
    /// the iPhone's.
    static var beforeStart: ScheduleActivityAttributes.ContentState {
        let now = Date()
        var state = ScheduleActivityAttributes.ContentState.sampleMorning()
        state.isInProgress = false
        state.progressStart = now.addingTimeInterval(-10 * 60)
        state.countdownFrom = now
        state.eventStart = now.addingTimeInterval(20 * 60)
        state.countdownTarget = state.eventStart
        state.eventEnd = now.addingTimeInterval(50 * 60)
        return state
    }

    /// The sample drop-off ten minutes in, 20 minutes left: the bar full (the start has come), the capsule counting
    /// to its end.
    static var underWay: ScheduleActivityAttributes.ContentState {
        let now = Date()
        var state = ScheduleActivityAttributes.ContentState.sampleMorning()
        state.isInProgress = true
        state.eventStart = now.addingTimeInterval(-10 * 60)
        state.eventEnd = now.addingTimeInterval(20 * 60)
        state.countdownFrom = now
        state.countdownTarget = state.eventEnd
        return state
    }

    /// The sample drop-off's last look once over (as `ActivityScheduler.finalContent` makes it): "Ended", no bar.
    static var ended: ScheduleActivityAttributes.ContentState {
        var state = ScheduleActivityAttributes.ContentState.sampleMorning()
        state.isInProgress = false
        state.countdownTarget = nil
        state.eventEnd = nil
        state.hasEnded = true
        return state
    }

    /// No event coming: the headline only, no bar.
    static var nothingNext: ScheduleActivityAttributes.ContentState {
        LiveActivityStateBuilder.build(events: [], lastLine: nil)
    }
}
#endif
