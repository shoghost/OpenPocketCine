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
    func testNanoDisplayPacerUsesBoundedThreeFrameReservoir() {
        XCTAssertEqual(NanoDisplayPacer.framesPerSecond, 30)
        XCTAssertEqual(NanoDisplayPacer.cadence, 1.0 / 30.0, accuracy: 0.000_001)
        XCTAssertEqual(NanoDisplayPacer.targetDepth, 3)
        XCTAssertEqual(NanoDisplayPacer.maximumDepth, 6)
    }
}
