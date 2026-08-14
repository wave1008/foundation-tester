# FT E2E アプリ UI 契約

このファイルが **testTag(=`#id`)と表示ラベルの唯一の正**。アプリ実装(`E2EAppCMP/composeApp`)と
シナリオ(`TestProjects/E2E-CMP/scenarios`)の両方がここを参照する。**片方だけ変えない**。
tag 定数は `composeApp/src/commonMain/kotlin/com/ftester/e2e/Tags.kt` に集約する(値はこの表と byte 一致)。

## 全体規約

- 全ての操作対象・検証対象に `Modifier.testTag(...)` を付ける。Android はルートで
  `exposeTestTagsAsResourceId()`(`semantics { testTagsAsResourceId = true }`)、iOS は testTag が
  自動で accessibilityIdentifier になる → `#id` が両 OS 共通で引ける。
  **罠**: ダイアログ(`AlertDialog` 等)は**別ウィンドウ**に描画されるためルートの
  `exposeTestTagsAsResourceId()` が届かない。ダイアログにも `modifier = Modifier.exposeTestTagsAsResourceId()`
  を**必ず再適用する**。忘れると Android だけダイアログ内の `#id` が全滅する(ラベルは引ける)。
- **型名は先頭小文字**(`.button` / `.staticText`)。ホスト側で正規化しており、スナップショット表示・
  セレクタ記法・生成コードで綴りが一致する(先頭大文字で書くと構文エラー)。
- **OS を跨いで保証される型は `button` / `staticText` / `switch` の3つ**
  (2026-07-26 のブリッジ役割正規化以降。それ以前は Compose の Button が Android で `cell` になり
  `ios {}` / `android {}` の分岐が必要だった)。この3つは型セレクタを OS 共通で書ける。
  **入力欄の型は OS 共通ではない**(2026-08-06 に実測して表を訂正した。Compose の制約であって
  ftester の穴ではない):

  | | `#field_single` | `#field_password` | `#field_multiline` |
  |---|---|---|---|
  | Android | `textField` | `secureTextField` | `textField` |
  | iOS(in-app / xcuitest とも) | `textView` | `textView` | `textView` |

  iOS では Compose の入力欄が UIKit の `UITextField` ではなく合成 AX 要素なので、
  XCUITest の `elementType` が `textView` になり、in-app ブリッジもそこへ揃えてある
  (`InAppSnapshot.elementType` のテキスト入力 trait 判定)。**マスクの有無は iOS では型に出ない**。
  よって**入力欄は `#id` で指す**。`.textField` / `.secureTextField` が使えるのは Android だけ。
  以前は in-app だけ `other` を返していて、探索(MCP)と実行で型が食い違っていた。
  **iOS の3エンジン間でも揃っている**: in-app は traits の `.toggleButton`(実測 0x20000000000001 =
  `.button` と併用。UIKit/SwiftUI/Compose 共通)で `switch` を出す。ここが抜けると in-app だけ
  `switch` が `button` になり、`:rightSwitch` が xcuitest とだけ食い違う(2026-07-27 に実害)。
- **WebView 画面だけは別規約**(`link` / `webView` 型が出る)。§WebView 画面を参照。
  **`#id` は 2026-08-14 に扱えるようにした**(旧規約「WebView 内の `#id` は使えない」は撤回)。
  供給源は**経路で違う**: DOM 経路は `el.id`(版に依存しない)/ a11y 経路は
  `viewIdResourceName`(**WebView 150 以降だけ**。124 は出さない)。
  **自動生成の id に頼らない** —— 実 web ページには `#mwHw` のように**ページを編集すると変わる**
  id があり(Wikipedia の parsoid で実測)、`#id` が在ることは安定していることを意味しない。
- **`checkBox` / `slider` / リスト行は型で指さない**。iOS 側の a11y が役割を出さず
  (Compose の Checkbox/Radio は iOS で `button`、Slider は `other`)、ブリッジでも揃えられない。
  これらは `#id` で指す。`#id` とラベルは全プラットフォーム共通。
- **ラベルはハードコード**(文字列リソース/ロケール依存にしない)。端末ロケールが ja/en どちらでも
  同じ文字列が出る = フリートのロケール差でシナリオが壊れない。
- **入力する値は ASCII のみ**(IME を介さない `type` の対象にするため)。
- **ラベルの部分一致衝突を意図的に1組だけ作る**(`許可` ⊂ `通知を許可`)。それ以外は衝突させない。
  素の文字列は完全一致なので衝突しないが、`*許可*` と書いたときの挙動(シナリオ 03)の検証材料。
  素の `許可` が `通知を許可` に当たらないことの検証材料でもある。
  リスト行は `行 01`〜`行 40` とゼロ詰め(`*行 1*` が `行 12` に contains 一致する事故を避ける)。
- **状態表示は必ず `key=value` 形式の Text にする**(`textIs` で完全一致検証できる)。
  Switch/Checkbox の AX value は OS で表現が違うため、値検証は原則この echo Text で行う
  (`valueIs` の OS 依存挙動は `ios {}` / `android {}` 節でのみ確認する)。
  **`checkIsON` / `checkIsOFF`(と セレクタの `checked=`)は iOS 側が UI 実装依存**
  (2026-07-26 の 4 SUT 実測。Android は 4 SUT とも取れる): Compose は selected trait を出すので
  iOS でも取れるが、**SwiftUI/UIKit と Flutter の checkbox は出さない**。
  だから**この契約では状態の正は echo Text**(`agree=<true|false>` 等)であり、
  チェック状態を跨 SUT で検証するシナリオは echo Text を見る。
- **プロセス起動時は必ずホームタブのルートに戻る**(画面遷移状態を永続化しない)。
  `launchApp` はアプリのデータを消さないため、ナビ状態のリセットはアプリ側の責務
  (docs/design.md §10 の知見)。永続化するのは下表の「永続」印の付いた値だけ。
- **Compose iOS の制約**: Scaffold 等コンテナの testTag は iOS AX ツリーに現れない
  → 着地判定は必ず leaf(Text/Button)で行う。高密度スクロール画面は frame がクランプされ
  tap が外れるため、リスト行の高さは 56dp 以上を確保する。

## シェル(全画面共通)

| tag | 種別 | ラベル/テキスト | 備考 |
|---|---|---|---|
| `#txt_screen_title` | Text | 各画面のタイトル文字列 | 着地判定の基準 |
| `#btn_back` | Button | `戻る` | ルート以外で表示 |
| `#tab_home` | Button | `ホーム` | 下部タブ |
| `#tab_controls` | Button | `コントロール` | 下部タブ |
| `#tab_about` | Button | `情報` | 下部タブ |

