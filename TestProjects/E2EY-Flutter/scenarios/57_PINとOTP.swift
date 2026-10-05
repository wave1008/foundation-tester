// 57_PINとOTP.swift
// 確かめる癖: 箱は入力欄ではない(打ち込む先は隠れた欄 1 つ)・6 桁そろうと 0.3 秒で自動送信され値が消える・
// PIN の自前キーパッドは「文字を打つ」経路では入らない(キーを 1 つずつ押す)。

import FTDSL

@TestClass
class PINとOTPを入力できること {

    @Test("OTP の箱を押して 6 桁打つと自動送信される")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_pin", scroll: .down)
                }.expectation {
                    select("#txt_otp_result").textIs("otp=none")
                }
            }
            scene(2, "箱を押して焦点を移し 6 桁打つ") {
                action {
                    tap("#otp_box_3")
                    type("123456")
                }.expectation {
                    select("#txt_otp_result").textIs("otp=123456", waitSeconds: 5)
                }
            }
        }
    }

    @Test("隠れた入力欄へ直接打つ(送信が速く読み返す前に値が消える)")
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
            scene(2, "欄へ打つ") {
                action {
                    type("#field_otp", "246810")
                }.expectation {
                    select("#txt_otp_result").textIs("otp=246810", waitSeconds: 5)
                }
            }
        }
    }

    @Test("PIN のキーパッドを押す")
    func S0030() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_pin", scroll: .down)
                }.expectation {
                    select("#txt_pin_len").textIs("pin_len=0")
                }
            }
            scene(2, "3 桁押して 1 つ消す") {
                action {
                    tap("#key_1", scroll: .down)
                    tap("#key_2", scroll: .down)
                    tap("#key_3", scroll: .down)
                }.expectation {
                    select("#txt_pin_len").textIs("pin_len=3")
                    select("#pin_dots").textIs("●●●")
                }.action {
                    tap("#key_del", scroll: .down)
                }.expectation {
                    select("#txt_pin_len").textIs("pin_len=2")
                }
            }
            scene(3, "4 桁そろうと送信して表示を空に戻す") {
                action {
                    tap("#key_4", scroll: .down)
                    tap("#key_5", scroll: .down)
                }.expectation {
                    select("#txt_pin_result").textIs("pin=1245")
                    select("#txt_pin_len").textIs("pin_len=0")
                }
            }
        }
    }
}
