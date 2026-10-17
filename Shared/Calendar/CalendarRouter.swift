import Foundation

enum RouterError: LocalizedError {
    /// A write to a calendar the account can only read.
    case readOnly(String)
    /// The event was deleted in Google before this change reached it.
    case deletedInGoogle(String)
    /// It changed in Google again while this change was being re-applied on top of Google's version.
    case changedInGoogle(String)

    var errorDescription: String? {
        switch self {
        case let .readOnly(name): String(localized: "You can't change events in “\(name)”.")
        case let .deletedInGoogle(title): String(localized: "“\(title)” was deleted in Google Calendar, so the change wasn't saved.")
        case let .changedInGoogle(title): String(localized: "“\(title)” was changed in Google Calendar at the same time. Try again.")
        }
    }
}

/// Every Google write the assistant makes, sent to the right account and calendar, with the cache kept in step.
///
/// New events go to the default write target (`AccountStore.defaultWriteTarget()`). Existing events carry their
/// account and calendar, so edits and deletes go to the copy's own calendar (after de-duplication, the organizer's
/// or a writable copy). Events without one (pre-migration) go to the default target. Before the single-account
/// sign-in is migrated, everything goes to its primary calendar, as before.
///
/// Two-way sync rules (docs/GOOGLE_CALENDAR_SYNC.md §10):
/// - Edits and deletes send the cached etag as If-Match. After a 412 the change is re-applied once on top of
///   Google's current copy (`ConflictMerge`), so a newer Google edit is never overwritten with stale fields.
/// - When Google cannot be reached (no network, a timeout, 5xx after the client's retries) the change goes to the
///   outbox (`SyncOutbox`) and the cache shows it at once, marked `isPendingSync`. A later change of an event that
///   still waits queues behind it, so order is kept. `SyncEngine` sends the queue.
///
/// Sample calendars (demo mode's accounts) never reach Google: their writes change the cache only
/// (`CalendarRouter+Sample.swift`).
struct CalendarRouter: Sendable {
    var accounts: AccountStore = .shared
    var tokens: GoogleTokenProvider = .shared
    var store: SharedStore = .shared
    var clock = WallClock()
    /// nil: the network with `tokens`. Unit tests pass a stand-in.
    var transport: (any CalendarTransport)? = nil
    /// Where changes wait while Google cannot be reached.
    var outbox: SyncOutbox = .shared

    /// Where a plan's series are searched for, around `now`.
    static let planSearchPast: TimeInterval = 365 * 86_400
    static let planSearchFuture: TimeInterval = 730 * 86_400

    func defaultTarget() async throws -> CalendarInfo {
        if let target = await accounts.defaultWriteTarget() { return target }
        if await accounts.connectedAccounts().isEmpty, tokens.hasLegacyTokens { return Self.legacyTarget }
        throw AuthError.signedOut
    }

    /// The client for a calendar; nil = the default target's.
    func client(for calendar: CalendarRef?) async -> GoogleCalendarClient {
        if let calendar {
            return GoogleCalendarClient(accountID: calendar.accountID, calendarID: calendar.calendarID, tokens: tokens,
                                        transport: transport)
        }
        guard let target = try? await defaultTarget() else { return GoogleCalendarClient(tokens: tokens, transport: transport) }
        return makeClient(target)
    }

    /// Inserts (idempotent ids), returns saved events stamped with account/calendar. Upserts them into the cache;
    /// when any is recurring, re-lists that calendar's rolling window instead. Offline: queued, shown at once and
    /// returned with `isPendingSync`.
    func insert(_ events: [MappedEvent], into target: CalendarInfo, mapper: CalendarEventMapper, now: Date) async throws -> [ScheduleEvent] {
        guard !events.isEmpty else { return [] }
        try Self.requireWritable(target)
        if Self.isSample(target.id) { return try await insertSample(events, into: target, mapper: mapper, now: now) }
        let saved: [GCalEvent]
        do {
            saved = try await makeClient(target).insertAll(events)
        } catch {
            if case let .transport(offline) = CalendarFailure.of(error) {
                return await queueInserts(events, into: target, mapper: mapper, now: now,
                                          mayHaveReachedGoogle: !offline, error: error)
            }
            throw Self.writeError(error, calendar: target)
        }
        let mapped = saved.compactMap { cachedEvent(from: $0, in: target, mapper: mapper) }
        if saved.contains(where: { $0.recurrence != nil }) {
            await refresh(calendar: target.id, now: now)
        } else {
            await store.upsert(mapped)
        }
        return mapped
    }

