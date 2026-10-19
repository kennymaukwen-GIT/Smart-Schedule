import SwiftUI

/// One page of Quick Capture's DAY pager (CaptureDayPager): the day as an hour grid, after Apple Calendar in the
/// app's black and white.
///
/// - Always the whole day, 00:00–24:00 ("HH:00" labels whatever the 12/24-hour setting, design 04). It opens with
///   the hour about an hour before now at the top (today), before where the day's timed events begin (another
///   day), or 08:00 (`DayTimelineLayout.openingHour`). Another day follows events that arrive later until the grid
///   is scrolled by hand; today stays put (no jump under a finger as the hour moves on).
/// - Timed events are blocks as tall as they last (24 pt at least, so a 10-minute item can still be tapped): white
///   with a stripe in the calendar's colour, peach deadlines, a ring before a task's title, drafts ghosted. Events
///   that overlap sit side by side in equal columns (`DayTimelineLayout.slots`); events from the evening before or
///   running past midnight are cut at the day's edges. Past events are dimmed.
/// - All-day events, and timed ones lasting through the whole day, are chips above the grid (two, then "+N").
/// - Today, a red line marks the time `now`. CaptureDayPager moves it on once a minute with its one `MinuteTick`
///   loop, outside the lazy pages: no page runs a timer of its own, and no `TimelineView` (the drawer froze with
///   nested ones: Shared/Core/MinuteTick.swift, CalendarDrawer.tickEveryMinute).
/// - Each page sets its scroll position once per day it shows, when its height is first known; later height changes
///   (the keyboard, the conversation's handle) leave the grid where it is. Quick Capture stopped opening after this
///   view arrived (2026-10-18), and a page re-scrolling on every height change inside the lazy day pager was one of
///   the suspects.
struct DayTimelineView: View {
    let day: Date
    let events: [ScheduleEvent]
    var now: Date = Date()
    var hourHeight: CGFloat = 56
    var onSelect: (ScheduleEvent) -> Void = { _ in }

    private let calendar = WallClock().calendar
    /// This grid's own offset. A `ScrollViewReader` here could also move the pager around the page (its
    /// `scrollTo` lines the target up in every enclosing scroll view), so a page appearing mid-swipe would pull the
    /// pager to itself; a `ScrollPosition` moves only this scroll view. `isPositionedByUser` says it was scrolled
    /// by hand, after which nothing moves it until the page shows another day.
    @State private var position = ScrollPosition(edge: .top)
    /// The day this page last put its opening hour on top for: once per day shown.
    @State private var positionedDay: Date?
    /// The grid's visible height, so a late opening hour stops at 24:00 instead of scrolling past it.
    @State private var viewportHeight: CGFloat = 0
    /// The whole page: caps the expanded all-day strip and tells narrow columns.
    @State private var pageSize: CGSize = .zero

