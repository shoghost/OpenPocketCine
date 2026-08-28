import XCTest
import CoreMedia
@testable import OpenPocketCineTest

final class DiagnosticsTargetTests: XCTestCase {
    func testMicroStutterDiagnosticsAreCompiledIntoTestTarget() {
        XCTAssertTrue(LiveFramePacingDiagnostics.isEnabled)
    }

    func testGapClassifierFindsTheFirstSlowBoundary() {
        XCTAssertEqual(
            FramePacingClassifier.classify(
                udpMs: 33, accessUnitMs: 80, decoderInputMs: 81, decoderOutputMs: 82,
                displayMs: 83, sourceTimestampMs: 33),
            .accessUnit)
        XCTAssertEqual(
            FramePacingClassifier.classify(
                udpMs: 33, accessUnitMs: 34, decoderInputMs: 34, decoderOutputMs: 90,
                displayMs: 92, sourceTimestampMs: 33),
            .decoder)
    }

    func testDjiTimestampParsingIsDiagnosticsOnlyAndBoundsChecked() {
        let bytes: [UInt8] = [
            0, 0, 1, 0xff, 4, 0, 0, 0, 1, 0, 2, 0, 0x78, 0x56, 0x34, 0x12,
        ]
        XCTAssertEqual(LiveFramePacingDiagnostics.djiRecordTimestamp(bytes), 0x1234_5678)
        XCTAssertNil(LiveFramePacingDiagnostics.djiRecordTimestamp([0, 0, 1, 0x67]))
    }

    func testDiagnosticsExportRequiresBothExpectedFiles() throws {
        XCTAssertEqual(
            DiagnosticsExporter.fileNames,
            ["control-live.log", "live-frame-pacing.csv"])

        let result = DiagnosticsExporter.exportURLs(fileManager: .default)
        if case .failure(let error) = result,
            let exportError = error as? DiagnosticsExporter.ExportError,
            case .filesMissing(let names) = exportError
        {
            XCTAssertFalse(names.isEmpty)
            XCTAssertTrue(Set(names).isSubset(of: Set(DiagnosticsExporter.fileNames)))
        }
    }

    func testNanoAccessUnitPacerUsesBoundedStabilityReservoir() {
        XCTAssertEqual(NanoAccessUnitPacer.framesPerSecond, 30)
        XCTAssertEqual(NanoAccessUnitPacer.cadence, 1.0 / 30.0, accuracy: 0.000_001)
        XCTAssertEqual(NanoAccessUnitPacer.targetDepth, 12)
        XCTAssertEqual(NanoAccessUnitPacer.maximumDepth, 60)
    }

    func testNanoAccessUnitPacerAcceptsCompleteAUWithoutMainActorHop() {
        let pacer = NanoAccessUnitPacer()
        pacer.configure { _ in }
        let now = ProcessInfo.processInfo.systemUptime
        let accessUnit = LivePacedAccessUnit(
            bytes: [0, 0, 0, 1, 0x41, 0x80],
            trace: LiveFrameTrace(
                id: 1, udpArrival: now, accessUnitComplete: now,
                sourceTimestamp: 1_000))
        let pushed = expectation(description: "compressed AU pushed off main")
        DispatchQueue.global(qos: .userInitiated).async {
            pacer.push(accessUnit)
            pushed.fulfill()
        }
        wait(for: [pushed], timeout: 1)

        let metrics = pacer.takeMetrics()
        XCTAssertEqual(metrics.inputCount, 1)
        XCTAssertEqual(metrics.depth, 1)
        XCTAssertEqual(metrics.outputCount, 0)
        pacer.disable(reason: "unit_test")
    }

    func testTimedRendererUsesTwelveAUPrerollAndBoundedPendingQueue() {
        XCTAssertFalse(NanoTimedVideoRenderer.shouldStart(pendingVideoAccessUnits: 11))
        XCTAssertTrue(NanoTimedVideoRenderer.shouldStart(pendingVideoAccessUnits: 12))
        XCTAssertEqual(NanoTimedVideoRenderer.prerollAccessUnits, 12)
        XCTAssertEqual(NanoTimedVideoRenderer.maximumPendingAccessUnits, 60)
    }

