import Foundation

/// One change made on this iPhone that Google has not confirmed yet: written when a create, edit or delete could not
/// reach Google (no network, a timeout, 5xx after the client's retries) and sent by `SyncEngine` later, in order.
struct OutboxItem: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// `body`: the whole new event (its client-chosen id makes sending it twice harmless).
        case insert
        /// `body`: the changed fields of one event or instance.
        case patch
        /// `body`: the changed fields of a series master; `eventID` is the series id.
        case patchSeries
        case delete
    }

    /// "Move every occurrence to this time of day", worked out against the series master when it is sent (the
    /// master's first date is not in the cache).
    struct SeriesTime: Codable, Equatable, Sendable {
        var newStart: Date
        var duration: TimeInterval
    }

    var id: UUID
    var kind: Kind
    /// Where the change goes. `accountID == ""`: the single-account sign-in before its migration.
    var calendar: CalendarRef
    var eventID: String
    var body: GCalEvent?
    var wantsConference: Bool
    var seriesTime: SeriesTime?
    /// The version the change is based on, sent as If-Match. nil for inserts and series.
    var etag: String?
    /// The event as it was when the change was made: rebases a time change after a 412, names it in the failed list.
    var base: ScheduleEvent?
    /// Edits folded into a queued insert. Sent as a PATCH when the insert turns out to have reached Google earlier
    /// (409), since Google's copy then predates them.
    var followUp: GCalEvent?
    /// The event's title and what the change was, for the failed list.
    var title: String
    var summary: String
    var createdAt: Date
    /// Bumped whenever another change is folded in, so a flush in another process never drops a newer edit.
    var revision: Int
    /// A failed attempt may have reached Google (a timeout, 5xx): a queued insert then cannot simply be dropped.
    var mayHaveReachedGoogle: Bool
    var attempts: Int
    var lastError: String?
    /// Google refused it: it waits in the failed list for Retry or Discard and is not applied to the cache.
    var failure: String?
    var failedAt: Date?

    init(kind: Kind, calendar: CalendarRef, eventID: String, body: GCalEvent? = nil, wantsConference: Bool = false,
         seriesTime: SeriesTime? = nil, etag: String? = nil, base: ScheduleEvent? = nil, title: String,
         summary: String = "", createdAt: Date = Date(), mayHaveReachedGoogle: Bool = false) {
        id = UUID()
        self.kind = kind
        self.calendar = calendar
        self.eventID = eventID
        self.body = body
        self.wantsConference = wantsConference
        self.seriesTime = seriesTime
        self.etag = etag
        self.base = base
        followUp = nil
        self.title = title
        self.summary = summary
        self.createdAt = createdAt
        revision = 0
        self.mayHaveReachedGoogle = mayHaveReachedGoogle
        attempts = 0
        lastError = nil
        failure = nil
        failedAt = nil
    }

    var isFailed: Bool { failure != nil }
    /// The single-account sign-in before its migration: events cached without a calendar.
    var isLegacy: Bool { calendar.accountID.isEmpty }

    var failedChange: FailedChange? {
        guard let failure else { return nil }
        return FailedChange(id: id, title: title, summary: summary, failedAt: failedAt ?? createdAt, reason: failure)
    }
}

