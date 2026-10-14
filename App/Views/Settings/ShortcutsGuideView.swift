import SwiftUI

/// Settings › Shortcuts and Siri: where Smart Schedule's button and phrases can be added. iOS lets only the user
/// add Control Center controls, the Action Button, Lock Screen controls and Siri phrases, so this page explains how.
struct ShortcutsGuideView: View {
    var body: some View {
        Form {
            guide("Control Center", systemImage: "switch.2",
                  "Open Control Center, tap +, then Add a Control. Search for Smart Schedule and choose it.")
            guide("Action Button", systemImage: "hand.tap",
                  "On iPhone 15 Pro and later: open the Settings app › Action Button, swipe to Shortcut, then choose Add to Smart Schedule.")
            guide("Lock Screen", systemImage: "lock.iphone",
                  "Touch and hold the Lock Screen, tap Customize › Lock Screen, tap a control at the bottom and choose Smart Schedule.")
            Section {
                Label {
                    Text("Say “Add a plan in Smart Schedule”, “Schedule something with Smart Schedule” or “Open Quick Capture in Smart Schedule”.")
                } icon: {
                    Image(systemName: "mic")
                }
            } header: {
                Text("Siri")
            } footer: {
                Text("iOS doesn't let apps add these for you.")
            }
        }
        .navigationTitle("Shortcuts and Siri")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func guide(_ title: LocalizedStringKey, systemImage: String, _ steps: LocalizedStringKey) -> some View {
        Section {
            Label {
                Text(steps)
            } icon: {
                Image(systemName: systemImage)
            }
        } header: {
            Text(title)
        }
    }
}