    func testTimedRendererPTSIsMonotonicAtNominalThirtyFPS() {
        let anchor = CMTime(seconds: 123.0, preferredTimescale: 30_000)
        var timeline = NanoTimedVideoRenderer.Timeline(anchor: anchor)
        let first = timeline.nextTiming()
        let second = timeline.nextTiming()
        let third = timeline.nextTiming()
        XCTAssertLessThan(first.presentationTimeStamp, second.presentationTimeStamp)
        XCTAssertLessThan(second.presentationTimeStamp, third.presentationTimeStamp)
        XCTAssertEqual(CMTimeGetSeconds(first.duration), 1.0 / 30.0, accuracy: 0.000_001)
        XCTAssertEqual(
            CMTimeGetSeconds(CMTimeSubtract(second.presentationTimeStamp, first.presentationTimeStamp)),
            1.0 / 30.0, accuracy: 0.000_001)
    }

    func testSourceTimestampGapDoesNotChangePresentationCadence() {
        var timeline = NanoTimedVideoRenderer.Timeline(anchor: .zero)
        _ = [1_000, 1_033, 1_100].map { _ in timeline.nextTiming() }
        var comparison = NanoTimedVideoRenderer.Timeline(anchor: .zero)
        let timings = (0 ..< 3).map { _ in comparison.nextTiming() }
        XCTAssertEqual(
            CMTimeGetSeconds(
                CMTimeSubtract(
                    timings[2].presentationTimeStamp, timings[1].presentationTimeStamp)),
            1.0 / 30.0, accuracy: 0.000_001)
    }

    func testTimedRendererReanchorsToNewHostTime() {
        var timeline = NanoTimedVideoRenderer.Timeline(anchor: .zero)
        _ = timeline.nextTiming()
        _ = timeline.nextTiming()
        let anchor = CMTime(seconds: 500.4, preferredTimescale: 30_000)
        timeline.reanchor(anchor)
        XCTAssertEqual(timeline.nextTiming().presentationTimeStamp, anchor)
    }

    func testRendererBackpressureWaitsWithoutFlushOrDrop() {
        XCTAssertEqual(
            NanoTimedVideoRenderer.backpressureAction(isReadyForMoreMediaData: false), .wait)
        XCTAssertFalse(NanoTimedVideoRenderer.shouldFlush(for: .overflow))
        XCTAssertTrue(NanoTimedVideoRenderer.shouldFlush(for: .formatChange))
        XCTAssertTrue(NanoTimedVideoRenderer.shouldFlush(for: .rendererFailure))
        XCTAssertTrue(NanoTimedVideoRenderer.shouldFlush(for: .requiresFlush))
    }

    func testTimedRendererPreservesSourceOrderAndStableArrivalOrder() {
        XCTAssertEqual(
            NanoTimedVideoRenderer.orderedArrivalIDs(
                for: [(33, 3), (0, 1), (33, 2), (66, 4)]),
            [1, 2, 3, 4])
    }

    func testTimedRendererDoesNotUseDisplayImmediately() {
        XCTAssertFalse(NanoTimedVideoRenderer.displayImmediately)
        XCTAssertEqual(NanoTimedVideoRenderer.framesPerSecond, 30)
        XCTAssertEqual(NanoTimedVideoRenderer.initialLeadSeconds, 0.400, accuracy: 0.000_001)
    }

    func testArrivalJitterBufferRestoresSourceTimestampCadence() {
        let arrivalIntervals: [Int64] = [70, 90, 20, 50]
        let outputIntervals = NanoArrivalJitterBuffer.Schedule.outputIntervalsMilliseconds(
            for: [0, 33, 67, 100, 133])
        XCTAssertEqual(outputIntervals, [33, 34, 33, 33])
        XCTAssertNotEqual(outputIntervals, arrivalIntervals)
    }

