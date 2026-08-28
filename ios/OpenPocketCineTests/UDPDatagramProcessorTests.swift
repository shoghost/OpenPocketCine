import Foundation
import XCTest
@testable import OpenPocketCine

final class UDPDatagramProcessorTests: XCTestCase {
    func testBurstPreservesDatagramOrderExactlyOnce() {
        let processor = UDPDatagramProcessor(label: "opv.tests.udp-order")
        processor.activate(generation: 7)
        let received = LockedBytes()
        let done = expectation(description: "all datagrams processed")
        done.expectedFulfillmentCount = 128

        for value in UInt8.min...127 {
            processor.submit(Data([value]), generation: 7) { data in
                received.append(data[0])
                done.fulfill()
            }
        }

        wait(for: [done], timeout: 2)
        processor.drain()
        XCTAssertEqual(received.values, Array(UInt8.min...127))
    }

    func testSubmitDoesNotWaitForProcessorCompletion() {
        let processor = UDPDatagramProcessor(label: "opv.tests.udp-nonblocking")
        processor.activate(generation: 1)
        let entered = expectation(description: "processor entered")
        let finished = expectation(description: "processor released")
        let release = DispatchSemaphore(value: 0)
        processor.submit(Data([1]), generation: 1) { _ in
            entered.fulfill()
            release.wait()
            finished.fulfill()
        }
        wait(for: [entered], timeout: 1)

        let started = ProcessInfo.processInfo.systemUptime
        processor.submit(Data([2]), generation: 1) { _ in }
        let submitMilliseconds =
            (ProcessInfo.processInfo.systemUptime - started) * 1_000

        release.signal()
        wait(for: [finished], timeout: 1)
        processor.drain()
        XCTAssertLessThan(submitMilliseconds, 50)
    }

    func testGenerationChangeRejectsOldSessionDatagrams() {
        let processor = UDPDatagramProcessor(label: "opv.tests.udp-generation")
        let received = LockedBytes()
        processor.activate(generation: 10)
        processor.activate(generation: 11)
        processor.submit(Data([10]), generation: 10) { data in
            received.append(data[0])
        }
        processor.submit(Data([11]), generation: 11) { data in
            received.append(data[0])
        }

        processor.drain()
        XCTAssertEqual(received.values, [11])
    }

    func testWindowAckCadenceRemainsFortyHertz() {
        XCTAssertEqual(DatalinkTransportPolicy.windowAckIntervalMilliseconds, 25)
    }
}

private final class LockedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt8] = []

    var values: [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: UInt8) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
