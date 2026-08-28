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

    func testArrivalJitterBufferEstimatesArrivalCadenceWithoutFixedFPS() throws {
        let thirty = try XCTUnwrap(
            NanoArrivalJitterBuffer.Policy.nominalInterval(
                arrivalTimes: (0..<61).map { Double($0) / 30 }))
        let twentyFive = try XCTUnwrap(
            NanoArrivalJitterBuffer.Policy.nominalInterval(
                arrivalTimes: (0..<51).map { Double($0) / 25 }))
        XCTAssertEqual(thirty, 1.0 / 30.0, accuracy: 0.000_001)
        XCTAssertEqual(twentyFive, 1.0 / 25.0, accuracy: 0.000_001)
    }

    func testArrivalJitterBufferDoesNotReplayMissingSourceTimestampGap() {
        let arrivals = [0.000, 0.033, 0.066, 0.132, 0.165, 0.198]
        let output = NanoArrivalJitterBuffer.Policy.simulatedReleaseIntervals(
            arrivalTimes: arrivals)
        XCTAssertFalse(output.contains { $0 >= 0.060 })
    }

    func testArrivalJitterBufferPreservesEveryAUExactlyOnceInArrivalOrder() {
        let ids = [100, 0, 133, 67, 33]
        let output = NanoArrivalJitterBuffer.Policy.preservesOrder(ids)
        XCTAssertEqual(output, ids)
        XCTAssertEqual(output.count, ids.count)
    }

    func testArrivalJitterBufferUsesDelayWithoutFixedThirtyHertzConsumption() {
        XCTAssertEqual(
            NanoArrivalJitterBuffer.targetQueueDelaySeconds, 0.200, accuracy: 0.000_001)
        XCTAssertFalse(NanoArrivalJitterBuffer.usesFixedRatePacer)
        XCTAssertEqual(
            NanoArrivalJitterBuffer.Policy.releaseInterval(
                nominal: 0.040, queueDelay: 0.200),
            0.040, accuracy: 0.000_001)
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

    func testWindowAckDiagnosticsMeasuresFortyHertzAtTwentyFiveMilliseconds() {
        let diagnostics = NanoWindowAckDiagnostics()
        var summary: NanoWindowAckDiagnostics.Summary?
        for index in 0...200 {
            summary = diagnostics.noteAck(
                at: Double(index) * 0.025, ackSequence: 0,
                windowSequence: UInt16(index &* 8)).summary ?? summary
        }
        XCTAssertEqual(summary?.rateHz ?? 0, 40, accuracy: 0.001)
        XCTAssertEqual(summary?.intervalMedianMilliseconds ?? 0, 25, accuracy: 0.001)
    }

    func testWindowAckDiagnosticsDetectsGapOverFiftyMilliseconds() {
        let diagnostics = NanoWindowAckDiagnostics()
        _ = diagnostics.noteAck(at: 10, ackSequence: 0, windowSequence: 100)
        let result = diagnostics.noteAck(at: 10.051, ackSequence: 0, windowSequence: 108)
        XCTAssertEqual(result.gap?.intervalMilliseconds ?? 0, 51, accuracy: 0.001)
        XCTAssertEqual(result.gap?.previousWindowSequence, 100)
        XCTAssertEqual(result.gap?.currentWindowSequence, 108)
    }

    func testWindowAckDiagnosticsDetectsGapOverOneHundredMilliseconds() {
        let diagnostics = NanoWindowAckDiagnostics()
        _ = diagnostics.noteAck(at: 20, ackSequence: 0, windowSequence: 200)
        let result = diagnostics.noteAck(at: 20.125, ackSequence: 0, windowSequence: 208)
        XCTAssertEqual(result.gap?.intervalMilliseconds ?? 0, 125, accuracy: 0.001)
    }

    func testWindowAckDiagnosticsSummaryCountsLongGaps() {
        let diagnostics = NanoWindowAckDiagnostics()
        _ = diagnostics.noteAck(at: 0, ackSequence: 0, windowSequence: 0)
        _ = diagnostics.noteAck(at: 0.025, ackSequence: 0, windowSequence: 8)
        _ = diagnostics.noteAck(at: 0.085, ackSequence: 0, windowSequence: 16)
        _ = diagnostics.noteAck(at: 0.210, ackSequence: 0, windowSequence: 24)
        let result = diagnostics.noteAck(at: 5.250, ackSequence: 0, windowSequence: 32)
        XCTAssertEqual(result.summary?.gapsOver50Milliseconds, 3)
        XCTAssertEqual(result.summary?.gapsOver100Milliseconds, 2)
        XCTAssertEqual(result.summary?.gapsOver200Milliseconds, 1)
    }

    func testWindowAckDiagnosticsCorrelatesIncompleteAUWithRecentAckState() {
        let diagnostics = NanoWindowAckDiagnostics()
        for index in 0...40 {
            _ = diagnostics.noteAck(
                at: Double(index) * 0.025, ackSequence: 0,
                windowSequence: UInt16(index &* 8))
        }
        let correlation = diagnostics.correlation(at: 1.100)
        XCTAssertEqual(correlation.lastAckAgeMilliseconds ?? 0, 100, accuracy: 0.001)
        XCTAssertEqual(correlation.ackRateLastSecondHz, 37, accuracy: 0.001)
        XCTAssertEqual(correlation.maxAckGapLastSecondMilliseconds, 100, accuracy: 0.001)
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
