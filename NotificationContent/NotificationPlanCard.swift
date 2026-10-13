import SwiftUI

/// Compact review card for a draft plan inside the expanded notification: title, dates, the summary, two session
/// lines, then Add / Keep editing. The app's `PlanPreviewCard` (App/Views) is the full version; this target does
/// not compile App/, so the compact layout is repeated here.
struct NotificationPlanCard: View {
    let draft: PlanDraft
    let status: NotificationChatModel.PlanStatus
    var onAdd: () -> Void = {}
    var onKeepEditing: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.revision > 1
                         ? String(localized: "DRAFT PLAN · REVISION \(draft.revision)")
                         : String(localized: "DRAFT PLAN"))
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textSecondary)
                Text(draft.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(dateLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            if !draft.summary.isEmpty {
                Text(draft.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
            }
            ForEach(Array(sessionLines.prefix(2).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            footer
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
        .overlay {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            if status.isOpen {
                shape.strokeBorder(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            } else {
                shape.strokeBorder(Theme.hairline, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch status {
        case .pending:
            Text("Nothing is added until you tap Add.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 8) {
                Button(action: onAdd) {
                    Text("Add")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(Capsule().fill(Color.white))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                Button(action: onKeepEditing) {
                    Text("Keep editing")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .overlay(Capsule().strokeBorder(Color.white, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        case .adding:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Adding…").font(.system(size: 12, weight: .medium))
            }
            .frame(minHeight: 32)
        case let .added(demo):
            Label(demo ? String(localized: "Added (demo)") : String(localized: "Added to Google Calendar"),
                  systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
        case .discarded:
            Label(String(localized: "Discarded"), systemImage: "xmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    /// "Oct 14 – Apr 13, 2027 · 26 weeks"
    private var dateLine: String {
        let calendar = WallClock().calendar
        let first = draft.startDate.formatted(.dateTime.month(.abbreviated).day())
        let last = draft.endDate.formatted(.dateTime.month(.abbreviated).day().year())
        let span = calendar.dateComponents([.day], from: calendar.startOfDay(for: draft.startDate),
                                           to: calendar.startOfDay(for: draft.endDate)).day ?? 0
        let days = max(1, span + 1)
        let weeks = Int((Double(days) / 7).rounded())
        let length = days < 14 ? String(localized: "\(days) days") : String(localized: "\(weeks) weeks")
        return "\(first) – \(last) · \(length)"
    }

    /// Distinct "Mon · Thu  18:30 · 60 min  Full body A" lines; phases usually repeat the same sessions.
    private var sessionLines: [String] {
        let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
        let symbols = Calendar.autoupdatingCurrent.shortWeekdaySymbols
        var seen = Set<String>()
        return draft.sessions.compactMap { session -> String? in
            let days = Set(session.weekdays.compactMap { codes.firstIndex(of: $0.uppercased()) })
                .sorted { ($0 + 6) % 7 < ($1 + 6) % 7 }
                .filter { $0 < symbols.count }
                .map { symbols[$0] }
                .joined(separator: " · ")
            let line = "\(days)  \(session.startTime) · \(session.durationMinutes) min  \(session.title)"
            return seen.insert(line).inserted ? line : nil
        }
    }
}
