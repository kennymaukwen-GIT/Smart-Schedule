import Foundation
import Network

/// Watches the network path so changes waiting in the outbox go out as soon as the device is back online,
/// instead of at the next foreground or timer tick. Runs for the app's lifetime.
@MainActor
final class ConnectivityMonitor {
    /// False while the path is unsatisfied (airplane mode, no signal). Starts true: unknown counts as online.
    private(set) var isOnline = true

    private var monitor: NWPathMonitor?
    private var hasFirstReport = false
    private var onChange: (@MainActor (_ isOnline: Bool, _ cameBack: Bool) -> Void)?

    /// Usable as a stored property's default value of a main-actor class.
    nonisolated init() {}

    /// `onChange` runs on the main actor with the state at start, then whenever the path flips; `cameBack` is true
    /// when it went from offline to online.
    func start(onChange: @escaping @MainActor (_ isOnline: Bool, _ cameBack: Bool) -> Void) {
        guard monitor == nil else { return }
        self.onChange = onChange
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = Self.pathHandler(for: self)
        monitor.start(queue: DispatchQueue(label: "com.smartschedule.connectivity", qos: .utility))
        self.monitor = monitor
    }

    /// Built outside the main actor: the monitor calls it on its own queue.
    nonisolated private static func pathHandler(for owner: ConnectivityMonitor) -> @Sendable (NWPath) -> Void {
        { [weak owner] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak owner] in owner?.update(online: online) }
        }
    }

    private func update(online: Bool) {
        let wasOnline = isOnline
        let isFirstReport = !hasFirstReport
        hasFirstReport = true
        isOnline = online
        guard isFirstReport || online != wasOnline else { return }
        onChange?(online, !isFirstReport && online && !wasOnline)
    }
}
