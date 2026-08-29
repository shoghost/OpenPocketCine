import Dispatch
import Foundation
import OpenPocketViewCore
import XCTest
@testable import OpenPocketCine

final class BSDUDPSocketTests: XCTestCase {
    func testDrainReadsBurstInOrderUntilWouldBlock() {
        var steps: [BSDUDPSocket.ReadStep] = [
            .datagram(Data([1])),
            .datagram(Data([2])),
            .datagram(Data([3])),
            .wouldBlock,
            .datagram(Data([4])),
        ]
        var delivered: [UInt8] = []
        let result = BSDUDPSocket.drain(
            readOne: { steps.removeFirst() },
            deliver: { delivered.append($0[0]) })

        XCTAssertEqual(delivered, [1, 2, 3])
        XCTAssertEqual(result.datagramCount, 3)
        XCTAssertEqual(result.readCount, 4)
        XCTAssertNil(result.failureCode)
        XCTAssertEqual(steps, [.datagram(Data([4]))])
    }

    func testDrainRetriesInterruptedReadBeforeEAGAIN() {
        var steps: [BSDUDPSocket.ReadStep] = [
            .interrupted, .datagram(Data([7])), .wouldBlock,
        ]
        var delivered: [UInt8] = []
        let result = BSDUDPSocket.drain(
            readOne: { steps.removeFirst() },
            deliver: { delivered.append($0[0]) })

        XCTAssertEqual(delivered, [7])
        XCTAssertEqual(result.readCount, 3)
        XCTAssertNil(result.failureCode)
    }

    func testReadDrainDoesNotWaitForSlowProcessor() {
        let processor = UDPDatagramProcessor(label: "opv.tests.bsd-read-nonblocking")
        processor.activate(generation: 3)
        let entered = expectation(description: "slow processor entered")
        let completed = expectation(description: "all processor work completed")
        completed.expectedFulfillmentCount = 3
        let release = DispatchSemaphore(value: 0)
        var steps: [BSDUDPSocket.ReadStep] = [
            .datagram(Data([0])), .datagram(Data([1])), .datagram(Data([2])), .wouldBlock,
        ]

        let started = ProcessInfo.processInfo.systemUptime
        let result = BSDUDPSocket.drain(
            readOne: { steps.removeFirst() },
            deliver: { data in
                processor.submit(data, generation: 3) { value in
                    if value[0] == 0 {
                        entered.fulfill()
                        release.wait()
                    }
                    completed.fulfill()
                }
            })
        let drainMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000

        XCTAssertEqual(result.datagramCount, 3)
        XCTAssertLessThan(drainMilliseconds, 50)
        wait(for: [entered], timeout: 1)
        release.signal()
        wait(for: [completed], timeout: 1)
        processor.drain()
    }

    func testConnectedSocketUsesEphemeralPortAndClosesIdempotently() throws {
        let socket = try BSDUDPSocket(
            remoteHost: "127.0.0.1", remotePort: 9,
            queue: DispatchQueue(label: "opv.tests.bsd-lifecycle"))
        XCTAssertTrue(socket.isOpen)
        XCTAssertNotEqual(socket.localPort, 0)
        XCTAssertEqual(BSDUDPSocket.requestedReceiveBufferSize, 2 * 1_024 * 1_024)
        XCTAssertEqual(BSDUDPSocket.minimumDesiredReceiveBufferSize, 1 * 1_024 * 1_024)
        XCTAssertGreaterThan(socket.actualReceiveBufferSize, 0)

        socket.start(onDatagram: { _ in }, onError: { _ in })
        socket.cancel()
        socket.cancel()
        XCTAssertFalse(socket.isOpen)
    }

    func testWindowAckCadenceAndPayloadRemainUnchanged() {
        XCTAssertEqual(DatalinkTransportPolicy.windowAckIntervalMilliseconds, 25)
        XCTAssertEqual(
            DumlTransport.ackPayload(
                peerCursor: 0x1234, ackedDataCursor: 0x5678, extraCursor: 0x9abc),
            [
                0x34, 0x12, 0x34, 0x12, 0, 0, 0, 0,
                0x78, 0x56, 0x78, 0x56, 0, 0, 0, 0,
                0xbc, 0x9a, 0xbc, 0x9a, 0, 0, 0, 0,
                0, 0,
            ])
    }
}
