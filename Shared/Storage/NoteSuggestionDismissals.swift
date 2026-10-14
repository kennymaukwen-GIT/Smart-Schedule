import Foundation

/// "×" on the event page's "Suggested" row: that event's note suggestions stay hidden on this iPhone. App Group
/// `UserDefaults`, key "SSNoteSuggestionDismissals": event id → when (seconds since 1970), so the app and its
/// extensions agree. Local only, never sent anywhere; the newest `maxEntries` are kept.
///
/// The key is what the caller passes: the page uses a repeating event's series id (`key(for:)`), so one "×" hides
/// the suggestions of every occurrence.
enum NoteSuggestionDismissals {
    static let defaultsKey = "SSNoteSuggestionDismissals"
    static let maxEntries = 500

    private static var defaults: UserDefaults? { UserDefaults(suiteName: AppConstants.appGroupID) }

    static func isDismissed(eventID: String) -> Bool { isDismissed(eventID: eventID, in: defaults) }
    static func dismiss(eventID: String) { dismiss(eventID: eventID, in: defaults) }
    /// Shows the suggestions again (undo).
    static func restore(eventID: String) { restore(eventID: eventID, in: defaults) }
    /// Erase all data.
    static func reset() { reset(in: defaults) }

    /// A repeating event's series, else the event: what the page dismisses.
    static func key(for event: ScheduleEvent) -> String { event.seriesID ?? event.id }

    // Explicit defaults for unit tests (a hostless test bundle has no App Group).

    static func isDismissed(eventID: String, in defaults: UserDefaults?) -> Bool {
        entries(in: defaults)[eventID] != nil
    }

    static func dismiss(eventID: String, in defaults: UserDefaults?, now: Date = Date()) {
        guard !eventID.isEmpty else { return }
        var entries = entries(in: defaults)
        entries[eventID] = now.timeIntervalSince1970
        if entries.count > maxEntries {
            let newest = entries.sorted { $0.value > $1.value }.prefix(maxEntries)
            entries = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        defaults?.set(entries, forKey: defaultsKey)
    }

    static func restore(eventID: String, in defaults: UserDefaults?) {
        var entries = entries(in: defaults)
        guard entries.removeValue(forKey: eventID) != nil else { return }
        defaults?.set(entries, forKey: defaultsKey)
    }

    static func reset(in defaults: UserDefaults?) {
        defaults?.removeObject(forKey: defaultsKey)
    }

    private static func entries(in defaults: UserDefaults?) -> [String: Double] {
        guard let stored = defaults?.dictionary(forKey: defaultsKey) else { return [:] }
        var entries: [String: Double] = [:]
        for (key, value) in stored {
            if let seconds = value as? Double { entries[key] = seconds }
            else if let number = value as? NSNumber { entries[key] = number.doubleValue }
        }
        return entries
    }
}
