import SwiftUI

/// WEEK mode of Quick Capture: a "This week" card with Sunday-first columns, time + title chips under each day
/// and multi-day events as bars across the top. Pages sideways one week at a time with no end either way:
/// "SCROLL →" advances a page, and the Today pill comes back to this week.
struct WeekAgendaCard: View {
    let events: [ScheduleEvent]
    let focusDay: Date
    let now: Date
    let revealRequest: ScheduleViewModel.FocusRequest?
    let isLoading: Bool
    let onSelectEvent: (ScheduleEvent) -> Void
    let onSelectDay: (Date) -> Void
    /// The week on screen, on appear and whenever paging comes to rest, so its events can be loaded.
    let onRangeChange: (DateInterval) -> Void

    private let calendar: Calendar
    private let thisWeek: Date
    /// The week at page 0; pages are week offsets from it.
    @State private var anchor: Date
    @State private var currentPage: Int?

    init(events: [ScheduleEvent],
         focusDay: Date,
         now: Date = Date(),
         revealRequest: ScheduleViewModel.FocusRequest? = nil,
         isLoading: Bool = false,
         onSelectEvent: @escaping (ScheduleEvent) -> Void = { _ in },
         onSelectDay: @escaping (Date) -> Void = { _ in },
         onRangeChange: @escaping (DateInterval) -> Void = { _ in }) {
        let calendar = WallClock().calendar
        self.events = events
        self.focusDay = focusDay
        self.now = now
        self.revealRequest = revealRequest
        self.isLoading = isLoading
        self.onSelectEvent = onSelectEvent
        self.onSelectDay = onSelectDay
        self.onRangeChange = onRangeChange
        self.calendar = calendar
        self.thisWeek = CalendarPaging.weekStart(containing: now, calendar: calendar)
        _anchor = State(initialValue: CalendarPaging.weekStart(containing: focusDay, calendar: calendar))
        _currentPage = State(initialValue: 0)
    }

    private var shownWeek: DateInterval {
        CalendarPaging.weekInterval(containing: CalendarPaging.week(currentPage ?? 0, from: anchor, calendar: calendar),
                                    calendar: calendar)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(CalendarPaging.weekPages, id: \.self) { offset in
                        let weekStart = CalendarPaging.week(offset, from: anchor, calendar: calendar)
                        WeekPage(
                            relativeWeek: CalendarPaging.weekOffset(of: weekStart, from: thisWeek, calendar: calendar),
                            weekStart: weekStart,
                            events: events,
                            focusDay: focusDay,
                            now: now,
                            calendar: calendar,
                            onSelectEvent: onSelectEvent,
                            onSelectDay: onSelectDay
                        )
                        .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentPage)
            .onScrollPhaseChange { _, phase in
                if phase == .idle { settle() }
            }
            .onAppear {
                // Lazy stacks don't always honor the initial position on first layout.
                proxy.scrollTo(currentPage ?? 0)
                onRangeChange(shownWeek)
            }
        }
        .background(CaptureCardBackground())
        .clipShape(RoundedRectangle(cornerRadius: CaptureCardBackground.radius, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            Button {
                PagerScroll.move($currentPage, to: (currentPage ?? 0) + 1)
            } label: {
                HStack(spacing: 3) {
                    Text("SCROLL")
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.35)))
            }
            .buttonStyle(.plain)
            .padding(8)
            .accessibilityLabel("Next week")
        }
        .overlay(alignment: .bottomLeading) {
            CalendarStatusAccessory(showsToday: CalendarPaging.weekOffset(of: shownWeek.start, from: thisWeek,
                                                                          calendar: calendar) != 0,
                                    isLoading: isLoading,
                                    onToday: showToday)
                .padding(8)
        }
        .onChange(of: revealRequest) { _, request in
            guard let request else { return }
            show(request.range.start)
        }
    }

    private func showToday() {
        show(now)
        onSelectDay(now)
    }

    private func show(_ date: Date) {
        let target = CalendarPaging.weekOffset(of: date, from: anchor, calendar: calendar)
        guard target != currentPage else { return }
        if CalendarPaging.isWithinReach(target, of: CalendarPaging.weekPages) {
            PagerScroll.move($currentPage, to: target)
        } else {
            // Decades away: page 0 becomes that week. Nothing scrolls, so report the range here.
            anchor = CalendarPaging.weekStart(containing: date, calendar: calendar)
            currentPage = 0
            onRangeChange(CalendarPaging.weekInterval(containing: date, calendar: calendar))
        }
    }

    /// Paging came to rest (after a swipe or an animated move). Runs once the position binding has caught up.
    private func settle() {
        Task { @MainActor in
            guard let page = currentPage else { return }
            if !CalendarPaging.isWithinReach(page, of: CalendarPaging.weekPages) {
                // Half a century of swiping: re-centre on the same week, which looks exactly the same.
                anchor = CalendarPaging.week(page, from: anchor, calendar: calendar)
                currentPage = 0
            }
            onRangeChange(shownWeek)
        }
    }
}

