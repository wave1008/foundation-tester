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

    /// ソフトウェアアップデートは常に保留(ユーザー決定)。実機の iPhone 13 で出た実物の題名と並び。インストールの側は押さない
    func testSoftwareUpdateIsAlwaysDeferredAndNeverInstalled() {
        let update = SystemAlertProbeResponse(present: true, title: "ソフトウェアアップデート",
                                              buttons: ["今すぐインストール", "あとで", "詳細"])
        XCTAssertEqual(plan(update, physical: true), .press(button: "あとで", deniesPermission: false))
        XCTAssertEqual(plan(SystemAlertProbeResponse(present: true, title: "Software Update",
                                                     buttons: ["Install Now", "Later", "Details"]), physical: true),
                       .press(button: "Later", deniesPermission: false))
        // 続けて出る選択(題名が無いことがある): 通知だけ先送りする側を押す
        XCTAssertEqual(plan(SystemAlertProbeResponse(present: true, title: nil, buttons: ["今夜インストール", "あとで通知"]),
                            physical: true),
                       .press(button: "あとで通知", deniesPermission: false))
        // 題名がアップデートでなければ「あとで」は押さない(別のアラートでは別の意味になりうる)
        guard case .warnOnly = plan(SystemAlertProbeResponse(present: true, title: "T", buttons: ["続ける", "あとで"]),
                                    physical: true) else { return XCTFail() }
        // 「今夜インストール」と並んでいない「あとで通知」も押さない
        guard case .warnOnly = plan(alert(["あとで通知", "設定"]), physical: true) else { return XCTFail() }
    }

    /// 続けて出る選択に「キャンセル」が並んでいても、保留(あとで通知)を先に押す(キャンセルでは保留にならずすぐまた出る)
    func testDeferralComesBeforeAHarmlessCancelOnTheFollowUpChoice() {
        XCTAssertEqual(plan(SystemAlertProbeResponse(present: true, title: nil,
                                                     buttons: ["今夜インストール", "あとで通知", "キャンセル"])),
                       .press(button: "あとで通知", deniesPermission: false))
        // 他のアラートの「キャンセル」は従来どおり
        XCTAssertEqual(plan(alert(["削除", "キャンセル"])), .press(button: "キャンセル", deniesPermission: false))
    }

    /// 続けて出る選択は SpringBoard の木から引く。アラートでもアクションシートでもよい(問い合わせはアラートしか見ない)。
    /// 「今夜インストール」と同じ入れ物に並んでいるときだけ
    func testFollowUpRemindIsFoundInAnAlertOrAnActionSheet() {
        func element(_ ref: Int, _ type: String, _ label: String?, depth: Int) -> ElementInfo {
            ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: depth)
        }
        for container in ["sheet", "alert"] {
            let tree = [element(1, container, nil, depth: 1), element(2, "button", "今夜インストール", depth: 2),
                        element(3, "button", "あとで通知", depth: 2)]
            let found = ResidualSystemAlertClearing.softwareUpdateFollowUpRemind(in: tree)
            XCTAssertEqual(found?.ref, 3, container)
            XCTAssertEqual(found?.label, "あとで通知", container)
        }
        // 「今夜インストール」が別の入れ物・入れ物の外なら返さない
        let apart = [element(1, "sheet", nil, depth: 1), element(2, "button", "あとで通知", depth: 2),
                     element(3, "button", "今夜インストール", depth: 1)]
        XCTAssertNil(ResidualSystemAlertClearing.softwareUpdateFollowUpRemind(in: apart))
    }

    /// 記録は「あとで」を押した事実を必ず含む(続けて出た選択を押したならそれも)
    func testDeferredUpdateMessageMentionsBothPresses() {
        let both = ResidualSystemAlertClearing.deferredUpdateMessage(label: "L", alert: "A", later: "あとで", remind: "あとで通知")
        XCTAssertTrue(both.contains("\u{201C}あとで\u{201D}") && both.contains("\u{201C}あとで通知\u{201D}"), both)
        let only = ResidualSystemAlertClearing.deferredUpdateMessage(label: "L", alert: "A", later: "Later", remind: nil)
        XCTAssertTrue(only.contains("\u{201C}Later\u{201D}") && !only.contains("follow-up"), only)
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
