import UIKit
import XCTest

@testable import OpenPocketCine

final class StreamingOrientationTests: XCTestCase {
    func testStreamingModeAllowsBothLandscapeOrientationsOnly() {
        let mask = StreamingOrientationPolicy.supportedOrientations(
            streaming: true, idiom: .phone)

        XCTAssertEqual(mask, .landscape)
        XCTAssertTrue(mask.contains(.landscapeLeft))
        XCTAssertTrue(mask.contains(.landscapeRight))
        XCTAssertFalse(mask.contains(.portrait))
        XCTAssertFalse(mask.contains(.portraitUpsideDown))
    }

    func testNormalModeRestoresPhoneOrientations() {
        XCTAssertEqual(
            StreamingOrientationPolicy.supportedOrientations(streaming: false, idiom: .phone),
            .allButUpsideDown
        )
    }

    func testNormalModeRestoresIPadOrientations() {
        XCTAssertEqual(
            StreamingOrientationPolicy.supportedOrientations(streaming: false, idiom: .pad),
            .all
        )
    }
}
