import Foundation

/// What asked for a sync; decides how fresh the Google → iPhone pass must be.
enum SyncTrigger: String, CaseIterable, Sendable {
    case foreground, timer, pull, background, outbox, network, notification, summon

    /// A calendar whose last full listing is older than this is listed in full; a younger one gets the cheap
    /// "changed since" pass. 0: always in full (pull-to-refresh, background refresh).
    var fullListingAfter: TimeInterval {
        switch self {
        case .pull, .background: 0
        case .foreground: 15 * 60
        case .timer, .outbox, .network, .notification, .summon: 30 * 60
        }
    }
}

struct SyncReport: Sendable {
    /// The cache's events changed (sent changes confirmed, Google's changes brought in).
    var changed = false
    /// Accounts whose every calendar answered.
    var pulledAccounts = 0
    /// Outbox items Google confirmed.
    var sent = 0
    var errors: [String] = []
}

/// One event as Google has it now, for a reminder's notification card.
enum FreshEvent: Equatable, Sendable {
    /// Unchanged in time (the title or place may have changed).
    case current(ScheduleEvent)
    /// Its start or end moved since it was cached.
    case moved(ScheduleEvent)
    case cancelled
    /// Not checked: offline, demo mode, signed out, or a change of it still waits to be sent.
    case unavailable
}

