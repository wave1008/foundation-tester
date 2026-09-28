// 36_入力の種類.swift
// 確かめる癖: 数字キーパッド・パスワード・複数行・IME の「次へ」・オートコンプリート・キーボードに隠れる欄。

import FTDSL

@TestClass
class 入力の種類ごとに入力できること {

    @Test("数字・パスワード・複数行")
    func S0010() {
        scenario {
            scene(1, "数字") {
                condition {
                    launchApp()
                    tap("#nav_inputs", scroll: .down)
                }.action {
                    type("#field_number", "123")
                }.expectation {
                    select("#txt_number_echo").textIs("number=123")
                }
            }
            scene(2, "パスワード") {
                action {
                    type("#field_password", "secret")
                }.expectation {
                    select("#txt_password_echo").textIs("password_len=6")
                }
            }
            scene(3, "複数行") {
                action {
                    type("#field_multiline", "a\nb\nc")
                }.expectation {
                    select("#txt_multiline_echo").textIs("lines=3")
                }
            }
        }
    }

    @Test("IME の「次へ」で次の欄へ焦点が移る")
    func S0020() {
        scenario {
            scene(1, "姓を入れて次へ") {
                condition {
                    launchApp()
                    tap("#nav_inputs", scroll: .down)
                }.action {
                    type("#field_first", "山田")
                    pressEnter()
                }.expectation {
                    select("#txt_focus_echo").textIs("focus=second")
                }
            }
        }
    }

    @Draft("既知の制約: Flutter の Autocomplete(iOS は候補のオーバーレイが echo を覆う・Android は入力が拒まれる)")
    @Test("オートコンプリートの候補を選ぶ")
    func S0030() {
        scenario {
            scene(1, "Ja と打って Japan") {
                condition {
                    launchApp()
                    tap("#nav_inputs", scroll: .down)
                }.action {
                    type("#field_auto", "Ja")
                    tap("#auto_opt_japan")
                }.expectation {
                    select("#txt_auto_echo").textIs("auto=Japan")
                }
            }
        }
    }

    @Test("キーボードに隠れる位置の欄へ入力")
    func S0040() {
        scenario {
            scene(1, "下の欄") {
                condition {
                    launchApp()
                    tap("#nav_inputs", scroll: .down)
                }.action {
                    type("#field_bottom", "xyz", scroll: .down)
                }.expectation {
                    select("#txt_bottom_echo", scroll: .down).textIs("bottom=xyz")
                }
            }
        }
    }
}
