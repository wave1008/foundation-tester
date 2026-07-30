// 92_screenIs.swift
// FM(Foundation Models)の画像判定を要するため通常実行(Scenarios/ 直下)には載せず _disabled/ に置く。
// **既定スイートに入れてはいけない**: screenIs は FM の非決定的な判定なので、
// 生きた FM で回すとフレーク源になる(FM が死んでいる間は skip されるので緑のまま気付けない)。
// 実行は `Scripts/fm-verify.sh`(90_自己修復 と一緒に一時的に有効化して ios-fm プロファイルで回す)。
//
// ftester 機能: screenIs(スクリーンショットと自然言語記述の FM 照合)。
// 記述は「文字が読めるか」ではなく**画面の構造**を書く(語句の一致に依存させるとアプリの
// 文言変更で落ちる。FM に渡すのは画像なので、レイアウトの言葉で書くのが安定する)。

import FTDSL

@TestClass(app: "com.ftester.e2e")
class 画面全体をFMで検証できること {

    @Test("ホームと入力画面を screenIs が見分ける")
    func S0010() {
        scenario {
            scene(1, "ホーム画面を screenIs で検証") {
                condition {
                    launchApp()
                }.expectation {
                    exist("#txt_home_marker")
                    screenIs("画面上部に見出しがあり、その下に画面遷移用のボタンが縦一列に並んだ一覧。"
                             + "最下部にタブバーがある")
                }
            }
            scene(2, "テキスト入力画面を screenIs で検証(別画面と混同しないこと)") {
                action {
                    tap("#nav_input")
                }.expectation {
                    exist("#field_single")
                    screenIs("テキスト入力用の入力欄が複数縦に並んでいる画面。"
                             + "入力内容を表示する行と、送信・クリアのボタンがある")
                }
            }
        }
    }
}
