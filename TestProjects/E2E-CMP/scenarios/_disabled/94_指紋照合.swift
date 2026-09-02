// 94_指紋照合.swift
// ロケータ指紋(FTCore/LocatorFingerprint.swift)の witness。既定実行(scenarios/ 直下)には
// 載せず _disabled/ に置く。**run を2回またいで初めて意味を持つ**ため、既定スイートに入れると
// 1周目の結果だけを見て赤/緑が揺れる。
//
// 指紋の鍵は `scenarioID | file:line | セレクタ` なので、**同じ行が「一度成功し、次にドリフトする」**
// 状況を作らないと照合側を通せない。90_自己修復 は scene 1 で必ず v2 へ切り替えてから撃つので、
// 対象行は一度も成功せず**指紋が存在しない**(= あちらは指紋の witness にならない)。
//
// **状態(schema)の制御はこのシナリオの外で行う。** ここに入れると、失敗でシナリオが中断した
// ときに後始末の scene へ到達できず状態が回復しない(2026-09-02 に実際に踏んだ)。手順:
//   1. 対象の台を schema=v1 にする(#sw_heal_schema を押す)
//   2. このシナリオを1周 → scene 2 が素直に解決し**指紋を採取**
//   3. 対象の台を schema=v2 にする
//   4. もう1周 → #btn_heal_v1 はドリフト → **指紋が #btn_heal_v2 に一致**して解決し、
//      注記 heal-fingerprint-match と "passed via locator fingerprint matching" が出る
//
// **4 が見たいもの**。2 だけでは何も検証していない。
// **schema はアプリのデータ = 台ごとの状態**なので、両周を `--device` で同じ台に固定すること
// (指紋はホスト側のファイルに貯まるため、台を跨ぐと指紋だけが引き継がれて噛み合わない)。

import FTDSL

@TestClass(app: "com.ftester.e2e")
class 指紋でid変更を追従できること {

    @Test("前回成功した要素の指紋で id 変更に追従する(2周目で照合)")
    func S0010() {
        scenario {
            scene(1, "自己修復画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_heal")
                }.expectation {
                    exist("#txt_heal_schema")
                }
            }
            scene(2, "この行が run をまたいで指紋の採取元/照合先になる") {
                action {
                    // schema=v1 の周は素直に解決して指紋を残し、schema=v2 の周は
                    // プライマリが外れて指紋照合へ落ちる。**行を動かすと鍵が変わって
                    // 指紋が失効する**ので、編集するときは往復の前提ごと見直すこと
                    tap("#btn_heal_v1")
                }.expectation {
                    // どちらの周でも成立する形にする(検証したいのは「解決できたか」で、
                    // どちらの id を叩いたかではない)
                    select("#txt_heal_result").textContains("tapped=")
                }
            }
        }
    }
}
