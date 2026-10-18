import Foundation

/// Where the timed events of one day go on Quick Capture's DAY timeline (App/Views/DayTimelineView.swift), like a
/// calendar app's day view: events that overlap share the width in equal columns, side by side.
///
/// Positions are minutes of the day's wall clock (0 = midnight, 1440 = the next midnight), which is what the hour
/// labels show, so on a DST day an event after the change still sits next to its hour. Pure, so the hostless tests
/// cover it.
enum DayTimelineLayout {
    /// The minutes in a day on the timeline: 00:00 to 24:00.
    static let dayMinutes: Double = 24 * 60

    /// One timed event to place.
    struct Item: Hashable, Sendable {
        var id: String
        var start: Date
        var end: Date

        init(id: String, start: Date, end: Date) {
            self.id = id
            self.start = start
            self.end = end
        }
    }

    /// Where one item goes. Columns split the width in `columns` equal parts; the item starts in `column` and covers
    /// `span` of them (more than one when the columns to its right are free while it runs).
    struct Slot: Hashable, Sendable, Identifiable {
        var id: String
        /// The item's position in the array given to `slots(for:in:calendar:minimumMinutes:)`.
        var index: Int
        /// Clipped to the day: an event from the evening before starts at 0, one running past midnight ends at 1440.
        var startMinute: Double
        var endMinute: Double
        var column: Int
        var columns: Int
        var span: Int
    }

    /// The slots of the items that show on `day` (local midnight to the next one), sorted by start; items that do
    /// not touch the day are left out. An item lasting no time shows only if it is inside the day.
    ///
    /// `minimumMinutes` is how long the shortest block looks (its minimum height): an item counts as at least that
    /// long when deciding what overlaps, so a 10-minute event and one starting 15 minutes later sit side by side
    /// instead of on top of each other. Items starting at the same minute always overlap.
    ///
    /// Overlapping items form a cluster (overlap is followed from item to item, so A–B and B–C put A, B and C in one
    /// cluster even when A and C don't meet). In a cluster, each item takes the leftmost column free at its start;
    /// every item of the cluster then has the cluster's column count, so overlapping events share the width equally.
    static func slots(for items: [Item], in day: DateInterval, calendar: Calendar,
                      minimumMinutes: Double = 0) -> [Slot] {
        var entries: [Entry] = []
        for (index, item) in items.enumerated() {
            let end = max(item.end, item.start)
            let isInstant = end == item.start
            let showsOnDay = isInstant
                ? item.start >= day.start && item.start < day.end
                : item.start < day.end && end > day.start
            guard showsOnDay else { continue }
            let startMinute = minute(of: item.start, in: day, calendar: calendar)
            let endMinute = max(startMinute, minute(of: end, in: day, calendar: calendar))
            entries.append(Entry(index: index, id: item.id, start: startMinute, end: endMinute,
                                 visualEnd: max(endMinute, startMinute + max(0, minimumMinutes))))
        }
        // By start; at the same start the longer first (it keeps the left column), then as given.
        entries.sort { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.end != rhs.end { return lhs.end > rhs.end }
            return lhs.index < rhs.index
        }

        var slots: [Slot] = []
        slots.reserveCapacity(entries.count)
        var cluster: [(entry: Entry, column: Int)] = []
        // Per column of the current cluster: the last entry placed in it.
        var columnLast: [Entry] = []
        var clusterEnd = -Double.infinity

        func closeCluster() {
            let columns = columnLast.count
            for member in cluster {
                var span = 1
                while member.column + span < columns,
                      !cluster.contains(where: { $0.column == member.column + span && $0.entry.collides(with: member.entry) }) {
                    span += 1
                }
                slots.append(Slot(id: member.entry.id, index: member.entry.index,
                                  startMinute: member.entry.start, endMinute: member.entry.end,
                                  column: member.column, columns: columns, span: span))
            }
            cluster.removeAll()
            columnLast.removeAll()
            clusterEnd = -Double.infinity
        }

        for entry in entries {
            // Sorted by start, so nothing placed yet starts later: the entry starts a new cluster once everything
            // so far has ended, unless something started at the same minute.
            if let previous = cluster.last?.entry, entry.start >= clusterEnd, entry.start > previous.start {
                closeCluster()
            }
            let column = columnLast.firstIndex { !$0.collides(with: entry) } ?? columnLast.count
            if column == columnLast.count {
                columnLast.append(entry)
            } else {
                columnLast[column] = entry
            }
            cluster.append((entry, column))
            clusterEnd = max(clusterEnd, entry.visualEnd)
        }
        closeCluster()
        return slots
    }

    /// Minutes from midnight on the wall clock of `calendar` (seconds included), 0 for anything before `day`, 1440
    /// for its end or later.
    static func minute(of date: Date, in day: DateInterval, calendar: Calendar) -> Double {
        if date <= day.start { return 0 }
        if date >= day.end { return dayMinutes }
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let minutes = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + Double(parts.second ?? 0) / 60
        return min(max(0, minutes), dayMinutes)
    }

    /// How many minutes `height` points cover at `hourHeight` points an hour. For `minimumMinutes`, pass the
    /// shortest block's height as drawn (after the gap between blocks), so blocks that don't touch on screen don't
    /// count as overlapping: back-to-back 30-minute events stay full width.
    static func minutes(spanning height: Double, hourHeight: Double) -> Double {
        hourHeight > 0 ? max(0, height) / hourHeight * 60 : 0
    }

    /// The hour the timeline of `day` opens at, with the hour line at the top: about an hour before `now` when the
    /// day is today, else before `firstStart` (where the day's timed events begin, if any), else `fallback` (08:00).
    /// "About an hour" is the hour that starts `lead` to `lead` + 60 minutes earlier, so the moment lands near the
    /// top even in a short grid (keyboard up): 12:27 opens at 11:00, 12:30 at 12:00.
    static func openingHour(day: DateInterval, now: Date, firstStart: Date?, calendar: Calendar,
                            lead: Double = 30, fallback: Int = 8) -> Int {
        let target: Double
        if now >= day.start && now < day.end {
            target = minute(of: now, in: day, calendar: calendar)
        } else if let firstStart {
            target = minute(of: firstStart, in: day, calendar: calendar)
        } else {
            return min(max(0, fallback), 23)
        }
        let hour = Int(((target - max(0, lead)) / 60).rounded(.down))
        return min(max(0, hour), 23)
    }

    private struct Entry {
        var index: Int
        var id: String
        var start: Double
        var end: Double
        /// `end`, or later for an item shorter than the shortest block.
        var visualEnd: Double

        func collides(with other: Entry) -> Bool {
            start == other.start || (start < other.visualEnd && other.start < visualEnd)
        }
    }
}
