import ActivityKit
import SwiftUI
import WidgetKit

/// Dynamic Island + Lock Screen presentation (Artboards 2 & 3): the event only, and under it a bar that fills up to
/// its start and stays full while it is under way (owner's choice, 2026-10-18: the bar replaced the "Up next" list).
///
/// Height budget. Apple: the expanded island and the Lock Screen view are 84–160 pt tall (408 or 371 pt wide; about
/// 412 on a 440-pt Pro Max), and anything taller is cut. Every row below has a fixed height (`IslandLayout`), so the
/// sums do not depend on fonts. Expanded island, worst case (time and place under the headline, the bar):
///
///     top row beside the camera: Edit · countdown       40   (measured on a 440-pt iPhone: ≈ 19–46)
///     headline                                          16   (center region, below the camera)
///     time · place                                      13
///     gap the system leaves before the bottom region     4   (measured)
///     spacing above the bar (`barTopPadding`)            6
///     bar (`barHeight`)                                  6
///     bottom margin (`contentMargins`)                  12
///     total                                             97   (100 if the center region starts at the measured 43)
///
/// With no bar (the ended activity's last look; no event, which has no time line either) there is no bottom region:
/// at most 40 + 16 + 13 + 12 = 81, so the island stays at its 84-pt minimum. Lock Screen (`LockScreenScheduleView`),
/// worst case:
///
///     padding                                           14
///     header: clock, headline 17 + time · place 13, countdown   32
///     spacing (`barSpacing`)                             8
///     bar (`barHeight`)                                  6
///     padding                                           14
///     total                                             74   (60 with no bar)
///
/// Corners (HIG: margins concentric with the outer edge, nothing poking into the rounded shape). The expanded content
/// keeps 16 pt from the island's sides and 12 pt from its bottom (`contentMargins`); the two capsules beside the
/// camera sit a further `cornerInset` (4) in and 2 down, and their outlines are drawn inside their frames. The
/// island's corner radius is taken as 44–52 pt (≈ 44 on 393-pt iPhones; ≈ 48 on a 440-pt Pro Max, whose island is
/// inset 14 pt from display corners of ≈ 62). The countdown capsule (56 × 22, ends of radius 11) has its end's centre
/// at (31, 32) from the island's top-right corner: 18 pt from the centre of a 44-pt corner's curve (44, 44), so
/// 18 + 11 = 29 < 44 (15 pt to spare; 13.7 at 48). The Edit capsule mirrors it on the left. The bar sits 12 pt above
/// the bottom, so it is drawn a further `barSideInset` (12) in from the side margins: its rounded end (about 3 pt)
/// is centred near (31, 15) from a bottom corner, 34.8 pt to its outer edge from a 44-pt curve's centre (9.2 to
/// spare), 40.1 at 48 (7.9), 45.5 at 52 (6.5). Across the full width between the margins (16 pt from the side) it
/// would keep 2.7 pt at 44, 1.1 at 48, and be cut at 52. Nothing on the bar can be tapped.
struct ScheduleLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScheduleActivityAttributes.self) { context in
            LockScreenScheduleView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.88))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(DeepLink.compose)
        } dynamicIsland: { context in
            DynamicIsland {
                // Beside the camera: ✎ Edit | countdown. Below it: the headline, its time and place, then the bar.
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
                    // Nothing when there is no bar (ended, or no event): the island shrinks.
                    if let bar = CountdownBar(state: context.state, isStale: context.isStale) {
                        bar
                            .padding(.horizontal, IslandLayout.barSideInset)
                            .padding(.top, IslandLayout.barTopPadding)
                    }
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
    /// The countdown bar (`CountdownBar`): its height, and the space above it in the island (on top of the gap the
    /// system leaves before the bottom region) and under the Lock Screen's header. In the island it is also inset
    /// from the side margins (`barSideInset`), so its ends stay clear of the bottom corners' curve; on the Lock
    /// Screen it runs the full width (the card's corners are ≈ 24 pt, its padding 14: about 11 pt to spare).
    static let barHeight: CGFloat = 6
    static let barTopPadding: CGFloat = 6
    static let barSideInset: CGFloat = 12
    static let barSpacing: CGFloat = 8
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

/// The bar under the headline: white on a dim track, as wide as its container (the island insets it from the bottom
/// corners, `IslandLayout.barSideInset`). It shows only the time until the start: it fills from when the activity
/// appeared to the start (`ContentState.progressRange`), and is full while the event is under way
/// (`ContentState.progressIsFull`).
/// `ProgressView(timerInterval:countsDown:)` is the only progress that moves in a Live Activity without updates from
/// the app, and only in the system's linear style (a custom `ProgressViewStyle` would be drawn once and stand
/// still), so the style is not replaced: the bar is tinted white and scaled from the system's 4 pt to `barHeight`.
/// No labels, and hidden from VoiceOver: the countdown capsule already reads the time left.
struct CountdownBar: View {
    /// The bar fills over this range; nil = full (the event is under way).
    let range: ClosedRange<Date>?

    /// The height of the system's linear bar, which the scale is worked out from.
    private static let systemBarHeight: CGFloat = 4

    /// nil = no bar: the activity's last look ("Ended"), or no event.
    init?(state: ScheduleActivityAttributes.ContentState, isStale: Bool) {
        if let range = state.progressRange(isStale: isStale) {
            self.range = range
        } else if state.progressIsFull(isStale: isStale) {
            self.range = nil
        } else {
            return nil
        }
    }

    var body: some View {
        Group {
            if let range {
                ProgressView(timerInterval: range, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                ProgressView(value: 1.0)
            }
        }
        .progressViewStyle(.linear)
        .tint(.white)
        // Dark, so the track is the system's dim light grey on the black card in light mode too.
        .environment(\.colorScheme, .dark)
        .scaleEffect(x: 1, y: IslandLayout.barHeight / Self.systemBarHeight, anchor: .center)
        .frame(maxWidth: .infinity)
        .frame(height: IslandLayout.barHeight)
        .accessibilityHidden(true)
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

/// The island's content stacked: the header row (clock glyph, headline, countdown), then the countdown bar (none
/// once ended or with no event). No Edit button (the owner's choice): a tap anywhere on the view opens Quick Capture,
/// after Face ID when locked (a Live Activity cannot take text input on the Lock Screen). The assistant's last line
/// is not shown: it is not about this event.
struct LockScreenScheduleView: View {
    let state: ScheduleActivityAttributes.ContentState
    var isStale = false
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: IslandLayout.barSpacing) {
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
            if let bar = CountdownBar(state: state, isStale: isStale) {
                bar
            }
        }
        .padding(14)
    }
}
