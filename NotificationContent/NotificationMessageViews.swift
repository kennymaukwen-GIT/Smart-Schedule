import SwiftUI

// Compact copies of the app's chat views (App/Views/AssistantMessageView.swift, ConversationScrollView.swift):
// this target does not compile App/. Keep the two in step.

/// One turn of the hold-to-reply conversation: the user's line as a bubble ("MY TEXT"); a reply's prose,
/// added-event rows, agenda and plan card ("THE RESPOND").
struct NotificationTurnRow: View {
    let turn: NotificationChatModel.Turn
    var isDemo = false
    var onAddPlan: () -> Void = {}
    var onKeepEditing: () -> Void = {}
    var onAddPendingEvents: () -> Void = {}
    var onEditPendingEvents: () -> Void = {}

    var body: some View {
        switch turn.role {
        case .user:
            Text(turn.text) // "MY TEXT"
                .font(.system(size: 15))
                .lineSpacing(3)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.bubble))
        case .assistant:
            VStack(alignment: .leading, spacing: 8) { // "THE RESPOND"
                if !turn.text.isEmpty {
                    NotificationReplyText(text: turn.text)
                }
                if !turn.addedEvents.isEmpty {
                    NotificationEventRows(events: turn.addedEvents, isDemo: isDemo)
                }
                if let agenda = turn.agenda {
                    NotificationAgendaList(digest: agenda)
                }
                if let plan = turn.planDraft {
                    NotificationPlanCard(draft: plan, status: turn.planStatus,
                                         onAdd: onAddPlan, onKeepEditing: onKeepEditing)
                }
                if let batch = turn.pendingEvents {
                    NotificationPendingEventsCard(batch: batch, status: turn.pendingEventsStatus, isDemo: isDemo,
                                                 onAdd: onAddPendingEvents, onEdit: onEditPendingEvents)
                }
            }
        }
    }
}

// MARK: - Prose

/// Paragraphs split on blank lines, "• ", "- " and "1. " lines as indented rows, inline Markdown (**bold**).
struct NotificationReplyText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                if block.isList {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(block.lines.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: line.marker)
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(minWidth: 12, alignment: .trailing)
                                Text(Self.inline(line.text))
                            }
                        }
                    }
                } else {
                    Text(Self.inline(block.lines.map(\.text).joined(separator: "\n")))
                }
            }
        }
        .font(.system(size: 15))
        .lineSpacing(4)
        .foregroundStyle(Color.white.opacity(0.92))
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private struct Line {
        var marker: String
        var text: String
    }

    private struct Block {
        var isList: Bool
        var lines: [Line]
    }

    private static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                blocks.append(Block(isList: false, lines: [])) // paragraph break
                continue
            }
            let item = listItem(line)
            let isList = item != nil
            let entry = item ?? Line(marker: "", text: line)
            if let last = blocks.indices.last, blocks[last].isList == isList, !blocks[last].lines.isEmpty {
                blocks[last].lines.append(entry)
            } else {
                blocks.append(Block(isList: isList, lines: [entry]))
            }
        }
        return blocks.filter { !$0.lines.isEmpty }
    }

    private static func listItem(_ line: String) -> Line? {
        for bullet in ["• ", "- "] where line.hasPrefix(bullet) {
            return Line(marker: "•", text: String(line.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces))
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard (1...2).contains(digits.count) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") else { return nil }
        return Line(marker: String(digits) + ".", text: String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }

    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - Added events

/// "Added to Google Calendar", then each event's title, day and time, and place.
struct NotificationEventRows: View {
    let events: [ScheduleEvent]
    var isDemo = false

    @Environment(\.locale) private var environmentLocale
    private let clock = WallClock()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                if isDemo {
                    Text("Added (demo)")
                } else {
                    Text("Added to Google Calendar")
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)

            ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                if index > 0 {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(ReplyFormatter.when(event, clock: clock, locale: NotificationFormat.dateLocale(environmentLocale)))
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                    if let location = event.location, !location.isEmpty {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    } else if event.meetURL != nil {
                        Label {
                            Text(verbatim: "Google Meet")
                        } icon: {
                            Image(systemName: "video")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.leading, 10)
                .background(alignment: .leading) {
                    Capsule().fill(Color(hex: event.colorHex)).frame(width: 3)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notificationCardBackground()
    }
}

// MARK: - Agenda

/// The range as a header, then "12:30  Lunch" rows with the times in their own column.
struct NotificationAgendaList: View {
    let digest: AgendaDigest

    @Environment(\.locale) private var environmentLocale
    private let clock = WallClock()
    private static let rowLimit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(digest.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            if digest.events.isEmpty {
                Text("Nothing scheduled")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.92))
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(Array(digest.events.prefix(Self.rowLimit).enumerated()), id: \.offset) { index, event in
                        if let day = newDay(at: index) {
                            Text(ReplyFormatter.dayLabel(day, clock: clock,
                                                         locale: NotificationFormat.dateLocale(environmentLocale)))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.75))
                                .padding(.top, index == 0 ? 0 : 3)
                        }
                        GridRow {
                            Group {
                                if event.isAllDay {
                                    Text("All day")
                                } else {
                                    Text(verbatim: ReplyFormatter.clockTime(event.start, clock: clock))
                                }
                            }
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.6))
                            Text(event.title)
                                .font(.system(size: 14))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                    }
                }
                if digest.events.count > Self.rowLimit {
                    Text("+\(digest.events.count - Self.rowLimit) more")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notificationCardBackground()
    }

    /// The day `events[index]` starts, when the range spans several days and it differs from the row above.
    private func newDay(at index: Int) -> Date? {
        let calendar = clock.calendar
        guard CalendarPaging.dayCount(of: digest.range, calendar: calendar) > 1 else { return nil }
        func day(_ event: ScheduleEvent) -> Date {
            calendar.startOfDay(for: max(event.start, digest.range.start))
        }
        let current = day(digest.events[index])
        return index > 0 && day(digest.events[index - 1]) == current ? nil : current
    }
}

