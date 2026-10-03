// 明示された serial は adb devices の全行(状態つき)と照らし、一覧に1行も無いときだけ断る
// (AndroidTargetResolution.explicitSerialRefusal)。断らないと adb forward の失敗が
// 「止まっている・応答が遅い」という案内に化けていた(2026-10-03 負荷テストの CLI ファズ)

import XCTest
@testable import FTAndroid

final class AndroidExplicitSerialRefusalTests: XCTestCase {

    func testRefusesOnlyASerialThatAdbDoesNotListAtAll() {
        let listed = ["emulator-5554": "device", "R5CT": "unauthorized", "emulator-5556": "offline"]
        XCTAssertEqual(AndroidTargetResolution.explicitSerialRefusal(serial: "emulator-9999", listed: listed),
                       .notListed(serial: "emulator-9999"))
        XCTAssertNil(AndroidTargetResolution.explicitSerialRefusal(serial: "emulator-5554", listed: listed))
    }

    /// offline / unauthorized は「居ない」ではない(adb の失敗文に事実を言わせる)
    func testOfflineAndUnauthorizedAreNotCalledDisconnected() {
        let listed = ["R5CT": "unauthorized", "emulator-5556": "offline"]
        XCTAssertNil(AndroidTargetResolution.explicitSerialRefusal(serial: "R5CT", listed: listed))
        XCTAssertNil(AndroidTargetResolution.explicitSerialRefusal(serial: "emulator-5556", listed: listed))
    }

    /// 一覧が引けない(nil)は不明 = 断らない
    func testUnreadableListIsNotARefusal() {
        XCTAssertNil(AndroidTargetResolution.explicitSerialRefusal(serial: "emulator-9999", listed: nil))
    }

    func testMessageNamesTheSerialAndTheCheck() {
        XCTAssertEqual(AndroidTargetError.notListed(serial: "emulator-9999").errorDescription,
            "serial emulator-9999 is not connected to adb on this machine (`adb devices` does not list it"
            + " — a typo, an unplugged device, or an emulator that is not running). Check `adb devices -l`.")
    }

    /// 「adb devices does not list it」と言う3箇所は、一覧の**全行**(offline / unauthorized も)で照らす。
    /// state=device だけの `connectedSerials()` で照らすと、載っている端末を「載っていない」と断じる
    func testNotListedClaimsCheckEveryListedLine() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        for path in ["Sources/FTAndroid/AndroidTargetResolution.swift",
                     "Sources/FTAndroid/AndroidLogcat.swift",
                     "Sources/fleetest-mcp/MCPServer+ConnectionLoss.swift"] {
            let code = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            let lines = code.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            XCTAssertTrue(lines.contains { $0.contains("listedSerialStates()") }, "\(path) が全行の一覧で照らしていない")
            // AndroidTargetResolution の connectedSerials は serial 省略時の自動採用(使える端末 = state=device だけ)で正当
            if path.hasSuffix("AndroidTargetResolution.swift") { continue }
            XCTAssertFalse(lines.contains { $0.contains("connectedSerials()") }, "\(path) が state=device だけの一覧で照らしている")
        }
    }
}
