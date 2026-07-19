# sut-ec-mobile 設計書

## Context（なぜ作るか）

Amazon 風の EC 買い物アプリを Compose Multiplatform で iOS / Android 両対応で作る。
最終的にはサーバーサイドも実装するが、**第1段階は「ローカルのダミーデータで動くモックアップ」**。
買い物・アカウント系の10機能を実装し、実際に画面遷移・カート操作・チェックアウトまで通しで動く状態を目指す。
本書は実装の正本。実装は Sonnet サブエージェントに委譲し、メインセッションが計画・レビュー・検証を担う（CLAUDE.md 準拠）。

> **現況（2026-07-19）**: 第1段階（モック）に続き、**第2段階（サーバー実装）も完了**。アプリは実サーバー（Ktor3 + PostgreSQL + JWT）に接続して動作し、Android/iOS 実機で E2E 検証済み。本書は主に第1段階の設計記録で、モック前提の記述（インメモリ／`delay()` 擬似／モック認証／python 画像配信）は第2段階で置換済み。**サーバー実装とクライアント接続の現行正本は [server-design.md](server-design.md)**。

## 決定事項（ユーザー確認済み）

- 機能: 提案の10機能で確定
- UI言語: **日英2言語対応**（実行時トグル）
- デザイン: **ライト&ミニマル**（白基調・余白広め・単色アクセント）
- 商品画像: **著作権処理の対象外画像をローカル配信**（AI生成/CC0/PD＋複製。`mock-server/images/<id>-<n>.jpg`。出典台帳は `mock-server/image-provenance.json`）。第1段階は `python3 -m http.server` で配信していたが、**第2段階では `:server` が `/images` で配信**（アプリは Coil3 で接続先URLから取得）。
- データ: この段階は**ローカルのインメモリ・ダミー**（`delay()` で通信を擬似）

## 技術スタック

| 項目 | 採用 | 備考 |
|---|---|---|
| Kotlin | 2.4.x | |
| Compose Multiplatform | 1.11.0 | 最新安定 |
| ターゲット | Android / iOS (arm64 + simulatorArm64 + x64) | |
| モジュール構成 | `composeApp`(KMP アプリ) / `:shared`(モデル契約) / `:server`(Ktor サーバー) の3モジュール | composeApp は commonMain / androidMain / iosMain |
| ナビゲーション | androidx.navigation-compose（マルチプラットフォーム / 型安全 @Serializable ルート） | CMP 1.10+ で安定 |
| ViewModel | androidx.lifecycle-viewmodel-compose（マルチプラットフォーム） | StateFlow で状態管理 |
| DI | Koin 4.x | `composeApp`(クライアント)のみ。`:server` は素の Ktor(DI なし) |
| 画像 | Coil 3（coil-compose + coil-network-ktor） | Ktor engine: iOS=Darwin / Android=OkHttp |
| 非同期 | kotlinx-coroutines / StateFlow | |
| シリアライズ | kotlinx-serialization | ナビ引数 + API(DTO)/`:shared` モデル |
| i18n | 自前 `tr(ja, en)`（呼び出し側インライン） + `LocalAppLanguage`(CompositionLocal) + `LocaleController`(StateFlow) | 実行時トグルを最優先し compose-resources のロケール切替摩擦を回避。文字列レジストリは持たない(並列実装での書き込み競合回避) |
| サーバー(第2段階) | Ktor 3 Server / Exposed + PostgreSQL / Flyway / JWT(bcrypt) | 詳細は [server-design.md](server-design.md)。モデル契約は `:shared` に抽出し共有 |

iOS 連携は CocoaPods 不使用。`composeApp` が Framework を書き出し、`iosApp` の Xcode プロジェクトが `ComposeUIViewController` をホストする（現行 CMP テンプレート方式）。

## ディレクトリ構成（現行 = 第2段階、3モジュール）

