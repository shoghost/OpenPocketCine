import Foundation
import os

enum DatalinkTransportPolicy {
    static let windowAckIntervalMilliseconds = 25
}

/// Ordered, non-blocking handoff from Network.framework's receive callback to datalink parsing.
/// Generation changes wait for an in-flight datagram and make every queued older datagram stale.
final class UDPDatagramProcessor: @unchecked Sendable {
    typealias Handler = @Sendable (Data) -> Void

    private let queue: DispatchQueue
    private let activeGeneration = OSAllocatedUnfairLock(initialState: -1)
    private let inFlight = NSLock()

    init(
        label: String = "opv.datalink.udp-processing",
        qos: DispatchQoS.QoSClass = .userInitiated
    ) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    func activate(generation next: Int) {
        activeGeneration.withLock { $0 = next }
        // Do not let a datagram that passed the first generation check outlive activation.
        inFlight.lock()
        inFlight.unlock()
    }

    func submit(_ datagram: Data, generation expected: Int, handler: @escaping Handler) {
        queue.async { [self] in
            guard activeGeneration.withLock({ $0 == expected }) else { return }
            inFlight.lock()
            defer { inFlight.unlock() }
            guard activeGeneration.withLock({ $0 == expected }) else { return }
            handler(datagram)
        }
    }

    /// Test seam: wait until every datagram submitted before this call has completed or been
    /// rejected by the generation gate.
    func drain() {
        queue.sync {}
    }
}
