import Foundation

/// On-demand ranges: the calendars scroll to any date, and `CalendarSync.load` (or demo generation) fills in
/// whatever range comes on screen. Kept apart from `replaceWindow`, whose `windowStart` / `windowEnd` /
/// `lastRefresh` belong to the rolling sync, so nothing here moves them.
///
/// Coverage is kept per synced calendar (`coverageByCalendar`): a newly connected account starts with none, so the
/// range on screen loads for it at once. Demo and pre-migration data use the calendar-less `loadedRanges`.
///
/// In Shared/Calendar rather than Shared/Storage because `LoadedRanges` lives here and the widget target, which
/// compiles Storage, never loads ranges.
extension SharedStore {
    /// Ranges every synced calendar has cached, so anything one calendar lacks counts as missing (and
    /// `CalendarSync.load` lists only what each calendar lacks). Demo mode, or no synced calendar: the calendar-less
    /// on-demand ranges plus the rolling window.
    func coverage() async -> LoadedRanges {
        let cached = snapshot()
        let synced = await accounts?.syncedCalendars() ?? []
        guard let first = synced.first else {
            var ranges = LoadedRanges(cached.loadedRanges)
            if let window = cached.window { ranges.insert(window) }
            return ranges
        }
        return synced.dropFirst().reduce(Self.coverage(of: first.id, in: cached)) { shared, calendar in
            shared.intersection(Self.coverage(of: calendar.id, in: cached))
        }
    }

    /// One calendar's rolling window plus its on-demand ranges.
    func coverage(for calendar: CalendarRef) -> LoadedRanges {
        Self.coverage(of: calendar, in: snapshot())
    }

    /// Merges a listing of `interval` and records the range as loaded. Older copies of listed events go wherever
    /// they were (an event moved here from another date).
    ///
    /// - Parameter replacingCached: true (Google) drops cached events in `interval` that the listing lacks, i.e.
    ///   deleted elsewhere. Demo mode passes false: its listing is generated, and events the demo assistant
    ///   created or deleted there exist only in this cache.
    func mergeRange(_ interval: DateInterval, with events: [ScheduleEvent], replacingCached: Bool = true) {
        update { snapshot in
            let incoming = Dictionary(events.map { ($0.ref, $0) }, uniquingKeysWith: { _, new in new })
            snapshot.events.removeAll { event in
                incoming[event.ref] != nil || (replacingCached && !event.isDraft && event.intersects(interval))
            }
            snapshot.events.append(contentsOf: incoming.values)
            var loaded = LoadedRanges(snapshot.loadedRanges)
            loaded.insert(interval)
            snapshot.loadedRanges = loaded.intervals
            return true
        }
    }

    /// One calendar's listing of `interval`: replaces that calendar's events there (others are left alone) and adds
    /// the range to that calendar's coverage.
    func mergeRange(_ interval: DateInterval, calendar: CalendarRef, with events: [ScheduleEvent]) {
        update { snapshot in
            let stamped = events.map { Self.stamped($0, calendar: calendar) }
            let incoming = Dictionary(stamped.map { ($0.ref, $0) }, uniquingKeysWith: { _, new in new })
            snapshot.events.removeAll { event in
                incoming[event.ref] != nil
                    || (event.calendarRef == calendar && !event.isDraft && event.intersects(interval))
            }
            snapshot.events.append(contentsOf: incoming.values)
            var covered = LoadedRanges(snapshot.coverageByCalendar[calendar.key] ?? [])
            covered.insert(interval)
            snapshot.coverageByCalendar[calendar.key] = covered.intervals
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
    /// plan previews. Every calendar's coverage is trimmed to the kept zones like the calendar-less ranges.
    /// Returns how many events were dropped; no write happens under the limit.
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
            let trimmedCoverage = snapshot.coverageByCalendar.mapValues { LoadedRanges($0).intersection(zones).intervals }
            guard dropped > 0 || trimmed != snapshot.loadedRanges || trimmedCoverage != snapshot.coverageByCalendar
            else { return false }
            snapshot.events = result.events
            snapshot.loadedRanges = trimmed
            snapshot.coverageByCalendar = trimmedCoverage
            return true
        }
        return dropped
    }

    private static func coverage(of calendar: CalendarRef, in snapshot: Snapshot) -> LoadedRanges {
        LoadedRanges(snapshot.coverageByCalendar[calendar.key] ?? [])
    }
}
