// 07_スクロール.swift
// ftester 機能: `scrollTo` による要素到達と、「exist/textIs は非スクロール(現在画面のみ判定)」の
// 契約検証(docs/design.md §10)。折り返し下の要素は直前に scrollTo が必須であることを確認する。

import FTDSL

@TestClass(app: "com.ftester.e2e")
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

    @Test("exist は非スクロールのため直前に scrollTo が必要")
    func S0020() {
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
    func S0030() {
        scenario {
            scene(1, "初期画面内の行を始点・終点にドラッグして送る") {
                condition {
                    launchApp()
                }.action {
                    // 始点・終点とも初期画面内で見えている行にする(#row_08 より下へ変えない。
                    // CMP はリストが 462pt あり #row_08 まで完全に見える。SwiftUI 版は短いので #row_06):
                    // 画面外要素は frame がクランプされ座標がずれる既知の罠があるため
                    tap("#nav_scroll")
                    swipeElementToElement("#row_08", "#row_02", durationSeconds: 0.5)
                }.expectation {
                    notExist("#row_01", timeout: 5)
                }
            }
        }
    }

    @Test("notExist(scroll:) で不在をスクロール探索できる")
    func S0040() {
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
        }
    }

    /// **CMP で「先頭へ」直後に探索してタップする回帰テスト**(2026-08-03 に追加)。
    /// Android の間欠ずれは「Compose の a11y ツリーがスワイプ応答より数十 ms 遅れて公開される」
    /// のが根因で、探索の snapshot をキャッシュ迂回にして解決した。
    /// **領域指定なしの形は S0110** に分けてある(別の原因を見ているので両方要る。
    /// docs/verification.md「Compose の探索直後タップ」の回帰テスト表)
    @Test("先頭へ戻した直後に領域指定で探索してタップしても狙った行が選ばれる")
    func S0080() {
        scenario {
            scene(1, "末尾まで送ってから先頭へ戻し、間を置かずに探索する") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_scroll")
                    scrollTo("#row_40", scrollFrame: "#list_rows", maxSwipes: 15)
                    tap("#btn_scroll_top")
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

    // **CMP 固有の制限は 2026-08-03 にすべて解消した**(原因は3つあり別物 ——
    // 容器の外に出る ghost 要素 / a11y ツリーの公開遅れ / 空打ちドラッグのクリック成立。
    // docs/verification.md「Compose の探索直後タップ」)。回帰テストは S0080 / S0110 / S0100

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

    /// **探索はアプリの状態を変えない**。`scrollTo` はタップを含まないので selected は "-" のまま。
    /// 探索終端の空打ちドラッグが**要素の矩形の中で離れているとクリックとして成立**し、
    /// 指の下の行が選ばれていた(2026-08-03 修正。矩形の外へ抜ける終点にして解決)。
    /// **既存資産は1本も検出できなかった** —— 後続のタップが誤選択を上書きするので、
    /// `clearAppData` して「探索の直後に読む」この形でないと表に出ない
    @Test("探索だけではアプリの状態が変わらない")
    func S0100() {
        scenario {
            scene(1, "末尾へ送るだけで、行は選択されない") {
                condition {
                    clearAppData()
                    launchApp()
                }.action {
                    tap("#nav_scroll")
                    scrollTo("#row_40", maxSwipes: 15)
                }.expectation {
                    textIs("#txt_row_selected", "selected=-")
                }
            }
        }
    }

    /// **領域を指定しない探索の回帰テスト**(CMP のみ。他 3 SUT は S0080 がこの形)。
    /// `scrollable` の申告が出ない Compose では viewport が画面全体になり、容器の外に並ぶ
    /// **`label` を持たない ghost 行**を「見えている」と判定して探索がそこで止まり、
    /// 容器の外の座標をタップして**タップが飲まれていた**(2026-08-03 修正。
    /// スナップショットの `depth` から clip 元の祖先を復元して見切れ判定に使う)
    @Test("領域を指定しない探索でも狙った行をタップできる")
    func S0110() {
        scenario {
            scene(1, "末尾まで送ってから先頭へ戻し、間を置かずに探索する") {
                condition {
                    clearAppData()
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
}
