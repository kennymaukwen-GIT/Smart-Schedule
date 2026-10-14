import SwiftUI

/// Month card of Artboard 5: weeks start on Settings › "Week starts on", adjacent-month days dimmed, today
/// circled, colored chips, task rows with checkboxes, multi-day bars ("Trip to San Diego") drawn as connected
/// segments across cells, "+N" overflow. Swipes sideways a month at a time with no end either way.
///
/// `month` (the view model's `displayedMonth`) is the source of truth both ways: a swipe that comes to rest
/// sets it, and setting it (a month chip, the assistant, the Today pill) pages there.
struct MonthGridView: View {
    @Binding var month: Date
    let today: Date
    let isLoading: Bool
    let eventsOnDay: (Date) -> [ScheduleEvent]
    let onSelect: (ScheduleEvent) -> Void
    /// False on the main screen, whose header already names the month.
    var showsTitle = true

    private let calendar = WallClock().calendar
    private let maxChips = 3
    /// The month at page 0; pages are month offsets from it.
    @State private var anchor: Date
    @State private var page: Int?

    init(month: Binding<Date>,
         today: Date,
         isLoading: Bool = false,
         showsTitle: Bool = true,
         eventsOnDay: @escaping (Date) -> [ScheduleEvent],
         onSelect: @escaping (ScheduleEvent) -> Void) {
        _month = month
        self.today = today
        self.isLoading = isLoading
        self.showsTitle = showsTitle
        self.eventsOnDay = eventsOnDay
        self.onSelect = onSelect
        _anchor = State(initialValue: CalendarPaging.monthStart(containing: month.wrappedValue,
                                                                calendar: WallClock().calendar))
        _page = State(initialValue: 0)
    }

    var body: some View {
        let monthInterval = CalendarPaging.monthInterval(containing: month, calendar: calendar)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if showsTitle {
                    Text(month.formatted(Date.FormatStyle(timeZone: calendar.timeZone).month(.wide).year()))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 6)
                CalendarStatusAccessory(showsToday: CalendarPaging.monthOffset(of: month, from: today,
                                                                               calendar: calendar) != 0,
                                        isLoading: isLoading,
                                        onToday: { month = CalendarPaging.monthStart(containing: today, calendar: calendar) })
                // Badge: events left this month.
                Text("\(remainingCount(in: monthInterval))")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.white))
            }

            HStack(spacing: 0) {
                ForEach(Array(Theme.weekdayLetters(firstWeekday: calendar.firstWeekday).enumerated()),
                        id: \.offset) { _, letter in
                    Text(letter)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                }
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(CalendarPaging.monthPages, id: \.self) { offset in
                            MonthWeeksPage(month: CalendarPaging.month(offset, from: anchor, calendar: calendar),
                                           today: today,
                                           eventsOnDay: eventsOnDay,
                                           maxChips: maxChips,
                                           calendar: calendar,
                                           onSelect: onSelect)
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
                    // reported the first page (a century back) through the binding: go by `month` instead.
                    let target = CalendarPaging.monthOffset(of: month, from: anchor, calendar: calendar)
                    page = target
                    proxy.scrollTo(target)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.surface))
        .onChange(of: month) { _, newMonth in
            show(newMonth)
        }
    }

    /// Pages to `newMonth` unless it is already on screen (as after a swipe).
    private func show(_ newMonth: Date) {
        let target = CalendarPaging.monthOffset(of: newMonth, from: anchor, calendar: calendar)
        guard target != page else { return }
        if CalendarPaging.isWithinReach(target, of: CalendarPaging.monthPages) {
            PagerScroll.move($page, to: target)
        } else {
            // Decades away: page 0 becomes that month.
            anchor = CalendarPaging.monthStart(containing: newMonth, calendar: calendar)
            page = 0
        }
    }

    /// Paging came to rest (after a swipe or an animated move). Runs once the position binding has caught up.
    private func settle() {
        Task { @MainActor in
            guard let page else { return }
            let shown = CalendarPaging.month(page, from: anchor, calendar: calendar)
            if !CalendarPaging.isWithinReach(page, of: CalendarPaging.monthPages) {
                // Half a century of swiping: re-centre on the same month, which looks exactly the same.
                anchor = shown
                self.page = 0
            }
            if CalendarPaging.monthOffset(of: shown, from: month, calendar: calendar) != 0 {
                withAnimation(.snappy) { month = shown }
            }
        }
    }

    private func remainingCount(in interval: DateInterval) -> Int {
        var count = 0
        var day = max(calendar.startOfDay(for: today), interval.start)
        while day < interval.end {
            count += eventsOnDay(day).filter { !$0.isDraft && calendar.isDate($0.start, inSameDayAs: day) }.count
            day = CalendarPaging.day(1, after: day, calendar: calendar)
        }
        return count
    }

    static func weeks(for month: Date, calendar: Calendar) -> [[Date]] {
        let grid = CalendarPaging.monthGridInterval(containing: month, calendar: calendar)
        var weeks: [[Date]] = []
        var cursor = grid.start
        while cursor < grid.end {
            weeks.append(CalendarPaging.days(ofWeekStarting: cursor, calendar: calendar))
            cursor = CalendarPaging.week(1, from: cursor, calendar: calendar)
        }
        return weeks
    }
}

