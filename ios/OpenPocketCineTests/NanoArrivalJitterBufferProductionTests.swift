import XCTest
@testable import OpenPocketCine

final class NanoArrivalJitterBufferProductionTests: XCTestCase {
    func testProductionCompilesSourceClockArrivalBufferPolicy() {
        XCTAssertEqual(NanoArrivalJitterBuffer.delaySeconds, 0.200, accuracy: 0.000_001)
        XCTAssertFalse(NanoArrivalJitterBuffer.usesFixedRatePacer)
        XCTAssertEqual(
            NanoArrivalJitterBuffer.Schedule.outputIntervalsMilliseconds(
                for: [0, 33, 67, 100, 167]),
            [33, 34, 33, 67])
    }

    func testProductionArrivalBufferDoesNotDropOrDuplicateScheduleEntries() {
        let timestamps: [UInt32] = [100, 0, 133, 67, 33]
        let order = NanoArrivalJitterBuffer.Schedule.orderedIndices(for: timestamps)
        XCTAssertEqual(order, [1, 4, 3, 0, 2])
        XCTAssertEqual(Set(order).count, timestamps.count)
        XCTAssertEqual(order.count, timestamps.count)
    }
}
