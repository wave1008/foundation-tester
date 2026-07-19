// カートに商品を追加.swift
// SUT Store(com.sutec.mobile)の「商品をカートに追加」ハッピーパス。
// セレクタは iPhone 17 Pro(iOS 27.0)/ja_JP で実機採取済み。このアプリは
// accessibilityIdentifier が一切無く、ラベル+型でしか指せない(無ラベル要素は .Button[n] 頼み)。
//
// ナビの罠(この経路を選んだ理由。安易に「ホーム/検索タブ」へ書き換えない):
//   - ホームタブは押すとカートが開く(不具合)。検索タブも間欠的にカートへ化ける(左2タブが誤爆)。
//   - よって右側の安定タブ「カート」を起点にし、空カートCTA「買い物を続ける」でホームへ入る。
//
// 擬陽性対策: カートはセッションを跨いで保持され累積する。単なる存在確認だと前回残留で緑になり
// 追加失敗を見逃す。→ 冒頭で全行削除して「空」を基準化し(scene1)、追加後の存在確認を意味あるものにする。
// 末尾で追加分を削除して副作用を残さない(scene4)。

import FTDSL

@TestClass(app: "com.sutec.mobile", platform: "ios")
class カートに商品を追加できること {

    /// カート画面で全行を削除して空にする(擬陽性防止の基準作り)。
    /// 削除(ゴミ箱)ボタンは無ラベル=各行2番目のButton。行を消すと先頭が繰り上がるので先頭を繰り返し消す。
    /// 空カートでは「合計」が無く ifCanSelect が空振りするため、上限回数だけ試せば安全(想定件数は僅少)。
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
                    tap(".Button=カート")  // 右側の安定タブでカートへ(壊れた左タブを避ける)
                    wait(1)
                    emptyCart()
                }.expectation {
                    exist("カートは空です")
                }
            }
            scene(2, "空カートCTA経由でホームの商品詳細を開く") {
                action {
                    tap(".Button=買い物を続ける")  // 空カートCTA→ホーム(壊れたホームタブを使わない確実な入口)
                    wait(1)
                    // おすすめ先頭カード。カード全体は長い連結ラベルだが型を絞れば部分一致で一意
                    tap(".Button=ミニマルデザイン腕時計")
                    wait(1)
                }.expectation {
                    exist("在庫あり")
                    exist(".Button=カートに追加")
                }
            }
            scene(3, "カートに追加し、空だったカートに入ることを確認する") {
                action {
                    tap(".Button=カートに追加")
                    wait(1)  // 「カートに追加しました」スナックバーのアニメーション整定
                    // 詳細右上のカートアイコンは無ラベル・idなし。上部3ボタン(戻る/♡/🛒)の3番目
                    tap(".Button[3]")
                    wait(1)
                }.expectation {
                    exist("合計")  // 空表示から商品ありへ遷移した(合計は非空時のみ出る)
                    exist("ミニマルデザイン腕時計")  // scene1で空を確認済み → 存在=今回の追加が成立
                }
            }
            scene(4, "後始末: カートを空に戻す") {
                action {
                    // 追加した1点を削除して副作用を残さない(次回実行の基準も保つ)
                    tap(".Button[2]")  // 先頭行の削除ボタン
                    wait(1)
                }.expectation {
                    exist("カートは空です")
                }
            }
        }
    }
}
