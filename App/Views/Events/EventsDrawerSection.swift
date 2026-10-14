import SwiftUI

/// The drawer's "Events" section: what is on now and next (at most `EventsDrawerSection.rowLimit` rows), then
/// "All events (N)", which pushes the full list. Every row opens the event page. Rows come from the visible
/// calendars and leave once their event has ended (`now` ticks every minute); "Nothing coming up" when none is left.
struct EventsDrawerSection: View {
    /// Every event the full list holds (`ScheduleViewModel.managedRows(now:)`): one row per repeating series.
    let rows: [ManagedEventRow]
    /// The next ones, one per occurrence, in time order.
    let upcoming: [ManagedEventRow]
    let now: Date
    var clock = WallClock()
    var onOpen: (ScheduleEvent) -> Void
    var onShowAll: () -> Void

    static let rowLimit = 6

    var body: some View {
        Section {
            if upcoming.isEmpty {
                Text("Nothing coming up")
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(Array(upcoming.prefix(Self.rowLimit)), id: \.id) { row in
                Button {
                    onOpen(row.event)
                } label: {
                    ManagedEventRowView(event: row.event, isSeries: row.isSeries, isHappeningNow: row.isHappeningNow) {
                        EventWhenText(event: row.event, now: now, clock: clock)
                    }
                }
                .buttonStyle(.plain)
            }
            Button(action: onShowAll) {
                HStack(spacing: 8) {
                    Text("All events (\(rows.count))")
                        .foregroundStyle(.white)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text("Events")
        }
    }
}
