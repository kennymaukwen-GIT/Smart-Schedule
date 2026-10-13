import SwiftUI

private let modeStorageKey = "quickCaptureMode"

/// Quick Capture (design 04): what the user sees after tapping the island's input pill. The OS can't host a
/// keyboard in the island, so the app opens straight into this island-shaped card (keyboard already up) instead
/// of the full month view, then gets out of the way. Top to bottom: focus date · DAY | WEEK | MONTH · month,
/// the calendar in that scope (endless either way), the conversation (the app's whole chat history, scrollable
/// inside the panel, with a handle to pull it up over the calendar) with the input bar, suggestions, and a grabber.
struct QuickCaptureView: View {
    let startsWithVoice: Bool
    let onClose: () -> Void

    @Environment(ChatViewModel.self) private var chat
    @Environment(ScheduleViewModel.self) private var schedule
    @Environment(AppRouter.self) private var router
    @Environment(\.locale) private var environmentLocale
    @AppStorage(modeStorageKey) private var storedMode: CalendarScope = .day
    @State private var mode: CalendarScope
    @FocusState private var inputFocused: Bool
    /// Pulled up by its handle, by a plan card arriving, or by scrolling back through the history.
    @State private var isConversationExpanded: Bool
    /// The handle's drag so far (negative = up); eases back when the drag ends.
    @GestureState(resetTransaction: Transaction(animation: .snappy)) private var handleDrag: CGFloat = 0
    /// The whole card's height: the expanded conversation takes about 60% of it.
    @State private var cardHeight: CGFloat = 0

    private static let panelFill = Color(white: 0.15)
    /// The calendar and the conversation share this height (less while the keyboard is up); the conversation's
    /// handle moves the line between them, so the composer stays where it is.
    private static let splitMinHeight: CGFloat = 256
    private static let splitMaxHeight: CGFloat = 460
    private static let splitGap: CGFloat = 10
    /// Design 04's example inputs, in both languages on purpose.
    private static let defaultSuggestions = [
        "I want to be muscular in 6 month design me a daily routine",
        "明天下午兩點跟 Joe 開線上會議",
        "Show me my schedule for today"
    ]

