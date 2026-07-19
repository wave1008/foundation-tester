# sut-ec-mobile サーバー実装 設計書

## 0. 本書について

| 項目 | 内容 |
|---|---|
| 位置づけ | **サーバーサイド本実装の正本**。API 契約・DB・認証・フェーズ計画の詳細を定める |
| 段階 | 第2段階（サーバー実装）。第1段階のモックアップ（[design.md](design.md)）の後継 |
| 前提 | クライアント（`composeApp`）のモデル・リポジトリ契約を踏襲。矛盾時は本書がサーバー側判断の正本、[design.md](design.md) がアプリ側判断の正本 |

### 決定事項（ユーザー確認済み）
- フレームワーク: **Ktor 3 Server (JVM)**
- 永続化: **最初から PostgreSQL**（S0 で Docker Compose + マイグレーション基盤を先に整備）
- 本書のスコープ: **設計ドキュメント確定まで**。実装は承認後に Sonnet サブエージェントへ委譲（CLAUDE.md 準拠）

---

## 1. 目標と非目標

**目標**: モックの `InMemory*Repository` が返していたデータを、実 API + PostgreSQL 永続化で置換する。アプリの UI・画面遷移は原則不変。契約（モデル）を単一情報源にし、API とアプリのズレを構造的に排除する。

**非目標（本段階では対象外）**: 実決済連携、メール送信、管理画面、商品検索の全文インデックス（DB の LIKE/ILIKE で足りる規模）、水平スケール前提の設計。

---

## 2. 技術選定

| 分類 | 採用 | 備考 |
|---|---|---|
| フレームワーク | Ktor 3.x Server（Netty エンジン） | クライアントと同一エコシステム。`ktor` バージョンは version catalog で client と共有 |
| シリアライズ | kotlinx-serialization（`ContentNegotiation` + `json`） | `:shared` の `@Serializable` モデルをそのまま DTO 化 |
| DB アクセス | **Exposed**（DSL/DAO は DSL を採用） | Kotlin ネイティブ。型安全 |
| DB | PostgreSQL 16 | Docker Compose で開発、環境変数で接続 |
| マイグレーション | **Flyway**（`db/migration/V__*.sql`） | スキーマの単一情報源。Exposed の `SchemaUtils.create` は使わない |
| 接続プール | HikariCP | |
| 認証 | JWT Bearer（`ktor-server-auth` + `ktor-server-auth-jwt`） + **bcrypt**（`org.mindrot:jbcrypt` 等） | ステートレス。パスワードは平文保存しない |
| バリデーション | Ktor `RequestValidation` + 自前 | |
| ロギング | Logback + `CallLogging` + `CallId` | |
| テスト | `ktor-server-test-host` + Testcontainers(PostgreSQL) | 統合/契約テスト |
| コンテナ | Docker（マルチステージ）+ Docker Compose（app + db） | |

---

## 3. モジュール構成

現行の単一 `composeApp` に、2 モジュールを追加する。

```
settings.gradle.kts:
  include(":composeApp")
  include(":shared")   # 新規: 契約(モデル/Totals/検索条件)の単一情報源
  include(":server")   # 新規: Ktor サーバー(JVM only)

:shared (KMP: commonMain 主体, JVM+Android+iOS ターゲット)
  data/model/*         # Product, Category, Review, CartItem, OrderTotals, Order, User, Address, PaymentMethod, enum 群
  Totals.kt            # computeOrderTotals（サーバーが注文確定時の権威計算に使用）
  SearchQuery/SortOption
  dto/                 # リクエスト/レスポンス専用型(AuthRequest, TokenResponse, PageResponse ...)

:composeApp  → depends on :shared（data/model と Totals を :shared から参照するよう移設）
:server (JVM) → depends on :shared
  Application.kt       # main + モジュール構成(plugins 配線)
  plugins/             # Serialization, Auth(JWT), StatusPages, CORS, CallLogging, RequestValidation
  db/                  # DataSource(Hikari), Flyway 起動, Exposed Table 定義
  routes/              # catalog, auth, cart, wishlist, orders, account
  service/             # ビジネスロジック(注文確定の権威計算など)
  repository/          # Exposed による DB アクセス
  seed/                # MockCatalog 相当のシード投入(Flyway もしくは起動時投入)
  images/              # 静的画像配信(mock-server/images を参照 or 同梱)
```

