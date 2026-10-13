import SwiftUI
import UIKit

/// Bottom half of Artboard 5: conversation with the scheduling agent.
struct ChatPanel: View {
    /// False while Quick Capture is on top: its own field answers Keep editing, not this one behind it.
    var takesFocusRequests = true

    @Environment(ChatViewModel.self) private var chat
    @Environment(ScheduleViewModel.self) private var schedule
    @FocusState private var inputFocused: Bool

    var body: some View {
        @Bindable var chat = chat

        VStack(spacing: 10) {
            if !schedule.isSignedIn && !schedule.isDemo {
                Button {
                    Task { await schedule.signIn() }
                } label: {
                    Label("Connect Google Calendar", systemImage: "calendar.badge.plus")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
                        .foregroundStyle(.black)
                }
                Button {
                    chat.enableDemo()
                    Task { await schedule.startDemo() }
                } label: {
                    Label("Try demo (no account)", systemImage: "sparkles")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hairline))
                        .foregroundStyle(.white)
                }
            }

            if schedule.isDemo {
                DemoBadge {
                    chat.disableDemo()
                    Task { await schedule.stopDemo() }
                }
            }

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(chat.messages) { message in
                            ChatMessageRow(message: message,
                                           onSuggestion: { chat.send($0) },
                                           onConfirmDelete: { chat.confirmDeletion(in: message) },
                                           onAddPlan: { chat.addPlan(message) },
                                           onKeepEditing: { chat.keepEditing(message) })
                                .id(message.id)
                        }
                        if chat.isSending {
                            ProgressView().tint(.white).padding(.leading, 4)
                        }
                    }
                    .padding(.top, 8)
                }
                .onChange(of: chat.messages.count) {
                    if let last = chat.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: chat.planRevealRequest) {
                    if let id = chat.openPlanMessageID {
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) } // the card's buttons
                    }
                }
            }

            ComposerBar(
                text: $chat.draft,
                placeholder: "Type your schedule, event, aim, or plan, or send a link with a date and time",
                showsAttachment: true,
                isBusy: chat.isBusy,
                focus: $inputFocused,
                onSend: { chat.send() }
            )
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Theme.surface))
        .onChange(of: chat.inputFocusRequest) {
            if takesFocusRequests { inputFocused = true } // Keep editing: "What would you like to change?"
        }
    }
}

/// "DEMO" capsule shown while the app runs on sample data; its menu leaves demo mode.
private struct DemoBadge: View {
    var onExit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button(role: .destructive, action: onExit) {
                    Label("Exit demo", systemImage: "xmark.circle")
                }
            } label: {
                Text("DEMO")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(hex: DemoData.taskHex)))
            }
            Text("Sample data · nothing is sent to Google")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }
}

struct ChatMessageRow: View {
    let message: ChatViewModel.Message
    /// Quick Capture: the plan card alone, compact (it carries the summary; the review line is its footer).
    var compactPlan = false
    var onSuggestion: (String) -> Void = { _ in }
    var onConfirmDelete: () -> Void = {}
    var onAddPlan: () -> Void = {}
    var onKeepEditing: () -> Void = {}

    var body: some View {
        switch message.role {
        case .user:
            // Artboard 5: wide graphite bubble, left-aligned text.
            Text(message.text)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.bubble))
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if let plan = message.planDraft {
                    // The card shows the summary and assumptions; only the rest of the reply goes above it.
                    if !compactPlan, let lead = PlanPreviewCard.leadText(message.text, summary: plan.summary) {
                        replyText(lead)
                    }
                    PlanPreviewCard(draft: plan,
                                    status: message.planStatus,
                                    style: compactPlan ? .compact : .full,
                                    onAdd: onAddPlan,
                                    onKeepEditing: onKeepEditing)
                } else {
                    replyText(message.text)
                    ForEach(message.assumptions, id: \.self) { assumption in
                        Label(assumption, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                if message.pendingDeletion != nil {
                    Button("Confirm", role: .destructive, action: onConfirmDelete)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
                if !message.suggestions.isEmpty {
                    // Scrolls sideways: Keep editing offers four chips, more than one row holds.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(message.suggestions, id: \.self) { suggestion in
                                Button(suggestion) { onSuggestion(suggestion) }
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().strokeBorder(Theme.hairline))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func replyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(.white.opacity(0.92))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shared input bar (Artboards 2–5): optional paperclip, field, mic, send.
struct ComposerBar: View {
    @Binding var text: String
    var placeholder: String
    var showsAttachment = false
    var isBusy = false
    var focus: FocusState<Bool>.Binding
    var startsRecording = false
    var onSend: () -> Void

    @State private var transcriber = SpeechTranscriber()

    var body: some View {
        HStack(spacing: 8) {
            if showsAttachment {
                Button(action: pasteLink) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                }
                .accessibilityLabel("Paste a link")
            }

            TextField(placeholder, text: $text)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .focused(focus)
                .submitLabel(.send)
                .onSubmit(onSend)

            Button {
                Task { await transcriber.toggle() }
            } label: {
                Image(systemName: transcriber.isRecording ? "waveform" : "mic.fill")
                    .symbolEffect(.variableColor.iterative, isActive: transcriber.isRecording)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(transcriber.isRecording ? 0.35 : 0.12)))
            }
            .accessibilityLabel(transcriber.isRecording ? "Stop dictation" : "Dictate")

            Button {
                if transcriber.isRecording { transcriber.stop() }
                onSend()
            } label: {
                Image(systemName: isBusy ? "hourglass" : "paperplane.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.25)))
            }
            .disabled(isBusy || text.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(minHeight: 50)
        .background(Capsule().fill(Theme.surfaceRaised))
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .onChange(of: transcriber.transcript) { _, transcript in
            if !transcript.isEmpty { text = transcript }
        }
        .task {
            if startsRecording { await transcriber.start() }
        }
    }

    /// "send a link" — e.g. an event page. Gemini reads the URL text; for full page context add the
    /// url_context tool on the server side.
    private func pasteLink() {
        guard let pasted = UIPasteboard.general.string, !pasted.isEmpty else { return }
        text = text.isEmpty ? pasted : text + " " + pasted
    }
}