    var body: some View {
        let interval = CalendarPaging.dayInterval(containing: day, calendar: calendar)
        let current = now
        let isToday = calendar.isDate(day, inSameDayAs: current)
        let allDay = events.filter { Self.goesAboveGrid($0, on: interval) }
        let timed = events.filter { !Self.goesAboveGrid($0, on: interval) }
        let slots = DayTimelineLayout.slots(
            for: timed.map { DayTimelineLayout.Item(id: $0.id, start: $0.start, end: $0.end) },
            in: interval,
            calendar: calendar,
            // As drawn, so blocks that don't touch on screen (30-minute ones back to back) stay full width.
            minimumMinutes: DayTimelineLayout.minutes(
                spanning: Double(DayMetrics.minimumBlockHeight - 2 * DayBlocksLayout.inset),
                hourHeight: Double(hourHeight))
        )
        let firstStart = Self.firstMoment(of: timed, in: interval)
        let opening = DayTimelineLayout.openingHour(day: interval, now: current, firstStart: firstStart,
                                                    calendar: calendar)
        let nowMinute: Double? = isToday ? DayTimelineLayout.minute(of: current, in: interval, calendar: calendar) : nil
        let contentHeight = DayMetrics.topInset + 24 * hourHeight + DayMetrics.bottomInset
        let blockArea = (pageSize.width > 0 ? pageSize.width : DayMetrics.typicalPageWidth)
            - DayMetrics.blocksLeading - DayMetrics.blocksTrailing
        // Expanded, the all-day chips take at most 40% of the page (less the strip's padding): the grid keeps the
        // rest, also in the short calendar while the keyboard is up or the conversation is pulled up.
        let chipsCap: CGFloat? = pageSize.height > 0 ? max(AllDayStrip.chipHeight, pageSize.height * 0.4 - 12) : nil

        VStack(spacing: 0) {
            if !allDay.isEmpty {
                AllDayStrip(events: allDay, maxChipsHeight: chipsCap, onSelect: onSelect)
                Rectangle()
                    .fill(DayMetrics.hourLine)
                    .frame(height: 0.5)
            }

            ScrollView(.vertical, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    HourGrid(hourHeight: hourHeight, nowMinute: nowMinute)

                    DayBlocksLayout(height: contentHeight,
                                    leading: DayMetrics.blocksLeading,
                                    trailing: DayMetrics.blocksTrailing) {
                        ForEach(slots, id: \.itemID) { slot in
                            let event = timed[slot.index]
                            let top = DayMetrics.topInset + CGFloat(slot.startMinute / 60) * hourHeight
                            let height = max(DayMetrics.minimumBlockHeight,
                                             CGFloat((slot.endMinute - slot.startMinute) / 60) * hourHeight)
                            let width = blockArea / CGFloat(max(1, slot.columns)) * CGFloat(max(1, slot.span))
                                - 2 * DayBlocksLayout.inset
                            let time = blockTime(of: event)
                            Button { onSelect(event) } label: {
                                TimelineBlock(event: event,
                                              height: height - 2 * DayBlocksLayout.inset,
                                              isNarrow: width < DayMetrics.narrowBlockWidth,
                                              time: time,
                                              isPast: event.end < current)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: event.title))
                            .accessibilityValue(Text(verbatim: spokenDetails(of: event, time: time.range)))
                            .layoutValue(key: BlockPlacementKey.self,
                                         value: BlockPlacement(top: top, height: height, column: slot.column,
                                                               columns: slot.columns, span: slot.span))
                        }
                    }

                    if let nowMinute {
                        NowLine(minute: nowMinute)
                            .offset(y: DayMetrics.topInset + CGFloat(nowMinute / 60) * hourHeight
                                    - NowLine.height / 2)
                    }
                }
                .frame(height: contentHeight, alignment: .top)
            }
            .scrollPosition($position)
            // A page of the DAY pager: only up and down here, sideways is the pager's.
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                viewportHeight = height
                // Once per day shown: the first layout with a height puts the opening hour on top. Later heights
                // (the keyboard, the conversation's handle) leave the grid where it is.
                guard height > 0, positionedDay != interval.start, !position.isPositionedByUser else { return }
                positionedDay = interval.start
                scroll(to: opening, viewport: height, contentHeight: contentHeight)
            }
            .onAppear {
                // Only if the height callback has not placed it yet; refined by it once the height is known.
                guard positionedDay != interval.start else { return }
                scroll(to: opening, viewport: viewportHeight, contentHeight: contentHeight)
                if viewportHeight > 0 { positionedDay = interval.start }
            }
            .onChange(of: interval.start) {
                // The pager re-anchored, so this page now shows another day: start over from its opening hour.
                positionedDay = viewportHeight > 0 ? interval.start : nil
                scroll(to: opening, viewport: viewportHeight, contentHeight: contentHeight)
            }
            .onChange(of: firstStart) {
                // Another day's events arrived after the page appeared. Today opens by the clock instead, and
                // doesn't move on with it: the grid would slide under a reader's finger every hour.
                guard !isToday, !position.isPositionedByUser else { return }
                withAnimation(.snappy) {
                    scroll(to: opening, viewport: viewportHeight, contentHeight: contentHeight)
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            pageSize = size
        }
    }

    /// All-day events, and timed ones lasting through the whole day (the middle days of a trip, or exactly
    /// 00:00–24:00): as a block they would hold a column all day and halve everything else.
    private static func goesAboveGrid(_ event: ScheduleEvent, on day: DateInterval) -> Bool {
        event.isAllDay || (event.start <= day.start && event.end >= day.end)
    }

    /// Where another day's timed events begin: the first one starting that day, or else where one carried over
    /// from the evening before ends. A night's sleep 23:00–07:00 opens the next day near 07:00, not at 00:00.
    private static func firstMoment(of timed: [ScheduleEvent], in day: DateInterval) -> Date? {
        timed.map(\.start).filter { $0 >= day.start && $0 < day.end }.min()
            ?? timed.map(\.end).filter { $0 > day.start && $0 < day.end }.min()
    }

    /// The opening hour's row at the top: its top is `topInset` above the hour line, so the label is whole. Late
    /// hours stop where 24:00 meets the bottom (once the grid's height is known).
    private func scroll(to hour: Int, viewport: CGFloat, contentHeight: CGFloat) {
        var y = CGFloat(hour) * hourHeight
        if viewport > 0 {
            y = min(y, max(0, contentHeight - viewport))
        }
        position.scrollTo(y: y)
    }

    /// "09:00–10:30", or "9:00 AM–10:30 AM": the iPhone's 12/24-hour setting, in the time zone of Settings ›
    /// "Time zone". The real times, also for an event cut at midnight. The start alone is for a column too narrow
    /// for the range.
    private func blockTime(of event: ScheduleEvent) -> BlockTime {
        let style = Date.FormatStyle(locale: .autoupdatingCurrent, timeZone: calendar.timeZone).hour().minute()
        let start = event.start.formatted(style)
        guard event.end > event.start else { return BlockTime(range: start, start: start) }
        return BlockTime(range: start + "–" + event.end.formatted(style), start: start)
    }

    /// Time, place and sync state for VoiceOver, which reads the title as the label.
    private func spokenDetails(of event: ScheduleEvent, time: String) -> String {
        var parts = [time]
        if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            parts.append(location)
        }
        if event.isWaitingToSync { parts.append(String(localized: "Waiting to sync")) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Metrics

private enum DayMetrics {
    /// Hour labels: right-aligned in this column, clear of the card's rounded edge.
    static let labelLeading: CGFloat = 4
    static let labelWidth: CGFloat = 36
    /// Where the hour lines start.
    static let gridLeading: CGFloat = 46
    /// Where event blocks start and end.
    static let blocksLeading: CGFloat = 48
    static let blocksTrailing: CGFloat = 8
    /// Above the 00:00 line, so its label is not cut, and below the 24:00 line, clear of the Today pill.
    static let topInset: CGFloat = 8
    static let bottomInset: CGFloat = 36
    static let minimumBlockHeight: CGFloat = 24
    /// Narrower blocks (four or more columns on most iPhones) give the time line to the title.
    static let narrowBlockWidth: CGFloat = 76
    /// The page's width before it is measured: the card on a 6.1-inch iPhone.
    static let typicalPageWidth: CGFloat = 345

    static let hourLine = Color.white.opacity(0.12)
    static let halfHourLine = Color.white.opacity(0.05)
    /// iOS's dark-mode red, like Apple Calendar's line.
    static let now = Color(hex: "#FF453A")
}

/// An hour row of the grid. Ids in the grid have types of their own: the pager's `ScrollViewReader` around the
/// pages scrolls to Int page offsets, and must not find anything inside a page.
private struct HourAnchor: Hashable {
    let hour: Int

    static let day = (0..<24).map(HourAnchor.init(hour:))
}

/// A block's or chip's identity: its event's position in the day's list (event ids can repeat across calendars).
private struct ItemID: Hashable {
    let index: Int

    static func all<T>(_ items: [T]) -> [ItemID] {
        items.indices.map(ItemID.init(index:))
    }
}

private extension DayTimelineLayout.Slot {
    var itemID: ItemID { ItemID(index: index) }
}

// MARK: - Grid

/// 24 rows, each with its hour line, a fainter half-hour line and its label, and the 24:00 line under them.
private struct HourGrid: View {
    let hourHeight: CGFloat
    /// Today: the time, whose own label replaces the hour label it would cover.
    let nowMinute: Double?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(HourAnchor.day, id: \.self) { anchor in
                row(anchor.hour)
            }
            line(DayMetrics.hourLine)
                .offset(y: DayMetrics.topInset)
                .frame(maxWidth: .infinity, minHeight: DayMetrics.topInset + DayMetrics.bottomInset,
                       maxHeight: DayMetrics.topInset + DayMetrics.bottomInset, alignment: .topLeading)
        }
        .accessibilityHidden(true)
    }

    /// Row `hour` starts `hour × hourHeight` down and its line `topInset` lower, so scrolling the row's top to the
    /// top of the grid keeps its label whole.
    private func row(_ hour: Int) -> some View {
        ZStack(alignment: .topLeading) {
            if showsLabel(hour) {
                Text(verbatim: String(format: "%02d:00", hour))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .frame(width: DayMetrics.labelWidth, height: 14, alignment: .trailing)
                    .padding(.leading, DayMetrics.labelLeading)
                    .offset(y: DayMetrics.topInset - 7)
            }
            line(DayMetrics.hourLine)
                .offset(y: DayMetrics.topInset)
            line(DayMetrics.halfHourLine)
                .offset(y: DayMetrics.topInset + hourHeight / 2)
        }
        .frame(maxWidth: .infinity, minHeight: hourHeight, maxHeight: hourHeight, alignment: .topLeading)
    }

    private func line(_ color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(height: 0.5)
            .padding(.leading, DayMetrics.gridLeading)
    }

    private func showsLabel(_ hour: Int) -> Bool {
        guard let nowMinute else { return true }
        return abs(nowMinute - Double(hour * 60)) / 60 * hourHeight >= 14
    }
}