タブ切替は各タブのルートへ着地する(スタックを持ち越さない)。

## 画面回転(全 SUT 共通契約)

**5 SUT すべてが縦・横の両方を許可し、回転しても今いる画面を保つ**(2026-08-11)。
`rotateTo(.landscape)` / `rotateTo(.portrait)` のシナリオを 5 SUT で同じ形に書くための前提。

- **横向きの許可**: iOS は `Info.plist` の `UISupportedInterfaceOrientations` に
  Portrait / LandscapeLeft / LandscapeRight。宣言していない向きへは**何をしても回らない**
  (ftester は 422 で落ちる = 不具合ではない)
- **画面の保持**: 回転を跨いで同じ画面に居続ける。**Android は Activity が作り直される**ので
  構成変更専用の引き継ぎが要る(E2EAppAndroid/docs/ui-contract.md)。Compose / Flutter / RN は
  フレームワーク側が保つ
- **横向きで見えなくなる要素がある**: `#txt_screen_title` は SwiftUI SUT の一部画面で画面外へ出る
  (実測)。回転のシナリオで着地判定に使うなら、その画面の**本体の要素**(例: テキスト入力画面の
  `#field_single`)を見ること
- 回した向きは**シナリオ終了時に自動で戻る**(Android は自動回転の設定も)。MCP の `ft_rotate` は
  戻さないので、探索の後は自分で戻す

## ディープリンク(全 SUT 共通契約・SUT ごとに固有の URL スキーム)

**URL スキームは SUT ごとに固有のものを登録する**(iOS = `Info.plist` の `CFBundleURLTypes`、
Android = `<intent-filter>` に `VIEW` + `DEFAULT` + `BROWSABLE` と `<data android:scheme="…"/>`)。
**理由(実測)**: iOS は同一のカスタムスキームを複数アプリが登録していても解決先を1つしか選ばず、
どれに届くかが端末ごとに揺れる。E2E のシミュレータには iOS の SUT が4つ同居するため、共通スキーム
`fte2e` では 2026-08-09 の E2E で CMP 宛の `openURL` が別アプリへ解決される事故が起きた。
Android は intent に package を明示するので影響しないが、**契約は全 SUT 共通なので iOS に合わせて
固有化する**。**Universal Links / App Links(`https://`)は使わない** —— AASA / assetlinks.json の
取得状態に左右され、シミュレータでは Safari へ流れることがある。カスタムスキームはデバイスの状態に
依存しない。

| SUT | アプリID | URL スキーム |
|---|---|---|
| `E2EAppCMP` | `com.ftester.e2e` | `fte2ecmp` |
| `E2EAppIOS` | `com.ftester.e2e.ios` | `fte2eios` |
| `E2EAppAndroid` | `com.ftester.e2e.android` | `fte2eandroid` |
| `E2EAppFlutter` | `com.ftester.e2e.flutter` | `fte2eflutter` |
| `E2EAppRN` | `com.ftester.e2e.rn` | `fte2ern` |

パス部分は全 SUT 共通(以下は `E2EAppCMP` の `fte2ecmp` を例に示す。他 SUT は自分のスキームへ読み替える):

| URL | 着地する画面 | 備考 |
|---|---|---|
| `fte2ecmp://screen/selector` | セレクタ画面 | ホームタブのスタックに積む(`#btn_back` でホームへ戻る) |
| `fte2ecmp://screen/lifecycle` | ライフサイクル画面 | 同上 |
| 上記に `?` 以降が付いた URL | 同じ画面 | クエリは解釈しない。URL 全体を `#txt_last_deeplink` に出す |
| 上記以外の `fte2ecmp://…` | **遷移しない**(今の画面のまま) | 受け取ったことは `#txt_last_deeplink` に出る |

- **受け取った URL は必ず `#txt_last_deeplink`(ライフサイクル画面)に丸ごと出す**。着地画面だけを
  見ると「URL が届いたのか、たまたま同じ画面だったのか」を区別できない。
- **起動時リセットの後に適用する**: プロセス起動では必ずホームタブのルートに戻り(§全体規約)、
  ディープリンクの遷移はその後に積む。`launchApp(url:)` は再起動 → URL 配送の順で 1 ステップ。
- **未知の URL でクラッシュしない・画面を変えない**。`openURL` が「届いたが遷移は起きない」ことを
  検証できる唯一の材料。
- 検証に使う URL には `&` を含める(例 `fte2ecmp://screen/lifecycle?tag=a&n=1`)。Android は
  `adb shell` を経由するので**クォートが落ちると `&` でコマンドが切れる**。この URL がその回帰を落とす。
- **CMP 実装メモ**: Android は `MainActivity` を `launchMode="singleTop"` にし `onNewIntent` で受ける
  (`singleTask` はタスクを畳み既存シナリオの launch 挙動に影響し得るため不採用)。iOS は SwiftUI の
  `.onOpenURL`(launch 時・起動済み着信の両方を1箇所でカバーする)。受け取った URL は
  commonMain の `DeepLinkRouter`(object)へ集約し、Compose 側の `LaunchedEffect` が消費してナビゲーションへ反映する。

## ホームタブ / ルート(タイトル `ホーム`)

| tag | 種別 | ラベル/テキスト | 備考 |
|---|---|---|---|
| `#txt_home_marker` | Text | `E2E ホーム` | ホーム着地の判定 |
| `#nav_selector` | Button | `セレクタ` | |
| `#nav_noid` | Button | `ID なし` | **上から3行目までに置く**(末尾だと下部タブに重なり、タップがタブに吸われる。iOS ネイティブ SUT で実測)。SUT ごとの実際の並びは2番目(Android/Flutter)と3番目(CMP/iOS)に割れているが、**制約は「末尾側に置かない」であって位置そのものではない**(2026-08-06 に実測して表記を訂正) |
| `#nav_input` | Button | `テキスト入力` | |
| `#nav_webview` | Button | `WebView` | **末尾に置かない**(`#nav_noid` と同じ理由でタップがタブに吸われる) |
| `#nav_gesture` | Button | `ジェスチャ` | |
| `#nav_scroll` | Button | `スクロール` | |
| `#nav_async` | Button | `非同期表示` | |
| `#nav_dialog` | Button | `ダイアログ` | |
| `#nav_lifecycle` | Button | `ライフサイクル` | |
| `#nav_heal` | Button | `自己修復` | |
| `#nav_diagnostics` | Button | `診断` | |

