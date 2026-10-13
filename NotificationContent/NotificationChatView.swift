import SwiftUI

/// Expanded notification body — Artboard 1 (right): header, MY TEXT bubble, THE RESPOND, input bar.
///
/// Input paths, in order of reliability:
/// 1. System text-input action ("Type in any plan to add or change") below this view — always works,
///    including on the Lock Screen; dictation comes from the keyboard's mic.
/// 2. The inline field here. Needs `UNNotificationExtensionUserInteractionEnabled = YES`; keyboard focus
///    inside content extensions has varied across iOS releases, so verify on device before relying on it.
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
            } else {
                conversation
            }
            if model.pendingDeletion != nil {
                Button("Confirm delete", role: .destructive) { model.confirmDeletion() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            inputBar
        }
        .padding(14)
        .background(Theme.canvas.opacity(0.92))
        .preferredColorScheme(.dark)
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
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.turns) { turn in
                        TurnRow(turn: turn).id(turn.id)
                    }
                }
            }
            .frame(maxHeight: 150)
            .onChange(of: model.turns) { _, turns in
                if let last = turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
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
            if model.isWorking {
                ProgressView().controlSize(.small)
            }
            Button {
                model.sendDraft()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.22)))
            }
            .disabled(model.draft.isEmpty || model.isWorking)
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(height: 40)
        .background(Capsule().fill(Theme.surfaceRaised))
    }
}

private struct TurnRow: View {
    let turn: NotificationChatModel.Turn

    var body: some View {
        switch turn.role {
        case .user:
            Text(turn.text) // "MY TEXT"
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.bubble))
        case .assistant:
            Text(turn.text) // "THE RESPOND"
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
