import SwiftUI

/// Artboard 5. Top = the header (hamburger · "2027 October" · avatar), then the view area (month chips, month
/// grid), both endless and kept in step through `displayedMonth`. Bottom = AI conversation.
struct MainView: View {
    @Environment(ScheduleViewModel.self) private var schedule
    @Environment(ChatViewModel.self) private var chat
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var schedule = schedule

        VStack(spacing: 12) {
            AppHeader(month: schedule.displayedMonth,
                      calendar: schedule.clock.calendar,
                      avatarInitial: schedule.avatarInitial,
                      onMenu: { withAnimation(.snappy) { router.isDrawerOpen = true } },
                      onAvatar: { router.openSheet(.accounts) },
                      syncIndicator: SyncHeaderIndicator(status: schedule.syncStatus,
                                                         failedCount: schedule.failedChanges.count,
                                                         isDemo: schedule.isDemo,
                                                         isNetworkOffline: schedule.isNetworkOffline),
                      onSyncIndicator: { withAnimation(.snappy) { router.isDrawerOpen = true } })
                .padding(.top, 4)

            MonthPickerBar(selection: $schedule.displayedMonth)
                .id(schedule.clockID)

            MonthGridView(
                month: $schedule.displayedMonth,
                today: Date(),
                isLoading: schedule.isLoadingRange,
                showsTitle: false,
                eventsOnDay: schedule.events(on:),
                onSelect: { event in
                    // A ghost occurrence has no detail yet: bring its plan or pending-events card (Add) into view.
                    if event.isDraft {
                        chat.revealOpenPlan()
                    } else {
                        router.selectedEventID = event.id
                    }
                }
            )
            // A new time zone or first weekday lays the pages out again from `displayedMonth`.
            .id(schedule.clockID)
            .frame(maxHeight: .infinity)

            ChatPanel(takesFocusRequests: router.quickCapture == nil)
                .containerRelativeFrame(.vertical) { height, _ in height * 0.40 }
        }
        .padding(.horizontal, 12)
        .background(Theme.canvas.ignoresSafeArea())
        .refreshable { await schedule.refresh(.pull) }
        .onChange(of: schedule.displayedMonth, initial: true) { _, month in
            // Every week the grid draws, however far from today.
            schedule.ensureEvents(covering: CalendarPaging.monthGridInterval(containing: month,
                                                                             calendar: schedule.clock.calendar))
        }
        .overlay(alignment: .top) {
            if let error = schedule.lastError {
                Text(error)
                    .font(.footnote)
                    .padding(10)
                    .background(Capsule().fill(Color.red.opacity(0.85)))
                    .onTapGesture { schedule.lastError = nil }
                    .padding(.top, 4)
            }
        }
    }
}

/// The month chips over the grid: a strip with no end either way. January shows its year ("JAN 2027" /
/// "2027年1月"), so it is clear which year the strip has scrolled into; the selected chip stays centered.
struct MonthPickerBar: View {
    @Binding var selection: Date

    @Environment(\.locale) private var environmentLocale
    private let calendar = WallClock().calendar
    /// The month at offset 0; chips are month offsets from it.
    @State private var anchor: Date

    init(selection: Binding<Date>) {
        _selection = selection
        _anchor = State(initialValue: CalendarPaging.monthStart(containing: selection.wrappedValue,
                                                                calendar: WallClock().calendar))
    }

    var body: some View {
        let selected = CalendarPaging.monthOffset(of: selection, from: anchor, calendar: calendar)
        let locale = ChatFormat.dateLocale(environmentLocale)

        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(CalendarPaging.monthPages, id: \.self) { offset in
                        let month = CalendarPaging.month(offset, from: anchor, calendar: calendar)
                        chip(month, label: CalendarPaging.monthChipLabel(month, calendar: calendar, locale: locale),
                             isSelected: offset == selected)
                    }
                }
                .padding(.horizontal, 4)
            }
            .scrollDismissesKeyboard(.never) // sideways: keeps the keyboard up
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
            .onChange(of: selection) { old, new in
                var target = CalendarPaging.monthOffset(of: new, from: anchor, calendar: calendar)
                if !CalendarPaging.isWithinReach(target, of: CalendarPaging.monthPages) {
                    // Decades away: offset 0 becomes that month.
                    anchor = CalendarPaging.monthStart(containing: new, calendar: calendar)
                    target = 0
                }
                if abs(CalendarPaging.monthOffset(of: new, from: old, calendar: calendar)) <= 12 {
                    withAnimation(.snappy) { proxy.scrollTo(target, anchor: .center) }
                } else {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
        .frame(height: 32)
    }

    private func chip(_ month: Date, label: String, isSelected: Bool) -> some View {
        Button {
            withAnimation(.snappy) { selection = month }
        } label: {
            Text(verbatim: label.uppercased())
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? Color.black : Color.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isSelected ? Color.white : Theme.surfaceRaised)
                )
                .overlay(Capsule().strokeBorder(Color.white.opacity(isSelected ? 0 : 0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