```
settings.gradle.kts: include(":composeApp", ":shared", ":server")

shared/src/commonMain/kotlin/com/sutec/mobile/       # client/server 共有契約
├─ i18n/AppLanguage.kt
├─ data/model/                  # Product, Category, Review, CartItem, Order, User, Address, PaymentMethod
└─ data/repository/             # Totals.kt(computeOrderTotals), SearchQuery.kt
└─ data/dto/                    # AuthDtos, UserDataDtos, PageResponse

composeApp/src/commonMain/kotlin/com/sutec/mobile/
├─ App.kt                      # ルート: Theme + NavHost + BottomBar
├─ di/                          # Koin.kt, FeatureModule.kt
├─ designsystem/               # theme/color/type/shape + 共通コンポーネント
│  ├─ Theme.kt Color.kt Type.kt Shape.kt Spacing.kt
│  └─ component/               # AppButtons, PriceText, ProductCard, RatingStars, QuantityStepper, AppTopBar, EmptyState ...
├─ i18n/Localization.kt        # tr(ja, en) + LocalAppLanguage + LocaleController
├─ util/AppMessages.kt          # トースト等のアプリ内メッセージ通知
├─ data/
│  ├─ remote/                   # ApiClient, TokenStore, ServerConfig(expect serverBaseUrl)
│  └─ repository/               # ProductRepository 等のインターフェース定義(:shared のモデルに依存)
│     └─ impl/                  # Remote{Product,Cart,Wishlist,Order,Auth,Account}Repository（Ktor client 実装）
├─ navigation/                 # Routes.kt(@Serializable), AppNavHost.kt, AppBottomBar.kt
└─ feature/                    # 各機能 = 1ディレクトリ = {XxxScreen.kt, XxxViewModel.kt}
   ├─ home/ catalog/ search/ productdetail/ cart/ checkout/
   ├─ wishlist/ orders/ auth/ profile/ address/
androidMain/... : MainActivity, SutEcApplication(Koin初期化), AndroidManifest, ServerConfig.android.kt(Ktor OkHttp)
iosMain/...     : MainViewController.kt, ServerConfig.ios.kt(Ktor Darwin)
iosApp/         : Xcode プロジェクト(SwiftUI で ComposeUIViewController をホスト)

server/src/main/kotlin/com/sutec/mobile/server/      # Ktor3 サーバー。詳細は server-design.md
├─ Application.kt, plugins/(Cors/RateLimit/Security/Validation/StatusPages/Monitoring/Serialization)
├─ db/(Database.kt, Tables.kt) + resources/db/migration/(V1__init.sql, V2__schema.sql, Flyway)
├─ auth/Jwt.kt, service/AuthService.kt
├─ repository/(CatalogRepository, CartStore, WishlistStore, OrderStore, AccountStore, UserRepository)
├─ routes/(CatalogRoutes, AuthRoutes, UserDataRoutes)
└─ seed/CatalogSeed.kt          # 起動時カタログシード(旧 MockCatalog の複製)
```

第1段階(モック)時代は単一 `composeApp` モジュールで、モデルは `data/model/`、カタログは `data/mock/MockCatalog.kt`、Repository は全てインメモリ実装だった。第2段階でモデル/Totals/SearchQuery を `:shared` に抽出し、`:server` を新設、`data/mock/`・インメモリ実装は削除して `Remote*Repository` に置換した。

各ファイルは ~2,000 行以下・1タスクの編集は1〜2ファイルに収まる粒度を維持（CLAUDE.md）。

## デザインシステム（ライト&ミニマル）

- Material 3 ベース。ライト基調 + **システムのダークモード追従**（`AppTheme` が `isSystemInDarkTheme()` でライト/ダーク配色を切替。第2段階で実装）。
- 配色: 白/極薄グレーのサーフェス、テキストは高コントラストのニアブラック、**単色アクセント（洗練されたインディゴ寄り）**、価格・CTA・セール表示のみ差し色。
- 角丸 12–16dp、境界線は薄グレーの hairline、影は控えめ。余白は 8pt グリッド（`Spacing`）。
- タイポは M3 タイプスケールを商品/価格向けに調整（価格は tabular figures 相当の強調）。
- 共通コンポーネントを `designsystem/component` に集約し、機能側はこれを組むだけにする。

## 10機能 → 画面/ViewModel

| # | 機能 | ディレクトリ | 主要リポジトリ |
|---|---|---|---|
| 1 | 商品一覧・カテゴリ | home, catalog | ProductRepository |
| 2 | 検索・絞り込み（価格/カテゴリ/並替） | search | ProductRepository |
| 3 | 商品詳細（画像カルーセル・レビュー・カート追加） | productdetail | ProductRepository |
| 4 | カート（数量変更・削除・小計） | cart | CartRepository |
| 5 | チェックアウト/注文確認（住所・支払い選択→確定） | checkout | Cart/Account/Order |
| 6 | お気に入り | wishlist | WishlistRepository |
| 7 | 注文履歴（一覧・詳細） | orders | OrderRepository |
| 8 | ログイン/サインアップ（実認証: bcrypt/JWT） | auth | AuthRepository |
| 9 | プロフィール/アカウント設定（言語切替含む） | profile | Auth/Account |
| 10 | 住所・支払い方法管理 | address | AccountRepository |

