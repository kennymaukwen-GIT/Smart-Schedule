import Foundation

/// Where this iPhone stands with Google, for the drawer's status line, the header indicator and the failed list.
/// Written by `SyncEngine` (app, Siri, notification extension); read synchronously through `SyncStatusStore`.
struct SyncStatus: Codable, Hashable, Sendable {
    /// Account id → end of its last sync in which every one of its calendars answered.
    var lastSuccess: [String: Date] = [:]
    /// Changes made here that Google has not confirmed yet (failed ones not included).
    var pendingCount = 0
    /// Changes Google refused; each can be retried or discarded.
    var failed: [FailedChange] = []
    /// The last attempt could not reach the network at all (no connection, airplane mode).
    var isOffline = false
    /// The last sync's failure other than the network or a sign-in that needs Reconnect; nil after a clean sync.
    var lastError: String?
    /// Demo mode: nothing is synced.
    var isDemo = false

    init(lastSuccess: [String: Date] = [:], pendingCount: Int = 0, failed: [FailedChange] = [],
         isOffline: Bool = false, lastError: String? = nil, isDemo: Bool = false) {
        self.lastSuccess = lastSuccess
        self.pendingCount = pendingCount
        self.failed = failed
        self.isOffline = isOffline
        self.lastError = lastError
        self.isDemo = isDemo
    }

    /// The most recent successful sync of any account.
    var latestSuccess: Date? { lastSuccess.values.max() }

    /// Something waits for Google or was refused: the header shows its indicator.
    var needsAttention: Bool { pendingCount > 0 || !failed.isEmpty }

    /// Tolerant: a newer build's file still reads, an unreadable field falls back to its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastSuccess = (try? c.decodeIfPresent([String: Date].self, forKey: .lastSuccess)) ?? [:]
        pendingCount = (try? c.decodeIfPresent(Int.self, forKey: .pendingCount)) ?? 0
        failed = ((try? c.decodeIfPresent([AccountsFileElement<FailedChange>].self, forKey: .failed)) ?? [])
            .compactMap(\.value)
        isOffline = (try? c.decodeIfPresent(Bool.self, forKey: .isOffline)) ?? false
        lastError = try? c.decodeIfPresent(String.self, forKey: .lastError)
        isDemo = (try? c.decodeIfPresent(Bool.self, forKey: .isDemo)) ?? false
    }
}

/// One change Google refused: a row in the drawer's failed list with Retry and Discard. `id` is the outbox item's.
struct FailedChange: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    /// The event's title.
    var title: String
    /// What the change was: "New event · Wed 14 Oct 14:00".
    var summary: String
    var failedAt: Date
    /// Why Google refused it, for the user.
    var reason: String
}
