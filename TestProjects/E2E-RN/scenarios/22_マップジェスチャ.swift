// 22_マップジェスチャ.swift
// ftester 機能: `pinchOut` / `pinchIn`(2本指ズーム)/ `doubleTap` / `swipeBy`(斜めを含む相対ドラッグ)。
// 対象は #pad_map(コンテンツ領域いっぱいのパッド)。判定値の契約は E2EAppCMP/docs/ui-contract.md。
// SUT 側の実装は `PanResponder` の生タッチから距離比・重心移動を自前計算している
// (E2EAppRN/src/screens/MapScreen.tsx)。ズームの不感帯は距離の**比**(ZOOM_DEAD_ZONE=0.05)で、
// Flutter の(想定される)絶対距離のしきい値とは仕組みが異なる。

import FTDSL

@TestClass(app: "com.ftester.e2e.rn")
class マップ系ジェスチャが正しく検出されること {

    @Test("ピンチ・ダブルタップ・斜めドラッグが区別して検出される")
    func S0010() {
        scenario {
            scene(1, "マップ画面を開く") {
                condition {
                    launchApp()
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
            // **iOS はエンジンで割れる可能性を Flutter 版から安全側で継承**: 既定の hybrid(in-app)
            // なら通るが、XCUITest のピンチは指の間隔を約 8px しか開かず、絶対距離のしきい値を
            // 前提にした検出には届かないことがある(Flutter で 2026-08-04 実測)。RN の判定は
            // 距離の**比**ベース(ZOOM_DEAD_ZONE=0.05)で Flutter とは仕組みが異なるため、
            // この制約が実際に当てはまるかは未検証(要デバイス実測)。当面は Android に閉じ、
            // iOS のピンチは E2E-CMP と E2E-iOS が担保する
            scene(2, "ピンチアウトで拡大が検出される(iOS は制約未検証のため対象外)") {
                action {
                    android { pinchOut("#pad_map", scale: 2.0) }
                }.expectation {
                    android { select("#txt_zoom_dir").textIs("zoom=in") }
                }
            }
            scene(3, "ピンチインで縮小が検出される(iOS は制約未検証のため対象外)") {
                action {
                    tap("#btn_map_reset")
                    android { pinchIn("#pad_map", scale: 0.5) }
                }.expectation {
                    android { select("#txt_zoom_dir").textIs("zoom=out") }
                }
            }
            scene(4, "単タップではダブルタップカウントが増えない(区別の検証)") {
                action {
                    tap("#btn_map_reset")
                    tap("#pad_map")
                }.expectation {
                    select("#txt_double_count").textIs("double=0")
                }
            }
            // android {} に閉じる(2026-08-08 実測): XCUITest の doubleTap は tapCount=2 の
            // 単一タッチ列で届き、JS の PanResponder には1タップにしか見えない(double=0)。
            // in-app エンジンは2タップを合成するので発火する(実測済み)が、シナリオは
            // 両エンジンで走るため iOS では実行しない。CMP の doubleTap と同じ扱い
            // (ネイティブ認識器 = react-native-gesture-handler を使う実アプリでは tapCount が
            // 読めるためこの制約は SUT の PanResponder 実装に固有)。
            scene(5, "ダブルタップでカウントが1増える") {
                action {
                    android {
                        doubleTap("#pad_map")
                    }
                }.expectation {
                    android {
                        select("#txt_double_count").textIs("double=1")
                    }
                }
            }
            scene(6, "左上への斜めドラッグが両軸で検出される") {
                action {
                    tap("#btn_map_reset")
                    swipeBy("#pad_map", dxRatio: -0.4, dyRatio: -0.4)
                }.expectation {
                    // 両軸とも非 none = 斜めに動いたこと(縦横だけなら片方が none になる)
                    select("#txt_pan").textIs("pan=left-up")
                }
            }
            scene(7, "右下への斜めドラッグ") {
                action {
                    tap("#btn_map_reset")
                    swipeBy("#pad_map", dxRatio: 0.4, dyRatio: 0.4)
                }.expectation {
                    select("#txt_pan").textIs("pan=right-down")
                }
            }
            scene(8, "対象を指定しないジェスチャは画面全体に効く(iOS は制約未検証のため対象外)") {
                action {
                    tap("#btn_map_reset")
                    android { pinchOut() }
                }.expectation {
                    android { select("#txt_zoom_dir").textIs("zoom=in") }
                }
            }
            scene(9, "リセットで全ての値が初期状態に戻る") {
                action {
                    tap("#btn_map_reset")
                }.expectation {
                    select("#txt_zoom_dir").textIs("zoom=-")
                    select("#txt_zoom").textIs("zoom=1.0")
                    select("#txt_pan").textIs("pan=-")
                    select("#txt_double_count").textIs("double=0")
                }
            }
        }
    }
}
