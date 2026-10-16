import SwiftUI

/// One calendar's settings on this iPhone, pushed inside the drawer: shown or hidden, its colour, its reminders,
/// and whether the assistant adds new events to it. Nothing here changes the calendar in Google.
struct CalendarDetailsView: View {
    let ref: CalendarRef

    @Environment(ScheduleViewModel.self) private var schedule

    private static let palette = Theme.calendarColorChoices

    var body: some View {
        Group {
            if let calendar = schedule.calendar(ref) {
                form(calendar)
                    .navigationTitle(Text(verbatim: calendar.displayName))
            } else {
                // Its account was removed, or Google removed it, while open.
                ContentUnavailableView("Calendar", systemImage: "calendar")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Theme.surface)
    }

    private func form(_ calendar: CalendarInfo) -> some View {
        Form {
            Section {
                Toggle("Show in Smart Schedules", isOn: Binding(
                    get: { calendar.isVisible },
                    set: { schedule.setVisible($0, calendar: ref) }
                ))
            } header: {
                Text(verbatim: calendar.accountEmail)
                    .textCase(nil)
            } footer: {
                Text("Hidden calendars stay on this iPhone but are not shown and send no reminders.")
            }

            Section {
                colourGrid(calendar)
            } header: {
                Text("Colour")
            } footer: {
                Text("Changes the colour on this iPhone only. Google Calendar keeps its own colour.")
            }

            Section {
                Toggle("Reminders", isOn: Binding(
                    get: { calendar.notificationsEnabled },
                    set: { schedule.setNotificationsEnabled($0, calendar: ref) }
                ))
            } header: {
                Text("Notifications")
            } footer: {
                Text("Off: Smart Schedules sends no reminders for events in this calendar.")
            }

            Section {
                Toggle("Use for new events", isOn: Binding(
                    get: { calendar.isWritable && schedule.defaultWriteTarget == ref },
                    set: { schedule.setDefaultCalendar($0 ? calendar : nil) }
                ))
                .disabled(!calendar.isWritable)
            } header: {
                Text("New events")
            } footer: {
                if calendar.isWritable {
                    Text("New events from the assistant go to this calendar.")
                } else {
                    Text("You can't add events to this calendar.")
                }
            }

            Section {
                LabeledContent("Access") {
                    Text(accessText(calendar.accessRole))
                }
                if let zone = calendar.timeZone, !zone.isEmpty {
                    LabeledContent("Time zone") {
                        Text(verbatim: zone)
                    }
                }
            } header: {
                Text("About")
            }
        }
    }

    // MARK: Colour

    private func colourGrid(_ calendar: CalendarInfo) -> some View {
        let columns = [GridItem(.adaptive(minimum: 40), spacing: 12)]

        return VStack(alignment: .leading, spacing: 12) {
            Button {
                schedule.setColorOverride(nil, calendar: ref)
            } label: {
                HStack(spacing: 10) {
                    Swatch(hex: calendar.googleColorHex, isSelected: calendar.colorOverrideHex == nil)
                    Text("Calendar colour")
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(Self.palette, id: \.self) { hex in
                    Button {
                        schedule.setColorOverride(hex, calendar: ref)
                    } label: {
                        Swatch(hex: hex, isSelected: calendar.colorOverrideHex?.uppercased() == hex.uppercased())
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func accessText(_ role: String) -> LocalizedStringKey {
        switch role {
        case "owner": "Owner"
        case "writer": "Can edit"
        default: "View only"
        }
    }
}

/// A round colour swatch, checked when selected.
private struct Swatch: View {
    let hex: String
    var isSelected = false

    var body: some View {
        Circle()
            .fill(Color(hex: hex))
            .frame(width: 30, height: 30)
            .overlay {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .overlay(Circle().strokeBorder(Color.white.opacity(isSelected ? 0.9 : 0), lineWidth: 2).padding(-4))
            .padding(4)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
