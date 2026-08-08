// 24_ブリッジの値供給.swift
// ftester 機能: **ブリッジが要素の状態を供給していること**をデバイス実行で固定する。
//
// echo Text(#txt_slider)による値検証は SUT が自前で描くので、**ブリッジが黙っても緑のまま**。
// ここはブリッジの emission そのものを見る —— Android の Slider value は
// `AccessibilityNodeInfo.getRangeInfo()` が唯一の供給源(採取と「パーセントへ正規化しない」
// 契約は Sources/FTCore/BridgeDTO.swift の `ElementInfo.range` 参照)。これが無いと実アプリ
// (音量・価格帯など echo を持たない画面)でスライダーの状態がまったく読めない。
// 固定コーパス(Tests/Fixtures/RealAppSnapshots/)は木を凍結するので、
// **ブリッジ側が後から退行しても捕まえられない** —— 生きた供給はこのシナリオだけが見る。
//
// 表記はエンジンごとに実測どおり(2026-08-08 に全て Simulator/Emulator で確認):
//   Android(RangeInfo)= "50" / Compose iOS = "50.0" / SwiftUI(E2E-iOS 側)= "50%"。
//   Flutter は value を申告しない(実測)ため E2E-Flutter に対応シナリオは無い。
// 同名シナリオが E2E-Android にもある(View の SeekBar = 同じ RangeInfo 経路の別実装)。

import FTDSL

@TestClass(app: "com.ftester.e2e")
class ブリッジが要素の状態を供給していること {

    @Test("Slider の現在値が value として木に載る")
    func S0010() {
        scenario {
            scene(1, "コントロールタブを初期状態で開く") {
                condition {
                    launchApp()
                    tap("#tab_controls")
                    tap("#btn_controls_reset")
                }.expectation {
                    select("#txt_slider").textIs("volume=50")   // 先にアプリ側の状態を確定させる
                }
            }
            scene(2, "ブリッジの供給を echo とは独立に確認する") {
                expectation {
                    android { select("#slider_volume").valueIs("50") }
                    ios { select("#slider_volume").valueIs("50.0") }
                }
            }
        }
    }
}
