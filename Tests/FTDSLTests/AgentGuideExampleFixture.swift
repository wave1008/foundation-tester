// このファイルは docs/user-docs/tools/agent_guide.md(と _ja.md)の Swift の見本と1文字も違わない
// (AgentGuideExampleTests が等号で固定する)。**テストターゲットに置いてあるので swift test がコンパイルする**
// = DSL を改名したとき、手引きの見本だけが古くなるのを防ぐ。見本を変えたらここも貼り替える。
// ---- ここから手引きの見本 ----
import FTDSL

@TestClass(app: "com.example.app", platform: "ios")
class SignInExample {
    @Test("Signing in shows the home screen")
    func S0010() {
        scenario {
            scene(1, "The sign-in screen opens") {
                condition {
                    launchApp()
                }.action {
                    tap("#btn_signin")
                }.expectation {
                    exist("#field_email")
                }
            }
            scene(2, "Signing in lands on home") {
                action {
                    tap("#field_email")
                    type("#field_email", "user@example.com")
                    ifCanSelect("#btn_dismiss_tips", waitSeconds: 1) {
                        tap("#btn_dismiss_tips")
                    }
                    tap("#btn_submit", scroll: .down)
                }.expectation {
                    select("#txt_title").textIs("Home")
                }
            }
        }
    }
}
