import Foundation
import Observation

@MainActor
@Observable
final class ScheduleViewModel {
    var events: [ScheduleEvent] = []
    var displayedMonth: Date
    var focusDay = Date()
    var isSignedIn = false
    var isRefreshing = false
    var lastError: String?

    let clock = WallClock()

    init() {
        displayedMonth = WallClock().calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
    }

    /// JUN … FEB around today (Artboard 5 month chips).
    var monthStrip: [Date] {
        let calendar = clock.calendar
        let current = calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
        return (-4...4).compactMap { calendar.date(byAdding: .month, value: $0, to: current) }
    }

    func bootstrap() async {
        isSignedIn = await GoogleTokenProvider.shared.isSignedIn
        await reloadFromCache()
        await refresh()
    }

    func reloadFromCache() async {
        events = await SharedStore.shared.snapshot().events.sorted { $0.start < $1.start }
    }

    func refresh() async {
        guard isSignedIn, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await CalendarSync(clock: clock).refreshWindow()
            await reloadFromCache()
            await ReminderScheduler.shared.reschedule()
            await LiveActivityManager.shared.refreshIfRunning()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            if let authError = error as? AuthError, case .refreshFailed = authError { isSignedIn = false }
        }
    }

    func signIn() async {
        do {
            try await GoogleSignInCoordinator().signIn()
            isSignedIn = true
            await refresh()
            try? await LiveActivityManager.shared.summon()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func events(on day: Date) -> [ScheduleEvent] {
        let calendar = clock.calendar
        let interval = DateInterval(start: calendar.startOfDay(for: day), duration: 86_400)
        return events
            .filter { $0.intersects(interval) }
            .sorted { lhs, rhs in
                // Multi-day bars first so they line up across cells, then by time.
                let lhsSpan = lhs.duration >= 86_400, rhsSpan = rhs.duration >= 86_400
                return lhsSpan != rhsSpan ? lhsSpan : lhs.start < rhs.start
            }
    }

    func focus(_ interval: DateInterval) {
        focusDay = interval.start
        displayedMonth = clock.calendar.dateInterval(of: .month, for: interval.start)?.start ?? displayedMonth
    }

    func event(id: String) -> ScheduleEvent? {
        events.first { $0.id == id }
    }
}