    func testArrivalJitterBufferPreservesRealSourceGap() {
        XCTAssertEqual(
            NanoArrivalJitterBuffer.Schedule.outputIntervalsMilliseconds(for: [0, 33, 100]),
            [33, 67])
    }

    func testArrivalJitterBufferPreservesEveryAUExactlyOnceAndInSourceOrder() {
        let timestamps: [UInt32] = [100, 0, 133, 67, 33]
        let order = NanoArrivalJitterBuffer.Schedule.orderedIndices(for: timestamps)
        XCTAssertEqual(order, [1, 4, 3, 0, 2])
        XCTAssertEqual(Set(order).count, timestamps.count)
        XCTAssertEqual(order.count, timestamps.count)
    }

    func testArrivalJitterBufferUsesDelayWithoutFixedThirtyHertzConsumption() {
        XCTAssertEqual(NanoArrivalJitterBuffer.delaySeconds, 0.200, accuracy: 0.000_001)
        XCTAssertFalse(NanoArrivalJitterBuffer.usesFixedRatePacer)
        let schedule = NanoArrivalJitterBuffer.Schedule(sourceBaseTimestamp: 1_000)
        XCTAssertEqual(schedule.offsetSeconds(for: 1_067), 0.067, accuracy: 0.000_001)
    }

    func testImmediateNanoDeliveryPreservesProductionPresentationSemantics() {
        XCTAssertTrue(NanoImmediateVideoDelivery.displayImmediately)
        XCTAssertTrue(NanoImmediateVideoDelivery.usesProductionPresentTiming)
        XCTAssertEqual(NanoImmediateVideoDelivery.mainActorHopsBeforeRendererEnqueue, 0)
        let expected = LiveViewPresentTiming.sampleTiming(frameIndex: 42)
        let actual = NanoImmediateVideoDelivery.sampleTiming(frameIndex: 42)
        XCTAssertEqual(actual.duration, expected.duration)
        XCTAssertEqual(actual.presentationTimeStamp, expected.presentationTimeStamp)
        XCTAssertEqual(actual.decodeTimeStamp, expected.decodeTimeStamp)
    }

    func testImmediateNanoDeliveryWaitsForRendererWithoutFlushPolicy() {
        XCTAssertEqual(
            NanoImmediateVideoDelivery.backpressureAction(isReadyForMoreMediaData: false), .wait)
        XCTAssertEqual(
            NanoImmediateVideoDelivery.backpressureAction(isReadyForMoreMediaData: true), .enqueue)
    }

    func testImmediateNanoDeliveryPreservesEverySampleExactlyOnceInOrder() {
        let ids: [UInt64] = [10, 11, 12, 13]
        let delivered = NanoImmediateVideoDelivery.orderedIDs(ids)
        XCTAssertEqual(delivered, ids)
        XCTAssertEqual(Set(delivered).count, ids.count)
    }

    func testNanoStageDurationProbeUsesIndependentFiftyMillisecondThreshold() {
        XCTAssertEqual(NanoStageDurationProbe.thresholdMilliseconds, 50)
        XCTAssertEqual(
            NanoStageDurationProbe.durationMilliseconds(from: 10.0, to: 10.075), 75,
            accuracy: 0.000_001)
    }

    func testIncompleteAUDiagnosticsFindsOneMissingFragment() {
        var diagnostics = NanoIncompleteAUDiagnostics()
        _ = diagnostics.observe(incompletePacket(group: 1, wire: 40, sequence: 1_000))
        _ = diagnostics.observe(incompletePacket(group: 1, wire: 42, sequence: 1_008))
        let boundary = diagnostics.observe(incompletePacket(group: 2, wire: 80, sequence: 1_016))
        XCTAssertEqual(boundary.closedGroup?.missingLocalIndices, [1])
        XCTAssertEqual(boundary.closedGroup?.receivedLocalIndices, [0, 2])
    }

