import SwiftUI

/// WEEK mode of Quick Capture: a "This week" card with Sunday-first columns, time + title chips under each day
/// and multi-day events as bars across the top. Pages sideways one week at a time; "SCROLL →" advances a page.
struct WeekAgendaCard: View {
    let events: [ScheduleEvent]
    let focusDay: Date
    let now: Date
    let revealRequest: ScheduleViewModel.FocusRequest?
    let onSelectEvent: (ScheduleEvent) -> Void
    let onSelectDay: (Date) -> Void

    /// Weeks reachable by paging, as offsets from the current week.
    static let pages = -8...26

    private let calendar: Calendar
    private let thisWeek: Date
    @State private var currentPage: Int

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
        _currentPage = State(initialValue: Self.page(showing: focusDay, thisWeek: thisWeek, calendar: calendar))
    }

    var body: some View {
        TabView(selection: $currentPage) {
            ForEach(Self.pages, id: \.self) { offset in
                WeekPage(
                    offset: offset,
                    weekStart: CalendarPaging.week(offset, from: thisWeek, calendar: calendar),
                    events: events,
                    focusDay: focusDay,
                    now: now,
                    calendar: calendar,
                    onSelectEvent: onSelectEvent,
                    onSelectDay: onSelectDay
                )
                .tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(CaptureCardBackground())
        .clipShape(RoundedRectangle(cornerRadius: CaptureCardBackground.radius, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if currentPage < Self.pages.upperBound {
                Button {
                    withAnimation(.snappy) { currentPage += 1 }
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
        }
        .onChange(of: revealRequest) { _, request in
            guard let request else { return }
            let target = Self.page(showing: request.range.start, thisWeek: thisWeek, calendar: calendar)
            withAnimation(.snappy) { currentPage = target }
        }
    }

    private static func page(showing date: Date, thisWeek: Date, calendar: Calendar) -> Int {
        let offset = CalendarPaging.weekOffset(of: date, from: thisWeek, calendar: calendar)
        return min(max(offset, pages.lowerBound), pages.upperBound)
    }
}

private struct WeekPage: View {
    let offset: Int
    let weekStart: Date
    let events: [ScheduleEvent]
    let focusDay: Date
    let now: Date
    let calendar: Calendar
    let onSelectEvent: (ScheduleEvent) -> Void
    let onSelectDay: (Date) -> Void

    private static let barHeight: CGFloat = 12
    private static let laneSpacing: CGFloat = 2

    var body: some View {
        let layout = CalendarPaging.weekLayout(startingAt: weekStart, events: events, calendar: calendar)
        let range = CalendarPaging.rangeTitle(
            DateInterval(start: weekStart, end: max(weekStart, CalendarPaging.week(1, from: weekStart, calendar: calendar))),
            calendar: calendar,
            locale: .autoupdatingCurrent
        )

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                title(range: range)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if (-1...1).contains(offset) {
                    Text(range)
                        .font(.system(size: 9, weight: .medium))
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
                .padding(.bottom, 30) // keeps the last chips clear of the SCROLL button
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
    }

    private func title(range: String) -> Text {
        switch offset {
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
