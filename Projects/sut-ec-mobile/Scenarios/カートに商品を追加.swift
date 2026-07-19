// カートに商品を追加.swift
// SUT Store（com.sutec.mobile）の「商品をカートに追加」ハッピーパス。
// セレクタは iPhone 17 Pro（iOS 27.0）/ja_JP・修正版ビルド（2026-07-20）で実機採取済み。
// 主要導線に accessibilityIdentifier が付いたため id 指定へ移行（旧・順序依存の .Button[N] を撤去）。
// タブスタック汚染バグ（ホームタブがカートを開く）は修正済みで、#tab_home が正常にホームへ遷移する。
//
// 擬陽性対策（維持）: カートはセッションを跨いで保持され累積する。単なる存在確認だと前回残留で緑になり
// 追加失敗を見逃す。→ 冒頭で全行削除して「空」を基準化し（scene1）、追加後の存在確認を意味あるものにする。
// 末尾で追加分を削除して副作用を残さない（scene4）。

import FTDSL

@TestClass(app: "com.sutec.mobile", platform: "ios")
class カートに商品を追加できること {

    /// カート画面で全行を削除して空にする（擬陽性防止の基準作り）。
    /// 空カートでは「合計」が無く ifCanSelect が空振りするため、上限回数だけ試せば安全（想定件数は僅少）。
    /// 注: 行ごとの削除ボタンは各行が同一 id=btn_remove_item を持ち複数行で曖昧になるため、
    /// ここは先頭行を型+順番 .Button[2]（各行 Button 並びは product, 削除 の順）で狙う。
    private func emptyCart() {
        ifCanSelect("合計", waitSeconds: 1) { tap(".Button[2]") }
        ifCanSelect("合計", waitSeconds: 1) { tap(".Button[2]") }
        ifCanSelect("合計", waitSeconds: 1) { tap(".Button[2]") }
        ifCanSelect("合計", waitSeconds: 1) { tap(".Button[2]") }
    }

    @Test("おすすめの商品をカートに追加できる")
    func S0010() {
        scenario {
            scene(1, "カートを空にして基準を作る") {
                condition {
                    launchApp()
                }.action {
                    tap("#tab_cart")  // カートタブ（id 指定）
                    wait(1)
                    emptyCart()
                }.expectation {
                    exist("カートは空です")
                }
            }
            scene(2, "ホームからおすすめ商品の詳細を開く") {
                action {
                    tap("#tab_home")  // ホームタブ（id 指定・修正版で正常にホームへ遷移）
                    wait(1)
                    // おすすめ先頭カード。カードは id 無しのため型+部分ラベルで一意に指す
                    tap(".Button=ミニマルデザイン腕時計")
                    wait(1)
                }.expectation {
                    exist("在庫あり")
                    exist(".Button=カートに追加")
                }
            }
            scene(3, "カートに追加し、空だったカートに入ることを確認する") {
                action {
                    tap(".Button=カートに追加")  // 追加ボタンは id 未付与のためラベルで指定
                    wait(1)  // 「カートに追加しました」スナックバーのアニメーション整定
                    tap("#btn_open_cart")  // 詳細右上のカートアイコン（id 指定）
                    wait(1)
                }.expectation {
                    exist("合計")  // 空表示から商品ありへ遷移した（合計は非空時のみ出る）
                    exist("ミニマルデザイン腕時計")  // scene1で空を確認済み → 存在=今回の追加が成立
                }
            }
            scene(4, "後始末: カートを空に戻す") {
                action {
                    // 追加した1点を削除（単一行なので id で一意）。副作用を残さない
                    tap("#btn_remove_item")
                    wait(1)
                }.expectation {
                    exist("カートは空です")
                }
            }
        }
    }
}
