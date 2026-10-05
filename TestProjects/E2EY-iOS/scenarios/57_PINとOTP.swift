// 57_PINとOTP.swift
// 確かめる癖: OTP の箱は入力欄ではない(実体は隠れた #field_otp)・6桁そろうと 0.3 秒後に自動送信されて値が消える
// (読み返す前に消えるので echo で確かめる)・PIN はソフトキーボードを使わない自前キーパッド(文字を打つ経路では入らない)。

import FTDSL

@TestClass
class PINとOTPを入力できること {

    @Test("OTP は隠れた入力欄へ打つ")
    func S0010() {
        scenario {
            scene(1, "6桁を打つと自動送信される") {
                condition {
                    launchApp()
                    tap("#nav_pin")
                }.action {
                    type("#field_otp", "123456")
                }.expectation {
                    select("#txt_otp_result", waitSeconds: 5).textIs("otp=123456")
                }
            }
        }
    }

    @Test("OTP の箱を押して焦点を移してから打つ")
    func S0020() {
        scenario {
            scene(1, "箱を押す") {
                condition {
                    launchApp()
                    tap("#nav_pin")
                }.action {
                    tap("#otp_box_3")
                    type("654321")
                }.expectation {
                    select("#txt_otp_result", waitSeconds: 5).textIs("otp=654321")
                }
            }
        }
    }

    @Test("PIN は自前キーパッドを押す")
    func S0030() {
        scenario {
            scene(1, "3桁押して消す") {
                condition {
                    launchApp()
                    tap("#nav_pin")
                }.action {
                    tap("#key_1")
                    tap("#key_2")
                    tap("#key_3")
                }.expectation {
                    select("#txt_pin_len").textIs("pin_len=3")
                }.action {
                    tap("#key_del")
                }.expectation {
                    select("#txt_pin_len").textIs("pin_len=2")
                }
            }
            scene(2, "4桁そろえる") {
                action {
                    tap("#key_3")
                    tap("#key_4")
                }.expectation {
                    select("#txt_pin_result").textIs("pin=1234")
                }
            }
        }
    }
}
