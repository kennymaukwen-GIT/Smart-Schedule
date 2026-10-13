import SwiftUI

/// "Settings updated": what a lasting instruction ("from now on…", "以後…") changed, old → new, with Undo.
/// The same change is in Settings › AI & privacy › What the assistant remembers.
struct SettingsUpdatedCard: View {
    let receipt: PreferenceChangeReceipt
    var undo: ChatViewModel.ReceiptUndoState = .available
    var onUndo: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Settings updated", systemImage: "slider.horizontal.3")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)

            ForEach(Array(receipt.changes.enumerated()), id: \.offset) { index, change in
                if index > 0 {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: change.key.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(verbatim: "\(change.oldDisplay) → \(change.newDisplay)")
                        .font(.system(size: 14).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                        .strikethrough(undo == .undone, color: .white.opacity(0.5))
                }
                .accessibilityElement(children: .combine)
            }

            footer

            Text("See everything the assistant remembers in Settings › AI & privacy.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatCardBackground()
        .animation(.snappy, value: undo)
    }

    @ViewBuilder
    private var footer: some View {
        switch undo {
        case .available:
            Button(action: onUndo) {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .overlay(Capsule().strokeBorder(Color.white, lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        case .undone:
            Label("Undone", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        case .changedSince:
            Text("Changed again since. Adjust it in Settings.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
