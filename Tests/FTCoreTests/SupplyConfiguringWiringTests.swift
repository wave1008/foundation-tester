// 供給の後のシミュレータの設定の書き込みの間は、run ボードの行を configuring にする(拡張は「デバイスを設定しています」)。
// 無いと全台 ready の「テストを開始しています」が、まだ準備中のこの間(実測 8 台で約 16 秒)も出ていた

import XCTest
@testable import FTCore

final class SupplyConfiguringWiringTests: XCTestCase {
    /// 拡張(runBoardModel.ts の SUPPLY_PROGRESS_STEPS・webview の runBoard.js)はこの文字列で読む
    func testConfiguringRawValueIsPinned() {
        XCTAssertEqual(RunProgressSupply.Step.configuring.rawValue, "configuring")
    }

    /// 書き込みの前に全台を configuring にし、台ごとに並行に書き込んで、その台が済んだら ready に戻す
    func testBuildIOSWorkersReportsConfiguringAroundTheSettingsWrites() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTAndroid/ProfileWorkerFactory.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let configuring = try XCTUnwrap(text.range(of: #"supplyStage?(device.name, "ios", .configuring)"#))
        let group = try XCTUnwrap(text.range(of: "await withTaskGroup(of: Void.self) { group in",
                                             range: configuring.upperBound..<text.endIndex),
                                  "設定の書き込みを台ごとに並行に撃っていない(順に撃つと 8 台で約 16 秒)")
        let reduceMotion = try XCTUnwrap(text.range(of: "IOSReduceMotion.apply(udid: device.udid,",
                                                    range: group.upperBound..<text.endIndex))
        let keyboard = try XCTUnwrap(text.range(of: "IOSSoftwareKeyboard.apply(udid: device.udid, warn: { warn($0) })",
                                                range: reduceMotion.upperBound..<text.endIndex))
        let ready = try XCTUnwrap(text.range(of: #"supplyStage?(device.name, "ios", .ready)"#,
                                             range: keyboard.upperBound..<text.endIndex))
        XCTAssertLessThan(text.distance(from: keyboard.upperBound, to: ready.lowerBound), 80,
                          "書き終えた直後に ready へ戻していない")
    }
}
