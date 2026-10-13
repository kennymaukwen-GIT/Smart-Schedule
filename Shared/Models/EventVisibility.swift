import Foundation

/// What `EventVisibility.apply` needs to know about the calendars, from `AccountStore.visibilityRules()`.
/// Keys are `CalendarRef.key`.
struct VisibilityRules: Sendable {
    var isDemoMode = false
    var hidden: Set<String> = []                 // CalendarRef.key the user hid
    var muted: Set<String> = []                  // notifications off
    var focusAllowed: Set<String>? = nil         // nil = no Focus filter active
    var calendarColors: [String: String] = [:]   // key → displayColorHex
    var writable: Set<String> = []
    /// Every known calendar: lower wins de-duplication ties (account order, then calendar order).
    var rank: [String: Int] = [:]
    /// The default write target's key: the third de-duplication tie-break.
    var defaultTarget: String? = nil
    /// False shows demo and Google events side by side, as before demo mode was tied to accounts. Only a store
    /// without an `AccountStore` (unit tests) uses it.
    var separatesDemoEvents = true

    init() {}
}

/// Which cached events a surface shows: per-calendar visibility, notifications and the Focus filter, the local
/// colour override, and one copy of a meeting that several connected accounts see. Pure, so it is unit-tested.
enum EventVisibility {
    /// Filters by audience, re-colours `usesCalendarColor` events, de-duplicates, sorts by start.
    static func apply(_ events: [ScheduleEvent], rules: VisibilityRules, audience: EventAudience) -> [ScheduleEvent] {
        let shown = events.compactMap { event -> ScheduleEvent? in
            guard isVisible(event, rules: rules, audience: audience) else { return nil }
            guard event.usesCalendarColor == true, let key = event.calendarRef?.key,
                  let color = rules.calendarColors[key], color != event.colorHex else { return event }
            var recoloured = event
            recoloured.colorHex = color
            return recoloured
        }
        return deduplicated(shown, rules: rules).sorted { $0.start < $1.start }
    }

    static func isVisible(_ event: ScheduleEvent, rules: VisibilityRules, audience: EventAudience) -> Bool {
        if rules.separatesDemoEvents && !event.isDraft {
            // Demo mode shows only sample data; outside it, leftover sample data never shows.
            guard DemoData.isDemoID(event.id) == rules.isDemoMode else { return false }
        }
        // Unknown calendar (no calendar, or one the account store does not list): visible and reminded.
        guard let key = event.calendarRef?.key else { return true }
        if rules.hidden.contains(key) { return false }
        if let allowed = rules.focusAllowed, rules.rank[key] != nil, !allowed.contains(key) { return false }
        if audience == .reminders, rules.muted.contains(key) { return false }
        return true
    }

    // MARK: De-duplication

    /// One meeting seen through two accounts is one event: copies are grouped by iCalUID and start (events without
    /// an iCalUID by id), and groups sharing a raw id are merged too, so the visible list never holds an id twice.
    /// Losers stay in the cache and come back when the winner's calendar is hidden.
    static func deduplicated(_ events: [ScheduleEvent], rules: VisibilityRules) -> [ScheduleEvent] {
        guard events.count > 1 else { return events }
        var parent = Array(events.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        func union(_ lhs: Int, _ rhs: Int) {
            let a = root(lhs), b = root(rhs)
            if a != b { parent[max(a, b)] = min(a, b) }
        }

        var firstByKey: [String: Int] = [:]
        for (index, event) in events.enumerated() {
            var keys = ["id|" + event.id]
            if let uid = event.iCalUID, !uid.isEmpty { keys.append("uid|\(uid)|\(event.start.timeIntervalSince1970)") }
            for key in keys {
                if let first = firstByKey[key] { union(first, index) } else { firstByKey[key] = index }
            }
        }

        var winner: [Int: Int] = [:]   // group root → index of the copy shown
        for index in events.indices {
            let group = root(index)
            if let current = winner[group] {
                if beats(events[index], events[current], rules: rules) { winner[group] = index }
            } else {
                winner[group] = index
            }
        }
        let kept = Set(winner.values)
        return events.indices.filter { kept.contains($0) }.map { events[$0] }
    }

    /// Organizer's copy, then a writable calendar's, then the default write target's, then account and calendar order.
    private static func beats(_ candidate: ScheduleEvent, _ current: ScheduleEvent, rules: VisibilityRules) -> Bool {
        let a = candidate.calendarRef?.key, b = current.calendarRef?.key
        let organizer = (candidate.isOrganizer == true, current.isOrganizer == true)
        if organizer.0 != organizer.1 { return organizer.0 }
        let writable = (a.map { rules.writable.contains($0) } ?? false, b.map { rules.writable.contains($0) } ?? false)
        if writable.0 != writable.1 { return writable.0 }
        let target = (a != nil && a == rules.defaultTarget, b != nil && b == rules.defaultTarget)
        if target.0 != target.1 { return target.0 }
        let rank = (a.flatMap { rules.rank[$0] } ?? Int.max, b.flatMap { rules.rank[$0] } ?? Int.max)
        return rank.0 < rank.1
    }
}
