import SwiftUI

/// Settings › Assistant: the language replies are written in, whether single events wait for approval, and the language
/// of voice input (the mic button, recognised on this iPhone only: no On-device recognition switch any more).
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
                Picker("Speech language", selection: Binding(
                    get: { VoiceInput.offeredLanguage(model.preferences.speechLanguage) },
                    set: { language in model.update { $0.speechLanguage = language } }
                )) {
                    Text("Automatic").tag(SpeechLanguage.automatic)
                    Text(verbatim: "中文（台灣）").tag(SpeechLanguage.chineseTaiwan)
                    Text(verbatim: "English (US)").tag(SpeechLanguage.englishUS)
                }
            } header: {
                Text("Voice input")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tap the mic next to the text field to speak a plan. Speech is turned into text on this iPhone; the audio is not saved or sent anywhere. Nothing is sent until you tap Send.")
                    if VoiceTranscriber.supportsOnDevice(localeIdentifier: VoiceInput.localeIdentifier(for: preferences)) {
                        Label("Supported for this language", systemImage: "checkmark.circle")
                    } else {
                        Label("Not supported for this language", systemImage: "xmark.circle")
                        Text("This iPhone can't recognise this language on the device yet, so the mic is hidden. The keyboard's dictation still works.")
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
}
