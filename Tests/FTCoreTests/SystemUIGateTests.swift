// OS のシステム UI(SpringBoard の権限アラート)が被さっている間、背面のアプリを
// 操作・検証させないこと。
//
// 受け手報告(2026-08-20): ATT のダイアログが出ている間もテストが背面のアプリを操作して進む。
// in-app の注入は accessibilityActivate か自プロセスの窓への合成タッチで OS のイベント経路を
// 通らないため、覆われていても届いてしまう。
//
// **`applicationState` は信号にならない**(2026-08-21 実測): 同じ写真の権限アラートで
// -01 は inactive・-02 は active と端末で割れた。判定は XCUITest ランナーの
// `GET /systemalert` の申告(`SystemAlertProbeResponse`)だけを見る。

import XCTest
@testable import FTCore

final class SystemUIGateTests: XCTestCase {

    /// **申告が present:true のときだけ**覆われている扱い。nil(ランナーが居ない構成)は
    /// 判定しない —— ここを「nil も怪しい」に倒すと engine=inapp 固定と Android で操作が止まる
    func testOnlyAnExplicitPresentCounts() {
        XCTAssertTrue(SystemUIGate.isCovered(SystemAlertProbeResponse(present: true)))
        XCTAssertFalse(SystemUIGate.isCovered(SystemAlertProbeResponse(present: false)))
        XCTAssertFalse(SystemUIGate.isCovered(nil), "申告が無い構成で操作を止めてはいけない")
    }

    /// 名指しは題名を最優先。無ければ押せるボタンの並びで代用する
    func testDescribesTheAlertByTitleFirst() {
        let titled = SystemAlertProbeResponse(present: true, title: "写真ライブラリへのアクセス",
                                              buttons: ["許可"])
        XCTAssertEqual(SystemUIGate.describeCovering(titled), "写真ライブラリへのアクセス")

        let buttonsOnly = SystemAlertProbeResponse(present: true, title: nil,
                                                   buttons: ["許可", "許可しない"])
        XCTAssertEqual(SystemUIGate.describeCovering(buttonsOnly), "buttons: 許可 / 許可しない")
    }

    /// **読めないなら nil**(「システム UI が載っている」以上のことを推測で書かない)。
    /// 出ていないときも nil(名指しするものが無い)
    func testSaysNothingWhenThereIsNothingToName() {
        XCTAssertNil(SystemUIGate.describeCovering(nil))
        XCTAssertNil(SystemUIGate.describeCovering(SystemAlertProbeResponse(present: false)))
        XCTAssertNil(SystemUIGate.describeCovering(
            SystemAlertProbeResponse(present: true, title: "", buttons: [""])),
                     "空の題名と空ラベルのボタンだけでは名指しにならない")
    }

    /// 失敗の言い分は**次の一手**まで書く。ここに来るのは「宣言はあるが当たらなかった」
    /// ときだけなので、**何を宣言していて何が出ていたか**を両方書く
    func testFailureMessageNamesBothTheAlertAndTheDeclaredLabels() {
        let message = SystemUIGate.failureMessage(covering: "写真ライブラリ",
                                                  declaredButtons: ["許可", "OK"])
        XCTAssertTrue(message.contains("写真ライブラリ"), "何が覆っているかを名指しすること: \(message)")
        XCTAssertTrue(message.contains("許可 / OK"), "何を宣言していたかを出すこと: \(message)")
        XCTAssertTrue(message.contains("a person could not"),
                      "「人手では不可能」がこの失敗の理由そのもの: \(message)")
    }
}
