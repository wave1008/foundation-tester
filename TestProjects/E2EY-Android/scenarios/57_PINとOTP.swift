// 57_PINとOTP.swift
// 確かめる癖: 箱は入力欄ではない(実体は透明な入力欄 1 つ #field_otp)・6 桁そろうと 0.3 秒後に自動送信して
// 値が消える(読み返しの前に消える = echo で確かめる)・PIN は IME を使わない自前キーパッド(文字を打つ経路では入らない)。

import FTDSL

@TestClass
class PINとOTPを入力できること {

    @Test("OTP は隠れた入力欄へ 6 桁を打つと自動送信される")
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
            scene(2, "6 桁を打つ") {
                action {
                    type("#field_otp", "123456")
                }.expectation {
                    select("#txt_otp_result").textIs("otp=123456")
                }
            }
        }
    }

    @Test("箱を押しても欄に焦点が移り、そこへ打てる")
    func S0020() {
        scenario {
            scene(1, "開く。3 番目の箱を押す") {
                condition {
                    launchApp()
                    tap("#nav_pin", scroll: .down)
                }.action {
                    tap("#otp_box_3")
                }.expectation {
                    select("#txt_otp_result").textIs("otp=none")
                }
            }
            scene(2, "焦点が移った欄へ(セレクタ無しで)打つ") {
                action {
                    type("654321")
                }.expectation {
                    select("#txt_otp_result").textIs("otp=654321")
                }
            }
        }
    }

    @Test("PIN は自前のキーパッドを押す")
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
            scene(2, "3 桁押して 1 桁消す") {
                action {
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
            scene(3, "4 桁そろうと確定して表示が空に戻る") {
                action {
                    tap("#key_3")
                    tap("#key_4")
                }.expectation {
                    select("#txt_pin_result").textIs("pin=1234")
                    select("#txt_pin_len").textIs("pin_len=0")
                }
            }
        }
    }
}
