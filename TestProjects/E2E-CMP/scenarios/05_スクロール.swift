// 05_スクロール.swift
// ftester 機能: `scrollTo` による要素到達と、「exist/textIs は非スクロール(現在画面のみ判定)」の
// 契約検証(docs/design.md §10)。折り返し下の要素は直前に scrollTo が必須であることを確認する。
// あわせて `textContains`/`textMatches`・Shirates 準拠のスクロールコマンド群(`scrollToBottom`/
// `scrollToTop`/`scrollDown(repeat:)`/`withScrollDown`/`tap(scroll:)`)・型付きセレクタ(Sel)の
// スコープ・状態フィルタ・スクロール別名族(`tapWithScrollDown`/`existWithScrollUp`/
// `*WithoutScroll`)をまとめて検証する。
// 旧シナリオ境界は tap("#tab_home") でホームへ戻ってから叩き直す形に置き換えてある
// (App() はタブ/子画面切替で remember 状態を破棄するため、selected=- 等の初期値はこれだけで戻る)。
// **統合B は2本の @Test に分けてある**(ios-xcuitest の壁時計対策。1本に畳むとスクロール操作の
// 直列化で最長シナリオが伸び、レーンを増やしても縮まない。docs/performance-tuning.md §3.6)。
// **S0060/S0080/S0090/S0100/S0110 は重量級(scrollFrame 本丸・古いツリー検出・横縦同居・
// 状態不変性・領域指定なし探索の回帰)のため統合しない**(各自 launchApp を残す独立 @Test のまま)。

import FTDSL

@TestClass
class スクロールで折り返し下の要素に到達できること {

