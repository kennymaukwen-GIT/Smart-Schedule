import ActivityKit
import SwiftUI
import WidgetKit

/// Dynamic Island + Lock Screen presentation (Artboards 2 & 3).
///
/// Height budget: the expanded island and the Lock Screen view are capped at 160 pt by the system;
/// anything taller is clipped. Layout below ≈ 36 (header row) + 64 (week) + 36 (input) + spacing.
struct ScheduleLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScheduleActivityAttributes.self) { context in
            LockScreenScheduleView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.88))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(DeepLink.compose)
        } dynamicIsland: { context in
            DynamicIsland {
                // Header row of Artboard 3: ⏰ | Online meeting on the product quality | 21 MIN
                DynamicIslandExpandedRegion(.leading) {
                    IslandClockGlyph()
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.headline)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CountdownCapsule(state: context.state, isStale: context.isStale)
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedIslandView(state: context.state)
                }
            } compactLeading: {
                // Artboard 2 pill: "⏰ Online meeting in 21 MIN"
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    Text(context.state.shortHeadline)
                        .lineLimit(1)
                        .frame(maxWidth: 84, alignment: .leading)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
            } compactTrailing: {
                CompactCountdown(state: context.state, isStale: context.isStale)
            } minimal: {
                Image(systemName: "clock")
                    .foregroundStyle(.white)
            }
            .widgetURL(DeepLink.compose)
            .keylineTint(.white)
        }
    }
}

// MARK: - Expanded island body (Artboard 3)

/// Week micro-calendar + input pill. The "text field" is a deep-link pill: Live Activities cannot host
/// TextField or a keyboard. Tapping it opens Quick Capture (Artboard 4) with the keyboard already up.
struct ExpandedIslandView: View {
    let state: ScheduleActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 7) {
            IslandWeekStrip(state: state)
            IslandInputPill()
        }
        .padding(.top, 2)
    }
}

struct IslandWeekStrip: View {
    let state: ScheduleActivityAttributes.ContentState

    var body: some View {
        // Older payloads have no `firstWeekday`: their week started on Sunday.
        let letters = Theme.weekdayLetters(firstWeekday: state.firstWeekday ?? 1)

        HStack(alignment: .top, spacing: 2) {
            ForEach(Array(state.days.enumerated()), id: \.offset) { index, day in
                VStack(spacing: 2) {
                    Text(letters[index % 7])
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text("\(day.dayNumber)")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(index == state.todayIndex ? Color.black : Color.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(index == state.todayIndex ? Color.white : Color.clear))
                    ForEach(Array(day.chips.enumerated()), id: \.offset) { _, chip in
                        IslandChip(chip: chip)
                    }
                    if day.overflow > 0 {
                        Text("+\(day.overflow)")
                            .font(.system(size: 6, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.11), Color.white.opacity(0.03)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
    }
}

struct IslandChip: View {
    let chip: ScheduleActivityAttributes.Chip

    var body: some View {
        let tint = Color(hex: chip.colorHex)
        HStack(spacing: 1.5) {
            if chip.isTask {
                Circle().stroke(tint, lineWidth: 1).frame(width: 4, height: 4)
            } else {
                RoundedRectangle(cornerRadius: 0.5).fill(tint).frame(width: 1.5)
            }
            Text(chip.title)
                .font(.system(size: 6.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, minHeight: 9, maxHeight: 9, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 2).fill(tint.opacity(chip.isTask ? 0.0 : 0.35)))
    }
}

struct IslandInputPill: View {
    var body: some View {
        HStack(spacing: 6) {
            Link(destination: DeepLink.compose) {
                Text("Type in any plan to add or change")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Link(destination: DeepLink.composeVoice) {
                IslandRoundIcon(systemName: "mic.fill", filled: false)
            }
            Link(destination: DeepLink.compose) {
                IslandRoundIcon(systemName: "paperplane.fill", filled: true)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(height: 36)
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

struct IslandRoundIcon: View {
    let systemName: String
    let filled: Bool

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(filled ? Color.white.opacity(0.28) : Color.white.opacity(0.12)))
    }
}

struct IslandClockGlyph: View {
    var body: some View {
        Image(systemName: "clock")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
    }
}

/// "21 MIN" capsule. `Text(timerInterval:)` is the only countdown that ticks without pushes; the range always has
/// its lower bound at or before the upper. Counts to the start, then (stale once the start passes) to the end.
struct CountdownCapsule: View {
    let state: ScheduleActivityAttributes.ContentState
    var isStale = false

    var body: some View {
        Group {
            if let range = state.countdownRange(isStale: isStale) {
                Text(timerInterval: range, countsDown: true, showsHours: false)
            } else {
                Text(state.isInProgress ? "NOW" : "—")
            }
        }
        .font(.system(size: 12, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .frame(width: 56)
        .padding(.vertical, 4)
        .overlay(Capsule().stroke(Color.white, lineWidth: 1))
    }
}

struct CompactCountdown: View {
    let state: ScheduleActivityAttributes.ContentState
    var isStale = false

    var body: some View {
        Group {
            if let range = state.countdownRange(isStale: isStale) {
                Text(timerInterval: range, countsDown: true, showsHours: false)
            } else {
                Text("now")
            }
        }
        .font(.system(size: 12, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white)
        .multilineTextAlignment(.trailing)
        .frame(width: 44)
    }
}

// MARK: - Lock Screen (also shown on devices without a Dynamic Island)

struct LockScreenScheduleView: View {
    let state: ScheduleActivityAttributes.ContentState
    var isStale = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                IslandClockGlyph()
                Text(state.headline)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 4)
                CountdownCapsule(state: state, isStale: isStale)
            }
            IslandWeekStrip(state: state)
            if let line = state.lastAssistantLine {
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
    }
}
