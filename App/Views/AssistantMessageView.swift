import SwiftUI

/// One assistant turn in the chat panel and Quick Capture: the prose first, then whatever the reply carries as
/// data (added-event rows, an agenda, a plan card, pending events, a settings change, a learned suggestion), then
/// its suggestion chips when it is the newest message.
struct AssistantMessageView: View {
    let message: ChatViewModel.Message
    /// Only the newest reply offers chips; an older one's would answer a question the conversation has left.
    var showsSuggestions = false
    /// Quick Capture's narrower panel: the plan card uses its compact type.
    var compact = false
    var isDemo = false
    var isBusy = false
    var onSuggestion: (String) -> Void = { _ in }
    var onConfirmDelete: () -> Void = {}
    var onAddPlan: () -> Void = {}
    var onKeepEditing: () -> Void = {}
    var actions = ChatCardActions()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !message.text.isEmpty {
                AssistantText(text: message.text)
            }
            if !message.addedEvents.isEmpty {
                EventAddedRows(events: message.addedEvents, isDemo: isDemo)
            }
            if let agenda = message.agenda {
                AgendaList(digest: agenda)
            }
            if let batch = message.pendingEvents {
                PendingEventsCard(batch: batch,
                                  status: message.pendingEventsStatus,
                                  isDemo: isDemo,
                                  compact: compact,
                                  onAdd: actions.addPendingEvents,
                                  onEdit: actions.editPendingEvents)
            }
            if let receipt = message.preferenceReceipt {
                SettingsUpdatedCard(receipt: receipt, undo: message.receiptUndo, onUndo: actions.undoPreferences)
            }
            if let suggestion = message.learnedSuggestion {
                LearnedSuggestionCard(suggestion: suggestion, onResolve: actions.resolveSuggestion)
            }
            if let plan = message.planDraft {
                // The card lists the plan's assumptions itself.
                PlanPreviewCard(draft: plan,
                                status: message.planStatus,
                                style: compact ? .compact : .full,
                                onAdd: onAddPlan,
                                onKeepEditing: onKeepEditing)
            } else if !message.assumptions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(message.assumptions, id: \.self) { assumption in
                        Label(assumption, systemImage: "info.circle")
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            }
            if message.pendingDeletion != nil {
                Button("Confirm", role: .destructive, action: onConfirmDelete)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            if showsSuggestions && !message.suggestions.isEmpty {
                SuggestionChips(suggestions: message.suggestions, isDisabled: isBusy, onSelect: onSuggestion)
            }
        }
    }
}

/// What the cards of the "Ask me first", settings and learned-suggestion flows do when tapped.
struct ChatCardActions {
    var addPendingEvents: () -> Void = {}
    var editPendingEvents: () -> Void = {}
    var undoPreferences: () -> Void = {}
    var resolveSuggestion: (_ accept: Bool) -> Void = { _ in }
}

extension ChatCardActions {
    /// The actions on `message`'s cards, run by `chat`.
    @MainActor
    init(message: ChatViewModel.Message, chat: ChatViewModel) {
        self.init(addPendingEvents: { chat.addPendingEvents(message) },
                  editPendingEvents: { chat.editPendingEvents(message) },
                  undoPreferences: { chat.undoPreferences(message) },
                  resolveSuggestion: { chat.resolveSuggestion(message, accept: $0) })
    }
}

// MARK: - Prose

