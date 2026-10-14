import Foundation

// Pure two-way sync logic, unit-tested: queued changes shown on top of the cache, a change re-applied after a 412,
// and a "changed since" listing applied to the cache.

extension GCalEvent {
    /// These fields with `patch`'s non-nil fields on top (PATCH semantics); private and shared extended properties
    /// are merged key by key, as Google does.
    func overlaid(with patch: GCalEvent) -> GCalEvent {
        var result = self
        if let value = patch.id { result.id = value }
        if let value = patch.status { result.status = value }
        if let value = patch.summary { result.summary = value }
        if let value = patch.description { result.description = value }
        if let value = patch.location { result.location = value }
        if let value = patch.colorId { result.colorId = value }
        if let value = patch.start { result.start = value }
        if let value = patch.end { result.end = value }
        if let value = patch.recurrence { result.recurrence = value }
        if let value = patch.recurringEventId { result.recurringEventId = value }
        if let value = patch.reminders { result.reminders = value }
        if let value = patch.attendees { result.attendees = value }
        if let value = patch.conferenceData { result.conferenceData = value }
        if let value = patch.extendedProperties {
            var merged = result.extendedProperties ?? GCalExtendedProperties()
            if let values = value.private {
                merged.private = (merged.private ?? [:]).merging(values) { _, new in new }
            }
            if let values = value.shared {
                merged.shared = (merged.shared ?? [:]).merging(values) { _, new in new }
            }
            result.extendedProperties = merged
        }
        if let value = patch.hangoutLink { result.hangoutLink = value }
        if let value = patch.htmlLink { result.htmlLink = value }
        if let value = patch.iCalUID { result.iCalUID = value }
        if let value = patch.organizer { result.organizer = value }
        if let value = patch.etag { result.etag = value }
        if let value = patch.updated { result.updated = value }
        return result
    }
}

/// The cache as the user expects it while changes wait in the outbox.
enum OutboxOverlay {
    /// Queued inserts present (weekly series expanded through `horizon`, as Google's `singleEvents` would), edits
    /// applied, deletions gone; every copy touched is marked `isPendingSync`. Failed items are skipped, so the next
    /// listing rolls their optimistic change back.
    static func apply(_ items: [OutboxItem], to cached: [ScheduleEvent], mapper: CalendarEventMapper,
                      horizon: Date) -> [ScheduleEvent] {
        var events = cached
        for item in items where !item.isFailed {
            switch item.kind {
            case .insert:
                guard let body = item.body else { continue }
                events.removeAll { belongs($0, to: item.calendar) && ($0.id == item.eventID || $0.seriesID == item.eventID) }
                events += inserted(body, calendar: item.calendar, mapper: mapper, horizon: horizon)
            case .patch:
                guard let body = item.body else { continue }
                for index in events.indices where belongs(events[index], to: item.calendar) && events[index].id == item.eventID {
                    events[index] = applying(body, to: events[index], clock: mapper.clock)
                    events[index].isPendingSync = true
                }
            case .patchSeries:
                var fields = item.body ?? GCalEvent()
                // The master's absolute times do not fit each instance; `seriesTime` moves them instead.
                fields.start = nil
                fields.end = nil
                for index in events.indices where belongs(events[index], to: item.calendar)
                    && (events[index].seriesID == item.eventID || events[index].id == item.eventID) {
                    var event = applying(fields, to: events[index], clock: mapper.clock)
                    if let time = item.seriesTime { move(&event, to: time, clock: mapper.clock) }
                    event.isPendingSync = true
                    events[index] = event
                }
            case .delete:
                events.removeAll { belongs($0, to: item.calendar) && ($0.id == item.eventID || $0.seriesID == item.eventID) }
            }
        }
        // A queued insert is drawn from its body, which has no note suggestions: keep the cached copy's.
        ScheduleEvent.keepingLocalFields(&events, from: cached)
        return events
    }

    /// The copy lives in `calendar`; for the pre-migration sign-in (`accountID == ""`), copies cached without one.
    static func belongs(_ event: ScheduleEvent, to calendar: CalendarRef) -> Bool {
        if calendar.accountID.isEmpty { return event.accountID == nil }
        return event.accountID == calendar.accountID && event.calendarID == calendar.calendarID
    }

