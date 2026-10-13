import SwiftUI
import UIKit

/// Settings › Data: how long the conversation is kept, clearing it, exporting everything as JSON, and erasing every
/// trace of Smart Schedule from this iPhone (Smart Schedule has no accounts of its own to delete).
struct DataSettingsView: View {
    /// Settings closes once everything is erased: the app is back at its welcome state.
    var onErased: () -> Void = {}

    @Environment(SettingsModel.self) private var model
    @Environment(ScheduleViewModel.self) private var schedule
    @Environment(ChatViewModel.self) private var chat

    @State private var confirmsClear = false
    @State private var confirmsErase = false
    @State private var isExporting = false
    @State private var isErasing = false
    @State private var export: ExportFile?
    @State private var exportError: String?

    var body: some View {
        Form {
            Section {
                Picker("Keep chat history", selection: model.binding(\.chatRetention)) {
                    Text("7 days").tag(ChatRetention.week)
                    Text("30 days").tag(ChatRetention.month)
                    Text("Forever").tag(ChatRetention.forever)
                }
                Button("Clear chat history", role: .destructive) { confirmsClear = true }
            } footer: {
                Text("Older messages are deleted automatically. At most the last 200 messages are kept.")
            }

            Section {
                Button {
                    makeExport()
                } label: {
                    HStack {
                        Text("Export my data")
                        Spacer(minLength: 8)
                        if isExporting { ProgressView() }
                    }
                }
                .disabled(isExporting)
                if let exportError {
                    Text(verbatim: exportError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("A JSON file with your settings, what the assistant remembers, cached events and chat history. Sign-in tokens are never included.")
            }

            Section {
                Button(role: .destructive) {
                    confirmsErase = true
                } label: {
                    HStack {
                        Text("Erase all data on this device")
                        Spacer(minLength: 8)
                        if isErasing { ProgressView() }
                    }
                }
                .disabled(isErasing)
            }
        }
        .navigationTitle("Data")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Clear chat history?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { clearHistory() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Erase all data on this device?", isPresented: $confirmsErase, titleVisibility: .visible) {
            Button("Erase", role: .destructive) { eraseAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes your settings, cached events, chat history, sign-in tokens, scheduled reminders and Live Activities from this iPhone and disconnects every Google account. Events in Google Calendar are not deleted. Subscriptions belong to your Apple Account and are not affected.")
        }
        .sheet(item: $export) { file in
            ShareSheet(items: [file.url])
                .presentationDetents([.medium, .large])
        }
    }

    private func clearHistory() {
        Task {
            await ChatHistoryStore.shared.clear()
            chat.resetConversation()
        }
    }

    private func makeExport() {
        isExporting = true
        exportError = nil
        Task {
            defer { isExporting = false }
            do {
                export = ExportFile(url: try await DataExporter.makeExport())
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func eraseAll() {
        isErasing = true
        Task {
            await DataEraser.eraseAll()
            await schedule.resetAfterErase()
            chat.resetAfterErase()
            isErasing = false
            onErased()
        }
    }
}

/// The exported file, for `.sheet(item:)`.
struct ExportFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet (AirDrop, Files, Mail…) for the export.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
