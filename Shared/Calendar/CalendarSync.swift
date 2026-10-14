import Foundation

/// Google → device direction of the two-way sync, for every calendar of every connected account.
///
/// Two passes (docs/GOOGLE_CALENDAR_SYNC.md §10):
/// - **Full listing** (`refreshWindow`): re-list the rolling window (−7 d … +120 d, recurrences expanded) per
///   calendar and replace that calendar's part of it in the cache. Stateless and always correct; the periodic truth.
/// - **Changed since** (`pull`): `events.list` with `updatedMin` + `showDeleted` over what the calendar has cached,
///   usually one small request; cancelled entries remove their copy. Falls back to the full listing when the last
///   one is older than the caller allows, Google answers 410, or there are too many changes.
/// `syncToken` is not used: it cannot be combined with `timeMin` / `timeMax`, while the cache only ever holds a
/// window and the ranges on screen.
///
/// Dates outside the window are listed on demand (`load`) when the calendars scroll there; see
/// `ScheduleViewModel.ensureEvents(covering:)`. After every listing the outbox's waiting changes are drawn on top
/// again, so a change made offline never flickers back to Google's older version.
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
    /// nil: the network with `tokens`. Unit tests pass a stand-in.
    var transport: (any CalendarTransport)? = nil
    /// Its waiting changes are drawn over every listing.
    var outbox: SyncOutbox = .shared
    /// Not drawn: changes Google just confirmed that leave the outbox once this listing is done.
    var skippingOutboxItems: Set<UUID> = []

    static let pastDays = 7
    static let futureDays = 120
    /// Calendars listed at the same time.
    static let maxConcurrent = 4
    /// A "changed since" pass this far behind is not trusted; the window is listed in full instead.
    static let maxChangesAge: TimeInterval = 7 * 86_400
    /// Each pass starts this long before Google's clock at the previous one, so no change falls between two passes.
    static let changesOverlap: TimeInterval = 60
    /// More pages of changes than this: listing the window in full is cheaper.
    static let maxChangePages = 2
    /// The single-account sign-in before its migration, in pull results and outbox items.
    static let legacyCalendar = CalendarRef(accountID: "", calendarID: "primary")

    /// One calendar's outcome in `pull`.
    struct PullResult: Sendable {
        var calendar: CalendarRef
        var failure: CalendarFailure?
        var message: String?
    }

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
            let items = try await legacyClient.list(from: window.start, to: window.end)
            await store.replaceWindow(window, with: items.compactMap(mapper.scheduleEvent(from:)))
            await drawPending(mapper: mapper, horizon: window.end)
        case let .calendars(calendars):
            try await eachCalendar(calendars) { info in
                try await listWindow(info, window: window, mapper: mapper)
            }
        }
    }

    /// One range the calendars scrolled to (any date, years away included): each calendar lists only the parts of
    /// it that calendar has not cached, and they are merged into the cache. Leaves `windowStart` / `windowEnd` /
    /// `lastRefresh` alone: they describe the rolling window only.
    func load(_ range: DateInterval) async throws {
        let mapper = CalendarEventMapper(clock: clock)
        let horizon = Self.window(now: Date(), clock: clock).end
        switch try await targets() {
        case .legacy:
            let items = try await legacyClient.list(from: range.start, to: range.end)
            await store.mergeRange(range, with: items.compactMap(mapper.scheduleEvent(from:)))
            await drawPending(mapper: mapper, horizon: horizon)
        case let .calendars(calendars):
            try await eachCalendar(calendars) { info in
                for gap in await store.coverage(for: info.id).missing(in: range) {
                    let items = try await client(for: info).list(from: gap.start, to: gap.end)
                    await store.mergeRange(gap, calendar: info.id,
                                           with: items.compactMap { mapper.scheduleEvent(from: $0, in: info) })
                }
                await drawPending(mapper: mapper, horizon: horizon)
            }
        }
    }

    /// `SyncEngine`'s pull. Per calendar: a "changed since" pass over everything it has cached when its last full
    /// listing is younger than `staleAfter`; otherwise (or when Google answers 410, or there are more than
    /// `maxChangePages` pages of changes) the full rolling window. `staleAfter <= 0` always lists in full.
    /// Never throws for one calendar: each one's failure is in its result.
    func pull(staleAfter: TimeInterval, now: Date = Date()) async throws -> [PullResult] {
        let window = Self.window(now: now, clock: clock)
        let mapper = CalendarEventMapper(clock: clock)
        switch try await targets() {
        case .legacy:
            do {
                try await refreshWindow(now: now)
                return [PullResult(calendar: Self.legacyCalendar)]
            } catch {
                return [PullResult(calendar: Self.legacyCalendar, failure: CalendarFailure.of(error), message: error.localizedDescription)]
            }
        case let .calendars(calendars):
            return await eachCalendarResult(calendars) { info in
                try await pullCalendar(info, window: window, staleAfter: staleAfter, now: now, mapper: mapper,
                                       known: calendars)
            }
        }
    }

    // MARK: Passes

    /// The full listing of one calendar's rolling window.
    private func listWindow(_ info: CalendarInfo, window: DateInterval, mapper: CalendarEventMapper) async throws {
        let started = Date()
        let listing = try await client(for: info).listing(from: window.start, to: window.end)
        await store.replaceWindow(window, calendar: info.id,
                                  with: listing.items.compactMap { mapper.scheduleEvent(from: $0, in: info) },
                                  listedAt: (listing.serverDate ?? started).addingTimeInterval(-Self.changesOverlap))
        await drawPending(mapper: mapper, horizon: window.end)
    }

    private func pullCalendar(_ info: CalendarInfo, window: DateInterval, staleAfter: TimeInterval, now: Date,
                              mapper: CalendarEventMapper, known: [CalendarInfo]) async throws {
        let mark = await store.syncMark(for: info.id)
        let coverage = await store.coverage(for: info.id)
        guard staleAfter > 0, !coverage.isEmpty,
              let fullListAt = mark?.fullListAt, now.timeIntervalSince(fullListAt) < staleAfter,
              let since = mark?.changesSince, now.timeIntervalSince(since) < Self.maxChangesAge else {
            try await listWindow(info, window: window, mapper: mapper)
            return
        }
        let started = Date()
        var changes: [GCalEvent] = []
        var serverDate: Date?
        do {
            for range in coverage.intervals {
                let listing = try await client(for: info).listing(from: range.start, to: range.end, updatedMin: since,
                                                                  maxPages: Self.maxChangePages)
                if listing.isTruncated {
                    try await listWindow(info, window: window, mapper: mapper)
                    return
                }
                changes += listing.items
                if serverDate == nil { serverDate = listing.serverDate }
            }
        } catch let error as CalendarAPIError where error.status == 410 {
            // updatedMinTooLongAgo: Google no longer has changes that far back.
            try await listWindow(info, window: window, mapper: mapper)
            return
        }
        let cached = await store.snapshot().events
        if IncrementalChanges.reshapesSeries(changes, calendar: info.id, cached: cached) {
            try await listWindow(info, window: window, mapper: mapper)
            return
        }
        await store.applyChanges(changes, calendar: info.id, known: known, mapper: mapper,
                                 changesSince: (serverDate ?? started).addingTimeInterval(-Self.changesOverlap))
        await drawPending(mapper: mapper, horizon: window.end)
    }

    /// Queued changes back on top of what a listing brought in.
    private func drawPending(mapper: CalendarEventMapper, horizon: Date) async {
        let waiting = await outbox.pending().filter { !skippingOutboxItems.contains($0.id) }
        guard !waiting.isEmpty else { return }
        await store.applyPending(waiting, mapper: mapper, horizon: horizon)
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

    private var legacyClient: GoogleCalendarClient {
        GoogleCalendarClient(tokens: tokens, transport: transport)
    }

    private func client(for calendar: CalendarInfo) -> GoogleCalendarClient {
        GoogleCalendarClient(accountID: calendar.accountID, calendarID: calendar.calendarID, tokens: tokens,
                             transport: transport)
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

    /// Like `eachCalendar`, with every calendar's outcome.
    private func eachCalendarResult(_ calendars: [CalendarInfo],
                                    _ work: @escaping @Sendable (CalendarInfo) async throws -> Void) async -> [PullResult] {
        guard !calendars.isEmpty else { return [] }
        return await withTaskGroup(of: PullResult.self) { group in
            var results: [PullResult] = []
            for calendar in calendars.prefix(Self.maxConcurrent) {
                group.addTask { await Self.outcome(work, calendar) }
            }
            var next = min(Self.maxConcurrent, calendars.count)
            while let result = await group.next() {
                results.append(result)
                if next < calendars.count {
                    let calendar = calendars[next]
                    next += 1
                    group.addTask { await Self.outcome(work, calendar) }
                }
            }
            return results
        }
    }

    private static func attempt(_ work: @Sendable (CalendarInfo) async throws -> Void, _ calendar: CalendarInfo) async -> Error? {
        do {
            try await work(calendar)
            return nil
        } catch {
            return error
        }
    }

    private static func outcome(_ work: @Sendable (CalendarInfo) async throws -> Void, _ calendar: CalendarInfo) async -> PullResult {
        do {
            try await work(calendar)
            return PullResult(calendar: calendar.id)
        } catch {
            return PullResult(calendar: calendar.id, failure: CalendarFailure.of(error), message: error.localizedDescription)
        }
    }
}
