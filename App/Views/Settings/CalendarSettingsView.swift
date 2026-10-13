import SwiftUI

/// Settings › Calendar & new events: where the assistant adds events and how long they last, the first day of the
/// week and the time zone.
struct CalendarSettingsView: View {
    @Environment(SettingsModel.self) private var model

    private static let durations = [15, 30, 45, 60, 90, 120]

    var body: some View {
        let preferences = model.preferences

        Form {
            Section {
                NavigationLink {
                    DefaultCalendarPicker()
                } label: {
                    LabeledContent {
                        Text(verbatim: preferences.displayValue(for: .defaultCalendar))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } label: {
                        Text("Calendar")
                    }
                }
                Picker("Default duration", selection: model.binding(\.defaultEventMinutes)) {
                    ForEach(Self.durations(including: preferences.defaultEventMinutes), id: \.self) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
            } header: {
                Text("New events")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Where the assistant adds events. Automatic uses My calendar of your first account.")
                    Text("Used when you don't say how long.")
                }
            }

            Section {
                Picker("Week starts on", selection: model.binding(\.weekStart)) {
                    Text("Sunday").tag(WeekStart.sunday)
                    Text("Monday").tag(WeekStart.monday)
                }
                Toggle("Follow this iPhone", isOn: Binding(
                    get: { preferences.timeZoneIdentifier == nil },
                    set: { follow in
                        let fixed = TimeZone.current.identifier
                        model.update { $0.timeZoneIdentifier = follow ? nil : fixed }
                    }
                ))
                if let identifier = preferences.timeZoneIdentifier {
                    NavigationLink {
                        TimeZonePicker(selection: identifier) { chosen in
                            model.update { $0.timeZoneIdentifier = chosen }
                        }
                    } label: {
                        LabeledContent {
                            Text(verbatim: TimeZonePicker.name(of: identifier))
                        } label: {
                            Text("Time zone")
                        }
                    }
                }
            } header: {
                Text("Calendar")
            } footer: {
                Text("New events are created in this time zone and your calendar is shown in it.")
            }
        }
        .navigationTitle("Calendar & new events")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The six lengths, plus a length set by voice ("make meetings 50 minutes") so the picker can show it.
    private static func durations(including current: Int) -> [Int] {
        durations.contains(current) ? durations : (durations + [current]).sorted()
    }
}

// MARK: - Calendar for new events

/// "Automatic" (the first account's My calendar), then every writable calendar, grouped by account.
struct DefaultCalendarPicker: View {
    @Environment(SettingsModel.self) private var model
    @Environment(ScheduleViewModel.self) private var schedule

    var body: some View {
        let chosen = model.preferences.defaultCalendar
        let automatic = schedule.accounts.first?.primaryCalendar

        Form {
            Section {
                CheckmarkRow(isSelected: chosen == nil, action: { choose(nil) }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatic")
                        if let automatic {
                            Text(verbatim: "\(automatic.displayName) · \(automatic.accountEmail)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Where the assistant adds events. Automatic uses My calendar of your first account.")
            }

            ForEach(schedule.accounts) { account in
                let writable = account.calendars.filter(\.isWritable)
                if !writable.isEmpty {
                    Section {
                        ForEach(writable) { calendar in
                            CheckmarkRow(isSelected: chosen == calendar.id, action: { choose(calendar) }) {
                                HStack(spacing: 10) {
                                    CalendarSquare(hex: calendar.displayColorHex)
                                    Text(verbatim: calendar.displayName)
                                }
                            }
                        }
                    } header: {
                        Text(verbatim: account.email)
                            .textCase(nil)
                    }
                }
            }
        }
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choose(_ calendar: CalendarInfo?) {
        if let calendar {
            let ref = calendar.id
            let label = calendar.promptLabel
            model.update {
                $0.defaultCalendar = ref
                $0.defaultCalendarLabel = label
            }
        } else {
            model.update { $0.reset(.defaultCalendar) }
        }
    }
}

// MARK: - Time zone

/// Every IANA time zone, searchable by city, region or identifier.
struct TimeZonePicker: View {
    let selection: String
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        List(matches, id: \.self) { identifier in
            CheckmarkRow(isSelected: identifier == selection, action: {
                onSelect(identifier)
                dismiss()
            }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: Self.name(of: identifier))
                    Text(verbatim: identifier)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle("Time zone")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var matches: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return all }
        return all.filter { identifier in
            identifier.localizedCaseInsensitiveContains(text)
                || Self.name(of: identifier).localizedCaseInsensitiveContains(text)
        }
    }

    /// "Taipei Standard Time" / "台北標準時間"; the identifier when iOS has no name for it.
    static func name(of identifier: String) -> String {
        TimeZone(identifier: identifier)?.localizedName(for: .generic, locale: .current) ?? identifier
    }
}
