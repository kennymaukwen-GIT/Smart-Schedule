import SwiftUI

/// Settings › Notifications: who sends reminders, default reminders and urgency per kind, quiet hours, the daily
/// briefing, a daily limit, the Dynamic Island, Focus filters and learned suggestions.
struct NotificationSettingsView: View {
    @Environment(SettingsModel.self) private var model
    /// The stepper's value while the limit is off, so turning it on again starts there.
    @State private var capDraft = 10

    private static let leadChoices: [Int?] = [nil, 15, 30, 60, 120]

    var body: some View {
        let preferences = model.preferences
        let sentBySmartSchedule = preferences.reminderSource != .google

        Form {
            sourceSection(preferences.reminderSource)

            Section {
                ForEach(ScheduleEvent.Kind.settingsOrder, id: \.self) { kind in
                    NavigationLink {
                        ReminderListEditor(kind: kind)
                    } label: {
                        LabeledContent {
                            Text(verbatim: preferences.displayValue(for: kind.remindersKey))
                                .lineLimit(1)
                        } label: {
                            Text(kind.settingsTitle)
                        }
                    }
                }
                NavigationLink {
                    AllDayReminderView()
                } label: {
                    LabeledContent {
                        Text(verbatim: preferences.displayValue(for: .allDayReminder))
                            .lineLimit(1)
                    } label: {
                        Text("All-day events")
                    }
                }
            } header: {
                Text("Default reminders")
            } footer: {
                Text("Used when you don't ask for specific reminders. Google allows up to 5 per event.")
            }

            Section {
                ForEach(ScheduleEvent.Kind.settingsOrder, id: \.self) { kind in
                    NavigationLink {
                        UrgencyPickerView(kind: kind)
                    } label: {
                        LabeledContent {
                            Text(verbatim: preferences.displayValue(for: kind.urgencyKey))
                        } label: {
                            Text(kind.settingsTitle)
                        }
                    }
                }
            } header: {
                Text("Urgency")
            } footer: {
                if sentBySmartSchedule {
                    Text("Automatic: Time Sensitive when 30 minutes or less before the start, otherwise Normal. Time Sensitive reminders break through Focus. Quiet reminders arrive silently in Notification Center.")
                } else {
                    Text("Only for reminders sent by Smart Schedule.")
                }
            }
            .disabled(!sentBySmartSchedule)

            quietHoursSection(preferences.quietHours, enabled: sentBySmartSchedule)

            briefingSection(preferences)

            capSection(preferences.dailyReminderCap, enabled: sentBySmartSchedule)

            Section {
                Picker("Show next event", selection: model.binding(\.liveActivityLeadMinutes)) {
                    ForEach(Self.leadChoices(including: preferences.liveActivityLeadMinutes), id: \.self) { minutes in
                        leadLabel(minutes).tag(minutes)
                    }
                }
            } header: {
                Text("Dynamic Island")
            } footer: {
                Text("Smart Schedule can show your next event in the Dynamic Island when you open the app or use its Control Center button. Starting it on its own before every event would need a push server, which Smart Schedule doesn't have.")
            }

            Section {
                Label("Focus filters", systemImage: "moon")
            } header: {
                Text("Focus")
            } footer: {
                Text("Choose which calendars show and alert while a Focus is on: open the Settings app, tap Focus, choose a Focus, then Add Filter › Smart Schedule.")
            }

            if !model.pendingSuggestions.isEmpty {
                suggestionsSection
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { capDraft = preferences.dailyReminderCap ?? capDraft }
    }

    // MARK: Who sends reminders

    private func sourceSection(_ source: ReminderSource) -> some View {
        Section {
            CheckmarkRow(isSelected: source == .smartSchedule, action: { setSource(.smartSchedule) }) {
                Text("Smart Schedule only")
            }
            CheckmarkRow(isSelected: source == .google, action: { setSource(.google) }) {
                Text("Google Calendar only")
            }
            CheckmarkRow(isSelected: source == .both, action: { setSource(.both) }) {
                Text("Both")
            }
        } header: {
            Text("Who sends reminders")
        } footer: {
            switch source {
            case .smartSchedule:
                Text("Smart Schedule's reminders let you reply, snooze or reschedule right in the notification. New events get no Google pop-ups, so your other devices won't alert you about them. Turn off notifications for the Google Calendar app on this iPhone to avoid duplicates.")
            case .google:
                Text("Google Calendar alerts you on all your devices. Smart Schedule sends no reminders, so you can't reply to them.")
            case .both:
                Text("You may get two alerts for the same event, one from Google and one from Smart Schedule. Turning off notifications for the Google Calendar app on this iPhone avoids that.")
            }
        }
    }

    private func setSource(_ source: ReminderSource) {
        model.update { $0.reminderSource = source }
    }

    // MARK: Quiet hours

    private func quietHoursSection(_ quiet: QuietHours, enabled: Bool) -> some View {
        Section {
            Toggle("Quiet hours", isOn: Binding(
                get: { quiet.isEnabled },
                set: { on in model.update { $0.quietHours.isEnabled = on } }
            ))
            if quiet.isEnabled {
                TimeOfDayPicker(title: "From", minuteOfDay: quiet.startMinute) { minute in
                    model.update { $0.quietHours.startMinute = minute }
                }
                TimeOfDayPicker(title: "To", minuteOfDay: quiet.endMinute) { minute in
                    model.update { $0.quietHours.endMinute = minute }
                }
            }
        } header: {
            Text("Quiet hours")
        } footer: {
            if enabled {
                Text("Reminders during quiet hours arrive silently. None are dropped.")
            } else {
                Text("Only for reminders sent by Smart Schedule.")
            }
        }
        .disabled(!enabled)
    }

    // MARK: Daily briefing

    private func briefingSection(_ preferences: AppPreferences) -> some View {
        Section {
            Toggle("Morning briefing", isOn: Binding(
                get: { preferences.morningBriefing.isEnabled },
                set: { on in model.update { $0.morningBriefing.isEnabled = on } }
            ))
            if preferences.morningBriefing.isEnabled {
                TimeOfDayPicker(title: "Time", minuteOfDay: preferences.morningBriefing.minuteOfDay) { minute in
                    model.update { $0.morningBriefing.minuteOfDay = minute }
                }
            }
            Toggle("Evening preview", isOn: Binding(
                get: { preferences.eveningPreview.isEnabled },
                set: { on in model.update { $0.eveningPreview.isEnabled = on } }
            ))
            if preferences.eveningPreview.isEnabled {
                TimeOfDayPicker(title: "Time", minuteOfDay: preferences.eveningPreview.minuteOfDay) { minute in
                    model.update { $0.eveningPreview.minuteOfDay = minute }
                }
            }
        } header: {
            Text("Daily briefing")
        } footer: {
            Text("A summary of the day's events, prepared ahead and refreshed whenever your calendar changes. The evening preview covers tomorrow.")
        }
    }

    // MARK: Daily limit

    private func capSection(_ cap: Int?, enabled: Bool) -> some View {
        Section {
            Toggle("Limit reminders per day", isOn: Binding(
                get: { cap != nil },
                set: { on in
                    let value = capDraft
                    model.update { $0.dailyReminderCap = on ? value : nil }
                }
            ))
            if let cap {
                Stepper(value: Binding(
                    get: { cap },
                    set: { value in
                        capDraft = value
                        model.update { $0.dailyReminderCap = value }
                    }
                ), in: 1...50) {
                    Text("At most \(cap) a day")
                }
            }
        } header: {
            Text("Daily limit")
        } footer: {
            if enabled {
                Text("When a day has more, the most important are sent: events starting now, then deadlines, other event reminders, tasks and routines. The rest are listed in that day's morning briefing.")
            } else {
                Text("Only for reminders sent by Smart Schedule.")
            }
        }
        .disabled(!enabled)
    }

    // MARK: Dynamic Island

    /// The five choices, plus a value set elsewhere (by an older build) so the picker can still show it.
    private static func leadChoices(including current: Int?) -> [Int?] {
        leadChoices.contains(current) ? leadChoices : leadChoices + [current]
    }

    @ViewBuilder
    private func leadLabel(_ minutes: Int?) -> some View {
        switch minutes {
        case nil: Text("Off")
        case 60?: Text("1 hour before")
        case let minutes? where minutes % 60 == 0: Text("\(minutes / 60) hours before")
        case let minutes?: Text("\(minutes) min before")
        }
    }

    // MARK: Suggestions

    private var suggestionsSection: some View {
        Section {
            ForEach(model.pendingSuggestions) { suggestion in
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: suggestion.question)
                        .font(.subheadline)
                    HStack(spacing: 10) {
                        Button("Stop it") { model.resolveSuggestion(suggestion, accept: true) }
                            .buttonStyle(.borderedProminent)
                        Button("Keep") { model.resolveSuggestion(suggestion, accept: false) }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Suggestions")
        } footer: {
            Text("Smart Schedule notices reminders you keep dismissing and offers to stop them. Nothing changes until you tap.")
        }
    }
}

// MARK: - All-day events

/// Settings › Notifications › All-day events: whether all-day events and plan check-ins get a reminder, and at what
/// time the day before.
struct AllDayReminderView: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        let minutes = model.preferences.allDayReminderMinutes

        Form {
            Section {
                Toggle("Remind me", isOn: Binding(
                    get: { minutes != nil },
                    set: { on in model.update { $0.allDayReminderMinutes = on ? (minutes ?? 900) : nil } }
                ))
                if let minutes {
                    // Minutes before 00:00 of the event day: 900 = the day before at 09:00.
                    TimeOfDayPicker(title: "The day before at", minuteOfDay: (1440 - minutes) % 1440) { minute in
                        model.update { $0.allDayReminderMinutes = 1440 - minute }
                    }
                }
            } footer: {
                Text("Used when you don't ask for specific reminders. Google allows up to 5 per event.")
            }
        }
        .navigationTitle("All-day events")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Urgency

/// Settings › Notifications › Urgency › a kind: how its reminders interrupt.
struct UrgencyPickerView: View {
    let kind: ScheduleEvent.Kind

    @Environment(SettingsModel.self) private var model

    var body: some View {
        let current = model.preferences.urgency(for: kind)

        Form {
            Section {
                ForEach(ReminderUrgency.allCases, id: \.self) { urgency in
                    CheckmarkRow(isSelected: urgency == current, action: { model.setUrgency(urgency, for: kind) }) {
                        Text(verbatim: AppPreferences.display(urgency))
                    }
                }
            } footer: {
                Text("Automatic: Time Sensitive when 30 minutes or less before the start, otherwise Normal. Time Sensitive reminders break through Focus. Quiet reminders arrive silently in Notification Center.")
            }
        }
        .navigationTitle(kind.settingsTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}
