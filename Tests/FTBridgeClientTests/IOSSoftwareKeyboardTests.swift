// シミュレータのソフトキーボードを縮めない設定(IOSSoftwareKeyboard)。Mac の再起動の後、
// AutomaticMinimizationEnabled が true のデバイスだけ keyboardIsShown が決定的に赤になった(2026-09-19)。

import XCTest
@testable import FTBridgeClient

final class IOSSoftwareKeyboardTests: XCTestCase {

    func testWritesTheKeyboardMinimizationOffForTheGivenSimulator() {
        XCTAssertEqual(IOSSoftwareKeyboard.writeArguments(udid: "UDID-1"),
                       ["xcrun", "simctl", "spawn", "UDID-1", "defaults", "write",
                        "com.apple.keyboard.preferences", "AutomaticMinimizationEnabled", "-bool", "false"],
                       "書く先は com.apple.keyboard.preferences(com.apple.Preferences に書いても効かなかった)")
    }

    /// 供給の2経路(run の iOS 供給・ブリッジのコールド起動)が、シミュレータにだけ撃つ
    func testBothSupplyPathsApplyItToSimulatorsOnly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let factory = try String(contentsOf: root.appendingPathComponent("Sources/FTAndroid/ProfileWorkerFactory.swift"),
                                 encoding: .utf8)
        // 実機を除いた一覧(simulators)を台ごとに並行に撃つ(1行の supplyStage のループは別なので改行まで含めて引く)
        let simulatorsOnly = try XCTUnwrap(factory.range(of: "let simulators = provisioned.filter { !$0.physical }"))
        let loop = try XCTUnwrap(factory.range(of: "for device in simulators {\n",
                                                range: simulatorsOnly.upperBound..<factory.endIndex))
        let loopEnd = try XCTUnwrap(factory.range(of: "\n        }", range: loop.upperBound..<factory.endIndex))
        XCTAssertTrue(factory[loop.upperBound..<loopEnd.lowerBound].contains("IOSSoftwareKeyboard.apply(udid: device.udid"),
                      "run の iOS 供給が設定を撃っていない")

        let launcher = try String(contentsOf: root.appendingPathComponent("Sources/FTBridgeClient/BridgeLauncher.swift"),
                                  encoding: .utf8)
        XCTAssertTrue(launcher.contains("enableReduceMotion()\n                    keepSoftwareKeyboardShown()"),
                      "ブリッジのコールド起動が設定を撃っていない")
        let body = try XCTUnwrap(launcher.range(of: "private func keepSoftwareKeyboardShown() {"))
        let bodyEnd = try XCTUnwrap(launcher.range(of: "\n    }", range: body.upperBound..<launcher.endIndex))
        XCTAssertTrue(launcher[body.upperBound..<bodyEnd.lowerBound].contains("if physical { return }"),
                      "実機に simctl spawn を撃たない")
    }
}