下タブ: ホーム / 検索 / カート / お気に入り / アカウント。カートバッジ・お気に入り状態は StateFlow で全画面同期。

## データ層

### 第1段階（モック・歴史）
- 各 Repository はインメモリ。カタログは `MockCatalog` のシード（多カテゴリ・複数画像URL・レビュー）。
- 通信は `delay(200–600ms)` で擬似。カート/お気に入り/認証セッションは `StateFlow` で保持し画面横断で共有。
- モデルは `@Serializable`（将来のAPI/JSONにそのまま流用）。ID 採番はインメモリのカウンタ。

### 第2段階（現行）
- `MockCatalog`/インメモリ実装・`delay()` 擬似は削除。`Remote*Repository`（`data/repository/impl/`）が Ktor client 経由で `:server` の実 API を呼ぶ。モデル・`Totals`（`computeOrderTotals`）・`SearchQuery` の契約は `:shared` に移動。
- `CartRepository`/`WishlistRepository`/`AccountRepository` の変更系メソッドは非 `suspend` のまま維持（当初 suspend 化を想定していたが実施せず）。`Remote*Repository` はローカル `StateFlow` を楽観的に更新しつつ背景でサーバー同期する方式で対応した。詳細は [server-design.md](server-design.md)。

## 実装フェーズと委譲計画

CLAUDE.md 準拠: 共有契約は先に確定 → 機能はディレクトリ互いに素で並列委譲。

- **Phase 0 スキャフォールド（逐次・要ビルド検証）**: Gradle / version catalog / `composeApp` / android+ios エントリ / Koin 初期化 / 空 `App.kt`。**Android で起動確認**まで通す。iOS フレームワーク書き出し設定も含む。
- **Phase 1 基盤（逐次・共有契約）**: ① designsystem（theme+主要component）② data(model/mock/repository) ③ i18n(tr()/LocaleController) ④ navigation(Routes/BottomBar/空NavHost)。以降の全機能が依存するため先行確定。
- **Phase 2 機能（並列・ディレクトリ互いに素）**: 5バッチを Sonnet 並列委譲。
  - A: home+catalog / B: search+productdetail / C: cart+checkout / D: wishlist+orders / E: auth+profile+address
  - 各バッチは自分の `feature/xxx` のみ書き込み、共有は読み取り専用。各機能は `NavGraphBuilder` 拡張を公開し、集約(`AppNavHost`)はメインが最後に結線（書込み競合回避）。
- **Phase 3 統合・仕上げ（メイン）**: NavHost 結線 / 下タブ / 全体トーン調整 / Android+iOS 実機(シミュレータ)で通し確認・スクショ・修正。

## 検証（Verification）

- ビルド: `./gradlew :composeApp:assembleDebug`（Android）/ `xcodebuild` で iOS simulator ビルド。
- 起動: Android エミュレータへ install→起動、iOS Simulator 起動。`run` スキルを使用。
- 通しシナリオ（両OS）: 一覧→検索/絞り込み→商品詳細→カート追加→カート数量変更→チェックアウト→注文確定→注文履歴に反映 / お気に入り登録↔一覧同期 / ログイン→プロフィールで日英トグルが全画面反映 / 住所・支払いのCRUD。
- 各フェーズ完了時にメインがレビュー（差し色の使い方・余白・言語切替漏れ・状態同期）。

## 実装状況（モックアップ第1段階: 完了）

- 全10機能を実装し Android エミュレータ / iOS シミュレータ両方で起動・主要フロー動作確認済み。
- 検証済みフロー(Android): ホーム→商品詳細→カート追加(バッジ同期)→チェックアウト(シード住所/支払い)→注文確定→注文履歴反映 / アカウントで日英切替が全画面即時反映。
- iOS: 同一 Compose UI が起動・レンダリング（ネットワーク画像/Koin/Coil-Ktor(Darwin) 動作）。