ナビ行は縦に並べる。11 行 + マーカーが 1 画面に収まらない場合はスクロール可にする
(`#nav_diagnostics` は `scrollTo` の対象になり得る)。

**ここに行を増やさない**(2026-08-04 に実際に踏んだ): 1行足すだけで末尾側が下部タブに重なり、
**素の `tap` がタブに吸われて別画面へ遷移したまま成功として記録される**。
スクロールを伴う `tapWithScrollDown` へ替えても、SwiftUI の SUT では**探索スワイプ自体が
ボタンを発火**して同じ事故になった。新しい画面は**関連画面から開く**こと
(マップ画面はジェスチャ画面の右下ボタンから開く)。

**E2E-iOS だけは、この事故が起きたままの状態を意図して残してある**(2026-08-06)。
あの SUT のホームは 11 行が収まらず、`#nav_heal` (16,788 370x62) が**下部タブの下に着地**し、
`#nav_diagnostics` は画面外に出る。ここは**直さない** —— ツール側の
「上に描かれた要素に覆われている」警告(`RefGuard.overlayCovering`)の**唯一の生きた witness**で、
飛び越し画面と同じ役割を持つ。安全なのは、この2つを触るシナリオが `_disabled/` にしか無いため
(CMP の `23_飛び越し.swift` は `#nav_diagnostics` を叩くが、CMP のホームは全行が収まる)。
**他の SUT でこの形を作らない**(witness は1つで足りる)。

## セレクタ画面(タイトル `セレクタ`)

`tap` のセレクタ記法(`#id` / ラベル / `*部分一致*` / `.型[n]` / `.型#id` / `&&` 合成 / `||`)を
網羅する。

| tag | 種別 | ラベル/テキスト | タップ時の結果 |
|---|---|---|---|
| `#txt_selector_result` | Text | `result=<v>` 初期 `result=-` | |
| `#btn_allow` | Button | `許可` | `result=allow` |
| `#btn_allow_notification` | Button | `通知を許可` | `result=allow_notification` |
| `#btn_item_1` | Button | `項目` | `result=item1` |
| `#btn_item_2` | Button | `項目` | `result=item2` |
| `#btn_item_3` | Button | `項目` | `result=item3` |
| `#txt_shared_label` | Text | `共通ラベル` | (タップ不可) |
| `#btn_shared_label` | Button | `共通ラベル` | `result=shared` |
| `#btn_alias_new` | Button | `別名ボタン` | `result=alias` |
| `#btn_selector_reset` | Button | `結果クリア` | `result=-` |
| `#txt_offscreen` | Text | `画面外テキスト` | 画面外(要 `scrollTo`) |

- `#btn_item_1..3` は**同一ラベル `項目` の3連**。ラベル指定は曖昧解決不能になり、
  `.型[n]` か `#id` でしか引けない(= 序数セレクタの検証材料)。
  **序数はこの画面の見えている Button 全体のツリー順**: 戻る(1) 許可(2) 通知を許可(3)
  項目(4,5,6) 共通ラベル(7) 別名(8) 結果クリア(9) タブ(10-12)。この並びを変えるとシナリオ 04 が壊れる。
- `#btn_alias_new` は `#btn_alias_old||#btn_alias_new` のフォールバック連鎖検証に使う
  (`btn_alias_old` は**存在しない**)。
- `#txt_offscreen` は `#btn_selector_reset` の下に十分な余白(600dp 以上)を挟んで配置する。

## テキスト入力画面(タイトル `テキスト入力`)

| tag | 種別 | ラベル/テキスト | 備考 |
|---|---|---|---|
| `#field_single` | TextField | placeholder `単一行` | singleLine・**IME アクション = 検索**(発火で `#txt_ime_action` を +1) |
| `#field_password` | TextField | placeholder `パスワード` | PasswordVisualTransformation |
| `#field_multiline` | TextField | placeholder `複数行` | 3行程度 |
| `#txt_echo_single` | Text | `single=<v>` 初期 `single=` | |
| `#txt_echo_password` | Text | `password=<v>` 初期 `password=` | 平文で echo(検証用) |
| `#txt_echo_multiline` | Text | `multiline=<v>` 初期 `multiline=` | 改行は `\n` を空白に置換して1行表示 |
| `#txt_echo_length` | Text | `len=<n>` 初期 `len=0` | `#field_single` の文字数 |
| `#txt_ime_action` | Text | `ime=<n>` 初期 `ime=0` | `#field_single` の IME アクション発火回数 |
| `#btn_input_submit` | Button | `送信` | `#txt_input_submitted` を更新 |
| `#txt_input_submitted` | Text | `submitted=<v>` 初期 `submitted=-` | |
| `#btn_input_clear` | Button | `入力クリア` | 3フィールドと echo を初期状態へ(`ime=0` を含む) |

**IME アクション(`#field_single`)**: Enter / 送信キーで発火し `#txt_ime_action` が +1 される
(シナリオ 18 が `pressEnter()` と `type("…\n")` の両方で検証する)。

- **改行は本文に入らない**: 発火しても `#txt_echo_single` / `#txt_echo_length` は変わらない
  (singleLine のフィールドとして全 SUT 共通。`len` が増えたら改行が文字として入っている = バグ)
- **発火後のフォーカス・キーボードの状態は SUT ごとに異なる**(UIKit は resignFirstResponder、
  Compose/Flutter は保持)。**シナリオは発火後に必ず tap し直してから次の入力をする**
- **Android の発火経路は2つある**。ftester は a11y の `ACTION_IME_ENTER`(actionId は
  フィールドの imeOptions = `IME_ACTION_SEARCH`・`KeyEvent` は **null**)を優先し、
  旧ブリッジ・API 30 未満では `keyevent 66`(actionId は **`IME_NULL`**・`KeyEvent` あり)に落ちる。
  **両方の actionId を受理**しないと片方の経路で発火しない(E2EAppAndroid/docs/ui-contract.md)

**配置の制約(すべて実測で確定。崩すと入力シナリオが落ちる)**: この画面のレイアウトは
**ソフトキーボードに支配される**。iPhone 17 Pro(iOS 27.0・高さ 874)でキーボード表示中に
触れるのは概ね `y < 500` = タイトル下から **約 384pt 分だけ**。

