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
}

/// A long-term plan shown for review. `create_long_term_plan` only produces a draft; the series reach Google
/// Calendar when the user taps Add. Keep editing asks what to change, the assistant answers with a complete new
/// revision, and this card is then marked as replaced.
///
/// `.full` is the chat panel's card. `.compact` fits Quick Capture's conversation panel: no phase breakdown,
/// at most two session lines.
struct PlanPreviewCard: View {
    enum Style { case full, compact }

    let draft: PlanDraft
    var status: PlanCardStatus = .pending
    var style: Style = .full
    var onAdd: () -> Void = {}
    var onKeepEditing: () -> Void = {}

    private static let radius: CGFloat = 18

    private var isCompact: Bool { style == .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 7 : 12) {
            header
            if !draft.summary.isEmpty {
                Text(draft.summary)
                    .font(.system(size: isCompact ? 12 : 14))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(isCompact ? 2 : nil)
            }
            if isCompact {
                compactSessions
            } else {
                phaseList
                details
            }
            footer
        }
        .padding(isCompact ? 12 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).fill(Theme.canvas))
        .overlay(border)
        .opacity(status.isOpen || isAdded ? 1 : 0.5)
        .animation(.snappy, value: status)
    }

    private var isAdded: Bool {
        if case .added = status { return true }
        return false
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                Text(revisionLabel)
            }
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(Theme.textSecondary)

            Text(draft.title)
                .font(.system(size: isCompact ? 15 : 17, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(isCompact ? 1 : 2)

            Text(dateLine)
                .font(.system(size: isCompact ? 11 : 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    private var revisionLabel: String {
        draft.revision > 1
            ? String(localized: "DRAFT PLAN · REVISION \(draft.revision)")
            : String(localized: "DRAFT PLAN")
    }

    /// "Oct 14 – Apr 13, 2027 · 26 weeks", plus the phase count on the compact card (it has no phase list).
    private var dateLine: String {
        var parts = [Self.dayRange(draft.startDate, draft.endDate, includeYear: true),
                     Self.lengthText(from: draft.startDate, to: draft.endDate)]
        if isCompact, draft.phases.count > 1 {
            parts.append(String(localized: "\(draft.phases.count) phases"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Phases and sessions

    private var phaseList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(draft.phases.enumerated()), id: \.offset) { index, phase in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(phase.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Self.dayRange(phase.start, phase.end))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    if let focus = phase.focus, !focus.isEmpty {
                        Text(focus)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(Array(sessions(inPhase: index).enumerated()), id: \.offset) { _, session in
                        PlanSessionLine(session: session)
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.3)).frame(width: 2)
                }
            }
            // Sessions whose phase_index points nowhere still belong on the card.
            ForEach(Array(unassignedSessions.enumerated()), id: \.offset) { _, session in
                PlanSessionLine(session: session)
            }
        }
    }

    private func sessions(inPhase index: Int) -> [PlanDraft.Session] {
        draft.sessions.filter { $0.phaseIndex == index }
    }

    private var unassignedSessions: [PlanDraft.Session] {
        draft.sessions.filter { !draft.phases.indices.contains($0.phaseIndex) }
    }

    /// Phases usually repeat the same sessions, so the compact card lists distinct ones.
    private var compactSessions: some View {
        let distinct = Self.distinctSessions(draft.sessions)
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(distinct.prefix(2).enumerated()), id: \.offset) { _, session in
                PlanSessionLine(session: session, compact: true)
            }
            if distinct.count > 2 {
                Text("+\(distinct.count - 2) more")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: Reminder, milestones, assumptions

    @ViewBuilder
    private var details: some View {
        if draft.nudge != nil || !draft.milestones.isEmpty || !draft.assumptions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let nudge = draft.nudge {
                    detailRow(String(localized: "Daily reminder at \(Self.clockTime(hour: nudge.hour, minute: nudge.minute))"),
                              systemImage: "bell")
                }
                if !draft.milestones.isEmpty {
                    detailRow(draft.milestones.count == 1
                                  ? String(localized: "1 milestone")
                                  : String(localized: "\(draft.milestones.count) milestones"),
                              systemImage: "flag")
                }
                ForEach(Array(draft.assumptions.enumerated()), id: \.offset) { _, assumption in
                    detailRow(assumption, systemImage: "info.circle", secondary: true)
                }
            }
        }
    }

    private func detailRow(_ text: String, systemImage: String, secondary: Bool = false) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemImage)
                .frame(width: 16)
        }
        .font(.system(size: secondary ? 12 : 13))
        .foregroundStyle(secondary ? Theme.textSecondary : Color.white.opacity(0.85))
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        switch status {
        case .pending:
            VStack(alignment: .leading, spacing: 8) {
                Text("Nothing is added until you tap Add.")
                    .font(.system(size: isCompact ? 10 : 11))
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 10) {
                    Button(action: onAdd) {
                        Text("Add")
                            .font(.system(size: isCompact ? 14 : 15, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: isCompact ? 34 : 40)
                            .background(Capsule().fill(Color.white))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button(action: onKeepEditing) {
                        Text("Keep editing")
                            .font(.system(size: isCompact ? 14 : 15, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: isCompact ? 34 : 40)
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
            .frame(minHeight: isCompact ? 34 : 40)
        case let .added(demo):
            statusLine(demo ? String(localized: "Added (demo)") : String(localized: "Added to Google Calendar"),
                       systemImage: "checkmark.circle.fill")
        case let .replaced(revision):
            statusLine(revision.map { String(localized: "Replaced by revision \($0)") }
                           ?? String(localized: "Replaced by a newer plan"),
                       systemImage: "arrow.triangle.2.circlepath")
        case .discarded:
            statusLine(String(localized: "Discarded"), systemImage: "xmark.circle")
        }
    }

    private func statusLine(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
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
}

// MARK: - Formatting

extension PlanPreviewCard {
    /// RFC 5545 BYDAY codes in `Calendar.shortWeekdaySymbols` order (Sunday first).
    private static let weekdayCodes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    /// `["TH", "MO"]` → "Mon · Thu" (Monday first, like a training week); all seven → "Every day".
    static func weekdayList(_ codes: [String]) -> String {
        let symbols = Calendar.autoupdatingCurrent.shortWeekdaySymbols
        let indices = Set(codes.compactMap { weekdayCodes.firstIndex(of: $0.uppercased()) })
            .sorted { ($0 + 6) % 7 < ($1 + 6) % 7 }
        if indices.count == 7 { return String(localized: "Every day") }
        return indices.filter { $0 < symbols.count }.map { symbols[$0] }.joined(separator: " · ")
    }

    /// "18:30 · 60 min"
    static func timing(of session: PlanDraft.Session) -> String {
        String(localized: "\(session.startTime) · \(session.durationMinutes) min")
    }

    /// "07:30", matching the 24-hour session times.
    static func clockTime(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    /// "Oct 14 – Dec 8" (both ends inclusive days).
    static func dayRange(_ start: Date, _ end: Date, includeYear: Bool = false) -> String {
        let first = start.formatted(.dateTime.month(.abbreviated).day())
        let last = includeYear
            ? end.formatted(.dateTime.month(.abbreviated).day().year())
            : end.formatted(.dateTime.month(.abbreviated).day())
        return "\(first) – \(last)"
    }

    /// "26 weeks" (rounded, so an inclusive or exclusive end date reads the same), or days for short plans.
    static func lengthText(from start: Date, to end: Date) -> String {
        let calendar = WallClock().calendar
        let span = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
        let days = max(1, span + 1)
        if days < 14 {
            return days == 1 ? String(localized: "1 day") : String(localized: "\(days) days")
        }
        let weeks = Int((Double(days) / 7).rounded())
        return String(localized: "\(weeks) weeks")
    }

    static func distinctSessions(_ sessions: [PlanDraft.Session]) -> [PlanDraft.Session] {
        var seen = Set<String>()
        return sessions.filter { session in
            let key = [session.weekdays.joined(separator: ","), session.startTime,
                       String(session.durationMinutes), session.title].joined(separator: "|")
            return seen.insert(key).inserted
        }
    }

    /// The reply text without the plan's summary, which the card already shows (nil when nothing is left).
    static func leadText(_ text: String, summary: String) -> String? {
        var rest = text
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty, let range = rest.range(of: summary) {
            rest.removeSubrange(range)
        }
        rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }
}

/// "Mon · Thu  18:30 · 60 min  Full body A". The title gives way first when the line is tight.
private struct PlanSessionLine: View {
    let session: PlanDraft.Session
    var compact = false

    var body: some View {
        let size: CGFloat = compact ? 11 : 12
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(PlanPreviewCard.weekdayList(session.weekdays))
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
            Text(PlanPreviewCard.timing(of: session))
                .font(.system(size: size).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            Text(session.title)
                .font(.system(size: size))
                .foregroundStyle(.white.opacity(0.9))
                .layoutPriority(-1)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
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
