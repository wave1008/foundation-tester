// Android 実機の画面は端末の設定で消える(ツールは消灯を抑止しない = 2026-09-05 ユーザー決定)。
// 起こすのが run 開始時の1回だけだと、途中で1回消えた後の全シナリオが launch 500 で落ち、
// 消灯に一言も触れなかった(2026-09-11 Pixel 4a: 22/24 赤)。そこでシナリオごと(子プロセス)と
// MCP の呼び出しごとに1往復で確かめ、消灯・ロック中のときだけ起こす。
// adb の実体は要るので、ここで固めるのは出力の読み方と配線(ソース走査)

import XCTest
@testable import FTAndroid

final class AndroidPhysicalWakeTests: XCTestCase {

    // MARK: - 確認の出力(実機の dumpsys の行をそのまま)

    func testAwakeWithAResumedActivityNeedsNothing() {
        XCTAssertEqual(AndroidPhysicalDevice.awakeAndUnlocked(checkOutput: """
              mWakefulness=Awake
                topResumedActivity=ActivityRecord{b20cf3e u0 com.ftester.e2e.android/.MainActivity t1167}
            """), true)
    }

    func testDozingIsAsleep() {
        XCTAssertEqual(AndroidPhysicalDevice.awakeAndUnlocked(checkOutput: "  mWakefulness=Dozing\n"), false)
        XCTAssertEqual(AndroidPhysicalDevice.awakeAndUnlocked(checkOutput: "  mWakefulness=Asleep\n"), false)
    }

    /// 点いていてもロック画面ならどのアクティビティも resume されない = 起こす(解除する)側
    func testAwakeOnTheLockScreenStillNeedsUnlocking() {
        XCTAssertEqual(AndroidPhysicalDevice.awakeAndUnlocked(checkOutput: "  mWakefulness=Awake\n"), false)
    }

    /// 取れなかったときは起こさない(確かめられないのに撃たない)
    func testUnreadableOutputIsUnknown() {
        XCTAssertNil(AndroidPhysicalDevice.awakeAndUnlocked(checkOutput: ""))
        XCTAssertNil(AndroidPhysicalDevice.awakeAndUnlocked(checkOutput: "error: device offline"))
    }

    // MARK: - 配線(ソース走査)

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// シナリオの子プロセスが、Android の実機に限って、ドライバを作る前に確かめること
    func testEveryScenarioChecksThePhysicalScreenBeforeDriving() throws {
        let code = try source("Sources/FTScenarioRunner/ScenarioRunnerMain.swift")
        guard let branch = code.range(of: "case \"android\":"),
              let driver = code.range(of: "driver = try AndroidDriver(serial: serial)",
                                      range: branch.upperBound..<code.endIndex) else {
            return XCTFail("Android の分岐が見つからない = 走査を見直す")
        }
        let between = String(code[branch.upperBound..<driver.lowerBound])
        XCTAssertTrue(between.contains("DevicePicker.isPhysicalAndroidSerial(serial)"),
                      "実機に絞っていない(エミュレータにも adb を払わせる)")
        XCTAssertTrue(between.contains("AndroidPhysicalDevice.wakeIfAsleep(serial: serial"),
                      "シナリオごとに画面を確かめていない")
    }

    /// 実行中に消えた1本は前の確認では救えないので、**落ちたときだけ**画面を見て名指しする
    /// (緑では撃たない = 失敗経路だけの費用)
    func testAFailedScenarioNamesAScreenThatWentOff() throws {
        let code = try source("Sources/FTScenarioRunner/ScenarioRunnerMain.swift")
        guard let gate = code.range(of: "if !passed, runPlatform == \"android\", let serial,"
                                         + " DevicePicker.isPhysicalAndroidSerial(serial),") else {
            return XCTFail("失敗時の確認が無い(実行中に消えた1本の失敗文が消灯に触れない)")
        }
        let tail = code[gate.upperBound...].prefix(400)
        XCTAssertTrue(tail.contains("AndroidPhysicalDevice.screenAwakeAndUnlocked(serial: serial) == false"),
                      String(tail))
    }

    /// 起こした「✔」の情報行は流さない(子の stderr は errorLogs の枠を1行ずつ取る)
    func testWakeDoesNotSpendAnErrorLogSlotOnSuccess() throws {
        let code = try source("Sources/FTAndroid/AndroidPhysicalDevice.swift")
        XCTAssertTrue(code.contains("if !line.hasPrefix(\"✔\") { log(line) }"), "成功行を流している")
    }

    /// **stayon は true も false も撃たない**(持ち主の「充電中はスリープしない」を消していた)
    func testNeverTouchesTheStayOnSetting() throws {
        let code = try source("Sources/FTAndroid/AndroidPhysicalDevice.swift")
        XCTAssertFalse(code.contains("\"stayon\""), "svc power stayon を撃っている")
    }
}
