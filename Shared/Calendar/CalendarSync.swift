import Foundation

/// Google → device direction of the two-way sync.
///
/// Strategy: re-list a rolling window (−7 d … +120 d, recurrences expanded) and replace it in the cache.
/// Stateless and always correct, ~1–4 requests. Triggers: app foreground, BGAppRefresh, after writes,
/// and (with a backend) an `events.watch` webhook → silent push. Switch to `syncToken` incremental sync
/// (handle 410 Gone → full resync) only when windows grow past a few thousand events.
struct CalendarSync: Sendable {
    var client = GoogleCalendarClient()
    var store: SharedStore = .shared
    var clock = WallClock()

    static let pastDays = 7
    static let futureDays = 120

    func refreshWindow(now: Date = Date()) async throws {
        let calendar = clock.calendar
        let start = calendar.date(byAdding: .day, value: -Self.pastDays, to: calendar.startOfDay(for: now))!
        let end = calendar.date(byAdding: .day, value: Self.pastDays + Self.futureDays, to: start)!
        let items = try await client.list(from: start, to: end)
        let mapper = CalendarEventMapper(clock: clock)
        await store.replaceWindow(DateInterval(start: start, end: end), with: items.compactMap(mapper.scheduleEvent(from:)))
    }
}