1. この画面は**スクロールさせない**(`ScreenColumn(scrollable = false)`)。スクロール可だと
   入力欄フォーカス時に Compose が bringIntoView で列を動かし、次の入力欄がキーボードの下へ
   回り込んで「ロケータを解決できません」になる。
2. **シナリオが触る要素(echo 3本 + submitted + `単一行`/`パスワード` 欄 + 送信/クリア)を
   この 384pt に収める**。`送信`/`入力クリア` は Row に横並びにして高さを節約する。
3. `複数行` 欄とその echo だけは折り返しの下でよい(シナリオが触らない)。
4. キーボードに覆われた要素は `exist`/`textIs` の可視性判定(requireVisible 既定 true)で
   「偽陽性(occlusion)」になり、検証不能になる。

## ジェスチャ画面(タイトル `ジェスチャ`)

画面はスクロールさせない(スワイプ検出と競合するため)。

| tag | 種別 | ラベル/テキスト | 備考 |
|---|---|---|---|
| `#btn_tap_counter` | Button | `タップ` | tap で +1 |
| `#txt_tap_count` | Text | `tap=<n>` 初期 `tap=0` | |
| `#btn_long_press` | Button | `長押し` | 長押しで +1(通常タップでは増えない) |
| `#txt_press_count` | Text | `press=<n>` 初期 `press=0` | |
| `#pad_swipe` | Box | 内部に Text `スワイプ領域` | **コンテンツ領域いっぱい**。他要素はこの上に重ねる |
| `#txt_swipe_dir` | Text | `swipe=<dir>` 初期 `swipe=-` | dir ∈ `up`/`down`/`left`/`right` |
| `#txt_last_gesture` | Text | `last=<g>` 初期 `last=-` | g ∈ `tap`/`longpress`/`swipe` |
| `#btn_gesture_reset` | Button | `ジェスチャクリア` | 全カウンタを初期化 |
| `#nav_map` | Button | `マップ` | **右下**に置く(マップ画面を開く。左下は `#btn_gesture_reset`)|

スワイプ方向は**指の移動方向**で判定する(上へ払う = `up`)。ftester の `swipe(.up)` と一致させる。

**レイアウトの制約(これを崩すと swipe 検証が落ちる)**: ブリッジの `swipe` は**要素を狙わず画面を払う** —
iOS は XCUITest の `XCUIApplication.swipeUp()` 等でアプリ frame 全体を払う(in-app エンジンは座標
スワイプを持たず、動かせるスクロールビューが無ければ 501 で XCUITest へ回る)。
Android(`BridgeRouter.handleSwipe`)は縦 0.3h↔0.7h・横 0.2w↔0.8w(y=0.5h)の固定座標。
よって `#pad_swipe` はコンテンツ領域いっぱいに敷き、操作要素はその**上に重ねる**。
重ねてよいのは Text(ポインタを消費しない)のみ。ボタン類は始点を塞がないよう
**幅 45% 以内(中央列 x=0.5w を空ける)** かつ **上下の端(中央行 y=0.5h を空ける)** に置く。

## マップ画面(タイトル `マップ`)

マップ系アプリの検証材料(**ピンチ・ダブルタップ・斜めドラッグ**)。ジェスチャ画面と分けてあるのは、
あちらの `#pad_swipe` が drag を消費して方向判定する作りで、同じ領域に変形ジェスチャを重ねると
どちらかが空振りするため。この画面はスクロールさせない。

| tag | 種別 | ラベル/テキスト | 備考 |
|---|---|---|---|
| `#pad_map` | Box | 内部に Text `マップ領域` | **コンテンツ領域いっぱい**。ピンチ・ダブルタップ・ドラッグを受ける。他要素はこの上に重ねる |
| `#txt_zoom_dir` | Text | `zoom=<d>` 初期 `zoom=-` | d ∈ `in`/`out`。累積倍率が 1.05 超で `in`・0.95 未満で `out` |
| `#txt_zoom` | Text | `zoom=<n.n>` 初期 `zoom=1.0` | 累積倍率(小数1桁)。**倍率が目減りしていないか**の診断用 |
| `#txt_pan` | Text | `pan=<h>-<v>` 初期 `pan=-` | h ∈ `left`/`right`/`none`・v ∈ `up`/`down`/`none`。**斜めは両方が非 none** |
| `#txt_double_count` | Text | `double=<n>` 初期 `double=0` | ダブルタップで +1。**単タップでは増えない** |
| `#btn_map_reset` | Button | `マップクリア` | 全カウンタ・倍率を初期化 |

判定の規約(全 SUT 共通):
- **パンは指の移動方向**(左上へ払う = `pan=left-up`)。ジェスチャ画面の swipe と同じ向き規約。
  軸ごとに 8dp/px 未満の移動は `none`(手ぶれで斜めと誤判定しないため)
- 倍率・移動量は**累積**(`マップクリア` でのみ戻る)。1操作ごとに戻すと、
  ジェスチャ直後の snapshot が間に合わなかったときに検証が落ちる
- 表示は**読み取り専用の Text**(パッドの上に重ねる)。`#btn_map_reset` は始点を塞がないよう
  ジェスチャ画面と同じ規律(幅 45% 以内・上下の端)に置く

**iOS はエンジンで成否が分かれるジェスチャがある**(2026-08-04 に4 SUT で実測。表と機構は
docs/commands.md)。**既定の hybrid では全て動く**が、`ios-xcuitest` プロファイルでは
`#txt_double_count` が Compose で増えず、`#txt_zoom_dir` が Flutter で動かない
(SUT 側の作りの問題ではないので直そうとしないこと)。E2E のシナリオは**両エンジンで走る**ため、
該当 scene を `android { }` に閉じてある —— iOS 側の担保は届く SUT
(ダブルタップ = E2EAppIOS/E2EAppFlutter、ピンチ = E2EAppIOS/E2EAppCMP)と、
in-app 経路のソース走査テスト(`InAppGestureRoutingTests`)が担う。

## スクロール画面(タイトル `スクロール`)

| tag | 種別 | ラベル/テキスト | 備考 |
|---|---|---|---|
| `#txt_row_selected` | Text | `selected=<v>` 初期 `selected=-` | 固定ヘッダ(スクロールしない) |
| `#btn_scroll_top` | Button | `先頭へ` | 固定ヘッダ |
| `#list_rows` | (容器) | (ラベルなし) | 行を包むスクロール容器。**スコープセレクタ `#list_rows >> …` の対象** |
| `#row_01` … `#row_40` | Button | `行 01` … `行 40` | 高さ 56dp 以上・ゼロ詰め・**`#list_rows` の子孫**。**初期表示で `#row_06` までは完全に見える**こと(下の横カルーセルぶんリストが短い。シナリオの `swipeElementToElement` が依存する)。**CMP はさらに `#row_08` まで完全に見えること** — CMP の S0030 は `#row_06` 起点だとドラッグ距離が足りず `#row_01` が消えない(実測)ため `#row_08` 起点で、この保証に乗っている |

