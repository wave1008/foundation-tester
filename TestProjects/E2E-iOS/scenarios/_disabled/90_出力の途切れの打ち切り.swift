// 90_出力の途切れの打ち切り.swift
// **陽性対照**(既定スイートには載せない・遅い = e2e-negative.sh --with-slow のときだけ): 子の出力が
// 2 × commandTimeout(既定 240 秒)を超えて途切れたら打ち切り、長さを申告した待ちは打ち切らないことを確かめる。
// commandTimeout はプロファイルで縮められないので、実際に 240 秒を超えて黙らせる(2 本で約 8 分)。
// 回すのは Scripts/e2e-negative.sh --with-slow(期待値は Scripts/negative-controls.json)。
// **S0010 は落ちるのが正常**: procedure の中の素の Swift は長さが分からず申告されない → 約 240 秒で打ち切られ、
// 行が「produced no output for … and was killed」になる。**緑か全体の上限での打ち切りなら退行**。
// **S0020 は緑が正常**: ifCanSelect の waitSeconds(250 秒)は申告されるので、240 秒を超えて黙っても止めない。
// **赤(打ち切り)なら退行**(申告が親に届いていない)。
import Foundation
import FTDSL

@TestClass(platform: "ios")
class 出力の途切れの打ち切り {

    @Test("長さの分からない処理が 240 秒を超えて黙ると打ち切られる(落ちるのが正常)")
    func S0010() {
        scenario {
            scene(1, "素の Swift で黙る") {
                action {
                    launchApp()
                    procedure("黙って待つ") {
                        Thread.sleep(forTimeInterval: 300)
                    }
                }.expectation {
                    exist("#txt_home_marker")
                }
            }
        }
    }

    @Test("長さを申告した待ちは 240 秒を超えて黙っても打ち切られない")
    func S0020() {
        scenario {
            scene(1, "250 秒待って無いことを確かめる") {
                action {
                    launchApp()
                    ifCanSelect("#definitely_missing_for_idle_allowance", waitSeconds: 250) {}
                }.expectation {
                    exist("#txt_home_marker")
                }
            }
        }
    }
}
