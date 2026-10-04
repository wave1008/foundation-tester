// 凍結した端末(adb devices には device のまま載り、`adb shell` が返らない)に、期限なしの
// `adb shell` を撃つ経路を増やさないための走査。期限が無いと1台の凍結が呼び手全体を握る ——
// MCP は呼び出しを順に処理するので、**他の健全な端末への呼び出しまで**返らなくなる(実地で確認)。
//
// 短く返るはずの命令は `adbAnswering`(期限つき)を、長さが読めない命令は入口で
// `requireDeviceAnswers()` を通す。ブリッジのコールド起動は最初の問い合わせが期限つきの門。

import XCTest

final class AndroidDeviceAnswerTimeoutScanTests: XCTestCase {

    private static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTAndroid/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n").map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
    }

    /// 短い命令(keyevent・dumpsys window・settings・force-stop・pm list)を AndroidDriver が素の `adb(` で撃たない
    func testShortDeviceCommandsInTheDriverAreBounded() throws {
        let text = try Self.source("AndroidDriver.swift")
        let unbounded = [
            #"adb(["shell", "input", "keyevent""#,
            #"adb(["shell", "dumpsys", "window""#,
            #"adb(["shell", "settings""#,
            #"adb(["shell", "am", "force-stop""#,
            #"adb(["shell", "pm", "list""#,
        ].filter { text.contains($0) }
        XCTAssertEqual(unbounded, [], "期限なしで端末へ撃つ短い命令がある(adbAnswering / adbProbe を通す)")
        XCTAssertTrue(text.contains("adbAnswering(["), "走査の前提(期限つきの呼び出し)が見つからない")
    }

    /// `pm clear` は所要が読めないので、入口で1回 端末が答えるかを確かめること
    func testClearAppDataChecksTheDeviceAnswersFirst() throws {
        let text = try Self.source("AndroidDriver.swift")
        let start = try XCTUnwrap(text.range(of: "public func clearAppData(bundleID: String) async throws {"))
        let body = text[start.upperBound...].prefix(200)
        let gate = try XCTUnwrap(body.range(of: "try requireDeviceAnswers()"), "clearAppData に門が無い")
        let clear = try XCTUnwrap(body.range(of: #"adb(["shell", "pm", "clear""#))
        XCTAssertLessThan(gate.lowerBound, clear.lowerBound)
    }

    /// ブリッジのコールド起動の最初の問い合わせは期限つき(続く段 = 設定・install・起動はその後ろ)
    func testBridgeColdStartIsGatedByABoundedProbe() throws {
        let text = try Self.source("AndroidBridge.swift")
        let gate = try XCTUnwrap(text.range(of: #"probe = try adbProbe(["shell", "settings", "get", "global", "window_animation_scale"],"#),
                                 "コールド起動の門が期限つきの問い合わせになっていない")
        let firstStage = try XCTUnwrap(text.range(of: "noticePersistentSettingsOnPhysicalDevice()\n        disableAnimations()"))
        XCTAssertLessThan(gate.lowerBound, firstStage.lowerBound)
        XCTAssertTrue(text.contains("} catch ShellError.timedOut {"), "期限切れを「端末が答えない」として断っていない")
    }
}
