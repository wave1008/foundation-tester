# D-15 レジ: English 表示でも支払い方法の行が「代金引換(COD)」のまま(3画面で3通りの表記)

| 項目 | 内容 |
|---|---|
| 対象 | ご注文手続き / お支払い方法の行(代金引換)・注文詳細のお支払い |
| 対応 SC/TC | user-manual §12「アプリ全体の表示が即座に切り替わります」/ 観点「国際化 › 翻訳漏れ/固定表記」 |
| 重大度 | 低 |
| 状態 | 起票 |
| 検出 | 手動(探索的テスト)/ iPhone 13・iOS 26.6.1・実機 |
| 起票日 | 2026-08-31 |

**再現手順**
1. ログイン → お支払い方法 → 追加 →「代金引換」を選び保存。
2. アカウント → 言語 → English。
3. カート → Checkout を開き、Payment の行を読む。

**期待結果**: "Cash on delivery"(お支払い方法一覧と同じ訳)。

**実際の挙動**: **「代金引換(COD)」**(未翻訳)。お支払い方法一覧は "Cash on delivery"、
注文詳細はサーバ保存の「代金引換」= 同じものが3通り。

**証拠**: ft_snapshot(English / Checkout)`button "代金引換(COD)" id=payment_row_pay_1af331bd`、
同画面の他の文言は "Shipping address" / "Payment" / "Place order" と英語。
ソース: `feature/checkout/CheckoutViewModel.kt` `"代金引換(COD)"`(`tr()` 未使用)/
`server/.../OrderStore.kt` の `"代金引換"` 固定保存。

**仕様裁定(要判断があれば)**: 表示名は種別(`PaymentType`)から画面側で `tr()` で引く。サーバには種別だけ保存する。
