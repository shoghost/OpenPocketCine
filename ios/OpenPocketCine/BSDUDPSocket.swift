import Darwin
import Dispatch
import Foundation
import os

/// Public-API connected UDP socket used by the Nano datalink.
///
/// The read source owns the file descriptor. Its event handler drains the kernel queue until
/// `EAGAIN`; datagram parsing is deliberately left to `UDPDatagramProcessor`.
final class BSDUDPSocket: @unchecked Sendable {
    static let requestedReceiveBufferSize = 2 * 1_024 * 1_024
    static let minimumDesiredReceiveBufferSize = 1 * 1_024 * 1_024
    static let maximumDatagramSize = 65_535

    struct Failure: Error, LocalizedError, Equatable, Sendable {
        let operation: String
        let code: Int32

        var errorDescription: String? {
            "\(operation) failed: errno=\(code) \(String(cString: strerror(code)))"
        }
    }

    enum ReadStep: Equatable, Sendable {
        case datagram(Data)
        case interrupted
        case wouldBlock
        case failed(Int32)
    }

    struct DrainResult: Equatable, Sendable {
        let datagramCount: Int
        let readCount: Int
        let failureCode: Int32?
    }

    typealias DatagramHandler = @Sendable (Data) -> Void
    typealias ErrorHandler = @Sendable (Failure) -> Void
    typealias SendCompletion = @Sendable (Failure?) -> Void

    let actualReceiveBufferSize: Int
    let receiveBufferSetFailure: Failure?
    let localPort: UInt16

    private struct State {
        var open = true
        var started = false
        var source: DispatchSourceRead?
    }

    private let descriptor: Int32
    private let queue: DispatchQueue
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var receiveBuffer = [UInt8](repeating: 0, count: BSDUDPSocket.maximumDatagramSize)

    var isOpen: Bool { state.withLock { $0.open } }

    init(remoteHost: String, remotePort: UInt16, queue: DispatchQueue) throws {
        self.queue = queue
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw Failure(operation: "socket", code: errno) }
        descriptor = fd

        do {
            let receiveBuffer = try Self.configureReceiveBuffer(fd)
            actualReceiveBufferSize = receiveBuffer.actual
            receiveBufferSetFailure = receiveBuffer.setFailure
            try Self.bindEphemeral(fd)
            localPort = try Self.boundPort(fd)
            try Self.connect(fd, host: remoteHost, port: remotePort)
            try Self.setNonBlocking(fd)
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
    }

    deinit { cancel() }

    func start(onDatagram: @escaping DatagramHandler, onError: @escaping ErrorHandler) {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, self.isOpen else { return }
            let result = Self.drain(
                readOne: { self.readOne() },
                deliver: onDatagram)
            if let code = result.failureCode {
                onError(Failure(operation: "recv", code: code))
                self.cancel()
            }
        }
        let fd = descriptor
        source.setCancelHandler { _ = Darwin.close(fd) }
        let shouldStart = state.withLock { state -> Bool in
            guard state.open, !state.started else { return false }
            state.started = true
            state.source = source
            return true
        }
        guard shouldStart else {
            // A concurrent pre-start cancel already closed the descriptor. Balance the source's
            // suspended state without closing that descriptor a second time.
            source.setCancelHandler {}
            source.cancel()
            source.resume()
            return
        }
        source.resume()
    }

    func send(_ data: Data, completion: SendCompletion? = nil) {
        queue.async { [weak self] in
            guard let self, self.isOpen else {
                completion?(Failure(operation: "send", code: EBADF))
                return
            }
            let sent = data.withUnsafeBytes { bytes in
                Darwin.send(self.descriptor, bytes.baseAddress, bytes.count, 0)
            }
            if sent == data.count {
                completion?(nil)
            } else {
                completion?(
                    Failure(operation: "send", code: sent < 0 ? errno : EMSGSIZE))
            }
        }
    }

    func cancel() {
        let cancellation = state.withLock { state -> (DispatchSourceRead?, Bool) in
            guard state.open else { return (nil, false) }
            state.open = false
            return (state.source, !state.started)
        }
        if let source = cancellation.0 {
            source.cancel()
        } else if cancellation.1 {
            _ = Darwin.close(descriptor)
        }
    }

    /// Pure drain loop used by the read source and unit tests. `interrupted` is retried, and the
    /// first `wouldBlock` ends the event after every currently queued datagram has been delivered.
    static func drain(
        readOne: () -> ReadStep,
        deliver: (Data) -> Void
    ) -> DrainResult {
        var datagrams = 0
        var reads = 0
        while true {
            reads += 1
            switch readOne() {
            case .datagram(let data):
                datagrams += 1
                deliver(data)
            case .interrupted:
                continue
            case .wouldBlock:
                return DrainResult(
                    datagramCount: datagrams, readCount: reads, failureCode: nil)
            case .failed(let code):
                return DrainResult(
                    datagramCount: datagrams, readCount: reads, failureCode: code)
            }
        }
    }

    private func readOne() -> ReadStep {
        let count = receiveBuffer.withUnsafeMutableBytes { bytes in
            Darwin.recv(descriptor, bytes.baseAddress, bytes.count, 0)
        }
        if count >= 0 {
            return .datagram(Data(receiveBuffer.prefix(count)))
        }
        let code = errno
        if code == EINTR { return .interrupted }
        if code == EAGAIN || code == EWOULDBLOCK { return .wouldBlock }
        return .failed(code)
    }

    private static func setNonBlocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { throw Failure(operation: "fcntl(F_GETFL)", code: errno) }
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw Failure(operation: "fcntl(F_SETFL)", code: errno)
        }
    }

    private static func configureReceiveBuffer(_ fd: Int32) throws -> (
        actual: Int, setFailure: Failure?
    ) {
        var requested = Int32(requestedReceiveBufferSize)
        let optionLength = socklen_t(MemoryLayout.size(ofValue: requested))
        let setFailure: Failure? =
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &requested, optionLength) == 0
            ? nil : Failure(operation: "setsockopt(SO_RCVBUF)", code: errno)

        var actual: Int32 = 0
        var actualLength = socklen_t(MemoryLayout.size(ofValue: actual))
        guard getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &actual, &actualLength) == 0 else {
            throw Failure(operation: "getsockopt(SO_RCVBUF)", code: errno)
        }
        return (Int(actual), setFailure)
    }

    private static func bindEphemeral(_ fd: Int32) throws {
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = in_port_t(0)
        local.sin_addr = in_addr(s_addr: in_addr_t(INADDR_ANY))
        let result = withUnsafePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw Failure(operation: "bind", code: errno) }
    }

    private static func connect(_ fd: Int32, host: String, port: UInt16) throws {
        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = in_port_t(port.bigEndian)
        let parsed = host.withCString { inet_pton(AF_INET, $0, &remote.sin_addr) }
        guard parsed == 1 else { throw Failure(operation: "inet_pton", code: EINVAL) }
        let result = withUnsafePointer(to: &remote) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw Failure(operation: "connect", code: errno) }
    }

    private static func boundPort(_ fd: Int32) throws -> UInt16 {
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard result == 0 else { throw Failure(operation: "getsockname", code: errno) }
        return UInt16(bigEndian: local.sin_port)
    }
}
