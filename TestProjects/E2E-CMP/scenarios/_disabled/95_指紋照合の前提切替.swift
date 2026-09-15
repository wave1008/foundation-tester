// 95_指紋照合の前提切替.swift
// 94_指紋照合 の前提(自己修復画面の id スキーマ)を切り替えるだけの補助シナリオ。
// 単独では何も検証しない。回すのは `Scripts/heal-verify.sh`(94 と一緒に一時的に有効化する)。
// schema は台ごとのアプリデータなので、94 と同じ台(`--device`)で回すこと。

import FTDSL

@TestClass(app: "com.ftester.e2e")
class 指紋照合の前提を切り替える {

    @Test("自己修復画面の schema を v1 にする")
    func S0010() {
        scenario {
            scene(1, "schema=v1") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_heal")
                    // schema は永続なので「v2 のときだけ切り替える」= 何周しても v1 に落ち着く
                    ifCanSelect("#btn_heal_v2", waitSeconds: 1) { tap("#sw_heal_schema") }
                }.expectation {
                    select("#txt_heal_schema").textIs("schema=v1")
                }
            }
        }
    }

    @Test("自己修復画面の schema を v2 にする")
    func S0020() {
        scenario {
            scene(1, "schema=v2") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_heal")
                    ifCanSelect("#btn_heal_v1", waitSeconds: 1) { tap("#sw_heal_schema") }
                }.expectation {
                    select("#txt_heal_schema").textIs("schema=v2")
                }
            }
        }
    }
}
