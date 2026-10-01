// FastLaunchDriver が「前面に届かなかった」と読む 500 の本文の目印と、ランナーの attach の本文の同期。
// ランナーは XCUITest の例外などでも 500 を返すので、ホストは status だけでなく目印で読む。
// 片方の文言だけ変えると、前面に届かなかった回の注記(activatedBeforeForeground)が黙って消える。

import XCTest
@testable import FTBridgeClient

final class FastLaunchAttachMarkerSyncTests: XCTestCase {

    func testRunnerAttachRefusalCarriesTheMarkerTheHostReads() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let router = try String(contentsOf: root.appendingPathComponent(
            "Runner/FleetestRunnerUITests/BridgeRouter.swift"), encoding: .utf8)
        XCTAssertTrue(router.contains("throw BridgeError(500, \"\(FastLaunchDriver.notInForegroundMarker):"),
                      "ランナーの attach の 500 の本文が目印で始まっていない")
    }
}
