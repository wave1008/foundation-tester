# D-16 お気に入り: ログイン前に登録したお気に入りがログインで破棄される(カートは引き継がれる)

| 項目 | 内容 |
|---|---|
| 対象 | お気に入り / `RemoteWishlistRepository` |
| 対応 SC/TC | user-manual §9「ログインすると、カート・お気に入り・注文・住所・支払い方法がそのアカウントに保存されます」 |
| 重大度 | 中(利用者の操作結果が黙って消える。カートと挙動が食い違う) |
| 状態 | 起票 |
| 検出 | 手動(探索的テスト)/ iPhone 13・iOS 26.6.1・実機 |
| 起票日 | 2026-08-31 |

**再現手順**
1. ログアウト状態でホームの ♡ を2つ(`fashion_5` / `books_4`)タップ → お気に入りタブに2件。
2. アカウント → ログイン(お気に入りが空のアカウント)。
3. お気に入りタブを開く。

**期待結果**: ゲストの2件がアカウントへ引き継がれる(カートと同じ)。

**実際の挙動**: **「お気に入りはありません」**(2件が消える)。ホームの ♡ も未登録に戻る。
同じ手順でカートは `POST /cart/merge` で合算される。

**証拠**: ft_snapshot(ログイン前)`#btn_wishlist_fashion_5 value="Wishlisted"` ×2 →
(ログイン後)`staticText "Your wishlist is empty"`。
ソース: `data/repository/impl/RemoteWishlistRepository.kt`(token 取得時に `refresh()` でサーバ値で上書き)
vs `RemoteCartRepository.kt`(`mergeGuest`)。

**仕様裁定(要判断があれば)**: カートと同様にゲストの集合をサーバへマージする(`POST /wishlist/merge`)。
引き継がない仕様にするなら FAQ にカート同様の注意書きを足す。
