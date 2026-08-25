// 16_飛び越し.swift
// fleetest 機能: scrollTo の決定的な「飛び越し」witness(#list_jump は 160dp の容器・内容 560dp =
// スクロール範囲 400dp で、1回の既定スワイプが端から端まで行き切る。docs/ui-contract.md「飛び越し画面」)。
// CMP のみ(他 3 SUT には無い)。

import FTDSL

@TestClass
class スクロール探索が要素を飛び越す現象を再現できること {

    @Test("scrollFrame を指定すれば今日でも #jrow_05 に到達できる")
    func S0010() {
        scenario {
            scene(1, "診断画面経由で飛び越し画面を開く(ホームのナビ行を増やさない契約により、ホーム直下ではなく診断画面から開く)") {
                condition {
                    clearAppData()
                    launchApp()
                }.action {
                    tap("#nav_diagnostics")
                    tap("#btn_open_jump")
                }.expectation {
                    select("#txt_jump_selected").textIs("jumped=-")
                }
            }
            scene(2, "#list_jump を指定した scrollTo は #jrow_05 に到達しタップできる") {
                action {
                    // 領域を明示した経路には刻みを詰める自己補正が効くため、今日でも通るのが期待値
                    scrollTo("#jrow_05", scrollFrame: "#list_jump")
                    tap("#jrow_05")
                }.expectation {
                    // **echo で見る**: 到達だけ見ても「容器の外の ghost を掴んで空振り」を
                    // 見逃す(タップが飲まれても要素は木に居るので exist は通ってしまう)
                    select("#txt_jump_selected").textIs("jumped=jrow_05")
                }
            }
        }
    }

    /// **witness**: 領域指定なしの既定スワイプは1回で容器2つぶん以上動くので、
    /// `#jrow_05` は上端の可視域にも下端の可視域にも入らず、**一度もツリーに現れない**。
    /// 素の探索では `element not found` になり、**端に着いてから逆向きに細刻みで戻る拾い直し**
    /// (StepExecutor.reverseSweep)で初めて到達できる。ステップの注記に
    /// `found by sweeping back after overshooting it` が出れば拾い直しが効いている。
    /// **落ちたら拾い直しが壊れている**(この画面の寸法の意味は
    /// E2EAppCMP/docs/ui-contract.md「飛び越し画面」)。
    @Test("scrollFrame を指定しない既定経路でも拾い直しで #jrow_05 に到達できる")
    func S0020() {
        scenario {
            scene(1, "診断画面経由で飛び越し画面を開く(ホームのナビ行を増やさない契約により、ホーム直下ではなく診断画面から開く)") {
                condition {
                    clearAppData()
                    launchApp()
                }.action {
                    tap("#nav_diagnostics")
                    tap("#btn_open_jump")
                }.expectation {
                    select("#txt_jump_selected").textIs("jumped=-")
                }
            }
            scene(2, "scrollFrame 未指定の scrollTo は飛び越すが、逆走査で拾い直せる") {
                action {
                    scrollTo("#jrow_05")
                    tap("#jrow_05")
                }.expectation {
                    // **タップの結果(echo)まで見る**: 到達だけ見ると「拾い直した行が容器の
                    // 縁にまたがったままで、撃っても隣の行が反応する」を見逃す
                    // (要素は木に居るので exist は通ってしまう)。この形は 2026-08-06 の
                    // 「触る前に容器の中へ寄せる」で塞いだので、ここが落ちたら寄せの退行
                    select("#txt_jump_selected").textIs("jumped=jrow_05")
                }
            }
        }
    }
}
