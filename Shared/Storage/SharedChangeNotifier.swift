import Foundation

/// Something another process may have changed in the App Group: the app, the widget extension and the
/// notification content extension are separate processes, so writers post and observers reload.
enum SharedChange: String, CaseIterable, Sendable {
    case preferences, accounts, consent
    /// `SyncStatusStore`: the outbox, failures or the last successful sync changed (cached events usually too).
    case syncStatus
    var darwinName: String { "com.smartschedule.changed.\(rawValue)" }

    /// Another name for `.syncStatus`.
    static let sync = SharedChange.syncStatus
}

/// Darwin notifications: no payload, delivered to every process that observes the name, the posting one included.
enum SharedChangeNotifier {
    static func post(_ change: SharedChange) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(change.darwinName as CFString),
                                             nil, nil, true)
    }

    /// Calls `handler` on the main queue whenever any process (this one too) posts `change`.
    /// Observation stops when the returned token is released.
    static func observe(_ change: SharedChange, handler: @escaping @Sendable () -> Void) -> SharedChangeObservation {
        SharedChangeObservation(change: change, handler: handler)
    }
}

/// Keep it alive for as long as the handler should run.
final class SharedChangeObservation {
    let change: SharedChange
    private let id = UUID()

    fileprivate init(change: SharedChange, handler: @escaping @Sendable () -> Void) {
        self.change = change
        DarwinObserverRegistry.shared.add(id: id, change: change, handler: handler)
    }

    deinit {
        DarwinObserverRegistry.shared.remove(id: id, change: change)
    }
}

/// One CF observer per name for the whole process. CF calls back with a raw pointer, so it points at this
/// never-released singleton rather than at an observation that might already be gone.
private final class DarwinObserverRegistry: @unchecked Sendable {
    static let shared = DarwinObserverRegistry()

    private let lock = NSLock()
    private var handlers: [SharedChange: [UUID: @Sendable () -> Void]] = [:]
    private var registered: Set<SharedChange> = []

    func add(id: UUID, change: SharedChange, handler: @escaping @Sendable () -> Void) {
        lock.lock()
        handlers[change, default: [:]][id] = handler
        let needsObserver = registered.insert(change).inserted
        lock.unlock()
        guard needsObserver else { return }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let registry = Unmanaged<DarwinObserverRegistry>.fromOpaque(observer).takeUnretainedValue()
                registry.deliver(name.rawValue as String)
            },
            change.darwinName as CFString,
            nil,
            .deliverImmediately
        )
    }

    func remove(id: UUID, change: SharedChange) {
        lock.lock()
        handlers[change]?[id] = nil
        lock.unlock()
    }

    private func deliver(_ name: String) {
        guard let change = SharedChange.allCases.first(where: { $0.darwinName == name }) else { return }
        lock.lock()
        let targets = handlers[change].map { Array($0.values) } ?? []
        lock.unlock()
        guard !targets.isEmpty else { return }
        DispatchQueue.main.async {
            for handler in targets { handler() }
        }
    }
}
