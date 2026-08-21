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

/// `systemAlertHandler` の登録(素のラベル / アラートの名指し)の読み書きと選定
final class SystemAlertRuleTests: XCTestCase {

    /// 名指しは**題名の部分一致**(題名にはアプリ名が埋め込まれるので完全一致は書けない)。
    /// ボタンは従来どおり完全一致(「許可」が「許可しない」を押さない)
    func testNamedRuleMatchesByTitleSubstringAndExactButton() {
        func el(_ type: String, _ label: String, ref: Int = 1) -> ElementInfo {
            ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)
        }
        let att = [el("alert", "“ローソン.stub”が他社のアプリを横断してトラッキングすることを許可しますか?"),
                   el("button", "アプリにトラッキングしないように要求", ref: 2),
                   el("button", "許可", ref: 3)]
        let rules: [SystemAlertRule] = [.alert(titleContains: "*トラッキング*", button: "許可")]

        let hit = SystemAlertDismissal.ruleToApply(in: att, rules: rules)
        XCTAssertEqual(hit?.button.ref, 3)
        XCTAssertEqual(hit?.ruleIndex, 0)

        // 題名が一致しないアラートには(同じボタンがあっても)当てない
        let location = [el("alert", "位置情報の利用を許可しますか?"),
                        el("button", "許可", ref: 3)]
        XCTAssertNil(SystemAlertDismissal.ruleToApply(in: location, rules: rules))

    }

    /// **`||` は日英の候補を並べる**(端末の言語で題名もボタンも変わる)。
    /// 分岐ごとの意味は従来どおり: 題名 = 部分一致 / ボタン = 完全一致
    func testAlternativesServeBothLocales() {
        func el(_ type: String, _ label: String, ref: Int = 1) -> ElementInfo {
            ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)
        }
        // `*` の解釈はセレクタと同一: bare = 完全一致なので、題名(アプリ名が埋め込まれた
        // 長文)には `*x*` を書く。分岐は**実際の題名に含まれる語**で書く(英語の ATT は
        // "…to track your activity…" で "Tracking" という語は含まれない)
        let rules: [SystemAlertRule] = [.alert(titleContains: "*トラッキング*||*track your activity*",
                                               button: "許可||Allow")]
        let ja = [el("alert", "“ローソン.stub”がトラッキングすることを許可しますか?"),
                  el("button", "許可", ref: 3)]
        XCTAssertEqual(SystemAlertDismissal.ruleToApply(in: ja, rules: rules)?.button.ref, 3)

        let en = [el("alert", "Allow “Lawson.stub” to track your activity?"),
                  el("button", "Allow", ref: 4)]
        XCTAssertEqual(SystemAlertDismissal.ruleToApply(in: en, rules: rules)?.button.ref, 4,
                       "英語端末でも同じ登録で押せること")

        // ボタンの分岐は**完全一致のまま**: 「許可しない」を「許可」の分岐で押さない
        let deny = [el("alert", "トラッキングの許可"), el("button", "許可しない", ref: 5)]
        XCTAssertNil(SystemAlertDismissal.ruleToApply(in: deny, rules: rules))
    }

    /// **空の分岐と `*` 単体は落とす**。`"a||"` や `"*"` の書き間違いを
    /// 「どの題名にも当たる」に化けさせない
    func testEmptyAlternativesDoNotMatchEverything() {
        func el(_ type: String, _ label: String, ref: Int = 1) -> ElementInfo {
            ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)
        }
        let tree = [el("alert", "無関係のアラート"), el("button", "OK", ref: 2)]
        XCTAssertNil(SystemAlertDismissal.ruleToApply(
            in: tree, rules: [.alert(titleContains: "*トラッキング*||", button: "OK")]),
            "空分岐が「どのアラートでも」に化けてはいけない")
        XCTAssertNil(SystemAlertDismissal.ruleToApply(
            in: tree, rules: [.alert(titleContains: "*", button: "OK")]),
            "`*` 単体が「どのアラートでも」に化けてはいけない")
        XCTAssertEqual(SystemAlertDismissal.alternatives("トラッキング || Tracking"),
                       ["トラッキング", "Tracking"], "分岐の前後の空白は落とす")
    }

    /// **題名が読めないアラートに名指しは当てない**(どのアラートか確かめようがないのに
    /// 押すと、意図しないアラートを閉じ得る)。素のラベルなら当たる
    func testNamedRuleNeedsAReadableTitle() {
        func el(_ type: String, _ label: String?, ref: Int = 1) -> ElementInfo {
            ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)
        }
        let titleless = [el("button", "許可", ref: 3)]
        XCTAssertNil(SystemAlertDismissal.ruleToApply(
            in: titleless, rules: [.alert(titleContains: "*トラッキング*", button: "許可")]))
        XCTAssertEqual(SystemAlertDismissal.ruleToApply(
            in: titleless, rules: [.button("許可")])?.button.ref, 3)
    }
}

