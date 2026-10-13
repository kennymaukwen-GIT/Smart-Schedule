import SwiftUI

private let modeStorageKey = "quickCaptureMode"

/// Quick Capture (design 04): what the user sees after tapping the island's input pill. The OS can't host a
/// keyboard in the island, so the app opens straight into this island-shaped card (keyboard already up) instead
/// of the full month view, then gets out of the way. Top to bottom: focus date · DAY | WEEK | MONTH · month,
/// the calendar in that scope, the latest exchange with the input bar, suggestions, and a grabber.
struct QuickCaptureView: View {
    let startsWithVoice: Bool
    let onClose: () -> Void

    @Environment(ChatViewModel.self) private var chat
    @Environment(ScheduleViewModel.self) private var schedule
    @Environment(AppRouter.self) private var router
    @AppStorage(modeStorageKey) private var storedMode: CalendarScope = .day
    @State private var mode: CalendarScope
    @FocusState private var inputFocused: Bool

    private static let panelFill = Color(white: 0.15)
    private static let defaultSuggestions = [
        "I want to be muscular in 6 month design me a daily routine",
        "明天下午兩點跟 Joe 開線上會議",
        "Show me my schedule for today"
    ]

    /// `initialMode` overrides the remembered scope (previews); nil opens in whatever the user picked last.
    init(startsWithVoice: Bool, initialMode: CalendarScope? = nil, onClose: @escaping () -> Void) {
        self.startsWithVoice = startsWithVoice
        self.onClose = onClose
        // `mode` drives the animation; `storedMode` only persists it. Both read the same defaults key.
        let stored = UserDefaults.standard.string(forKey: modeStorageKey).flatMap(CalendarScope.init(rawValue:))
        _mode = State(initialValue: initialMode ?? stored ?? .day)
    }

    var body: some View {
        let day = schedule.focusDay

        VStack(spacing: 0) {
            header(day: day)
                .padding(.bottom, 10)

            Rectangle()
                .fill(Color.white.opacity(0.85))
                .frame(height: 1)
                .padding(.bottom, 10)

            // Both flexible frames give way while the keyboard is up, so the input bar stays above it.
            calendarArea(day: day, now: Date())
                .frame(minHeight: 130, idealHeight: 250, maxHeight: 250)
                .padding(.bottom, 10)

            // Taller while a plan card waits for Add / Keep editing, so its buttons fit without scrolling.
            conversationPanel
                .frame(minHeight: 116,
                       idealHeight: showsPlanCard ? 340 : 200,
                       maxHeight: showsPlanCard ? 340 : 200)
                .padding(.bottom, 10)

            suggestionRow
                .padding(.bottom, 6)

            grabber
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 4)
        .background(
            RoundedRectangle(cornerRadius: Theme.islandRadius, style: .continuous)
                .fill(Color.black)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.islandRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
        )
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .onAppear { if !startsWithVoice { inputFocused = true } }
        .onChange(of: mode) { _, newMode in
            storedMode = newMode
            inputFocused = false // picking a scope means "let me see the calendar"
        }
        .onChange(of: schedule.focusRequest) { _, request in
            guard let request else { return }
            let scope = request.scope ?? CalendarScope.fitting(request.range, calendar: schedule.clock.calendar)
            if scope != mode {
                withAnimation(.snappy) { mode = scope }
            }
        }
        .onChange(of: chat.inputFocusRequest) {
            inputFocused = true // Keep editing: "What would you like to change?"
        }
        .animation(.snappy, value: showsPlanCard)
        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
            if value.translation.height < -40 { onClose() } // flick up = back into the island
        })
    }

    // MARK: Header

    private func header(day: Date) -> some View {
        ZStack(alignment: .bottom) {
            HStack(alignment: .bottom) {
                VStack(spacing: 3) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                    Text(day.formatted(.dateTime.day()))
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.black)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.white))
                }
                Spacer(minLength: 0)
                Text(day.formatted(.dateTime.month(.abbreviated)))
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(height: 40)
            }
            // Centered on the card, level with the date disc.
            CaptureModePicker(selection: $mode)
                .padding(.bottom, 2)
        }
    }

    // MARK: Calendar

    @ViewBuilder
    private func calendarArea(day: Date, now: Date) -> some View {
        ZStack {
            switch mode {
            case .day:
                DayTimelineView(day: day, events: schedule.events(on: day), hourHeight: 46, onSelect: openDetail)
                    .transition(.opacity)
            case .week:
                WeekAgendaCard(events: schedule.displayEvents,
                               focusDay: day,
                               now: now,
                               revealRequest: schedule.focusRequest,
                               onSelectEvent: openDetail,
                               onSelectDay: selectDay)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            case .month:
                MonthScrollCard(events: schedule.displayEvents,
                                focusDay: day,
                                now: now,
                                revealRequest: schedule.focusRequest,
                                onSelectEvent: openDetail,
                                onSelectDay: selectDay)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.snappy, value: mode)
    }

    private func openDetail(_ event: ScheduleEvent) {
        // A ghost occurrence has no detail yet; its plan card is the latest reply here.
        guard !event.isDraft else { return }
        router.selectedEventID = event.id // RootView's sheet shows the detail
    }

    private func selectDay(_ day: Date) {
        withAnimation(.snappy) { schedule.focusDay = day }
    }

    // MARK: Conversation

    /// The latest reply is a plan card (open or not), shown compact in the panel.
    private var showsPlanCard: Bool {
        !chat.isSending && chat.lastExchange.reply?.planDraft != nil
    }

    private var conversationPanel: some View {
        @Bindable var chat = chat
        let exchange = chat.lastExchange

        return VStack(spacing: 10) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    if let user = exchange.user {
                        Text(user.text)
                            .lineLimit(showsPlanCard ? 1 : nil)
                            .font(.system(size: 15))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.bubble))
                            .padding(.leading, 36)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    if chat.isSending {
                        ProgressView().tint(.white)
                    } else if let reply = exchange.reply {
                        // Its suggestions are shown under the panel instead.
                        ChatMessageRow(message: withoutSuggestions(reply),
                                       compactPlan: true,
                                       onConfirmDelete: { chat.confirmDeletion(in: reply) },
                                       onAddPlan: { chat.addPlan(reply) },
                                       onKeepEditing: { chat.keepEditing(reply) })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }
            .id(exchange.user?.id) // a new exchange starts at the top
            .scrollDismissesKeyboard(.interactively)

            ComposerBar(
                text: $chat.draft,
                placeholder: "Type in any plan to add or change",
                isBusy: chat.isBusy,
                focus: $inputFocused,
                startsRecording: startsWithVoice,
                onSend: { chat.send() }
            )
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Self.panelFill))
    }

    private func withoutSuggestions(_ message: ChatViewModel.Message) -> ChatViewModel.Message {
        var copy = message
        copy.suggestions = []
        return copy
    }

    // MARK: Suggestions + grabber

    private var suggestions: [String] {
        let fromReply = chat.lastExchange.reply?.suggestions ?? []
        return fromReply.isEmpty ? Self.defaultSuggestions : fromReply
    }

    private var suggestionRow: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            chat.send(suggestion)
                        } label: {
                            // A long suggestion stops at the row's width and truncates, like the design's first one.
                            let cap = WidthCap(maxWidth: geo.size.width)
                            cap {
                                Text(suggestion)
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .overlay(Capsule().strokeBorder(Color.white, lineWidth: 1))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(chat.isBusy)
                    }
                }
            }
        }
        .frame(height: 32)
    }

    private var grabber: some View {
        Capsule()
            .fill(Color.white.opacity(0.4))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity, minHeight: 18)
            .contentShape(Rectangle())
            .onTapGesture(perform: onClose)
            .accessibilityElement()
            .accessibilityLabel("Close")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onClose() }
    }
}

