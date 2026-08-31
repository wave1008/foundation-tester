# D-09 認証: メールの大文字小文字が別アカウント扱い(二重登録できる・ログインできない)/ 先頭空白で 500

| 項目 | 内容 |
|---|---|
| 対象 | サーバ `AuthService` / `UserRepository` |
| 対応 SC/TC | user-manual §9・FAQ「同じメールアドレスは二重登録できません」 |
| 重大度 | 高(同一人物のアカウントが分裂し、カート・注文・住所が別々になる) |
| 状態 | 起票 |
| 検出 | API 直叩き(静的監査の候補を dev サーバで確認)/ 2026-08-31 |
| 起票日 | 2026-08-31 |

**再現手順(API。アプリの登録・ログイン画面からも同じ)**
1. `Case@Test.com` / `pass1234` で登録 → 201。
2. `case@test.com` / `pass1234` でログイン → **401 invalid credentials**。
3. `case@test.com` / `pass1234` で登録 → **201(2つ目のアカウントができる)**。
4. ` case@test.com`(先頭空白)で登録 → **500 INTERNAL** で本文に
   `org.postgresql.util.PSQLException: ERROR: duplicate key value violates unique constraint "users_email_key"` が生のまま返る。

**期待結果**: メールは大文字小文字・前後空白を正規化して一意。重複は 409、内部例外は露出しない。

**実際の挙動**: 上記のとおり。4 はアプリ上では「登録に失敗しました」に丸まる(D-08)。

**証拠**: curl の応答(上記)。
ソース: `server/.../repository/UserRepository.kt`(`Users.email eq email` 完全一致)/
`service/AuthService.kt`(重複チェックは `req.email` 生値・INSERT は `trim()` 後 → 検査と保存が食い違う)/
`plugins/StatusPages.kt`(`exception<Throwable>` が例外文字列をそのまま返す)。

**仕様裁定(要判断があれば)**: 登録・ログイン・重複判定の全経路で `email.trim().lowercase()` に正規化する。
