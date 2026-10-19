// 25_runで共有するメモ.swift
// fleetest 機能: beforeAll(1回の run × クラスで1回・どのデバイスのシナリオより先)・afterAll(run × クラスで1回・
// 全デバイスの仕事の後)・setUpDevice(1回の run × デバイス × クラスで
// 最大1回)と writeMemo / readMemo / memoTextAs。メモは run 全体(全デバイス)で共有される(シナリオは1本ずつ別プロセス)。
// 3本がどのデバイスに配られても、beforeAll が run で1回だけ走れば全部緑になる。
// beforeAll が2回走ると、2回目の冒頭の thisIs("") が赤になる(見張り)。別のデバイスのシナリオが beforeAll より先に
// 走ると、そのシナリオの readMemo("beforeAllRan") が "" で赤になる(待たせる仕組みの見張り)。
// tearDownDevice はデバイスの仕事の後に専用のプロセスで1回走る(合否には数えない)。**clearMemo() はしない** ——
// メモは run 全体なので、先に終わったデバイスが消すと他のデバイスのシナリオが読めなくなる

import FTDSL

@TestClass
class runで共有するメモ {

    func beforeAll() {
        readMemo("beforeAllRan").thisIs("")
        writeMemo("beforeAllRan", "yes")
        launchApp()
        tap("#nav_input")
        select("#txt_echo_single").memoTextAs("echo")
    }

    // デバイスごとに1回。メモは run 全体なので、デバイスごとの回数はメモでは見張れない(単体テストが見る)
    func setUpDevice() {
        launchApp()
    }

    // デバイスがシナリオを終えた後に1回(結果は run ログの「tearDownDevice of runで共有するメモ: passed」)
    func tearDownDevice() {
        readMemo("beforeAllRan").thisIs("yes")
    }

    // run の全デバイスの仕事が終わった後に専用のプロセスで1回(結果は run ログの「afterAll of runで共有するメモ: passed」)。
    // beforeAll とシナリオが書いたメモを読める(片付けの経路でもメモは run 全体)。scenarioRan は3本とも書く =
    // `--scenario` で一部だけ流す run でも成り立つ(S0020 だけが書く scratch を見ると、S0020 を含まない run で必ず赤になる)
    func afterAll() {
        readMemo("beforeAllRan").thisIs("yes")
        readMemo("scenarioRan").thisIs("yes")
    }

    @Test("beforeAll が書いた値を読める(1本目)")
    func S0010() {
        scenario {
            scene(1, "メモを読む") {
                action {
                    writeMemo("scenarioRan", "yes")
                }.expectation {
                    readMemo("beforeAllRan").thisIs("yes")
                    readMemo("echo").thisIs("single=")
                }
            }
        }
    }

    @Test("beforeAll が書いた値を読める(2本目)・上書きは最後の値")
    func S0020() {
        scenario {
            scene(1, "メモを読んで書き足す") {
                action {
                    writeMemo("scenarioRan", "yes")
                    writeMemo("scratch", "a")
                    writeMemo("scratch", "b")
                }.expectation {
                    readMemo("beforeAllRan").thisIs("yes")
                    readMemo("scratch").thisIs("b")
                }
            }
        }
    }

    @Test("beforeAll が書いた値を読める(3本目)")
    func S0030() {
        scenario {
            scene(1, "メモを読む") {
                action {
                    writeMemo("scenarioRan", "yes")
                }.expectation {
                    readMemo("beforeAllRan").thisIs("yes")
                    readMemo("echo").thisIs("single=")
                }
            }
        }
    }
}