// MARK: - Scrolling

struct NotificationConversationTail: Equatable {
    var lastID: UUID?
    /// The user's own line always scrolls into view.
    var isOwnMessage = false
    var isTyping = false
}

/// Follows new turns only while the reader is at the bottom; scrolled up, it keeps their place and shows a
/// "New message ↓" pill.
struct NotificationConversationScroll<Content: View>: View {
    let tail: NotificationConversationTail
    @ViewBuilder var content: () -> Content

    @State private var isAtBottom = true
    @State private var hasUnseen = false

    private static var bottomID: String { "notification-conversation-bottom" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    content()
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                }
            }
            .onScrollGeometryChange(for: NotificationViewport.self) { geometry in
                NotificationViewport(isAtBottom: geometry.visibleRect.maxY >= geometry.contentSize.height - 40,
                                     height: geometry.containerSize.height)
            } action: { old, new in
                if new.height != old.height && old.isAtBottom {
                    // The card grew (a plan arrived) or the keyboard came up: stay on the newest turn.
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    return
                }
                isAtBottom = new.isAtBottom
                if new.isAtBottom { hasUnseen = false }
            }
            .onChange(of: tail) { old, new in
                if isAtBottom || new.isOwnMessage {
                    withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                } else if new.lastID != old.lastID {
                    hasUnseen = true
                }
            }
            .onAppear {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            .overlay(alignment: .bottom) {
                if hasUnseen {
                    Button {
                        withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    } label: {
                        Text("New message ↓")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.white))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 4)
                    .transition(.opacity)
                }
            }
            .animation(.snappy, value: hasUnseen)
        }
    }
}

private struct NotificationViewport: Equatable {
    var isAtBottom: Bool
    var height: CGFloat
}

// MARK: - Formatting

/// Copy of the app's `ChatFormat` (App/Views/AssistantMessageView.swift).
enum NotificationFormat {
    /// RFC 5545 BYDAY codes in `Calendar.shortWeekdaySymbols` order (Sunday first).
    private static let weekdayCodes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    /// Dates follow the language the UI strings resolved to, unless a view sets its own `\.locale` (previews).
    static func dateLocale(_ environment: Locale) -> Locale {
        environment.identifier == Locale.current.identifier ? ReplyFormatter.displayLocale : environment
    }

    /// `["TH", "TU"]` → "Tue · Thu" / "週二 · 週四", Monday first; nil for all seven days.
    static func weekdays(_ codes: [String], locale: Locale) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = calendar.shortWeekdaySymbols
        let indices = Set(codes.compactMap { weekdayCodes.firstIndex(of: $0.uppercased()) })
            .sorted { ($0 + 6) % 7 < ($1 + 6) % 7 }
        if indices.count == 7 { return nil }
        return indices.filter { $0 < symbols.count }.map { symbols[$0] }.joined(separator: " · ")
    }

    /// "60 min" / "60 分鐘".
    static func duration(minutes: Int, locale: Locale) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitStyle = .medium
        formatter.unitOptions = .providedUnit
        return formatter.string(from: Measurement(value: Double(minutes), unit: UnitDuration.minutes))
    }

    /// "Oct 14 – Dec 8" / "10月14日 – 12月8日".
    static func dayRange(_ start: Date, _ end: Date, clock: WallClock, locale: Locale) -> String {
        ReplyFormatter.shortDate(start, clock: clock, locale: locale) + " – "
            + ReplyFormatter.shortDate(end, clock: clock, locale: locale)
    }
}

extension View {
    func notificationCardBackground() -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return background(shape.fill(Color.white.opacity(0.06)))
            .overlay(shape.strokeBorder(Theme.hairline))
    }
}
