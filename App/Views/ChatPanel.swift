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
                // Version 1.0 has no attachments; 1.1 brings the paperclip back for photos and PDFs.
                showsAttachment: false,
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
/// Touching and holding a reply's prose, or a card that shows what the assistant wrote (a plan, added or pending
/// events, an agenda), offers Copy and Report this reply (App Review Guidelines 1.2 and 4.7.1); both take
/// `Message.reportText`, the prose, those cards and the suggestions together. VoiceOver offers the same two as
/// actions. Buttons in the cards keep working, and the suggestion chips, drawn under the cards here, have no menu. A
/// reply with nothing the assistant wrote in its cards (a learned suggestion, a settings change) has no menu on them.
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

    /// The text "Report this reply" quotes while its dialog is up (`ReplyReportDialog`).
    @State private var reportQuote: String? = nil

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
            // The prose, the cards and the chips are drawn apart, so the menu sits on the prose and on the cards
            // (when they show something the assistant wrote) but never on the chips.
            VStack(alignment: .leading, spacing: 10) {
                if !message.text.isEmpty {
                    AssistantText(text: message.text)
                        .contentShape(.interaction, Rectangle()) // the whole block, not only the glyphs
                        // One VoiceOver element for the prose, carrying Copy and Report this reply.
                        .accessibilityElement(children: .combine)
                        .replyMenu { replyMenuItems }
                }
                if let cards = Self.cards(of: message) {
                    AssistantMessageView(message: cards,
                                         showsSuggestions: showsSuggestions,
                                         compact: style == .capture,
                                         isDemo: isDemo,
                                         isBusy: isBusy,
                                         onSuggestion: onSuggestion,
                                         onConfirmDelete: onConfirmDelete,
                                         onAddPlan: onAddPlan,
                                         onKeepEditing: onKeepEditing,
                                         actions: actions)
                        // A long press on a card shows the menu; a tap still reaches its buttons. VoiceOver gets the
                        // actions on each of the cards' elements, buttons included, which keep their own action.
                        .replyMenu(message.hasReportableCards) { replyMenuItems }
                }
                if showsSuggestions && !message.suggestions.isEmpty {
                    SuggestionChips(suggestions: message.suggestions, isDisabled: isBusy, onSelect: onSuggestion)
                }
            }
            .padding(.horizontal, 4)
            .replyReportDialog(quote: $reportQuote)
        }
    }

    /// The reply without its prose and chips, for `AssistantMessageView` to draw its cards; nil when it would draw
    /// nothing, so a reply that is only text gets no empty space under it. Anything it cannot tell apart from an empty
    /// message (a field added later) counts as something to draw, so a card is never left out.
    static func cards(of message: ChatViewModel.Message) -> ChatViewModel.Message? {
        var cards = message
        cards.text = ""
        cards.suggestions = [] // drawn by the row, outside the menu
        let empty = ChatViewModel.Message(id: message.id, date: message.date, role: message.role, text: "")
        // What AssistantMessageView does not draw: a status without its card.
        var drawn = cards
        if drawn.planDraft == nil { drawn.planStatus = empty.planStatus }
        if drawn.pendingEvents == nil { drawn.pendingEventsStatus = empty.pendingEventsStatus }
        if drawn.preferenceReceipt == nil { drawn.receiptUndo = empty.receiptUndo }
        return drawn == empty ? nil : cards
    }

    /// Copy and Report this reply, on a long press and as VoiceOver actions. The text is read when one is chosen.
    @ViewBuilder
    private var replyMenuItems: some View {
        Button {
            UIPasteboard.general.string = message.reportText
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        // Like Settings › About's Contact support, hidden when the Info.plist has no address.
        if AppConstants.info("SSSupportEmail") != nil {
            Button {
                reportQuote = message.reportText
            } label: {
                Label("Report this reply", systemImage: "exclamationmark.bubble")
            }
        }
    }
}

