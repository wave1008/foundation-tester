# FT E2E アプリ UI 契約

このファイルが **testTag(=`#id`)と表示ラベルの唯一の正**。アプリ実装(`E2EApp/composeApp`)と
シナリオ(`Projects/E2E/Scenarios`)の両方がここを参照する。**片方だけ変えない**。
tag 定数は `composeApp/src/commonMain/kotlin/com/ftester/e2e/Tags.kt` に集約する(値はこの表と byte 一致)。

## 全体規約

- 全ての操作対象・検証対象に `Modifier.testTag(...)` を付ける。Android はルートで
  `exposeTestTagsAsResourceId()`(`semantics { testTagsAsResourceId = true }`)、iOS は testTag が
  自動で accessibilityIdentifier になる → `#id` が両 OS 共通で引ける。
  **罠**: ダイアログ(`AlertDialog` 等)は**別ウィンドウ**に描画されるためルートの
  `exposeTestTagsAsResourceId()` が届かない。ダイアログにも `modifier = Modifier.exposeTestTagsAsResourceId()`
  を**必ず再適用する**。忘れると Android だけダイアログ内の `#id` が全滅する(ラベルは引ける)。
- **要素の型名は OS で異なる**(実スナップショットで採取): Compose の Button は
  iOS = `Button` / Android = `Cell`。型を使うセレクタ(`.Type[n]` / `.Type#id` / `.Type=ラベル`)は
  `ios {}` / `android {}` で分ける。`#id` とラベルは共通。
- **ラベルはハードコード**(文字列リソース/ロケール依存にしない)。端末ロケールが ja/en どちらでも
  同じ文字列が出る = フリートのロケール差でシナリオが壊れない。
- **入力する値は ASCII のみ**(IME を介さない `type` の対象にするため)。
- **ラベルの部分一致衝突を意図的に1組だけ作る**(`許可` ⊂ `通知を許可`)。それ以外は衝突させない。
  リスト行は `行 01`〜`行 40` とゼロ詰め(`行 1` が `行 12` に contains 一致する事故を避ける)。
- **状態表示は必ず `key=value` 形式の Text にする**(`textIs` で完全一致検証できる)。
  Switch/Checkbox の AX value は OS で表現が違うため、値検証は原則この echo Text で行う
  (`valueIs` の OS 依存挙動は `ios {}` / `android {}` 節でのみ確認する)。
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

## ホームタブ / ルート(タイトル `ホーム`)

| tag | 種別 | ラベル/テキスト | 備考 |
|---|---|---|---|
| `#txt_home_marker` | Text | `E2E ホーム` | ホーム着地の判定 |
| `#nav_selector` | Button | `セレクタ` | |
| `#nav_input` | Button | `テキスト入力` | |
| `#nav_gesture` | Button | `ジェスチャ` | |
| `#nav_scroll` | Button | `スクロール` | |
| `#nav_async` | Button | `非同期表示` | |
| `#nav_dialog` | Button | `ダイアログ` | |
| `#nav_lifecycle` | Button | `ライフサイクル` | |
| `#nav_heal` | Button | `自己修復` | |
| `#nav_diagnostics` | Button | `診断` | |

ナビ行は縦に並べる。9 行 + マーカーが 1 画面に収まらない場合はスクロール可にする
(`#nav_diagnostics` は `scrollTo` の対象になり得る)。

## セレクタ画面(タイトル `セレクタ`)

`tap` のセレクタ記法(`#id` / ラベル / `.Type[n]` / `.Type#id` / `.Type=label` / `||`)を網羅する。

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
  `.Type[n]` か `#id` でしか引けない(= 序数セレクタの検証材料)。
  **序数はこの画面の見えている Button 全体のツリー順**: 戻る(1) 許可(2) 通知を許可(3)
  項目(4,5,6) 共通ラベル(7) 別名(8) 結果クリア(9) タブ(10-12)。この並びを変えるとシナリオ 04 が壊れる。
- `#btn_alias_new` は `#btn_alias_old||#btn_alias_new` のフォールバック連鎖検証に使う
  (`btn_alias_old` は**存在しない**)。
