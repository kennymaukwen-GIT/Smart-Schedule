import SwiftUI

/// "CLICK TO VIEW PLAN" (Artboard 5, right), now the event page itself (`EventPage`): what an event is, editable in
/// place, as a sheet. The day list (`DayAgendaSheet`) presents it over itself for `AppRouter.agendaEventID`; otherwise
/// RootView presents it for `AppRouter.selectedEventID`, whoever set it: a chip in the month
/// grid or Quick Capture's DAY / WEEK / MONTH, the drawer's Events section, the events list, the chat's "Manage"
/// button, a reminder tapped in Notification Center or a `smartschedule://event?id=` link.
struct EventDetailSheet: View {
    let event: ScheduleEvent

    var body: some View {
        NavigationStack {
            EventPage(event: event)
        }
        .preferredColorScheme(.dark)
    }
}