/// Proposes `min(natural width, maxWidth)` to its single child, so text truncates inside a horizontal scroll
/// view (which otherwise offers unlimited width) while short content keeps its own size.
private struct WidthCap: Layout {
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let natural = child.sizeThatFits(.unspecified)
        let width = min(natural.width, maxWidth, proposal.width ?? .infinity)
        return child.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Hour-grid day view (white pills, peach deadlines), 24-hour labels.
struct DayTimelineView: View {
    let day: Date
    let events: [ScheduleEvent]
    var hourHeight: CGFloat = 56
    var onSelect: (ScheduleEvent) -> Void = { _ in }

    private let calendar = WallClock().calendar
    private let gutter: CGFloat = 50

    var body: some View {
        let timed = events.filter { !$0.isAllDay }
        let firstHour = max(0, min(timed.map { calendar.component(.hour, from: $0.start) }.min() ?? 8, 20) - 1)
        let startOfRange = calendar.date(bySettingHour: firstHour, minute: 0, second: 0, of: day) ?? day

        ScrollView(showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(firstHour..<24, id: \.self) { hour in
                        HStack(alignment: .top, spacing: 6) {
                            Text(hourLabel(hour))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.white)
                                .frame(width: gutter - 8, alignment: .trailing)
                            Rectangle().fill(Color.white.opacity(0.75)).frame(height: 1).padding(.top, 6)
                        }
                        .frame(height: hourHeight, alignment: .top)
                    }
                }
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 1, height: CGFloat(24 - firstHour) * hourHeight)
                    .padding(.leading, gutter)

                ForEach(Array(timed.enumerated()), id: \.element.id) { index, event in
                    let minutes = event.start.timeIntervalSince(startOfRange) / 60
                    TimelinePill(event: event)
                        .onTapGesture { onSelect(event) }
                        .offset(x: gutter + 10 + CGFloat(overlapColumn(index, in: timed)) * 90,
                                y: CGFloat(minutes / 60) * hourHeight + 8)
                }
            }
        }
    }

    /// "09:00" … "23:00", whatever the device's 12/24-hour setting (design 04).
    private func hourLabel(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }

    /// Shift overlapping pills right so they stay readable.
    private func overlapColumn(_ index: Int, in events: [ScheduleEvent]) -> Int {
        events[..<index].filter { $0.overlaps(events[index]) }.count
    }
}

private struct TimelinePill: View {
    let event: ScheduleEvent

    var body: some View {
        // A draft is outlined rather than filled: a dashed edge would vanish against the white pill.
        let fill = event.kind == .deadline ? Theme.deadline : Color.white
        Text(event.title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(event.isDraft ? Color.white : Color.black)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(event.isDraft ? fill.opacity(0.18) : fill))
            .draftGhost(event.isDraft, shape: Capsule(), tint: fill)
            .contentShape(Capsule())
    }
}