/// Runs the two-way sync for every process (app, Siri, notification extension): sends the outbox, then brings in
/// what changed in Google, and keeps `SyncStatusStore` current. Never throws; concurrent calls share one run.
/// Demo mode never touches the network. See docs/GOOGLE_CALENDAR_SYNC.md §10.
actor SyncEngine {
    static let shared = SyncEngine()

    private let store: SharedStore
    private let accounts: AccountStore
    private let outbox: SyncOutbox
    private let tokens: GoogleTokenProvider
    private let transport: (any CalendarTransport)?
    private let statusDefaults: UserDefaults?
    private let fixedClock: WallClock?
    private let isDemoMode: @Sendable () -> Bool
    private var onChange: @Sendable () async -> Void

    private struct Run {
        let id: UUID
        let fullListingAfter: TimeInterval
        let task: Task<SyncReport, Never>
    }

    private struct FlushResult {
        var sent = 0
        /// Stopped at a transport failure; the rest of the queue waits behind it.
        var stopped = false
        /// That failure never left the iPhone (no connection).
        var offline = false
        var unreachable: String?
        var errors: [String] = []
    }

    private var run: Run?
    private var flushing: Task<FlushResult, Never>?

    /// - Parameters:
    ///   - transport: nil = the network with `tokens`; unit tests pass a stand-in.
    ///   - statusDefaults: where `SyncStatusStore` lives (the App Group); unit tests pass their own suite.
    ///   - clock: nil = Settings › Time zone, read per run.
    ///   - onChange: runs after a sync changed the cache (reminders follow); the app adds the Live Activity
    ///     (`setChangeHandler`).
    init(store: SharedStore = .shared,
         accounts: AccountStore = .shared,
         outbox: SyncOutbox = .shared,
         tokens: GoogleTokenProvider = .shared,
         transport: (any CalendarTransport)? = nil,
         statusDefaults: UserDefaults? = UserDefaults(suiteName: AppConstants.appGroupID),
         clock: WallClock? = nil,
         isDemoMode: @escaping @Sendable () -> Bool = { AppConstants.isDemoMode },
         onChange: @escaping @Sendable () async -> Void = { await ReminderScheduler.shared.reschedule() }) {
        self.store = store
        self.accounts = accounts
        self.outbox = outbox
        self.tokens = tokens
        self.transport = transport
        self.statusDefaults = statusDefaults
        self.fixedClock = clock
        self.isDemoMode = isDemoMode
        self.onChange = onChange
    }

    func setChangeHandler(_ handler: @escaping @Sendable () async -> Void) {
        onChange = handler
    }

    // MARK: Sync

    /// Sends the outbox, then pulls (a "changed since" pass or the full window, per `trigger`), then sends what
    /// was queued meanwhile. A call while a run at least as thorough is under way gets that run's report; a more
    /// thorough one waits for it and runs after it.
    @discardableResult
    func sync(_ trigger: SyncTrigger, now: Date = Date()) async -> SyncReport {
        guard !isDemoMode() else {
            await publishStatus { status in
                status.isOffline = false
                status.lastError = nil
            }
            return SyncReport()
        }
        let fullListingAfter = trigger.fullListingAfter
        while let running = run {
            if running.fullListingAfter <= fullListingAfter { return await running.task.value }
            _ = await running.task.value
        }
        let id = UUID()
        let task = Task { () -> SyncReport in
            let report = await self.perform(fullListingAfter: fullListingAfter, now: now)
            await self.endRun(id)
            return report
        }
        run = Run(id: id, fullListingAfter: fullListingAfter, task: task)
        return await task.value
    }

    /// Sends what the outbox holds, in order, then pulls when anything went out. Returns how many Google confirmed.
    @discardableResult
    func flushOutbox() async -> Int {
        guard !isDemoMode() else { return 0 }
        let result = await flushSerially(now: Date())
        if result.sent > 0 {
            _ = await sync(.outbox)
        } else {
            await publishStatus { status in
                if result.stopped { status.isOffline = result.offline }
            }
        }
        return result.sent
    }

    /// A failed change back in the queue, sent at once.
    func retry(_ id: UUID) async {
        guard await outbox.retry(id: id) else { return }
        await publishStatus()
        guard !isDemoMode() else { return }
        _ = await sync(.outbox)
    }

    /// A failed (or waiting) change dropped: its calendar is listed again, so Google's version replaces what this
    /// iPhone showed.
    func discard(_ id: UUID) async {
        guard let item = await outbox.discard(id: id) else { return }
        await publishStatus()
        guard !isDemoMode() else { return }
        let before = Set(await store.snapshot().events)
        await makeRouter().refresh(calendar: item.calendar, now: Date())
        let after = Set(await store.snapshot().events)
        if before != after {
            await onChange()
            SharedChangeNotifier.post(.syncStatus)
        }
    }

    /// The event behind a reminder, fetched fresh (`events.get`) and compared with the cached copy, which is
    /// updated (or removed when Google cancelled it).
    func freshEvent(_ ref: EventRef) async -> FreshEvent {
        let cached = await store.snapshot().events.first { $0.ref == ref }
        guard !isDemoMode(), cached?.isWaitingToSync != true,
              let accountID = ref.accountID, let calendarID = ref.calendarID, !accountID.isEmpty else {
            return .unavailable
        }
        let calendar = CalendarRef(accountID: accountID, calendarID: calendarID)
        let client = GoogleCalendarClient(accountID: accountID, calendarID: calendarID, tokens: tokens, transport: transport)
        let fetched: GCalEvent
        do {
            fetched = try await client.get(eventID: ref.eventID)
        } catch {
            guard CalendarFailure.of(error) == .gone else { return .unavailable }
            await removeCancelled(ref)
            return .cancelled
        }
        guard fetched.status != "cancelled" else {
            await removeCancelled(ref)
            return .cancelled
        }
        let mapper = CalendarEventMapper(clock: clock)
        let info = await accounts.calendar(calendar)
        let mapped = info.flatMap({ mapper.scheduleEvent(from: fetched, in: $0) })
            ?? mapper.scheduleEvent(from: fetched).map({ SharedStore.stamped($0, calendar: calendar) })
        guard let fresh = mapped else { return .unavailable }
        guard fresh != cached else { return .current(fresh) }
        await store.upsert([fresh])
        await onChange()
        SharedChangeNotifier.post(.syncStatus)
        if let cached, cached.start != fresh.start || cached.end != fresh.end || cached.isAllDay != fresh.isAllDay {
            return .moved(fresh)
        }
        return .current(fresh)
    }

    // MARK: Runs

    private func endRun(_ id: UUID) {
        if run?.id == id { run = nil }
    }

    private func perform(fullListingAfter: TimeInterval, now: Date) async -> SyncReport {
        var report = SyncReport()
        let before = Set(await store.snapshot().events)

        let flushed = await flushSerially(now: now)
        report.sent = flushed.sent
        report.errors += flushed.errors
        var offline = flushed.offline
        var unreachable = flushed.unreachable
        var problem: String?
        var synced: [String] = []

        if !offline {
            do {
                let results = try await makeSync().pull(staleAfter: fullListingAfter, now: now)
                let byAccount = Dictionary(grouping: results, by: { $0.calendar.accountID })
                for (accountID, outcomes) in byAccount where !accountID.isEmpty && outcomes.allSatisfy({ $0.failure == nil }) {
                    synced.append(accountID)
                }
                report.pulledAccounts = synced.count
                if results.contains(where: { $0.failure == nil }) {
                    offline = false
                    unreachable = nil
                }
                for result in results {
                    guard let failure = result.failure else { continue }
                    let message = result.message ?? ""
                    report.errors.append(message)
                    switch failure {
                    case let .transport(isOffline):
                        if isOffline, !results.contains(where: { $0.failure == nil }) { offline = true }
                        if !isOffline { unreachable = unreachable ?? message }
                    case .auth:
                        break // that account shows Reconnect
                    case .conflict, .gone, .rejected:
                        problem = problem ?? message
                    }
                }
                // Google answered: what was queued during the pull goes out too (unless the queue is stuck behind
                // a change Google did not take).
                let waiting = await outbox.pending()
                if !flushed.stopped, !synced.isEmpty, !waiting.isEmpty {
                    let again = await flushSerially(now: now)
                    report.sent += again.sent
                    report.errors += again.errors
                }
            } catch {
                report.errors.append(error.localizedDescription)
                switch CalendarFailure.of(error) {
                case .auth: break // signed out, or every account needs Reconnect
                case let .transport(isOffline):
                    if isOffline { offline = true } else { unreachable = error.localizedDescription }
                default: problem = error.localizedDescription
                }
            }
        }

        let after = Set(await store.snapshot().events)
        report.changed = before != after
        if report.changed { await onChange() }

        let connected = Set(await accounts.connectedAccounts().map(\.id))
        let finished = Date()
        let lastError = offline ? nil : (problem ?? unreachable)
        let statusChanged = await publishStatus { status in
            status.isOffline = offline
            status.lastError = lastError
            for accountID in synced { status.lastSuccess[accountID] = finished }
            status.lastSuccess = status.lastSuccess.filter { connected.contains($0.key) }
        }
        // Other processes reload their events on this.
        if report.changed, !statusChanged { SharedChangeNotifier.post(.syncStatus) }
        return report
    }

    // MARK: Outbox

    /// One flush at a time per process; a caller during a flush gets its result. (A flush in another process at
    /// the same time is harmless: inserts are idempotent, a repeated edit meets a 412 and finds nothing left to
    /// apply, a repeated delete meets 404.)
    private func flushSerially(now: Date) async -> FlushResult {
        if let flushing { return await flushing.value }
        let task = Task { () -> FlushResult in
            let result = await self.flush(now: now)
            await self.endFlush()
            return result
        }
        flushing = task
        return await task.value
    }

    private func endFlush() {
        flushing = nil
    }

    /// Sends the queue in order. A transport failure stops it (order is kept); a sign-in problem holds back that
    /// account's items (they stay queued until Reconnect); anything Google refuses goes to the failed list.
    private func flush(now: Date) async -> FlushResult {
        var result = FlushResult()
        let items = await outbox.pending()
        guard !items.isEmpty else { return result }
        let router = makeRouter()
        let connected = await accounts.connectedAccounts()
        var held = Set<String>()
        for item in items {
            let accountID = item.calendar.accountID
            if !item.isLegacy {
                guard let account = connected.first(where: { $0.id == accountID }) else {
                    // Hold, never discard: an unreadable accounts.json also looks like "no accounts". A real
                    // disconnect already removed this account's items (AccountManager.disconnect).
                    held.insert(accountID)
                    continue
                }
                if account.needsReconnect { held.insert(accountID) }
            }
            if held.contains(accountID) { continue }
            if item.kind == .insert { await outbox.markSending(id: item.id) }
            do {
                try await router.send(item, now: now)
                await outbox.complete(item)
                result.sent += 1
            } catch {
                let message = error.localizedDescription
                result.errors.append(message)
                let failure = CalendarFailure.of(error)
                switch failure {
                case let .transport(offline):
                    await outbox.recordAttempt(id: item.id, mayHaveReachedGoogle: item.mayHaveReachedGoogle || !offline,
                                               error: message)
                    result.stopped = true
                    result.offline = offline
                    if !offline { result.unreachable = message }
                    return result
                case .auth:
                    held.insert(accountID)
                    // Google wrote nothing: clears the in-flight mark.
                    await outbox.recordAttempt(id: item.id, mayHaveReachedGoogle: item.mayHaveReachedGoogle, error: message)
                    if case let .http(status, _, _)? = error as? CalendarAPIError, status == 401, !item.isLegacy {
                        await accounts.setNeedsReconnect(true, accountID: accountID)
                    }
                case .conflict, .gone, .rejected:
                    let reason = await Self.reason(for: failure, error: error, item: item, accounts: accounts)
                    await outbox.fail(id: item.id, reason: reason, at: now)
                }
            }
        }
        return result
    }

    /// The failed list's "why".
    private static func reason(for failure: CalendarFailure, error: Error, item: OutboxItem,
                               accounts: AccountStore) async -> String {
        switch failure {
        case .conflict:
            return String(localized: "It was changed in Google Calendar at the same time.")
        case .gone where item.kind != .insert:
            return String(localized: "It was deleted in Google Calendar.")
        default:
            if let error = error as? RouterError { return error.localizedDescription }
            guard case let .http(status, reason, _)? = error as? CalendarAPIError else { return error.localizedDescription }
            if status == 403, reason != "rateLimitExceeded" {
                let name = await accounts.calendar(item.calendar)?.displayName ?? item.calendar.calendarID
                return RouterError.readOnly(name).localizedDescription
            }
            return String(localized: "Google Calendar refused this change (error \(status)).")
        }
    }

    // MARK: Helpers

    private var clock: WallClock { fixedClock ?? WallClock() }

    private func makeRouter() -> CalendarRouter {
        CalendarRouter(accounts: accounts, tokens: tokens, store: store, clock: clock, transport: transport, outbox: outbox)
    }

    private func makeSync() -> CalendarSync {
        CalendarSync(store: store, accounts: accounts, tokens: tokens, clock: clock, transport: transport, outbox: outbox)
    }

    private func removeCancelled(_ ref: EventRef) async {
        await store.remove([ref])
        await onChange()
        SharedChangeNotifier.post(.syncStatus)
    }

    /// The outbox's counts and failed list, plus `change`. True when the stored status changed (and was posted).
    @discardableResult
    private func publishStatus(_ change: (inout SyncStatus) -> Void = { _ in }) async -> Bool {
        let items = await outbox.items()
        let demo = isDemoMode()
        let before = SyncStatusStore.current(in: statusDefaults)
        let after = SyncStatusStore.update(in: statusDefaults) { status in
            status.isDemo = demo
            status.pendingCount = items.filter { !$0.isFailed }.count
            status.failed = items.compactMap(\.failedChange)
            change(&status)
        }
        return after != before
    }
}
