import CoreVideo
import OpenPocketViewCore
import XCTest
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

    @MainActor
    func testNanoDisplayPacerUsesBoundedStabilityReservoir() {
        XCTAssertEqual(NanoDisplayPacer.framesPerSecond, 30)
        XCTAssertEqual(NanoDisplayPacer.cadence, 1.0 / 30.0, accuracy: 0.000_001)
        XCTAssertEqual(NanoDisplayPacer.targetDepth, 24)
        XCTAssertEqual(NanoDisplayPacer.maximumDepth, 45)
    }

    func testNanoFrameBufferAcceptsDecodedFrameWithoutMainActorHop() throws {
        var created: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                16,
                16,
                kCVPixelFormatType_32BGRA,
                nil,
                &created),
            kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(created)
        let storage = NanoDisplayFrameBuffer()
        let pushed = expectation(description: "decoded frame pushed off main")
        DispatchQueue.global(qos: .userInitiated).async {
            storage.push(
                imageBuffer: pixelBuffer,
                effects: LiveImageEffects(),
                transfer: .rec709,
                trace: nil,
                callbackAt: ProcessInfo.processInfo.systemUptime)
            pushed.fulfill()
        }
        wait(for: [pushed], timeout: 1)

        let metrics = storage.takeMetrics()
        XCTAssertEqual(metrics.inputCount, 1)
        XCTAssertEqual(metrics.depth, 1)
        XCTAssertEqual(metrics.enqueueDurations.count, 1)
    }
}
