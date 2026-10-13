import SwiftUI

/// "Ask me first": single events the assistant prepared, not in the calendar until Add. Edit asks what to change;
/// the next version replaces this card. The events show as ghosts in the calendars meanwhile.
struct PendingEventsCard: View {
    let batch: PendingEventBatch
    var status: ChatViewModel.PendingEventsStatus = .pending
    var isDemo = false
    var compact = false
    var onAdd: () -> Void = {}
    var onEdit: () -> Void = {}

    @Environment(\.locale) private var environmentLocale
    private let clock = WallClock()

    private var events: [ScheduleEvent] { batch.previewEvents.sorted { $0.start < $1.start } }
    private var isRetired: Bool { status == .discarded || status == .replaced }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Not in your calendar yet", systemImage: "calendar.badge.clock")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)

            ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                if index > 0 {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                row(event)
            }

            if !isDemo, let target = batch.targetLabel, !target.isEmpty {
                Text("Adds to \(target)")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }

            footer
        }
        .padding(compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.canvas))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(status.isOpen ? 0.7 : 0.25),
                              style: StrokeStyle(lineWidth: 1, dash: status.isOpen ? [5, 4] : []))
        )
        .opacity(isRetired ? 0.7 : 1)
        .animation(.snappy, value: status)
    }

    private func row(_ event: ScheduleEvent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(event.title)
                .font(.system(size: compact ? 15 : 16, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Text(ReplyFormatter.when(event, clock: clock, locale: ChatFormat.dateLocale(environmentLocale)))
                .font(.system(size: 14).monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
            if let location = event.location, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 11)
        .background(alignment: .leading) {
            Capsule().fill(Color(hex: event.colorHex)).frame(width: 3)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var footer: some View {
        switch status {
        case .pending:
            VStack(alignment: .leading, spacing: 10) {
                Text("Nothing is added until you tap Add.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 10) {
                    Button(action: onAdd) {
                        Text("Add")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: compact ? 36 : 40)
                            .background(Capsule().fill(Color.white))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Button(action: onEdit) {
                        Text("Edit")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: compact ? 36 : 40)
                            .overlay(Capsule().strokeBorder(Color.white, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        case .adding:
            HStack(spacing: 8) {
                ProgressView().tint(.white).controlSize(.small)
                Text("Adding…")
                    .font(.system(size: 13, weight: .medium))
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
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
    }
}