private extension View {
    /// `items` as this view's context menu and as its VoiceOver actions; the view as it is when `isEnabled` is false,
    /// so a card with nothing to report gets no menu at all (not an empty one).
    @ViewBuilder
    func replyMenu<Items: View>(_ isEnabled: Bool = true, @ViewBuilder items: () -> Items) -> some View {
        if isEnabled {
            let menu = items()
            contextMenu { menu }
                .accessibilityActions { menu }
        } else {
            self
        }
    }
}

// MARK: - Copy and Report this reply

@MainActor
extension ChatViewModel.Message {
    /// What Copy and Report this reply take from a reply (`ReplyReport.reportText`): the prose as it reads, without
    /// the Markdown asterisks, then what its cards show that the assistant wrote: a plan's title, summary, phases (the
    /// card names them when there are several), sessions and assumptions (the reply's own when it has no plan), and
    /// the events it added, has waiting for Add or lists as an answer ("Lunch · Wed, Oct 14 · 13:00–14:00", then
    /// " · <location>" where the added and pending cards show one), and last its suggestions (the chips). The user's
    /// request is not in it. "" for a reply with none of these.
    var reportText: String {
        let clock = WallClock()
        return joinedReport(includingProse: true) { event, showsLocation in
            ReplyReport.eventLine(title: event.title, when: ReplyFormatter.when(event, clock: clock),
                                  location: showsLocation ? event.location : nil)
        }
    }

    /// The cards show something the assistant wrote. A learned suggestion, a settings change, a hidden-calendar notice
    /// or a lone Confirm button do not.
    var hasReportableCards: Bool {
        !joinedReport(includingProse: false) { event, _ in event.title }.isEmpty
    }

    /// - Parameters:
    ///   - includingProse: the prose and the suggestions, drawn outside the cards, go in too.
    ///   - eventLine: an event's line; true when its card shows the location (added and pending, not an agenda).
    private func joinedReport(includingProse: Bool, eventLine: (ScheduleEvent, Bool) -> String) -> String {
        let plan = planDraft
        let phases = plan.map { $0.phases.count > 1 ? $0.phases.map(\.name) : [] } ?? []
        let titled: (ScheduleEvent) -> Bool = { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // In the order the cards draw them; pending events as their card sorts them.
        let pending = (pendingEvents?.previewEvents ?? []).sorted { $0.start < $1.start }
        let carded: [String] = (addedEvents + pending).filter(titled).map { eventLine($0, true) }
        let listed: [String] = (agenda?.events ?? []).filter(titled).map { eventLine($0, false) }
        return ReplyReport.reportText(text: includingProse ? String(AssistantText.inline(text).characters) : "",
                                      planTitle: plan?.title,
                                      planSummary: plan?.summary,
                                      phaseNames: phases,
                                      sessionTitles: plan?.sessions.map(\.title) ?? [],
                                      // The plan card lists the plan's own assumptions.
                                      assumptions: plan?.assumptions ?? assumptions,
                                      eventTitles: carded + listed,
                                      // Only with the prose, so the chips never make a card reportable.
                                      suggestedReplies: includingProse ? suggestions : [])
    }
}

extension View {
    /// The "Report this reply" dialog while `quote` is set (`ReplyReportDialog`); setting it to "" (Settings › AI &
    /// privacy) reports without a quote.
    func replyReportDialog(quote: Binding<String?>) -> some View {
        modifier(ReplyReportDialog(quote: quote))
    }
}

/// "Report this reply" (App Review Guidelines 1.2 and 4.7.1), shared by the chat's long-press menu and Settings › AI &
/// privacy: a dialog says where the report goes, then Open Email copies the report and opens a new email to support
/// that quotes the reply (`ReplyReport.mailURL`), and Copy Report only copies it. The report is copied either way,
/// because Mail installed without an account takes the link (it opens its account setup, so `openURL` succeeds) and no
/// email is written; the in-app mail composer is not used. When no app takes the link, an alert says the report was
/// copied and where to send it, as it does after Copy Report. Without a quote (Settings › AI & privacy) the dialog is
/// "Report an AI reply" and does not mention a reply.
struct ReplyReportDialog: ViewModifier {
    /// The text to quote: `ChatViewModel.Message.reportText`, or "" when there is none (the email then asks the user to
    /// paste or describe the reply). nil when the dialog is closed; the dialog never opens without a support address.
    @Binding var quote: String?