    /// PATCH one event or instance in its own calendar (If-Match: its cached etag); upserts the result. Offline, or
    /// while an earlier change of the event still waits: queued and returned with `isPendingSync`.
    func patch(_ event: ScheduleEvent, body: GCalEvent, mapper: CalendarEventMapper, now: Date = Date()) async throws -> ScheduleEvent? {
        let calendar = try await owningCalendar(of: event)
        try Self.requireWritable(calendar)
        if Self.isSample(calendar.id) { return try await patchSample(event, body: body, mapper: mapper) }
        let target = calendar.id
        let waiting = await outbox.hasPending(calendar: target, eventID: event.id)
        if waiting || event.isWaitingToSync {
            return await queue(.patch, calendar: target, eventID: event.id, body: body, base: event, mapper: mapper,
                               now: now, mayHaveReachedGoogle: false)
        }
        let saved: GCalEvent
        do {
            saved = try await sendPatch(makeClient(calendar), eventID: event.id, body: body, etag: event.etag,
                                        base: event, mapper: mapper)
        } catch {
            switch CalendarFailure.of(error) {
            case let .transport(offline):
                return await queue(.patch, calendar: target, eventID: event.id, body: body, base: event, mapper: mapper,
                                   now: now, mayHaveReachedGoogle: !offline)
            case .gone:
                await store.remove([event.ref])
                throw RouterError.deletedInGoogle(event.title)
            case .conflict:
                throw RouterError.changedInGoogle(event.title)
            default:
                throw Self.writeError(error, calendar: calendar)
            }
        }
        guard let updated = cachedEvent(from: saved, in: calendar, mapper: mapper) else { return nil }
        await store.upsert([updated])
        return updated
    }

    /// GET the series master of `event` (its `seriesID`; the event itself when it is not an instance) in the event's
    /// calendar.
    func master(of event: ScheduleEvent) async throws -> GCalEvent {
        let calendar = try await owningCalendar(of: event)
        return try await makeClient(calendar).get(eventID: event.seriesID ?? event.id)
    }

    /// PATCH the series master, then re-list that calendar's rolling window. `newStart` moves every occurrence to
    /// its time of day for `duration`: worked out against the master when it is sent, since the master's first date
    /// is not in the cache. Returns true when the change was queued (offline) instead of sent.
    @discardableResult
    func patchSeries(of event: ScheduleEvent, body: GCalEvent, newStart: Date? = nil, duration: TimeInterval? = nil,
                     mapper: CalendarEventMapper, now: Date) async throws -> Bool {
        let calendar = try await owningCalendar(of: event)
        try Self.requireWritable(calendar)
        if Self.isSample(calendar.id) {
            try await patchSampleSeries(of: event, body: body, newStart: newStart, duration: duration, mapper: mapper)
            return false
        }
        let target = calendar.id
        let seriesID = event.seriesID ?? event.id
        var body = body
        var seriesTime = newStart.map { OutboxItem.SeriesTime(newStart: $0, duration: duration ?? event.duration) }
        if seriesTime != nil {
            // The instance's own date would move the master; the time of day is applied to the master's date.
            body.start = nil
            body.end = nil
        }

        if await outbox.hasPending(calendar: target, eventID: seriesID) {
            // A series Google does not have yet: its queued insert is the master.
            if let time = seriesTime, let master = await outbox.pendingInsert(calendar: target, eventID: seriesID),
               let shifted = mapper.seriesTimePatch(master: master, newStart: time.newStart, duration: time.duration) {
                body.start = shifted.start
                body.end = shifted.end
                seriesTime = nil
            }
            _ = await queue(.patchSeries, calendar: target, eventID: seriesID, body: body, seriesTime: seriesTime,
                            base: event, mapper: mapper, now: now, mayHaveReachedGoogle: false)
            return true
        }
        do {
            try await sendSeriesPatch(makeClient(calendar), seriesID: seriesID, body: body, seriesTime: seriesTime,
                                      mapper: mapper)
        } catch {
            switch CalendarFailure.of(error) {
            case let .transport(offline):
                _ = await queue(.patchSeries, calendar: target, eventID: seriesID, body: body, seriesTime: seriesTime,
                                base: event, mapper: mapper, now: now, mayHaveReachedGoogle: !offline)
                return true
            case .gone:
                throw RouterError.deletedInGoogle(event.title)
            case .conflict:
                throw RouterError.changedInGoogle(event.title)
            default:
                throw Self.writeError(error, calendar: calendar)
            }
        }
        await refresh(calendar: calendar.id, now: now)
        return false
    }

