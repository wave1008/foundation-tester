// 25_デバイス単位のメモ.swift
// fleetest 機能: setUpDevice(1回の run × デバイス × クラスで最大1回)と writeMemo / readMemo / memoTextAs。
// メモは同じデバイスで走ったシナリオの間でだけ共有される(シナリオは1本ずつ別プロセス)。
// 3本がどのデバイスに配られても、各デバイスで setUpDevice が1回だけ走れば全部緑になる。
// setUpDevice が同じデバイスで2回走ると、2回目の冒頭の thisIs("") が赤になる(見張り)。
// tearDownDevice はデバイスの仕事の後に専用のプロセスで1回走る(合否には数えない)。

import FTDSL

@TestClass
class デバイス単位のメモ {

    func setUpDevice() {
        readMemo("setUpDeviceRan").thisIs("")
        writeMemo("setUpDeviceRan", "yes")
        launchApp()
        tap("#nav_input")
        select("#txt_echo_single").memoTextAs("echo")
    }

    // デバイスがシナリオを終えた後に1回(結果は run ログの「tearDownDevice of デバイス単位のメモ: passed」)
    func tearDownDevice() {
        readMemo("setUpDeviceRan").thisIs("yes")
        clearMemo()
    }

    @Test("setUpDevice が書いた値を読める(1本目)")
    func S0010() {
        scenario {
            scene(1, "メモを読む") {
                expectation {
                    readMemo("setUpDeviceRan").thisIs("yes")
                    readMemo("echo").thisIs("single=")
                }
            }
        }
    }

    @Test("setUpDevice が書いた値を読める(2本目)・上書きは最後の値")
    func S0020() {
        scenario {
            scene(1, "メモを読んで書き足す") {
                action {
                    writeMemo("scratch", "a")
                    writeMemo("scratch", "b")
                }.expectation {
                    readMemo("setUpDeviceRan").thisIs("yes")
                    readMemo("scratch").thisIs("b")
                }
            }
        }
    }

    @Test("setUpDevice が書いた値を読める(3本目)")
    func S0030() {
        scenario {
            scene(1, "メモを読む") {
                expectation {
                    readMemo("setUpDeviceRan").thisIs("yes")
                    readMemo("echo").thisIs("single=")
                }
            }
        }
    }
}