### 3.1 モデル共有の設計論点（S0 で決着させる）

`:shared` へ `data/model` を移すと、`Product.name(lang)` 等が `i18n.AppLanguage` に依存する。方針:

- **採用**: `AppLanguage` は言語識別の純粋な enum なので `:shared` へ移す（`i18n` の `LocalStrings` 等の Compose 依存は移さない）。`Product.name(lang)`/`brand`/`description`、`Category.name`、`Review.title/body` は `:shared` に残せる。
- `composeApp` 側の `i18n` パッケージは `AppLanguage` を `:shared` から re-export/参照する形に修正。
- lang 引数のヘルパを持たせたくない場合の代替: モデルは純データにし、lang 解決を `composeApp` の拡張関数へ切り出す。**まず前者（AppLanguage 移設）で進める**。

---

## 4. API 契約

### 4.1 共通事項
- ベースパス: `/api/v1`。JSON（`application/json`, UTF-8）。
- 認証: 保護リソースは `Authorization: Bearer <JWT>`。未認証は `401`。
- 金額: 円の整数（minor unit なし）。モデルは `:shared` の `@Serializable` をそのまま使用。
- エラーエンベロープ（`StatusPages` で統一）:
  ```json
  { "error": { "code": "VALIDATION_ERROR", "message": "…", "details": { } } }
  ```
  code 例: `VALIDATION_ERROR`(400) / `UNAUTHORIZED`(401) / `FORBIDDEN`(403) / `NOT_FOUND`(404) / `CONFLICT`(409) / `INTERNAL`(500)。
- ページング: 一覧は `PageResponse<T> { items, page, pageSize, total }`。query: `?page=0&pageSize=20`。

### 4.2 エンドポイント（リポジトリ契約から導出）

| メソッド | パス | 認証 | 対応する既存契約 |
|---|---|---|---|
| GET | `/categories` | 公開 | `ProductRepository.getCategories` |
| GET | `/products` | 公開 | `getProducts(SearchQuery)`（下記クエリ）+ ページング |
| GET | `/products/featured` | 公開 | `getFeatured` |
| GET | `/products/{id}` | 公開 | `getProduct` |
| GET | `/products/{id}/reviews` | 公開 | `getReviews` |
| GET | `/products/{id}/related` | 公開 | `getRelated` |
| GET | `/products/by-ids?ids=a,b,c` | 公開 | `getProductsByIds`（お気に入り一覧の解決用） |
| POST | `/auth/signup` | 公開 | `AuthRepository.signup` → `TokenResponse` |
| POST | `/auth/login` | 公開 | `AuthRepository.login` → `TokenResponse` |
| POST | `/auth/logout` | 要 | `logout`（サーバーは no-op でも可。トークン失効を持つなら失効） |
| GET | `/me` | 要 | 現在ユーザー（`currentUser` 相当） |
| GET | `/cart` | 要 | `CartRepository.items/totals` |
| POST | `/cart/items` | 要 | `add(productId, quantity)` |
| POST | `/cart/merge` | 要 | ゲストカート統合。`{items:[{productId,quantity}]}` を加算マージ |
| PATCH | `/cart/items/{productId}` | 要 | `setQuantity`（0 以下で削除） |
| DELETE | `/cart/items/{productId}` | 要 | `remove` |
| DELETE | `/cart` | 要 | `clear` |
| GET | `/wishlist` | 要 | `WishlistRepository.productIds` |
| PUT | `/wishlist/{productId}` | 要 | `toggle`(冪等 add) |
| DELETE | `/wishlist/{productId}` | 要 | `remove` |
| GET | `/orders` | 要 | `OrderRepository.orders` |
| GET | `/orders/{id}` | 要 | `getOrder` |
| POST | `/orders` | 要 | `placeOrder`（**合計はサーバー権威計算**、下記 4.4） |
| GET | `/addresses` | 要 | `AccountRepository.addresses` |
| POST/PUT | `/addresses` / `/addresses/{id}` | 要 | `upsertAddress` |
| DELETE | `/addresses/{id}` | 要 | `deleteAddress` |
| POST | `/addresses/{id}/default` | 要 | `setDefaultAddress` |
| GET/POST/PUT/DELETE | `/payment-methods[...]` | 要 | 住所と同型（`upsert/delete/setDefault`） |