- `#txt_offscreen` は `#btn_selector_reset` の下に十分な余白(600dp 以上)を挟んで配置する。

## テキスト入力画面(タイトル `テキスト入力`)

| tag | 種別 | ラベル/テキスト | 備考 |
|---|---|---|---|
| `#field_single` | TextField | placeholder `単一行` | singleLine |
| `#field_password` | TextField | placeholder `パスワード` | PasswordVisualTransformation |
| `#field_multiline` | TextField | placeholder `複数行` | 3行程度 |
| `#txt_echo_single` | Text | `single=<v>` 初期 `single=` | |
| `#txt_echo_password` | Text | `password=<v>` 初期 `password=` | 平文で echo(検証用) |
| `#txt_echo_multiline` | Text | `multiline=<v>` 初期 `multiline=` | 改行は `\n` を空白に置換して1行表示 |
| `#txt_echo_length` | Text | `len=<n>` 初期 `len=0` | `#field_single` の文字数 |
| `#btn_input_submit` | Button | `送信` | `#txt_input_submitted` を更新 |
| `#txt_input_submitted` | Text | `submitted=<v>` 初期 `submitted=-` | |
| `#btn_input_clear` | Button | `入力クリア` | 3フィールドと echo を初期状態へ |

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

スワイプ方向は**指の移動方向**で判定する(上へ払う = `up`)。ftester の `swipe(.up)` と一致させる。

**レイアウトの制約(これを崩すと swipe 検証が落ちる)**: ブリッジの `swipe` は**要素を狙わず画面を払う** —
iOS は XCUITest の `XCUIApplication.swipeUp()` 等でアプリ frame 全体を払う(in-app エンジンは座標
スワイプを持たず、動かせるスクロールビューが無ければ 501 で XCUITest へ回る)。
Android(`BridgeRouter.handleSwipe`)は縦 0.3h↔0.7h・横 0.2w↔0.8w(y=0.5h)の固定座標。
よって `#pad_swipe` はコンテンツ領域いっぱいに敷き、操作要素はその**上に重ねる**。
重ねてよいのは Text(ポインタを消費しない)のみ。ボタン類は始点を塞がないよう
**幅 45% 以内(中央列 x=0.5w を空ける)** かつ **上下の端(中央行 y=0.5h を空ける)** に置く。

## スクロール画面(タイトル `スクロール`)

| tag | 種別 | ラベル/テキスト | 備考 |
|---|---|---|---|
| `#txt_row_selected` | Text | `selected=<v>` 初期 `selected=-` | 固定ヘッダ(スクロールしない) |
| `#btn_scroll_top` | Button | `先頭へ` | 固定ヘッダ |
| `#row_01` … `#row_40` | Button | `行 01` … `行 40` | 高さ 56dp 以上・ゼロ詰め |

行タップで `selected=row_NN`。`#row_40` は `scrollTo` の到達目標。

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
| `#btn_controls_reset` | Button | `コントロールリセット` | 全て初期値へ |

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
| `#btn_freeze_3s` | Button | `3秒フリーズ` | メインスレッドを 3 秒ブロック |
| `#btn_crash` | Button | `クラッシュさせる` | 確認ダイアログを出すだけ |
| `#btn_crash_confirm` | Button | `本当にクラッシュ` | **即プロセス異常終了**(通常シナリオでは押さない) |
| `#btn_crash_cancel` | Button | `やめる` | |

`#btn_crash_confirm` はブリッジ切断・クラッシュレポート添付の検証専用。
通常実行に載せる `Scenarios/` 直下には置かず `_disabled/` に置く。

## 情報タブ(タイトル `情報`)

| tag | 種別 | ラベル/テキスト | 備考 |
|---|---|---|---|
| `#txt_about_marker` | Text | `E2E について` | 情報タブ着地の判定 |
| `#txt_about_app` | Text | `app=com.ftester.e2e` | |
| `#txt_about_version` | Text | `version=<APP_VERSION>` | |

## 永続化する値(これ以外は永続化しない)

`launch`(起動回数)/ `auto`(起動時ダイアログ)/ `schema`(自己修復の id スキーマ)の 3 つだけ。
Android は SharedPreferences、iOS は NSUserDefaults(expect/actual)。