/// The outbox's ordering and folding rules (pure, unit-tested).
enum OutboxQueue {
    /// Adds `item` after the waiting changes, folding it into an earlier change of the same event:
    /// - insert + edit → the insert with the edit applied (and remembered in `followUp`);
    /// - edit + edit → one edit; the first etag and base stay, later fields win;
    /// - anything + delete → the delete; an insert that never reached Google is dropped together with the delete;
    /// - delete + edit → the edit is dropped.
    /// Items Google refused (failed list) are never folded into. The queue keeps first-queued order.
    static func enqueue(_ item: OutboxItem, into items: [OutboxItem]) -> [OutboxItem] {
        var items = items
        switch item.kind {
        case .insert:
            if let index = items.firstIndex(where: { isSameEvent($0, item) && $0.kind == .insert }) {
                // The same seeded id again (Add tapped twice offline): the newer body.
                items[index].body = item.body
                items[index].wantsConference = items[index].wantsConference || item.wantsConference
                items[index].title = item.title
                items[index].summary = item.summary
                items[index].revision += 1
            } else {
                items.append(item)
            }

        case .patch, .patchSeries:
            guard let index = items.lastIndex(where: { isSameEvent($0, item) && folds(item.kind, into: $0.kind) }) else {
                items.append(item)
                return items
            }
            var earlier = items[index]
            if earlier.kind == .delete { return items } // the event is going away anyway
            let change = item.body ?? GCalEvent()
            var body = (earlier.body ?? GCalEvent()).overlaid(with: change)
            if earlier.kind == .insert {
                earlier.followUp = (earlier.followUp ?? GCalEvent()).overlaid(with: change)
            } else if let seriesTime = item.seriesTime {
                // A later "move every occurrence" replaces an earlier absolute time.
                body.start = nil
                body.end = nil
                earlier.seriesTime = seriesTime
            }
            earlier.body = body
            earlier.mayHaveReachedGoogle = earlier.mayHaveReachedGoogle || item.mayHaveReachedGoogle
            if !item.title.isEmpty { earlier.title = item.title }
            if earlier.kind != .insert, !item.summary.isEmpty { earlier.summary = item.summary }
            earlier.revision += 1
            items[index] = earlier

        case .delete:
            let related: (OutboxItem) -> Bool = { other in
                !other.isFailed && other.calendar == item.calendar
                    && (other.eventID == item.eventID || other.base?.seriesID == item.eventID)
            }
            let folded = items.filter(related)
            items.removeAll(where: related)
            let insert = folded.first { $0.kind == .insert && $0.eventID == item.eventID }
            if let insert, !insert.mayHaveReachedGoogle { return items } // Google never had it
            var delete = item
            // Google's copy of a queued insert has an etag this iPhone never saw.
            if insert != nil { delete.etag = nil }
            delete.mayHaveReachedGoogle = delete.mayHaveReachedGoogle || folded.contains(where: \.mayHaveReachedGoogle)
            items.append(delete)
        }
        return items
    }

    private static func isSameEvent(_ lhs: OutboxItem, _ rhs: OutboxItem) -> Bool {
        !lhs.isFailed && lhs.calendar == rhs.calendar && lhs.eventID == rhs.eventID
    }

    /// An instance edit folds into an earlier insert, edit or delete of that id; a series edit into an earlier insert
    /// of the series (the master), series edit or delete.
    private static func folds(_ kind: OutboxItem.Kind, into earlier: OutboxItem.Kind) -> Bool {
        switch (kind, earlier) {
        case (.patch, .patchSeries), (.patchSeries, .patch): false
        default: true
        }
    }
}

