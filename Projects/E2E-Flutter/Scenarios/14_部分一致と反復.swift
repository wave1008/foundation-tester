// 14_部分一致と反復.swift
// ftester 機能: `textContains` / `textMatches`(動的な文字列を含む表示の検証)と
// `repeatWhileCanSelect`(件数不定の一括操作。DSL にループが無かった頃の
// 「ガード付き反復を上限回数ぶん並べる」の置き換え)。
// 型を使うセレクタは OS 共通で書ける(ブリッジが役割へ正規化するため。ui-contract.md 全体規約)。
// CMP 版(Projects/E2E/Scenarios/14_部分一致と反復.swift)の移植。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class 部分一致と反復が正しく動くこと {

    @Test("textContains / textMatches が動的な文字列を検証できる")
    func S0010() {
        scenario {
            scene(1, "スクロール画面を開き行ラベルを部分一致で検証する") {
                condition {
                    launchApp()
                }.expectation {
                    // Flutter は起動直後の数百 ms、a11y ツリーは完成しているのに**ポインタ入力を
                    // 取りこぼす**ことがある(初回タップが成功扱いのまま黙って無反応になる。
                    // Android で実測)。ここで1往復させ、着地を確認してから操作する。
                    //
                    // requireVisible: false = これは可視性の**検証**ではなく同期のための1往復。
                    // FM はホスト全体で直列化(約1回/秒)されるため、全 launchApp で FM を
                    // 呼ぶとコストだけが乗る。**可視性の検証と、occlusion-guard の誤判定を
                    // 検出する役目は 01_起動と画面遷移 が既定(true)のまま担う**
                    // (README「既知の ftester 欠陥」参照。ここで guard を切っても検出器は死なない)。
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_scroll")
                }.expectation {
                    // 行ラベルは `行 01`。完全一致(textIs)でも書けるが、ここは部分一致の検証
                    textContains("#row_01", "01")
                    textMatches("#row_01", "^行 [0-9]{2}$")
                }
            }
            scene(2, "選択結果の echo を正規表現で検証する") {
                action {
                    tap("#row_03")
                }.expectation {
                    // `selected=row_03`。数字部分は動的とみなして正規表現で受ける
                    textMatches("#txt_row_selected", "^selected=row_[0-9]+$")
                    textContains("#txt_row_selected", "row_03")
                }
            }
            scene(3, "一致しない期待は失敗する側の規約(部分一致は含むかどうかだけを見る)") {
                expectation {
                    // `行 03` は `行 3` を含まない(ゼロ詰め契約。ui-contract.md)。
                    // セレクタ側の部分一致記法でも同じ結論になることを見る
                    notExist("*行 3*")
                    // 同じ契約を**要素単位の否定**でも見る(セレクタ側の否定とは経路が違う)
                    textContainsNot("#row_03", "行 3")
                    exist("*行 0*")
                    textContains("#row_03", "行 0")
                }
            }
        }
    }

    @Test("repeatWhileCanSelect が解決できる限り繰り返す")
    func S0020() {
        scenario {
            scene(1, "ダイアログ画面へ移動する") {
                condition {
                    launchApp()
                }.expectation {
                    // Flutter は起動直後の数百 ms、a11y ツリーは完成しているのに**ポインタ入力を
                    // 取りこぼす**ことがある(初回タップが成功扱いのまま黙って無反応になる。
                    // Android で実測)。ここで1往復させ、着地を確認してから操作する。
                    //
                    // requireVisible: false = これは可視性の**検証**ではなく同期のための1往復。
                    // FM はホスト全体で直列化(約1回/秒)されるため、全 launchApp で FM を
                    // 呼ぶとコストだけが乗る。**可視性の検証と、occlusion-guard の誤判定を
                    // 検出する役目は 01_起動と画面遷移 が既定(true)のまま担う**
                    // (README「既知の ftester 欠陥」参照。ここで guard を切っても検出器は死なない)。
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_dialog")
                }.expectation {
                    textIs("#txt_dialog_result", "dialog=none")
                }
            }
            scene(2, "出るか不定なダイアログを、出なくなるまで閉じ続ける") {
                action {
                    // #btn_maybe_dialog は奇数回目だけダイアログを開く(ui-contract.md)。
                    // 「開いたら閉じる」を上限まで繰り返す = 件数不定の一括操作の縮図
                    tap("#btn_maybe_dialog")
                }.expectation {
                    // 1回目は必ず開く。ここで肯定側の検証を1つ置いておくと、最後の notExist が
                    // 「id の綴り誤りでも成功する」経路に落ちない(run 終了時の警告と同じ趣旨)
                    exist("#txt_dialog_title")
                }.action {
                    repeatWhileCanSelect("#btn_dialog_cancel", max: 3, title: "ダイアログを閉じる") {
                        tap("#btn_dialog_cancel")
                        tap("#btn_maybe_dialog")
                    }
                }.expectation {
                    // 上限で止まっても失敗にはならない契約。最後は必ず閉じている
                    notExist("#txt_dialog_title")
                }
            }
        }
    }
}
