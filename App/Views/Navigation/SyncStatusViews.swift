import SwiftUI

// How Smart Schedule shows where it stands with Google: the drawer's status line and failed list, the header's
// indicator, and the "waiting to sync" glyph on event chips. State comes from `SyncStatus` (written by
// `SyncEngine` in any process) plus what the app knows right now (demo mode, network path, a sync under way).

/// What the drawer's status line says.
enum SyncSummary: Equatable {
    case demo
    case offline(pending: Int)
    /// The last sync failed for a reason other than the network path (Google down, timeouts).
    case unreachable
    case syncing
    case waiting(pending: Int)
    /// The oldest of the accounts' last successful syncs.
    case synced(Date)
    case notSynced

    /// `accountIDs`: the accounts whose sync counts (connected, not waiting for Reconnect).
    init(status: SyncStatus, isDemo: Bool, isNetworkOffline: Bool, isSyncing: Bool, accountIDs: [String]) {
        if isDemo || status.isDemo {
            self = .demo
        } else if status.isOffline || isNetworkOffline {
            self = .offline(pending: status.pendingCount)
        } else if isSyncing && (status.lastError != nil || status.pendingCount > 0) {
            // A retry or a flush under way; a routine tick keeps the calm "Synced" line instead.
            self = .syncing
        } else if status.lastError != nil {
            self = .unreachable
        } else if status.pendingCount > 0 {
            self = .waiting(pending: status.pendingCount)
        } else if let oldest = accountIDs.compactMap({ status.lastSuccess[$0] }).min() {
            self = .synced(oldest)
        } else {
            self = isSyncing ? .syncing : .notSynced
        }
    }

    /// A `Text` (not a `String`), so the view's locale applies: the zh-Hant previews read in Chinese too.
    func label(now: Date, clock: WallClock, locale: Locale) -> Text {
        switch self {
        case .demo:
            return Text("Demo · not synced")
        case .offline(0):
            return Text("Offline")
        case let .offline(pending):
            return Text("Offline · \(pending) changes waiting")
        case .unreachable:
            return Text("Can't reach Google · tap to retry")
        case .syncing:
            return Text("Syncing…")
        case let .waiting(pending):
            return Text("\(pending) changes waiting to sync")
        case let .synced(date):
            return Self.synced(date, now: now, clock: clock, locale: locale)
        case .notSynced:
            return Text("Not synced yet")
        }
    }

    /// "Synced · just now", "Synced · 5 min ago", "Synced · 3 h ago", then the day and 24-hour time.
    static func synced(_ date: Date, now: Date, clock: WallClock, locale: Locale) -> Text {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return Text("Synced · just now") }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return Text("Synced · \(minutes) min ago") }
        let hours = minutes / 60
        if hours < 24 { return Text("Synced · \(hours) h ago") }
        let when = ReplyFormatter.shortDate(date, clock: clock, locale: locale) + " "
            + ReplyFormatter.clockTime(date, clock: clock)
        return Text("Synced · \(when)")
    }

    var systemImage: String {
        switch self {
        case .demo: "iphone"
        case .offline: "wifi.slash"
        case .unreachable: "exclamationmark.icloud"
        case .syncing, .waiting: "arrow.triangle.2.circlepath"
        case .synced: "checkmark.icloud"
        case .notSynced: "icloud"
        }
    }

    var needsAttention: Bool {
        switch self {
        case .offline, .unreachable: true
        default: false
        }
    }

    /// Tapping syncs now; demo mode has nothing to sync and a sync is already running.
    var isTappable: Bool {
        switch self {
        case .demo, .syncing: false
        default: true
        }
    }
}

/// The drawer's status line under the accounts: "Synced · just now", "Offline · 3 changes waiting",
/// "Can't reach Google · tap to retry". `now` is the drawer's minute clock, so "5 min ago" moves on with it.
///
/// No `TimelineView` of its own: the line sits inside the drawer's List, and a time-driven view inside a List that
/// is redrawn on a timer hung the app (see `CalendarDrawer.now`).
struct SyncStatusLine: View {
    let summary: SyncSummary
    let now: Date
    var onTap: () -> Void = {}