行タップで `selected=row_NN`。`#row_40` は `scrollTo` の到達目標。

**同じ画面に横スクロール領域も置く**(スクロール領域の指定 = `scrollFrame` の検証材料。
縦と横が同居していないと「指定した方だけが動く」ことを確かめられない):

| tag | 種別 | ラベル/テキスト | 備考 |
|---|---|---|---|
| `#txt_tag_selected` | Text | `tag=<v>` 初期 `tag=-` | **`#carousel_tags` の直下**(スクロールしない。全 SUT で並びを揃える — 相対セレクタが SUT で割れないため) |
| `#carousel_tags` | (容器) | (ラベルなし) | **横スクロール**する容器。`#list_rows` と同じくスコープの対象 |
| `#tag_01` … `#tag_20` | Button | `タグ 01` … `タグ 20` | 幅 120dp・高さ 56dp 以上。**`#carousel_tags` の子孫** |

配置は **`#list_rows` の下**(縦リストの高さは残りいっぱい)。**画面中央に置いてはいけない** ——
領域を指定しない従来のスクロール(画面中央基準の全画面スワイプ)がカルーセルに吸われ、
`scrollToTop` 等が端に着く前に「変化なし」で止まる(2026-08-03 実測)。
タグタップで `tag=tag_NN`。**横は1画面に 3〜4 個しか入らない幅**にする —— 全部見えていると
「横スクロールした」ことを不在で検証できない。

**`#list_rows` は「容器を公開する」ことそのものが契約**(スコープセレクタの検証材料)。
子孫が a11y ツリー上で**実際に入れ子になる**形で公開すること — 畳んで葉にしない:
- Compose: `LazyColumn` に `testTag`(iOS/Android とも子が入れ子になる。実測)
- SwiftUI/UIKit: `UITableView` の `accessibilityIdentifier`(セルが子)
- View/XML: `RecyclerView` の `android:id`
- **Flutter: `Semantics(container: true, explicitChildNodes: true)`。`tagged()`(=`MergeSemantics`)で
  包んではいけない** — 畳むと子孫が消えてスコープの対象が無くなる(2026-07-26 実測)

## 飛び越し画面(タイトル `飛び越し`。**今のところ CMP のみ**・他 3 SUT には無い)

スクロール探索が要素を「飛び越す」現象(発生率 0.8%)を決定的に再現する witness 画面。

到達は診断画面の `#btn_open_jump` から(「ホームタブ / ルート」節の「ここに行を増やさない」契約に
従った結果。ここへ戻さないこと)。

| tag | 種別 | ラベル/テキスト | 備考 |
|---|---|---|---|
| `#txt_jump_selected` | Text | `jumped=<v>` 初期 `jumped=-` | 固定ヘッダ(スクロールしない) |
| `#list_jump` | (容器) | (ラベルなし) | 行を包むスクロール容器。**高さ 160dp 固定** |
| `#jrow_01` … `#jrow_12` | Button | `跳 01` … `跳 12` | **高さ 56dp**(契約の下限)・ゼロ詰め・`#list_jump` の子孫 |

行タップで `jumped=jrow_NN`。

**寸法と位置そのものがこの画面の存在理由**(どちらを崩しても witness が死ぬ):

1. **容器は下寄せ**(上下の Spacer が 4:1)。Android の既定スワイプは**画面 70% → 30%**なので、
   容器を画面中央に置くと**指が容器に乗らず1ピクセルも動かない**(2026-08-06 に実測。
   「飛び越している」ように見えて実際は何も動いていなかった)
2. **容器 180dp < 1回の移動量(画面の約 40%)- 行 2つぶん**。この差のぶんだけ、
   上端の可視域と下端の可視域の**間に穴**が空き、`#jrow_05` / `#jrow_06` は
   **一度もツリーに現れない**(= 決定論的な飛び越し)

`scrollFrame: "#list_jump"` を書いた経路は刻みが容器基準に縮むので中間位置でも木を撮れ、
同じ行に到達できる = 対照になる。**iOS では別の病理(容器の外に出た ghost 行が木に残る)が先に
出るため、この witness が狙いどおり効くのは Android**。

## 非同期表示画面(タイトル `非同期表示`)

| tag | 種別 | ラベル/テキスト | 備考 |
|---|---|---|---|
| `#txt_delay_state` | Text | `state=<s>` 初期 `state=idle` | s ∈ `idle`/`waiting`/`done` |
| `#btn_delay_1` | Button | `1秒後に表示` | |
| `#btn_delay_3` | Button | `3秒後に表示` | |
| `#btn_delay_8` | Button | `8秒後に表示` | 既定 timeout(5秒)超え = 失敗検証用 |
| `#txt_delayed` | Text | `遅延表示 完了` | 待機中は**ツリーに存在しない**(非表示ではなく未配置) |
| `#txt_countdown` | Text | `count=<n>` | `#btn_delay_3` 押下中に 3→2→1→0 と毎秒変化 |
| `#btn_async_reset` | Button | `非同期リセット` | 進行中のタイマもキャンセルして idle へ |

## ダイアログ画面(タイトル `ダイアログ`)

| tag | 種別 | ラベル/テキスト | 備考 |
|---|---|---|---|
| `#txt_dialog_result` | Text | `dialog=<v>` 初期 `dialog=none` | v ∈ `none`/`ok`/`cancel` |
| `#btn_show_dialog` | Button | `ダイアログを開く` | 必ず開く |
| `#btn_maybe_dialog` | Button | `交互にダイアログ` | 奇数回目だけ開く(1回目=開く) |
| `#txt_dialog_title` | Text | `確認` | ダイアログ内 |
| `#btn_dialog_ok` | Button | `OK` | ダイアログ内 |
| `#btn_dialog_cancel` | Button | `キャンセル` | ダイアログ内 |
| `#sw_auto_dialog` | Switch | `起動時ダイアログ` | **永続**。ON なら画面に入るたび自動で開く |
| `#txt_auto_dialog` | Text | `auto=<on\|off>` 初期 `auto=off` | |

