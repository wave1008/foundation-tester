// ワーカー label の生成と解析の往復。
// RunEvent は platform を運ばないため、集計側は label から platform を戻すしかない。
// デバイス名は "(" や ":" を含みうる(実例: "Pixel 9(Android 15)-01")ので、素朴な split では
// デバイス名を platform と誤認する(実際に稼働率集計が誤った値を出した)。

import XCTest
import FTCore

final class RunWorkerLabelTests: XCTestCase {

    func testRoundTripForProfileLabels() {
        let cases: [(name: String, platform: String, id: String)] = [
            ("シミュ1", "ios", "8123"),
            ("Pixel 9(Android 15)-01", "android", "emulator-5554"),   // 名前が括弧を含む
            ("実機:A", "android", "R5CT30ABCDE"),                      // 名前がコロンを含む
            ("iPhone 17 Pro(iOS 27.0)-06", "ios", "8125"),
        ]
        for c in cases {
            let label = RunWorker.makeLabel(deviceName: c.name, platform: c.platform, id: c.id)
            XCTAssertEqual(RunWorker.platform(fromLabel: label), c.platform,
                           "往復できること: \(label)")
        }
    }

    func testParsesNonProfileLabels() {
        // --port/--serial 経路(Fleetest.swift)が作る形式
        XCTAssertEqual(RunWorker.platform(fromLabel: "ios:8123"), "ios")
        XCTAssertEqual(RunWorker.platform(fromLabel: "android"), "android")
    }

    func testReturnsNilForUnknownPlatform() {
        // 解釈できない label は nil。呼び出し側が "?" 等へ寄せる(黙って誤った platform にしない)
        XCTAssertNil(RunWorker.platform(fromLabel: "Pixel 9(Android 15)-01"))
        XCTAssertNil(RunWorker.platform(fromLabel: "windows:1"))
        XCTAssertNil(RunWorker.platform(fromLabel: ""))
    }

    func testPrefersTrailingGroupOverLeadingText() {
        // 名前の側に "ios" が入っていても、末尾の括弧群が正
        let label = RunWorker.makeLabel(deviceName: "ios風の名前", platform: "android", id: "x")
        XCTAssertEqual(RunWorker.platform(fromLabel: label), "android")
    }
}
