// 10_イレギュラーハンドラ.swift
// fleetest 機能: `irregularHandler`(出るか不定なアプリ内メッセージの検出・自動終了)。
// 07_条件分岐とダイアログ.swift はハンドラなしでのダイアログ操作(ifCanSelect/select)を検証しており、
// 干渉させないためこちらは分けて irregularHandler 専用に検証する。
// CMP 版(TestProjects/E2E-CMP/scenarios/17_イレギュラーハンドラ.swift)の移植。**予測**: RN の
// `Modal` ベースのダイアログ(E2EAppRN/src/ui.tsx DialogOverlay)は通常の a11y 要素として出るため、
// E2E-iOS 版のようなラベルへのフォールバックは不要なはず(#txt_dialog_title がそのまま引ける予測。
// 09 と同じ根拠。未検証)。

import FTDSL

@TestClass(app: "com.ftester.e2e.rn")
class イレギュラーハンドラが自動でダイアログを閉じること {

    // 宣言の寿命はシナリオ1本なので setUp に置くのが定石(docs/commands.md)
    func setUp() {
        irregularHandler("#txt_dialog_title", dismiss: "#btn_dialog_cancel")
    }

    @Test("宣言後は検証コマンド・操作コマンドどちらの発火でもダイアログが自動的に閉じる")
    func S0010() {
        scenario {
            scene(1, "検証コマンド側の発火: expectation の照合前に自動で閉じられる") {
                condition {
                    launchApp()
                }.expectation {
                    // 起動直後は a11y ツリー完成後もポインタ入力を一時的に取りこぼす実装が
                    // Flutter で実測されている。RN で同じ罠があるかは未検証だが、害の無い
                    // 1往復なので安全側として残す。
                    //
                    // requireVisible: false = これは可視性の**検証**ではなく同期のための1往復。
                    // FM はホスト全体で直列化(約1回/秒)されるため、全 launchApp で FM を
                    // 呼ぶとコストだけが乗る。**可視性の検証と、occlusion-guard の誤判定を
                    // 検出する役目は 01_起動と画面遷移 が既定(true)のまま担う**
                    // (README「既知の fleetest 欠陥」参照。ここで guard を切っても検出器は死なない)。
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_dialog")
                }.expectation {
                    select("#txt_dialog_result").textIs("dialog=none")
                }.action {
                    tap("#btn_show_dialog")
                }.expectation {
                    // textIs/notExist はどちらも判定前にスナップショットを取る。そこで
                    // #txt_dialog_title を検出し #btn_dialog_cancel を自動タップしてから判定する
                    // (検証コマンドでも発火する仕様の固定。閉じたことはステップの注記に残る)
                    select("#txt_dialog_result").textIs("dialog=cancel")
                    notExist("#txt_dialog_title")
                }
            }
            scene(2, "操作コマンド側の発火: 次のタップの解決前に自動で閉じられる") {
                action {
                    tap("#btn_show_dialog")
                    // 直前で開いたダイアログはこのタップの解決前に自動で閉じられ、続けて
                    // 交互ダイアログ(#btn_maybe_dialog)の1回目タップ(奇数回目=開く)で再び開く
                    tap("#btn_maybe_dialog")
                }.expectation {
                    select("#txt_dialog_result").textIs("dialog=cancel")
                    notExist("#txt_dialog_title")
                }
            }
        }
    }
}