/// Today's time: its label in the hour column, a dot where the grid starts and a line across it, over the events.
private struct NowLine: View {
    static let height: CGFloat = 14

    let minute: Double

    var body: some View {
        let total = Int(minute)
        ZStack(alignment: .leading) {
            Text(verbatim: String(format: "%02d:%02d", total / 60 % 24, total % 60))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(DayMetrics.now)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: DayMetrics.labelWidth, alignment: .trailing)
                .padding(.leading, DayMetrics.labelLeading)
            Rectangle()
                .fill(DayMetrics.now)
                .frame(height: 1.5)
                .padding(.leading, DayMetrics.gridLeading)
            Circle()
                .fill(DayMetrics.now)
                .frame(width: 7, height: 7)
                .padding(.leading, DayMetrics.gridLeading - 3.5)
        }
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Event blocks

private struct BlockPlacement: Equatable, Sendable {
    /// From the top of the grid, and the height before the inset.
    var top: CGFloat
    var height: CGFloat
    var column: Int
    var columns: Int
    var span: Int
}

private struct BlockPlacementKey: LayoutValueKey {
    static let defaultValue = BlockPlacement(top: 0, height: 0, column: 0, columns: 1, span: 1)
}

/// Places each block by its `BlockPlacementKey`: columns split the width between `leading` and `trailing` equally,
/// and every block keeps `inset` from its neighbours. One layout for all blocks, so none needs a GeometryReader.
private struct DayBlocksLayout: Layout {
    static let inset: CGFloat = 1