/// Assistant prose laid out for reading: blank lines split paragraphs, lines starting with "• ", "- " or "1. "
/// become indented list rows, and inline Markdown (**bold**) is rendered.
struct AssistantText: View {
    let text: String
    var size: CGFloat = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .paragraph(paragraph):
                    Text(Self.inline(paragraph))
                case let .list(items):
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: item.marker)
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(minWidth: 14, alignment: .trailing)
                                Text(Self.inline(item.text))
                            }
                        }
                    }
                    .padding(.leading, 2)
                }
            }
        }
        .font(.system(size: size))
        .lineSpacing(4)
        .foregroundStyle(Color.white.opacity(0.92))
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension AssistantText {
    enum Block: Equatable {
        /// Consecutive lines without a blank line between them; their line breaks are kept.
        case paragraph(String)
        case list([ListItem])
    }

    struct ListItem: Equatable {
        /// "•" for "• " and "- " lines, "1." for numbered ones.
        var marker: String
        var text: String
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var items: [ListItem] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }
        func flushList() {
            guard !items.isEmpty else { return }
            blocks.append(.list(items))
            items = []
        }

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                flushList()
            } else if let item = listItem(line) {
                flushParagraph()
                items.append(item)
            } else {
                flushList()
                paragraph.append(line)
            }
        }
        flushParagraph()
        flushList()
        return blocks
    }

    static func listItem(_ line: String) -> ListItem? {
        for bullet in ["• ", "- "] where line.hasPrefix(bullet) {
            return ListItem(marker: "•", text: String(line.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces))
        }
        // ASCII digits only: Character.isNumber is also true for "一" and "½".
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard (1...2).contains(digits.count) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") else { return nil }
        return ListItem(marker: String(digits) + ".", text: String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }

    /// Inline Markdown only: "1. " and "- " stay literal here (the list rows above handle them), and line breaks
    /// survive.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - Added events

/// What a reply put in the calendar, as rows instead of a sentence: a checkmark eyebrow, then each event's title,
/// day and time, and place. `Reply.text` keeps the sentence for Siri and notifications.
struct EventAddedRows: View {
    let events: [ScheduleEvent]
    var isDemo = false

    @Environment(\.locale) private var environmentLocale
    private let clock = WallClock()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                if isDemo {
                    Text("Added (demo)")
                } else {
                    Text("Added to Google Calendar")
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)

            ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                if index > 0 {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                row(event)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatCardBackground()
    }

    private func row(_ event: ScheduleEvent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(event.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Text(ReplyFormatter.when(event, clock: clock, locale: ChatFormat.dateLocale(environmentLocale)))
                .font(.system(size: 14).monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
            if let location = event.location, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            if event.meetURL != nil {
                Label {
                    Text(verbatim: "Google Meet")
                } icon: {
                    Image(systemName: "video")
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.leading, 11)
        .background(alignment: .leading) {
            Capsule().fill(Color(hex: event.colorHex)).frame(width: 3)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Agenda

/// The answer to a schedule question: the range as a header ("Today · Wed, Oct 15"), then one row per event
/// with the times in their own column ("12:30  Lunch"), under day labels when the range spans several days.
struct AgendaList: View {
    let digest: AgendaDigest

    @Environment(\.locale) private var environmentLocale
    private let clock = WallClock()
    private static let rowLimit = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(digest.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)

            if digest.events.isEmpty {
                Text("Nothing scheduled")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.92))
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                        if groupsByDay {
                            // Outside a GridRow, so it spans both columns.
                            Text(ReplyFormatter.dayLabel(section.day, clock: clock,
                                                         locale: ChatFormat.dateLocale(environmentLocale)))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.75))
                                .padding(.top, index == 0 ? 0 : 4)
                        }
                        ForEach(Array(section.events.enumerated()), id: \.offset) { _, event in
                            GridRow {
                                timeLabel(event)
                                Text(event.title)
                                    .font(.system(size: 15))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                if digest.events.count > Self.rowLimit {
                    Text("+\(digest.events.count - Self.rowLimit) more")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatCardBackground()
    }

    @ViewBuilder
    private func timeLabel(_ event: ScheduleEvent) -> some View {
        Group {
            if event.isAllDay {
                Text("All day")
            } else {
                Text(verbatim: ReplyFormatter.clockTime(event.start, clock: clock))
            }
        }
        .font(.system(size: 14, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.6))
    }

    private struct DaySection {
        let day: Date
        var events: [ScheduleEvent]
    }

    private var groupsByDay: Bool {
        CalendarPaging.dayCount(of: digest.range, calendar: clock.calendar) > 1
    }

    private var sections: [DaySection] {
        let calendar = clock.calendar
        var sections: [DaySection] = []
        for event in digest.events.prefix(Self.rowLimit) {
            // An event that began before the range is listed on the range's first day.
            let day = calendar.startOfDay(for: max(event.start, digest.range.start))
            if let last = sections.indices.last, sections[last].day == day {
                sections[last].events.append(event)
            } else {
                sections.append(DaySection(day: day, events: [event]))
            }
        }
        return sections
    }
}

// MARK: - Suggestions

/// One-tap answers under the newest reply. Scrolls sideways: Keep editing offers four, more than a row holds.
struct SuggestionChips: View {
    let suggestions: [String]
    var isDisabled = false
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        onSelect(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().strokeBorder(Theme.hairline))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled)
                }
            }
        }
    }
}

// MARK: - Formatting

/// What the chat's cards need beyond `ReplyFormatter` (which also writes the text versions Siri reads):
/// the locale for dates, weekday names for plan sessions, and durations.
enum ChatFormat {
    /// RFC 5545 BYDAY codes in `Calendar.shortWeekdaySymbols` order (Sunday first).
    private static let weekdayCodes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    /// Dates follow the language the UI strings resolved to, like the text replies, unless a view sets its own
    /// `\.locale` (the zh-Hant previews).
    static func dateLocale(_ environment: Locale) -> Locale {
        environment.identifier == Locale.current.identifier ? ReplyFormatter.displayLocale : environment
    }

    /// `["TH", "TU"]` → "Tue · Thu" / "週二 · 週四", Monday first like a training week; nil for all seven days.
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

    /// "07:30", matching the 24-hour session times.
    static func clockTime(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }
}

extension View {
    /// The faint rounded panel behind added-event rows and agendas; reads on both the chat panel and Quick
    /// Capture's lighter one.
    func chatCardBackground() -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return background(shape.fill(Color.white.opacity(0.06)))
            .overlay(shape.strokeBorder(Theme.hairline))
    }
}
