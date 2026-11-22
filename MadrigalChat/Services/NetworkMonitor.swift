import Foundation
import Network
import Observation
import SwiftUI

/// Proactive offline detection so the composer can disable send rather than
/// letting the request fail after the fact. See spec section 10.
@Observable
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isOnline: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.whittle.madrigalchat.network")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.isOnline = online
            }
        }
        monitor.start(queue: queue)
    }
}

extension EnvironmentValues {
    /// Whether the device has a network path. Set from `NetworkMonitor` at
    /// the root, so views read a value instead of the singleton.
    @Entry var isOnline: Bool = true
}
