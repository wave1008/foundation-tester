// **キーボードの下に潜った入力欄へは、送って外してから打つ**ことの回帰。
//
// witness は E2EAppIOS の `#field_under_keyboard`。上の欄で焦点を取るとキーボードが立ち、
// 下の欄がその下に潜る。潜ったまま打つと**焦点が移らず、打鍵が直前に焦点のあった欄へ
// 流れ込む**(受け手の 4.7 インチ実機で実測: 市区町村の欄に住所が3回ぶん追記された。
// 読み返しが 422 で止めるが、**別の欄はすでに壊れている**)。
//
// **判定は2つ要る**: 下の欄に入ったことだけでなく、**上の欄が汚れていないこと**。
// 前者だけだと「両方に入った」形の退行を見逃す。
//
// **この対照が効くのは xcuitest だけ**(縁の帯の witness と同じ理由)。in-app エンジンは
// 要素へ直接文字を挿入するので、覆われていても入ってしまう。

import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
class キーボードの下の入力欄 {

    @Test("キーボードに潜った欄へ打つと、送って外してから入る")
    func S0010() {
        scenario {
            scene(1, "上の欄で焦点を取ってキーボードを立てる") {
                condition {
                    launchApp()
                    tap("#nav_keyboard_cover", scroll: .down)
                }.action {
                    type("#field_above_keyboard", "above")
                }.expectation {
                    select("#field_above_keyboard").valueIs("above")
                }
            }
            scene(2, "キーボードの下の欄へ打つ") {
                action {
                    type("#field_under_keyboard", "under")
                }.expectation {
                    select("#field_under_keyboard").valueIs("under")
                    // 外せていなければ上の欄へ流れ込む(送った後なので上の欄は画面外)
                    select("#field_above_keyboard", scroll: .up).valueIs("above")
                }
            }
        }
    }
}