    /// Deletes each ref in its own calendar (404/410 = done; If-Match with the cached etag, and after a 412 the
    /// delete is sent anyway, since the user asked for the event to go) and removes those copies, and the instances
    /// of a ref that names a series, from the cache. Refs without a calendar go to the default target. Stops at the
    /// first failure; what was deleted until then leaves the cache too. When Google cannot be reached, this ref and
    /// the rest are queued and leave the cache at once. Returns true when anything was queued.
    @discardableResult
    func delete(_ refs: [EventRef], now: Date = Date()) async throws -> Bool {
        var fallback: CalendarInfo?
        var deleted: [EventRef] = []
        var failure: Error?
        var queued = false
        let cached = await store.snapshot().events
        let mapper = CalendarEventMapper(clock: clock)
        for ref in refs {
            do {
                let calendar: CalendarInfo
                if let accountID = ref.accountID, let calendarID = ref.calendarID {
                    calendar = await calendarInfo(CalendarRef(accountID: accountID, calendarID: calendarID))
                } else if let fallback {
                    calendar = fallback
                } else {
                    calendar = try await defaultTarget()
                    fallback = calendar
                }
                try Self.requireWritable(calendar)
                if Self.isSample(calendar.id) {
                    // Sample events live in the cache only: they leave it below, with a series' occurrences.
                    try await requireDemoActive()
                    deleted += [ref, EventRef(accountID: calendar.accountID, calendarID: calendar.calendarID,
                                              eventID: ref.eventID)]
                    continue
                }
                let target = calendar.id
                let copy = cached.first(where: { $0.ref == ref })
                    ?? cached.first(where: { $0.id == ref.eventID && OutboxOverlay.belongs($0, to: target) })
                let waiting = await outbox.hasPending(calendar: target, eventID: ref.eventID)
                if queued || waiting || copy?.isWaitingToSync == true {
                    await queueDelete(ref.eventID, calendar: target, copy: copy, now: now, mayHaveReachedGoogle: false)
                    queued = true
                    // Gone here at once, also when the queue simply dropped a create that never reached Google.
                    deleted.append(copy?.ref ?? ref)
                    continue
                }
                do {
                    try await sendDelete(makeClient(calendar), eventID: ref.eventID, etag: copy?.etag)
                } catch {
                    if case let .transport(offline) = CalendarFailure.of(error) {
                        await queueDelete(ref.eventID, calendar: target, copy: copy, now: now, mayHaveReachedGoogle: !offline)
                        queued = true
                        deleted.append(copy?.ref ?? ref)
                        continue
                    }
                    throw Self.writeError(error, calendar: calendar)
                }
                deleted.append(ref)
                if ref.accountID == nil, !Self.isLegacy(calendar) {
                    // The cached copy may carry the calendar the request did not name.
                    deleted.append(EventRef(accountID: calendar.accountID, calendarID: calendar.calendarID, eventID: ref.eventID))
                }
            } catch {
                failure = error
                break
            }
        }
        if !deleted.isEmpty { await store.remove(deleted, includingSeries: true) }
        if queued { await drawPending(mapper: mapper, now: now) }
        if let failure { throw failure }
        return queued
    }

    /// Series masters of a plan across all writable synced calendars (a plan lives where it was added). Offline:
    /// the plan's series as cached, so deleting it can wait in the outbox.
    func planEventRefs(planID: String, now: Date) async throws -> [EventRef] {
        if let target = try? await defaultTarget(), Self.isSample(target.id) { return await samplePlanRefs(planID: planID) }
        do {
            return try await listedPlanRefs(planID: planID, now: now)
        } catch let error where CalendarFailure.of(error).isTransport {
            var seen = Set<EventRef>()
            let refs = await store.snapshot().events
                .filter { $0.planID == planID }
                .map { EventRef(accountID: $0.accountID, calendarID: $0.calendarID, eventID: $0.seriesID ?? $0.id) }
                .filter { seen.insert($0).inserted }
            if refs.isEmpty { throw error }
            return refs
        }
    }

