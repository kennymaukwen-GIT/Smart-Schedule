import SwiftUI

/// "October 2026" card of Artboard 5: Sunday-first grid, adjacent-month days dimmed, today circled,
/// colored chips, task rows with checkboxes, multi-day bars ("Trip to San Diego") drawn as connected
/// segments across cells, "+N" overflow.
struct MonthGridView: View {
    let month: Date
    let today: Date
    let eventsOnDay: (Date) -> [ScheduleEvent]
    let onSelect: (ScheduleEvent) -> Void

    private let calendar = WallClock().calendar
    private let maxChips = 3

    var body: some View {
        let weeks = Self.weeks(for: month, calendar: calendar)
        let monthInterval = calendar.dateInterval(of: .month, for: month)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                // Badge: events left this month.
                Text("\(remainingCount(in: monthInterval))")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.white))
            }

            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { index in
                    Text(Theme.weekdayLetters[index])
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                }
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(weeks, id: \.self) { week in
                        HStack(alignment: .top, spacing: 0) { // spacing 0 lets multi-day segments touch
                            ForEach(week, id: \.self) { day in
                                DayCell(
                                    day: day,
                                    isInMonth: monthInterval.map { day >= $0.start && day < $0.end } ?? true,
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
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.surface))
    }

    private func remainingCount(in interval: DateInterval?) -> Int {
        guard let interval else { return 0 }
        var count = 0
        var day = max(calendar.startOfDay(for: today), interval.start)
        while day < interval.end {
            count += eventsOnDay(day).filter { !$0.isDraft && calendar.isDate($0.start, inSameDayAs: day) }.count
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return count
    }

    static func weeks(for month: Date, calendar: Calendar) -> [[Date]] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: month),
              var cursor = calendar.dateInterval(of: .weekOfYear, for: monthInterval.start)?.start else { return [] }
        var weeks: [[Date]] = []
        while cursor < monthInterval.end {
            weeks.append((0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: cursor) })
            cursor = calendar.date(byAdding: .day, value: 7, to: cursor)!
        }
        return weeks
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