    var height: CGFloat
    var leading: CGFloat
    var trailing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.replacingUnspecifiedDimensions().width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let inset = Self.inset
        let area = max(0, bounds.width - leading - trailing)
        for subview in subviews {
            let placement = subview[BlockPlacementKey.self]
            let column = area / CGFloat(max(1, placement.columns))
            let size = CGSize(width: max(0, column * CGFloat(max(1, placement.span)) - 2 * inset),
                              height: max(0, placement.height - 2 * inset))
            subview.place(at: CGPoint(x: bounds.minX + leading + column * CGFloat(placement.column) + inset,
                                      y: bounds.minY + placement.top + inset),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(size))
        }
    }
}

/// A block's time: the range, and the start alone for a column too narrow for it.
private struct BlockTime {
    var range: String
    var start: String
}

/// White block with a 3-pt stripe in the calendar's colour (a ring before the title for a task), peach for a
/// deadline, ghosted for a draft. The title takes a second line from 50 pt, the time shows from 36 pt and the place
/// from 64 pt. A narrow block (four or more side by side) is all title, as many lines as fit; VoiceOver still reads
/// its time.
private struct TimelineBlock: View {
    let event: ScheduleEvent
    /// On screen, after the inset.
    let height: CGFloat
    let isNarrow: Bool
    let time: BlockTime
    let isPast: Bool