`#btn_maybe_dialog` は乱数を使わず**決定的に交互**(奇数回目に開く)。カウンタは画面離脱で 0 に戻す。

## コントロールタブ(タイトル `コントロール`)

| tag | 種別 | ラベル/テキスト | 備考 |
|---|---|---|---|
| `#sw_notify` | Switch | `通知` | |
| `#txt_sw_notify` | Text | `notify=<on\|off>` 初期 `notify=off` | |
| `#cb_agree` | Checkbox | `同意する` | |
| `#txt_cb_agree` | Text | `agree=<true\|false>` 初期 `agree=false` | |
| `#radio_a` / `#radio_b` / `#radio_c` | RadioButton | `プランA` / `プランB` / `プランC` | |
| `#txt_radio` | Text | `plan=<A\|B\|C>` 初期 `plan=A` | |
| `#slider_volume` | Slider | (ラベルなし) | 0..100・steps で 25 刻み |
| `#txt_slider` | Text | `volume=<n>` 初期 `volume=50` | |
| `#btn_always_disabled` | Button | `無効ボタン` | **常に disabled**。押しても何も起きない |
| `#btn_toggle_target` | Button | `切替対象` | **`#cb_agree` が true のときだけ enabled**(初期 disabled)。押しても何も起きない |
| `#btn_controls_reset` | Button | `コントロールリセット` | 全て初期値へ |

**disabled の 2 ボタンは `enabledIsTrue`/`enabledIsFalse` の検証材料**(ftester 側の唯一の disabled 供給源)。
- **無効でもアクセシビリティツリーから消さない**(消えると「要素が見つかりません」になり
  「無効であること」を検証できない)。無効化は enabled 属性だけで表現する。
- `#btn_toggle_target` は既存の `#cb_agree` を有効化スイッチとして流用する(新しいトグルを増やさない)。
  「同意したら次へ進める」という実アプリで最も多い disabled パターンの再現でもある。
- どちらも**タップ対象にしない**(無効ボタンへの tap の挙動は OS/フレームワークで割れるため、
  シナリオは状態検証だけに使う)。

Switch/Checkbox/RadioButton は**ラベル Text 自体をタップ対象にしない**(tag 付きのコントロール本体だけを
タップ対象にする)。ラベルとコントロールが別要素になるよう Row で並べる。

## ライフサイクル画面(タイトル `ライフサイクル`)

| tag | 種別 | ラベル/テキスト | 備考 |
|---|---|---|---|
| `#txt_launch_count` | Text | `launch=<n>` | **永続**。プロセス起動ごとに +1 |
| `#txt_session_count` | Text | `session=<n>` 初期 `session=0` | プロセス内メモリのみ |
| `#btn_session_inc` | Button | `セッション+1` | |
| `#btn_reset_persisted` | Button | `永続カウンタをリセット` | `launch=1` に戻す(現プロセス分) |
| `#txt_platform` | Text | `platform=<iOS\|Android>` | |
| `#txt_last_deeplink` | Text | `deeplink=<受け取った URL 全体>` 初期 `deeplink=-` | プロセス内メモリのみ(永続しない)。§ディープリンク |

`relaunchApp` の検証: 事前に `session` を上げ、relaunch 後に `session=0` かつ `launch` が +1 されている。

## 自己修復画面(タイトル `自己修復`)

`--heal` とヒールキャッシュの E2E 用。**ラベルは不変・id だけが切り替わる**。

| tag | 種別 | ラベル/テキスト | 備考 |
|---|---|---|---|
| `#sw_heal_schema` | Switch | `旧ID(v1)を使う` | **永続**。既定 ON(= v1) |
| `#txt_heal_schema` | Text | `schema=<v1\|v2>` | |
| `#btn_heal_v1` または `#btn_heal_v2` | Button | `修復対象`(不変) | Switch の状態で tag が入れ替わる |
| `#txt_heal_result` | Text | `tapped=<v1\|v2\|->` 初期 `tapped=-` | |
| `#btn_heal_reset` | Button | `修復結果クリア` | |

シナリオは `#btn_heal_v1` を書く。schema=v2 のとき id は解決できず、ラベル `修復対象` から
FM が修復できるかを検証する。

## 診断画面(タイトル `診断`)

| tag | 種別 | ラベル/テキスト | 備考 |
|---|---|---|---|
| `#txt_build_info` | Text | `build=<APP_VERSION>` | `Tags.kt` 隣の `AppInfo.VERSION` |
| `#txt_diag_note` | Text | `診断メニュー` | |
| `#btn_open_jump` | Button | `飛び越し` | 飛び越し画面を開く。**`#btn_crash` 系より前に置く**(即プロセス落ちの押下対象の近くに新しい押下対象を並べない) |
| `#btn_freeze_3s` | Button | `3秒フリーズ` | メインスレッドを 3 秒ブロック |
| `#btn_crash` | Button | `クラッシュさせる` | 確認ダイアログを出すだけ |
| `#btn_crash_confirm` | Button | `本当にクラッシュ` | **即プロセス異常終了**(通常シナリオでは押さない) |
| `#btn_crash_cancel` | Button | `やめる` | |

`#btn_crash_confirm` はブリッジ切断・クラッシュレポート添付の検証専用。
通常実行に載せる `scenarios/` 直下には置かず `_disabled/` に置く。

## ID なし画面(タイトル `ID なし`)

**この画面の要素には testTag / accessibilityIdentifier を一切付けない**(付けたら契約違反)。
id を公開しないアプリを模し、**方向セレクタ(`:right` / `:left` / `:above` / `:below`)だけで
操作・検証できること**を保証するための画面。到達用のナビ `#nav_noid` とシェル(`#btn_back` 等)には
id がある(そこまで無いとテストが書けないため)。

| 位置 | 種別 | ラベル/テキスト | 備考 |
|---|---|---|---|
| 見出し | Text | `設定` | `設定:below…` の基準 |
| 行1 左 | Text | `通知` | |
| 行1 右 | Switch | (無ラベル) | `通知:rightSwitch` で指す。初期 off |
| 行1 下 | Text | `notify=off` / `notify=on` | 前方一致 `notify=*` で引く |
| 行2 左 | Text | `位置情報` | |
| 行2 右 | Switch | (無ラベル) | `位置情報:rightSwitch`。初期 off |
| 行2 下 | Text | `location=off` / `location=on` | |
| 行3 左 | Button | `変更` | qty を -1(下限 0) |
| 行3 中 | Text | `数量` | 左右ボタンの基準 |
| 行3 右 | Button | `変更` | qty を +1 |
| 行3 下 | Text | `qty=<n>` 初期 `qty=0` | |

