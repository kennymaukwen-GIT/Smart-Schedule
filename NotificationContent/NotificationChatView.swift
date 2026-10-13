import SwiftUI

/// Expanded notification body — Artboard 1 (right): header, MY TEXT bubble, THE RESPOND, input bar.
///
/// Input paths, in order of reliability:
/// 1. System text-input action ("Type in any plan to add or change") below this view — always works,
///    including on the Lock Screen; dictation comes from the keyboard's mic.
/// 2. The inline field here. Needs `UNNotificationExtensionUserInteractionEnabled = YES`; keyboard focus
///    inside content extensions has varied across iOS releases, so verify on device before relying on it.
///
/// The whole conversation stays scrollable. A long-term plan arrives as a draft card inside it with Add / Keep
/// editing, and nothing is written until Add.
struct NotificationChatView: View {
    @Bindable var model: NotificationChatModel
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.turns.isEmpty {
                Text("Hold-to-reply: tell me what to add or change.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            } else {
                conversation
            }
            if model.pendingDeletion != nil {
                Button("Confirm delete", role: .destructive) { model.confirmDeletion() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            if !model.suggestions.isEmpty {
                suggestionRow
            }
            inputBar
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.canvas.opacity(0.92))
        .preferredColorScheme(.dark)
        .onChange(of: model.inputFocusRequest) {
            inputFocused = true // Keep editing: "What would you like to change?"
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            CalendarBadge()
            VStack(alignment: .leading, spacing: 2) {
                Text(model.headerTitle.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(model.headerBody.uppercased())
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private var conversation: some View {
        NotificationConversationScroll(tail: tail) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.turns) { turn in
                    NotificationTurnRow(turn: turn,
                                        isDemo: model.isDemo,
                                        onAddPlan: { model.addPlan(turn.id) },
                                        onKeepEditing: { model.keepEditing(turn.id) },
                                        onAddPendingEvents: { model.addPendingEvents(turn.id) },
                                        onEditPendingEvents: { model.editPendingEvents(turn.id) })
                        .id(turn.id)
                }
                if model.isThinking {
                    ProgressView().controlSize(.small).tint(.white)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 2)
        }
    }

    private var tail: NotificationConversationTail {
        NotificationConversationTail(lastID: model.turns.last?.id,
                                     isOwnMessage: model.turns.last?.role == .user,
                                     isTyping: model.isThinking)
    }

    private var suggestionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.suggestions, id: \.self) { suggestion in
                    Button {
                        model.send(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .overlay(Capsule().strokeBorder(Theme.hairline))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isWorking)
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Type in any plan to add or change", text: $model.draft)
                .font(.system(size: 14))
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { model.sendDraft() }
            Button {
                model.sendDraft()
            } label: {
                Image(systemName: model.isWorking ? "hourglass" : "paperplane.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.22)))
            }
            .disabled(model.draft.isEmpty || model.isWorking)
            .accessibilityLabel("Send")
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(height: 40)
        .background(Capsule().fill(Theme.surfaceRaised))
    }
}

/// The "31" calendar tile from Artboard 1.
private struct CalendarBadge: View {
    var body: some View {
        Text("\(Calendar.current.component(.day, from: Date()))")
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: "#1A73E8")))
    }
}