    @Environment(\.openURL) private var openURL
    /// Kept after the alert closes, so its title does not change while it fades out.
    @State private var copied: Copied?
    @State private var showsCopied = false
    /// The last dialog had no quote; kept after it closes, so its title does not change while it fades out.
    @State private var shownUnquoted = false

    /// What the dialog acts on.
    private struct Request {
        let quote: String
        let address: String

        /// "" (or only spaces) from Settings › AI & privacy: the email asks for the reply (`ReplyReport.body`).
        var hasQuote: Bool { !ReplyReport.quoted(quote).isEmpty }
    }

    /// The alert after the report was copied.
    private struct Copied {
        let address: String
        /// Open Email found no app for the link.
        let mailFailed: Bool
    }

    private var request: Request? {
        guard let quote, let address = AppConstants.info("SSSupportEmail") else { return nil }
        return Request(quote: quote, address: address)
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(dialogTitle, isPresented: requestShown, titleVisibility: .visible,
                                presenting: request) { request in
                Button("Open Email") { openEmail(request) }
                Button("Copy Report") { copyReport(request) }
                Button("Cancel", role: .cancel) {}
            } message: { request in
                dialogMessage(request)
            }
            .alert(copiedTitle, isPresented: $showsCopied, presenting: copied) { _ in
                Button("OK", role: .cancel) {}
            } message: { copied in
                Text("The report has been copied. Paste it into an email to \(copied.address).")
            }
            .onChange(of: quote) { _, new in
                if let new { shownUnquoted = ReplyReport.quoted(new).isEmpty }
            }
    }

    private var requestShown: Binding<Bool> {
        Binding(get: { request != nil },
                set: { if !$0 { quote = nil } })
    }

    private var copiedTitle: Text {
        copied?.mailFailed == true ? Text("Couldn't open Mail") : Text("Report copied")
    }

    /// "Report this reply" from the chat; "Report an AI reply", the button's own name, from Settings › AI & privacy.
    private var dialogTitle: Text {
        let unquoted = request.map { !$0.hasQuote } ?? shownUnquoted
        return unquoted ? Text("Report an AI reply") : Text("Report this reply")
    }

    /// Where the email goes; "with the reply" only when there is one to quote.
    private func dialogMessage(_ request: Request) -> Text {
        request.hasQuote
            ? Text("This opens an email to \(request.address) with the reply. The report is also copied, so you can paste it into any email app.")
            : Text("This opens an email to \(request.address). The report is also copied, so you can paste it into any email app.")
    }

    /// The report as text, for the clipboard.
    private func plainText(_ request: Request) -> String {
        ReplyReport.plainText(reply: request.quote, appVersion: AboutView.version,
                              systemVersion: UIDevice.current.systemVersion)
    }

    /// Copies the report first, so it is on the clipboard whatever the mail app does with the link.
    private func openEmail(_ request: Request) {
        UIPasteboard.general.string = plainText(request)
        guard let url = ReplyReport.mailURL(to: request.address, reply: request.quote, appVersion: AboutView.version,
                                            systemVersion: UIDevice.current.systemVersion) else {
            showCopied(to: request.address, mailFailed: true)
            return
        }
        openURL(url) { accepted in
            if !accepted { showCopied(to: request.address, mailFailed: true) }
        }
    }

    private func copyReport(_ request: Request) {
        UIPasteboard.general.string = plainText(request)
        showCopied(to: request.address, mailFailed: false)
    }

    /// On the next turn of the main loop: the dialog's buttons and Open Email's result come while the dialog is still
    /// closing, and an alert presented then would not show.
    private func showCopied(to address: String, mailFailed: Bool) {
        DispatchQueue.main.async {
            copied = Copied(address: address, mailFailed: mailFailed)
            showsCopied = true
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