- **行1/行2 のスイッチは同じ型・同じ(無)ラベル**なので、行を跨いで取り違えないこと(帯判定)が
  この画面の主目的。行の高さは 48dp 以上を確保し、行同士を縦に十分離す。
- **行3 の `変更` は左右で同一ラベル**。`数量:leftButton` / `数量:rightButton` でしか区別できない。
- 状態は `key=value` の Text で echo する(全体規約と同じ)。値の永続化はしない。

## WebView 画面(タイトル `WebView`)

ネイティブの WebView(iOS=WKWebView / Android=android.webkit.WebView)に**同じ HTML** を
読ませる画面。HTML の唯一の正は **`E2EAppCMP/docs/webview.html`**(5 SUT がその写しを持つ。
iOS/CMP は文字列定数、Android/Flutter はアセット)。ネットワークは使わない。

**この画面だけ規約が違う。読む前に必ずここを読むこと**:

- **`#id` は使えない**(確定仕様。将来も `#id` には載せない)。HTML の `id` 属性は
  iOS/Android とも a11y の identifier に現れない(2026-07-29 に4経路で実測)。
  Android は **Chromium が `viewIdResourceName` にも extras bundle にも HTML id を出さない**
  (WebView 124 / Android 15 で実測、2026-07-29)。**指せるのは表示テキストと `aria-label` と型だけ**。
  だから他の画面と違い、以下の表は tag ではなく**ラベル**を主キーにしている。
- **コンテナも `#wv_container` では引けない**(Android の WebView ノードは resource-id を
  持たない)。スコープを切るときは型セレクタ `.webView` を使う。
- **リンクは2要素に分かれて出る**(`.link` と、その中の `.staticText`。両 OS 共通)。
  同じラベルが2つ並ぶので、**ラベル単独では曖昧解決不能**。`.link&&WebView リンク` のように
  型で絞る。
- **iOS は中身が出るまで約 2.3 秒かかる**(WebContent プロセスの a11y 起動待ち。内蔵 HTML で
  この値なので、実ページ+通信ではさらに延びる)。`timeout: 0` のアサーションは書かない。
- **Android は操作後のテキスト更新が a11y に 4〜8 秒遅れて届く**(Chromium が DOM 変更の
  a11y イベントを遅らせる。CMP / Flutter の interop 埋め込みで実測)。**ブリッジ側で
  WebView 内ノードだけ `refresh()` してから読む**ようにしたので利用者側の対処は不要
  (`AndroidRunner` の `SnapshotBuilder.collect`)。シナリオはこの修正の退行検知を兼ねて
  **既定 timeout のまま**書く。
- **iOS in-app は DOM を直接読む**(a11y ツリーは別プロセス提供で見えないため)。
  SwiftUI / UIKit ホストではこの経路が使われ、WebView 画面でも 1 手 4ms 程度で動く。
  **Compose / Flutter ホストは interop がタッチと入力を横取りする**ため DOM 経路を使わず、
  画面ごと XCUITest へ委譲する(`WebViewDelegatingDriver`)。どちらも利用者の書き分けは要らない。

| ラベル/テキスト | 型 | タップ時の結果 | 備考 |
|---|---|---|---|
| `WebView 見出し` | staticText | (タップ不可) | 着地判定の基準 |
| `WebView 本文` | staticText | (タップ不可) | |
| `WebView リンク` | link | `wv_result=link` | 同ラベルの staticText と重複して出る |
| (placeholder `WebView 入力`) | textField | | ラベルが無いので `placeholder=WebView 入力` で指す。入力値は ASCII のみ |
| `送信` | button | `wv_result=<入力値>` | |
| `WebView アリアラベル` | button | `wv_result=aria` | ラベルは `aria-label` 由来(表示テキストは `●`) |
| `変形ボタン` | button | `wv_result=transform` | `transform: translate(60px, 0)`。**座標検証の材料**(rect が transform 込みで来ないとタップが外れる。移動量は半幅より大きくしてある) |
| `固定ボタン` | button | `wv_result=fixed` | `position: fixed`(右下)。**スクロール後**も正しい座標で当たることの検証材料。全幅要素の中心を覆わない位置に置く |
| `wv_result=<v>` 初期 `wv_result=-` | staticText | (タップ不可) | 状態の echo |
| `WebView 行 01`〜`WebView 行 30` | staticText | (タップ不可) | 行の高さ 56px 以上 |
| `WebView 画面外テキスト` | staticText | (タップ不可) | 画面外(要 `scrollTo`) |
| `8/13` `晴れ` `31` … | staticText | (タップ不可) | **見出しを a11y へ出さない格子**(3列×3行)。下記 |

**格子の見出し行は `aria-hidden="true"`**(2026-08-13 追加)。**描画はされるが a11y には出ない**ので、
`日付` / `天気` / `気温` は木に**現れない**。実 web ページで観測した形(ブラウザが `<th>` を
落とす等)を**オフラインで決定的に再現する**ための材料で、`gridWithoutHeaderNote` と
`webViewGapNote` の**唯一の offline witness**(実 web を叩くタスクは盤面が毎日変わるので
bench では使わない —— Bench/README.md)。**触るときの制約が2つある**:

- **`aria-hidden` を外さない**。外すと見出しが木に出て検知が発火しなくなる
- **見出し行の厚み(`padding: 34px`)を減らさない**。判定は「直上の空き ÷ 行間の中央値 ≥ 2.0」で、
  素直な厚みだと 91/48 = **1.9 で発火しない**(2026-08-13 に iOS シミュレータで測って 34px に決めた)
- **埋め込み先の言語ごとにリテラルの制約が違う**。この HTML は 6 ファイルへ写すが、
  **同じ本文でも言語によって落ちる**(2026-08-13 に2回踏んだ):
  - RN(TS のテンプレートリテラル)= **バッククォートを書かない**。HTML コメントの中でも
    文字列が途中で終端してビルドが落ちる
  - iOS(Swift の複数行リテラル)= **全行を閉じ区切り以上に字下げする**。1行でも足りないと
    コンパイルエラー。**Swift は最初のエラーで止まる**ので、報告された行だけ直すと次の周回で
    別の行が出る —— リテラル全体を機械的に見ること
  - **`swift test` は SUT アプリをビルドしない**(別の Xcode プロジェクト)。この type の
    退行を捕まえるのは `Scripts/e2e.sh` だけで1周4〜7分かかる。配り終えたら
    `xcodebuild -project E2EAppIOS/FTE2EIOS.xcodeproj -scheme FTE2EIOS … build` を
    直接1回打つほうが速い

