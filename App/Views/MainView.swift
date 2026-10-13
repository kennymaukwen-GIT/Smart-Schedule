import SwiftUI

/// Artboard 5. Top half = view area (year, month chips, month grid). Bottom = AI conversation.
struct MainView: View {
    @Environment(ScheduleViewModel.self) private var schedule
    @Environment(ChatViewModel.self) private var chat
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var schedule = schedule

        VStack(spacing: 12) {
            Text(schedule.displayedMonth.formatted(.dateTime.year()))
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .padding(.top, 4)

            MonthPickerBar(months: schedule.monthStrip, selection: $schedule.displayedMonth)

            MonthGridView(
                month: schedule.displayedMonth,
                today: Date(),
                eventsOnDay: schedule.events(on:),
                onSelect: { event in
                    // A ghost occurrence has no detail yet: bring its plan card (Add / Keep editing) into view.
                    if event.isDraft {
                        chat.revealOpenPlan()
                    } else {
                        router.selectedEventID = event.id
                    }
                }
            )
            .frame(maxHeight: .infinity)

            ChatPanel(takesFocusRequests: router.quickCapture == nil)
                .containerRelativeFrame(.vertical) { height, _ in height * 0.40 }
        }
        .padding(.horizontal, 12)
        .background(Theme.canvas.ignoresSafeArea())
        .refreshable { await schedule.refresh() }
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

struct MonthPickerBar: View {
    let months: [Date]
    @Binding var selection: Date

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(months, id: \.self) { month in
                        let isSelected = Calendar.current.isDate(month, equalTo: selection, toGranularity: .month)
                        Button {
                            withAnimation(.snappy) { selection = month }
                        } label: {
                            Text(month.formatted(.dateTime.month(.abbreviated)).uppercased())
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(isSelected ? Color.black : Color.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(isSelected ? Color.white : Theme.surfaceRaised)
                                )
                                .overlay(Capsule().strokeBorder(Color.white.opacity(isSelected ? 0 : 0.6), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .id(month)
                    }
                }
                .padding(.horizontal, 4)
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
    }
}
