import Foundation

/// App Group JSON cache — the single source of truth for every surface that cannot do network I/O
/// at render time (Live Activity, widgets) and a fast local context for prompts.
///
/// Three processes write here, so every access re-reads the file under `NSFileCoordinator`.
/// The file is small (a 90-day window ≈ 50–150 KB; ranges loaded on demand are capped by
/// `ScheduleViewModel.maxCachedEvents`); move to SQLite/SwiftData only if profiling says so.
///
/// Events are cached per copy (`EventRef`: account, calendar, event id), so one meeting seen through two accounts
/// is two cached copies; `visibleEvents` shows one of them (`EventVisibility`).
actor SharedStore {
    static let shared = SharedStore()

    struct Snapshot: Codable {
        var events: [ScheduleEvent] = []
        var nudges: [PlanNudge] = []
        var windowStart: Date?
        var windowEnd: Date?
        var lastRefresh: Date?
        var lastAssistantLine: String?
        /// The long-term plan waiting for Add / Keep editing. Optional so caches written before drafts existed decode.
        var pendingPlan: PlanDraft?
        /// Ranges outside the rolling window whose calendar-less (demo, pre-migration) events were loaded on demand
        /// (sorted, merged). Written by the app only (Shared/Calendar/SharedStore+LoadedRanges.swift);
        /// `replaceWindow` empties it.
        var loadedRanges: [DateInterval] = []
        /// Per synced calendar (`CalendarRef.key`): its rolling window plus the ranges loaded on demand, merged.
        var coverageByCalendar: [String: [DateInterval]] = [:]
        /// "Ask me first": single events waiting for Add, shared with Siri and the notification extension.
        var pendingEventBatch: PendingEventBatch?
        /// Per synced calendar (`CalendarRef.key`): when it was last listed in full and since when Google's changes
        /// have been applied (`SyncEngine`'s "changed since" pass).
        var syncMarks: [String: SyncMark] = [:]

        /// The rolling sync window (`windowStart ..< windowEnd`), when a sync or the demo seed has set one.
        var window: DateInterval? {
            guard let windowStart, let windowEnd, windowEnd > windowStart else { return nil }
            return DateInterval(start: windowStart, end: windowEnd)
        }
    }

    private let fileURL: URL
    /// Visibility rules and synced calendars come from here. nil (unit tests without one): every cached event is
    /// visible and coverage is the calendar-less one, as before accounts existed.
    let accounts: AccountStore?

    init(fileName: String = "schedule-cache.json") {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID)
            ?? FileManager.default.temporaryDirectory
        fileURL = container.appendingPathComponent(fileName)
        accounts = .shared
    }

    /// A cache at an explicit location. Unit tests use a temporary file, since a hostless test bundle has no
    /// App Group entitlement.
    init(fileURL: URL, accounts: AccountStore? = nil) {
        self.fileURL = fileURL
        self.accounts = accounts
    }

    // MARK: Reads

    /// Every cached copy, hidden calendars and other accounts' copies of a meeting included: for storage
    /// maintenance. Surfaces use `visibleEvents`.
    func snapshot() -> Snapshot { read() }

    /// What a surface shows: hidden calendars (and, while a Focus filter is on, calendars outside it) left out,
    /// `.reminders` also leaves out calendars whose notifications are off, local colours applied, one copy per
    /// meeting, sorted by start. Calendars the account store does not know stay visible.
    func visibleEvents(in interval: DateInterval? = nil, audience: EventAudience = .display) async -> [ScheduleEvent] {
        let cached = read().events
        let candidates = interval.map { range in cached.filter { $0.intersects(range) } } ?? cached
        let rules = await visibilityRules()
        return EventVisibility.apply(candidates, rules: rules, audience: audience)
    }

    func events(in interval: DateInterval) async -> [ScheduleEvent] {
        await visibleEvents(in: interval, audience: .display)
    }

    /// The visible copy of `id`, else any cached copy (an event in a hidden calendar can still be opened).
    func event(id: String) async -> ScheduleEvent? {
        let copies = read().events.filter { $0.id == id }
        guard !copies.isEmpty else { return nil }
        let rules = await visibilityRules()
        return EventVisibility.apply(copies, rules: rules, audience: .display).first ?? copies.first
    }

    func pendingPlan() -> PlanDraft? {
        read().pendingPlan
    }

    func pendingEventBatch() -> PendingEventBatch? {
        read().pendingEventBatch
    }

    // MARK: Writes

    /// Inserts or replaces by `EventRef`: the same id in another calendar is another copy and stays.
    func upsert(_ events: [ScheduleEvent]) {
        mutate { snapshot in
            let incoming = Dictionary(events.map { ($0.ref, $0) }, uniquingKeysWith: { _, new in new })
            snapshot.events.removeAll { incoming[$0.ref] != nil }
            snapshot.events.append(contentsOf: incoming.values)
        }
    }

    /// Every copy with one of these ids, in any calendar, and the instances of these series (demo mode).
    func remove(ids: Set<String>, seriesIDs: Set<String> = []) {
        mutate { snapshot in
            snapshot.events.removeAll { ids.contains($0.id) || ($0.seriesID.map { seriesIDs.contains($0) } ?? false) }
        }
    }

    /// These copies only. `includingSeries` also removes the instances of a ref that names a series, in the same
    /// calendar (deleting "all occurrences").
    func remove(_ refs: [EventRef], includingSeries: Bool = false) {
        guard !refs.isEmpty else { return }
        let targets = Set(refs)
        mutate { snapshot in
            snapshot.events.removeAll { event in
                if targets.contains(event.ref) { return true }
                guard includingSeries, let seriesID = event.seriesID else { return false }
                return targets.contains(EventRef(accountID: event.accountID, calendarID: event.calendarID, eventID: seriesID))
            }
        }
    }

    /// Replaces everything inside `interval` with a fresh listing; keeps events outside it, except older copies of
    /// listed events (an event moved into the window from a range loaded on demand). Used by demo seeding and the
    /// single-account fallback; every calendar's coverage is forgotten, as all events in the window are replaced.
    ///
    /// Also forgets the on-demand ranges: their events stay cached and on screen, but each range is listed again
    /// the next time it is shown, so edits made elsewhere reach far dates too.
    func replaceWindow(_ interval: DateInterval, with events: [ScheduleEvent]) {
        mutate { snapshot in
            let incoming = Dictionary(events.map { ($0.ref, $0) }, uniquingKeysWith: { _, new in new })
            snapshot.events.removeAll { $0.intersects(interval) || incoming[$0.ref] != nil }
            snapshot.events.append(contentsOf: incoming.values)
            snapshot.windowStart = interval.start
            snapshot.windowEnd = interval.end
            snapshot.lastRefresh = Date()
            snapshot.loadedRanges = []
            snapshot.coverageByCalendar = [:]
            snapshot.syncMarks = [:]
        }
    }

    /// One calendar's rolling window: replaces that calendar's events inside `interval` (and older copies of listed
    /// events elsewhere in it), leaves every other calendar alone, and sets that calendar's coverage to the window,
    /// forgetting its on-demand ranges like the calendar-less version.
    ///
    /// - Parameter listedAt: Google's clock when the listing started (less a safety margin): Google changes after it
    ///   are what the next "changed since" pass asks for. nil: two minutes before now on this iPhone's clock.
    func replaceWindow(_ interval: DateInterval, calendar: CalendarRef, with events: [ScheduleEvent],
                       listedAt: Date? = nil) {
        mutate { snapshot in
            let stamped = events.map { Self.stamped($0, calendar: calendar) }
            let incoming = Dictionary(stamped.map { ($0.ref, $0) }, uniquingKeysWith: { _, new in new })
            snapshot.events.removeAll { event in
                incoming[event.ref] != nil || (event.calendarRef == calendar && event.intersects(interval))
            }
            snapshot.events.append(contentsOf: incoming.values)
            snapshot.windowStart = interval.start
            snapshot.windowEnd = interval.end
            snapshot.lastRefresh = Date()
            snapshot.coverageByCalendar[calendar.key] = [interval]
            snapshot.syncMarks[calendar.key] = SyncMark(fullListAt: Date(),
                                                        changesSince: listedAt ?? Date().addingTimeInterval(-120))
        }
    }

    func addNudge(_ nudge: PlanNudge) {
        mutate { snapshot in
            snapshot.nudges.removeAll { $0.planID == nudge.planID }
            snapshot.nudges.append(nudge)
        }
    }

    func removeNudges(planID: String) {
        mutate { $0.nudges.removeAll { $0.planID == planID } }
    }

    func setLastAssistantLine(_ line: String?) {
        mutate { $0.lastAssistantLine = line }
    }

    /// nil clears it (after Add or discard).
    func setPendingPlan(_ draft: PlanDraft?) {
        mutate { $0.pendingPlan = draft }
    }

    /// nil clears it (after Add or discard). A new batch replaces the old one.
    func setPendingEventBatch(_ batch: PendingEventBatch?) {
        mutate { $0.pendingEventBatch = batch }
    }

    // MARK: Accounts

    /// A disconnected account: its cached events and range bookkeeping go, and the morning nudges of plans that
    /// lived only in its calendars.
    func purge(accountID: String) {
        purgeEvents(where: { $0.accountID == accountID }, coverage: { CalendarRef(key: $0)?.accountID == accountID })
    }

    /// A calendar that left the account's calendar list.
    func purge(calendar: CalendarRef) {
        purgeEvents(where: { $0.calendarRef == calendar }, coverage: { $0 == calendar.key })
    }

    /// After the single-account migration: Google events cached before events carried their calendar. Demo events
    /// and plan previews stay; the next sync lists the account's calendars again.
    func dropUnscopedGoogleEvents() {
        update { snapshot in
            let before = snapshot.events.count
            snapshot.events.removeAll { $0.accountID == nil && !$0.isDraft && !DemoData.isDemoID($0.id) }
            guard snapshot.events.count != before || !snapshot.loadedRanges.isEmpty else { return false }
            snapshot.loadedRanges = []
            return true
        }
    }

    /// Events, ranges, nudges, the pending plan and the pending batch (erase all data).
    func eraseAll() {
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forDeleting, error: &coordinationError) { url in
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func purgeEvents(where matches: (ScheduleEvent) -> Bool, coverage: (String) -> Bool) {
        update { snapshot in
            let purged = snapshot.events.filter(matches)
            let coverageKeys = snapshot.coverageByCalendar.keys.filter(coverage)
            guard !purged.isEmpty || !coverageKeys.isEmpty else { return false }
            snapshot.events.removeAll(where: matches)
            for key in coverageKeys {
                snapshot.coverageByCalendar[key] = nil
                snapshot.syncMarks[key] = nil
            }
            let remainingPlans = Set(snapshot.events.compactMap(\.planID))
            let orphaned = Set(purged.compactMap(\.planID)).subtracting(remainingPlans)
            snapshot.nudges.removeAll { orphaned.contains($0.planID) }
            return true
        }
    }

    // MARK: Helpers

    func visibilityRules() async -> VisibilityRules {
        if let accounts { return await accounts.visibilityRules() }
        var rules = VisibilityRules()
        rules.separatesDemoEvents = false
        return rules
    }

    static func stamped(_ event: ScheduleEvent, calendar: CalendarRef) -> ScheduleEvent {
        guard event.accountID != calendar.accountID || event.calendarID != calendar.calendarID else { return event }
        var event = event
        event.accountID = calendar.accountID
        event.calendarID = calendar.calendarID
        return event
    }

    // MARK: File I/O

    private func read() -> Snapshot {
        var result = Snapshot()
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { url in
            guard let data = try? Data(contentsOf: url) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            result = (try? decoder.decode(Snapshot.self, from: data)) ?? Snapshot()
        }
        return result
    }

    private func mutate(_ change: (inout Snapshot) -> Void) {
        update { snapshot in
            change(&snapshot)
            return true
        }
    }

    /// One coordinated read-modify-write. `change` returns false when it left the snapshot as it was, which skips
    /// the write. Internal for the extensions in folders the widget target does not compile (Shared/Calendar);
    /// everything else uses the named writes above.
    func update(_ change: (inout Snapshot) -> Bool) {
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: [], error: &coordinationError) { url in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            var snapshot = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Snapshot.self, from: $0) } ?? Snapshot()
            guard change(&snapshot) else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            try? encoder.encode(snapshot).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}

