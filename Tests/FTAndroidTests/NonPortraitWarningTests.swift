// run 開始時に縦向きでない iOS のデバイスを警告する(ProfileWorkerFactory.warnOnNonPortraitIOS)。
// 横向きのまま残った Simulator で、縦向き前提のシナリオが「見つからない」で落ちた(同じ台で2回)。

import XCTest
@testable import FTCore
@testable import FTAndroid

final class NonPortraitWarningTests: XCTestCase {

    func testLandscapeIsWarnedWithTheDeviceName() throws {
        let line = try XCTUnwrap(ProfileWorkerFactory.nonPortraitWarning(
            label: "iPhone 17 Pro(iOS 27.0)-08(ios:8146)", orientation: .landscape))
        XCTAssertTrue(line.contains("iPhone 17 Pro(iOS 27.0)-08"), line)
        XCTAssertTrue(line.contains("landscape"), line)
    }

    func testPortraitAndUnknownAreSilent() {
        XCTAssertNil(ProfileWorkerFactory.nonPortraitWarning(label: "d", orientation: .portrait))
        XCTAssertNil(ProfileWorkerFactory.nonPortraitWarning(label: "d", orientation: nil),
                     "読めない台は黙って飛ばす(不明を警告にしない)")
    }

    /// 開始時の準備(3つの供給口が共有する1箇所)から呼ばれていること
    func testRunStartPreparationCallsTheCheck() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTAndroid/ProfileWorkerFactory.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let start = text.range(of: "public static func prepareDevicesOnStart("),
              let end = text.range(of: "\n    }\n", range: start.upperBound..<text.endIndex)
        else { return XCTFail("prepareDevicesOnStart が見つからない") }
        XCTAssertTrue(text[start.lowerBound..<end.upperBound].contains("await warnOnNonPortraitIOS(workers, log: log)"))
    }
}