    /// `initialMode` overrides the remembered scope (previews); nil opens in whatever the user picked last.
    /// `conversationExpanded` opens with the conversation pulled up (previews).
    init(startsWithVoice: Bool,
         initialMode: CalendarScope? = nil,
         conversationExpanded: Bool = false,
         onClose: @escaping () -> Void) {
        self.startsWithVoice = startsWithVoice
        self.onClose = onClose
        // `mode` drives the animation; `storedMode` only persists it. Both read the same defaults key.
        let stored = UserDefaults.standard.string(forKey: modeStorageKey).flatMap(CalendarScope.init(rawValue:))
        _mode = State(initialValue: initialMode ?? stored ?? .day)
        _isConversationExpanded = State(initialValue: conversationExpanded)
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

            // Gives way while the keyboard is up, so the input bar stays above it.
            GeometryReader { geo in
                let heights = splitHeights(total: geo.size.height)
                VStack(spacing: Self.splitGap) {
                    calendarArea(day: day, now: Date())
                        .frame(height: heights.calendar)
                    conversationPanel
                        .frame(height: heights.conversation)
                }
            }
            .frame(minHeight: Self.splitMinHeight, idealHeight: Self.splitMaxHeight, maxHeight: Self.splitMaxHeight)
            .padding(.bottom, 10)

            suggestionRow
                .padding(.bottom, 6)

            grabber
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 4)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            cardHeight = height
        }
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
        .onAppear {
            if !startsWithVoice { inputFocused = true }
            if showsPlanCard { isConversationExpanded = true }
        }
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
        // A plan card needs the room: it arrived, or a ghost occurrence asked to bring it into view.
        .onChange(of: chat.openPlanMessageID) { _, id in
            if id != nil { expandConversation() }
        }
        .onChange(of: chat.planRevealRequest) {
            expandConversation()
        }
        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
            if value.translation.height < -40 { onClose() } // flick up = back into the island
        })
    }

    // MARK: Header

    private func header(day: Date) -> some View {
        let calendar = schedule.clock.calendar
        let year = CalendarPaging.yearLabel(for: CalendarPaging.dayInterval(containing: day, calendar: calendar),
                                            now: Date(),
                                            calendar: calendar,
                                            locale: ChatFormat.dateLocale(environmentLocale))
        // Settings › Time zone, not necessarily the device's.
        let style = Date.FormatStyle(timeZone: calendar.timeZone)

        return ZStack(alignment: .bottom) {
            HStack(alignment: .bottom) {
                VStack(spacing: 3) {
                    Text(day.formatted(style.weekday(.abbreviated)).uppercased())
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                    Text(day.formatted(style.day()))
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.black)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.white))
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 0) {
                    // Only outside the current year, level with the weekday over the date disc.
                    if let year {
                        Text(verbatim: year)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Text(day.formatted(style.month(.abbreviated)))
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(height: 40)
                }
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
                CaptureDayPager(focusDay: day,
                                now: now,
                                isLoading: schedule.isLoadingRange,
                                eventsOnDay: schedule.events(on:),
                                onSelectEvent: openDetail,
                                onSelectDay: selectDay,
                                onRangeChange: loadEvents)
                    .transition(.opacity)
            case .week:
                WeekAgendaCard(events: schedule.displayEvents,
                               focusDay: day,
                               now: now,
                               revealRequest: schedule.focusRequest,
                               isLoading: schedule.isLoadingRange,
                               onSelectEvent: openDetail,
                               onSelectDay: selectDay,
                               onRangeChange: loadEvents)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            case .month:
                MonthScrollCard(events: schedule.displayEvents,
                                focusDay: day,
                                now: now,
                                revealRequest: schedule.focusRequest,
                                isLoading: schedule.isLoadingRange,
                                onSelectEvent: openDetail,
                                onSelectDay: selectDay,
                                onRangeChange: loadEvents)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        // A new time zone or first weekday lays the pagers out again from the focus day.
        .id(schedule.clockID)
        .animation(.snappy, value: mode)
    }

    private func openDetail(_ event: ScheduleEvent) {
        // A ghost occurrence has no detail yet: bring its plan card (Add / Keep editing) into view instead.
        guard !event.isDraft else {
            chat.revealOpenPlan()
            return
        }
        router.selectedEventID = event.id // RootView's sheet shows the detail
    }

    private func selectDay(_ day: Date) {
        withAnimation(.snappy) { schedule.focusDay = day }
    }

    /// Whatever range a calendar settles on gets its events, however far from today.
    private func loadEvents(_ range: DateInterval) {
        schedule.ensureEvents(covering: range)
    }

    // MARK: Conversation

    /// A plan card waits for review somewhere in the conversation.
    private var showsPlanCard: Bool {
        chat.openPlanMessageID != nil
    }

    private struct SplitHeights {
        var calendar: CGFloat
        var conversation: CGFloat
    }

    /// Collapsed, the conversation keeps the design's 200 pt (the calendar 250), sharing evenly once the keyboard
    /// leaves less. Expanded, it takes about 60% of the whole card and the calendar shrinks to a strip. A drag on
    /// the handle moves anywhere in between.
    private func splitHeights(total: CGFloat) -> SplitHeights {
        let usable = max(0, total - Self.splitGap)
        let collapsed = min(usable, max(116, min(200, usable / 2)))
        let expanded = max(collapsed, min(usable - 72, cardHeight * 0.6))
        let base = isConversationExpanded ? expanded : collapsed
        let conversation = min(max(base - handleDrag, collapsed), expanded)
        return SplitHeights(calendar: usable - conversation, conversation: conversation)
    }

    private func expandConversation() {
        guard !isConversationExpanded else { return }
        withAnimation(.snappy) { isConversationExpanded = true }
    }

    private func toggleConversation() {
        withAnimation(.snappy) { isConversationExpanded.toggle() }
    }

    private var conversationPanel: some View {
        @Bindable var chat = chat

        return VStack(spacing: 6) {
            conversationHandle

            ConversationScrollView(tail: chat.conversationTail,
                                   revealRequest: chat.planRevealRequest,
                                   revealID: chat.openPlanMessageID,
                                   onScrollBack: expandConversation) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(chat.messages) { message in
                        // Suggestions show under the panel instead.
                        ChatMessageRow(message: message,
                                       style: .capture,
                                       isDemo: schedule.isDemo,
                                       isBusy: chat.isBusy,
                                       onConfirmDelete: { chat.confirmDeletion(in: message) },
                                       onAddPlan: { chat.addPlan(message) },
                                       onKeepEditing: { chat.keepEditing(message) },
                                       actions: ChatCardActions(message: message, chat: chat))
                            .id(message.id)
                    }
                    if chat.isSending {
                        ProgressView().tint(.white)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
                .padding(.bottom, 4)
            }
            .scrollDismissesKeyboard(.interactively)

            if chat.showsConsentBanner {
                ConsentBanner { chat.reviewConsent() }
            }

            ComposerBar(
                text: $chat.draft,
                placeholder: "Type in any plan to add or change",
                isBusy: chat.isBusy,
                focus: $inputFocused,
                startsRecording: startsWithVoice,
                onSend: { chat.send() }
            )
            .padding(.top, 4)
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Self.panelFill))
    }

    /// Grabber on top of the conversation: drag it up (or tap) for more history, down for more calendar.
    private var conversationHandle: some View {
        let label: LocalizedStringKey = isConversationExpanded ? "Collapse conversation" : "Expand conversation"

        return Capsule()
            .fill(Color.white.opacity(0.35))
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity, minHeight: 12)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleConversation)
            // Global space: the handle itself moves while the panel grows under the finger.
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .updating($handleDrag) { value, state, _ in
                    state = value.translation.height
                }
                .onEnded { value in
                    let travel = value.predictedEndTranslation.height
                    guard abs(travel) > 40 else { return }
                    withAnimation(.snappy) { isConversationExpanded = travel < 0 }
                })
            .accessibilityElement()
            .accessibilityLabel(Text(label))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggleConversation() }
    }

    // MARK: Suggestions + grabber

    /// The newest reply's suggestions, else examples to start from.
    private var suggestions: [String] {
        let fromReply = chat.latestReply?.suggestions ?? []
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
