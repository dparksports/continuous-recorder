import Foundation
import Network

/// There is no public API that turns a radio off — not Wi-Fi, not Bluetooth, not cellular.
/// What an app can do is notice whether one is up, which is enough to *enforce* a deployment
/// precondition and to record when it stops holding.
///
/// Be precise about what this proves: `NWPathMonitor` reports whether there is a usable
/// network path. Wi-Fi that is switched on but unassociated still scans and still reports
/// no path, so "silent" here means "no connectivity", not "no RF". Only Airplane Mode — or
/// not having the hardware — gives you actual silence.
@MainActor
final class RadioMonitor {

    struct State: Equatable {
        enum Interface: String, CaseIterable {
            case wifi, cellular, wired, other
        }

        var hasPath = false
        var interfaces: Set<Interface> = []

        /// No usable network path. See the caveat above before treating this as RF silence.
        var isSilent: Bool { !hasPath }

        var description: String {
            guard hasPath else { return "no path" }
            let names = interfaces.map(\.rawValue).sorted().joined(separator: "+")
            return names.isEmpty ? "path up" : names
        }
    }

    /// Delivered on the main queue.
    var onChange: ((State) -> Void)?

    private(set) var state = State()
    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.example.recorderapp.radio")

    func start() {
        guard monitor == nil else { return }

        let monitor = NWPathMonitor()
        self.monitor = monitor

        monitor.pathUpdateHandler = { [weak self] path in
            var next = State()
            next.hasPath = path.status == .satisfied
            if path.usesInterfaceType(.wifi) { next.interfaces.insert(.wifi) }
            if path.usesInterfaceType(.cellular) { next.interfaces.insert(.cellular) }
            if path.usesInterfaceType(.wiredEthernet) { next.interfaces.insert(.wired) }
            if path.usesInterfaceType(.other) { next.interfaces.insert(.other) }

            Task { @MainActor in
                guard let self else { return }
                let changed = self.state != next
                self.state = next
                if changed { self.onChange?(next) }
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        state = State()
    }
}
