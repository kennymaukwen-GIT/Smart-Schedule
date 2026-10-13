import Foundation

/// Time ranges kept sorted and merged: overlapping or touching ranges become one, empty ones are dropped.
///
/// Bookkeeping for on-demand loading. The calendars scroll without end, so the app loads whatever range comes
/// on screen: `missing(in:)` says what is not cached (or in flight) yet, and the cache cap keeps only the
/// ranges near today and near the screen (`keepZones`, `evict`). Pure value math, so it is unit-tested directly.
/// Ranges are half-open: `end` is the first instant not covered.
struct LoadedRanges: Equatable, Sendable {
    private(set) var intervals: [DateInterval] = []

    init(_ intervals: [DateInterval] = []) {
        self.intervals = Self.merged(intervals)
    }

    var isEmpty: Bool { intervals.isEmpty }

    mutating func insert(_ interval: DateInterval) {
        intervals = Self.merged(intervals + [interval])
    }

    func union(_ other: LoadedRanges) -> LoadedRanges {
        LoadedRanges(intervals + other.intervals)
    }

    /// Takes `cut` out, splitting a range it falls inside.
    mutating func remove(_ cut: DateInterval) {
        guard cut.duration > 0 else { return }
        var result: [DateInterval] = []
        for range in intervals {
            guard range.start < cut.end && cut.start < range.end else {
                result.append(range)
                continue
            }
            if range.start < cut.start { result.append(DateInterval(start: range.start, end: cut.start)) }
            if cut.end < range.end { result.append(DateInterval(start: cut.end, end: range.end)) }
        }
        intervals = result
    }

    func intersection(_ other: LoadedRanges) -> LoadedRanges {
        var result: [DateInterval] = []
        for range in intervals {
            for zone in other.intervals {
                let start = max(range.start, zone.start)
                let end = min(range.end, zone.end)
                if start < end { result.append(DateInterval(start: start, end: end)) }
            }
        }
        return LoadedRanges(result)
    }

    func contains(_ interval: DateInterval) -> Bool {
        missing(in: interval).isEmpty
    }

    /// True when `start..<end` shares time with a range. An instant (`start == end`) counts when a range holds it.
    /// Takes two dates rather than a `DateInterval`, which traps when a malformed event ends before it starts.
    func intersects(start: Date, end: Date) -> Bool {
        intervals.contains { range in
            start < range.end && (end > range.start || start >= range.start)
        }
    }

    /// The parts of `request` no range covers, in order.
    func missing(in request: DateInterval) -> [DateInterval] {
        guard request.duration > 0 else { return [] }
        var gaps: [DateInterval] = []
        var cursor = request.start
        for range in intervals where range.end > cursor {
            if range.start >= request.end { break }
            if range.start > cursor { gaps.append(DateInterval(start: cursor, end: range.start)) }
            cursor = max(cursor, range.end)
            if cursor >= request.end { break }
        }
        if cursor < request.end { gaps.append(DateInterval(start: cursor, end: request.end)) }
        return gaps
    }

    static func merged(_ intervals: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        for interval in intervals.filter({ $0.duration > 0 }).sorted(by: { $0.start < $1.start }) {
            if let last = result.last, interval.start <= last.end {
                if interval.end > last.end { result[result.count - 1] = DateInterval(start: last.start, end: interval.end) }
            } else {
                result.append(interval)
            }
        }
        return result
    }

    // MARK: Requests

    /// What to load for a range on screen: the whole months it touches plus `padMonths` months either side,
    /// so the next swipe or two is already cached and gaps line up with month boundaries. A range on screen is
    /// days to weeks long; one longer than `maxMonths` keeps only its first `maxMonths` months, so a single call
    /// can never list decades.
    static func request(around visible: DateInterval, padMonths: Int = 1, maxMonths: Int = 12,
                        calendar: Calendar) -> DateInterval {
        var lastInstant = visible.end > visible.start ? visible.end.addingTimeInterval(-1) : visible.start
        if let limit = calendar.date(byAdding: .month, value: max(1, maxMonths), to: visible.start), lastInstant >= limit {
            lastInstant = limit.addingTimeInterval(-1)
        }
        guard let firstMonth = calendar.dateInterval(of: .month, for: visible.start),
              let lastMonth = calendar.dateInterval(of: .month, for: lastInstant),
              let start = calendar.date(byAdding: .month, value: -padMonths, to: firstMonth.start),
              let end = calendar.date(byAdding: .month, value: padMonths, to: lastMonth.end),
              end > start else { return visible }
        return DateInterval(start: start, end: end)
    }

    // MARK: Cache cap

    /// Each anchor widened by `months` calendar months both ways: what the cache cap never drops.
    static func keepZones(around anchors: [DateInterval], months: Int, calendar: Calendar) -> LoadedRanges {
        LoadedRanges(anchors.compactMap { anchor -> DateInterval? in
            guard let start = calendar.date(byAdding: .month, value: -months, to: anchor.start),
                  let end = calendar.date(byAdding: .month, value: months, to: anchor.end) else { return nil }
            return DateInterval(start: start, end: max(start, end))
        })
    }

    /// The cache cap. Once there are more than `limit` events, drops those touching no `keep` zone, except plan
    /// previews (`isDraft`), the pending plan's events and whatever `isEvictable` refuses, and trims `loaded` to
    /// `keep` so a dropped range is loaded again when it comes back on screen. nil when under the limit.
    static func evict(_ events: [ScheduleEvent],
                      loaded: LoadedRanges,
                      keep: LoadedRanges,
                      limit: Int,
                      pendingPlanID: String?,
                      isEvictable: (ScheduleEvent) -> Bool = { _ in true }) -> (events: [ScheduleEvent], loaded: LoadedRanges)? {
        guard events.count > limit else { return nil }
        let kept = events.filter { event in
            if event.isDraft || keep.intersects(start: event.start, end: event.end) { return true }
            if let pendingPlanID, event.planID == pendingPlanID { return true }
            return !isEvictable(event)
        }
        return (kept, loaded.intersection(keep))
    }
}
