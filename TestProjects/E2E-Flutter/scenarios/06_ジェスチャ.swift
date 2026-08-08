// 06_ジェスチャ.swift
// ftester 機能: `tap` の連打カウント / `tap(holdSeconds:)`(長押し)と通常タップの区別 / `swipe` 4方向 /
// `swipePointToPoint`(座標スワイプ)/ `pinchOut` / `pinchIn`(2本指ズーム)/ `doubleTap` /
// `swipeBy`(斜めを含む相対ドラッグ)をまとめて検証する(旧: 06_ジェスチャ の S0010〜S0020 /
// 22_マップジェスチャ)。
// SUT 側は GestureDetector の onPanEnd / onLongPress で検出する。swipe は要素を狙わず
// 画面全体を払う形(iOS=XCUITest の swipeUp() 等 / Android=縦 0.3h↔0.7h の固定座標)で撃たれるため、
// #pad_swipe をコンテンツ領域いっぱいに敷いてある(E2EAppFlutter/docs/ui-contract.md)。
// マップ画面はジェスチャ画面から開く導線のみ(ホームのナビ行を増やすと末尾が下部タブに重なる)。
// 旧シナリオ境界は tap("#tab_home") でホームへ戻ってから叩き直す形に置き換えてある
// (AppShell はタブ切替で子画面の State を破棄するため、tap=0 等の初期値はこれだけで戻る)。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class ジェスチャが正しく検出されること {

    @Test("タップ連打・長押し・4方向スワイプ・座標スワイプ・ピンチ・ダブルタップ・斜めドラッグが区別して検出される")
    func S0010() {
        scenario {
            scene(1, "06.S0010: タップ連打・長押し・4方向スワイプが区別して検出される") {
                condition {
                    launchApp()
                }.expectation {
                    // Flutter は起動直後の数百 ms、a11y ツリーは完成しているのに**ポインタ入力を
                    // 取りこぼす**ことがある(初回タップが成功扱いのまま黙って無反応になる。
                    // Android で実測)。ここで1往復させ、着地を確認してから操作する。
                    //
                    // requireVisible: false = これは可視性の**検証**ではなく同期のための1往復。
                    // FM はホスト全体で直列化(約1回/秒)されるため、全 launchApp で FM を
                    // 呼ぶとコストだけが乗る。**可視性の検証と、occlusion-guard の誤判定を
                    // 検出する役目は 01_起動と画面遷移 が既定(true)のまま担う**
                    // (README「既知の ftester 欠陥」参照。ここで guard を切っても検出器は死なない)。
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_gesture")
                }.expectation {
                    select("#txt_tap_count").textIs("tap=0")
                }
            }
            scene(2, "タップ3回でカウントが3になる") {
                action {
                    tap("#btn_tap_counter")
                    tap("#btn_tap_counter")
                    tap("#btn_tap_counter")
                }.expectation {
                    select("#txt_tap_count").textIs("tap=3")
                    select("#txt_last_gesture").textIs("last=tap")
                }
            }
            scene(3, "長押しでカウントが1になる") {
                action {
                    tap("#btn_long_press", holdSeconds: 1.0)
                }.expectation {
                    select("#txt_press_count").textIs("press=1")
                    select("#txt_last_gesture").textIs("last=longpress")
                }
            }
            scene(4, "通常タップでは長押しカウントが増えない(区別の検証)") {
                action {
                    tap("#btn_long_press")
                }.expectation {
                    select("#txt_press_count").textIs("press=1")
                }
            }
            scene(5, "holdSeconds 指定の長押しも検出される(既定 1 秒以外が実際に届いていること)") {
                action {
                    tap("#btn_long_press", holdSeconds: 2.0)
                }.expectation {
                    select("#txt_press_count").textIs("press=2")
                    select("#txt_last_gesture").textIs("last=longpress")
                }
            }
            scene(6, "上スワイプ") {
                action {
                    swipe(.up)
                }.expectation {
                    select("#txt_swipe_dir").textIs("swipe=up")
                }
            }
            scene(7, "下スワイプ") {
                action {
                    swipe(.down)
                }.expectation {
                    select("#txt_swipe_dir").textIs("swipe=down")
                }
            }
            scene(8, "左スワイプ") {
                action {
                    swipe(.left)
                }.expectation {
                    select("#txt_swipe_dir").textIs("swipe=left")
                }
            }
            scene(9, "右スワイプ") {
                action {
                    swipe(.right)
                }.expectation {
                    select("#txt_swipe_dir").textIs("swipe=right")
                }
            }
            scene(10, "リセットで全カウンタが初期値に戻る") {
                action {
                    tap("#btn_gesture_reset")
                }.expectation {
                    select("#txt_tap_count").textIs("tap=0")
                    select("#txt_press_count").textIs("press=0")
                    select("#txt_swipe_dir").textIs("swipe=-")
                    select("#txt_last_gesture").textIs("last=-")
                }
            }
            scene(11, "06.S0020: swipePointToPoint が座標スワイプとして認識される") {
                condition {
                    tap("#tab_home")
                }.expectation {
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_gesture")
                    // 座標は snapshot の screen 座標系(iOS pt / Android px)。中央列(x=0.5w 付近)は
                    // ui-contract のジェスチャ画面レイアウト制約(ボタン類は幅45%以内・中央行を空ける)
                    // により操作要素が置かれず空いている
                    ios { swipePointToPoint(startX: 200, startY: 550, endX: 200, endY: 250, durationSeconds: 0.3) }
                    android { swipePointToPoint(startX: 540, startY: 1500, endX: 540, endY: 700, durationSeconds: 0.3) }
                }.expectation {
                    select("#txt_swipe_dir").textIs("swipe=up")
                }
            }
            scene(12, "22.S0010: ピンチ・ダブルタップ・斜めドラッグが区別して検出される") {
                condition {
                    tap("#tab_home")
                }.action {
                    // マップ画面はジェスチャ画面から開く(ホームのナビ行を増やすと
                    // 末尾が下部タブに重なる。E2EAppCMP/docs/ui-contract.md)
                    tap("#nav_gesture")
                    tap("#nav_map")
                }.expectation {
                    select("#txt_zoom_dir").textIs("zoom=-")
                    select("#txt_double_count").textIs("double=0")
                }
            }
            // **iOS の Flutter はエンジンで割れる**: 既定の hybrid(in-app)なら通るが、
            // XCUITest のピンチは指の間隔を約 8px しか開かず Flutter のしきい値に届かない
            // (2026-08-04 実測・docs/commands.md)。このシナリオは両エンジンで走るので
            // Android に閉じる —— iOS のピンチは E2E-CMP と E2E-iOS が担保する
            scene(13, "ピンチアウトで拡大が検出される(iOS の Flutter は上流制約で対象外)") {
                action {
                    android { pinchOut("#pad_map", scale: 2.0) }
                }.expectation {
                    android { select("#txt_zoom_dir").textIs("zoom=in") }
                }
            }
            scene(14, "ピンチインで縮小が検出される(iOS の Flutter は上流制約で対象外)") {
                action {
                    tap("#btn_map_reset")
                    android { pinchIn("#pad_map", scale: 0.5) }
                }.expectation {
                    android { select("#txt_zoom_dir").textIs("zoom=out") }
                }
            }
            scene(15, "単タップではダブルタップカウントが増えない(区別の検証)") {
                action {
                    tap("#btn_map_reset")
                    tap("#pad_map")
                }.expectation {
                    select("#txt_double_count").textIs("double=0")
                }
            }
            scene(16, "ダブルタップでカウントが1増える") {
                action {
                    doubleTap("#pad_map")
                }.expectation {
                    select("#txt_double_count").textIs("double=1")
                }
            }
            scene(17, "左上への斜めドラッグが両軸で検出される") {
                action {
                    tap("#btn_map_reset")
                    swipeBy("#pad_map", dxRatio: -0.4, dyRatio: -0.4)
                }.expectation {
                    // 両軸とも非 none = 斜めに動いたこと(縦横だけなら片方が none になる)
                    select("#txt_pan").textIs("pan=left-up")
                }
            }
            scene(18, "右下への斜めドラッグ") {
                action {
                    tap("#btn_map_reset")
                    swipeBy("#pad_map", dxRatio: 0.4, dyRatio: 0.4)
                }.expectation {
                    select("#txt_pan").textIs("pan=right-down")
                }
            }
            scene(19, "対象を指定しないジェスチャは画面全体に効く(iOS の Flutter は上流制約で対象外)") {
                action {
                    tap("#btn_map_reset")
                    android { pinchOut() }
                }.expectation {
                    android { select("#txt_zoom_dir").textIs("zoom=in") }
                }
            }
            scene(20, "リセットで全ての値が初期状態に戻る") {
                action {
                    tap("#btn_map_reset")
                }.expectation {
                    select("#txt_zoom_dir").textIs("zoom=-")
                    select("#txt_zoom").textIs("zoom=1.0")
                    select("#txt_pan").textIs("pan=-")
                    select("#txt_double_count").textIs("double=0")
                }.action {
                    tap("#tab_home")
                }
            }
        }
    }
}
