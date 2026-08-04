# sut-ec-mobile テスト文書レビュー記録

## 0. レビュー概要

| 項目 | 内容 |
|---|---|
| 対象文書 | [テスト計画書](test-plan.md) / [テスト観点](test-viewpoints.md) / [テストシナリオ一覧](test-scenarios.md) / [テスト手順書](test-procedures.md) |
| レビュー観点 | 網羅性 / 矛盾 / リスク考慮 |
| 基準(正本) | [詳細設計 design.md](../design.md) / [概要設計 overview-design.md](../overview-design.md) |
| レビュー実施日 | 2026-07-19 |
| レビュアー | Claude Code(メインセッション) |
| レビュー方法 | 4文書と設計正本の突合。実装挙動に依拠する主張は該当コードで裏取り。 |

> 本レビューは第1段階（モック）のテスト文書を対象とする。第2段階（サーバー実装）でのテスト条件・期待結果の差分は [テスト計画書 §0.1](test-plan.md#01-第2段階サーバー実装でのテストへの影響) にまとめた（本記録の指摘とは別管理）。
| 指摘件数 | 12件(矛盾5 / 網羅性5 / リスク2) ※C5 は追随レビューで追加 |

---

## 1. 指摘一覧

区分: **矛盾** / **網羅** / **リスク**。重大度は「テスト活動・判定への影響」で付与(高/中/低)。状態は**全件反映済み**(2026-07-19、下記 §5 対応記録参照)。

| ID | 区分 | 対象文書・箇所 | 重大度 | 指摘内容 | 推奨対応 | 状態 |
|---|---|---|---|---|---|---|
| C1 | 矛盾 | scenarios [L208](test-scenarios.md#L208) | 高 | 実施記録テンプレートが「SC-01〜**SC-125**」のみ列挙指示。§14 の SC-130〜164(★含む強化異常系すべて)が記録対象から抜ける。計画書が「最優先・重点」とした範囲が成果物に載らない自己矛盾。 | 列挙範囲を「SC-01〜SC-164」に修正。 | 反映済み |
| C2 | 矛盾 | plan [L128](test-plan.md#L128) × procedures TC-151/152 | 高 | 終了基準「高100%消化かつ全合格」と、優先度高の ★TC-151/152 が両立しない。★は期待を「あるべき挙動」に置くが実装はサイレント失敗=Fail確定(下記 F1)。このままでは終了基準を満たせない。 | 既知不具合の waive 条件/例外扱いを終了基準に明記。または★を「仕様確認・起票前提」ケースとして終了判定から分離。 | 反映済み |
| C3 | 矛盾 | procedures [TC-130 L335](test-procedures.md#L335) × design | 中 | ログイン空欄挙動が三者不一致。正本 design「任意情報で成功」・アプリUI文言「任意の情報でログインできます」・実装「isBlank で失敗」。テスト文書は実装挙動(空欄=失敗)を「期待=Pass」に確定させ、仕様との矛盾を Pass で覆い隠している。 | 「空欄失敗は仕様として妥当か」をまず裁定。仕様/UI文言のどちらを直すかを起票事項として扱い、テストが仕様の正誤を独断確定しない。 | 反映済み |
| C4 | 矛盾 | procedures [TC-140 L377](test-procedures.md#L377) | 低 | 「単価の異なる商品で調整」とするのみで、整数円価格でちょうど 2,999/3,000 を作れる具体SKU・数量が未特定。到達不能なら境界2,999は実施不能(V1と連動)。 | 2,999/3,000 に到達する商品ID・数量の組合せを手順に明記。 | 反映済み |
| C5 | 矛盾 | plan §3.3/§5.1/§7・procedures 前提/TC-160・viewpoints §7(E)・scenarios SC-160・overview-design §1.3/§7 | 高 | 画像配信を「**外部CDN/インターネット必須/機内モードで失敗注入**」と記述。実際は**ローカル `python http.server` :8000**(Android=10.0.2.2 / iOS=127.0.0.1)配信で、正本 design.md(§実装状況「画像サーバー必須」)・実装と一致。TC-160 の機内モード repro は再現不能、開始基準に画像サーバー起動が無い。overview-design §1.3/§7 の外部CDN記述が誤りの発生源(正本 design.md と矛盾)。※初回レビューが見落とし、§3 で「画像CDN依存の前提整理が正確」と誤認していた。 | CDN/インターネット前提を**ローカル画像サーバー前提に訂正**。TC-160 を「サーバー停止で注入(機内モードでは再現不可)」に変更。開始基準に「画像サーバー起動」を追加。overview-design の外部CDN記述も正本に合わせ訂正。 | 反映済み |
| V1 | 網羅 | procedures [シードデータ基準 L12-19](test-procedures.md#L12-L19) | 中 | 基準値表が前提SKUを特定していないため実施/判定不能になり得るTCがある: 在庫切れ商品(TC-37)/複数画像商品(TC-31)/レビュー0件商品(TC-35)/2,999・3,000 到達組合せ(TC-140)。 | 各前提に該当する具体商品IDを基準値表に追記して確定。 | 反映済み |
| V2 | 網羅 | viewpoints [L159](test-viewpoints.md#L159) / design §5.1 | 低 | 「注文スナップショット不変」が観点・設計にあるが SC/TC に未落とし込み。 | 「確定→同一商品を再カート操作→注文詳細が不変」を1ケース追加。 | 反映済み |
| V3 | 網羅 | procedures TC-30 / TC-32 | 低 | タグ表示が BESTSELLER/Prime のみ。SALE・NEW・LOW_STOCK の表示、割引率(%)算出値の表示(design §5.1)まで踏み込まず。 | 残りタグと割引率数値の確認を追加。 | 反映済み |
| V4 | 網羅 | procedures [TC-10 L68](test-procedures.md#L68) | 低 | キャンペーンバナーのタップ挙動(遷移有無)未検証。表示のみ確認。 | リンクなら遷移TCを追加、装飾なら「装飾」と明記。 | 反映済み |
| V5 | 網羅 | procedures [TC-52 L188](test-procedures.md#L188) | 低 | tax=0(税行の表示/¥0)を明示確認するTCが無い。「カートと一致」止まり。 | 税=¥0 表示の確認観点を1行追加。 | 反映済み |
| R1 | リスク | plan [§7 L154-162](test-plan.md#L154) | 中 | 破壊的テストの順序・復元リスクが未管理。TC-102/112(削除)・TC-145/146(全削除)・TC-151/152(選択中削除)はシードを破壊し、非永続ゆえ復元は再起動のみ。破壊的TC後に住所/支払い前提の後続TC(TC-50/103/113等)を回す際の初期化ガードが手順に無い。 | 実施順序を規定、または各破壊的TC後に「再起動して初期化」する復元手順を明記。 | 反映済み |
| R2 | リスク | viewpoints §7(D) / procedures TC-151/152 | 中 | ★の根本原因(選択IDの再検証欠如)は「管理から削除」経路以外にも、同一 CheckoutViewModel 保持中に一覧が変化する全経路(デフォルト削除・全削除・別タブ経由編集後に戻る等)で同型に再現。TCは削除経路のみ。 | 観点に「VM保持中に住所/支払い一覧が変化する任意経路」を追加し、代表1〜2経路をTC化。 | 反映済み |

---

## 2. コードによる裏取り(確認済み事実)

> 本節は第1段階(モック)レビュー時点の記録。参照先(`InMemoryAuthRepository.kt`/`ImageBase*.kt`/`MockCatalog.kt`)は第2段階で削除済みのため下記リンクは無効。**現行実装の裏取りは §7 を参照**。

テスト文書が実装挙動に依拠している主張を該当コードで確認。いずれも**主張は(当時)正確**。

| ID | 主張(テスト文書) | 確認結果 | 根拠 |
|---|---|---|---|
| F1 | ★選択中の住所/支払い削除→確定ボタンが活性のままサイレント失敗し得る(SC-151/152) | **実在・確定的に再現**。選択IDを保持し再検証しない→ボタンは `!= null` のみで活性→placeOrder は該当なしで `?: return` 終了。 | [CheckoutViewModel.kt:60](../../composeApp/src/commonMain/kotlin/com/sutec/mobile/feature/checkout/CheckoutViewModel.kt#L60), [CheckoutScreen.kt:77-79](../../composeApp/src/commonMain/kotlin/com/sutec/mobile/feature/checkout/CheckoutScreen.kt#L77-L79), [CheckoutViewModel.kt:84](../../composeApp/src/commonMain/kotlin/com/sutec/mobile/feature/checkout/CheckoutViewModel.kt#L84) |
| F2 | ログイン/サインアップは空・空白で失敗(isBlank) | **実在**。login/signup とも isBlank で failure。 | [InMemoryAuthRepository.kt:19,29](../../composeApp/src/commonMain/kotlin/com/sutec/mobile/data/repository/impl/InMemoryAuthRepository.kt#L19) |
| F3 | 送料は小計3,000以上で無料/未満500/空0 | **一致**。 | [Totals.kt:13-17](../../composeApp/src/commonMain/kotlin/com/sutec/mobile/data/repository/Totals.kt#L13-L17) |
| F4 | 商品画像は外部CDNでなくローカル `python http.server` :8000 から配信(C5) | **確認済**。imageBaseUrl は Android=`10.0.2.2:8000` / iOS=`127.0.0.1:8000`。design.md 実装状況「画像サーバー必須」と一致し、overview-design の「外部CDN」は誤り。 | [ImageBase.android.kt:4](../../composeApp/src/androidMain/kotlin/com/sutec/mobile/data/mock/ImageBase.android.kt#L4), [ImageBase.ios.kt:4](../../composeApp/src/iosMain/kotlin/com/sutec/mobile/data/mock/ImageBase.ios.kt#L4), [MockCatalog.kt:20-21](../../composeApp/src/commonMain/kotlin/com/sutec/mobile/data/mock/MockCatalog.kt#L20-L21) |

> 注: F1 は R2 のとおり「管理から削除」以外の経路でも同型に再現する。テストは削除経路のみを対象化している。

---

## 3. 良い点(維持)

- 観点 → シナリオ(SC) → 手順(TC) の **1:1 トレーサビリティ**が全域で成立している。
- 優先度/重大度の定義、開始・終了基準が明文化されている。
- **★潜在リスクの着眼が的確**(コードと一致、F1)。異常系・境界・例外を独立セクションで強化している。
- iOS `Info.plist` 罠・非永続の前提整理が正確で、リスク表に対応方針まで記載。(※画像配信の前提は当初 CDN と誤認。C5 で訂正済み)

---

## 4. 推奨対応順序

1. **C1・C2**(実施記録の列挙範囲 / 終了基準の★扱い)— 判定破綻の回避。
2. **V1・C4**(シードSKUの確定)— 実施不能TCの解消。
3. **C3**(空欄ログインの仕様裁定を起票化)— テストが仕様矛盾を隠さないように。
4. **R1**(破壊的TCの順序・復元ガード)。
5. 残り(V2〜V5・R2)は網羅性の底上げとして順次。

> 本記録はレビュー時点のもの。対応時は各行の「状態」を更新し、実装不具合(F1等)は不具合一覧へ別途起票する。

---

## 5. 対応記録(2026-07-19 反映)

| ID | 反映先 | 対応要点 |
|---|---|---|
| C1 | scenarios 消化状況記録 | 列挙範囲を「SC-01〜SC-164」に修正(§14 の★含む強化異常系を記録対象に含めた)。 |
| C2 | [plan §5.2](test-plan.md#52-終了基準exit-criteria) | ★(TC-151/152/158)を「分離(消化率・合格率に非算入)」または「waive 合意・例外明記」で扱う旨を終了基準に追記。 |
| C3 | procedures TC-130 / viewpoints §7(A) | 空欄ログインの実挙動再現に留め、design/UI 文言/実装の三者不一致は仕様確認事項として起票扱いに変更(テストで仕様を独断確定しない)。 |
| C4 | procedures TC-140 | シード価格が10円単位のため 2,999/3,001 到達不能である旨を明記し、到達可能な代表(¥2,980 / ¥3,000)と具体 SKU・数量を明記。 |
| V1 | procedures シードデータ基準 | 複数画像(electronics_1)・レビュー0件(fashion_4)・送料境界組合せ(TC-140)の SKU を確定。在庫切れ商品はシード不在=実施不能を明記(TC-37 にも注記、データ整備を起票)。 |
| V2 | scenarios SC-64 / procedures TC-64 | 「注文スナップショット不変」を1ケース追加(確定→同一商品再カート操作→注文詳細不変)。 |
| V3 | procedures TC-30 / TC-32 | 残りタグ(SALE/NEW/LOW_STOCK)の表示確認と割引率(%)算出値の一致確認を追加。 |
| V4 | procedures TC-10 | キャンペーンバナーは `clickable` 無しの装飾要素であり遷移しないことを確認する旨を明記。 |
| V5 | procedures TC-52 | tax=0(税行は¥0、合計=小計+送料)の確認観点を追加。 |
| R1 | [plan §7](test-plan.md#7-リスクと前提) | 破壊的 TC の実施順序規定と、各破壊的 TC 後の再起動復元ガードを追記。 |
| R2 | viewpoints §7(D)+mindmap / scenarios SC-158 / procedures TC-158 | 「VM 保持中に一覧が変化する任意経路(デフォルト変更・編集後戻る等)」を観点化し、代表経路を TC 化。 |
| C5 | plan §3.3/§5.1/§7・procedures 前提/TC-160・viewpoints §7(E)・scenarios SC-160・overview-design §1.3/§7 | 画像配信の前提を「ローカル画像サーバー(:8000、Android=10.0.2.2 / iOS=127.0.0.1)」に統一訂正。TC-160 を「サーバー停止で注入(機内モードでは再現不可)」に変更。plan 開始基準に画像サーバー起動を追加。overview-design の外部CDN記述も正本 design.md に合わせ訂正。追随レビュー(2026-07-19)で追加。 |

> F1(選択中削除のサイレント失敗)は**実装不具合**であり本対応では起票のみ。修正は別タスク。★ケースの合否は §5.2 の例外扱いに従う。

---

## 6. 第2段階(サーバー実装完了)追随レビュー(2026-07-19)

第2段階の実装完了を受け、§0.1 差分表・4文書のバナーが現行実装と一致するか再点検した。対象は本記録冒頭と同じ4文書+本記録自身。コードでの裏取りは §7 参照。

| ID | 区分 | 対象 | 重大度 | 指摘内容 | 対応 | 状態 |
|---|---|---|---|---|---|---|
| S1 | 矛盾 | plan §0.1 自動テスト件数 | 低 | `ApiIntegrationTest` の件数を「計11件」としていたが、現行コードは `@Test` 12件(`cart_merge_sums_quantities` 含む)。 | 「計12件」に修正し、カートマージのカバレッジを明記。 | 反映済み |
| S2 | 網羅 | plan §2.2 対象外 | 中 | 「ダークテーマ」「サーバーAPI連携」「データ永続化」を対象外としたままだが、第2段階でいずれも実装済み・対象内。特にダークテーマは対象外のまま観点が一切無かった。 | §2.2 に第2段階差分の注記を追加し、ダークテーマ等の観点を viewpoints §8 に新設。 | 反映済み |
| S3 | 矛盾 | plan §7・procedures TC-164・scenarios SC-124/164・viewpoints (E) | 高 | 「アプリ再起動でデータが初期化される」という第1段階前提が第2段階では**反転**(PostgreSQL永続+トークン永続化で再起動してもログイン状態・データが保持される)。旧文言のまま実施すると期待結果が逆になり誤判定を招く。破壊的TCの復元ガード(「再起動でシードへ復元」)も第2段階では機能しない。 | plan §7 のリスク行・復元ガード手順を第2段階版に置換(専用テストアカウント運用+DBコンテナ再作成による全体リセット手順を明記)。procedures TC-164・scenarios SC-124/164・viewpoints (E) に期待結果反転の注記を追加。 | 反映済み |
| S4 | 矛盾 | procedures TC-160・scenarios SC-160・viewpoints (E) | 中 | 画像取得失敗の注入法「画像専用サーバー:8000を停止」は第2段階で無効。画像もカタログも同一 `:server` から配信されるため、サーバー停止は画像以外の機能も同時に失敗させ、TCの意図(画像以外は継続動作)を検証できない。 | `IMAGES_DIR` に存在しないパスを指定して `:server` を起動する方法(画像のみ404、他APIは正常)に置換。`:server` 全停止のケースは新設のロード失敗+ErrorState/再試行観点に読み替え。 | 反映済み |
| S5 | 網羅 | viewpoints | 中 | 第2段階で新規実装されたクライアント機能(トークン永続化・401自動ログアウト・ゲストカート統合・ロード失敗のErrorState+再試行・無限スクロール・ダークテーマ)とサーバーハードニング(JWT_SECRET fail-fast・CORS許可制・認証レート制限)の観点が文書群のどこにも無かった。 | viewpoints に新設(§8 テキスト版+マインドマップに「第2段階追加機能」ブランチ)。 | 反映済み |
| S6 | 網羅 | plan §0.1 前提環境 | 低 | 「python画像サーバー:8000→:server」の記述はあるが、画像配信が `:server` の `/images` に統合された旨(python画像サーバーの完全廃止)が明示されていなかった。 | §0.1 前提環境行に「画像も `:server` の `/images` 配信に統合(python画像サーバー:8000は廃止)」を明記。 | 反映済み |

### 7. コードによる裏取り(第2段階再確認)

| 主張 | 確認結果 | 根拠 |
|---|---|---|
| 既定ポートは 8090 | **確認済**。`PORT` 環境変数未設定時のデフォルト。 | [Application.kt:10](../../server/src/main/kotlin/com/sutec/mobile/server/Application.kt#L10) |
| 画像は `:server` の `/images` から配信(python:8000は廃止) | **確認済**。`IMAGES_DIR` が有効なディレクトリの場合のみ `/images` に `staticFiles` 登録。 | [Routing.kt:22-27](../../server/src/main/kotlin/com/sutec/mobile/server/Routing.kt#L22-L27) |
| 認証は実認証(重複=409/誤PW=401/空欄=400) | **確認済**(統合テスト `signup_login_and_errors` で検証)。 | [ApiIntegrationTest.kt:153](../../server/src/test/kotlin/com/sutec/mobile/server/ApiIntegrationTest.kt#L153) |
| `ApiIntegrationTest` は12件 | **確認済**。`@Test` 12個(health_ok/categories_seeded/featured_returns_twelve/product_detail_and_404/search_filters_and_paginates/reviews_related_byIds/cart_requires_auth/signup_login_and_errors/cart_and_place_order/empty_cart_order_is_rejected/cart_merge_sums_quantities/wishlist_add_list_remove)。 | [ApiIntegrationTest.kt](../../server/src/test/kotlin/com/sutec/mobile/server/ApiIntegrationTest.kt) |
| トークン永続化・401自動ログアウト・ゲストカート統合・ErrorState+再試行・無限スクロール(pageSize12)・ダークテーマ・JWT_SECRET fail-fast・CORS許可制・認証レート制限(既定60) | **すべて確認済**(実装済み)。 | `TokenStore.kt` / `ApiClient.kt:40-51` / `RemoteCartRepository.kt:45-67`+`UserDataRoutes.kt:28` / `StateViews.kt:27-38` / `CatalogViewModel.kt:107`+`SearchViewModel.kt:135` / `Theme.kt:11-16` / `Application.kt:27-35` / `Cors.kt:9-20` / `RateLimit.kt:9-20` |

> 本追随レビューは §0.1 差分表・4文書のバナーの正確性を再点検するもので、§1〜5(第1段階時点の指摘)とは独立管理。


</content>
</invoke>
