import SwiftUI

/// Where a plan card stands. Only `.pending` offers Add and Keep editing.
enum PlanCardStatus: Equatable {
    case pending
    case adding
    case added(demo: Bool)
    /// A newer revision of the same plan took its place; nil when a different plan did.
    case replaced(revision: Int?)
    case discarded

    /// Still waiting for (or in the middle of) the user's decision.
    var isOpen: Bool {
        switch self {
        case .pending, .adding: true
        case .added, .replaced, .discarded: false
        }
    }

    /// Replaced or discarded: the card folds down to its header and status.
    var isRetired: Bool {
        switch self {
        case .replaced, .discarded: true
        case .pending, .adding, .added: false
        }
    }
}

/// A long-term plan shown for review. `create_long_term_plan` only produces a draft; the series reach Google
/// Calendar when the user taps Add. Keep editing asks what to change, the assistant answers with a complete new
/// revision, and this card is then marked as replaced.
///
/// Laid out to be scanned: title and span, the one- or two-sentence summary, then the week as a table (a header
/// per phase, one row per session), the reminder and check-ins, and the assumptions folded away. Days and times
/// appear only in the table; the summary never restates them.
///
/// `.full` is the chat panel's card; `.compact` is the same card with tighter type for Quick Capture's panel.
struct PlanPreviewCard: View {
    enum Style { case full, compact }

    let draft: PlanDraft
    var status: PlanCardStatus = .pending
    var style: Style = .full
    var onAdd: () -> Void = {}
    var onKeepEditing: () -> Void = {}

    @Environment(\.locale) private var environmentLocale
    @State private var showsAssumptions = false
    /// A retired card unfolds on tap, to compare with the revision that replaced it.
    @State private var showsRetiredDetails = false

    private static let radius: CGFloat = 18
    private let clock = WallClock()