private struct WeekPage: View {
    /// Weeks from the current one: 0 is "This week".
    let relativeWeek: Int
    let weekStart: Date
    let events: [ScheduleEvent]
    let focusDay: Date
    let now: Date
    let calendar: Calendar
    let onSelectEvent: (ScheduleEvent) -> Void
    let onSelectDay: (Date) -> Void

    private static let barHeight: CGFloat = 12
    private static let laneSpacing: CGFloat = 2

    @Environment(\.locale) private var environmentLocale

    var body: some View {
        let layout = CalendarPaging.weekLayout(startingAt: weekStart, events: events, calendar: calendar)
        let week = DateInterval(start: weekStart,
                                end: max(weekStart, CalendarPaging.week(1, from: weekStart, calendar: calendar)))
        let range = CalendarPaging.rangeTitle(week, calendar: calendar, locale: .autoupdatingCurrent)

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                title(range: range)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if (-1...1).contains(relativeWeek) {
                    Text(range)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                } else if let year = CalendarPaging.yearLabel(for: week, now: now, calendar: calendar,
                                                              locale: ChatFormat.dateLocale(environmentLocale)) {
                    // Far pages are titled with dates alone; this says which year they are in.
                    Text(verbatim: year)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 0) {
                ForEach(layout.days, id: \.self) { day in
                    VStack(spacing: 2) {
                        Text(day, format: .dateTime.weekday(.abbreviated))
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        CaptureDayNumber(day: day,
                                         calendar: calendar,
                                         isToday: calendar.isDate(day, inSameDayAs: now),
                                         isFocused: calendar.isDate(day, inSameDayAs: focusDay))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelectDay(day) }
                }
            }

            if layout.laneCount > 0 {
                CaptureSpanBars(spans: layout.spans,
                                barHeight: Self.barHeight,
                                laneSpacing: Self.laneSpacing,
                                onSelect: onSelectEvent)
                    .frame(height: CGFloat(layout.laneCount) * (Self.barHeight + Self.laneSpacing))
            }

            ScrollView(.vertical, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(layout.singles.enumerated()), id: \.offset) { _, dayEvents in
                        VStack(spacing: 3) {
                            ForEach(dayEvents) { event in
                                Button { onSelectEvent(event) } label: {
                                    WeekEventChip(event: event)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 1.5)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .padding(.bottom, 30) // keeps the last chips clear of the Today pill and SCROLL
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
    }

    private func title(range: String) -> Text {
        switch relativeWeek {
        case 0: return Text("This week")
        case 1: return Text("Next week")
        case -1: return Text("Last week")
        default: return Text(range)
        }
    }
}

/// Two-line chip: start time, then the title. Tasks get a check circle instead of the colored bar.
private struct WeekEventChip: View {
    let event: ScheduleEvent

    var body: some View {
        let isTask = event.kind == .task
        let tint = isTask ? CaptureChipStyle.taskTint : Color(hex: event.colorHex)

        HStack(alignment: .top, spacing: 2) {
            if isTask {
                Image(systemName: event.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(tint)
                    .padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if event.isAllDay {
                        Text("All day")
                    } else {
                        Text(event.start, format: .dateTime.hour().minute())
                    }
                }
                .font(.system(size: 6, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                Text(event.title)
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .lineLimit(1)
        }
        .padding(.leading, isTask ? 2 : 5)
        .padding(.trailing, 2)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            if !isTask {
                tint.frame(width: 2)
            }
        }
        .background(tint.opacity(isTask ? 0.2 : 0.28))
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .draftGhost(event.isDraft, shape: RoundedRectangle(cornerRadius: 3, style: .continuous), tint: tint)
    }
}
