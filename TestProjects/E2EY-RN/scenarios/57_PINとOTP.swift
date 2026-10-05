// 57_PINとOTP.swift
// 確かめる癖: OTP の箱は入力欄ではない(実体は隠れた入力欄 1 つ・箱を押すと焦点が移る・揃うと 0.3 秒で
// 自動送信して欄が空に戻る = 読み返す前に値が消える)。PIN はソフトキーボードを使わない自前のキーパッド。

import FTDSL

@TestClass
class PINとOTPを入力できること {

    @Test("自前のキーパッドで 4 桁を押す")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_pin", scroll: .down)
                }.expectation {
                    select("#txt_pin_result").textIs("pin=none")
                    select("#txt_pin_len").textIs("pin_len=0")
                }
            }
            scene(2, "2 桁押す") {
                action {
                    tap("#key_1")
                    tap("#key_2")
                }.expectation {
                    select("#txt_pin_len").textIs("pin_len=2")
                }
            }
            scene(3, "削除で 1 桁戻す") {
                action {
                    tap("#key_del")
                }.expectation {
                    select("#txt_pin_len").textIs("pin_len=1")
                }
            }
            scene(4, "4 桁そろえる") {
                action {
                    tap("#key_3")
                    tap("#key_4")
                    tap("#key_5")
                }.expectation {
                    select("#txt_pin_result").textIs("pin=1345")
                }
            }
        }
    }

    @Test("箱を押して焦点を移し、6 桁を打つと自動送信される")
    func S0020() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_pin", scroll: .down)
                }.expectation {
                    select("#txt_otp_result").textIs("otp=none")
                }
            }
            scene(2, "箱を押して打つ") {
                action {
                    tap("#otp_box_3")
                    type("123456")
                }.expectation {
                    select("#txt_otp_result").textIs("otp=123456", waitSeconds: 3)
                }
            }
        }
    }

    @Test("隠れた入力欄へ直接打つ")
    func S0030() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_pin", scroll: .down)
                }.expectation {
                    select("#txt_otp_result").textIs("otp=none")
                }
            }
            scene(2, "入力欄へ打つ") {
                action {
                    type("#field_otp", "654321")
                }.expectation {
                    select("#txt_otp_result").textIs("otp=654321", waitSeconds: 3)
                }
            }
        }
    }
}
