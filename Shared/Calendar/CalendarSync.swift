import Foundation

/// Google → device direction of the two-way sync, for every calendar of every connected account.
///
/// Strategy: re-list a rolling window (−7 d … +120 d, recurrences expanded) per calendar and replace that
/// calendar's part of it in the cache. Stateless and always correct, ~1–4 requests per calendar. Triggers: app
/// foreground, BGAppRefresh, after writes, and (with a backend) an `events.watch` webhook → silent push. Switch to
/// `syncToken` incremental sync (handle 410 Gone → full resync) only when windows grow past a few thousand events.
///
/// Dates outside the window are listed on demand (`load`) when the calendars scroll there; see
/// `ScheduleViewModel.ensureEvents(covering:)`.
///
/// Failures stay per calendar: one that fails keeps its cache and coverage, an account whose refresh token stopped
/// working is marked `needsReconnect` (by `GoogleTokenProvider`) and the others keep syncing. Only "no account at
/// all" or "every calendar failed" is thrown.
struct CalendarSync: Sendable {
    var store: SharedStore = .shared
    var accounts: AccountStore = .shared
    var tokens: GoogleTokenProvider = .shared
    var clock = WallClock()
    /// Only these calendars (after adding an account, after a write); nil = every synced calendar.
    var calendars: [CalendarRef]? = nil

    static let pastDays = 7
    static let futureDays = 120
    /// Calendars listed at the same time.
    static let maxConcurrent = 4

    /// The rolling window for `now`: −7 days … +120 days from the start of today.
    static func window(now: Date, clock: WallClock) -> DateInterval {
        let calendar = clock.calendar
        let start = calendar.date(byAdding: .day, value: -pastDays, to: calendar.startOfDay(for: now))!
        let end = calendar.date(byAdding: .day, value: pastDays + futureDays, to: start)!
        return DateInterval(start: start, end: end)
    }

    func refreshWindow(now: Date = Date()) async throws {
        let window = Self.window(now: now, clock: clock)
        let mapper = CalendarEventMapper(clock: clock)
        switch try await targets() {
        case .legacy:
            let items = try await GoogleCalendarClient(tokens: tokens).list(from: window.start, to: window.end)
            await store.replaceWindow(window, with: items.compactMap(mapper.scheduleEvent(from:)))
        case let .calendars(calendars):
            try await eachCalendar(calendars) { info in
                let items = try await client(for: info).list(from: window.start, to: window.end)
                await store.replaceWindow(window, calendar: info.id,
                                          with: items.compactMap { mapper.scheduleEvent(from: $0, in: info) })
            }
        }
    }

    /// One range the calendars scrolled to (any date, years away included): each calendar lists only the parts of
    /// it that calendar has not cached, and they are merged into the cache. Leaves `windowStart` / `windowEnd` /
    /// `lastRefresh` alone: they describe the rolling window only.
    func load(_ range: DateInterval) async throws {
        let mapper = CalendarEventMapper(clock: clock)
        switch try await targets() {
        case .legacy:
            let items = try await GoogleCalendarClient(tokens: tokens).list(from: range.start, to: range.end)
            await store.mergeRange(range, with: items.compactMap(mapper.scheduleEvent(from:)))
        case let .calendars(calendars):
            try await eachCalendar(calendars) { info in
                for gap in await store.coverage(for: info.id).missing(in: range) {
                    let items = try await client(for: info).list(from: gap.start, to: gap.end)
                    await store.mergeRange(gap, calendar: info.id,
                                           with: items.compactMap { mapper.scheduleEvent(from: $0, in: info) })
                }
            }
        }
    }

    // MARK: Helpers

    private enum Targets {
        /// The single-account version's sign-in, not migrated yet: its primary calendar, cached without a calendar.
        case legacy
        case calendars([CalendarInfo])
    }

    private func targets() async throws -> Targets {
        let synced = await accounts.syncedCalendars()
        guard !synced.isEmpty else {
            if await accounts.connectedAccounts().isEmpty, tokens.hasLegacyTokens { return .legacy }
            if let account = await accounts.connectedAccounts().first(where: \.needsReconnect) {
                throw AuthError.reconnectNeeded(email: account.email)
            }
            throw AuthError.signedOut
        }
        guard let calendars else { return .calendars(synced) }
        let wanted = Set(calendars)
        return .calendars(synced.filter { wanted.contains($0.id) })
    }

    private func client(for calendar: CalendarInfo) -> GoogleCalendarClient {
        GoogleCalendarClient(accountID: calendar.accountID, calendarID: calendar.calendarID, tokens: tokens)
    }

    /// Runs `work` for every calendar, at most `maxConcurrent` at a time. Throws the first error only when every
    /// calendar failed.
    private func eachCalendar(_ calendars: [CalendarInfo],
                              _ work: @escaping @Sendable (CalendarInfo) async throws -> Void) async throws {
        guard !calendars.isEmpty else { return }
        let errors: [Error] = await withTaskGroup(of: Error?.self) { group in
            var failures: [Error] = []
            for calendar in calendars.prefix(Self.maxConcurrent) {
                group.addTask { await Self.attempt(work, calendar) }
            }
            var next = min(Self.maxConcurrent, calendars.count)
            while let result = await group.next() {
                if let result { failures.append(result) }
                if next < calendars.count {
                    let calendar = calendars[next]
                    next += 1
                    group.addTask { await Self.attempt(work, calendar) }
                }
            }
            return failures
        }
        if errors.count == calendars.count, let first = errors.first { throw first }
    }

    private static func attempt(_ work: @Sendable (CalendarInfo) async throws -> Void, _ calendar: CalendarInfo) async -> Error? {
        do {
            try await work(calendar)
            return nil
        } catch {
            return error
        }
    }
}