    /// The fields a PATCH body sets, applied to a cached copy.
    static func applying(_ patch: GCalEvent, to event: ScheduleEvent, clock: WallClock) -> ScheduleEvent {
        var event = event
        if let summary = patch.summary { event.title = summary }
        if let location = patch.location { event.location = location.isEmpty ? nil : location }
        if let description = patch.description { event.notes = EventNotes.plainText(fromDescription: description) }
        if let colorID = patch.colorId, let hex = GoogleColor.palette[colorID] {
            event.colorHex = hex
            event.usesCalendarColor = false
        }
        if let start = patch.start.flatMap({ instant($0, clock: clock) }) {
            let length = event.duration
            event.start = start.date
            event.isAllDay = start.isAllDay
            if patch.end == nil { event.end = start.date.addingTimeInterval(length) }
        }
        if let end = patch.end.flatMap({ instant($0, clock: clock) }) { event.end = end.date }
        if event.end <= event.start { event.end = event.start.addingTimeInterval(event.isAllDay ? 86_400 : 300) }
        if patch.reminders != nil || patch.extendedProperties?.private?[SSProperty.localReminders] != nil {
            var reminders = GCalEvent()
            reminders.reminders = patch.reminders
            reminders.extendedProperties = patch.extendedProperties
            event.reminderMinutes = CalendarEventMapper.reminderMinutes(of: reminders)
        }
        return event
    }

    /// `2026-10-15` (all day) or a `dateTime`.
    static func instant(_ value: GCalDateTime, clock: WallClock) -> (date: Date, isAllDay: Bool)? {
        if let day = value.date, let date = clock.date(day) { return (date, true) }
        if let raw = value.dateTime, let date = WallClock.parseRFC3339(raw) ?? clock.dateTime(raw) { return (date, false) }
        return nil
    }

    private static func inserted(_ body: GCalEvent, calendar: CalendarRef, mapper: CalendarEventMapper,
                                 horizon: Date) -> [ScheduleEvent] {
        var events = body.recurrence == nil ? [] : RecurrenceExpander.instances(of: body, through: horizon, idPrefix: "", mapper: mapper)
        if events.isEmpty, let single = mapper.scheduleEvent(from: body) { events = [single] }
        return events.map { instance in
            var event = instance
            if !calendar.accountID.isEmpty {
                event.accountID = calendar.accountID
                event.calendarID = calendar.calendarID
            }
            event.usesCalendarColor = body.colorId == nil
            event.isPendingSync = true
            return event
        }
    }

    /// An occurrence of a series moved to `time`'s time of day on its own date, `time.duration` long (all-day
    /// occurrences stay as they are).
    static func move(_ event: inout ScheduleEvent, to time: OutboxItem.SeriesTime, clock: WallClock) {
        guard !event.isAllDay else { return }
        let calendar = clock.calendar
        let parts = calendar.dateComponents([.hour, .minute], from: time.newStart)
        guard let start = calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: event.start)
        else { return }
        event.start = start
        event.end = start.addingTimeInterval(max(time.duration, 300))
    }
}

