import SwiftUI

/// Settings › Assistant: the language replies are written in and whether single events wait for approval.
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
        }
        .navigationTitle("Assistant")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func setAutonomy(_ autonomy: AssistantAutonomy) {
        model.update { $0.autonomy = autonomy }
    }
}