    @Test("scrollTo 到達・非スクロール契約・swipeElementToElement・notExist(scroll:)・固定ヘッダ")
    func S0010() {
        scenario {
            scene(1, "07.S0010: scrollTo で行リストの末尾まで到達しタップできる") {
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
            scene(4, "07.S0020: exist は非スクロールのため直前に scrollTo が必要") {
                condition {
                    tap("#tab_home")
                }.action {
                    tap("#nav_selector")
                }.expectation {
                    select("#txt_selector_result").textIs("result=-")
                }
            }
            scene(5, "#txt_offscreen は scrollTo で送らない限り exist で見つからない画面外要素") {
                action {
                    // exist 自体はスクロールしないため、scrollTo で画面内に入れてから確認する。
                    // scrollTo を省いて直接 exist するとタイムアウト失敗する契約の裏返しの検証
                    scrollTo("#txt_offscreen", maxSwipes: 12)
                }.expectation {
                    exist("#txt_offscreen")
                }
            }
            scene(6, "07.S0030: swipeElementToElement でリストがスクロールする") {
                condition {
                    tap("#tab_home")
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
            scene(7, "07.S0040: notExist(scroll:) で不在をスクロール探索できる") {
                condition {
                    tap("#tab_home")
                }.action {
                    tap("#nav_scroll")
                }.expectation {
                    // #row_99 は存在しない行(#row_01〜#row_40 の範囲外)。スクロールしても見つからないことを検証する
                    notExist("#row_99", scroll: .down, maxSwipes: 3)
                }
            }
            scene(8, "07.S0070: scrollFrame に固定ヘッダを指定するとリストは動かない") {
                condition {
                    tap("#tab_home")
                }.action {
                    tap("#nav_scroll")
                }.expectation {
                    exist("#row_01")
                }
            }
            scene(9, "スクロールしない固定ヘッダの帯を払っても先頭行が残る") {
                action {
                    // 座標が**指定した領域から**作られている証拠。全画面固定のままなら
                    // 画面中央 = リストの上を払ってしまい #row_01 は流れて消える
                    scrollDown(scrollFrame: "#txt_row_selected", repeat: 2)
                }.expectation {
                    exist("#row_01")
                }.action {
                    tap("#tab_home")
                }
            }
        }
    }

    @Test("textContains/textMatches・Shirates 準拠のスクロールコマンド(scrollToBottom/scrollToTop/tap(scroll:))・scrollDown(repeat:)/withScrollDown")
    func S0020() {
        scenario {
            scene(1, "14.S0010: textContains / textMatches が動的な文字列を検証できる") {
                condition {
                    launchApp()
                    tap("#nav_scroll")
                }.expectation {
                    // 行ラベルは `行 01`。完全一致(textIs)でも書けるが、ここは部分一致の検証
                    select("#row_01").textContains("01")
                    select("#row_01").textMatches("^行 [0-9]{2}$")
                }
            }
            scene(2, "選択結果の echo を正規表現で検証する") {
                action {
                    tap("#row_03")
                }.expectation {
                    // `selected=row_03`。数字部分は動的とみなして正規表現で受ける
                    select("#txt_row_selected").textMatches("^selected=row_[0-9]+$")
                    select("#txt_row_selected").textContains("row_03")
                }
            }
            scene(3, "一致しない期待は失敗する側の規約(部分一致は含むかどうかだけを見る)") {
                expectation {
                    // `行 03` は `行 3` を含まない(ゼロ詰め契約。ui-contract.md)。
                    // セレクタ側の部分一致記法でも同じ結論になることを見る
                    notExist("*行 3*")
                    // 同じ契約を**要素単位の否定**でも見る(セレクタ側の否定とは経路が違う)
                    select("#row_03").textContainsNot("行 3")
                    exist("*行 0*")
                    select("#row_03").textContains("行 0")
                }
            }
            scene(4, "16.S0020: Shirates 準拠のスクロールコマンドと tap(scroll:)") {
                condition {
                    tap("#tab_home")
                    tap("#nav_scroll")
                }.action {
                    // 狙うのは一覧末尾(07 と同じ `#row_40`)
                    tap("#row_40", scroll: .down, maxSwipes: 15)
                }.expectation {
                    // #txt_row_selected は固定ヘッダなのでスクロール後も見える(07 と同じ理由)。
                    // **スクロール後に元の位置へ戻って検証しない**(戻す向きの操作は不安定)
                    select("#txt_row_selected").textIs("selected=row_40")
                }
            }
            scene(5, "`scrollToBottom` は端まで送る") {
                action {
                    scrollToBottom(maxSwipes: 20)
                }.expectation {
                    // 端に着いていれば末尾行が**探索なしで**見えている(端判定は静止署名の
                    // 2回連続不変化。commands.md の scrollToBottom/scrollToTop 節)
                    existWithoutScroll("#row_40")
                }
            }
            scene(6, "`scrollToTop` は端まで送る") {
                action {
                    scrollToTop(maxSwipes: 20)
                }.expectation {
                    // 端まで戻っていれば先頭行が**探索なしで**見えている
                    existWithoutScroll("#row_01")
                }
            }
            scene(7, "16.S0030: scrollDown(repeat:) と withScrollDown") {
                condition {
                    tap("#tab_home")
                    tap("#nav_scroll")
                }.action {
                    scrollDown(repeat: 2)
                }.expectation {
                    // 遅延生成の一覧なので、送った先では先頭行がツリーから消える
                    notExist("#row_01", timeout: 2)
                }
            }
            scene(8, "`withScrollDown { }` はブロック内をスクロール探索にする") {
                condition {
                    scrollToTop(maxSwipes: 20)
                }.action {
                    withScrollDown {
                        // 明示の scroll: を書かなくても探索される(狙いは 07 と同じ末尾行)
                        tap("#row_40")
                        // 固定ヘッダは現在画面にあるので、探索を打ち消して確認する
                        existWithoutScroll("#txt_row_selected")
                    }
                }.expectation {
                    select("#txt_row_selected").textIs("selected=row_40")
                }.action {
                    tap("#tab_home")
                }
            }
        }
    }

    @Test("型付きセレクタ(Sel)のスコープ・状態フィルタ・スクロール別名族が文字列版と同じ挙動になること")
    func S0030() {
        scenario {
            scene(1, "15.S0020: スコープ・状態フィルタ") {
                condition {
                    launchApp()
                    tap(.id("nav_scroll"))
                }.expectation {
                    exist(.id("list_rows").find(.id("row_02")))                    // #list_rows >> #row_02
                    select(.id("list_rows").find(.type(.button).nth(2))).textIs("行 02")   // #list_rows >> .button[2]
                    notExist(.id("list_rows").find(.id("txt_row_selected")))
                }
            }
            scene(2, "checked / enabled のフィルタ") {
                condition {
                    tap(.id("tab_controls"))
                    tap(.id("btn_controls_reset"))
                }.expectation {
                    exist(.id("cb_agree").checked(false))                 // #cb_agree&&checked=false
                    countIs(.type(.button).enabled(false), 2)             // .button&&enabled=false
                }.action {
                    tap(.id("cb_agree"))
                }.expectation {
                    exist(.id("cb_agree").checked())                      // #cb_agree&&checked=true
                    countIs(.type(.button).enabled(false), 1)
                }
            }
            /// Shirates 由来のスクロール別名族は String 版と Sel 版が1対1(design.md §型付きセレクタ)。
            /// 委譲先の方向を取り違えても**コンパイルは通る**ので、実際に届くことをここで固定する
            /// (方向の転記ミス自体は SelScrollVariantDispatchTests がユニットで押さえる)
            scene(3, "15.S0030: スクロール別名族の Sel 版が文字列版と同じ挙動になる") {
                condition {
                    tap(.id("tab_home"))
                }.action {
                    tap(.id("nav_scroll"))
                }.expectation {
                    exist(.id("row_01"))
                }
            }
            scene(4, "tapWithScrollDown の Sel 版で折り返し下の行まで送ってタップする") {
                action {
                    tapWithScrollDown(.id("row_40"), maxSwipes: 15)
                }.expectation {
                    // 固定ヘッダなのでスクロール後も見える
                    select(.id("txt_row_selected")).textIs("selected=row_40")
                }
            }
            scene(5, "existWithScrollUp の Sel 版で先頭へ戻りながら確認する") {
                expectation {
                    existWithScrollUp(.id("row_01"), maxSwipes: 15)
                }
            }
            scene(6, "withScrollDown の中でも *WithoutScroll の Sel 版は現在画面だけを見る") {
                action {
                    withScrollDown {
                        // 固定ヘッダは常に現在画面にある = スクロールせずに解決できる
                        existWithoutScroll(.id("txt_row_selected"))
                        tapWithoutScroll(.id("btn_scroll_top"))
                    }
                }.expectation {
                    exist(.id("row_01"))
                }.action {
                    tap("#tab_home")
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
            // 上方向は下方向の鏡像だが**マージンの適用辺が入れ替わる**ので別経路(ScrollGeometry)。
            // 末尾に居るこの位置が、上方向を試すのに追加の送りが要らない唯一の場所
            scene(3, "`scrollUp` は1画面ぶんコンテンツを戻す") {
                action {
                    scrollUp(scrollFrame: "#list_rows", repeat: 2)
                }.expectation {
                    notExist("#row_40")
                }
            }
            scene(4, "`withScrollUp { }` はブロック内を上方向のスクロール探索にする") {
                action {
                    withScrollUp(scrollFrame: "#list_rows") {
                        tap("#row_01", maxSwipes: 15)
                    }
                }.expectation {
                    // 直前は selected=row_40 なので、探索・タップが届かなければ落ちる
                    select("#txt_row_selected").textIs("selected=row_01")
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
                    select("#txt_row_selected").textIs("selected=row_30")
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
            // **横方向は縦の焼き直しではない**: 端マージンの適用辺が入れ替わり、横スクロール容器の
            // `scrollable` 申告はフレームワークで割れる(Compose は出さない)。4 SUT で回す価値が高い
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
            // 横の端送り。端判定の機構(静止署名の2回連続不変化)は縦の scrollToBottom/scrollToTop と
            // 共通で軸だけが違うが、**容器の scrollable 申告はフレームワークで割れる**ので4 SUT で回す
            // (カルーセルは 20 件・1画面 3〜4 件のため往復で十数秒かかる。2026-08-04 にコスト優先で
            //  CMP のみにしたが、揃える判断に変えた)
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

    /// **領域を指定しない探索の回帰テスト**(CMP のみ。他 3 SUT は S0080 がこの形)。
    /// `scrollable` の申告が出ない Compose では viewport が画面全体になり、容器の外に並ぶ
    /// **`label` を持たない ghost 行**を「見えている」と判定して探索がそこで止まり、
    /// 容器の外の座標をタップして**タップが飲まれていた**(2026-08-03 修正。
    /// スナップショットの `depth` から clip 元の祖先を復元して見切れ判定に使う)。
    ///
    /// **既知の残存フレーク**(2026-08-03 実測)。落ちたときの値は `selected=-` =
    /// **タップが飲まれている**(誤った行が選ばれるのではない)。
    /// **新しい退行ではなくこの修正の取りこぼし** —— 修正前は決定的に落ちていた。
    ///
    /// **効くのは iOS 8 レーン同時稼働**(スイート実行)。単独実行では出ない:
    /// スイート **3/10(30%)** / 単独 **2/96(2%)**。
    /// **計装を入れると消える**(0/13)—— probe の I/O がタイミングを変える heisenbug。
    /// 追い方と未検証の仮説は docs/verification.md「Compose の探索直後タップ」原因1 の「残存」
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
                    select("#txt_row_selected").textIs("selected=row_30")
                }
            }
        }
    }
}
