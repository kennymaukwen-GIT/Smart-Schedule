import SwiftUI

/// MONTH mode of Quick Capture: continuous weeks that scroll vertically (no month pages), snapping to whole
/// rows. Titled with the first and last visible dates ("Oct 4 – Nov 7"); the badge counts the focus day's events.
/// Opens one week before the focus week so the days just gone stay in view.
struct MonthScrollCard: View {
    let events: [ScheduleEvent]
    let focusDay: Date
    let now: Date
    let revealRequest: ScheduleViewModel.FocusRequest?
    let onSelectEvent: (ScheduleEvent) -> Void
    let onSelectDay: (Date) -> Void

    /// Rows that can be scrolled to, as week offsets from the current week (about six months back, a year ahead).
    static let weeks = -26...52
    private static let rowRange = 3...5
    private static let minimumRowHeight = 34.0

    private let calendar: Calendar
    private let thisWeek: Date
    private let initialTopWeek: Int
    @State private var topWeek: Int?
    @State private var visibleRows = 5 // rowRange.upperBound until the first layout

    init(events: [ScheduleEvent],
         focusDay: Date,
         now: Date = Date(),
         revealRequest: ScheduleViewModel.FocusRequest? = nil,
         onSelectEvent: @escaping (ScheduleEvent) -> Void = { _ in },
         onSelectDay: @escaping (Date) -> Void = { _ in }) {
        let calendar = WallClock().calendar
        let thisWeek = CalendarPaging.weekStart(containing: now, calendar: calendar)
        self.events = events
        self.focusDay = focusDay
        self.now = now
        self.revealRequest = revealRequest
        self.onSelectEvent = onSelectEvent
        self.onSelectDay = onSelectDay
        self.calendar = calendar
        self.thisWeek = thisWeek

        // Opened by a month-sized request ("show me November"): start on that range, not a week before it.
        let showsRequestedMonth = revealRequest.map {
            CalendarScope.fitting($0.range, calendar: calendar) == .month
                && calendar.isDate($0.range.start, inSameDayAs: focusDay)
        } ?? false
        let top = Self.firstRow(showing: focusDay, leadWeeks: showsRequestedMonth ? 0 : 1,
                               thisWeek: thisWeek, calendar: calendar)
        initialTopWeek = top
        _topWeek = State(initialValue: top)
    }

    var body: some View {
        let top = topWeek ?? initialTopWeek
        let first = CalendarPaging.week(top, from: thisWeek, calendar: calendar)
        let window = DateInterval(start: first, end: max(first, CalendarPaging.week(visibleRows, from: first, calendar: calendar)))
        let referenceMonth = CalendarPaging.referenceMonth(of: window, calendar: calendar)
        let focusCount = CalendarPaging.events(on: focusDay, from: events, calendar: calendar).filter { !$0.isDraft }.count

        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center) {
                Text(CalendarPaging.rangeTitle(window, calendar: calendar, locale: .autoupdatingCurrent))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Text("\(focusCount)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.black)
                    .padding(.horizontal, focusCount > 9 ? 4 : 0)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(Color.white))
                    .accessibilityLabel("\(focusCount) events on the selected day")
            }

            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { index in
                    Text(Theme.weekdayLetters[index])
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                }
            }

            GeometryReader { geo in
                let rows = CalendarPaging.visibleWeekCount(forHeight: Double(geo.size.height),
                                                           minimumRowHeight: Self.minimumRowHeight,
                                                           range: Self.rowRange)
                let rowHeight = geo.size.height / CGFloat(rows)

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(Self.weeks, id: \.self) { offset in
                                MonthWeekRow(
                                    weekStart: CalendarPaging.week(offset, from: thisWeek, calendar: calendar),
                                    events: events,
                                    referenceMonth: referenceMonth,
                                    now: now,
                                    focusDay: focusDay,
                                    calendar: calendar,
                                    onSelectEvent: onSelectEvent,
                                    onSelectDay: onSelectDay
                                )
                                .frame(height: rowHeight)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: $topWeek)
                    .onAppear {
                        // Belt and braces for the initial `topWeek`: lazy stacks don't always honor it on first
                        // layout (and may already have reported row `weeks.lowerBound` back through the binding).
                        proxy.scrollTo(initialTopWeek, anchor: .top)
                    }
                }
                .onChange(of: rows, initial: true) { _, newValue in
                    visibleRows = newValue
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(CaptureCardBackground())
        .clipShape(RoundedRectangle(cornerRadius: CaptureCardBackground.radius, style: .continuous))
        .onChange(of: revealRequest) { _, request in
            guard let request else { return }
            let lead = CalendarScope.fitting(request.range, calendar: calendar) == .month ? 0 : 1
            let target = Self.firstRow(showing: request.range.start, leadWeeks: lead, thisWeek: thisWeek, calendar: calendar)
            withAnimation(.snappy) { topWeek = target }
        }
    }

    private static func firstRow(showing date: Date, leadWeeks: Int, thisWeek: Date, calendar: Calendar) -> Int {
        let offset = CalendarPaging.weekOffset(of: date, from: thisWeek, calendar: calendar) - leadWeeks
        return min(max(offset, weeks.lowerBound), weeks.upperBound - (rowRange.upperBound - 1))
    }
}