    private var isCompact: Bool { style == .compact }
    private var locale: Locale { ChatFormat.dateLocale(environmentLocale) }
    private var showsDetails: Bool { !status.isRetired || showsRetiredDetails }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 12 : 14) {
            header
            if showsDetails {
                if !draft.summary.isEmpty {
                    Text(draft.summary)
                        .font(.system(size: isCompact ? 14 : 15))
                        .lineSpacing(4)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !draft.sessions.isEmpty {
                    weeklySchedule
                }
                details
            }
            footer
        }
        .padding(isCompact ? 12 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).fill(Theme.canvas))
        .overlay(border)
        .opacity(status.isRetired ? 0.7 : 1)
        .animation(.snappy, value: status)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                if draft.revision > 1 {
                    Text("DRAFT PLAN · REVISION \(draft.revision)")
                } else {
                    Text("DRAFT PLAN")
                }
            }
            .font(.system(size: 11, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(Theme.textSecondary)

            Text(draft.title)
                .font(.system(size: isCompact ? 16 : 18, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)

            metaLine
        }
    }

    /// "Oct 14 – Apr 13 · 26 weeks · 3 phases" / "10月14日 – 4月13日 · 26 週 · 3 個階段".
    private var metaLine: some View {
        HStack(spacing: 0) {
            Text(verbatim: dayRange(draft.startDate, draft.endDate))
            Text(verbatim: " · ")
            lengthText
            if draft.phases.count > 1 {
                Text(verbatim: " · ")
                Text("\(draft.phases.count) phases")
            }
        }
        .font(.system(size: 13).monospacedDigit())
        .foregroundStyle(Theme.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .combine)
    }

    /// Weeks, rounded so an inclusive or exclusive end date reads the same; days for plans under two weeks.
    @ViewBuilder
    private var lengthText: some View {
        let days = Self.dayCount(from: draft.startDate, to: draft.endDate)
        if days == 1 {
            Text("1 day")
        } else if days < 14 {
            Text("\(days) days")
        } else {
            Text("\(Int((Double(days) / 7).rounded())) weeks")
        }
    }

    // MARK: Weekly schedule

    private var weeklySchedule: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Weekly schedule")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(phaseBlocks.enumerated()), id: \.offset) { index, block in
                    if index > 0 {
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        if let phase = block.phase {
                            phaseHeader(phase)
                        }
                        ForEach(Array(block.sessions.enumerated()), id: \.offset) { _, session in
                            PlanSessionRow(session: session, locale: locale, compact: isCompact)
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.07)))
        }
    }

    private func phaseHeader(_ phase: PlanDraft.Phase) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(phase.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(verbatim: dayRange(phase.start, phase.end))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    private struct PhaseBlock {
        /// Nil for a single-phase plan (no headers) and for sessions whose phase_index points nowhere.
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
            VStack(alignment: .leading, spacing: 8) {
                if let nudge = draft.nudge {
                    iconRow("bell") {
                        Text("Daily reminder \(ChatFormat.clockTime(hour: nudge.hour, minute: nudge.minute))")
                    }
                }
                if !draft.milestones.isEmpty {
                    iconRow("flag") { checkInText }
                }
                if !draft.assumptions.isEmpty {
                    assumptionsDisclosure
                }
            }
        }
    }

    @ViewBuilder
    private var checkInText: some View {
        let count = draft.milestones.count
        if count == 1, let only = draft.milestones.first {
            Text("Check-in on \(ReplyFormatter.shortDate(only.date, clock: clock, locale: locale))")
        } else if Self.isMonthly(draft.milestones) {
            Text("Monthly check-ins ×\(count)")
        } else {
            Text("Check-ins ×\(count)")
        }
    }

    private func iconRow<Content: View>(_ systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 18)
            content()
        }
        .font(.system(size: 14))
        .foregroundStyle(.white.opacity(0.85))
    }

    private var assumptionsDisclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { showsAssumptions.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .frame(width: 18)
                    Text("Assumptions (\(draft.assumptions.count))")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(showsAssumptions ? 180 : 0))
                }
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsAssumptions {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(draft.assumptions.enumerated()), id: \.offset) { _, assumption in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: "•")
                            Text(assumption)
                        }
                    }
                }
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 26)
                .transition(.opacity)
            }
        }
    }

    // MARK: Footer

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
                            .frame(maxWidth: .infinity, minHeight: isCompact ? 36 : 40)
                            .background(Capsule().fill(Color.white))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button(action: onKeepEditing) {
                        Text("Keep editing")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: isCompact ? 36 : 40)
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
            .frame(minHeight: isCompact ? 36 : 40)
        case let .added(demo):
            statusLine(demo ? "Added (demo)" : "Added to Google Calendar", systemImage: "checkmark.circle.fill")
        case .replaced, .discarded:
            Button {
                withAnimation(.snappy) { showsRetiredDetails.toggle() }
            } label: {
                HStack(spacing: 8) {
                    retiredStatus
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .rotationEffect(.degrees(showsRetiredDetails ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var retiredStatus: some View {
        switch status {
        case .replaced(revision: let revision?):
            statusLine("Replaced by revision \(revision)", systemImage: "arrow.triangle.2.circlepath")
        case .replaced:
            statusLine("Replaced by a newer plan", systemImage: "arrow.triangle.2.circlepath")
        default:
            statusLine("Discarded", systemImage: "xmark.circle")
        }
    }

    private func statusLine(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
    }

    /// Dashed while the plan is still a draft, like its ghost occurrences in the calendar.
    @ViewBuilder
    private var border: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        if status.isOpen {
            shape.strokeBorder(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        } else {
            shape.strokeBorder(Theme.hairline, lineWidth: 1)
        }
    }

    /// "Oct 14 – Dec 8" / "10月14日 – 12月8日" (both ends inclusive days).
    private func dayRange(_ start: Date, _ end: Date) -> String {
        ReplyFormatter.shortDate(start, clock: clock, locale: locale) + " – "
            + ReplyFormatter.shortDate(end, clock: clock, locale: locale)
    }
}

// MARK: - Formatting

extension PlanPreviewCard {
    /// Calendar days from `start` to `end`, both included.
    static func dayCount(from start: Date, to end: Date) -> Int {
        let calendar = WallClock().calendar
        let span = calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                           to: calendar.startOfDay(for: end)).day ?? 0
        return max(1, span + 1)
    }

    /// Plans add one check-in a month (prompt rule 4); spacing of three to five weeks reads as monthly.
    static func isMonthly(_ milestones: [PlanDraft.Milestone]) -> Bool {
        let dates = milestones.map(\.date).sorted()
        guard dates.count > 1, let first = dates.first, let last = dates.last else { return false }
        let averageDays = last.timeIntervalSince(first) / 86_400 / Double(dates.count - 1)
        return averageDays >= 21 && averageDays <= 38
    }
}

/// One session in the weekly table: days over the title on the left, start time over the length on the right.
private struct PlanSessionRow: View {
    let session: PlanDraft.Session
    let locale: Locale
    var compact = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                days
                    .font(.system(size: compact ? 14 : 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(session.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: session.startTime)
                    .font(.system(size: compact ? 14 : 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                Text(verbatim: ChatFormat.duration(minutes: session.durationMinutes, locale: locale))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
            }
            .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var days: some View {
        if let names = ChatFormat.weekdays(session.weekdays, locale: locale) {
            Text(verbatim: names)
        } else {
            Text("Every day")
        }
    }
}

// MARK: - Ghost occurrences

/// A pending plan's preview occurrences: dashed outline and dimmed, so they never pass for real events.
private struct DraftGhostModifier<S: Shape>: ViewModifier {
    let isDraft: Bool
    let shape: S
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if isDraft {
            content
                .overlay(shape.stroke(tint, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .opacity(0.55)
                .accessibilityHint(Text("Draft, not in your calendar yet"))
        } else {
            content
        }
    }
}

extension View {
    /// Ghost styling for `ScheduleEvent.isDraft` chips; `shape` should match the chip's own outline.
    func draftGhost<S: Shape>(_ isDraft: Bool, shape: S, tint: Color = .white) -> some View {
        modifier(DraftGhostModifier(isDraft: isDraft, shape: shape, tint: tint))
    }
}
