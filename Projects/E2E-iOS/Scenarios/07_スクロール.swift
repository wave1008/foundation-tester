// 07_スクロール.swift
// ftester 機能: `scrollTo` による要素到達と、「exist/textIs は非スクロール(現在画面のみ判定)」の
// 契約検証(docs/design.md §10)。
// SUT のリストは **UIKit の UITableView**(型は Table / Cell)。UITableView は可視範囲＋数行しか
// セルを実体化しないため、画面外の行は **#id ごとツリーに存在しない**(Compose の LazyColumn と同じ)。
// = scrollTo なしの exist が落ちる契約の裏返しの検証材料になる。

import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
class スクロールで折り返し下の要素に到達できること {

    @Test("scrollTo で行リストの末尾まで到達しタップできる")
    func S0010() {
        scenario {
            scene(1, "スクロール画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_scroll")
                }.expectation {
                    exist("#row_01")
                }
            }
            scene(2, "scrollTo で #row_40 まで送ってからタップ") {
                action {
                    scrollTo("#row_40", maxSwipes: 15)
                    tap("#row_40")
                }.expectation {
                    // #txt_row_selected は固定ヘッダなのでスクロール後も見える
                    textIs("#txt_row_selected", "selected=row_40")
                }
            }
            scene(3, "先頭へで #row_01 が再び見える") {
                action {
                    tap("#btn_scroll_top")
                }.expectation {
                    exist("#row_01")
                }
            }
        }
    }

    @Test("行は Cell 型でラベルセレクタからも引ける")
    func S0020() {
        scenario {
            scene(1, "スクロール画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_scroll")
                }.expectation {
                    exist("#row_01")
                }
            }
            scene(2, ".clickable&&行 03 でラベル指定タップできる(ラベルは Cell 側に集約してある)") {
                action {
                    tap(".clickable&&行 03")
                }.expectation {
                    textIs("#txt_row_selected", "selected=row_03")
                }
            }
        }
    }

    @Test("exist は非スクロールのため直前に scrollTo が必要")
    func S0030() {
        scenario {
            scene(1, "セレクタ画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_selector")
                }.expectation {
                    textIs("#txt_selector_result", "result=-")
                }
            }
            scene(2, "#txt_offscreen は scrollTo で送らない限り exist で見つからない画面外要素") {
                action {
                    // exist 自体はスクロールしないため、scrollTo で画面内に入れてから確認する。
                    // scrollTo を省いて直接 exist するとタイムアウト失敗する契約の裏返しの検証
                    scrollTo("#txt_offscreen", maxSwipes: 12)
                }.expectation {
                    exist("#txt_offscreen")
                }
            }
        }
    }

    @Test("swipeElementToElement でリストがスクロールする")
    func S0040() {
        scenario {
            scene(1, "行間ドラッグでリストがスクロールする") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_scroll")
                    // #row_06 は scrollTo なしでも初期画面内に見えている行(これより下へ変えない。
                    // 画面下部に横カルーセルを置いたぶんリストが短く、#row_08 は見切れる)
                    swipeElementToElement("#row_06", "#row_02", durationSeconds: 0.5)
                }.expectation {
                    notExist("#row_01", timeout: 5)
                }
            }
        }
    }

    @Test("notExist(scroll:) で不在をスクロール探索できる")
    func S0050() {
        scenario {
            scene(1, "スクロール画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_scroll")
                }.expectation {
                    // #row_99 は存在しない行(#row_01〜#row_40 の範囲外)。スクロールしても見つからないことを検証する
                    notExist("#row_99", scroll: .down, maxSwipes: 3)
                }
            }
        }
    }

    // --- スクロール領域の指定(Shirates の scrollFrame 相当)---
    // ホストが領域の矩形から座標を計算してブリッジへ渡す(FTCore/ScrollGeometry)。
    // **iOS hybrid では in-app が座標を実行できず 501 を返す**ので、XCUITest へ落ちる経路も同時に通る。

    @Test("scrollFrame でリストを指定して末尾まで到達できる")
    func S0060() {
        scenario {
            scene(1, "スクロール画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_scroll")
                }.expectation {
                    exist("#row_01")
                }
            }
            scene(2, "#list_rows を指定した scrollTo で #row_40 に到達する") {
                action {
                    scrollTo("#row_40", scrollFrame: "#list_rows", maxSwipes: 15)
                    tap("#row_40")
                }.expectation {
                    textIs("#txt_row_selected", "selected=row_40")
                }
            }
            // **先頭へ戻したことを検証してから次のシーンへ進む**: プログラム的スクロールの
            // 直後に古いツリーを掴む欠陥(828c1f6 で修正済み)の再発防止。競合をそのまま書く形の
            // 回帰テストは S0080(そちらは検証を挟まない。挟むと競合が消える)
            scene(3, "先頭へ戻す") {
                action {
                    tap("#btn_scroll_top")
                }.expectation {
                    exist("#row_01")
                }
            }
            scene(4, "withScrollDown(scrollFrame:) のブロックでも探索できる") {
                action {
                    withScrollDown(scrollFrame: "#list_rows") {
                        tap("#row_30", maxSwipes: 15)
                    }
                }.expectation {
                    textIs("#txt_row_selected", "selected=row_30")
                }
            }
        }
    }

    @Test("scrollFrame に固定ヘッダを指定するとリストは動かない")
    func S0070() {
        scenario {
            scene(1, "スクロール画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_scroll")
                }.expectation {
                    exist("#row_01")
                }
            }
            // 座標が**指定した領域から**作られている証拠。全画面固定のままなら
            // 画面中央 = リストの上を払ってしまい #row_01 は流れて消える
            scene(2, "スクロールしない固定ヘッダの帯を払っても先頭行が残る") {
                action {
                    scrollDown(scrollFrame: "#txt_row_selected", repeat: 2)
                }.expectation {
                    exist("#row_01")
                }
            }
        }
    }

    /// **検証を挟まずに**「先頭へ」の直後を探索するのが要点。プログラム的な
    /// アニメーションスクロールが待たれないと、探索が古い a11y ツリーの座標を
    /// タップして別の行が選ばれる(ステップは成功のまま = 黙って誤った結果)。
    /// 2026-08-02 に in-app エンジンで実際に踏んだ回帰テスト
    @Test("プログラム的スクロールの直後でも探索が古いツリーを見ない")
    func S0080() {
        scenario {
            scene(1, "末尾まで送ってから先頭へ戻し、間を置かずに探索する") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_scroll")
                    scrollTo("#row_40", maxSwipes: 15)
                    tap("#btn_scroll_top")
                    withScrollDown {
                        tap("#row_30", maxSwipes: 15)
                    }
                }.expectation {
                    textIs("#txt_row_selected", "selected=row_30")
                }
            }
        }
    }

    // --- 縦と横のスクロール領域が同居する画面での領域指定 ---
    // これが `scrollFrame` の本丸: 2つのスクロール領域があるとき、**指定した方だけ**が動くこと。
    // 横方向の scrollFrame もここでしか通らない

    @Test("scrollFrame で指定した領域だけが動く(縦リストと横カルーセル)")
    func S0090() {
        scenario {
            scene(1, "スクロール画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_scroll")
                }.expectation {
                    exist("#row_01")
                    exist("#tag_01")
                }
            }
            scene(2, "縦リストを指定して送ると、横カルーセルは動かない") {
                action {
                    scrollDown(scrollFrame: "#list_rows", repeat: 2)
                }.expectation {
                    // 先頭行は流れ、先頭タグは残る
                    notExist("#row_01")
                    exist("#tag_01")
                }
            }
            scene(3, "横カルーセルを指定して送ると、縦リストは動かない") {
                action {
                    tap("#btn_scroll_top")
                    exist("#row_01")
                    scrollRight(scrollFrame: "#carousel_tags", repeat: 2)
                }.expectation {
                    // 先頭タグは流れ、先頭行は残る
                    notExist("#tag_01")
                    exist("#row_01")
                }
            }
        }
    }
}