    var body: some View {
        let isTask = event.kind == .task
        let fill = event.kind == .deadline ? Theme.deadline : Color.white
        // A draft is outlined rather than filled: a dashed edge would vanish against the white block.
        let ink = event.isDraft ? Color.white : Color.black
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let location = !isNarrow && height >= 64
            ? event.location?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        // 12-pt lines are about 14.5 pt; 6 pt of padding.
        let titleLines = isNarrow ? max(1, Int((height - 6) / 14.5)) : (height >= 50 ? 2 : 1)

        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if isTask {
                    TaskRing(isCompleted: event.isCompleted, size: 10,
                             color: event.isDraft ? ink : CaptureChipStyle.taskTint)
                }
                if event.isWaitingToSync {
                    PendingSyncGlyph(size: 9, color: ink.opacity(0.6))
                }
                Text(event.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ink)
                    .strikethrough(isTask && event.isCompleted)
                    .lineLimit(titleLines)
            }
            if !isNarrow && height >= 36 {
                // "中午12:32–下午1:02" doesn't fit three columns: then the start alone.
                ViewThatFits(in: .horizontal) {
                    timeText(time.range, ink: ink)
                    timeText(time.start, ink: ink)
                }
            }
            if let location, !location.isEmpty {
                Text(location)
                    .font(.system(size: 10.5))
                    .foregroundStyle(ink.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .padding(.leading, isNarrow ? (isTask ? 3 : 5) : (isTask ? 5 : 8))
        .padding(.trailing, isNarrow ? 2 : 4)
        .padding(.top, height < 30 ? 3 : 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .leading) {
            if !isTask {
                Color(hex: event.colorHex).frame(width: 3)
            }
        }
        .background(event.isDraft ? fill.opacity(0.18) : fill)
        .clipShape(shape)
        .draftGhost(event.isDraft, shape: shape, tint: fill)
        .opacity(isPast ? 0.55 : 1)
        .contentShape(shape)
    }

    private func timeText(_ text: String, ink: Color) -> some View {
        Text(verbatim: text)
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(ink.opacity(0.6))
            .lineLimit(1)
    }
}

/// A task's check circle, red-orange like WEEK and MONTH (design 04).
private struct TaskRing: View {
    let isCompleted: Bool
    let size: CGFloat
    let color: Color

