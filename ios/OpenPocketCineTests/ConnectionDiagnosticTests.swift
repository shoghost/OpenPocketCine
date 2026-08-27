import Foundation
import NetworkExtension
import XCTest

@testable import OpenPocketCine

final class ConnectionDiagnosticTests: XCTestCase {
    func testStagesCoverThePhysicalConnectionSpineInOrder() {
        XCTAssertEqual(
            ConnectionDiagnosticStage.allCases,
            [
                .bleConnect, .pairing, .approval, .wifiSSID, .wifiPassword,
                .hotspotApply, .wifiVerification, .datalink,
            ]
        )
    }

    func testNSErrorDomainCodeAndDescriptionArePreserved() {
        let error = NSError(
            domain: NEHotspotConfigurationErrorDomain,
            code: NEHotspotConfigurationError.internal.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "internal error"]
        )
        let info = ConnectionDiagnosticErrorInfo(error: error)

        XCTAssertEqual(info.domain, NEHotspotConfigurationErrorDomain)
        XCTAssertEqual(info.code, NEHotspotConfigurationError.internal.rawValue)
        XCTAssertEqual(info.description, "internal error")
        XCTAssertTrue(info.isHotspotInternalError)
    }

    func testJoinErrorRetainsUnderlyingHotspotMetadata() {
        let error = WiFiJoiner.JoinError.failed(
            domain: NEHotspotConfigurationErrorDomain,
            code: NEHotspotConfigurationError.internal.rawValue,
            description: "internal error"
        )
        let info = ConnectionDiagnosticErrorInfo(error: error)

        XCTAssertEqual(info.domain, NEHotspotConfigurationErrorDomain)
        XCTAssertEqual(info.code, NEHotspotConfigurationError.internal.rawValue)
        XCTAssertEqual(info.description, "internal error")
        XCTAssertTrue(error.allowsManualWifiFallback)
    }

    func testManualWifiFallbackIsLimitedToHotspotInternalError() {
        XCTAssertFalse(
            WiFiJoiner.JoinError.failed(
                domain: NEHotspotConfigurationErrorDomain,
                code: NEHotspotConfigurationError.userDenied.rawValue,
                description: "denied"
            ).allowsManualWifiFallback
        )
        XCTAssertFalse(
            WiFiJoiner.JoinError.failed(
                domain: "example.error", code: NEHotspotConfigurationError.internal.rawValue,
                description: "internal"
            ).allowsManualWifiFallback
        )
        XCTAssertFalse(WiFiJoiner.JoinError.pathNotReady.allowsManualWifiFallback)
    }
}
