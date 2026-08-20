# FT E2E Android ネイティブアプリ UI 契約

**画面構成・`#id`・表示ラベルは `E2EAppCMP/docs/ui-contract.md`(Compose Multiplatform 版)と共通**。
同じシナリオを各 SUT に当てて比較できるよう、値は byte 一致させてある。
このファイルは **Android ネイティブ実装(View/XML + 一部 Compose)固有の差分だけ**を定義する。

- applicationId: `com.ftester.e2e.android`(Compose 版 `com.ftester.e2e` と共存できる)
- `#txt_about_app` は `app=com.ftester.e2e.android`
- シナリオ: `TestProjects/E2E-Android/scenarios/`
- ディープリンク: `MainActivity` は `android:launchMode="singleTop"` + `onNewIntent`(`singleTask` は
  タスクを畳んで既存シナリオの launch 挙動に影響し得るため避けた)。

## `textAllCaps` を必ず切る(2026-08-06)

`Theme.FTE2E` に `android:textAllCaps=false` / `textAllCaps=false` を入れてある。
AppCompat の既定は `Button` を大文字で描き、**a11y ラベルまで大文字になる** ——
`android:text="WebView"` の `#nav_webview` が `WEBVIEW` で出て、
「ラベルは全 SUT 共通」の契約どおりに書いたシナリオがこの SUT でだけ落ちていた。

**日本語ラベルは大文字化の影響を受けない**ので、ASCII ラベルの `WebView` 1件だけが
表面化していた。ASCII のラベルを増やすときはここを疑うこと。

## 実装方式(どこが View で、どこが Compose か)

**同じアプリの中で View と Compose を同居させる**のがこの SUT の核。型語彙が画面ごとに変わる。

| 画面 | 実装 | ツリー上の型 |
|---|---|---|
| コントロール | `ComposeView`(material3) | Switch → `switch`、Button → `button`、Checkbox/RadioButton → `checkBox`、Slider → `slider` |
| スクロール | `RecyclerView` + clickable な行 ViewGroup | `collectionView` + `clickable` |
| テキスト入力 | `EditText` | `textField` / `secureTextField`(password のみ) |
| それ以外 | View/XML | `button` / `staticText` / `switch` / `scrollView` |

## 実スナップショットで採取した型(2026-07-23・Pixel 9/Android 15)

| 要素 | 型 | 備考 |
|---|---|---|
| `android.widget.Button` | `button` | View 側のボタん全部 |
| `TextView` | `staticText` | |
| `EditText`(通常) | `textField` | `textMultiLine` も `textField`(iOS ネイティブは `textView` になる) |
| `EditText`(textPassword) | `secureTextField` | |
| `SwitchCompat` | `switch` | ダイアログ画面・自己修復画面 |
| Compose `Switch` / `Button` | `switch` / `button` | className は `android.view.View` のまま。ブリッジが checkable と同じ矩形の Button マーカー子から役割を復元する(2026-07-26 正規化。それ以前は両方 `cell` = 現 `clickable` の旧名)。**Button は 2026-08-06 まで復元に失敗して `clickable` のままだった** —— ComposeView 埋め込みでは親とマーカー子の矩形が完全一致せず、一致条件で弾かれていた(`looksLikeRoleMarker` で辺の共有判定に緩めて解消) |
| Compose `Checkbox` / `RadioButton` | `checkBox` | ラジオも `checkBox` に丸められる |
| Compose `Slider` | `slider` | |
| `RecyclerView` | `collectionView` | |
| 行(clickable ViewGroup) | `clickable` | |

### セレクタ画面の序数(シナリオ 04 が依存)

見えている Button のツリー順は Compose 版・iOS ネイティブ版と**同じ**:
戻る(1) 許可(2) 通知を許可(3) 項目(4,5,6) 共通ラベル(7) 別名(8) 結果クリア(9) タブ(10-12)。
→ 3番目の『項目』= `.button[6]`。

## Android 固有の罠(すべて実測で踏んだもの)

### 1. View は resource-id を実行時生成できない

Compose の `testTag` に相当する仕組みが View 系には無い。動的リスト(`#row_01`..`#row_40`)は
**`res/values/ids.xml` に静的宣言**し、`onBindViewHolder` で `view.id = R.id.row_NN` を割り当てる。
これを忘れると行は `#id` を一切持たない。

### 2. ComposeView の中だけ `testTagsAsResourceId` が要る

View 側は `android:id` が自動的に resource-id として出るが、ComposeView の中は
`Modifier.semantics { testTagsAsResourceId = true }` を立てないと `#id` が全滅する
(ラベルは引ける)。ルートで1回立てれば子孫全体に効く。

### 3. `importantForAccessibility="no"` では消えない

ブリッジの UiAutomation は not-important view も含めて走査するため、行内の TextView は
`importantForAccessibility="no"` を付けても `staticText` としてツリーに残る。
結果として行ラベル「行 03」は **Cell と StaticText の2要素**に出る。
→ ラベル指定は**型限定**(`.clickable=行 03`)で一意化する契約にしてある。

### 4. 縦 LinearLayout の `layout_weight` は幅に効かない

ジェスチャ画面で「幅 45%」を作ろうとして縦 LinearLayout に `layout_width="0dp"` +
`layout_weight` を書くと、幅が 0 のままになり **要素がスナップショットから丸ごと消える**
(幅 2px 未満はフィルタで除外)。幅の比率は**横**の LinearLayout + `weightSum` で作る。

### 5. AlertDialog の既定ボタンは id を持てない

