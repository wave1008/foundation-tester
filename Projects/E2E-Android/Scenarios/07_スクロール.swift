// 07_スクロール.swift
// ftester 機能: `scrollTo` による要素到達と、「exist/textIs は非スクロール(現在画面のみ判定)」の
// 契約検証(docs/design.md §10)。
// SUT のリストは **RecyclerView**(型は CollectionView)、行は clickable な ViewGroup(型は `Cell`)。
// 行 id は res/values/ids.xml に静的宣言した row_01..row_40 を onBind で割り当てている
// (View は resource-id を実行時生成できないため。E2EAppAndroid/docs/ui-contract.md)。

import FTDSL

@TestClass(app: "com.ftester.e2e.android", platform: "android")
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
                    select("#txt_row_selected").textIs("selected=row_40")
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
            scene(2, ".clickable&&行 03 で引く(行内 TextView にも同じ文字列が出るため型限定が必要)") {
                action {
                    tap(".clickable&&行 03")
                }.expectation {
                    select("#txt_row_selected").textIs("selected=row_03")
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
                    select("#txt_selector_result").textIs("result=-")
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
            scene(1, "#row_06 から #row_02 へドラッグして上方向へスクロールする") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_scroll")
                    // 始点・終点とも初期表示で見えている行にする(#row_06 より下は画面外でヒール対象外の終点に届かない)
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
                    select("#txt_row_selected").textIs("selected=row_40")
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
                    select("#txt_row_selected").textIs("selected=row_30")
                }
            }
            // 上方向は下方向の鏡像だが**マージンの適用辺が入れ替わる**ので別経路(ScrollGeometry)。
            // 下まで送ったこの位置が、上方向を試すのに追加の送りが要らない唯一の場所
            scene(5, "`scrollUp` は1画面ぶんコンテンツを戻す") {
                action {
                    scrollUp(scrollFrame: "#list_rows", repeat: 2)
                }.expectation {
                    notExist("#row_30")
                }
            }
            scene(6, "`withScrollUp { }` はブロック内を上方向のスクロール探索にする") {
                action {
                    withScrollUp(scrollFrame: "#list_rows") {
                        tap("#row_01", maxSwipes: 15)
                    }
                }.expectation {
                    // 直前は selected=row_30 なので、探索・タップが届かなければ落ちる
                    select("#txt_row_selected").textIs("selected=row_01")
                }
            }
            // 別名族は本体(`tap(scroll:)` / `exist(scroll:)`)の糖衣で、転送そのものは
            // Tests/FTBridgeClientTests/SwipeForScrollForwardingTests.swift がソース走査で固定している。
            // ここで見るのは**同じ経路を通って実機に届くこと**だけ(CMP は 15_型付きセレクタ が
            // Sel 版で同じ組を通しているので、文字列版はこちらの3 SUT が担う)
            scene(7, "スクロール探索の別名族(tapWithScrollDown / existWithScrollUp / tapWithoutScroll)") {
                action {
                    tapWithScrollDown("#row_40", maxSwipes: 15)
                }.expectation {
                    // 直前は selected=row_01 なので、届かなければ落ちる
                    select("#txt_row_selected").textIs("selected=row_40")
                    existWithScrollUp("#row_01", maxSwipes: 15)
                }.action {
                    withScrollDown {
                        // 固定ヘッダは常に現在画面にある = スクロールせずに解決できる
                        existWithoutScroll("#txt_row_selected")
                        tapWithoutScroll("#btn_scroll_top")
                    }
                }.expectation {
                    exist("#row_01")
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
                    select("#txt_row_selected").textIs("selected=row_30")
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
            // **横方向は縦の焼き直しではない**: 端マージンの適用辺が入れ替わり、横スクロール容器の
            // `scrollable` 申告はフレームワークで割れる。4 SUT で回す価値が高い
            scene(4, "`scrollLeft` で横カルーセルを戻すと先頭タグが再び見える") {
                action {
                    scrollLeft(scrollFrame: "#carousel_tags", repeat: 2)
                }.expectation {
                    exist("#tag_01")
                    exist("#row_01")
                }
            }
            // **見るのはブロックが方向を継承するかだけ**で、タップまでは含めない。
            // iOS の SwiftUI / Flutter では**横探索の直後のタップが飲まれる**ことがあり
            // (2026-08-04 実測: #tag_08 は整定後も画面内 (205,672) に見えているのに tag=- のまま。
            // CMP と Android では再現しない)、タップまで入れるとこの検証がその問題に巻き込まれる。
            // スクロール直後のタップは縦方向の S0080 / S0110 が回帰テストとして持っている
            scene(5, "`withScrollRight { }` / `withScrollLeft { }` はブロック内を横方向の探索にする") {
                action {
                    withScrollRight(scrollFrame: "#carousel_tags") {
                        // 方向を継承していなければ画面外の #tag_15 に届かず落ちる
                        exist("#tag_15", maxSwipes: 10)
                    }
                }.expectation {
                    // 探索が実際に画面へ入れたこと(現在画面だけで解決できる)
                    existWithoutScroll("#tag_15")
                }.action {
                    withScrollLeft(scrollFrame: "#carousel_tags") {
                        exist("#tag_01", maxSwipes: 10)
                    }
                }.expectation {
                    existWithoutScroll("#tag_01")
                }
            }
            scene(6, "`scrollToRightEdge` / `scrollToLeftEdge` は横の端まで送る") {
                action {
                    scrollToRightEdge(scrollFrame: "#carousel_tags", maxSwipes: 20)
                }.expectation {
                    existWithoutScroll("#tag_20")
                }.action {
                    scrollToLeftEdge(scrollFrame: "#carousel_tags", maxSwipes: 20)
                }.expectation {
                    existWithoutScroll("#tag_01")
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
                    select("#txt_row_selected").textIs("selected=-")
                }
            }
        }
    }
}
