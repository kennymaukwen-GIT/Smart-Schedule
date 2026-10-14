import Foundation

/// App Group `UserDefaults` key "SSSyncStatus" (JSON), so the app, Siri and the notification extension read the same
/// status synchronously (like `AIConsentStore`). Every change posts `SharedChange.syncStatus`.
///
/// Advisory only: `SyncEngine` recomputes the counts from the outbox file whenever it writes, so a lost update
/// between two processes heals on the next sync.
enum SyncStatusStore {
    static let defaultsKey = "SSSyncStatus"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: AppConstants.appGroupID) }

    static var current: SyncStatus { current(in: defaults) }

    /// Read, change, write; posts only when something changed.
    static func update(_ change: (inout SyncStatus) -> Void) {
        update(in: defaults, change)
    }

    /// Erase all data.
    static func reset() { reset(in: defaults) }

    // Explicit defaults for unit tests (a hostless test bundle has no App Group).

    static func current(in defaults: UserDefaults?) -> SyncStatus {
        guard let data = defaults?.data(forKey: defaultsKey) else { return SyncStatus() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(SyncStatus.self, from: data)) ?? SyncStatus()
    }

    @discardableResult
    static func update(in defaults: UserDefaults?, _ change: (inout SyncStatus) -> Void) -> SyncStatus {
        let before = current(in: defaults)
        var status = before
        change(&status)
        guard status != before else { return status }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(status) else { return before }
        defaults?.set(data, forKey: defaultsKey)
        SharedChangeNotifier.post(.syncStatus)
        return status
    }

    static func reset(in defaults: UserDefaults?) {
        defaults?.removeObject(forKey: defaultsKey)
        SharedChangeNotifier.post(.syncStatus)
    }
}

/// Lets code that is compiled without Shared/Calendar (the widget target, so Shared/Intents and Shared/LiveActivity)
/// ask for a sync: the app installs the handler at launch (`AppRefresh.installSyncHooks()`), and the Control Center
/// summon, which iOS runs in the app process, calls `request("summon")`. Without a handler it does nothing.
enum SyncRequests {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (String) async -> Void)?

    /// `trigger` is a `SyncTrigger` raw value.
    static func install(_ newHandler: @escaping @Sendable (_ trigger: String) async -> Void) {
        lock.withLock { handler = newHandler }
    }

    static func request(_ trigger: String) async {
        let current = lock.withLock { handler }
        await current?(trigger)
    }
}