/// One week of the month grid: date numbers, multi-day bars in lanes, then chips; "+N" when a day overflows.
private struct MonthWeekRow: View {
    let weekStart: Date
    let events: [ScheduleEvent]
    let referenceMonth: DateInterval?
    let now: Date
    let focusDay: Date
    let calendar: Calendar
    let onSelectEvent: (ScheduleEvent) -> Void
    let onSelectDay: (Date) -> Void

    /// Date number plus the gap under it.
    private static let dateBlock: CGFloat = 18
    /// One chip or bar line (9 pt) plus a 1 pt gap.
    private static let line: CGFloat = 10

    var body: some View {
        let layout = CalendarPaging.weekLayout(startingAt: weekStart, events: events, calendar: calendar)

        GeometryReader { geo in
            let lines = max(0, Int(((geo.size.height - Self.dateBlock) / Self.line).rounded(.down)))
            ZStack(alignment: .topLeading) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(layout.days.enumerated()), id: \.offset) { column, day in
                        cell(day: day, column: column, layout: layout, lines: lines)
                    }
                }
                CaptureSpanBars(spans: layout.spans,
                                visibleLanes: lines,
                                barHeight: Self.line - 1,
                                laneSpacing: 1,
                                topInset: Self.dateBlock,
                                fontSize: 6.5,
                                onSelect: onSelectEvent)
            }
        }
        .clipped()
    }

    private func cell(day: Date, column: Int, layout: CalendarPaging.WeekLayout, lines: Int) -> some View {
        let plan = CalendarPaging.cellLayout(column: column, in: layout, lines: lines)
        let isInMonth = referenceMonth.map { day >= $0.start && day < $0.end } ?? true

        return VStack(spacing: 0) {
            CaptureDayNumber(day: day,
                             calendar: calendar,
                             isToday: calendar.isDate(day, inSameDayAs: now),
                             isFocused: calendar.isDate(day, inSameDayAs: focusDay),
                             diameter: 16,
                             fontSize: 9.5)
                .frame(maxWidth: .infinity)
                .frame(height: Self.dateBlock - 1)
                .padding(.bottom, 1)
                .contentShape(Rectangle())
                .onTapGesture { onSelectDay(day) }

            Color.clear.frame(height: CGFloat(plan.barLines) * Self.line)

            ForEach(layout.singles[column].prefix(plan.chips)) { event in
                MonthEventChip(event: event)
                    .frame(height: Self.line - 1)
                    .padding(.bottom, 1)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelectEvent(event) }
            }

            if plan.more > 0 {
                Text("+\(plan.more)")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.leading, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: Self.line - 1)
            }
        }
        .padding(.horizontal, 1.5)
        .frame(maxWidth: .infinity, alignment: .top)
        .opacity(isInMonth ? 1 : 0.45)
    }
}

/// Single-line chip: colored bar for events, check circle for tasks.
private struct MonthEventChip: View {
    let event: ScheduleEvent

    var body: some View {
        let isTask = event.kind == .task
        let tint = isTask ? CaptureChipStyle.taskTint : Color(hex: event.colorHex)

        HStack(spacing: 2) {
            if isTask {
                Image(systemName: event.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 5.5, weight: .bold))
                    .foregroundStyle(tint)
            }
            Text(event.title)
                .font(.system(size: 6.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.leading, isTask ? 1 : 4)
        .padding(.trailing, 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            if !isTask {
                tint.frame(width: 2)
            }
        }
        .background(tint.opacity(isTask ? 0 : 0.3))
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .draftGhost(event.isDraft, shape: RoundedRectangle(cornerRadius: 2, style: .continuous), tint: tint)
    }
}