/// 宣言と消費状態の台帳。選定・消費・監視解除の知識をここに集約してあることの検証
/// (呼び手が「名指しだけ消費する」を知らなくてよいのがこの型の存在理由)
final class SystemAlertWatchlistTests: XCTestCase {

    private func el(_ type: String, _ label: String, ref: Int = 1) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)
    }

    /// 名指しを全部処理したら isWatching が落ちる(= 監視の解除)。処理前は見張る
    func testNamedRulesReleaseTheWatchOnceAllArePressed() {
        var list = SystemAlertWatchlist(rules: [.alert(titleContains: "*写真*", button: "許可しない"),
                                                .alert(titleContains: "*トラッキング*", button: "許可")])
        XCTAssertTrue(list.isWatching)
        let photos = [el("alert", "写真ライブラリへのアクセス"), el("button", "許可しない", ref: 2)]
        guard let first = list.buttonToTap(in: photos) else { XCTFail("1枚目が選ばれること"); return }
        list.notePressed(first.index)
        XCTAssertTrue(list.isWatching, "まだ2枚目が残っている")

        let att = [el("alert", "トラッキングの許可"), el("button", "許可", ref: 3)]
        guard let second = list.buttonToTap(in: att) else { XCTFail("2枚目が選ばれること"); return }
        list.notePressed(second.index)
        XCTAssertFalse(list.isWatching, "全部処理したら監視を解除すること")
    }

    /// **1回の登録 = 1枚のアラート**。押したら外れ、台帳が空になれば監視も止まる。
    /// 同じラベルを2枚待つなら**2回登録**すればよい —— 登録は枚数ぶんあるので、
    /// `許可` のような汎用ラベルを複数のアラートが使っても取り合いにならない
    func testOneRegistrationServesOneAlert() {
        var list = SystemAlertWatchlist(rules: [.button("許可"), .button("許可")])
        let alert = [el("alert", "何かの許可"), el("button", "許可", ref: 2)]
        guard let first = list.buttonToTap(in: alert) else { XCTFail(); return }
        list.notePressed(first.index)
        XCTAssertTrue(list.isWatching, "2枚目の登録が残っている")
        guard let second = list.buttonToTap(in: alert) else {
            XCTFail("2回登録したら2枚目にも使えること"); return
        }
        list.notePressed(second.index)
        XCTAssertFalse(list.isWatching, "全部発火したら監視を止めること")
        XCTAssertNil(list.buttonToTap(in: alert), "空の台帳は何も押さない")
    }

    /// 登録は後からでも足せる(シナリオの途中で「次の操作でアラートが出る」と予告する形)
    func testRegistrationCanHappenMidScenario() {
        var list = SystemAlertWatchlist()
        XCTAssertFalse(list.isWatching, "登録が無い間は監視しない")
        list.register(.button("許可"))
        XCTAssertTrue(list.isWatching)
    }

    /// 消費済みの名指しは選定から外れる(同じアラートを二度押さない)
    func testAHandledNamedRuleIsNotSelectedAgain() {
        var list = SystemAlertWatchlist(rules: [.alert(titleContains: "*写真*", button: "許可しない")])
        let photos = [el("alert", "写真ライブラリへのアクセス"), el("button", "許可しない", ref: 2)]
        guard let first = list.buttonToTap(in: photos) else { XCTFail(); return }
        list.notePressed(first.index)
        XCTAssertNil(list.buttonToTap(in: photos), "処理済みの名指しをもう一度当ててはいけない")
    }

    /// 範囲外の index は黙って無視する(クラッシュさせない)
    func testAnOutOfRangeIndexIsIgnored() {
        var list = SystemAlertWatchlist(rules: [.button("許可")])
        list.notePressed(99)
        XCTAssertTrue(list.isWatching)
    }
}

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
