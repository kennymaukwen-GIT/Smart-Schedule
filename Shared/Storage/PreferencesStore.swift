import Foundation

/// Settings, "What the assistant remembers" (the ledger), learned suggestions and dismiss streaks, kept in the
/// App Group file `preferences.json` so the app and both extensions share them.
///
/// `current()` is a synchronous, cached read for `WallClock()` and every other non-async caller. The cache is
/// replaced after this store's own writes and dropped when any process posts `.preferences`. Writes are
/// coordinated read-modify-writes like `SharedStore`'s and post `.preferences`.
actor PreferencesStore {
    static let shared = PreferencesStore()

    struct Document: Codable {
        static let currentVersion = 1

        var version = Document.currentVersion
        var preferences = AppPreferences()
        /// Newest first.
        var ledger: [LedgerEntry] = []
        var suggestions: [LearnedSuggestion] = []
        /// `LearnedSuggestion.streakKey` → consecutive dismissals without opening, snoozing or replying.
        var dismissStreaks: [String: Int] = [:]

        init() {}

        /// Unreadable parts fall back to their defaults one by one; a ledger line or suggestion this build cannot
        /// read is dropped on its own.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = c.preferenceValue(.version, default: Document.currentVersion)
            preferences = c.preferenceValue(.preferences, default: AppPreferences())
            ledger = c.preferenceValue(.ledger, default: [PreferenceLossy<LedgerEntry>]()).compactMap(\.value)
            suggestions = c.preferenceValue(.suggestions, default: [PreferenceLossy<LearnedSuggestion>]()).compactMap(\.value)
            dismissStreaks = c.preferenceValue(.dismissStreaks, default: [:])
        }
    }

    private let fileURL: URL
    private let cache: Cache
    private let observation: SharedChangeObservation

    init(fileName: String = "preferences.json") {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID)
            ?? FileManager.default.temporaryDirectory
        fileURL = container.appendingPathComponent(fileName)
        let cache = Cache()
        self.cache = cache
        observation = PreferencesStore.invalidating(cache)
    }

    /// A store at an explicit location. Unit tests use a temporary file, since a hostless test bundle has no
    /// App Group entitlement.
    init(fileURL: URL) {
        self.fileURL = fileURL
        let cache = Cache()
        self.cache = cache
        observation = PreferencesStore.invalidating(cache)
    }

    private static func invalidating(_ cache: Cache) -> SharedChangeObservation {
        SharedChangeNotifier.observe(.preferences) { cache.invalidate() }
    }

    // MARK: Reads

    /// Cached; reads the file only when the cache is empty (first use, or another process changed it).
    nonisolated func current() -> AppPreferences {
        let (cached, generation) = cache.read()
        if let cached { return cached }
        let preferences = Self.load(from: fileURL).preferences
        cache.fill(preferences, generation: generation)
        return preferences
    }

    /// "What the assistant remembers", newest first: at most one line per key, only for keys not at their default.
    func ledger() -> [LedgerEntry] {
        let document = Self.load(from: fileURL)
        let defaults = AppPreferences()
        var seen: Set<PreferenceKey> = []
        return document.ledger.sorted { $0.date > $1.date }.filter { entry in
            document.preferences.canonicalValue(for: entry.key) != defaults.canonicalValue(for: entry.key)
                && seen.insert(entry.key).inserted
        }
    }

    func pendingSuggestions() -> [LearnedSuggestion] {
        Self.load(from: fileURL).suggestions.filter { $0.status == .pending }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Pending suggestions the chat has not shown as a card yet.
    func suggestionsToShowInChat() -> [LearnedSuggestion] {
        pendingSuggestions().filter { !$0.shownInChat }
    }

    /// Every suggestion ever made, whatever its status (export).
    func allSuggestions() -> [LearnedSuggestion] {
        Self.load(from: fileURL).suggestions.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: Changing preferences

    /// One write. Every `PreferenceKey` is diffed before/after `change`: the ledger gets one line per changed key
    /// (removed when the key is back at its default) and the receipt lists the changes. nil when no key changed
    /// (other settings, such as the Dynamic Island lead time, are still saved). `change` must not read this store.
    @discardableResult
    func update(source: LedgerSource = .settings,
                _ change: @Sendable (inout AppPreferences) -> Void) -> PreferenceChangeReceipt? {
        var receipt: PreferenceChangeReceipt?
        var wrote = false
        transact { document in
            var preferences = document.preferences
            change(&preferences)
            guard preferences != document.preferences else { return false }
            receipt = Self.record(from: document.preferences, to: preferences, source: source, in: &document)
            document.preferences = preferences
            wrote = true
            return true
        }
        if wrote { SharedChangeNotifier.post(.preferences) }
        return receipt
    }

    /// `update_preferences`: normalises each model value, resolves default_calendar through `resolveCalendar`,
    /// applies every valid change in one write and returns the receipt (nil when nothing changed) plus rejections.
    /// A change to the value already set is dropped silently.
    func apply(_ requests: [PreferenceChangeRequest],
               source: LedgerSource,
               resolveCalendar: @Sendable (String) async -> CalendarChoice?) async -> PreferenceApplyResult {
        // Calendars first: the resolver is async, the coordinated write below is not.
        var calendarValues: [Int: Result<String, PreferenceValueError>] = [:]
        for (index, request) in requests.enumerated() where request.key == .defaultCalendar {
            let text = request.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.lowercased() == "automatic" {
                calendarValues[index] = .success("automatic")
            } else if let choice = await resolveCalendar(text) {
                calendarValues[index] = .success(choice.ref.key + "|" + choice.label)
            } else {
                calendarValues[index] = .failure(.invalid("no writable calendar matches “\(text)”"))
            }
        }

        var rejected: [PreferenceRejection] = []
        var receipt: PreferenceChangeReceipt?
        transact { document in
            rejected = []
            var preferences = document.preferences
            for (index, request) in requests.enumerated() {
                do {
                    // Normalised against the values so far, so "on" / "off" keep times set earlier in the batch.
                    let canonical = try calendarValues[index]?.get() ?? preferences.normalized(request.value, for: request.key)
                    try preferences.apply(canonical: canonical, for: request.key)
                } catch {
                    let reason = (error as? PreferenceValueError)?.reason ?? "invalid value"
                    rejected.append(PreferenceRejection(key: request.key.rawValue, value: request.value, reason: reason))
                }
            }
            guard preferences != document.preferences else { return false }
            receipt = Self.record(from: document.preferences, to: preferences, source: source, in: &document)
            document.preferences = preferences
            return true
        }
        if receipt != nil { SharedChangeNotifier.post(.preferences) }
        return PreferenceApplyResult(receipt: receipt, rejected: rejected)
    }

    /// Restores every key whose value still equals the receipt's `newValue` (the old value and its old ledger line).
    /// False when nothing could be restored because each key changed again since.
    @discardableResult
    func undo(_ receipt: PreferenceChangeReceipt) -> Bool {
        var restored = false
        transact { document in
            var preferences = document.preferences
            for change in receipt.changes where preferences.canonicalValue(for: change.key) == change.newValue {
                guard (try? preferences.apply(canonical: change.oldValue, for: change.key)) != nil else { continue }
                document.ledger.removeAll { $0.key == change.key }
                if let replaced = change.replacedEntry { document.ledger.append(replaced) }
                restored = true
            }
            guard restored else { return false }
            document.ledger.sort { $0.date > $1.date }
            document.preferences = preferences
            return true
        }
        if restored { SharedChangeNotifier.post(.preferences) }
        return restored
    }

    /// Deleting a line of "What the assistant remembers" puts that setting back to its default.
    func deleteLedgerEntry(id: UUID) {
        var wrote = false
        transact { document in
            guard let entry = document.ledger.first(where: { $0.id == id }) else { return false }
            document.ledger.removeAll { $0.key == entry.key }
            document.preferences.reset(entry.key)
            wrote = true
            return true
        }
        if wrote { SharedChangeNotifier.post(.preferences) }
    }

    // MARK: Learned suggestions

    /// Counts consecutive dismissals per (kind, offset). At `LearnedSuggestion.dismissThreshold` in a row, while
    /// the offset is still one of that kind's defaults, creates the one pending suggestion that key will ever get
    /// and returns it. Engaging (opening, snoozing, replying) resets the streak.
    @discardableResult
    func recordReminderOutcome(kind: ScheduleEvent.Kind,
                               offsetMinutes: Int,
                               isAllDay: Bool,
                               dismissed: Bool) -> LearnedSuggestion? {
        let key = LearnedSuggestion.streakKey(kind: kind, offsetMinutes: offsetMinutes, isAllDay: isAllDay)
        var created: LearnedSuggestion?
        transact { document in
            let previous = document.dismissStreaks[key] ?? 0
            guard dismissed else {
                guard previous != 0 else { return false }
                document.dismissStreaks[key] = nil
                return true
            }
            let count = previous + 1
            document.dismissStreaks[key] = count
            if count >= LearnedSuggestion.dismissThreshold,
               !document.suggestions.contains(where: { $0.streakKey == key }),
               Self.isDefaultReminder(offsetMinutes, kind: kind, isAllDay: isAllDay, in: document.preferences) {
                let suggestion = LearnedSuggestion(id: UUID(), kind: kind, offsetMinutes: offsetMinutes, isAllDay: isAllDay,
                                                   dismissCount: count, createdAt: Date(), status: .pending,
                                                   shownInChat: false)
                document.suggestions.append(suggestion)
                created = suggestion
            }
            return true
        }
        if created != nil { SharedChangeNotifier.post(.preferences) }
        return created
    }

    func markShownInChat(_ ids: [UUID]) {
        let ids = Set(ids)
        transact { document in
            var changed = false
            for index in document.suggestions.indices
            where ids.contains(document.suggestions[index].id) && !document.suggestions[index].shownInChat {
                document.suggestions[index].shownInChat = true
                changed = true
            }
            return changed
        }
    }

    /// "Stop it" removes that offset from the kind's defaults (all-day: no all-day reminder) with ledger source
    /// `.learned` and returns the receipt; "Keep" only marks the suggestion declined. nil when nothing changed.
    @discardableResult
    func resolveSuggestion(id: UUID, accept: Bool) -> PreferenceChangeReceipt? {
        var receipt: PreferenceChangeReceipt?
        transact { document in
            guard let index = document.suggestions.firstIndex(where: { $0.id == id && $0.status == .pending }) else {
                return false
            }
            let suggestion = document.suggestions[index]
            document.suggestions[index].status = accept ? .accepted : .declined
            document.dismissStreaks[suggestion.streakKey] = nil
            guard accept else { return true }
            var preferences = document.preferences
            if suggestion.isAllDay {
                preferences.allDayReminderMinutes = nil
            } else {
                let remaining = preferences.reminders(for: suggestion.kind).filter { $0 != suggestion.offsetMinutes }
                preferences.setReminders(remaining, for: suggestion.kind)
            }
            receipt = Self.record(from: document.preferences, to: preferences, source: .learned, in: &document)
            document.preferences = preferences
            return true
        }
        if receipt != nil { SharedChangeNotifier.post(.preferences) }
        return receipt
    }

    // MARK: Erase

    /// Deletes the file; every preference is back at its default, the ledger and suggestions are gone.
    func eraseAll() {
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forDeleting, error: &coordinationError) { url in
            try? FileManager.default.removeItem(at: url)
        }
        cache.store(AppPreferences())
        SharedChangeNotifier.post(.preferences)
    }

    // MARK: Ledger bookkeeping

    /// Diffs every key and keeps the ledger invariant (one line per key, none for keys at their default).
    private static func record(from before: AppPreferences,
                               to after: AppPreferences,
                               source: LedgerSource,
                               in document: inout Document,
                               now: Date = Date()) -> PreferenceChangeReceipt? {
        let defaults = AppPreferences()
        let source = source.trimmed
        var changes: [PreferenceChange] = []
        for key in PreferenceKey.allCases {
            let old = before.canonicalValue(for: key)
            let new = after.canonicalValue(for: key)
            guard old != new else { continue }
            let replaced = document.ledger.first { $0.key == key }
            document.ledger.removeAll { $0.key == key }
            let oldDisplay = before.displayValue(for: key)
            let newDisplay = after.displayValue(for: key)
            if new != defaults.canonicalValue(for: key) {
                let entry = LedgerEntry(id: UUID(), key: key, value: new, display: newDisplay,
                                        previousDisplay: oldDisplay, source: source, date: now)
                document.ledger.insert(entry, at: 0)
            }
            changes.append(PreferenceChange(key: key, oldValue: old, newValue: new, oldDisplay: oldDisplay,
                                            newDisplay: newDisplay, replacedEntry: replaced))
        }
        guard !changes.isEmpty else { return nil }
        return PreferenceChangeReceipt(id: UUID(), date: now, source: source, changes: changes)
    }

    private static func isDefaultReminder(_ offset: Int, kind: ScheduleEvent.Kind, isAllDay: Bool,
                                          in preferences: AppPreferences) -> Bool {
        isAllDay ? preferences.allDayReminderMinutes != nil : preferences.reminders(for: kind).contains(offset)
    }

    // MARK: File I/O

    /// One coordinated read-modify-write. `change` returns false when it left the document as it was, which skips
    /// the write.
    private func transact(_ change: (inout Document) -> Bool) {
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: [], error: &coordinationError) { url in
            var document = Self.decode(try? Data(contentsOf: url))
            guard change(&document) else { return }
            do {
                try Self.encode(document).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                cache.store(document.preferences)
            } catch {
                cache.invalidate()
            }
        }
    }

    private static func load(from fileURL: URL) -> Document {
        var document = Document()
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { url in
            document = decode(try? Data(contentsOf: url))
        }
        return document
    }

    /// Missing or unreadable files read as defaults.
    static func decode(_ data: Data?) -> Document {
        guard let data else { return Document() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(Document.self, from: data)) ?? Document()
    }

    static func encode(_ document: Document) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    /// Backs `current()`. `generation` stops a slow file read from filling in a value an invalidation superseded.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: AppPreferences?
        private var generation = 0

        func read() -> (AppPreferences?, Int) {
            lock.lock()
            defer { lock.unlock() }
            return (value, generation)
        }

        func fill(_ preferences: AppPreferences, generation expected: Int) {
            lock.lock()
            if generation == expected { value = preferences }
            lock.unlock()
        }

        func store(_ preferences: AppPreferences) {
            lock.lock()
            value = preferences
            generation += 1
            lock.unlock()
        }

        func invalidate() {
            lock.lock()
            value = nil
            generation += 1
            lock.unlock()
        }
    }
}
