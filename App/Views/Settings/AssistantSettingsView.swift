import Speech
import SwiftUI

/// Settings › Assistant: the language replies are written in, whether single events wait for approval, and voice
/// input.
struct AssistantSettingsView: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        let preferences = model.preferences

        Form {
            Section {
                Picker("Reply language", selection: model.binding(\.replyLanguage)) {
                    Text("Match what I type").tag(ReplyLanguage.matchInput)
                    // Language names are shown in their own language.
                    Text(verbatim: "繁體中文").tag(ReplyLanguage.traditionalChinese)
                    Text(verbatim: "English").tag(ReplyLanguage.english)
                }
            } header: {
                Text("Replies")
            }

            Section {
                CheckmarkRow(isSelected: preferences.autonomy == .addDirectly,
                             action: { setAutonomy(.addDirectly) }) {
                    Text("Add directly")
                }
                CheckmarkRow(isSelected: preferences.autonomy == .askFirst,
                             action: { setAutonomy(.askFirst) }) {
                    Text("Ask me first")
                }
            } header: {
                Text("Adding events")
            } footer: {
                Text("Ask me first: single events wait on a card with Add and Edit. Long-term plans always wait for your review.")
            }

            Section {
                Picker("Speech language", selection: model.binding(\.speechLanguage)) {
                    Text("Automatic").tag(SpeechLanguage.automatic)
                    Text(verbatim: "中文（台灣）").tag(SpeechLanguage.chineseTaiwan)
                    Text(verbatim: "English (UK)").tag(SpeechLanguage.englishUK)
                    Text(verbatim: "English (US)").tag(SpeechLanguage.englishUS)
                }
                Toggle("On-device recognition", isOn: model.binding(\.speechOnDevice))
            } header: {
                Text("Voice input")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("When on, speech in languages this iPhone supports is recognised on the device and never leaves it. Other languages use Apple's servers.")
                    if Self.supportsOnDevice(preferences.speechLanguage) {
                        Label("Supported for this language", systemImage: "checkmark.circle")
                    } else {
                        Label("Not supported for this language", systemImage: "xmark.circle")
                    }
                }
            }
        }
        .navigationTitle("Assistant")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func setAutonomy(_ autonomy: AssistantAutonomy) {
        model.update { $0.autonomy = autonomy }
    }

    /// Whether this iPhone can recognise `language` without Apple's servers.
    static func supportsOnDevice(_ language: SpeechLanguage) -> Bool {
        let locale = language.localeIdentifier.map(Locale.init(identifier:)) ?? Locale.current
        return SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
    }
}
