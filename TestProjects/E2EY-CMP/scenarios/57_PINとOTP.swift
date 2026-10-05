// 57_PINとOTP.swift
// 確かめる癖: 6 つの箱は入力欄ではない(実体は隠れた入力欄 1 つ・箱を押すと焦点が移る)・6 桁そろうと 0.3 秒で自動送信され
// 値が消える・PIN は自前キーパッド(「文字を打つ」経路では入らない)。

import FTDSL

@TestClass
class PINとOTPを入力できること {

    @Test("OTP: 箱を押して 6 桁打つと自動で送信される")
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
            scene(2, "3 つ目の箱を押して 6 桁打つ") {
                action {
                    tap("#otp_box_3")
                    type("123456")
                }.expectation {
                    select("#txt_otp_result").textIs("otp=123456", waitSeconds: 5)
                }
            }
        }
    }

    @Test("PIN: キーパッドで 4 桁押すと確定し表示が空に戻る")
    func S0020() {
        scenario {
            scene(1, "2 桁押して 1 桁消す") {
                condition {
                    launchApp()
                    tap("#nav_pin", scroll: .down)
                }.action {
                    tap("#key_9")
                    tap("#key_8")
                }.expectation {
                    select("#txt_pin_len").textIs("pin_len=2")
                    select("#pin_dots").textIs("●●")
                }.action {
                    tap("#key_del")
                }.expectation {
                    select("#txt_pin_len").textIs("pin_len=1")
                }
            }
            scene(2, "続けて 4 桁目まで押す") {
                action {
                    tap("#key_7")
                    tap("#key_6")
                    tap("#key_5")
                }.expectation {
                    select("#txt_pin_result").textIs("pin=9765")
                    select("#txt_pin_len").textIs("pin_len=0")
                }
            }
        }
    }
}
