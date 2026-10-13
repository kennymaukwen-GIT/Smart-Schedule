import SwiftUI

/// Review card for a draft plan inside the expanded notification: title and span, the short summary, the week as a
/// table (a header per phase, one row per session), reminder and check-ins, assumptions folded away, then Add /
/// Keep editing. The app's `PlanPreviewCard` (App/Views) is the same layout; this target does not compile App/,
/// so it is repeated here in compact type.
struct NotificationPlanCard: View {
    let draft: PlanDraft
    let status: NotificationChatModel.PlanStatus
    var onAdd: () -> Void = {}
    var onKeepEditing: () -> Void = {}

    @Environment(\.locale) private var environmentLocale
    @State private var showsAssumptions = false
    private let clock = WallClock()

    private var locale: Locale { NotificationFormat.dateLocale(environmentLocale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            // A replaced or discarded card keeps only its header and status.
            if !status.isRetired {
                if !draft.summary.isEmpty {
                    Text(draft.summary)
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !draft.sessions.isEmpty {
                    schedule
                }
                details
            }
            footer
        }
        .padding(12)
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
        .opacity(status.isRetired ? 0.7 : 1)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Group {
                if draft.revision > 1 {
                    Text("DRAFT PLAN · REVISION \(draft.revision)")
                } else {
                    Text("DRAFT PLAN")
                }
            }
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(Theme.textSecondary)

            Text(draft.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)

            HStack(spacing: 0) {
                Text(verbatim: NotificationFormat.dayRange(draft.startDate, draft.endDate, clock: clock, locale: locale))
                Text(verbatim: " · ")
                lengthText
                if draft.phases.count > 1 {
                    Text(verbatim: " · ")
                    Text("\(draft.phases.count) phases")
                }
            }
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var lengthText: some View {
        let calendar = clock.calendar
        let span = calendar.dateComponents([.day], from: calendar.startOfDay(for: draft.startDate),
                                           to: calendar.startOfDay(for: draft.endDate)).day ?? 0
        let days = max(1, span + 1)
        if days == 1 {
            Text("1 day")
        } else if days < 14 {
            Text("\(days) days")
        } else {
            Text("\(Int((Double(days) / 7).rounded())) weeks")
        }
    }

    // MARK: Weekly schedule

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Weekly schedule")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(phaseBlocks.enumerated()), id: \.offset) { index, block in
                    if index > 0 {
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        if let phase = block.phase {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(phase.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(verbatim: NotificationFormat.dayRange(phase.start, phase.end, clock: clock, locale: locale))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                        ForEach(Array(block.sessions.enumerated()), id: \.offset) { _, session in
                            sessionRow(session)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
        }
    }

    /// Days over the title on the left, start time over the length on the right.
    private func sessionRow(_ session: PlanDraft.Session) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Group {
                    if let names = NotificationFormat.weekdays(session.weekdays, locale: locale) {
                        Text(verbatim: names)
                    } else {
                        Text("Every day")
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                Text(session.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(verbatim: session.startTime)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                Text(verbatim: NotificationFormat.duration(minutes: session.durationMinutes, locale: locale))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
            }
            .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    private struct PhaseBlock {
        var phase: PlanDraft.Phase?
        var sessions: [PlanDraft.Session]
    }

    private var phaseBlocks: [PhaseBlock] {
        guard draft.phases.count > 1 else { return [PhaseBlock(phase: nil, sessions: draft.sessions)] }
        var blocks = draft.phases.indices.compactMap { index -> PhaseBlock? in
            let sessions = draft.sessions.filter { $0.phaseIndex == index }
            return sessions.isEmpty ? nil : PhaseBlock(phase: draft.phases[index], sessions: sessions)
        }
        let unassigned = draft.sessions.filter { !draft.phases.indices.contains($0.phaseIndex) }
        if !unassigned.isEmpty { blocks.append(PhaseBlock(phase: nil, sessions: unassigned)) }
        return blocks
    }

    // MARK: Reminder, check-ins, assumptions

    @ViewBuilder
    private var details: some View {
        if draft.nudge != nil || !draft.milestones.isEmpty || !draft.assumptions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let nudge = draft.nudge {
                    iconRow("bell") {
                        Text("Daily reminder \(String(format: "%02d:%02d", nudge.hour, nudge.minute))")
                    }
                }
                if !draft.milestones.isEmpty {
                    iconRow("flag") { checkInText }
                }
                if !draft.assumptions.isEmpty {
                    Button {
                        withAnimation(.snappy) { showsAssumptions.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .frame(width: 16)
                            Text("Assumptions (\(draft.assumptions.count))")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(showsAssumptions ? 180 : 0))
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showsAssumptions {
                        ForEach(Array(draft.assumptions.enumerated()), id: \.offset) { _, assumption in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(verbatim: "•")
                                Text(assumption)
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.leading, 22)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var checkInText: some View {
        let dates = draft.milestones.map(\.date).sorted()
        if dates.count == 1, let only = dates.first {
            Text("Check-in on \(ReplyFormatter.shortDate(only, clock: clock, locale: locale))")
        } else if let first = dates.first, let last = dates.last,
                  (21...38).contains(last.timeIntervalSince(first) / 86_400 / Double(dates.count - 1)) {
            // One check-in a month (prompt rule 4).
            Text("Monthly check-ins ×\(dates.count)")
        } else {
            Text("Check-ins ×\(dates.count)")
        }
    }

    private func iconRow<Content: View>(_ systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .frame(width: 16)
            content()
        }
        .font(.system(size: 13))
        .foregroundStyle(.white.opacity(0.85))
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        switch status {
        case .pending:
            Text("Nothing is added until you tap Add.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 8) {
                Button(action: onAdd) {
                    Text("Add")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(Capsule().fill(Color.white))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                Button(action: onKeepEditing) {
                    Text("Keep editing")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .overlay(Capsule().strokeBorder(Color.white, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        case .adding:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Adding…").font(.system(size: 13, weight: .medium))
            }
            .frame(minHeight: 34)
        case let .added(demo):
            statusLine(demo ? "Added (demo)" : "Added to Google Calendar", systemImage: "checkmark.circle.fill")
        case .replaced(revision: let revision?):
            statusLine("Replaced by revision \(revision)", systemImage: "arrow.triangle.2.circlepath")
        case .replaced:
            statusLine("Replaced by a newer plan", systemImage: "arrow.triangle.2.circlepath")
        case .discarded:
            statusLine("Discarded", systemImage: "xmark.circle")
        }
    }

    private func statusLine(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
    }
}
