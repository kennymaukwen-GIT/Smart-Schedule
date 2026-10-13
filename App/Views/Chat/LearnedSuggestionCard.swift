import SwiftUI

/// "You dismissed the “1 day before” reminder for events 5 times in a row. Stop sending it?" Smart Schedule only
/// offers; nothing changes until "Stop it".
struct LearnedSuggestionCard: View {
    let suggestion: LearnedSuggestion
    var onResolve: (_ accept: Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Suggestions", systemImage: "lightbulb")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)

            Text(verbatim: suggestion.question)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)

            switch suggestion.status {
            case .pending:
                HStack(spacing: 10) {
                    Button { onResolve(true) } label: {
                        Text("Stop it")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(Capsule().fill(Color.white))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Button { onResolve(false) } label: {
                        Text("Keep")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .overlay(Capsule().strokeBorder(Color.white, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            case .accepted:
                Label("Stopped. You can turn it back on in Settings › Notifications.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            case .declined:
                Label("OK, it stays on.", systemImage: "bell")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatCardBackground()
        .animation(.snappy, value: suggestion.status)
    }
}
