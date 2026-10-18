import ActivityKit
import SwiftUI
import WidgetKit

/// Dynamic Island + Lock Screen presentation (Artboards 2 & 3).
///
/// Height budget. Apple: the expanded island and the Lock Screen view are 84–160 pt tall (408 or 371 pt wide; about
/// 412 on a 440-pt Pro Max), and anything taller is cut. Every row below has a fixed height (`IslandLayout`), so the
/// sums do not depend on fonts. Expanded island, worst case (time and place under the headline, "Up next" with three
/// rows):
///
///     top row beside the camera: Edit · countdown       40   (measured on a 440-pt iPhone: ≈ 19–46)
///     headline                                          16   (center region, below the camera)
///     time · place                                      13
///     gap the system leaves before the bottom region     4   (measured)
///     "Up next" label, "+N" on the right                12
///     spacing                                            2
///     3 rows × 16                                       48
///     bottom margin (`contentMargins`)                  12
///     total                                            147   (150 if the center region starts at the measured 43)
///
/// One row less per missing line: "Nothing else today" alone is 13 (total 98), and with no event there is no bottom
/// region at all (the island shrinks to its 84-pt minimum). Lock Screen (`LockScreenScheduleView`), worst case:
///
///     padding                                           14
///     header: clock, headline 17 + time · place 13, countdown   32
///     spacing                                            8
///     "Up next": 12 + 2 + 3 × 16                        62
///     padding                                           14
///     total                                            130
///
/// Corners (HIG: margins concentric with the outer edge, nothing poking into the rounded shape). The expanded content
/// keeps 16 pt from the island's sides and 12 pt from its bottom (`contentMargins`); the two capsules beside the
/// camera sit a further `cornerInset` (4) in and 2 down, and their outlines are drawn inside their frames. With the
/// island's corner radius taken as ≈ 44 pt, the countdown capsule (56 × 22, ends of radius 11) has its end's centre
/// at (31, 32) from the island's top-right corner, 18 pt from the centre of the corner's curve (44, 44): 18 + 11 = 29
/// < 44, inside with 15 pt to spare (the Edit capsule mirrors it on the left). The last row's outer corner, at
/// (16, 12) from a bottom corner, is 42.5 pt from that curve's centre: inside too. The old full-width Edit capsule
/// (30 tall, ends of radius 15, 15 pt above the bottom, almost at the sides) reached 47 pt: cut, as in the screenshot.
struct ScheduleLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScheduleActivityAttributes.self) { context in
            LockScreenScheduleView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.88))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(DeepLink.compose)
        } dynamicIsland: { context in
            DynamicIsland {
                // Beside the camera: ✎ Edit | countdown. Below it: the headline, its time and place, then "Up next".
                DynamicIslandExpandedRegion(.leading) {
                    IslandEditPill()
                        .padding(.leading, IslandLayout.cornerInset)
                        .padding(.top, IslandLayout.cornerInsetTop)
                }
                DynamicIslandExpandedRegion(.center) {
                    IslandHeadline(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CountdownCapsule(state: context.state, isStale: context.isStale)
                        .padding(.trailing, IslandLayout.cornerInset)
                        .padding(.top, IslandLayout.cornerInsetTop)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    UpNextList(state: context.state)
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
            // A tap anywhere else on the island opens Quick Capture too.
            .widgetURL(DeepLink.compose)
            .keylineTint(.white)
            .contentMargins(.horizontal, IslandLayout.sideMargin, for: .expanded)
            .contentMargins(.bottom, IslandLayout.bottomMargin, for: .expanded)
        }
    }
}

/// The fixed sizes the height budget above adds up.
enum IslandLayout {
    /// Expanded island: content inset from its sides and bottom (`DynamicIsland.contentMargins`).
    static let sideMargin: CGFloat = 16
    static let bottomMargin: CGFloat = 12
    /// The Edit and countdown capsules, which sit where the island's top corners curve: a further inset from the
    /// side and the top, so their own rounded ends stay concentric with the island's corners.
    static let cornerInset: CGFloat = 4
    static let cornerInsetTop: CGFloat = 2
    static let capsuleHeight: CGFloat = 22
    static let headlineHeight: CGFloat = 16
    static let detailHeight: CGFloat = 13
    static let labelHeight: CGFloat = 12
    static let rowHeight: CGFloat = 16
    static let labelSpacing: CGFloat = 2
    /// Lock Screen: the header row (clock glyph, headline and its time and place, countdown).
    static let lockScreenHeaderHeight: CGFloat = 32
    static let lockScreenHeadlineHeight: CGFloat = 17
}

// MARK: - Expanded island (Artboard 3)

/// "✎ Edit" (zh-Hant 「編輯」 from the String Catalog) beside the camera, the island's only control. Live Activities
/// cannot host a TextField or a keyboard, so it is a `Link` to `DeepLink.compose`: Quick Capture (Artboard 4) opens
/// with the keyboard already up.
struct IslandEditPill: View {
    var body: some View {
        Link(destination: DeepLink.compose) {
            HStack(spacing: 3) {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
                Text("Edit")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(height: IslandLayout.capsuleHeight)
            .background(Capsule().fill(Color.white.opacity(0.16)))
        }
    }
}

/// The headline and, under it, the event's time and place ("08:15–08:45 · Riverside Primary School"), formatted
/// here so they follow the iPhone's 12/24-hour setting. "Nothing next" has no second line.
struct IslandHeadline: View {
    let state: ScheduleActivityAttributes.ContentState
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            Text(state.headline)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(height: IslandLayout.headlineHeight)
            if let detail = state.detailLine(locale: locale) {
                Text(verbatim: detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .frame(height: IslandLayout.detailHeight)
            }
        }
    }
}

/// What comes after the event: "Up next" ("+N" on the right when the day has more), then up to three rows of
/// start time, a coloured bar (a ring for a task) and title. From the next day it is one row, "Tomorrow 09:00". With
/// nothing after the event that day or the next: "Nothing else today". Nothing at all when there is no event (or
/// an older payload has no list). Rows, not a filled box, so nothing pokes into the island's rounded corners.
struct UpNextList: View {
    let state: ScheduleActivityAttributes.ContentState
    @Environment(\.locale) private var locale

    var body: some View {
        if state.eventID != nil, let items = state.upNext {
            VStack(alignment: .leading, spacing: IslandLayout.labelSpacing) {
                if items.isEmpty {
                    Text("Nothing else today")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .frame(height: IslandLayout.detailHeight)
                } else {
                    HStack(spacing: 4) {
                        Text("Up next")
                        Spacer(minLength: 4)
                        if let more = state.upNextMore, more > 0 {
                            Text("+\(more)")
                        }
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .frame(height: IslandLayout.labelHeight)

                    let style = state.timeStyle(locale: locale)
                    Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 0) {
                        ForEach(Array(items.prefix(LiveActivityStateBuilder.upNextLimit).enumerated()), id: \.offset) { _, item in
                            GridRow {
                                UpNextTime(item: item, style: style)
                                UpNextMarker(item: item)
                                Text(item.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .frame(height: IslandLayout.rowHeight)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct UpNextTime: View {
    let item: ScheduleActivityAttributes.UpNextItem
    let style: Date.FormatStyle

    var body: some View {
        Group {
            if item.isTomorrow {
                Text("Tomorrow \(item.start, format: style)")
            } else {
                Text(item.start, format: style)
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(Theme.textSecondary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: IslandLayout.rowHeight)
    }
}

/// The 2-pt bar of the event's colour, or a ring for a task (as the week strip's chips had).
struct UpNextMarker: View {
    let item: ScheduleActivityAttributes.UpNextItem

    var body: some View {
        let tint = Color(hex: item.colorHex)
        Group {
            if item.isTask {
                Circle().strokeBorder(tint, lineWidth: 1.5).frame(width: 7, height: 7)
            } else {
                RoundedRectangle(cornerRadius: 1).fill(tint).frame(width: 2, height: 11)
            }
        }
        .frame(width: 7, height: IslandLayout.rowHeight)
    }
}

/// The Lock Screen header's clock (owner's choice, 2026-10-18: no Edit pill on the Lock Screen).
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
/// its lower bound at or before the upper. Counts to the start, then (stale once the start passes) to the end. The
/// outline is drawn inside the capsule's frame (`strokeBorder`), so no part of it falls outside the region. An ended
/// activity's last look (`hasEnded`) reads "Ended" (zh-Hant 「已結束」) rather than a dash.
struct CountdownCapsule: View {
    let state: ScheduleActivityAttributes.ContentState
    var isStale = false

    var body: some View {
        Group {
            if let range = state.countdownRange(isStale: isStale) {
                Text(timerInterval: range, countsDown: true, showsHours: false)
            } else if state.hasEnded == true {
                Text("Ended")
            } else {
                Text(state.isInProgress ? "NOW" : "—")
            }
        }
        .font(.system(size: 12, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .lineLimit(1)
        .frame(width: 56, height: IslandLayout.capsuleHeight)
        .overlay(Capsule().strokeBorder(Color.white, lineWidth: 1))
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

/// The island's content stacked: the header row (clock glyph, headline, countdown), then "Up next". No Edit button
/// (the owner's choice): a tap anywhere on the view opens Quick Capture, after Face ID when locked (a Live Activity
/// cannot take text input on the Lock Screen). The assistant's last line is no longer shown: with it (8 spacing + a
/// 13-pt line) the view would be ≈ 151 pt, over the 150-pt budget, and it is not about this event.
struct LockScreenScheduleView: View {
    let state: ScheduleActivityAttributes.ContentState
    var isStale = false
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                IslandClockGlyph()
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.headline)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(height: IslandLayout.lockScreenHeadlineHeight)
                    if let detail = state.detailLine(locale: locale) {
                        Text(verbatim: detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .frame(height: IslandLayout.detailHeight)
                    }
                }
                Spacer(minLength: 4)
                CountdownCapsule(state: state, isStale: isStale)
            }
            .frame(height: IslandLayout.lockScreenHeaderHeight)
            UpNextList(state: state)
        }
        .padding(14)
    }
}
