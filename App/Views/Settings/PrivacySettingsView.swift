import SwiftUI

/// Settings › AI & privacy: whether the assistant may send requests to Google's Gemini API (and what it sends),
/// and "What the assistant remembers": every lasting preference changed by voice, in Settings or learned from
/// habits, each deletable (back to its default).
struct PrivacySettingsView: View {
    @Environment(SettingsModel.self) private var model
    @State private var confirmsStop = false
    /// Allow shows the same disclosure as the first use of the assistant, and grants only from its Allow.
    @State private var asksConsent = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    if model.consent.isGranted {
                        Text("Allowed")
                    } else {
                        Text("Not allowed")
                    }
                }
                if model.consent.isGranted {
                    Button("Stop sharing", role: .destructive) { confirmsStop = true }
                } else {
                    Button("Allow") { asksConsent = true }
                }
                NavigationLink {
                    ScrollView {
                        AIConsentDisclosureText()
                            .padding(20)
                    }
                    .navigationTitle("What is sent")
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Text("What is sent")
                }
            } header: {
                Text("AI data sharing")
            } footer: {
                Text("The assistant sends your requests to Google's Gemini API to understand them.")
            }

            Section {
                if model.ledger.isEmpty {
                    Text("Nothing yet. Try saying “from now on, remind me 2 hours before gym”.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.ledger) { entry in
                    LedgerRow(entry: entry)
                }
                .onDelete { indices in
                    model.deleteLedgerEntries(indices.map { model.ledger[$0].id })
                }
            } header: {
                Text("What the assistant remembers")
            } footer: {
                Text("Deleting an item puts that setting back to its default.")
            }
        }
        .navigationTitle("AI & privacy")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $asksConsent) {
            AIConsentSheet(onAllow: {
                model.allowAI()
                asksConsent = false
            }, onNotNow: {
                asksConsent = false
            })
        }
        .confirmationDialog("Stop sharing with Google Gemini?", isPresented: $confirmsStop, titleVisibility: .visible) {
            Button("Stop sharing", role: .destructive) { model.stopSharingAI() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The assistant will stop working until you allow sharing again. Demo mode keeps working.")
        }
        .toolbar {
            if !model.ledger.isEmpty { EditButton() }
        }
    }
}

/// "Quiet hours: Off → 22:00–08:00", then where it came from and when ("You said: “…” · Oct 14").
struct LedgerRow: View {
    let entry: LedgerEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: "\(entry.key.title): \(entry.previousDisplay) → \(entry.display)")
            Text(verbatim: "\(entry.source.label) · \(entry.date.formatted(.dateTime.month(.abbreviated).day()))")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}
