import Foundation

/// Two-way sync bookkeeping on the cache: "changed since" passes, the outbox's waiting changes drawn on top of
/// every listing, and Google's copy taking over once a change is confirmed. In Shared/Calendar because the logic
/// (`IncrementalChanges`, `OutboxOverlay`) lives here and the widget target never syncs.
extension SharedStore {
    func syncMark(for calendar: CalendarRef) -> SyncMark? {
        snapshot().syncMarks[calendar.key]
    }

    /// Applies one calendar's "changed since" listing and moves its mark to `changesSince`. True when the cache's
    /// events changed.
    @discardableResult
    func applyChanges(_ changes: [GCalEvent], calendar: CalendarRef, known: [CalendarInfo],
                      mapper: CalendarEventMapper, changesSince: Date) -> Bool {
        var changed = false
        update { snapshot in
            if let result = IncrementalChanges.apply(changes, calendar: calendar, known: known,
                                                     to: snapshot.events, mapper: mapper) {
                snapshot.events = result
                changed = true
            }
            var mark = snapshot.syncMarks[calendar.key] ?? SyncMark()
            mark.changesSince = changesSince
            snapshot.syncMarks[calendar.key] = mark
            return true
        }
        return changed
    }

    /// Draws the outbox's waiting changes over the cache: after every listing (which brought Google's version
    /// back) and when a change is queued.
    func applyPending(_ items: [OutboxItem], mapper: CalendarEventMapper, horizon: Date) {
        let waiting = items.filter { !$0.isFailed }
        guard !waiting.isEmpty else { return }
        update { snapshot in
            let result = OutboxOverlay.apply(waiting, to: snapshot.events, mapper: mapper, horizon: horizon)
            guard result != snapshot.events else { return false }
            snapshot.events = result
            return true
        }
    }

    /// Google confirmed a change of `eventID`: its optimistic copies (and queued series instances) are replaced by
    /// `saved`, Google's copies. nil keeps them and only clears their waiting mark, for a series whose instances the
    /// caller lists again (the listing replaces them).
    func confirmPending(calendar: CalendarRef, eventID: String, replacingWith saved: [ScheduleEvent]?) {
        update { snapshot in
            let isOptimistic: (ScheduleEvent) -> Bool = { event in
                event.isWaitingToSync && OutboxOverlay.belongs(event, to: calendar)
                    && (event.id == eventID || event.seriesID == eventID)
            }
            guard let saved else {
                var changed = false
                for index in snapshot.events.indices where isOptimistic(snapshot.events[index]) {
                    snapshot.events[index].isPendingSync = nil
                    changed = true
                }
                return changed
            }
            snapshot.events.removeAll(where: isOptimistic)
            let incoming = Dictionary(saved.map { ($0.ref, $0) }, uniquingKeysWith: { _, new in new })
            snapshot.events.removeAll { incoming[$0.ref] != nil }
            snapshot.events.append(contentsOf: incoming.values)
            return true
        }
    }
}
