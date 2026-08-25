// 95_可視性の幾何.swift
// **陽性対照**(既定スイートには載せない): `requireVisible`(実行プロファイル `falsePositiveCheck: true`)の
// 幾何 Tier-0 =「木に居ても収まる軸の中心が画面外なら不可視」がデバイスで効くことを確かめる。
// 既定プロファイルは falsePositiveCheck が OFF なので、緑の run ではこの経路は1度も実行されない。
// 回し方: scenarios/ 直下へ一時的に出し、`fleetest run --project E2E-iOS --profile ios-fpc --scenario 可視性の幾何`
// (ios-fpc = falsePositiveCheck: true・1台)。**S0010 は落ちるのが正常**(失敗理由に
// `false positive (offscreen)` と中心座標が出る)。S0020 / S0030 は通る。
// witness はホーム直後の `#nav_diagnostics`(y=858・高さ62 → 中心 889 > 画面高 874。SwiftUI の
// ScrollView は画面外の子も frame ごと a11y に出す)。FM が死んでいても(このホストの
// ModelManagerError(1001))幾何は効く = FM 不在時のフォールバックの確認でもある。
import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
class 可視性の幾何 {

    @Test("木に居るが中心が画面外の要素への exist は落ちる(陽性対照・落ちるのが正常)")
    func S0010() {
        scenario {
            scene(1, "ホーム直後の #nav_diagnostics は中心が画面外") {
                condition { launchApp() }.expectation { exist("#nav_diagnostics", timeout: 2) }
            }
        }
    }

    @Test("requireVisible: false なら従来どおりツリー存在だけで通る")
    func S0020() {
        scenario {
            scene(1, "逃げ道") {
                condition { launchApp() }.expectation { exist("#nav_diagnostics", timeout: 2, requireVisible: false) }
            }
        }
    }

    @Test("スクロールで画面内に入れれば幾何は通る(陰性対照)")
    func S0030() {
        scenario {
            scene(1, "scrollTo 後の exist") {
                condition { launchApp() }.action { scrollTo("#nav_diagnostics") }.expectation { exist("#nav_diagnostics") }
            }
        }
    }
}
