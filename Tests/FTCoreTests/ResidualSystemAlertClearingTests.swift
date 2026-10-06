// 各シナリオの前に残ったシステムアラートを「消すか・警告だけか・何もしないか」と、その文言

import XCTest
@testable import FTCore

final class ResidualSystemAlertClearingTests: XCTestCase {

    private let photos = SystemAlertProbeResponse(
        present: true, title: "“App”に写真ライブラリへのアクセスを許可しますか?",
        buttons: ["写真を選択", "フルアクセスを許可", "許可しない"])

    private func plan(_ probe: SystemAlertProbeResponse?, physical: Bool = false,
                      canRebuildBridge: Bool = true) -> ResidualSystemAlertClearing.Plan {
        ResidualSystemAlertClearing.plan(probe: probe, label: "iPhone-07(ios:8126)", physical: physical,
                                         canRebuildBridge: canRebuildBridge)
    }

    /// 判定できない(旧ランナー・問い合わせの失敗)とき・居ないときは何もしない
    func testNothingWhenAbsentOrUnknown() {
        XCTAssertEqual(plan(nil), .nothing)
        XCTAssertEqual(plan(SystemAlertProbeResponse(present: false)), .nothing)
    }

    private func alert(_ buttons: [String]) -> SystemAlertProbeResponse {
        SystemAlertProbeResponse(present: true, title: "T", buttons: buttons)
    }

    /// 1段目: 副作用の無いボタン(完全一致)。実機でも押す
    func testPressesAHarmlessButtonFirst() {
        XCTAssertEqual(plan(alert(["削除", "キャンセル"])), .press(button: "キャンセル", deniesPermission: false))
        XCTAssertEqual(plan(alert(["Close"]), physical: true), .press(button: "Close", deniesPermission: false))
        // 拒否側と並んでいても副作用の無い方を先に押す
        XCTAssertEqual(plan(alert(["許可しない", "キャンセル"])), .press(button: "キャンセル", deniesPermission: false))
    }

    /// 「OK」はボタンが1つだけのときだけ(複数あるときは是認の意味になりうる)
    func testPressesOKOnlyWhenItIsTheSoleButton() {
        XCTAssertEqual(plan(alert(["OK"])), .press(button: "OK", deniesPermission: false))
        XCTAssertEqual(plan(alert(["OK", "設定"])), .clear)
    }

    /// 2段目: 権限の拒否側。押すと権限が拒否になるので、その旨を立てる
    func testPressesThePermissionDenyButtonAndSaysSo() {
        XCTAssertEqual(plan(photos), .press(button: "許可しない", deniesPermission: true))
        XCTAssertEqual(plan(alert(["Don’t Allow", "Allow"]), physical: true),
                       .press(button: "Don’t Allow", deniesPermission: true))
        XCTAssertEqual(plan(alert(["Don't Allow", "Allow"])), .press(button: "Don't Allow", deniesPermission: true))
    }

    /// 是認側は押さない・前方一致や部分一致で押さない(「キャンセルして削除」は「キャンセル」ではない)
    func testNeverPressesAnAffirmingOrPartiallyMatchingButton() {
        XCTAssertEqual(plan(alert(["許可", "Allow", "OK", "続ける"])), .clear)
        XCTAssertEqual(plan(alert(["キャンセルして削除", "閉じないで続ける"])), .clear)
    }

    /// 3段目: 押せるボタンが無ければ Simulator は起こし直す。実機・プロファイルの無い run は警告だけ
    func testFallsBackToRespringOrWarnsWhenNothingIsSafeToPress() {
        XCTAssertEqual(plan(alert(["許可", "後で"])), .clear)
        guard case .warnOnly(let physical) = plan(alert(["許可", "後で"]), physical: true) else { return XCTFail() }
        XCTAssertTrue(physical.contains("physical device"), physical)
        XCTAssertTrue(physical.contains("iPhone-07(ios:8126)"))
        guard case .warnOnly(let noProfile) = plan(alert(["許可", "後で"]), canRebuildBridge: false) else {
            return XCTFail()
        }
        XCTAssertTrue(noProfile.contains("--profile"), noProfile)
    }

    /// 押すボタンは、アラートの子孫の中でラベルが完全一致するものだけ(アラートの外の同名ボタンを押さない)
    func testButtonRefIsTakenFromInsideTheAlertWithAnExactLabel() {
        func element(_ ref: Int, _ type: String, _ label: String?, depth: Int) -> ElementInfo {
            ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: depth)
        }
        let tree = [
            element(1, "button", "キャンセル", depth: 1),
            element(2, "alert", "T", depth: 1),
            element(3, "button", "キャンセルして削除", depth: 2),
            element(4, "button", "キャンセル", depth: 2),
            element(5, "button", "キャンセル", depth: 1),
        ]
        XCTAssertEqual(ResidualSystemAlertClearing.buttonRef(label: "キャンセル", in: tree), 4)
        XCTAssertNil(ResidualSystemAlertClearing.buttonRef(label: "閉じる", in: tree))
    }

    func testPressedMessageSaysWhenThePermissionIsNowDenied() {
        let denied = ResidualSystemAlertClearing.pressedMessage(label: "L", alert: "A", button: "許可しない",
                                                               deniesPermission: true)
        XCTAssertTrue(denied.contains("now denied"), denied)
        XCTAssertTrue(denied.contains("clearAppData()"), denied)
        let harmless = ResidualSystemAlertClearing.pressedMessage(label: "L", alert: "A", button: "キャンセル",
                                                                 deniesPermission: false)
        XCTAssertFalse(harmless.contains("denied"), harmless)
    }

    func testDescribeShowsTitleAndButtons() {
        XCTAssertEqual(ResidualSystemAlertClearing.describe(photos),
                       "“App”に写真ライブラリへのアクセスを許可しますか?, buttons: 写真を選択 / フルアクセスを許可 / 許可しない")
        XCTAssertEqual(ResidualSystemAlertClearing.describe(SystemAlertProbeResponse(present: true)), "no title")
    }

    func testClearedMessageSaysNoButtonWasPressed() {
        let line = ResidualSystemAlertClearing.clearedMessage(label: "L", alert: "A", seconds: 19.04)
        XCTAssertTrue(line.contains("without pressing any button"), line)
        XCTAssertTrue(line.contains("19.0s"), line)
    }
}
