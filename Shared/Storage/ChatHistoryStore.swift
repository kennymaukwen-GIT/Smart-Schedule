import Foundation

/// One message of the app's conversation, as it is kept across launches. Cards keep their data and settled state
/// (plan drafts and statuses, receipts, suggestions, pending events). Pending deletions are not kept on purpose:
/// a stale Confirm after a relaunch could delete the wrong thing.
struct ChatRecord: Codable, Hashable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }

    var id: UUID
    var date: Date
    var role: Role
    var text: String
    var suggestions: [String] = []
    var assumptions: [String] = []
    var planDraft: PlanDraft?
    /// "pending" | "added" | "added_demo" | "replaced" | "replaced:<revision>" | "discarded" ("adding" is saved as "pending").
    var planStatus: String?
    var addedEvents: [ScheduleEvent] = []
    var agenda: AgendaDigest?
    var preferenceReceipt: PreferenceChangeReceipt?
    var preferenceUndone: Bool?
    var learnedSuggestion: LearnedSuggestion?
    var pendingEvents: PendingEventBatch?
    /// "pending" | "added" | "added_demo" | "discarded" | "replaced".
    var pendingEventsStatus: String?

    init(id: UUID = UUID(),
         date: Date,
         role: Role,
         text: String,
         suggestions: [String] = [],
         assumptions: [String] = [],
         planDraft: PlanDraft? = nil,
         planStatus: String? = nil,
         addedEvents: [ScheduleEvent] = [],
         agenda: AgendaDigest? = nil,
         preferenceReceipt: PreferenceChangeReceipt? = nil,
         preferenceUndone: Bool? = nil,
         learnedSuggestion: LearnedSuggestion? = nil,
         pendingEvents: PendingEventBatch? = nil,
         pendingEventsStatus: String? = nil) {
        self.id = id
        self.date = date
        self.role = role
        self.text = text
        self.suggestions = suggestions
        self.assumptions = assumptions
        self.planDraft = planDraft
        self.planStatus = planStatus
        self.addedEvents = addedEvents
        self.agenda = agenda
        self.preferenceReceipt = preferenceReceipt
        self.preferenceUndone = preferenceUndone
        self.learnedSuggestion = learnedSuggestion
        self.pendingEvents = pendingEvents
        self.pendingEventsStatus = pendingEventsStatus
    }

    /// Tolerant: a card this build cannot read drops that card, not the message or the whole history.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        date = (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? Date(timeIntervalSince1970: 0)
        role = (try? c.decodeIfPresent(Role.self, forKey: .role)) ?? .assistant
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        suggestions = (try? c.decodeIfPresent([String].self, forKey: .suggestions)) ?? []
        assumptions = (try? c.decodeIfPresent([String].self, forKey: .assumptions)) ?? []
        planDraft = try? c.decodeIfPresent(PlanDraft.self, forKey: .planDraft)
        planStatus = try? c.decodeIfPresent(String.self, forKey: .planStatus)
        addedEvents = (try? c.decodeIfPresent([ScheduleEvent].self, forKey: .addedEvents)) ?? []
        agenda = try? c.decodeIfPresent(AgendaDigest.self, forKey: .agenda)
        preferenceReceipt = try? c.decodeIfPresent(PreferenceChangeReceipt.self, forKey: .preferenceReceipt)
        preferenceUndone = try? c.decodeIfPresent(Bool.self, forKey: .preferenceUndone)
        learnedSuggestion = try? c.decodeIfPresent(LearnedSuggestion.self, forKey: .learnedSuggestion)
        pendingEvents = try? c.decodeIfPresent(PendingEventBatch.self, forKey: .pendingEvents)
        pendingEventsStatus = try? c.decodeIfPresent(String.self, forKey: .pendingEventsStatus)
    }
}

/// The app's conversation, kept in the App Group file `chat-history.json` (`{ "version": 1, "records": […] }`).
/// Retention (7 days, 30 days or forever) and the 200-message cap are applied on every load and save, so old
/// messages actually leave the disk. Only the app writes it; Siri and notification replies are not kept.
actor ChatHistoryStore {
    static let shared = ChatHistoryStore()
    static let maxRecords = 200
    static let currentVersion = 1

    struct File: Codable, Sendable {
        var version = ChatHistoryStore.currentVersion
        var records: [ChatRecord] = []

        init(records: [ChatRecord] = []) {
            self.records = records
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? ChatHistoryStore.currentVersion
            records = ((try? c.decodeIfPresent([LossyRecord].self, forKey: .records)) ?? []).compactMap(\.record)
        }
    }

    /// One unreadable record is skipped instead of failing the whole file.
    private struct LossyRecord: Decodable {
        let record: ChatRecord?
        init(from decoder: Decoder) throws { record = try? ChatRecord(from: decoder) }
    }

    private let fileURL: URL

    init(fileName: String = "chat-history.json") {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID)
            ?? FileManager.default.temporaryDirectory
        fileURL = container.appendingPathComponent(fileName)
    }

    /// A store at an explicit location. Unit tests use a temporary file, since a hostless test bundle has no
    /// App Group entitlement.
    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Oldest first. Records past `retention` or beyond the newest 200 are dropped, from the file too.
    func load(retention: ChatRetention, now: Date = Date()) -> [ChatRecord] {
        guard let file = read() else { return [] }
        let kept = Self.pruned(file.records, retention: retention, now: now)
        if kept.count != file.records.count { write(File(records: kept)) }
        return kept
    }

    func save(_ records: [ChatRecord], retention: ChatRetention, now: Date = Date()) {
        let normalized = records.map { record -> ChatRecord in
            var record = record
            if record.planStatus == "adding" { record.planStatus = "pending" }
            return record
        }
        write(File(records: Self.pruned(normalized, retention: retention, now: now)))
    }

    /// "Clear chat history": no records left.
    func clear() {
        write(File())
    }

    /// Erase all data: the file is deleted.
    func eraseAll() {
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forDeleting, error: &coordinationError) { url in
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func pruned(_ records: [ChatRecord], retention: ChatRetention, now: Date) -> [ChatRecord] {
        var kept = records
        if let maxAge = retention.maxAge {
            let cutoff = now.addingTimeInterval(-maxAge)
            kept.removeAll { $0.date < cutoff }
        }
        return Array(kept.suffix(maxRecords))
    }

    // MARK: File I/O

    /// nil when there is no file or it cannot be read at all (it is then left alone).
    private func read() -> File? {
        var result: File?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { url in
            guard let data = try? Data(contentsOf: url) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            result = try? decoder.decode(File.self, from: data)
        }
        return result
    }

    private func write(_ file: File) {
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: [], error: &coordinationError) { url in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            try? encoder.encode(file).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}
