// 注文履歴.swift
// testbase: user-manual §7「注文履歴」。「自分で確定した注文が『準備中』で追加されていく」を検証する。
// セレクタは iPhone 17 Pro(iOS 27.0)/ja_JP・in-app エンジンで採取。
//
// **自己完結させる理由**: シナリオの実行順は保証されない(_Main.swift は discovery のみ)ので、
// 「チェックアウトが先に走っている」に依存できない。よって注文を1件自分で確定してから履歴を見る。
// チェックアウト.swift と前提の作り方が重なるが、**主張が違う** —— あちらは完了画面、
// こちらは履歴への反映とステータス。準備が重なるのは準備だから。
//
// **注文詳細を開く手順は入れていない**: 履歴の行は id が生成 ID(#order_row_ord_b26b7852)で、
// 一覧の容器にも画面にも id が無い。行を安定して指す手段が現状のアプリには無く、
// MCP も生成 ID をそのまま勧めてくる(別環境では存在しない値)。行に安定 id が付いたら足す。

import FTDSL

@TestClass(app: "com.sutec.mobile")  // iOS/Android 両対応(#id は testTag→resource-id/accessibilityId で共通)
class 注文履歴に確定した注文が並ぶこと {

    private let 氏名 = "E2E チェックアウト"
    private let メール = "e2e-checkout@example.com"
    private let パスワード = "Passw0rd1!"

    func setUp() {
        launchApp()
    }

    /// **未ログイン状態へ戻す**(理由は チェックアウト.swift の tearDown と同じ)。
    /// 他のシナリオはアカウント画面に「ログイン / 登録」が出ることを前提にしている
    func tearDown() {
        ifCanSelect("#btn_back") { tap("#btn_back") }
        ifCanSelect("#tab_account") { tap("#tab_account") }
        // 4.7インチ実機ではアカウント画面の下端が下部タブバーに潜る(D-02)。末尾まで送ってから
        // 押さないと、タップがタブ「カート」に当たりログアウトできない
        ifCanSelect("#btn_logout", waitSeconds: 1) {
            scrollToBottom()
            tap("#btn_logout")
        }
    }

    /// ログイン状態にする。未登録なら登録、登録済みなら「登録に失敗しました」からログインへ回る
    /// (サーバーはユーザーをシードせず、dev の DB はコンテナ再作成ごとに作り直されるため)
    private func ensureSignedIn() {
        tap("#tab_account")
        ifCanSelect("#btn_login", waitSeconds: 1) {
            tap("#btn_login")
            tap("#btn_goto_signup")
            type("#field_name", 氏名)
            type("#field_email", メール)
            type("#field_password", パスワード)
            pressEnter()
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

    /// お届け先・お支払い方法を1件ずつ用意する。**チェックアウト画面の追加ボタンは使わない**
    /// —— あちらには id が無く、シナリオから安定して指せない
    private func ensureAddressAndPayment() {
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

    @Test("確定した注文が注文履歴に準備中で並ぶ")
    func S0010() {
        scenario {
            scene(1, "ログイン状態とお届け先・お支払い方法を用意する") {
                action {
                    ensureSignedIn()
                    ensureAddressAndPayment()
                }.expectation {
                    exist("#btn_logout")
                }
            }
            scene(2, "注文を1件確定して履歴に載せる材料を作る") {
                action {
                    tap("#tab_cart")
                    // カートは実行を跨いで累積する。空を基準にしないと「入れた1点」が曖昧になる
                    ifCanSelect("#btn_remove_fashion_5", waitSeconds: 1) { tap("#btn_remove_fashion_5") }
                    tap("#tab_home")
                    tap("#product_card_fashion_5", timeout: 5)  // おすすめは非同期ロード
                    tap("#btn_add_to_cart")
                    wait(1)  // 「カートに追加しました」スナックバーの整定
                    tap("#btn_open_cart")
                    tap("#btn_checkout")
                    tap("#btn_place_order")
                }.expectation {
                    exist("ご注文ありがとうございます")
                    exist("#text_order_id")
                }
            }
            scene(3, "注文履歴にその注文が準備中で並ぶ") {
                action {
                    tap("#btn_continue_shopping")
                    tap("#tab_account")
                    tap("#btn_orders")
                }.expectation {
                    // §7 の表示項目。scene2 で確定した注文がここに出る
                    exist("準備中")
                    exist("¥18,000")  // ミニマルデザイン腕時計1点の合計(送料無料)
                    exist("1点")
                }
            }
        }
    }
}