/// App Group `sync-outbox.json`: the changes waiting for Google, shared by the app, Siri and the notification
/// extension. Every access re-reads the file under `NSFileCoordinator`, like `SharedStore`.
actor SyncOutbox {
    static let shared = SyncOutbox()
    static let currentVersion = 1

    struct File: Codable, Sendable {
        var version = SyncOutbox.currentVersion
        var items: [OutboxItem] = []
    }

    private let fileURL: URL

    init(fileName: String = "sync-outbox.json") {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID)
            ?? FileManager.default.temporaryDirectory
        fileURL = container.appendingPathComponent(fileName)
    }

    /// Unit tests use a temporary file (a hostless test bundle has no App Group).
    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: Reads

    /// Waiting and failed, in queue order.
    func items() -> [OutboxItem] { read().items }

    /// Waiting to be sent, in order.
    func pending() -> [OutboxItem] { read().items.filter { !$0.isFailed } }

    func failed() -> [OutboxItem] { read().items.filter(\.isFailed) }

    func item(id: UUID) -> OutboxItem? { read().items.first { $0.id == id } }

    /// Changes of this account that Google does not have: waiting ones and refused ones. Removing the account loses
    /// them, which its confirmation says.
    func unsentCount(accountID: String) -> Int {
        read().items.filter { $0.calendar.accountID == accountID }.count
    }

    /// A change of this event (or of the series it names) still waits: later changes queue behind it.
    func hasPending(calendar: CalendarRef, eventID: String) -> Bool {
        read().items.contains { !$0.isFailed && $0.calendar == calendar && $0.eventID == eventID }
    }

    /// The body of a queued insert, e.g. a recurring series' master that Google does not have yet.
    func pendingInsert(calendar: CalendarRef, eventID: String) -> GCalEvent? {
        read().items.first { !$0.isFailed && $0.kind == .insert && $0.calendar == calendar && $0.eventID == eventID }?.body
    }

    // MARK: Writes

    func enqueue(_ item: OutboxItem) {
        mutate { file in
            file.items = OutboxQueue.enqueue(item, into: file.items)
            return true
        }
    }

    /// Google confirmed `item`. It leaves the queue unless another change was folded into it meanwhile (its revision
    /// moved on): that one is sent next time, and an insert's folded edits go as its `followUp`.
    func complete(_ item: OutboxItem) {
        mutate { file in
            guard let index = file.items.firstIndex(where: { $0.id == item.id }) else { return false }
            guard file.items[index].revision == item.revision else { return false }
            file.items.remove(at: index)
            return true
        }
    }

    /// About to be sent: until the answer is in, Google may have it, so a delete folded in meanwhile is kept and
    /// sent after it instead of dropping both.
    func markSending(id: UUID) {
        mutate { file in
            guard let index = file.items.firstIndex(where: { $0.id == id }),
                  !file.items[index].mayHaveReachedGoogle else { return false }
            file.items[index].mayHaveReachedGoogle = true
            return true
        }
    }

    /// A transport failure: it stays queued. `mayHaveReachedGoogle` replaces the mark `markSending` set.
    func recordAttempt(id: UUID, mayHaveReachedGoogle: Bool, error: String) {
        mutate { file in
            guard let index = file.items.firstIndex(where: { $0.id == id }) else { return false }
            file.items[index].attempts += 1
            file.items[index].lastError = error
            file.items[index].mayHaveReachedGoogle = mayHaveReachedGoogle
            return true
        }
    }

    /// Google refused it: into the failed list.
    func fail(id: UUID, reason: String, at date: Date = Date()) {
        mutate { file in
            guard let index = file.items.firstIndex(where: { $0.id == id }) else { return false }
            file.items[index].failure = reason
            file.items[index].failedAt = date
            file.items[index].attempts += 1
            return true
        }
    }

    /// Retry: back in the queue at its place. False when it is not a failed item.
    @discardableResult
    func retry(id: UUID) -> Bool {
        var found = false
        mutate { file in
            guard let index = file.items.firstIndex(where: { $0.id == id && $0.isFailed }) else { return false }
            file.items[index].failure = nil
            file.items[index].failedAt = nil
            found = true
            return true
        }
        return found
    }

    /// Discard: gone for good; returns it so its calendar can be listed again.
    @discardableResult
    func discard(id: UUID) -> OutboxItem? {
        var removed: OutboxItem?
        mutate { file in
            guard let index = file.items.firstIndex(where: { $0.id == id }) else { return false }
            removed = file.items.remove(at: index)
            return true
        }
        return removed
    }

    /// A removed account: its changes can never be sent.
    func removeAll(accountID: String) {
        mutate { file in
            let before = file.items.count
            file.items.removeAll { $0.calendar.accountID == accountID }
            return file.items.count != before
        }
    }

    /// Erase all data.
    func eraseAll() {
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forDeleting, error: &coordinationError) { url in
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: File I/O

    private func read() -> File {
        var result = File()
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { url in
            guard let data = try? Data(contentsOf: url) else { return }
            result = Self.decode(data)
        }
        return result
    }

    /// One coordinated read-modify-write; `change` returns false when it changed nothing, which skips the write.
    private func mutate(_ change: (inout File) -> Bool) {
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: [], error: &coordinationError) { url in
            var file = (try? Data(contentsOf: url)).map(Self.decode) ?? File()
            guard change(&file) else { return }
            file.version = max(file.version, Self.currentVersion)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            try? encoder.encode(file).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    private static func decode(_ data: Data) -> File {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(File.self, from: data)) ?? File()
    }
}

extension SyncOutbox.File {
    /// Tolerant: an item this build cannot read (a newer build's) is skipped instead of losing the whole queue.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? SyncOutbox.currentVersion
        items = ((try? c.decodeIfPresent([AccountsFileElement<OutboxItem>].self, forKey: .items)) ?? [])
            .compactMap(\.value)
    }
}
