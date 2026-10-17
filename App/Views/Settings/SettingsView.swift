import SwiftUI
import UIKit

/// The drawer's "General": HOW the app behaves. Notifications, new events, the assistant, AI and privacy, data,
/// the Shortcuts guide, language, demo mode and about.
struct SettingsView: View {
    @Environment(ScheduleViewModel.self) private var schedule
    @Environment(ChatViewModel.self) private var chat
    @Environment(\.dismiss) private var dismiss
    @State private var model: SettingsModel

    init(model: SettingsModel? = nil) {
        _model = State(initialValue: model ?? SettingsModel())
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        Label("Notifications", systemImage: "bell.badge")
                    }
                    NavigationLink {
                        CalendarSettingsView()
                    } label: {
                        Label("Calendar & new events", systemImage: "calendar")
                    }
                    NavigationLink {
                        AssistantSettingsView()
                    } label: {
                        Label("Assistant", systemImage: "sparkles")
                    }
                }

                Section {
                    NavigationLink {
                        PrivacySettingsView()
                    } label: {
                        Label("AI & privacy", systemImage: "hand.raised")
                    }
                    NavigationLink {
                        DataSettingsView(onErased: { dismiss() })
                    } label: {
                        Label("Data", systemImage: "externaldrive")
                    }
                }

                Section {
                    NavigationLink {
                        ShortcutsGuideView()
                    } label: {
                        Label("Shortcuts and Siri", systemImage: "square.grid.2x2")
                    }
                }

                Section {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        LabeledContent {
                            Text(verbatim: Self.appLanguageName)
                        } label: {
                            Label("Language", systemImage: "globe")
                        }
                    }
                    .foregroundStyle(.primary)
                } footer: {
                    Text("iOS sets each app's language in the Settings app.")
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { schedule.isDemo },
                        set: { setDemo($0) }
                    )) {
                        Label("Demo mode", systemImage: "theatermasks")
                    }
                } footer: {
                    Text("Fictional sample calendars; your Google account isn't used. With AI data sharing allowed, what you type and the sample events go to Google's Gemini API; otherwise offline rules answer.")
                }

                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .environment(model)
        .task { await model.start() }
        .preferredColorScheme(.dark)
    }

    private func setDemo(_ on: Bool) {
        guard on != schedule.isDemo else { return }
        if on {
            chat.enableDemo()
            Task { await schedule.startDemo() }
        } else {
            chat.disableDemo()
            Task { await schedule.stopDemo() }
        }
    }

    /// The language the app's strings resolved to, named in that language ("English", "中文（台灣）").
    static var appLanguageName: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        let locale = Locale(identifier: code)
        return locale.localizedString(forIdentifier: code) ?? code
    }
}

// MARK: - Shared pieces of the Settings pages

/// A row with a checkmark when selected, for the inline pickers (who sends reminders, adding events, …).
struct CheckmarkRow<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var label: () -> Content

    var body: some View {
        Button(action: action) {
            HStack {
                label()
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A 24-hour time picker for a minute of the day, whatever the device's 12/24-hour setting.
struct TimeOfDayPicker: View {
    let title: LocalizedStringKey
    let minuteOfDay: Int
    let onChange: (Int) -> Void

    var body: some View {
        LabeledContent {
            DatePicker(selection: Binding(
                get: { SettingsTime.date(minuteOfDay: minuteOfDay) },
                set: { onChange(SettingsTime.minuteOfDay($0)) }
            ), displayedComponents: .hourAndMinute) {
                EmptyView()
            }
            .labelsHidden()
            // en_GB shows 24-hour digits without AM/PM; UTC matches `SettingsTime`. Only the picker: the label keeps
            // the app's language.
            .environment(\.locale, Locale(identifier: "en_GB"))
            .environment(\.timeZone, SettingsTime.timeZone)
        } label: {
            Text(title)
        }
    }
}
