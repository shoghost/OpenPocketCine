import XCTest
@testable import OpenPocketCine

final class NanoArrivalJitterBufferProductionTests: XCTestCase {
    func testProductionUsesDJIQueueDelayFeedbackPolicy() {
        XCTAssertEqual(
            NanoArrivalJitterBuffer.targetQueueDelaySeconds, 0.200, accuracy: 0.000_001)
        XCTAssertEqual(
            NanoArrivalJitterBuffer.estimationWindowSeconds, 2.0, accuracy: 0.000_001)
        XCTAssertEqual(
            NanoArrivalJitterBuffer.feedbackDeadbandSeconds, 0.010, accuracy: 0.000_001)
        XCTAssertEqual(
            NanoArrivalJitterBuffer.feedbackStepSeconds, 0.005, accuracy: 0.000_001)
        XCTAssertFalse(NanoArrivalJitterBuffer.usesFixedRatePacer)
    }

    func testStableThirtyFpsArrivalSelectsThirtyFpsCadence() throws {
        let arrivals = (0..<61).map { Double($0) / 30 }
        let interval = try XCTUnwrap(
            NanoArrivalJitterBuffer.Policy.nominalInterval(arrivalTimes: arrivals))
        XCTAssertEqual(interval, 1.0 / 30.0, accuracy: 0.000_001)
    }

    func testStableTwentyFiveFpsArrivalSelectsTwentyFiveFpsCadence() throws {
        let arrivals = (0..<51).map { Double($0) / 25 }
        let interval = try XCTUnwrap(
            NanoArrivalJitterBuffer.Policy.nominalInterval(arrivalTimes: arrivals))
        XCTAssertEqual(interval, 1.0 / 25.0, accuracy: 0.000_001)
    }

    func testMissingAUDoesNotBecomeSourceTimestampSizedPlayoutHole() {
        let arrivals = [0.000, 0.033, 0.066, 0.132, 0.165, 0.198]
        let intervals = NanoArrivalJitterBuffer.Policy.simulatedReleaseIntervals(
            arrivalTimes: arrivals)
        XCTAssertEqual(intervals.count, arrivals.count - 1)
        XCTAssertFalse(intervals.contains { $0 >= 0.060 })
    }

    func testQueueDelayFeedbackSpeedsUpAndSlowsDown() {
        let nominal = 1.0 / 30.0
        let fast = NanoArrivalJitterBuffer.Policy.releaseInterval(
            nominal: nominal, queueDelay: 0.211)
        let steady = NanoArrivalJitterBuffer.Policy.releaseInterval(
            nominal: nominal, queueDelay: 0.200)
        let upperBoundary = NanoArrivalJitterBuffer.Policy.releaseInterval(
            nominal: nominal,
            queueDelay: NanoArrivalJitterBuffer.targetQueueDelaySeconds
                + NanoArrivalJitterBuffer.feedbackDeadbandSeconds)
        let lowerBoundary = NanoArrivalJitterBuffer.Policy.releaseInterval(
            nominal: nominal,
            queueDelay: NanoArrivalJitterBuffer.targetQueueDelaySeconds
                - NanoArrivalJitterBuffer.feedbackDeadbandSeconds)
        let slow = NanoArrivalJitterBuffer.Policy.releaseInterval(
            nominal: nominal, queueDelay: 0.189)
        XCTAssertEqual(fast, nominal - 0.005, accuracy: 0.000_001)
        XCTAssertEqual(steady, nominal, accuracy: 0.000_001)
        XCTAssertEqual(upperBoundary, nominal, accuracy: 0.000_001)
        XCTAssertEqual(lowerBoundary, nominal, accuracy: 0.000_001)
        XCTAssertEqual(slow, nominal + 0.005, accuracy: 0.000_001)
    }

    func testProcessingCostIsSubtractedFromReleaseSleep() {
        let sleep = NanoArrivalJitterBuffer.Policy.releaseInterval(
            nominal: 0.040, queueDelay: 0.200, processingCost: 0.007)
        XCTAssertEqual(sleep, 0.033, accuracy: 0.000_001)
    }

    func testUnderflowWaitsForTargetQueueDelayBeforeRestart() {
        XCTAssertFalse(NanoArrivalJitterBuffer.Policy.hasRefilled(queueDelay: 0.150))
        XCTAssertTrue(NanoArrivalJitterBuffer.Policy.hasRefilled(queueDelay: 0.200))
    }

    func testProductionQueuePreservesEveryAUOnceInArrivalOrder() {
        let ids = [9, 2, 7, 4, 1]
        let output = NanoArrivalJitterBuffer.Policy.preservesOrder(ids)
        XCTAssertEqual(output, ids)
        XCTAssertEqual(output.count, ids.count)
    }
}