**検索クエリ（`GET /products`）**: `text` / `categoryId` / `minPriceYen` / `maxPriceYen` / `tag` / `sort`(`RELEVANCE|PRICE_ASC|PRICE_DESC|RATING|NEWEST`)。`SearchQuery` と 1:1。

### 4.3 リクエスト/レスポンス DTO（`:shared/dto`）
- `SignupRequest { name, email, password }` / `LoginRequest { email, password }`
- `TokenResponse { token, user: User }`
- `AddCartItemRequest { productId, quantity }` / `SetQuantityRequest { quantity }`
- `PlaceOrderRequest { addressId, paymentMethodId }`（**items はサーバー側のカートから確定**。クライアントは金額を送らない）
- `PageResponse<T> { items, page, pageSize, total }`

### 4.4 注文確定の権威（重要な不変条件）
- `POST /orders` は **サーバー保存のカート**と `addressId`/`paymentMethodId` から Order を構築する。
- 金額は **サーバーが `:shared` の `computeOrderTotals` で再計算**（送料規則 `FREE_SHIPPING_THRESHOLD_YEN=3000` / `SHIPPING_FEE_YEN=500`、税込 `taxYen=0`）。クライアント送信の金額は受け付けない。
- Order.items は確定時点の **Product スナップショット**（以後の価格改定・在庫変更の影響を受けない）。
- 確定成功でサーバー側カートを clear。初期 status = `PROCESSING`。`placedAt` はサーバー時刻（ISO-8601、`Asia/Tokyo`）。

---

## 5. DB スキーマ（PostgreSQL / Exposed + Flyway）

Flyway の `V1__init.sql` で作成し、Exposed の Table 定義はこれに一致させる（`SchemaUtils.create` は使わない）。

| テーブル | 主なカラム | 備考 |
|---|---|---|
| `users` | id(uuid pk), name, email(unique), password_hash, created_at | bcrypt ハッシュ |
| `categories` | id(pk text), name_ja, name_en, emoji, sort_order | シード |
| `products` | id(pk text), name_ja/en, brand_ja/en, description_ja/en, price_yen, list_price_yen(null), category_id(fk), rating, review_count, in_stock | シード |
| `product_images` | id, product_id(fk), url_path, position | `imageUrls` を正規化。url_path は相対（例 `images/electronics_1-1.jpg`） |
| `product_tags` | product_id(fk), tag(enum) | 複合 pk |
| `reviews` | id(pk), product_id(fk), author_name, rating, title_ja/en, body_ja/en, date | シード |
| `addresses` | id(pk), user_id(fk), full_name, postal_code, prefecture, city, line1, line2, phone, is_default | ユーザー単位 |
| `payment_methods` | id(pk), user_id(fk), type(enum), brand, last4, holder_name, exp_month, exp_year, is_default | CARD 時のみ card 列に意味 |
| `carts` | user_id(pk, fk) | 1 ユーザー 1 カート |
| `cart_items` | cart_user_id(fk), product_id(fk), quantity | 複合 pk。合計は都度計算 |
| `wishlist_items` | user_id(fk), product_id(fk) | 複合 pk |
| `orders` | id(pk), user_id(fk), status(enum), placed_at, subtotal_yen, shipping_yen, tax_yen, shipping_address_json, payment_label | 住所はスナップショット JSON |
| `order_items` | order_id(fk), position, product_json(jsonb), quantity | **Product スナップショットを jsonb で保持**（`CartItem` を復元可能に） |

- `is_default` の一意化: 「1 ユーザーにつきデフォルト 1 件」はアプリ層で保証（`setDefault` 時に他を false 更新）。部分ユニークインデックスでも可。
- シード: カテゴリ/商品/レビュー/画像は `MockCatalog.kt` の内容を SQL 化 or 起動時投入スクリプトで挿入（S1）。

---

## 6. 認証設計

- サインアップ: email 重複は `409 CONFLICT`。password は bcrypt でハッシュ化して保存。成功で JWT 発行。
- ログイン: email 照合 + bcrypt 検証。失敗は `401`（モックの「任意情報で成功」は**廃止**）。
- JWT: `sub=userId`, 署名鍵は環境変数 `JWT_SECRET`、`exp` は環境変数（既定 30 日）。`realm`/`issuer`/`audience` を設定。
- 保護ルートは `authenticate("auth-jwt") { ... }` で囲む。principal から userId を取得しユーザー単位データにスコープ。
- ログアウト: 既定はクライアント側トークン破棄（サーバー no-op）。将来トークン失効が必要になればブラックリスト or 短命 access + refresh を導入。