`setPositiveButton` のボタンは resource-id が `android:id/button1` / `button2` になり
`#btn_dialog_ok` を引けない。**`setView` に自前の id 付きレイアウトを載せる**
(`res/layout/dialog_confirm.xml`)。別ウィンドウでも View の resource-id はそのまま出るため、
`#txt_dialog_title` も引ける(iOS ネイティブは UIAlertController が id を捨てるのでここが OS 差)。

### 6. savedInstanceState は捨てる

`MainActivity.onCreate` は `super.onCreate(null)` を呼ぶ。渡すと Android が View 階層の状態
(EditText の文字列など)まで復元し、`relaunchApp` 後の初期状態が前回実行に汚染される。
EditText 側にも `android:saveEnabled="false"` を付けてある。

### 7. IME アクションの発火経路は2つ。キーイベントはソフトキーボードに吸われる

`pressEnter()`(と `type` の末尾改行)は **a11y の `ACTION_IME_ENTER`** を優先し、旧ブリッジ・
API 30 未満のときだけ `keyevent 66` に落ちる。`OnEditorActionListener` への届き方が経路で違う:

| 経路 | actionId | KeyEvent |
|---|---|---|
| a11y `ACTION_IME_ENTER`(既定) | フィールドの imeOptions = `IME_ACTION_SEARCH` | **null** |
| `keyevent 66`(フォールバック) | `IME_NULL` | あり |

**両方の actionId を受理**しないと片方の経路で取りこぼす。数えるのは `event == null`(a11y 経路)
または `KeyEvent.ACTION_UP` のときだけ(キーイベント経路で DOWN/UP の両方が来ても二重に数えない)。
実装は `Screens.kt` の `buildInputScreen`。

**罠(実測 2026-07-28)**: ソフトキーボードが出ていると `keyevent 66` は **View/XML の `EditText` に
そもそも届かない**(IME が消費する)。`adb shell ime disable <id>` で IME を止めると同じキーで発火する
ことを確認済み。**Compose の入力欄は同条件でも発火する**ので、CMP SUT だけ見ていると気付けない
(実際シナリオ 18 は CMP で緑・View/XML で赤になった)。ftester が a11y 経路を既定にしたのはこのため。

### 8. ダイアログ表示中は `screen` が別ウィンドウのサイズになる

ダイアログを開いた状態のスナップショットは `screen: 1024x427` のようにダイアログ側の
ウィンドウ寸法を返す。座標系は絶対座標のままなので tap には影響しないが、
画面比率で撃つ `swipe` をダイアログ表示中に使ってはいけない。

### WebView 画面(SUT 固有の実測)

- WebView ノードは **resource-id を持たない**(レイアウトで `@+id/wv_container` を付けても
  a11y ノードには出ない)。`.webView` 型で指す。
- 実 View と Chromium の仮想ルートで **WebView が2重に出る**ため、ブリッジが内側を落として
  1つに畳んでいる(SnapshotBuilder の `nestedWebView`)。
- リンクは className が `android.view.View` で、そのままだと `clickable` になる。
  Chromium の `AccessibilityNodeInfo.chromeRole`(非ローカライズ)を見て `link` に正規化している。
  **roleDescription は端末ロケールで訳されるので使わない**。
- 中身は即座に見える(ネイティブ WebView)。ただし `loadDataWithBaseURL` を使う SUT
  (CMP / Flutter)は初回 6〜8 秒かかる。
- **DOM 変更の a11y 反映が 4〜8 秒遅れる**(CMP / Flutter で実測。タップは効いているのに
  `textIs` だけ古い値で落ちる)。ブリッジが WebView 内ノードを `refresh()` してから読むことで
  1 秒未満に短縮している(コストは snapshot 1 回あたり +20ms)。

## 容器つきの入力欄(`#field_wrapped`)

**この SUT だけが持つ**(Material の `TextInputLayout` / `TextInputEditText` と同じ形の再現)。
`FrameLayout`(id 付き・`clickable="true"`)が **id を持たない `EditText`** を包む。

- **容器をタップしても入力フォーカスは中身へ移らない**(容器がタップを吸うだけ)。
  そのため `tap("#field_wrapped")` の直後の `type("…")` は、素朴に実装すると
  「フォーカスが無い」で落ちる —— ツールは焦点が立っていなければ**中身の欄へ入れ直す**
  (`InputFocusRescue`。注記 `type-focus-recovered`)
- 中身は `findViewById` で引けない = **シナリオ側も `#id` では指せない**。
  指すなら祖先スコープ(`#field_wrapped>>.textField`)か型+順序

## 出た直後だけ無効なボタン(`#btn_enables_late`)

**この SUT だけが持つ**。コントロール画面に入ってから **1.5 秒間 disabled**、その後 enabled。
押すと `#txt_late_result` が `late=tapped`。

- **要素は最初から木に居る**ので `waitForDisplay` では待ち切れない = `tap` が
  「操作可能になるまで待つ」ことの witness(待たない実装だと `late=-` のまま緑にならない)
- 1.5 秒は `OverlayWindow`(iOS)と同じ間で揃えてある

## 画面回転

**回転しても画面は保たれる**(2026-08-11)。Android は回転で Activity を作り直すため、素のままだと
ホームへ落ちていた(他の SUT は保つので、この SUT だけ挙動が割れていた)。
`onRetainCustomNonConfigurationInstance` でタブと子画面だけを引き継いでいる ——
**構成変更専用でプロセス死を跨がない**ので、「起動時は必ずホームのルート」契約
(`MainActivity.onCreate` が `savedInstanceState` を捨てる理由)はそのまま。
View 階層の状態(EditText の文字列など)は引き継がない。

## ビルド

```sh
cd E2EAppAndroid
./scripts/build-android.sh    # → dist/android/ft-e2e-android-debug.apk
```