    private func listedPlanRefs(planID: String, now: Date) async throws -> [EventRef] {
        let from = now.addingTimeInterval(-Self.planSearchPast), to = now.addingTimeInterval(Self.planSearchFuture)
        let property = (key: SSProperty.planID, value: planID)
        let writable = await accounts.syncedCalendars().filter(\.isWritable)
        guard !writable.isEmpty else {
            let target = try await defaultTarget()
            let masters = try await makeClient(target).list(from: from, to: to, singleEvents: false, privateProperty: property)
            return masters.compactMap { master in
                master.id.map { EventRef(accountID: Self.accountID(of: target), calendarID: Self.calendarID(of: target), eventID: $0) }
            }
        }
        var refs: [EventRef] = []
        var firstError: Error?
        for calendar in writable {
            do {
                let masters = try await makeClient(calendar).list(from: from, to: to, singleEvents: false, privateProperty: property)
                refs += masters.compactMap { master in
                    master.id.map { EventRef(accountID: calendar.accountID, calendarID: calendar.calendarID, eventID: $0) }
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if refs.isEmpty, let firstError { throw firstError }
        return refs
    }

    /// Re-lists one calendar's rolling window (after writes). Failures keep the cache as it was. `skipping`: outbox
    /// items Google just confirmed, whose optimistic copies must not be drawn over Google's again.
    func refresh(calendar: CalendarRef, now: Date, skipping: Set<UUID> = []) async {
        try? await CalendarSync(store: store, accounts: accounts, tokens: tokens, clock: clock,
                                calendars: calendar == Self.legacyTarget.id ? nil : [calendar],
                                transport: transport, outbox: outbox, skippingOutboxItems: skipping)
            .refreshWindow(now: now)
    }

    // MARK: Outbox

    /// Sends one queued change (`SyncEngine`) and puts Google's copy in the cache in place of the optimistic one.
    /// Throws what Google answered; the engine decides whether it stays queued, waits for Reconnect or fails.
    func send(_ item: OutboxItem, now: Date) async throws {
        let calendar: CalendarInfo
        if item.isLegacy {
            calendar = Self.legacyTarget
        } else {
            calendar = await calendarInfo(item.calendar)
        }
        try Self.requireWritable(calendar)
        let client = makeClient(calendar)
        let mapper = CalendarEventMapper(clock: clock)
        switch item.kind {
        case .insert:
            guard let body = item.body else { return }
            let result = try await client.insertReportingExisting(MappedEvent(body: body, wantsConference: item.wantsConference))
            var saved = result.event
            // An earlier attempt got through before later edits were folded in: send those edits too.
            if result.existed, let followUp = item.followUp,
               let rebased = ConflictMerge.rebase(followUp, base: nil, onto: saved, mapper: mapper) {
                saved = try await sendPatch(client, eventID: item.eventID, body: rebased, etag: saved.etag, base: nil,
                                            mapper: mapper)
            }
            if saved.recurrence != nil {
                // The queued expansion's instance ids are not Google's: the listing replaces them.
                await store.confirmPending(calendar: item.calendar, eventID: item.eventID, replacingWith: nil)
                await refresh(calendar: calendar.id, now: now, skipping: [item.id])
            } else {
                let mapped = cachedEvent(from: saved, in: calendar, mapper: mapper)
                await store.confirmPending(calendar: item.calendar, eventID: item.eventID,
                                           replacingWith: mapped.map { [$0] } ?? [])
            }
        case .patch:
            guard let body = item.body else { return }
            let saved = try await sendPatch(client, eventID: item.eventID, body: body, etag: item.etag, base: item.base,
                                            mapper: mapper)
            let mapped = cachedEvent(from: saved, in: calendar, mapper: mapper)
            await store.confirmPending(calendar: item.calendar, eventID: item.eventID,
                                       replacingWith: mapped.map { [$0] } ?? [])
        case .patchSeries:
            try await sendSeriesPatch(client, seriesID: item.eventID, body: item.body ?? GCalEvent(),
                                      seriesTime: item.seriesTime, mapper: mapper)
            await store.confirmPending(calendar: item.calendar, eventID: item.eventID, replacingWith: nil)
            await refresh(calendar: calendar.id, now: now, skipping: [item.id])
        case .delete:
            try await sendDelete(client, eventID: item.eventID, etag: item.etag)
            let ref = EventRef(accountID: Self.accountID(of: calendar), calendarID: Self.calendarID(of: calendar),
                               eventID: item.eventID)
            await store.remove([ref], includingSeries: true)
        }
    }

    // MARK: Sending

    /// PATCH with If-Match. After a 412: Google's current copy with the change re-applied on top (`ConflictMerge`),
    /// sent once more with that copy's etag; a cancelled copy reads as gone (410).
    private func sendPatch(_ client: GoogleCalendarClient, eventID: String, body: GCalEvent, etag: String?,
                           base: ScheduleEvent?, mapper: CalendarEventMapper) async throws -> GCalEvent {
        do {
            return try await client.patch(eventID: eventID, body, ifMatch: etag)
        } catch let error as CalendarAPIError where error.status == 412 {
            let fresh = try await client.get(eventID: eventID)
            guard fresh.status != "cancelled" else {
                throw CalendarAPIError.http(status: 410, reason: "deleted", message: "")
            }
            guard let rebased = ConflictMerge.rebase(body, base: base, onto: fresh, mapper: mapper) else { return fresh }
            return try await client.patch(eventID: eventID, rebased, ifMatch: fresh.etag)
        }
    }

    /// A series edit; `seriesTime` is worked out against the master fetched now (and its etag guards the PATCH).
    private func sendSeriesPatch(_ client: GoogleCalendarClient, seriesID: String, body: GCalEvent,
                                 seriesTime: OutboxItem.SeriesTime?, mapper: CalendarEventMapper) async throws {
        var body = body
        var etag: String?
        if let time = seriesTime {
            let master = try await client.get(eventID: seriesID)
            etag = master.etag
            let shifted = mapper.seriesTimePatch(master: master, newStart: time.newStart, duration: time.duration)
            body.start = shifted?.start
            body.end = shifted?.end
        }
        _ = try await sendPatch(client, eventID: seriesID, body: body, etag: etag, base: nil, mapper: mapper)
    }

    /// DELETE with If-Match; after a 412 (changed in Google since it was read) it is deleted anyway, since the user
    /// asked for it to go.
    private func sendDelete(_ client: GoogleCalendarClient, eventID: String, etag: String?) async throws {
        do {
            try await client.delete(eventID: eventID, ifMatch: etag)
        } catch let error as CalendarAPIError where error.status == 412 {
            try await client.delete(eventID: eventID)
        }
    }

    // MARK: Queueing

    private func queueInserts(_ events: [MappedEvent], into target: CalendarInfo, mapper: CalendarEventMapper, now: Date,
                              mayHaveReachedGoogle: Bool, error: Error) async -> [ScheduleEvent] {
        var shown: [ScheduleEvent] = []
        for event in events {
            guard let id = event.body.id else { continue }
            var preview = cachedEvent(from: event.body, in: target, mapper: mapper)
            preview?.isPendingSync = true
            var item = OutboxItem(kind: .insert, calendar: target.id, eventID: id, body: event.body,
                                  wantsConference: event.wantsConference, title: event.body.summary ?? "",
                                  summary: Self.changeSummary(.insert, preview, clock: mapper.clock), createdAt: now,
                                  mayHaveReachedGoogle: mayHaveReachedGoogle)
            item.attempts = 1
            item.lastError = error.localizedDescription
            await outbox.enqueue(item)
            if let preview { shown.append(preview) }
        }
        await drawPending(mapper: mapper, now: now)
        return shown
    }

    /// Queues an edit and shows it at once; returns the edited copy as it now looks.
    private func queue(_ kind: OutboxItem.Kind, calendar: CalendarRef, eventID: String, body: GCalEvent,
                       seriesTime: OutboxItem.SeriesTime? = nil, base: ScheduleEvent, mapper: CalendarEventMapper,
                       now: Date, mayHaveReachedGoogle: Bool) async -> ScheduleEvent? {
        var shown: ScheduleEvent?
        if kind == .patch {
            var updated = OutboxOverlay.applying(body, to: base, clock: mapper.clock)
            updated.isPendingSync = true
            shown = updated
        }
        let item = OutboxItem(kind: kind, calendar: calendar, eventID: eventID, body: body, seriesTime: seriesTime,
                              etag: kind == .patch ? base.etag : nil, base: base, title: base.title,
                              summary: Self.changeSummary(kind, shown ?? base, clock: mapper.clock), createdAt: now,
                              mayHaveReachedGoogle: mayHaveReachedGoogle)
        await outbox.enqueue(item)
        await drawPending(mapper: mapper, now: now)
        return shown
    }

    private func queueDelete(_ eventID: String, calendar: CalendarRef, copy: ScheduleEvent?, now: Date,
                             mayHaveReachedGoogle: Bool) async {
        // A copy of a series (deleting every occurrence) is an instance; the master's etag is not cached.
        let etag = copy?.id == eventID ? copy?.etag : nil
        let item = OutboxItem(kind: .delete, calendar: calendar, eventID: eventID, etag: etag, base: copy,
                              title: copy?.title ?? "", summary: Self.changeSummary(.delete, copy, clock: clock),
                              createdAt: now, mayHaveReachedGoogle: mayHaveReachedGoogle)
        await outbox.enqueue(item)
    }

    private func drawPending(mapper: CalendarEventMapper, now: Date) async {
        let waiting = await outbox.pending()
        await store.applyPending(waiting, mapper: mapper, horizon: CalendarSync.window(now: now, clock: clock).end)
    }

    /// The failed list's second line: what the change was and when the event is.
    static func changeSummary(_ kind: OutboxItem.Kind, _ event: ScheduleEvent?, clock: WallClock) -> String {
        guard let event else { return "" }
        let when = ReplyFormatter.when(event, clock: clock)
        switch kind {
        case .insert: return String(localized: "New event · \(when)")
        case .patch: return String(localized: "Edit · \(when)")
        case .patchSeries: return String(localized: "Edit every occurrence")
        case .delete: return String(localized: "Delete · \(when)")
        }
    }

    // MARK: Helpers

    /// Stand-in for the single-account sign-in before migration: its primary calendar, events cached unscoped.
    private static let legacyTarget = CalendarInfo(accountID: "", accountEmail: "", calendarID: "primary",
                                                   name: "primary", isPrimary: true, accessRole: "owner")

    private static func isLegacy(_ calendar: CalendarInfo) -> Bool { calendar.accountID.isEmpty }
    private static func accountID(of calendar: CalendarInfo) -> String? { isLegacy(calendar) ? nil : calendar.accountID }
    private static func calendarID(of calendar: CalendarInfo) -> String? { isLegacy(calendar) ? nil : calendar.calendarID }

    private func makeClient(_ calendar: CalendarInfo) -> GoogleCalendarClient {
        GoogleCalendarClient(accountID: Self.accountID(of: calendar), calendarID: calendar.calendarID, tokens: tokens,
                             transport: transport)
    }

    private func cachedEvent(from event: GCalEvent, in calendar: CalendarInfo, mapper: CalendarEventMapper) -> ScheduleEvent? {
        Self.isLegacy(calendar) ? mapper.scheduleEvent(from: event) : mapper.scheduleEvent(from: event, in: calendar)
    }

    /// The calendar an existing copy lives in; the default target for copies cached without one.
    private func owningCalendar(of event: ScheduleEvent) async throws -> CalendarInfo {
        guard let ref = event.calendarRef else { return try await defaultTarget() }
        return await calendarInfo(ref)
    }

    /// A calendar the account store no longer lists (removed meanwhile) is still addressed by its ids; Google
    /// decides whether the write is allowed.
    private func calendarInfo(_ ref: CalendarRef) async -> CalendarInfo {
        if let known = await accounts.calendar(ref) { return known }
        let email = await accounts.connectedAccount(id: ref.accountID)?.email ?? ""
        return CalendarInfo(accountID: ref.accountID, accountEmail: email, calendarID: ref.calendarID,
                            name: ref.calendarID, isPrimary: ref.calendarID == email, accessRole: "writer")
    }

    private static func requireWritable(_ calendar: CalendarInfo) throws {
        guard calendar.isWritable else { throw RouterError.readOnly(calendar.displayName) }
    }

    /// Google's "you need writer access" (`requiredAccessLevel`, e.g. access changed since the calendar list was
    /// read) reads as "You can't change events in …". Rate limits were retried by the client already.
    private static func writeError(_ error: Error, calendar: CalendarInfo) -> Error {
        guard case let .http(status, reason, _)? = error as? CalendarAPIError, status == 403,
              reason == "requiredAccessLevel" || !calendar.isWritable else { return error }
        return RouterError.readOnly(calendar.displayName)
    }
}