---

## 7. 画像配信（python サーバーの統合）

- Ktor `staticFiles("/images", File(imagesDir))` で `mock-server/images/` を配信。開発は同ディレクトリ参照、本番はイメージ同梱 or オブジェクトストレージ（将来）。
- `products.product_images.url_path` は**相対パス**（`images/<id>-<n>.jpg`）を保持。API はそのまま相対で返し、**クライアントが API ベース URL で解決**する。
- これにより第1段階の `mock-server/serve.sh`（python http.server）と `ImageBase` の expect/actual ホスト分岐は不要化（クライアント側 C0 で API ベース URL 構成に一般化）。

---

## 8. 構成・運用

- 環境変数: `DATABASE_URL` / `DB_USER` / `DB_PASSWORD` / `JWT_SECRET` / `JWT_TTL_DAYS` / `PORT` / `IMAGES_DIR` / `CORS_ORIGINS` / `APP_ENV` / `RATE_LIMIT_PER_MIN`。
- ローカル DB 起動は2系統: **Apple Container**(推奨・Docker デーモン不要、`./scripts/dev-server.sh`)、または **Docker Compose**(`db`+`server`、デーモンが使える環境)。Apple Container はコンテナ毎に IP を割り当てるためスクリプトが IP から `DATABASE_URL` を組み立てる。
- **ハードニング(実装済)**: `APP_ENV=production` かつ `JWT_SECRET` が未設定/開発既定(`dev-secret-change-me`)なら**起動失敗**(`requireSecureConfig`)。`CORS_ORIGINS` 指定時はそのオリジンに限定(未指定は開発用 anyHost)。認証系(`/auth/*`,`/me`)は IP 単位で毎分 `RATE_LIMIT_PER_MIN`(既定60)に制限。
- ロギング: `CallId` + `CallLogging`、エラーは `StatusPages` で 4.1 のエンベロープに変換。
- ヘルスチェック: `GET /health`（DB 接続確認込み）。

---

## 9. クライアント側の改訂（`composeApp`）

サーバー化に伴う**契約変更**を含むため、アプリ側も追随する。詳細フェーズは C0–C2。

- **C0 基盤**: `ApiClient`（Ktor `HttpClient` + `ContentNegotiation` + `Auth` プラグイン）。`ImageBase` の expect/actual を **API ベース URL 構成**へ一般化（Android=`10.0.2.2` / iOS=`127.0.0.1` / 本番ホスト）。
- **C1 リポジトリ契約の改訂（重要・破壊的変更）**:
  - 現行 [Repositories.kt](../composeApp/src/commonMain/kotlin/com/sutec/mobile/data/repository/Repositories.kt) の **`CartRepository`/`WishlistRepository`/`AccountRepository` の変更系メソッドは非 `suspend`**（`StateFlow` 即時反映の fire-and-forget）。サーバー化でネットワーク往復になるため **`suspend` 化**する。
  - 実装を `InMemory*` → `Remote*`（HTTP 呼び出し + ローカル `StateFlow` キャッシュ、楽観更新 or ローディング状態）へ差し替え。DI（[Koin.kt](../composeApp/src/commonMain/kotlin/com/sutec/mobile/di/Koin.kt)）のバインドを切替。
  - `computeOrderTotals` はクライアントでは**表示用**に残せるが、確定金額はサーバー権威（4.4）。
  - `placeOrder` は `items/totals` をクライアントから渡さず、`addressId/paymentMethodId` のみ送る形へ。
  - 各機能の ViewModel は `suspend` 化した呼び出しに追随（`viewModelScope.launch`）。
