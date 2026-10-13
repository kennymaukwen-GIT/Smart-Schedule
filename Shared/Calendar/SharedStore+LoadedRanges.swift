import Foundation

/// On-demand ranges: the calendars scroll to any date, and `CalendarSync.load` (or demo generation) fills in
/// whatever range comes on screen. Kept apart from `replaceWindow`, whose `windowStart` / `windowEnd` /
/// `lastRefresh` belong to the rolling sync, so nothing here moves them.
///
/// In Shared/Calendar rather than Shared/Storage because `LoadedRanges` lives here and the widget target, which
/// compiles Storage, never loads ranges.
extension SharedStore {
    /// Ranges whose events are cached: the on-demand ranges plus the rolling window.
    func coverage() -> LoadedRanges {
        let cached = snapshot()
        var ranges = LoadedRanges(cached.loadedRanges)
        if let window = cached.window { ranges.insert(window) }
        return ranges
    }

    /// Merges a listing of `interval` and records the range as loaded. Older copies of listed ids go wherever
    /// they were (an event moved here from another date).
    ///
    /// - Parameter replacingCached: true (Google) drops cached events in `interval` that the listing lacks, i.e.
    ///   deleted elsewhere. Demo mode passes false: its listing is generated, and events the demo assistant
    ///   created or deleted there exist only in this cache.
    func mergeRange(_ interval: DateInterval, with events: [ScheduleEvent], replacingCached: Bool = true) {
        update { snapshot in
            let incoming = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            snapshot.events.removeAll { event in
                incoming[event.id] != nil || (replacingCached && !event.isDraft && event.intersects(interval))
            }
            snapshot.events.append(contentsOf: incoming.values)
            var loaded = LoadedRanges(snapshot.loadedRanges)
            loaded.insert(interval)
            snapshot.loadedRanges = loaded.intervals
            return true
        }
    }

    /// Every on-demand range will be loaded again when shown; cached events stay.
    func resetLoadedRanges() {
        update { snapshot in
            guard !snapshot.loadedRanges.isEmpty else { return false }
            snapshot.loadedRanges = []
            return true
        }
    }

    /// The cache cap (`LoadedRanges.evict`). The rolling window is always kept, so are the pending plan and
    /// plan previews. Returns how many events were dropped; no write happens under the limit.
    @discardableResult
    func evictEvents(outside keep: LoadedRanges,
                     whenCountExceeds limit: Int,
                     isEvictable: @Sendable (ScheduleEvent) -> Bool = { _ in true }) -> Int {
        var dropped = 0
        update { snapshot in
            var zones = keep
            if let window = snapshot.window { zones.insert(window) }
            guard let result = LoadedRanges.evict(snapshot.events,
                                                  loaded: LoadedRanges(snapshot.loadedRanges),
                                                  keep: zones,
                                                  limit: limit,
                                                  pendingPlanID: snapshot.pendingPlan?.id,
                                                  isEvictable: isEvictable) else { return false }
            dropped = snapshot.events.count - result.events.count
            let trimmed = result.loaded.intervals
            guard dropped > 0 || trimmed != snapshot.loadedRanges else { return false }
            snapshot.events = result.events
            snapshot.loadedRanges = trimmed
            return true
        }
        return dropped
    }
}