    @Environment(\.locale) private var environmentLocale

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Group {
                    if summary == .syncing {
                        ProgressView().controlSize(.mini).tint(Theme.textSecondary)
                    } else {
                        Image(systemName: summary.systemImage)
                    }
                }
                .frame(width: 18)
                summary.label(now: now, clock: WallClock(), locale: ChatFormat.dateLocale(environmentLocale))
                    .lineLimit(2)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(summary.needsAttention ? Color.orange : Theme.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!summary.isTappable)
        .animation(.easeInOut(duration: 0.2), value: summary)
    }
}

/// A change Google refused (no permission, a bad request, the event is gone): what it was, why, Retry / Discard.
struct FailedChangeRow: View {
    let change: FailedChange
    var isRetrying = false
    var onRetry: () -> Void = {}
    var onDiscard: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: change.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if !change.summary.isEmpty {
                        Text(verbatim: change.summary)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(2)
                    }
                    if !change.reason.isEmpty {
                        Text(verbatim: change.reason)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(3)
                    }
                }
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 10) {
                Button(action: onRetry) {
                    HStack(spacing: 6) {
                        if isRetrying {
                            ProgressView().controlSize(.mini).tint(.black)
                        }
                        Text("Retry")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 30)
                    .background(Capsule().fill(Color.white))
                    .contentShape(Capsule())
                }
                .disabled(isRetrying)
                Button(action: onDiscard) {
                    Text("Discard")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 30)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .disabled(isRetrying)
            }
            .buttonStyle(.borderless) // two buttons in one List row
            .padding(.leading, 20)
        }
        .padding(.vertical, 4)
    }
}

/// The tiny mark beside the header's month: only while changes wait for Google or Google refused one.
enum SyncHeaderIndicator: Equatable {
    case pending(count: Int, offline: Bool)
    case failing(count: Int)

    init?(status: SyncStatus, failedCount: Int, isDemo: Bool, isNetworkOffline: Bool) {
        guard !isDemo, !status.isDemo else { return nil }
        if failedCount > 0 {
            self = .failing(count: failedCount)
        } else if status.pendingCount > 0 {
            self = .pending(count: status.pendingCount, offline: status.isOffline || isNetworkOffline)
        } else {
            return nil
        }
    }

    var systemImage: String {
        switch self {
        case .failing: "exclamationmark.triangle.fill"
        case .pending(_, true): "icloud.slash"
        case .pending: "arrow.triangle.2.circlepath"
        }
    }

    var accessibilityLabel: Text {
        switch self {
        case .failing: Text("Some changes couldn't sync")
        case .pending(let count, true): Text("Offline · \(count) changes waiting")
        case .pending(let count, _): Text("\(count) changes waiting to sync")
        }
    }
}

struct SyncHeaderIndicatorView: View {
    let indicator: SyncHeaderIndicator
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Image(systemName: indicator.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isFailing ? Color.orange : Theme.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(indicator.accessibilityLabel)
        .accessibilityHint(Text("Shows the sync status"))
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
    }

    private var isFailing: Bool {
        if case .failing = indicator { return true }
        return false
    }
}

// MARK: - Waiting to sync

/// A change made on this iPhone that Google has not confirmed yet (offline, or Google unreachable): a small
/// circular-arrows glyph on the event's chip.
struct PendingSyncGlyph: View {
    var size: CGFloat = 7
    var color: Color = .white.opacity(0.75)

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(color)
            .accessibilityLabel(Text("Waiting to sync"))
    }
}

// MARK: - Saved to a hidden calendar

/// "Saved to «Gym» (hidden in Smart Schedules)" with Show: a new event went to the default calendar, which this
/// iPhone hides. Google has it either way; Show makes the calendar visible here again.
struct HiddenCalendarNotice: View {
    let calendarName: String
    var onShow: () -> Void = {}

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "eye.slash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("Saved to «\(calendarName)» (hidden in Smart Schedules)")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: onShow) {
                Text("Show")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 28)
                    .background(Capsule().fill(Color.white))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatCardBackground()
    }
}

/// The notice for one chat message: shown only while that calendar is still hidden, so it goes away once shown
/// (here, from the drawer, or on another visit).
struct HiddenCalendarNoticeRow: View {
    let ref: CalendarRef

    @Environment(ScheduleViewModel.self) private var schedule: ScheduleViewModel?

    var body: some View {
        if let schedule, let calendar = schedule.calendar(ref), !calendar.isVisible {
            HiddenCalendarNotice(calendarName: calendar.displayName) {
                withAnimation(.snappy) { schedule.setVisible(true, calendar: ref) }
            }
            .transition(.opacity)
        }
    }
}