**値のセルは Android でも iOS でも木に出る**(ブリッジ版 61 以降)。見出し行だけが
`aria-hidden` で出ない = 上の検知の witness。

**格子の最終行と `#wv_icon` は、DOM 経路の2規則の唯一の witness**(2026-08-13。版 66):

**8/16 の行の `<td><span>19</span> / <span>24</span></td>`** が、DOM 経路の
「**インラインだけの容器は1ノードへ畳む**」規則の唯一の witness(版 66)。
a11y(Chromium の accname)は `19 / 24` と連結するので、畳まないと**同じ画面で a11y と DOM の
セレクタが割れる**。**span を平文へ均さないこと** —— 均すと規則が1画面も通らなくなる。

**もう1つの規則(`alt` が無い画像は `src` のファイル名を名前にする)には offline の witness が無い**
(2026-08-13 に置こうとして断念)。**壊れた画像は箱を持たない**ので木に出ず、
埋め込み HTML はアセットを解決できないため**読み込める画像を置けない**。
data URI にすると「ファイル名」という手掛かり自体が無意味になる。
この規則の根拠は**実 web ページ**(気象庁のページで `logo_small` / `bosai_forecast` が
取れることを実測)。**offline で守れない規則がある**ことを承知の上で入れてある。

**2026-08-13 に「Android では表が木に出ない」と誤って記録していた**(4 SUT で実測したが、
測っていたのは**自分のブリッジの出力**だった)。実際はセルは a11y ツリーに在り、
`SnapshotBuilder.mappedType` の葉テキスト救済が `contentDesc` しか見ていなかったため
`Other` へ落ち、`shouldInclude` の default が resource-id を要求して捨てていた。
`<table>` 自身は GridView + id で残るので空白帯にもならず**黙って消えていた**。
版 61 で修正済み(`AndroidTextLeafRuleTests` が規則を固定)。
**教訓**: 道具の外の性質を、その道具の出力だけで断定しない。

**`#id` は WebView の版で割れる**(2026-08-13 実測)。DOM の `id` が
`viewIdResourceName` に出るかどうかが違う:

| | WebView 124(エミュレータ) | WebView 150(Pixel 4a 実機) |
|---|---|---|
| 表のセルの値 | ○ | ○ |
| 見出し(`aria-hidden`) | ×(意図どおり) | ×(意図どおり) |
| WebView 内の `#id` | **×** | **○**(`#wv_grid` `#wv_row_26`) |
| 入力欄の `placeholder` | **○**(`ph="WebView 入力"`) | **×** |

**WebView 150 は入力欄の名前を出さない**(2026-08-14 実測)。`placeholder` だけでなく
**`aria-label` を足しても名前にならない**(同じページの `<button aria-label>` は名前になるので、
入力欄に固有の挙動)。accname では `aria-label` が最優先のはずで、**Chromium 側の回帰と見ている**。
したがって、**この入力欄はどれか1つの属性では指せない**。

**`#id` と `placeholder` は入れ替わる**(2026-08-14 実測。トレードではない):

    124: textField ph="WebView 入力"     ← placeholder あり / id なし
    150: textField id=wv_input          ← id あり / placeholder なし

**どちらの版に合わせて書いても他方で落ちる。** 1台だけ更新して実際に事故を起こした
(`placeholder=WebView 入力` のシナリオが 150 の端末でだけ「セレクタが見つからない」)。
run 開始時に `AndroidWebViewVersions` が混在を警告する。

**書き方は `#wv_input||#WebView 入力`**(2026-08-15。全 SUT のシナリオがこの形)。
`#x` は identifier で引けなければ placeholder を引く(docs/commands.md)ので、
**2節でこの表の4通りすべてを覆う**:

| 構成 | 何が出るか | どちらの節が当たるか |
|---|---|---|
| iOS in-app(DOM) | id と placeholder の両方 | `#wv_input` |
| iOS xcuitest | placeholder のみ(WebKit は HTML id を a11y へ出さない) | `#WebView 入力` |
| Android WebView 124 | placeholder のみ | `#WebView 入力` |
| Android WebView 150 | id のみ | `#wv_input` |

**片方だけに縮めないこと** —— 縮めた瞬間に、上の4行のどれかで「セレクタが見つからない」に戻る。

Android の版ではない(実機 SDK 33 / エミュレータ SDK 35 で、**古い OS のほうが新しい WebView**)。
**シナリオは WebView 内の `#id` に依存させない** —— 受け手はユーザーの WebView 版を選べない。

したがって:

- **iOS**: 値が木に出て見出しが出ない = `gridWithoutHeaderNote` の offline witness
- **Android**: 表ごと出ない = `webViewGapNote`(描画はあるのに木に無い)の offline witness
- **シナリオでこの格子の値を Android で assert しないこと**(原理的に取れない)

到達は `#nav_webview`(ホームのナビ。ここはネイティブなので id が効く)。
**CMP は interop 埋め込み**(Android=`AndroidView`、iOS=`UIKitView`)。iOS 側は
`UIKitInteropProperties(isNativeAccessibilityEnabled = true)` が**必須**で、これが無いと
Compose の a11y ツリーが interop ビューを1ノードに畳み、中身が一切見えない(2026-07-29 実測)。
初回表示は SUT により 0〜8 秒かかる(ネイティブ Android=即時 / iOS=約2.3秒 /
CMP Android=約6秒 / Flutter Android=約8秒)。
**行は `行 01` 形式のゼロ詰め**(`*行 1*` が `行 12` に contains 一致する事故を避ける。他画面と同じ)。

## 情報タブ(タイトル `情報`)

| tag | 種別 | ラベル/テキスト | 備考 |
|---|---|---|---|
| `#txt_about_marker` | Text | `E2E について` | 情報タブ着地の判定 |
| `#txt_about_app` | Text | `app=com.ftester.e2e` | |
| `#txt_about_version` | Text | `version=<APP_VERSION>` | |

## 永続化する値(これ以外は永続化しない)

`launch`(起動回数)/ `auto`(起動時ダイアログ)/ `schema`(自己修復の id スキーマ)の 3 つだけ。
Android は SharedPreferences、iOS は NSUserDefaults(expect/actual)。
