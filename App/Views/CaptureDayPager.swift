import SwiftUI

/// DAY mode of Quick Capture: the hour grid of one day, swiped sideways a day at a time with no end either way.
/// `focusDay` is the source of truth both ways: a swipe that comes to rest makes its day the focus day (so the
/// header's date disc and month follow), and a new focus day (a tap in WEEK or MONTH, the assistant, the Today
/// pill) pages here.
struct CaptureDayPager: View {
    let focusDay: Date
    let now: Date
    let isLoading: Bool
    let eventsOnDay: (Date) -> [ScheduleEvent]
    let onSelectEvent: (ScheduleEvent) -> Void
    /// A swipe came to rest on this day, or the Today pill was tapped.
    let onSelectDay: (Date) -> Void
    /// The day on screen, on appear and whenever it changes, so its events can be loaded.
    let onRangeChange: (DateInterval) -> Void

    private let calendar = WallClock().calendar
    /// The day at page 0; pages are day offsets from it.
    @State private var anchor: Date
    @State private var page: Int?

    init(focusDay: Date,
         now: Date = Date(),
         isLoading: Bool = false,
         eventsOnDay: @escaping (Date) -> [ScheduleEvent],
         onSelectEvent: @escaping (ScheduleEvent) -> Void = { _ in },
         onSelectDay: @escaping (Date) -> Void = { _ in },
         onRangeChange: @escaping (DateInterval) -> Void = { _ in }) {
        self.focusDay = focusDay
        self.now = now
        self.isLoading = isLoading
        self.eventsOnDay = eventsOnDay
        self.onSelectEvent = onSelectEvent
        self.onSelectDay = onSelectDay
        self.onRangeChange = onRangeChange
        _anchor = State(initialValue: WallClock().calendar.startOfDay(for: focusDay))
        _page = State(initialValue: 0)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(CalendarPaging.dayPages, id: \.self) { offset in
                        let day = CalendarPaging.day(offset, after: anchor, calendar: calendar)
                        DayTimelineView(day: day, events: eventsOnDay(day), hourHeight: 46, onSelect: onSelectEvent)
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)
            .onScrollPhaseChange { _, phase in
                if phase == .idle { settle() }
            }
            .onAppear {
                // Lazy stacks don't always honor the initial position on first layout, and may already have
                // reported the first page (a century back) through the binding: go by `focusDay` instead.
                let target = CalendarPaging.dayOffset(of: focusDay, from: anchor, calendar: calendar)
                page = target
                proxy.scrollTo(target)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            CalendarStatusAccessory(showsToday: !calendar.isDate(focusDay, inSameDayAs: now),
                                    isLoading: isLoading,
                                    onToday: { onSelectDay(now) })
                .padding(8)
        }
        .onChange(of: calendar.startOfDay(for: focusDay), initial: true) { _, day in
            show(day)
            onRangeChange(CalendarPaging.dayInterval(containing: day, calendar: calendar))
        }
    }

    /// Pages to `day` unless it is already on screen (as after a swipe).
    private func show(_ day: Date) {
        let target = CalendarPaging.dayOffset(of: day, from: anchor, calendar: calendar)
        guard target != page else { return }
        if CalendarPaging.isWithinReach(target, of: CalendarPaging.dayPages) {
            PagerScroll.move($page, to: target)
        } else {
            // Decades away: page 0 becomes that day.
            anchor = day
            page = 0
        }
    }

    /// Paging came to rest (after a swipe or an animated move). Runs once the position binding has caught up.
    private func settle() {
        Task { @MainActor in
            guard let page else { return }
            let day = CalendarPaging.day(page, after: anchor, calendar: calendar)
            if !CalendarPaging.isWithinReach(page, of: CalendarPaging.dayPages) {
                // Half a century of swiping: re-centre on the same day, which looks exactly the same.
                anchor = day
                self.page = 0
            }
            if !calendar.isDate(day, inSameDayAs: focusDay) { onSelectDay(day) }
        }
    }
}
