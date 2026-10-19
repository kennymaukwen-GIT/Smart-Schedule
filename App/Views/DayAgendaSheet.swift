import SwiftUI

/// What a tapped date in the main month grid opens: every event of that day, all-day ones first, then by time
/// (`DayAgenda`), with the place under the title. It follows changes as they happen (the rows come from the schedule).
/// A row opens the event page on top, as a chip does; a draft (a plan or an "Ask me first" event still waiting for
/// Add) closes the list and brings its card into view instead, as its chip does.
struct DayAgendaSheet: View {
    let day: Date

    @Environment(AppRouter.self) private var router
    @Environment(ScheduleViewModel.self) private var schedule
    @Environment(ChatViewModel.self) private var chat
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var environmentLocale

    /// The event page open over the list.
    @State private var openEventID: String?

    var body: some View {
        let clock = schedule.clock
        let items = DayAgenda.items(on: day, events: schedule.events(on: day), calendar: clock.calendar)

        NavigationStack {
            List {
                if items.isEmpty {
                    Text("No events on this day")
                        .foregroundStyle(Theme.textSecondary)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(items) { item in
                        Button {
                            open(item.event)
                        } label: {
                            DayAgendaRow(item: item, clock: clock)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.surface)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.canvas)
            .navigationTitle(Text(verbatim: ReplyFormatter.dayLabel(day, clock: clock,
                                                                    locale: ChatFormat.dateLocale(environmentLocale))))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .sheet(item: Binding(
            get: { openEventID.flatMap(schedule.event(id:)) },
            set: { openEventID = $0?.id }
        )) { event in
            EventDetailSheet(event: event)
                .environment(router)
                .environment(schedule)
                .environment(chat)
                .environment(\.timeZone, clock.timeZone)
        }
    }

    private func open(_ event: ScheduleEvent) {
        if event.isDraft {
            dismiss()
            chat.revealOpenPlan()
        } else {
            openEventID = event.id
        }
    }
}

/// Time on the left ("09:00" over "10:00", "All day", "→ 12:00" for an event from an earlier day, "18:00 →" for one
/// going on past midnight), the calendar's colour, then the title and the place.
private struct DayAgendaRow: View {
    let item: DayAgenda.Item
    let clock: WallClock

    var body: some View {
        let event = item.event
        let tint = Color(hex: event.colorHex)

        HStack(alignment: .top, spacing: 10) {
            time
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .frame(width: 64, alignment: .leading)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(tint)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if event.kind == .task {
                        Image(systemName: event.isCompleted ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                    Text(event.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .strikethrough(event.kind == .task && event.isCompleted)
                        .lineLimit(2)
                    if event.isWaitingToSync {
                        PendingSyncGlyph(size: 11, color: Theme.textSecondary)
                    }
                }
                if let place = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
                    Text(place)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .draftGhost(event.isDraft, shape: RoundedRectangle(cornerRadius: 8), tint: tint)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var time: some View {
        switch item.timing {
        case .allDay:
            Text("All day")
                .foregroundStyle(.white)
        case let .timed(start?, end?) where start == end:
            Text(verbatim: ReplyFormatter.clockTime(start, clock: clock))
                .foregroundStyle(.white)
        case let .timed(start?, end?):
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: ReplyFormatter.clockTime(start, clock: clock))
                    .foregroundStyle(.white)
                Text(verbatim: ReplyFormatter.clockTime(end, clock: clock))
                    .foregroundStyle(Theme.textSecondary)
            }
        case let .timed(start?, nil):
            Text(verbatim: ReplyFormatter.clockTime(start, clock: clock) + " →")
                .foregroundStyle(.white)
        case let .timed(nil, end?):
            Text(verbatim: "→ " + ReplyFormatter.clockTime(end, clock: clock))
                .foregroundStyle(.white)
        case .timed(nil, nil):
            Text("All day")
                .foregroundStyle(.white)
        }
    }
}
