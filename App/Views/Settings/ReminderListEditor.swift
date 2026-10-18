import SwiftUI

/// Settings › Notifications › Default reminders › a kind: the reminders an event of that kind gets when the user
/// does not ask for specific ones. At most 5, Google's limit per event.
struct ReminderListEditor: View {
    let kind: ScheduleEvent.Kind

    @Environment(SettingsModel.self) private var model

    /// The "Add reminder" menu, in minutes before the start.
    private static let choices = [0, 5, 10, 15, 30, 60, 120, 1440, 2880, 10_080]
    private static let maxReminders = 5

    var body: some View {
        let minutes = model.reminders(for: kind)

        Form {
            Section {
                if minutes.isEmpty {
                    Text("None")
                        .foregroundStyle(.secondary)
                }
                ForEach(minutes, id: \.self) { offset in
                    Label {
                        Text(verbatim: ReminderText.offset(offset))
                    } icon: {
                        Image(systemName: "bell")
                    }
                }
                .onDelete { indices in
                    let remaining = minutes.enumerated().filter { !indices.contains($0.offset) }.map(\.element)
                    model.setReminders(remaining, for: kind)
                }

                Menu {
                    ForEach(Self.choices.filter { !minutes.contains($0) }, id: \.self) { offset in
                        Button(ReminderText.offset(offset)) {
                            model.setReminders(minutes + [offset], for: kind)
                        }
                    }
                } label: {
                    Label("Add reminder", systemImage: "plus.circle")
                }
                .disabled(minutes.count >= Self.maxReminders)
            } footer: {
                if kind == .routine {
                    Text("Used when you don't ask for specific reminders. Google allows up to 5 per event.")
                } else {
                    // ReminderPolicy.sameDayMinutes: items created for later the same day get [10, 0] instead.
                    Text("Used when you don't ask for specific reminders. A one-off event, deadline or task added for later the same day gets 10 min before and at start instead. Google allows up to 5 per event.")
                }
            }
        }
        .navigationTitle(kind.settingsTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !minutes.isEmpty { EditButton() }
        }
    }
}
