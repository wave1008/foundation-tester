// デモ_Androidアプリ.swift
// 4台並列デモ用(エミュ標準アプリ: Files com.google.android.documentsui / 連絡先 com.google.android.contacts)。
// 連絡先の実パッケージは com.google.android.contacts(AOSP の com.android.contacts は本エミュ未導入)。
// @TestClass の app は Files(初回ダイアログなし・安定)。連絡先は launchApp(パッケージ名) で個別起動する
// (デモ_Android設定.S0060 のアプリ切替パターンと同型)。
// 全セレクタは 日本語||英語 の連鎖。Android フォルダ名(DCIM/Download等)はロケール非依存のため単独表記。
// データ作成はしない: 連絡先の新規作成フォームは開かない(閉じるボタンに識別子が無く安全に戻せないため未使用)。
// 連絡先の初回起動時のみ通知許可ダイアログが出る(#permission_deny_button, id はロケール非依存)。
// documentsui のフォルダグリッド項目(内部ストレージ配下の DCIM 等)はタップしても遷移しない(実機確認済みの
// 制約。ルート一覧(Show roots 経由)の項目は正常に遷移する)ため、フォルダ深掘りは閲覧のみに留める。

import FTDSL

@TestClass(app: "com.google.android.documentsui", platform: "android")
class デモ_Androidアプリ {

    @Test("Filesアプリでダウンロードと画像フォルダを行き来できる")
    func S0010() {
        scenario {
            scene(1, "起動直後はダウンロードフォルダが開いている") {
                condition {
                    launchApp()
                }.expectation {
                    exist("#breadcrumb_text")
                    exist(".StaticText=ダウンロード||.StaticText=Downloads")
                }
            }
            scene(2, "ルート一覧から画像フォルダへ切り替える") {
                action {
                    tap("ルートを表示||Show roots")
                    tap("画像||Images")
                }.expectation {
                    exist(".StaticText=画像||.StaticText=Images")
                }
            }
        }
    }

    @Test("Filesアプリで表示形式とファイル種別フィルタを切り替えられる(状態は戻す)")
    func S0020() {
        scenario {
            scene(1, "リスト表示とグリッド表示を切り替えて戻す(起動直後はグリッド表示)") {
                condition {
                    launchApp()
                }.action {
                    tap("リスト表示||List view")
                    tap("グリッド表示||Grid view")
                }.expectation {
                    exist("リスト表示||List view")
                }
            }
            scene(2, "画像フィルタを ON にして OFF に戻す") {
                action {
                    tap("画像||Images")
                    valueIs("画像||Images", "1")
                    tap("画像||Images")
                    valueIs("画像||Images", "0")
                }.expectation {
                    exist("#breadcrumb_text")
                }
            }
        }
    }

    @Test("Filesアプリで内部ストレージのフォルダ構成を確認できる(閲覧のみ)")
    func S0030() {
        scenario {
            scene(1, "内部ストレージを開く") {
                condition {
                    launchApp()
                }.action {
                    tap("ルートを表示||Show roots")
                    tap("sdk_gphone64_arm64")
                }.expectation {
                    exist("DCIM")
                    exist("Download")
                }
            }
            scene(2, "スクロールして他のフォルダも確認する") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("Pictures")
                    exist("Music")
                }
            }
        }
    }

    // ダウンロードフォルダは空の場合「No items」になり「一致なし」文言が出ないため、
    // 中身のある内部ストレージ配下で検索する(標準フォルダ名なので確実に不一致になる)。
    @Test("Filesアプリで検索できる(結果は確認して戻す)")
    func S0040() {
        scenario {
            scene(1, "内部ストレージへ切り替える") {
                condition {
                    launchApp()
                }.action {
                    tap("ルートを表示||Show roots")
                    tap("sdk_gphone64_arm64")
                }.expectation {
                    exist("DCIM")
                }
            }
            scene(2, "検索して「一致なし」を確認する") {
                action {
                    tap("#option_menu_search")
                    type("#search_src_text", "xyzzynotfound")
                }.expectation {
                    // 空状態メッセージは「該当するものは [ルート名] にありません」で可変のルート名を含む。
                    // id=message はロケール非依存かつ可変部を跨がないため最も安定
                    exist("#message")
                }
            }
            scene(3, "検索を閉じて内部ストレージへ戻る") {
                action {
                    tap("戻る||Back")
                }.expectation {
                    exist("#breadcrumb_text")
                }
            }
        }
    }

    @Test("連絡先アプリの一覧・検索・整理タブを確認できる(データは作成しない)")
    func S0050() {
        scenario {
            scene(1, "連絡先アプリを起動する(初回の通知許可は許可しない)") {
                condition {
                    launchApp("com.google.android.contacts")
                }.action {
                    ifCanSelect("#permission_deny_button", waitSeconds: 2) {
                        tap("#permission_deny_button")
                    }
                }.expectation {
                    exist("#contacts")
                }
            }
            scene(2, "検索してから閉じる") {
                action {
                    tap("#open_search_bar")
                    type("#open_search_view_edit_text", "xyzzynotfound")
                    tap("戻る||Back")
                }.expectation {
                    exist("#contacts")
                }
            }
            scene(3, "整理タブと設定画面を確認する(閲覧のみ)") {
                action {
                    tap("#nav_organize")
                    tap("設定||Settings")
                }.expectation {
                    exist("並べ替え||Sort by")  // 実ラベル「並べ替え順序」に contains 一致
                    exist("モード||Theme")  // 実ラベルは「モード」(「テーマ」行は存在しない)
                }
            }
        }
    }
}