extension SharedStore.Snapshot {
    /// A draft the current build cannot decode (written by an older or newer version) is dropped on its own
    /// instead of failing the whole snapshot, which would also lose the local-only nudges.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = try container.decode([ScheduleEvent].self, forKey: .events)
        nudges = try container.decode([PlanNudge].self, forKey: .nudges)
        windowStart = try container.decodeIfPresent(Date.self, forKey: .windowStart)
        windowEnd = try container.decodeIfPresent(Date.self, forKey: .windowEnd)
        lastRefresh = try container.decodeIfPresent(Date.self, forKey: .lastRefresh)
        lastAssistantLine = try container.decodeIfPresent(String.self, forKey: .lastAssistantLine)
        pendingPlan = try? container.decodeIfPresent(PlanDraft.self, forKey: .pendingPlan)
        // Missing in caches written before on-demand loading; unreadable means "load again", never a lost cache.
        loadedRanges = (try? container.decodeIfPresent([DateInterval].self, forKey: .loadedRanges)) ?? []
        // Missing before multiple accounts: every calendar loads its ranges again.
        coverageByCalendar = (try? container.decodeIfPresent([String: [DateInterval]].self, forKey: .coverageByCalendar)) ?? [:]
        pendingEventBatch = try? container.decodeIfPresent(PendingEventBatch.self, forKey: .pendingEventBatch)
        // Missing before two-way sync: the next sync lists every calendar in full.
        syncMarks = (try? container.decodeIfPresent([String: SyncMark].self, forKey: .syncMarks)) ?? [:]
    }
}

/// One synced calendar's place in the Google → iPhone direction.
struct SyncMark: Codable, Hashable, Sendable {
    /// Its rolling window was last listed in full (this iPhone's clock).
    var fullListAt: Date?
    /// Google's changes up to here are in the cache (Google's clock, with a margin): the next `updatedMin`.
    var changesSince: Date?
}
