import Foundation

/// App Group JSON cache — the single source of truth for every surface that cannot do network I/O
/// at render time (Live Activity, widgets) and a fast local context for prompts.
///
/// Three processes write here, so every access re-reads the file under `NSFileCoordinator`.
/// The file is small (a 90-day window ≈ 50–150 KB; ranges loaded on demand are capped by
/// `ScheduleViewModel.maxCachedEvents`); move to SQLite/SwiftData only if profiling says so.
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
        /// Ranges outside the rolling window whose events were loaded on demand (sorted, merged). Written by the
        /// app only (Shared/Calendar/SharedStore+LoadedRanges.swift); `replaceWindow` empties it.
        var loadedRanges: [DateInterval] = []

        /// The rolling sync window (`windowStart ..< windowEnd`), when a sync or the demo seed has set one.
        var window: DateInterval? {
            guard let windowStart, let windowEnd, windowEnd > windowStart else { return nil }
            return DateInterval(start: windowStart, end: windowEnd)
        }
    }

    private let fileURL: URL

    init(fileName: String = "schedule-cache.json") {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID)
            ?? FileManager.default.temporaryDirectory
        fileURL = container.appendingPathComponent(fileName)
    }

    /// A cache at an explicit location. Unit tests use a temporary file, since a hostless test bundle has no
    /// App Group entitlement.
    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: Reads

    func snapshot() -> Snapshot { read() }

    func events(in interval: DateInterval) -> [ScheduleEvent] {
        read().events.filter { $0.intersects(interval) }.sorted { $0.start < $1.start }
    }

    func event(id: String) -> ScheduleEvent? {
        read().events.first { $0.id == id }
    }

    func pendingPlan() -> PlanDraft? {
        read().pendingPlan
    }

    // MARK: Writes

    func upsert(_ events: [ScheduleEvent]) {
        mutate { snapshot in
            let incoming = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            snapshot.events.removeAll { incoming[$0.id] != nil }
            snapshot.events.append(contentsOf: incoming.values)
        }
    }

    func remove(ids: Set<String>, seriesIDs: Set<String> = []) {
        mutate { snapshot in
            snapshot.events.removeAll { ids.contains($0.id) || ($0.seriesID.map { seriesIDs.contains($0) } ?? false) }
        }
    }

    /// Replaces everything inside `interval` with a fresh server listing; keeps events outside it, except older
    /// copies of listed ids (an event moved into the window from a range loaded on demand).
    ///
    /// Also forgets the on-demand ranges: their events stay cached and on screen, but each range is listed again
    /// the next time it is shown, so edits made elsewhere reach far dates too.
    func replaceWindow(_ interval: DateInterval, with events: [ScheduleEvent]) {
        mutate { snapshot in
            let incoming = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            snapshot.events.removeAll { $0.intersects(interval) || incoming[$0.id] != nil }
            snapshot.events.append(contentsOf: incoming.values)
            snapshot.windowStart = interval.start
            snapshot.windowEnd = interval.end
            snapshot.lastRefresh = Date()
            snapshot.loadedRanges = []
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
    }
}
