import Foundation

extension ScheduleActivityAttributes.ContentState {
    /// Island / Lock Screen state built from `DemoData` — for Xcode Previews and demo mode. Pure value
    /// construction; no ActivityKit request is made.
    static func demo(now: Date = Date()) -> Self {
        LiveActivityStateBuilder.build(events: DemoData.events(now: now),
                                       lastLine: "Added: Gym · Mon 18:30",
                                       now: now)
    }
}
