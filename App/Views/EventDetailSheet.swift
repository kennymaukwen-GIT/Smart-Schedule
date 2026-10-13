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
        if event.isAllDay {
            return event.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) + " · "
                + String(localized: "All day")
        }
        let day = event.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        // 24-hour, like the timeline and the chat.
        return "\(day) · \(ReplyFormatter.timeRange(event, clock: WallClock()))"
    }

    static func reminderText(_ minutes: Int, allDay: Bool = false) -> String {
        if allDay {
            // All-day reminders count back from 00:00 of the event day: 900 = the day before at 09:00.
            let daysBefore = (minutes + 1439) / 1440
            let minuteOfDay = daysBefore * 1440 - minutes
            let time = String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60)
            switch daysBefore {
            case 0: return String(localized: "On the day at \(time)")
            case 1: return String(localized: "The day before at \(time)")
            default: return String(localized: "\(daysBefore) days before at \(time)")
            }
        }
        return switch minutes {
        case 0: String(localized: "At start")
        case 1..<60: String(localized: "\(minutes) minutes before")
        case 60..<120: String(localized: "1 hour before")
        case 120..<1440: String(localized: "\(minutes / 60) hours before")
        case 1440..<2880: String(localized: "1 day before")
        default: String(localized: "\(minutes / 1440) days before")
        }
    }
}
