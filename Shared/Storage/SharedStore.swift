import Foundation

/// App Group JSON cache — the single source of truth for every surface that cannot do network I/O
/// at render time (Live Activity, widgets) and a fast local context for prompts.
///
/// Three processes write here, so every access re-reads the file under `NSFileCoordinator`.
/// The file is small (a 90-day window ≈ 50–150 KB); move to SQLite/SwiftData only if profiling says so.
actor SharedStore {
    static let shared = SharedStore()

    struct Snapshot: Codable {
        var events: [ScheduleEvent] = []
        var nudges: [PlanNudge] = []
        var windowStart: Date?
        var windowEnd: Date?
        var lastRefresh: Date?
        var lastAssistantLine: String?
    }

    private let fileURL: URL

    init(fileName: String = "schedule-cache.json") {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID)
            ?? FileManager.default.temporaryDirectory
        fileURL = container.appendingPathComponent(fileName)
    }

    // MARK: Reads

    func snapshot() -> Snapshot { read() }

    func events(in interval: DateInterval) -> [ScheduleEvent] {
        read().events.filter { $0.intersects(interval) }.sorted { $0.start < $1.start }
    }

    func event(id: String) -> ScheduleEvent? {
        read().events.first { $0.id == id }
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

    /// Replaces everything inside `interval` with a fresh server listing; keeps events outside it.
    func replaceWindow(_ interval: DateInterval, with events: [ScheduleEvent]) {
        mutate { snapshot in
            snapshot.events.removeAll { $0.intersects(interval) }
            snapshot.events.append(contentsOf: events)
            snapshot.windowStart = interval.start
            snapshot.windowEnd = interval.end
            snapshot.lastRefresh = Date()
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
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: [], error: &coordinationError) { url in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            var snapshot = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Snapshot.self, from: $0) } ?? Snapshot()
            change(&snapshot)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            try? encoder.encode(snapshot).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}
