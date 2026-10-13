import SwiftUI

// Pieces shared by the endless calendars: Quick Capture's DAY, WEEK and MONTH and the main view's month pages.
//
// Each pager is a lazy stack over `CalendarPaging.dayPages` / `weekPages` / `monthPages` (a century each way),
// identified by offsets from an anchor date it keeps in @State. Pages are all the same size, so the scroll view
// can place any offset without building the ones in between, and a jump far beyond that re-anchors instead.

/// "Today" capsule: shown while a calendar's range leaves out today, tapping it brings today back.
struct TodayPill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Today")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.black)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white))
                .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The Today pill and a small spinner while events for an on-demand range load, side by side.
struct CalendarStatusAccessory: View {
    var showsToday: Bool
    var isLoading: Bool
    var onToday: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
                    .accessibilityLabel(Text("Loading events"))
                    .transition(.opacity)
            }
            if showsToday {
                TodayPill(action: onToday)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .animation(.snappy, value: showsToday)
        .animation(.easeInOut(duration: 0.2), value: isLoading)
    }
}

enum PagerScroll {
    /// Pages within `nearby` slide there. A farther target is reached by jumping to its neighbour first and
    /// sliding the last page, so the animation never has to draw every page in between.
    @MainActor
    static func move(_ position: Binding<Int?>, to target: Int, nearby: Int = 2) {
        guard let current = position.wrappedValue, abs(target - current) > nearby else {
            withAnimation(.snappy) { position.wrappedValue = target }
            return
        }
        position.wrappedValue = target + (target > current ? -1 : 1)
        // A few frames later, so the jump is drawn on its own instead of merging into one long animated scroll.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            withAnimation(.snappy) { position.wrappedValue = target }
        }
    }
}
