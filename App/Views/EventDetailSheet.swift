import SwiftUI

/// "CLICK TO VIEW PLAN" (Artboard 5, right) — mirrors Google Calendar's event detail.
struct EventDetailSheet: View {
    let event: ScheduleEvent
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(hex: event.colorHex))
                            .frame(width: 14, height: 14)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.title).font(.title3.weight(.semibold))
                            Text(timeLine).font(.subheadline).foregroundStyle(.secondary)
                            if event.isWaitingToSync {
                                Label("Waiting to sync", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    if let location = event.location ?? (event.meetURL != nil ? "Google Meet" : nil) {
                        Label(location, systemImage: "mappin.and.ellipse")
                    }
                    if let minutes = event.reminderMinutes, !minutes.isEmpty {
                        Label(minutes.map { Self.reminderText($0, allDay: event.isAllDay) }.joined(separator: ", "),
                              systemImage: "bell")
                    }
                    if let notes = event.notes, !notes.isEmpty {
                        Label(notes, systemImage: "text.alignleft")
                    }
                    if event.planID != nil {
                        Label("Part of a long-term plan", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }
                Section {
                    if let meet = event.meetURL {
                        Button { openURL(meet) } label: { Label("Join Google Meet", systemImage: "video") }
                    }
                    if let link = event.htmlLink {
                        Button { openURL(link) } label: { Label("Open in Google Calendar", systemImage: "arrow.up.right.square") }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private var timeLine: String {
        // Settings › Time zone, not necessarily the device's.
        let clock = WallClock()
        let day = event.start.formatted(
            Date.FormatStyle(timeZone: clock.timeZone).weekday(.wide).month(.abbreviated).day()
        )
        if event.isAllDay {
            return day + " · " + String(localized: "All day")
        }
        // 24-hour, like the timeline and the chat.
        return "\(day) · \(ReplyFormatter.timeRange(event, clock: clock))"
    }

    /// "1 hour before", "The day before at 09:00": the wording Settings uses too.
    static func reminderText(_ minutes: Int, allDay: Bool = false) -> String {
        ReminderText.offset(minutes, allDay: allDay)
    }
}