/// The weeks of one month in the pager, scrolling vertically when they don't fit.
private struct MonthWeeksPage: View {
    let month: Date
    let today: Date
    let eventsOnDay: (Date) -> [ScheduleEvent]
    let maxChips: Int
    let calendar: Calendar
    let onSelect: (ScheduleEvent) -> Void

    var body: some View {
        let monthInterval = CalendarPaging.monthInterval(containing: month, calendar: calendar)

        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                ForEach(MonthGridView.weeks(for: month, calendar: calendar), id: \.self) { week in
                    HStack(alignment: .top, spacing: 0) { // spacing 0 lets multi-day segments touch
                        ForEach(week, id: \.self) { day in
                            DayCell(
                                day: day,
                                isInMonth: day >= monthInterval.start && day < monthInterval.end,
                                isToday: calendar.isDate(day, inSameDayAs: today),
                                events: eventsOnDay(day),
                                maxChips: maxChips,
                                calendar: calendar,
                                onSelect: onSelect
                            )
                        }
                    }
                }
            }
        }
    }
}

private struct DayCell: View {
    let day: Date
    let isInMonth: Bool
    let isToday: Bool
    let events: [ScheduleEvent]
    let maxChips: Int
    let calendar: Calendar
    let onSelect: (ScheduleEvent) -> Void

    var body: some View {
        VStack(spacing: 2) {
            Text("\(calendar.component(.day, from: day))")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(isToday ? Color.black : (isInMonth ? Color.white : Theme.textSecondary.opacity(0.6)))
                .frame(width: 24, height: 24)
                .background(Circle().fill(isToday ? Color.white : Color.clear))

            ForEach(events.prefix(maxChips)) { event in
                EventChip(event: event, day: day, calendar: calendar)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(event) }
            }
            if events.count > maxChips {
                Text("+\(events.count - maxChips)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .top)
        .opacity(isInMonth ? 1 : 0.55)
    }
}

private struct EventChip: View {
    let event: ScheduleEvent
    let day: Date
    let calendar: Calendar

    var body: some View {
        let tint = Color(hex: event.colorHex)
        let segment = Segment(event: event, day: day, calendar: calendar)

        HStack(spacing: 3) {
            if event.kind == .task {
                Image(systemName: event.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(tint)
            } else if !segment.isMultiDay {
                RoundedRectangle(cornerRadius: 1).fill(tint).frame(width: 2)
            }
            if event.isWaitingToSync && segment.isStart {
                PendingSyncGlyph(size: 6)
            }
            Text(segment.isStart ? event.title : " ")
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, minHeight: 13, maxHeight: 13, alignment: .leading)
        .background(
            UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: segment.isStart ? 3 : 0,
                bottomLeading: segment.isStart ? 3 : 0,
                bottomTrailing: segment.isEnd ? 3 : 0,
                topTrailing: segment.isEnd ? 3 : 0
            ))
            .fill(event.kind == .task ? Color.clear : tint.opacity(segment.isMultiDay ? 0.85 : 0.28))
        )
        .draftGhost(event.isDraft, shape: RoundedRectangle(cornerRadius: 3), tint: tint)
        .padding(.leading, segment.isStart ? 2 : 0)
        .padding(.trailing, segment.isEnd ? 2 : 0)
    }

    /// Position of `day` within a multi-day event, clipped to the week row.
    private struct Segment {
        let isMultiDay: Bool
        let isStart: Bool
        let isEnd: Bool

        init(event: ScheduleEvent, day: Date, calendar: Calendar) {
            let first = calendar.startOfDay(for: event.start)
            let last = calendar.startOfDay(for: event.end.addingTimeInterval(-1))
            let current = calendar.startOfDay(for: day)
            let weekday = calendar.component(.weekday, from: day)
            let lastColumn = (calendar.firstWeekday + 5) % 7 + 1
            isMultiDay = first != last
            isStart = !isMultiDay || current == first || weekday == calendar.firstWeekday
            isEnd = !isMultiDay || current == last || weekday == lastColumn
        }
    }
}
