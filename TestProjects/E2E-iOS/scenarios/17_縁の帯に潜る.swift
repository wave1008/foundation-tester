// **縁の帯に潜った操作対象は、撃つ前に容器を送って外す**ことの回帰。
//
// witness は E2EAppIOS の `#btn_under_footer`。スクロール内容の最後にあり、シェルの
// **タブバーの下に潜っている**(覆い画面が内容をタブバーの下へ延ばしている)。実アプリで頻出する形で、
// 受け手の SUT では 4.7 インチ実機でログアウトがタブバーに潜り、タップがタブ「カート」に
// 当たって7本が巻き添えで落ちた(D-02)。
//
// **この対照が効くのは xcuitest だけ**(2026-08-27 の実測)。in-app エンジンは要素を
// 直接活性化するので座標のヒットテストを通らず、覆われていても対象が反応する
// = 機能を殺しても緑のままになる。既定スイート(in-app)では素通りするので、
// タップ経路を触ったら `Scripts/e2e.sh --ios-xcuitest` でこの1本を通すこと。
//
// **判定は結果テキストで行う**: 対象に当たれば `cover=target`、帯に当たれば `cover=footer`。
// 「タップが成功したか」では区別できない —— どちらも押下としては成功するため、
// 覆いを外せていない退行は**この対照が無いと沈黙する**。

import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
class 縁の帯に潜った対象 {

    @Test("固定フッタに潜ったボタンは送って外してから撃たれる")
    func S0010() {
        scenario {
            scene(1, "覆い画面を開く") {
                condition {
                    launchApp()
                    tap("#nav_cover", scroll: .down)
                }.expectation {
                    // 表示直後は対象がタブバーの下 = まだ誰も押していない
                    select("#txt_cover_result").textIs("cover=none")
                }
            }
            scene(2, "潜った対象を撃つ") {
                action {
                    tap("#btn_under_footer")
                }.expectation {
                    // 外せていなければタブバーに当たり、タブが切り替わって
                    // #txt_cover_result 自体が画面から消える
                    select("#txt_cover_result").textIs("cover=target")
                }
            }
        }
    }
}
