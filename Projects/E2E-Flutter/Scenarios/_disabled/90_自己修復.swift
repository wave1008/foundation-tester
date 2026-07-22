// 90_自己修復.swift
// FM(Foundation Models)を要するため通常実行(Scenarios/ 直下)には載せず _disabled/ に置く。
// `ios-heal` プロファイル(--heal)でのみ通す想定。
//
// ftester 機能: ヒールキャッシュ経由の自己修復(docs/design.md §10「自己修復の再設計」)。
// #sw_heal_schema を OFF にして id スキーマを v1→v2 に切り替える(ラベル『修復対象』は不変)。
// シナリオは #btn_heal_v1 を書いたままにし、実体は #btn_heal_v2 になっている状態で
// ラベルから FM が解決できるかを検証する。
// **SUT(Flutter)を替えても同じラベルで修復できるか**が、4 SUT 体制で新たに測れる点。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class 自己修復でid変更を追従できること {

    @Test("id スキーマが v2 に切り替わってもラベルから修復できる")
    func S0010() {
        scenario {
            scene(1, "自己修復画面を開き v2 スキーマへ切替") {
                condition {
                    launchApp()
                }.expectation {
                    // Flutter は起動直後の数百 ms ポインタ入力を取りこぼす(E2EAppFlutter/docs/ui-contract.md)。
                    // 着地を確認してから操作する。
                    exist("#txt_home_marker")
                }.action {
                    tap("#nav_heal")
                    // schema は永続。無条件トグルだと2回目の実行で v1 に戻ってしまうため、
                    // 「v1 の id が実在するときだけ切り替える」= 冪等にする。
                    ifCanSelect("#btn_heal_v1", waitSeconds: 1) { tap("#sw_heal_schema") }
                }.expectation {
                    textIs("#txt_heal_schema", "schema=v2")
                }
            }
            scene(2, "id は v1 のままだが FM がラベル『修復対象』から解決する") {
                action {
                    tap("#btn_heal_v1")
                }.expectation {
                    textIs("#txt_heal_result", "tapped=v2")
                }
            }
            scene(3, "後始末: 既定スキーマ(v1)へ戻す") {
                action {
                    ifCanSelect("#btn_heal_v2", waitSeconds: 1) { tap("#sw_heal_schema") }
                }.expectation {
                    textIs("#txt_heal_schema", "schema=v1")
                }
            }
        }
    }
}
