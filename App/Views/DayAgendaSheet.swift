import SwiftUI

/// What holding down a date in the main month grid opens: every event of that day, all-day ones first, then by time
/// (`DayAgenda`), with the place under the title. It follows changes as they happen (the rows come from the schedule).
/// A row opens the event page on top (`AppRouter.agendaEventID`, which a reminder tapped while the list is open uses
/// too); a draft (a plan or an "Ask me first" event still waiting for Add) closes the list and brings its card into
/// view instead, as its chip does.
struct DayAgendaSheet: View {
    let day: Date

    @Environment(AppRouter.self) private var router
    @Environment(ScheduleViewModel.self) private var schedule
    @Environment(ChatViewModel.self) private var chat
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var environmentLocale

    var body: some View {
        let clock = schedule.clock
        let items = DayAgenda.items(on: day, events: schedule.events(on: day), calendar: clock.calendar)

        NavigationStack {
            List {
                if items.isEmpty && schedule.isLoadingRange {
                    // The day's range is still being fetched: "No events" would not be true yet.
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } else if items.isEmpty {
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
            get: { router.agendaEventID.flatMap(schedule.event(id:)) },
            set: { router.agendaEventID = $0?.id }
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
            router.agendaEventID = event.id
        }
    }
}

/// Time on the left ("09:00" over "10:00", "All day", "→ 12:00" for an event from an earlier day, "18:00 →" for one
/// going on past midnight), the calendar's colour, then the title and the place.
private struct DayAgendaRow: View {
    let item: DayAgenda.Item
    let clock: WallClock

    /// Wide enough for "18:00 →" at the user's text size.
    @ScaledMetric(relativeTo: .subheadline) private var timeWidth: CGFloat = 64

    var body: some View {
        let event = item.event
        let tint = Color(hex: event.colorHex)

        HStack(alignment: .top, spacing: 10) {
            time
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(width: timeWidth, alignment: .leading)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(tint)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if event.kind == .task {
                        Image(systemName: event.isCompleted ? "checkmark.circle.fill" : "circle")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(tint)
                    }
                    Text(event.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white)
                        .strikethrough(event.kind == .task && event.isCompleted)
                        .lineLimit(2)
                    if event.isWaitingToSync {
                        PendingSyncGlyph(size: 11, color: Theme.textSecondary)
                    }
                }
                if let place = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
                    Text(place)
                        .font(.footnote)
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
