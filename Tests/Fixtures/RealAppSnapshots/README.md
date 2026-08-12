# 実アプリのスナップショット(検知の回帰用フィクスチャ)

`GET /snapshot` の生 JSON をそのまま置いてある。**自前の 4 SUT は遮蔽・積み重なり・
中身外しの形を代表しない**(2026-08-07 の3ラウンドで、誤検知も真陽性も実アプリでだけ出た)ので、
`SweepHarnessTests` はここへ全数で検知を当てて件数を基準値と突き合わせる。

**接頭辞は OS を表すだけで、アーキタイプは表さない**(`ios-` に地図も設定もブラウザも居る)。
**アーキタイプの分類の正は `NoteCoverageTests.archetypes`** —— フィクスチャを足したらそちらにも
足すこと(`testEveryFixtureHasAnArchetype` が食い違いを検出)。分類は「注記・検知がその形でしか
効いていないのか」を測るためにある: 2026-08-12 に地図以外を6枚足したところ、
**それまで「地図でしか出ない」と見えていた注記5本のうち3本が他アーキタイプでも出た**
(docs/verification.md §「注記の発火と出力コスト…」)。

| 接頭辞 | 由来 | 何を代表するか |
|---|---|---|
| `and-` | Google マップ 11.x / Android 15(emulator) | 塗り順 `z` を**持つ**木・全画面シート・横カルーセル。`and-maps_suggest_ime` は IME を開いたまま採った木(`keyboardFrame` 申告付き。ブリッジ版53以降でだけ採れる) |
| `ios-` | Apple マップ / iOS 27.0(Simulator・xcuitest) | `z` を**持たない**木(ツリー順フォールバック)。`ios-maps_suggest_keyboard`(キーボード + `keyboardFrame`)と `ios-maps_station`(地図 POI 67個 = bulk 間引き後の高密度画面)は 2026-08-08・版58 で採取。**`ios-maps_suggest_guides` と `ios-place_guides_scrolled` は 2026-08-09 の監査で足した witness** —— 前者は行セルの中心を中の帯が横取りする形(`nested`)、後者は申告されたスクロール容器の上へ抜けた行(`scrolledOut`)の供給源で、どちらも Simulator 上で誤タップを実測してから採った |
| `sut-` | E2E-CMP(自前) | 契約で盤面が固定された対照 |
| `sutec-` | sut-ec-mobile / iOS 27.0(Simulator・**in-app**) | in-app エンジンの木(それまで1枚も無かった)・画面外中心(`offscreen`)の供給源・下部バーの遮蔽 |

**2026-08-12 に足した6枚**(コーパスの地図比率を 14/19 → 14/25 へ下げるため。いずれも実アプリ):

| ファイル | アーキタイプ | 由来 | 何を代表するか |
|---|---|---|---|
| `ios-settings_root` | settings | iOS 設定 | 深い設定ツリー。**無名 clickable が地図以外でも出ることの witness**(`unlabeledClickablesNote`) |
| `and-settings_root` | settings | Android 設定 | 同上の Android 版(`#title`/`#summary` が行ごとに重複する形) |
| `ios-messages_keyboard` | chat | iOS メッセージ | 会話 + ソフトキーボード。**`keyboardCoverageNote` と `scrollFrameCandidates` が地図以外でも出ることの witness**。検知は全項目0 = **陰性対照** |
| `ios-photos_grid` | media | iOS 写真 | 同じ id のタイル格子 |
| `ios-safari_article` | webview | Safari(Wikipedia) | 実 web ページの a11y 木。**実アプリで初めて `disabled` が出た**(履歴なしの「戻る」)。**overlay 14 件のうち 10 件は「折り返す inline テキスト」の誤検知**(SweepHarnessTests の当該コメント参照) |
| `and-dialer_keypad` | keypad | Android 電話 | 12 キーの格子。`nested`(容器の中心がキーに乗る)と `disabled`(空入力時の Backspace)の実アプリ witness |

**採り直すとき**は基準値も一緒に更新する(`SweepHarnessTests.baselines`)。件数が増えたら
まず誤検知を疑い、真陽性だと確かめてから基準値を上げること —— 黙って上げると、
この砦は「現状を追認するだけ」になる。

内容は公開アプリの UI ラベル(店名・広告見出しを含む)。個人データは含まない。