### iOS の必須制約(罠)
- Compose Multiplatform(iOS) は起動時に `Info.plist` の `CADisableMinimumFrameDurationOnPhone=true` を要求する。無いと `PlistSanityCheck` が例外→即クラッシュ。
  そのため `iosApp/project.yml` は自動生成でなく明示 Info.plist(`info.properties`)でこのキーを付与している。`xcodegen generate` の再実行時も維持すること。
- ビルド/起動: Android=`./gradlew :composeApp:assembleDebug` + adb install。iOS=`cd iosApp && xcodegen generate && xcodebuild ... -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO` → `simctl install/launch`。
- **画像サーバー必須(第1段階の記述)**: 第1段階は `mock-server/serve.sh`(python http.server:8000)で配信していた。**第2段階では `:server` が `/images` で配信**し python 配信は不要（`./scripts/dev-server.sh` でサーバー起動）。停止していると全商品画像がプレースホルダになる点は同じ。

### 画像パイプライン(mock-server/)
- 実体: `mock-server/images/<productId>-<n>.jpg`(全123枚)。`imgmap.json` が id→検索語→枚数。
- **配信画像は著作権処理の対象外のみ**: AI生成(Pollinations) / CC0・パブリックドメイン / それらの複製。権利処理が必要な画像は削除済み(出典台帳は `mock-server/image-provenance.json`)。
- 補充手段(対象外のみ): `fill_missing.py`(AI生成) / 同カテゴリの対象外画像の複製。著作権を含み得る取得スクリプトは削除済み。
- 本番/公開・商用で実写にする場合は Unsplash/Pexels(商用可・帰属不要) か自社素材へ差し替え。

## 第2段階（サーバー実装: 完了）

**正本は [server-design.md](server-design.md)**（API 契約・DB・認証・フェーズ・実装状況の詳細）。要点:

- **モジュール構成**: `composeApp`(アプリ) / **`:shared`**(モデル・Totals・SearchQuery・AppLanguage・DTO の契約) / **`:server`**(Ktor サーバー) の3モジュール。モデルは `:shared` で共有。
- **サーバー**: Ktor 3 (Netty) + PostgreSQL 16 (Exposed + Flyway) + JWT/bcrypt。カタログ read API、ユーザー単位の cart/wishlist/orders/account、注文確定の金額はサーバーが権威計算。カタログはサーバー起動時にシード（`server/.../seed/CatalogSeed.kt` = 旧 `MockCatalog` の複製）。
- **画像**: サーバーが `/images` で静的配信（python 配信は廃止）。`imageUrls` は相対パス、クライアントが接続先 URL で解決。
- **クライアント**: `data/remote`(ApiClient/TokenStore/serverBaseUrl) + `Remote*Repository`（Ktor client で API 呼び出し、StateFlow キャッシュ）。`MockCatalog`/`InMemory*`/`ImageBase` は削除。認証は実認証に置換（「任意情報で成功」は廃止）。トークンは `multiplatform-settings` で永続化し起動時 `GET /me` でセッション復元、401 失効で自動ログアウト。ゲストカートはログイン時 `/cart/merge` で統合。エラーは `AppMessages` トースト + 共通 `ErrorState` 再試行。Search/Catalog は無限スクロール(pageSize 12)。
- **接続先ポート**: 既定 8090（8080 回避）。ハードコードせず `gradle.properties`(`sutec.server.*`)/`-P`/環境変数 `SUTEC_SERVER_*` で設定、サーバーは `PORT` env。
- **起動**: DB は Apple Container（`./scripts/dev-server.sh`、Docker デーモン不要）または Docker Compose。サーバーは `./gradlew :server:run`。
- **自動テスト**: `OrderTotalsTest`(単体・DB不要) + `ApiIntegrationTest`(実 PostgreSQL に対し `/api/v1` を通し検証、11件)。DB は Testcontainers(Docker) / `TEST_DATABASE_URL`(外部DB) / 無ければスキップ の3モード。`./gradlew :server:test`。
- **検証済み**: 上記自動テスト全PASS（Apple Container の Postgres で実走）。加えて Android エミュレータ + iOS シミュレータで実サーバー接続・カタログ/画像描画を確認。詳細は server-design.md §11.5。

## 未確定 / 将来

- 実決済連携、画像のオブジェクトストレージ/CDN 配信、オフライン同梱切替。
</content>
</invoke>
