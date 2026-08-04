// 14_部分一致と反復.swift
// ftester 機能: `textContains` / `textMatches`(動的な文字列を含む表示の検証)と
// `repeatWhileCanSelect`(件数不定の一括操作。DSL にループが無かった頃の
// 「ガード付き反復を上限回数ぶん並べる」の置き換え)。
// 型を使うセレクタは OS 共通で書ける(ブリッジが役割へ正規化するため。ui-contract.md 全体規約)。

import FTDSL

@TestClass(app: "com.ftester.e2e")
class 部分一致と反復が正しく動くこと {

    @Test("textContains / textMatches が動的な文字列を検証できる")
    func S0010() {
        scenario {
            scene(1, "スクロール画面の行ラベルを部分一致で検証する") {
                condition {
                    launchApp()
                    tap("#nav_scroll")
                }.expectation {
                    // 行ラベルは `行 01`。完全一致(textIs)でも書けるが、ここは部分一致の検証
                    select("#row_01").textContains("01")
                    select("#row_01").textMatches("^行 [0-9]{2}$")
                }
            }
            scene(2, "選択結果の echo を正規表現で検証する") {
                action {
                    tap("#row_03")
                }.expectation {
                    // `selected=row_03`。数字部分は動的とみなして正規表現で受ける
                    select("#txt_row_selected").textMatches("^selected=row_[0-9]+$")
                    select("#txt_row_selected").textContains("row_03")
                }
            }
            scene(3, "一致しない期待は失敗する側の規約(部分一致は含むかどうかだけを見る)") {
                expectation {
                    // `行 03` は `行 3` を含まない(ゼロ詰め契約。ui-contract.md)。
                    // セレクタ側の部分一致記法でも同じ結論になることを見る
                    notExist("*行 3*")
                    // 同じ契約を**要素単位の否定**でも見る(セレクタ側の否定とは経路が違う)
                    select("#row_03").textContainsNot("行 3")
                    exist("*行 0*")
                    select("#row_03").textContains("行 0")
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
                    tap("#nav_dialog")
                }.expectation {
                    select("#txt_dialog_result").textIs("dialog=none")
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