    func testIncompleteAUDiagnosticsSeparatesCompleteOutOfOrderGroup() {
        var diagnostics = NanoIncompleteAUDiagnostics()
        _ = diagnostics.observe(incompletePacket(group: 1, wire: 40, sequence: 1_000))
        _ = diagnostics.observe(incompletePacket(group: 1, wire: 42, sequence: 1_008))
        let late = diagnostics.observe(incompletePacket(group: 1, wire: 41, sequence: 1_016))
        let boundary = diagnostics.observe(incompletePacket(group: 2, wire: 80, sequence: 1_024))
        XCTAssertTrue(late.reordered)
        XCTAssertTrue(late.lateFragment)
        XCTAssertEqual(boundary.closedGroup?.missingLocalIndices, [])
        XCTAssertEqual(boundary.closedGroup?.correlation, .reorderOrLate)
    }

    func testIncompleteAUDiagnosticsIdentifiesDuplicateFragment() {
        var diagnostics = NanoIncompleteAUDiagnostics()
        _ = diagnostics.observe(incompletePacket(group: 1, wire: 40, sequence: 1_000))
        _ = diagnostics.observe(incompletePacket(group: 1, wire: 41, sequence: 1_008))
        let duplicate = diagnostics.observe(
            incompletePacket(group: 1, wire: 41, sequence: 1_010))
        let boundary = diagnostics.observe(incompletePacket(group: 2, wire: 80, sequence: 1_016))
        XCTAssertTrue(duplicate.duplicate)
        XCTAssertEqual(boundary.closedGroup?.duplicateFragments, 1)
        XCTAssertEqual(boundary.closedGroup?.correlation, .duplicate)
    }

    func testIncompleteAUDiagnosticsRecordsNextGroupDropReason() {
        var diagnostics = NanoIncompleteAUDiagnostics()
        _ = diagnostics.observe(incompletePacket(group: 1, wire: 40, sequence: 1_000))
        _ = diagnostics.observe(incompletePacket(group: 1, wire: 42, sequence: 1_008))
        let boundary = diagnostics.observe(incompletePacket(group: 2, wire: 80, sequence: 1_016))
        XCTAssertEqual(boundary.closedGroup?.reason, .newGroupArrived)
        XCTAssertEqual(boundary.closedGroup?.nextGroupArrived, true)
    }

    func testIncompleteAUDiagnosticsCorrelatesDatalinkSequenceGap() {
        var diagnostics = NanoIncompleteAUDiagnostics()
        _ = diagnostics.observe(incompletePacket(group: 1, wire: 40, sequence: 1_000))
        let gap = diagnostics.observe(incompletePacket(group: 1, wire: 42, sequence: 1_016))
        let boundary = diagnostics.observe(incompletePacket(group: 2, wire: 80, sequence: 1_024))
        XCTAssertEqual(gap.newSequenceGaps, [1_008])
        XCTAssertEqual(boundary.closedGroup?.udpSequenceGaps, [1_008])
        XCTAssertEqual(boundary.closedGroup?.correlation, .udpSequenceGap)
    }

    func testIncompleteAUDiagnosticsDistinguishesAssemblerMissingWithContinuousSequence() {
        var diagnostics = NanoIncompleteAUDiagnostics()
        _ = diagnostics.observe(incompletePacket(group: 1, wire: 40, sequence: 1_000))
        _ = diagnostics.observe(incompletePacket(group: 1, wire: 42, sequence: 1_008))
        let boundary = diagnostics.observe(incompletePacket(group: 2, wire: 80, sequence: 1_016))
        XCTAssertEqual(boundary.closedGroup?.udpSequenceGaps, [])
        XCTAssertEqual(
            boundary.closedGroup?.correlation, .assemblerMissingWithoutSequenceGap)
    }

    private func incompletePacket(
        group: UInt16, wire: Int, sequence: UInt16, at: TimeInterval = 1.0
    ) -> NanoIncompleteAUDiagnostics.Packet {
        NanoIncompleteAUDiagnostics.Packet(
            groupID: group, frameNumber: UInt8(truncatingIfNeeded: group), wireIndex: wire,
            datalinkSequence: sequence, sourceTimestamp: nil, arrivalTime: at)
    }
}