    var body: some View {
        Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

// MARK: - All day

/// Chips above the grid, pinned while it scrolls: two side by side, then "+N", which shows them all.
private struct AllDayStrip: View {
    static let chipHeight: CGFloat = 20

    let events: [ScheduleEvent]
    /// Expanded, the chips scroll beyond this height (the page's share for them), nil while the page is unmeasured.
    let maxChipsHeight: CGFloat?
    let onSelect: (ScheduleEvent) -> Void

    @State private var isExpanded = false

    private static let collapsedCount = 2
    private static let spacing: CGFloat = 4
    /// Expanded, at most this many rows and half of the next, which says there is more; more rows scroll.
    private static let maxRows = 3
    private static let maxHeight = CGFloat(maxRows) * (chipHeight + spacing) + chipHeight / 2

    var body: some View {
        let hidden = events.count - Self.collapsedCount

        HStack(alignment: .top, spacing: 0) {
            Text("All day")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: DayMetrics.labelWidth, height: Self.chipHeight, alignment: .trailing)
                .padding(.leading, DayMetrics.labelLeading)
                .frame(width: DayMetrics.blocksLeading + DayBlocksLayout.inset, alignment: .leading)
                .accessibilityHidden(true)

            HStack(alignment: .top, spacing: Self.spacing) {
                if isExpanded && hidden > 0 {
                    expandedChips
                } else {
                    ForEach(ItemID.all(Array(events.prefix(Self.collapsedCount))), id: \.self) { item in
                        chip(events[item.index])
                    }
                }
                if hidden > 0 {
                    toggle(hidden: hidden)
                }
            }
        }
        .padding(.trailing, DayMetrics.blocksTrailing + DayBlocksLayout.inset)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var expandedChips: some View {
        let rows = (events.count + 1) / 2
        let height = CGFloat(rows) * (Self.chipHeight + Self.spacing) - Self.spacing
        let limit = max(Self.chipHeight, min(Self.maxHeight, maxChipsHeight ?? Self.maxHeight))
        if height > limit {
            ScrollView(.vertical, showsIndicators: false) {
                grid
            }
            .frame(height: limit)
        } else {
            grid
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Self.spacing), GridItem(.flexible(), spacing: Self.spacing)],
                  spacing: Self.spacing) {
            ForEach(ItemID.all(events), id: \.self) { item in
                chip(events[item.index])
            }
        }
    }

    private func chip(_ event: ScheduleEvent) -> some View {
        Button { onSelect(event) } label: {
            AllDayChip(event: event, height: Self.chipHeight)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(Text(verbatim: event.title))
        .accessibilityValue(Text("All day"))
    }

    private func toggle(hidden: Int) -> some View {
        Button {
            withAnimation(.snappy) { isExpanded.toggle() }
        } label: {
            Group {
                if isExpanded {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                } else {
                    Text("+\(hidden)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
            }
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 7)
            .frame(minWidth: 28, minHeight: Self.chipHeight, maxHeight: Self.chipHeight)
            .background(Capsule().fill(Color.white.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Expanded, every event is listed for VoiceOver already; there is no label for "fewer".
        .accessibilityHidden(isExpanded)
    }
}

/// Title only, on the calendar's colour (a stripe and a tint, like WEEK's chips); peach for a deadline.
private struct AllDayChip: View {
    let event: ScheduleEvent
    let height: CGFloat

    var body: some View {
        let isTask = event.kind == .task
        let isDeadline = event.kind == .deadline
        let tint = isTask ? CaptureChipStyle.taskTint : Color(hex: event.colorHex)
        let ink = isDeadline && !event.isDraft ? Color.black : Color.white
        let fill = isDeadline ? Theme.deadline.opacity(event.isDraft ? 0.18 : 1) : tint.opacity(isTask ? 0.2 : 0.3)
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)

        HStack(spacing: 4) {
            if isTask {
                TaskRing(isCompleted: event.isCompleted, size: 9, color: tint)
            }
            if event.isWaitingToSync {
                PendingSyncGlyph(size: 8, color: ink.opacity(0.7))
            }
            Text(event.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ink)
                .lineLimit(1)
        }
        .padding(.leading, isTask ? 5 : 8)
        .padding(.trailing, 5)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .background(alignment: .leading) {
            if !isTask {
                tint.frame(width: 3)
            }
        }
        .background(fill)
        .clipShape(shape)
        .draftGhost(event.isDraft, shape: shape, tint: isDeadline ? Theme.deadline : tint)
        .contentShape(shape)
    }
}
