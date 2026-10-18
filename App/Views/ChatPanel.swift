import SwiftUI
import UIKit

/// Bottom half of Artboard 5: conversation with the scheduling agent.
struct ChatPanel: View {
    /// False while Quick Capture is on top: its own field answers Keep editing, not this one behind it.
    var takesFocusRequests = true

    @Environment(ChatViewModel.self) private var chat
    @Environment(ScheduleViewModel.self) private var schedule
    @Environment(AppRouter.self) private var router
    @FocusState private var inputFocused: Bool

    var body: some View {
        @Bindable var chat = chat

        VStack(spacing: 10) {
            if !schedule.isSignedIn && !schedule.isDemo {
                // Welcome: connect (the add page), or look around with sample data (App Review guideline 2.1).
                Button {
                    router.openSheet(.addAccount)
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
                    Label("Try without signing in", systemImage: "sparkles")
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

            ConversationScrollView(tail: chat.conversationTail,
                                   revealRequest: chat.planRevealRequest,
                                   revealID: chat.openPlanMessageID) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(chat.messages) { message in
                        ChatMessageRow(message: message,
                                       showsSuggestions: message.id == chat.latestReply?.id,
                                       isDemo: schedule.isDemo,
                                       isBusy: chat.isBusy,
                                       onSuggestion: { chat.send($0) },
                                       onConfirmDelete: { chat.confirmDeletion(in: message) },
                                       onAddPlan: { chat.addPlan(message) },
                                       onKeepEditing: { chat.keepEditing(message) },
                                       actions: ChatCardActions(message: message, chat: chat))
                            .id(message.id)
                    }
                    if chat.isSending {
                        ProgressView().tint(.white).padding(.leading, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }

            if chat.showsConsentBanner {
                ConsentBanner { chat.reviewConsent() }
            } else if chat.showsDemoOfflineBanner {
                ConsentBanner(message: "Demo mode is using offline rules. Allow AI data sharing to try the real assistant.") {
                    chat.reviewConsent()
                }
            }

            ComposerBar(
                text: $chat.draft,
                placeholder: "Type your schedule, event, aim, or plan, or send a link with a date and time",
                showsAttachment: true,
                isBusy: chat.isBusy,
                focus: $inputFocused,
                // Quick Capture, the drawer or a sheet over the chat: its mic stops.
                isCovered: router.quickCapture != nil || router.coversQuickCapture(schedule)
                    || chat.consentRequest != nil,
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
                    .background(Capsule().fill(Theme.demoBadge))
            }
            Text("Sample data · not your Google Calendar")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }
}

/// One message in the chat panel or Quick Capture: the user's line as a bubble, a reply as `AssistantMessageView`.
struct ChatMessageRow: View {
    enum Style {
        /// Chat panel (Artboard 5): wide graphite bubbles.
        case panel
        /// Quick Capture: the user's lines as trailing bubbles, the compact plan card.
        case capture
    }

    let message: ChatViewModel.Message
    var style: Style = .panel
    var showsSuggestions = false
    var isDemo = false
    var isBusy = false
    var onSuggestion: (String) -> Void = { _ in }
    var onConfirmDelete: () -> Void = {}
    var onAddPlan: () -> Void = {}
    var onKeepEditing: () -> Void = {}
    var actions = ChatCardActions()

    var body: some View {
        switch message.role {
        case .user:
            switch style {
            case .panel:
                // Artboard 5: wide graphite bubble, left-aligned text.
                Text(message.text)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.bubble))
            case .capture:
                Text(message.text)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.bubble))
                    .padding(.leading, 36)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        case .assistant:
            AssistantMessageView(message: message,
                                 showsSuggestions: showsSuggestions,
                                 compact: style == .capture,
                                 isDemo: isDemo,
                                 isBusy: isBusy,
                                 onSuggestion: onSuggestion,
                                 onConfirmDelete: onConfirmDelete,
                                 onAddPlan: onAddPlan,
                                 onKeepEditing: onKeepEditing,
                                 actions: actions)
                .padding(.horizontal, 4)
        }
    }
}

/// Shared input bar (Artboards 2–5): optional paperclip, field, mic, send. The mic (`VoiceTranscriber`) turns speech
/// into text on this iPhone and shows only when the chosen language can be recognised on the device; the keyboard's
/// dictation works either way. Its words fill the field; nothing is sent until Send.
struct ComposerBar: View {
    @Binding var text: String
    var placeholder: LocalizedStringKey
    var showsAttachment = false
    var isBusy = false
    var focus: FocusState<Bool>.Binding
    /// `smartschedule://compose?mode=voice` (`AppRouter.QuickCapture.id`, new for every link): start the mic when that
    /// needs no permission prompt; otherwise the keyboard comes up.
    var voiceRequest: UUID?
    /// Something covers this composer (Quick Capture over the main chat, the drawer, a sheet): a recording stops,
    /// keeping the words heard so far, and a voice request does not start one, so the mic never listens out of sight.
    var isCovered = false
    var onSend: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var transcriber = VoiceTranscriber()

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
                .onSubmit(send)

            if transcriber.isAvailable || transcriber.isRecording {
                Button {
                    Task { await transcriber.toggle(typed: text) }
                } label: {
                    Image(systemName: transcriber.isRecording ? "waveform" : "mic.fill")
                        .symbolEffect(.variableColor.iterative, isActive: transcriber.isRecording)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.white.opacity(transcriber.isRecording ? 0.35 : 0.12)))
                }
                .accessibilityLabel(transcriber.isRecording ? "Stop dictation" : "Dictate")
            }

            Button(action: send) {
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
        .onChange(of: transcriber.fieldText) { _, words in
            if let words { text = words }
        }
        // The field was cleared (Send here or in the other composer, a suggestion, Clear chat history, by hand): the
        // recording ends and words still on their way are dropped, so they can't refill it.
        .onChange(of: text) { old, new in
            if new.isEmpty, !old.isEmpty { transcriber.cancel() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                transcriber.refreshAvailability()
            } else {
                transcriber.stop()
            }
        }
        .onChange(of: isCovered) { _, covered in
            if covered { transcriber.stop() }
        }
        .task(id: voiceRequest) {
            transcriber.refreshAvailability()
            guard voiceRequest != nil else { return }
            if isCovered {
                focus.wrappedValue = true
            } else if !(await transcriber.startIfAllowed(typed: text)) {
                focus.wrappedValue = true
            }
        }
        .onDisappear { transcriber.cancel() }
        .alert("Voice input", isPresented: problemShown, presenting: transcriber.problem) { problem in
            if problem.opensSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { problem in
            Text(verbatim: problem.message ?? "")
        }
    }

    /// Send ends a recording first; words still on their way are dropped, so they can't refill the cleared field.
    private func send() {
        transcriber.cancel()
        onSend()
    }

    private var problemShown: Binding<Bool> {
        Binding(get: { transcriber.problem != nil },
                set: { if !$0 { transcriber.problem = nil } })
    }

    /// "send a link" — e.g. an event page. Gemini reads the URL text; for full page context add the
    /// url_context tool on the server side.
    private func pasteLink() {
        guard let pasted = UIPasteboard.general.string, !pasted.isEmpty else { return }
        text = text.isEmpty ? pasted : text + " " + pasted
    }
}
