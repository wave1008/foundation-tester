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
| `ios-settings_root` | settings | iOS 設定 | 深い設定ツリー。**行を `clickable` の容器で包み、同じ矩形に `button` + `#id` を置く形の witness**(2026-08-13: この形は `unlabeledClickablesNote` の**誤検知**と判明し、同一矩形に `.stable` なセレクタがあるときは黙るようにした。11/11 が該当してこの画面では発火しなくなった) |
| `and-settings_root` | settings | Android 設定 | 同上の Android 版(`#title`/`#summary` が行ごとに重複する形) |
| `ios-messages_keyboard` | chat | iOS メッセージ | 会話 + ソフトキーボード。**`keyboardCoverageNote` と `scrollFrameCandidates` が地図以外でも出ることの witness**。検知は全項目0 = **陰性対照** |
| `ios-photos_grid` | media | iOS 写真 | 同じ id のタイル格子 |
| `ios-safari_article` | webview | Safari(Wikipedia) | 実 web ページの a11y 木。**実アプリで初めて `disabled` が出た**(履歴なしの「戻る」)。**overlay 14 件のうち 10 件は「折り返す inline テキスト」の誤検知**(SweepHarnessTests の当該コメント参照) |
| `and-dialer_keypad` | keypad | Android 電話 | 12 キーの格子。`nested`(容器の中心がキーに乗る)と `disabled`(空入力時の Backspace)の実アプリ witness |

**2026-08-12 に足した1枚**(ホイールピッカーの witness):

| ファイル | アーキタイプ | 由来 | 何を代表するか |
|---|---|---|---|
| `ios-maps_route_options` | picker | Apple マップの経路オプション | **`pickerWheel` が入れ物を上下にはみ出して申告する形**。`datePicker` (41,246.7 320x216) の中のホイール3本が (y 209.2・高さ 291) で、その上のセグメンテッドコントロールの中心を覆っていると判定していた(**overlay 10→4 の誤検知6件**。`OcclusionGeometry.reportsContentExtent` で解消)。残る overlay 4 は「シート下端に貼り付く `Reset` が料金セクションの行を覆う」= スクリーンショットで実描画を確認した真陽性 |

**2026-08-12 に足した4枚**(ブラウザ = 初見のアーキタイプ。`webview` の1枚は「記事の a11y 木」だけで、
アドレスバー・オーバーレイ・広告で動くレイアウトを代表しない):

| ファイル | アーキタイプ | 由来 | 何を代表するか |
|---|---|---|---|
| `ios-browser_nationwide` | browser | Safari / Yahoo!天気「全国の天気」 | **実 web ページの高密度**(120件 + 38件が上限で脱落)。`link` とその子 `staticText` が**同じラベル・同じ frame で並ぶ**形 = `interactiveOnly` が効かない witness。無名 `link` が多数 |
| `ios-browser_startpage` | browser | Safari / アドレスバーをタップした状態 | **オーバーレイ配下が木に残る**形。スタートページ + `keyboardFrame` が出ているのに、**背後の WebView 本文がそのまま列挙される**(`ios-browser_nationwide` の続きの状態) |
| `and-browser_weather` | browser | Chrome / Yahoo!天気(同一ページの Android 版) | **同じページで OS によりラベルが別物**になる witness —— 市区町村リンクが `13101`/`13102`(内部コード。iOS は `千代田区`)、天気概況の `img alt` はツリーに出ない。下端に貼り付く広告あり |
| `and-browser_urlmenu` | browser | Chrome / URL バーのポップアップ | **背景を木から落とす**オーバーレイ(21要素・`keyboardFrame` あり)。`ios-browser_startpage` と**対の陰性対照**(iOS は落とさない) |

**2026-08-12 に足した2枚**(**同じページを両 OS で採った対**。片方だけでは「木に無い」ことを
証明できない —— ページ自体にその要素が無いのか、ブラウザが公開していないのかが区別できない):