/// Google answered 412: the event changed there since the etag the user's change was based on.
enum ConflictMerge {
    /// The user's change re-applied on top of Google's current copy: only the fields the change sets that differ
    /// from `fresh` (so Google's edits to every other field stay). When the user moved the event without changing
    /// its length and Google has since changed the length, the new end keeps Google's length. A start that moves
    /// always sends its end too. nil when Google already has everything the change sets.
    static func rebase(_ change: GCalEvent, base: ScheduleEvent?, onto fresh: GCalEvent,
                       mapper: CalendarEventMapper) -> GCalEvent? {
        let clock = mapper.clock
        var result = GCalEvent()
        if let value = change.summary, value != fresh.summary { result.summary = value }
        if let value = change.description, value != (fresh.description ?? "") { result.description = value }
        if let value = change.location, value != (fresh.location ?? "") { result.location = value }
        if let value = change.colorId, value != fresh.colorId { result.colorId = value }
        if let value = change.reminders, value != fresh.reminders { result.reminders = value }
        if let value = change.attendees, value != fresh.attendees { result.attendees = value }
        if let values = change.extendedProperties?.private {
            let current = fresh.extendedProperties?.private ?? [:]
            let differing = values.filter { current[$0.key] != $0.value }
            if !differing.isEmpty { result.extendedProperties = GCalExtendedProperties(private: differing) }
        }

        if change.start != nil || change.end != nil {
            let start = change.start ?? fresh.start
            var end = change.end ?? fresh.end
            if let newStart = change.start.flatMap({ OutboxOverlay.instant($0, clock: clock) }),
               let freshStart = fresh.start.flatMap({ OutboxOverlay.instant($0, clock: clock) }),
               let freshEnd = fresh.end.flatMap({ OutboxOverlay.instant($0, clock: clock) }),
               !newStart.isAllDay, !freshStart.isAllDay {
                let freshLength = freshEnd.date.timeIntervalSince(freshStart.date)
                if let newEnd = change.end.flatMap({ OutboxOverlay.instant($0, clock: clock) }) {
                    let keptLength = base.map { !$0.isAllDay && abs(newEnd.date.timeIntervalSince(newStart.date) - $0.duration) < 1 } ?? false
                    if keptLength, let base, freshLength > 0, abs(freshLength - base.duration) >= 1 {
                        end = mapper.timed(newStart.date.addingTimeInterval(freshLength))
                    }
                } else if freshLength > 0 {
                    // A new start alone keeps the length Google has.
                    end = mapper.timed(newStart.date.addingTimeInterval(freshLength))
                }
            }
            if !sameTime(start, fresh.start, clock: clock) { result.start = start }
            if result.start != nil || !sameTime(end, fresh.end, clock: clock) { result.end = end }
        }
        return result == GCalEvent() ? nil : result
    }

    private static func sameTime(_ lhs: GCalDateTime?, _ rhs: GCalDateTime?, clock: WallClock) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        guard let left = OutboxOverlay.instant(lhs, clock: clock), let right = OutboxOverlay.instant(rhs, clock: clock)
        else { return lhs == rhs }
        return left.isAllDay == right.isAllDay && abs(left.date.timeIntervalSince(right.date)) < 1
    }
}

/// A calendar's "changed since" listing (`updatedMin` + `showDeleted`, recurrences expanded) applied to the cache.
enum IncrementalChanges {
    /// Cancelled entries remove that copy (and the instances of a cancelled series); others replace the cached copy
    /// or are added. Other calendars' copies are untouched; a calendar not in `known` (removed meanwhile) is
    /// ignored. nil when nothing changed.
    static func apply(_ changes: [GCalEvent], calendar: CalendarRef, known: [CalendarInfo],
                      to events: [ScheduleEvent], mapper: CalendarEventMapper) -> [ScheduleEvent]? {
        guard let info = known.first(where: { $0.id == calendar }) else { return nil }
        var result = events
        var changed = false
        for change in changes {
            guard let id = change.id else { continue }
            if change.status == "cancelled" {
                let before = result.count
                result.removeAll { $0.calendarRef == calendar && ($0.id == id || $0.seriesID == id) }
                if result.count != before { changed = true }
            } else if var mapped = mapper.scheduleEvent(from: change, in: info) {
                if let index = result.firstIndex(where: { $0.ref == mapped.ref }) {
                    // Google's copy has no note suggestions (local only): they are no change.
                    mapped.suggestedNotes = mapped.suggestedNotes ?? result[index].suggestedNotes
                    if result[index] != mapped {
                        result[index] = mapped
                        changed = true
                    }
                } else {
                    result.append(mapped)
                    changed = true
                }
            }
        }
        return changed ? result : nil
    }

    /// A series re-timed or extended in Google gives its instances new ids (an instance id carries its original
    /// start) and the old instances are not reported as cancelled, so a new instance of a series already cached
    /// calls for a full listing instead.
    static func reshapesSeries(_ changes: [GCalEvent], calendar: CalendarRef, cached: [ScheduleEvent]) -> Bool {
        let mine = cached.filter { $0.calendarRef == calendar }
        let ids = Set(mine.map(\.id))
        let series = Set(mine.compactMap(\.seriesID))
        return changes.contains { change in
            guard change.status != "cancelled", let id = change.id, let seriesID = change.recurringEventId else {
                return false
            }
            return series.contains(seriesID) && !ids.contains(id)
        }
    }
}