- **C2 認証/状態**: トークン永続化=**実装済**（`multiplatform-settings` の `Settings` で保存: Android=SharedPreferences / iOS=NSUserDefaults）。起動時に `TokenStore` が保存済みトークンを load → `RemoteAuthRepository` が `GET /me` でセッション復元（401=無効なら自動ログアウト）、cart/wishlist 等も token 購読で自動復元。**401失効ハンドリング=実装済**（`ApiClient` の `HttpResponseValidator` が保護APIの 401 でトークンを破棄→`RemoteAuthRepository` が currentUser=null にしアプリ全体がログアウトに反応。`/auth/*` の 401 は除外）。**トースト通知=実装済**（`AppMessages` 通知バス→App ルートの `SnackbarHost` で現在言語表示。失効時と注文失敗時に発火）。**ロード失敗のエラー表示＋リトライ=実装済**（共通 `ErrorState`。Home/Catalog/Search/ProductDetail/Orders が loading/error/content を分岐し「再試行」で再ロード。`getProduct` は 404=notFound とネットワークエラー=retry を区別）。**残**: cart/wishlist/account は楽観更新+背景同期方式（明示ロード工程が無いため `ErrorState` 対象外）で、失敗時はトースト通知に依存。

---

## 10. 実装フェーズ（承認後に委譲）

サーバー（S）は逐次寄り（DB 契約が全体に効くため）。クライアント（C）はサーバー API 確定後に追随。

- **S0 スキャフォールド**: `:shared` 抽出（model/Totals/SearchQuery + `AppLanguage` 移設、`composeApp` 参照修正、ビルド通し）／`:server` スキャフォールド／Docker Compose(Postgres)／Hikari + Flyway 配線／`/health`。
- **S1 カタログ + 画像**: `V1__init.sql`（全テーブル）＋シード投入（`MockCatalog` 移植）／カタログ read API（categories/products/featured/{id}/reviews/related/ids）＋ページング／`/images` 静的配信（**python サーバー置換**）。
- **S2 認証**: `users`／signup/login（bcrypt + JWT）／`/me`／保護ルートの `authenticate` 配線。
- **S3 ユーザーデータ**: cart / wishlist / orders / account を DB 永続・ユーザー単位で実装／注文確定の権威計算（4.4）。
- **S4 ハードニング**: RequestValidation ／エラー契約統一 ／CORS ／CallLogging ／統合テスト（Testcontainers）／Docker マルチステージ仕上げ／README。
- **C0→C2**: 上記 S の進捗に追随（S1 後に C0/C1 の read 系、S2 後に認証、S3 後に cart/order 系）。

---

## 11. 検証（Verification）

- **サーバー統合テスト(実装済・`ApiIntegrationTest`)**: `ktor-server-test-host` + 実 PostgreSQL(Flyway+シード)。カタログ、認証(201/409/401/400)、カート、**注文確定の権威計算が `computeOrderTotals` と一致**、お気に入り、401ガード、404 を通し検証。DB は Testcontainers(Docker) / `TEST_DATABASE_URL`(外部DB) / 無ければ assumeTrue でスキップ、の3モード。**2026-07-19 に Apple Container の Postgres を `TEST_DATABASE_URL` に指定して全12件 PASS**。`OrderTotalsTest`(DB不要の単体)も併存。
- **契約整合**: `:shared` を両者が参照するため、レスポンス JSON がアプリのモデルへ復元可能なことを round-trip テスト。
- **通し（アプリ×サーバー）**: 第1段階の通しシナリオ（一覧→検索→詳細→カート→チェックアウト→注文確定→履歴反映／お気に入り同期／ログイン→言語トグル／住所・支払い CRUD）を、**実サーバー起動下**で Android/iOS 両方確認。
- **移行確認**: python 画像サーバーを停止しても、Ktor `/images` から画像取得できること。

---

## 11.5 実装状況（2026-07-19: S0–S4 + C0–C2 完了、コンパイル検証まで）

