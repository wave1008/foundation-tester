// 05_スクロール.swift
// ftester 機能: `scrollTo` による要素到達と、「exist/textIs は非スクロール(現在画面のみ判定)」の
// 契約検証(docs/design.md §10)・ラベルセレクタでの行タップ・`swipeElementToElement` /
// `notExist(scroll:)` / 固定ヘッダを指定した `scrollFrame` / `textContains`・`textMatches` /
// Shirates 準拠のスクロールコマンド(`scrollToBottom`/`scrollToTop`/`scrollDown(repeat:)`/
// `withScrollDown`/`tap(scroll:)`)をまとめて検証する。
// SUT のリストは `FlatList`(仮想化リスト)。可視範囲＋数行しか描画されないため、画面外の行は
// **#id ごとツリーに存在しない**(= scrollTo なしの exist が落ちる契約の裏返しの検証材料)。
// 行は `TaggedButton`(accessibilityRole="button")で実装してある(型語彙の予測は 04 参照)。
// 旧シナリオ境界は tap("#tab_home") でホームへ戻ってから叩き直す形に置き換えてある
// (AppShell はタブ切替で homeChild を null に戻し子画面をアンマウントするため、selected="-" 等の
// 初期値はこれだけで戻る)。**境界でも起動直後の同期用 exist(#txt_home_marker) は元の scene1 に
// あった場合だけ維持する**。
// **S0060/S0080/S0090/S0100 は重量級(scrollFrame 本丸・古いツリー検出・横縦同居・状態不変性)の
// ため統合しない**(各自 launchApp を残す独立 @Test のまま)。
// **S0110/S0120 は旧 14_部分一致と反復.S0010 と旧 16_フィルタORと否定と対称アサーション.S0020/S0030 の
// 移設**(いずれもこのスクロール画面が舞台のため。S0110 は単独、S0120 は S0020→S0030 を1本に統合)。

import FTDSL

@TestClass(app: "com.ftester.e2e.rn")
class スクロールで折り返し下の要素に到達できること {

