import SwiftUI

/// Compact copy of the app's `PendingEventsCard` (this target does not compile App/): "Ask me first" events that
/// are not in the calendar until Add. Edit focuses the inline field.
struct NotificationPendingEventsCard: View {
    let batch: PendingEventBatch
    var status: NotificationChatModel.PendingEventsStatus = .pending
    var isDemo = false
    var onAdd: () -> Void = {}
    var onEdit: () -> Void = {}

    @Environment(\.locale) private var environmentLocale
    private let clock = WallClock()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Not in your calendar yet", systemImage: "calendar.badge.clock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)

            let events = batch.previewEvents.sorted { $0.start < $1.start }
            ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                if index > 0 {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(ReplyFormatter.when(event, clock: clock,
                                             locale: NotificationFormat.dateLocale(environmentLocale)))
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.leading, 10)
                .background(alignment: .leading) {
                    Capsule().fill(Color(hex: event.colorHex)).frame(width: 3)
                }
                .accessibilityElement(children: .combine)
            }

            if !isDemo, let target = batch.targetLabel, !target.isEmpty {
                Text("Adds to \(target)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            footer
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notificationCardBackground()
        .animation(.snappy, value: status)
    }

    @ViewBuilder
    private var footer: some View {
        switch status {
        case .pending:
            VStack(alignment: .leading, spacing: 8) {
                Text("Nothing is added until you tap Add.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 8) {
                    Button(action: onAdd) {
                        Text("Add")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(Capsule().fill(Color.white))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Button(action: onEdit) {
                        Text("Edit")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .overlay(Capsule().strokeBorder(Color.white, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        case .adding:
            HStack(spacing: 6) {
                ProgressView().tint(.white).controlSize(.small)
                Text("Adding…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
            }
        case let .added(demo):
            statusLine(demo ? "Added (demo)" : "Added to Google Calendar", systemImage: "checkmark.circle.fill")
        case .discarded:
            statusLine("Discarded", systemImage: "xmark.circle")
        case .replaced:
            statusLine("Replaced by a newer version", systemImage: "arrow.triangle.2.circlepath")
        }
    }

    private func statusLine(_ text: LocalizedStringKey, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
    }
}
