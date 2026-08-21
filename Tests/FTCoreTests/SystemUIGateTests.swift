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
    /// ときだけなので、**宣言した名前**と**実際にそのアラートに在る名前**の両方を書く。
    /// 実際の名前が無いと、受け手はシミュレータの画面を連続撮影して正解を探すしかない
    /// (2026-08-20 受け手依頼。数秒で消えるアラートは捕まらない)
    func testFailureMessageNamesTheActualButtonsToo() {
        let message = SystemUIGate.failureMessage(
            covering: "トラッキングを許可しますか?",
            actualButtons: ["Appにトラッキングしないよう要求", "許可"],
            declaredButtons: ["アプリの使用中は許可", "許可"])
        XCTAssertTrue(message.contains("トラッキングを許可しますか?"),
                      "何が覆っているかを名指しすること: \(message)")
        XCTAssertTrue(message.contains("アプリの使用中は許可 / 許可"),
                      "何を宣言していたかを出すこと: \(message)")
        XCTAssertTrue(message.contains("「Appにトラッキングしないよう要求」"),
                      "**実際に在るボタン**を出すこと(これが無いと次の一手が決まらない): \(message)")
        XCTAssertTrue(message.contains("a person could not"),
                      "「人手では不可能」がこの失敗の理由そのもの: \(message)")
    }

    /// **読めなかったときは黙らずにそう言う**。「出していない」のか「読めなかった」のかで
    /// 受け手の次の一手が変わる(前者ならラベルを足す・後者はシナリオで閉じるしかない)
    func testFailureMessageSaysSoWhenNoButtonLabelsCouldBeRead() {
        let message = SystemUIGate.failureMessage(covering: "何か", actualButtons: ["", ""],
                                                  declaredButtons: ["許可"])
        XCTAssertTrue(message.contains("no button labels"),
                      "読めなかったことを明示すること: \(message)")
        XCTAssertFalse(message.contains("Buttons on this alert"),
                       "空の一覧を出さないこと: \(message)")
    }
}
