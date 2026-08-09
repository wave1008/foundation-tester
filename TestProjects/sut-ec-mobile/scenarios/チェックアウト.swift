// チェックアウト.swift
// testbase: user-manual §6「ご注文手続き（チェックアウト）」/ §7 注文履歴の前段。
// SUT Store（com.sutec.mobile）の「カート → レジ → 注文確定」ハッピーパス。既存17本で唯一
// 未カバーだった金銭の経路。セレクタは iPhone 17 Pro(iOS 27.0)/ja_JP・in-app エンジンで採取。
//
// 前提の作り方（このシナリオの肝）:
//   サーバーはユーザーをシードせず、DB は dev コンテナの再作成ごとに作り直される。さらに
//   チェックアウト画面の「住所を追加」「支払い方法を追加」には id が無い（MCP も「安定セレクタ
//   無し」と申告する）。そこで前提は **id のあるアカウント配下の画面から** 冪等に作る:
//     - 未登録なら登録、登録済みなら「登録に失敗しました」が出るのでログインへ回る
//     - 住所／支払い方法は空表示が出たときだけ追加する
//   どちらの環境から始めても同じ状態に収束する。
//
// 擬陽性対策: カートはセッションを跨いで累積するので scene 2 で空を基準化する。
// 注文確定でカートが空になることを最後に確認するため、ここを飛ばすと「もともと空だった」
// のか「注文で空になった」のか区別できない。

import FTDSL

@TestClass(app: "com.sutec.mobile")  // iOS/Android 両対応(#id は testTag→resource-id/accessibilityId で共通)
class チェックアウトできること {

    private let 氏名 = "E2E チェックアウト"
    private let メール = "e2e-checkout@example.com"
    private let パスワード = "Passw0rd1!"

    func setUp() {
        launchApp()
    }

    /// **未ログイン状態へ戻す**。他のシナリオ(タブナビゲーション・言語切替 等)はアカウント画面に
    /// 「ログイン / 登録」が出ることを前提にしており、ログインしたまま抜けると軒並み落ちる
    /// (2026-08-10 に実際に5本落とした)。失敗はシナリオ全体を中断するので、緑経路の scene ではなく
    /// tearDown に置く。住所・支払い方法・注文履歴はサーバー側に残るが、未ログインなら見えない
    func tearDown() {
        ifCanSelect("#btn_back") { tap("#btn_back") }
        ifCanSelect("#tab_account") { tap("#tab_account") }
        ifCanSelect("#btn_logout", waitSeconds: 1) { tap("#btn_logout") }
    }

    /// ログイン状態にする。**登録を先に試す** —— 未登録の環境では登録が唯一の入口で、
    /// 登録済みなら同じ画面に「登録に失敗しました」が出るのでログインへ回れる。
    /// 逆順（ログイン先行）だと失敗表示が出るまで待つ分だけ遅い。
    private func ensureSignedIn() {
        tap("#tab_account")
        // ログアウト中のときだけ入口ボタンが出る（ログイン中は #btn_logout）
        ifCanSelect("#btn_login", waitSeconds: 1) {
            tap("#btn_login")
            tap("#btn_goto_signup")
            type("#field_name", 氏名)
            type("#field_email", メール)
            type("#field_password", パスワード)
            pressEnter()  // 保存ボタンがキーボードに隠れるため先に畳む
            tap("#btn_signup")
            ifCanSelect("登録に失敗しました", waitSeconds: 2) {
                tap("#btn_goto_login")
                type("#field_email", メール)
                type("#field_password", パスワード)
                pressEnter()
                tap("#btn_login")
            }
        }
    }

    /// お届け先が1件も無ければ追加する。**チェックアウト画面の「住所を追加」は使わない** ——
    /// あちらには id が無く、シナリオから安定して指せない
    private func ensureAddress() {
        tap("#tab_account")
        tap("#btn_addresses")
        ifCanSelect("登録済みの住所がありません", waitSeconds: 1) {
            tap("#btn_add_address")
            type("#field_full_name", 氏名)
            type("#field_postal_code", "1000001")
            type("#field_prefecture", "東京都")
            type("#field_city", "千代田区")
            type("#field_address_line", "千代田1-1")
            type("#field_phone", "09012345678")
            pressEnter()
            tap("#btn_save")
        }
        tap("#btn_back")
    }

    /// お支払い方法が1件も無ければ追加する（理由は ensureAddress と同じ）
    private func ensurePayment() {
        tap("#tab_account")
        tap("#btn_payments")
        ifCanSelect("登録済みのお支払い方法がありません", waitSeconds: 1) {
            tap("#btn_add_payment")
            type("#field_card_brand", "VISA")
            type("#field_card_number", "4111111111111111")
            type("#field_card_holder", "E2E TEST")
            type("#field_expiry_month", "12")
            type("#field_expiry_year", "2030")
            pressEnter()
            tap("#btn_save")
        }
        tap("#btn_back")
    }

    /// 対象商品の行を削除して空にする。行の削除ボタンは id=btn_remove_<productId> で一意。
    /// 空カートなら空振りして無害
    private func emptyCart() {
        ifCanSelect("#btn_remove_fashion_5", waitSeconds: 1) { tap("#btn_remove_fashion_5") }
    }

    @Test("カートからレジに進み、注文を確定できる")
    func S0010() {
        scenario {
            scene(1, "ログイン状態とお届け先・お支払い方法を用意する") {
                action {
                    ensureSignedIn()
                    ensureAddress()
                    ensurePayment()
                }.expectation {
                    // ログイン済みの証拠。未ログインなら #btn_login のままここで落ちる
                    exist("#btn_logout")
                }
            }
            scene(2, "カートを空にして基準を作る") {
                action {
                    tap("#tab_cart")
                    emptyCart()
                }.expectation {
                    exist("カートは空です")
                }
            }
            scene(3, "商品をカートに入れる") {
                action {
                    tap("#tab_home")
                    tap("#product_card_fashion_5", timeout: 5)  // おすすめは非同期ロード
                    tap("#btn_add_to_cart")
                    wait(1)  // 「カートに追加しました」スナックバーの整定
                    tap("#btn_open_cart")
                }.expectation {
                    exist("ミニマルデザイン腕時計")  // scene2 で空を確認済み → 存在=今回の追加
                    exist("#btn_checkout")
                }
            }
            scene(4, "レジに進み、両方が選択済みで注文を確定できる") {
                action {
                    tap("#btn_checkout")
                }.expectation {
                    // 住所と支払い方法が選ばれるまで確定できない仕様（scene1 で用意済み）
                    exist("#btn_place_order")
                    exist("#text_order_total")
                }
            }
            scene(5, "注文完了画面に注文番号が出る") {
                action {
                    tap("#btn_place_order")
                }.expectation {
                    exist("ご注文ありがとうございます")
                    exist("#text_order_id")
                }
            }
            scene(6, "注文でカートが空になる") {
                action {
                    tap("#btn_continue_shopping")
                    tap("#tab_cart")
                }.expectation {
                    exist("カートは空です")  // scene3 で商品ありを確認済み → 空=注文で消えた
                }
            }
        }
    }
}