- **S0–S4 完了**: `:shared`/`:server` 構築、V2 全スキーマ + Flyway、起動時カタログシード（`CatalogSeed` = client `MockCatalog` の複製、画像相対パス）、カタログ read API、`/images` 配信、JWT+bcrypt 認証、cart/wishlist/orders/account（ユーザー単位）、注文確定の権威計算、RequestValidation、統一エラーエンベロープ、`OrderTotalsTest`、Dockerfile + compose、`server/README.md`。
- **C0–C2 完了**: `ApiClient`/`TokenStore`/`serverBaseUrl` expect-actual、`Remote*Repository` 6種、DI 切替、`MockCatalog`/`InMemory*`/`ImageBase` 削除。
- **契約変更の実装方針(設計 §9 C1 からの調整)**: cart/wishlist/account のミューテーションは **suspend 化せず非 suspend のまま**、`Remote*` 実装が「ローカル `StateFlow` キャッシュ + 楽観更新 + 背景サーバー同期」で実現した。これにより全 ViewModel が無変更。suspend 化が必要だったのは `OrderRepository.placeOrder(addressId, paymentMethodId)` のみ（CheckoutViewModel を追随）。
- **検証範囲**: Android `assembleDebug` / iOS `compileKotlinIosSimulatorArm64` / `:server:build`(テスト含む) すべて PASS。
- **ランタイム E2E 検証済み(2026-07-19、Apple Container)**: Docker/Lima デーモンはこの環境で起動不可だが、**Apple Container**(`brew install container`、Virtualization.framework の軽量VM、デーモン不要)で `postgres:16` を起動し実サーバーを接続実行して検証済み。確認項目: `/health`={"status":"ok","db":"up"} / カタログ(categories=8, featured=12, 検索, 商品詳細, 相対imageUrls) / `/images` 静的配信=200 / 未認証 cart=401 / signup→JWT / 重複email=409 / 誤パスワード=401 / `/me` / 住所・支払い追加 / カート追加→**サーバー権威計算**(小計16860,送料0,税0) / 注文確定(PROCESSING, placedAt=サーバー日付, 支払ラベル"代金引換", 金額一致, カート自動クリア) / 注文履歴 / お気に入り / 空カート注文=400。起動は `./scripts/dev-server.sh`。
- **実機アプリ↔サーバー E2E 検証済み(Android + iOS)**:
  - **Android**(Pixel エミュレータ): ホーム画面がサーバーからカテゴリ/おすすめを取得し**実画像を Coil でレンダリング**(相対→絶対URL解決)、商品詳細で画像カルーセル(4枚)/レビュー/関連。スクショで視認 + サーバーログ 200 着信。
  - **iOS**(iPhone 17 Pro シミュレータ, iOS 27): `xcodegen`+`xcodebuild`(BUILD SUCCEEDED)→`simctl install/launch`。キャッシュ消去後の起動でサーバーへ `GET /categories`, `/products/featured` と**おすすめ商品画像6枚 `/images/*.jpg`** を要求(Coil の Darwin/Ktor エンジン)。Coil は表示された AsyncImage のみ取得するため、これはホーム画面の Compose 描画+画像ロード成功の確証。※ simctl のスクショはこの多重シミュレータ環境で Metal レイヤーを取り込めず白画像になるため、サーバーアクセスログで検証(Info.plist の ATS で 127.0.0.1:8090 平文許可、CADisableMinimumFrameDurationOnPhone 必須)。
- **接続先はハードコードせず設定可能**(既定 8090。8080 は Apache 等と衝突しやすいため回避)。
  - サーバー: `PORT` 環境変数(既定 8090)。`DATABASE_URL` 等も env。
  - クライアント: `gradle.properties` の `sutec.server.host.android` / `sutec.server.host.ios` / `sutec.server.port`(または `-P` / 環境変数 `SUTEC_SERVER_*`)。build 時に `composeApp` が `ServerConfigDefaults.kt` を生成し、`ServerConfig.*.kt` の `serverBaseUrl()` がそれを参照する(`build.gradle.kts` の `generateServerConfig` タスク)。ソース編集不要でポート/ホストを変更できる。
- **既知の挙動**: カタログは公開だが cart 等は要トークン。未ログイン時はローカルキャッシュで動作し、**ログイン時にローカルのゲストカートを `/cart/merge` でサーバーへ加算マージ**（`RemoteCartRepository` が token 変化を検知して実行）。住所/支払い/注文はユーザーごと空スタート（実認証のため。モックのグローバル seed は廃止）。
- **ログイン維持**: トークンを永続化し、アプリ再起動をまたいでログイン状態を保持（Android エミュレータで force-stop→再起動→再ログイン不要、cold start で `/me`+`/cart`+`/wishlist` 復元を確認済み）。

## 12. 未確定 / 将来
- 実決済連携、refresh token、レート制限、全文検索、管理画面、画像のオブジェクトストレージ/CDN 配信、オフライン同梱切替。
</content>
</invoke>