| ファイル | アーキタイプ | 由来 | 何を代表するか |
|---|---|---|---|
| `and-browser_weektable` | browser | Chrome / tenki.jp「東京都の2週間天気」 | **格子の見出し行だけが木から落ちる**形の witness。値のセル(天気・気温・降水確率)は 4列×3行そろっているのに、**その真上の「日付 / 12日(水) / 13日(木) …」が1つも無い**ので、列と日付を対応付けられない。空帯は y=1199→1391 の **192px**(可視容器の 8.9%)で、`webViewGapNote` をスライス本数で測っていた頃は取り逃していた(`gridWithoutHeaderNote` と帯の実測化の供給源)。`url_bar` の値が `tenki.jp/lite/…` = **要求した URL とは別ページへリダイレクトされている**witness でもある |
| `ios-browser_weektable` | browser | Safari / **同じ URL・同じページ** | 上の**陰性対照**。同じ格子だが `日付` `12日` `13日` `14日` `15日` が木にあるので、見出し欠落の検知は**発火してはいけない**。同じページでも OS で木の中身がここまで違うことの witness(iOS 120要素 / Android 88要素) |

**2026-08-13 に足した2枚**(**同じ画面を両 OS で採った対**。Yahoo!天気の週間画面):

| ファイル | アーキタイプ | 由来 | 何を代表するか |
|---|---|---|---|
| `ios-browser_weather_weekly` | browser | Safari / Yahoo!天気(東京)を週間表まで送った状態 | **`gridWithoutHeaderNote` が実アプリで初めて出した誤検知**の witness。週間表は日付(`8/15`…)も曜日(`（土）`…)も木にあるが、**どちらも値のセルと centerX で揃っている**ため見出しが鎖の最上行として取り込まれ、その上の段落間(22pt / 行間 19pt = 1.16倍)を「見出しが無い」と読んでいた。**overlay 30 は全部真陽性**で原因は1つ —— 下端に貼り付く広告が週間表のアイコン・気温の行を丸ごと覆う(ft_screenshot で確認)。木に在るのに画面では読めない = **裏取りの手段が無い**形の witness でもある |
| `and-browser_weather_weekly` | browser | Chrome / **同じページ・同じ位置** | **閾値超えの空白帯が2本ある**形。最大の1本だけを返していた頃は 345px の帯だけが報告され、**268px のほう(週間表の日付・気温・アイコンが丸ごと落ちている場所)が黙って捨てられていた**。生き残った値は降水確率の1行だけなので**格子にすらならず**、`gridWithoutHeaderNote` の側からも見えない。コーパスで**初めて ghost が非0**(`staticText "洗濯指数10"`。SweepHarnessTests の当該コメントに検分を記録) |

**2026-08-13 の監査ラウンド5で足した2枚**(jma.go.jp。**これまでと違い両OS対ではない**——
それぞれ別の欠陥の単独 witness):

| ファイル | アーキタイプ | 由来 | 何を代表するか |
|---|---|---|---|
| `and-browser_jma_notree` | browser | Chrome / jma.go.jp(気象庁)の地域天気ページ | **要素19件が全部ブラウザ自身の chrome**(ツールバー・アドレス欄・タブ切替)で、ページ本体が a11y ツリーに1つも出ない形。画面には本文が全部描画されているのにツリーには何も無い(unrepresentedScreenFraction 0.886)。`missingPageContentNote` の witness ——`webViewGapNote` は webView 容器の**内側**しか測れず、`emptyTreeNote` は要素0の完全一致でしか発火しないので、この形はどちらの網にも掛からず黙って通り抜けていた |
| `ios-browser_jma_hscroll` | browser | Safari / 同じ地域天気ページで横スクロールする表をページングした後 | **横スクロール後、前後のコピーが両方ツリーに残る**形。233要素のうち refs 72-81 と 158-167 が「同じ行・x だけ定数200ptずれた」10ペア(最左列は x=0 にクランプ)。`duplicateRegionNote` の witness —— 単純な最長共通連続列だと、同じ画面内の**別々の2つの表が共有する同一見出し行**(11要素一致・y が別)を誤検知するため、y/x の幾何制約を必須にした |

**採り直すとき**は基準値も一緒に更新する(`SweepHarnessTests.baselines`)。件数が増えたら
まず誤検知を疑い、真陽性だと確かめてから基準値を上げること —— 黙って上げると、
この砦は「現状を追認するだけ」になる。

内容は公開アプリの UI ラベル(店名・広告見出しを含む)。個人データは含まない。