    @Test("scrollTo 到達・ラベルセレクタ・非スクロール契約・swipeElementToElement・notExist(scroll:)・固定ヘッダ")
    func S0010() {
        scenario {
            scene(1, "07.S0010: scrollTo で行リストの末尾まで到達しタップできる") {
                condition {
                    launchApp()
                }.expectation {
                    // 起動直後は a11y ツリー完成後もポインタ入力を一時的に取りこぼす実装が
                    // Flutter で実測されている。RN で同じ罠があるかは未検証だが、害の無い
                    // 1往復なので安全側として残す。
                    //
                    // requireVisible: false = これは可視性の**検証**ではなく同期のための1往復。
                    // FM はホスト全体で直列化(約1回/秒)されるため、全 launchApp で FM を
                    // 呼ぶとコストだけが乗る。**可視性の検証と、occlusion-guard の誤判定を
                    // 検出する役目は 01_起動と画面遷移 が既定(true)のまま担う**
                    // (README「既知の ftester 欠陥」参照。ここで guard を切っても検出器は死なない)。
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_scroll")
                }.expectation {
                    exist("#row_01")
                }
            }
            scene(2, "scrollTo で #row_40 まで送ってからタップ") {
                action {
                    scrollTo("#row_40", maxSwipes: 15)
                    // scrollTo は「解決できた瞬間」に止まる。最終行が下端に数 px だけ覗いた
                    // 状態でも解決するため、その中心をタップすると行の外(タブバー側)に落ちて
                    // 黙って空振りする(iOS で実測)。もう一度端まで送ると、リスト下端の
                    // padding(80px)ぶん上に停止位置が固定され、行が必ず全体表示になる。
                    swipe(.up)
                }.expectation {
                    exist("#row_40")
                }.action {
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
            scene(4, "07.S0020: 行はラベルセレクタからも引ける") {
                condition {
                    tap("#tab_home")
                }.expectation {
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_scroll")
                }.expectation {
                    exist("#row_01")
                }
            }
            scene(5, ".button&&行 03 でラベル指定タップできる") {
                action {
                    tap(".button&&行 03")
                }.expectation {
                    select("#txt_row_selected").textIs("selected=row_03")
                }
            }
            scene(6, "07.S0030: exist は非スクロールのため直前に scrollTo が必要") {
                condition {
                    tap("#tab_home")
                }.expectation {
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_selector")
                }.expectation {
                    select("#txt_selector_result").textIs("result=-")
                }
            }
            scene(7, "#txt_offscreen は scrollTo で送らない限り exist で見つからない画面外要素") {
                action {
                    // exist 自体はスクロールしないため、scrollTo で画面内に入れてから確認する。
                    // scrollTo を省いて直接 exist するとタイムアウト失敗する契約の裏返しの検証
                    scrollTo("#txt_offscreen", maxSwipes: 12)
                }.expectation {
                    exist("#txt_offscreen")
                }
            }
            scene(8, "07.S0040: swipeElementToElement でリストがスクロールする") {
                condition {
                    tap("#tab_home")
                }.expectation {
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_scroll")
                    // 始点・終点とも初期画面内で見えている行にする(#row_06 より下へ変えない):
                    // 画面外要素は frame がクランプされ座標がずれる既知の罠があるため
                    swipeElementToElement("#row_06", "#row_02", durationSeconds: 0.5)
                }.expectation {
                    notExist("#row_01", timeout: 5)
                }
            }
            scene(9, "07.S0050: notExist(scroll:) で不在をスクロール探索できる") {
                condition {
                    tap("#tab_home")
                }.expectation {
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_scroll")
                }.expectation {
                    // #row_99 は存在しない行(#row_01〜#row_40 の範囲外)。スクロールしても見つからないことを検証する
                    notExist("#row_99", scroll: .down, maxSwipes: 3)
                }
            }
            scene(10, "07.S0070: scrollFrame に固定ヘッダを指定するとリストは動かない") {
                condition {
                    tap("#tab_home")
                }.action {
                    tap("#nav_scroll")
                }.expectation {
                    exist("#row_01")
                }
            }
            scene(11, "スクロールしない固定ヘッダの帯を払っても先頭行が残る") {
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
            // ここで見るのは**同じ経路を通ってデバイスに届くこと**だけ(CMP は 05_スクロール の Sel 版統合
            // @Test が同じ組を通しているので、文字列版はこちらの SUT 群が担う)
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
                    // **戻しは往路より多く撃つ**(フリングの距離は往路と復路で対称ではない。
                    // 12_フリック の同型 scene と同じ理由・同じ回数)。
                    // 2026-08-06 にフル実行で1度だけ `#tag_01` 不在で落ちた
                    // (208 サンプルでは再現せず = 未確定。回数を合わせて余裕を持たせる)
                    scrollLeft(scrollFrame: "#carousel_tags", repeat: 3)
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

    @Test("textContains / textMatches が動的な文字列を検証できる")
    func S0110() {
        scenario {
            scene(1, "スクロール画面を開き行ラベルを部分一致で検証する") {
                condition {
                    launchApp()
                }.expectation {
                    // 起動直後は a11y ツリー完成後もポインタ入力を一時的に取りこぼす実装が
                    // Flutter で実測されている。RN で同じ罠があるかは未検証だが、害の無い
                    // 1往復なので安全側として残す。
                    //
                    // requireVisible: false = これは可視性の**検証**ではなく同期のための1往復。
                    // FM はホスト全体で直列化(約1回/秒)されるため、全 launchApp で FM を
                    // 呼ぶとコストだけが乗る。**可視性の検証と、occlusion-guard の誤判定を
                    // 検出する役目は 01_起動と画面遷移 が既定(true)のまま担う**
                    // (README「既知の ftester 欠陥」参照。ここで guard を切っても検出器は死なない)。
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
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
        }
    }

    @Test("Shirates 準拠のスクロールコマンドと tap(scroll:)・scrollDown(repeat:)と withScrollDown")
    func S0120() {
        scenario {
            scene(1, "16.S0020: `tap(scroll:)` は探索してからタップする(scrollTo を前置するのと同じ)") {
                condition {
                    launchApp()
                    // 起動直後のポインタ取りこぼし対策(理由は S0010 scene 1)
                    exist("#txt_home_marker", requireVisible: false)
                    tap("#nav_scroll")
                }.action {
                    // 狙うのは一覧末尾(このファイルの scrollTo 系 scene と同じ #row_40)。tap(scroll:) は
                    // 内部で scrollTo と同じ探索(runScrollSearch)を使うため、scrollTo 側で実測した
                    // 「末尾行が下端をわずかに覗いただけで解決しタップが空振りする」問題が
                    // ここにも及ぶ可能性がある(未検証)
                    tap("#row_40", scroll: .down, maxSwipes: 15)
                }.expectation {
                    // #txt_row_selected は固定ヘッダなのでスクロール後も見える(07 と同じ理由)。
                    // **スクロール後に元の位置へ戻って検証しない**(戻す向きの操作は不安定)
                    select("#txt_row_selected").textIs("selected=row_40")
                }
            }
            scene(2, "`scrollToBottom` は端まで送る") {
                action {
                    scrollToBottom(maxSwipes: 20)
                }.expectation {
                    // 端まで送られていれば最終行が探索なしで見えている
                    existWithoutScroll("#row_40")
                }
            }
            scene(3, "`scrollToTop` は端まで送る") {
                action {
                    scrollToTop(maxSwipes: 20)
                }.expectation {
                    // 端まで戻っていれば先頭行が探索なしで見えている
                    existWithoutScroll("#row_01")
                }
            }
            scene(4, "16.S0030: scrollDown(repeat:) と withScrollDown") {
                condition {
                    tap("#tab_home")
                    // 起動直後のポインタ取りこぼし対策(理由は S0010 scene 1)
                    exist("#txt_home_marker", requireVisible: false)
                    tap("#nav_scroll")
                }.action {
                    scrollDown(repeat: 2)
                }.expectation {
                    // 遅延生成の一覧なので、送った先では先頭行がツリーから消える
                    notExist("#row_01", timeout: 2)
                }
            }
            scene(5, "`withScrollDown { }` はブロック内をスクロール探索にする") {
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
}
