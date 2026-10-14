import SwiftUI

/// Drawer › Events › "All events": every event of the visible calendars that has not ended, in sections (Now,
/// Today, Tomorrow, This week, Later) with one row per repeating series under "Repeating". Pushed inside the drawer.
///
/// Nothing needs refreshing by hand: the rows are worked out again every minute (ended events leave) and whenever
/// the cache changes (the assistant, a plan, Siri, the notification extension or another device through sync).
/// Opening the page asks for the next 12 months to be loaded (`ScheduleViewModel.loadUpcomingEvents`). Search
/// filters by title, place and notes; a row swipes to Delete (a series asks: this event or all) or Edit.
struct AllEventsView: View {
    @Environment(ScheduleViewModel.self) private var schedule
    @Environment(AppRouter.self) private var router
    @Environment(\.locale) private var locale

    @State private var query = ""
    /// The "Delete …?" confirmation on screen.
    @State private var pendingDelete: ScheduleEvent?
    @State private var errorMessage: String?

    var body: some View {
        TimelineView(.everyMinute) { context in
            list(now: context.date)
        }
        .navigationTitle(Text("Events"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search events"))
        .scrollContentBackground(.hidden)
        .background(Theme.surface)
        .onAppear { schedule.loadUpcomingEvents() }
        .eventDeleteDialog($pendingDelete) { event, scope in
            Task {
                do {
                    try await schedule.deleteEvent(event, scope: scope)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .alert(Text("Couldn't delete"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func list(now: Date) -> some View {
        let rows = schedule.rows(schedule.managedRows(now: now), matching: query)
        let sections = schedule.managedSections(rows, now: now)

        return List {
            if rows.isEmpty && query.isEmpty && !schedule.isLoadingRange {
                Section {
                    Text("Nothing coming up")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            ForEach(sections, id: \.section) { group in
                Section {
                    ForEach(group.rows, id: \.id) { row in
                        rowView(row, in: group.section, now: now)
                    }
                } header: {
                    ManagedEventSectionTitle(section: group.section)
                }
            }
            Section {
                if schedule.isLoadingRange {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading events")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .font(.system(size: 14))
                }
            } footer: {
                Text("Shows events in the next 12 months.")
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if rows.isEmpty && !query.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private func rowView(_ row: ManagedEventRow, in section: ManagedEventSection, now: Date) -> some View {
        let event = row.event
        return Button {
            router.selectedEventID = event.id
        } label: {
            ManagedEventRowView(event: event, isSeries: row.isSeries, isHappeningNow: row.isHappeningNow) {
                VStack(alignment: .leading, spacing: 2) {
                    if section == .repeating {
                        if let summary = schedule.repeatSummary(for: row, locale: ChatFormat.dateLocale(locale)) {
                            Text(verbatim: summary)
                        }
                        NextOccurrenceText(start: event.start, clock: schedule.clock)
                    } else {
                        EventWhenText(event: event, now: now, clock: schedule.clock)
                        if let location = event.location, !location.isEmpty {
                            Text(verbatim: location)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Not `role: .destructive`: that would animate the row away before the confirmation is answered.
            if !schedule.isReadOnly(event) {
                Button {
                    pendingDelete = event
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
            Button {
                router.selectedEventID = event.id
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }
}

extension View {
    /// "Delete “Yoga”?": one event asks once ("Delete event"); an event of a repeating series asks which ("Delete
    /// this event" / "Delete all events"). `onDelete` runs with the event and the scope chosen.
    func eventDeleteDialog(_ event: Binding<ScheduleEvent?>,
                           onDelete: @escaping (ScheduleEvent, EditScope) -> Void) -> some View {
        confirmationDialog(
            Text("Delete “\(event.wrappedValue?.title ?? "")”?"),
            isPresented: Binding(
                get: { event.wrappedValue != nil },
                set: { if !$0 { event.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: event.wrappedValue
        ) { target in
            if target.seriesID != nil {
                Button("Delete this event", role: .destructive) { onDelete(target, .thisEvent) }
                Button("Delete all events", role: .destructive) { onDelete(target, .allEvents) }
            } else {
                Button("Delete event", role: .destructive) { onDelete(target, .thisEvent) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            if target.seriesID != nil {
                Text("This is a repeating event.")
            }
        }
    }
}
