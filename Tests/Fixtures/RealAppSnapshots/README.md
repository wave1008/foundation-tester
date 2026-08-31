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
| `and-` | Google マップ 11.x / Android 15(emulator) | 塗り順 `z` を**持つ**木・全画面シート・横カルーセル。`and-maps_suggest_ime` は IME を開いたまま採った木(`keyboardFrame` 申告付き。ブリッジ版53以降でだけ採れる)。`and-sutec_home` は sut-ec-mobile を Android 実機で採った1枚(下の節を参照) |
| `ios-` | Apple マップ / iOS 27.0(Simulator・xcuitest) | `z` を**持たない**木(ツリー順フォールバック)。`ios-maps_suggest_keyboard`(キーボード + `keyboardFrame`)と `ios-maps_station`(地図 POI 67個 = bulk 間引き後の高密度画面)は 2026-08-08・版58 で採取。**`ios-maps_suggest_guides` と `ios-place_guides_scrolled` は 2026-08-09 の監査で足した witness** —— 前者は行セルの中心を中の帯が横取りする形(`nested`)、後者は申告されたスクロール容器の上へ抜けた行(`scrolledOut`)の供給源で、どちらも Simulator 上で誤タップを実測してから採った |
| `sut-` | E2E-CMP(自前) | 契約で盤面が固定された対照 |
| `sutec-` | sut-ec-mobile / iOS 27.0(Simulator・**in-app**) | in-app エンジンの木(それまで1枚も無かった)・画面外中心(`offscreen`)の供給源・下部バーの遮蔽。**接頭辞は OS を表すだけ**なので、同じ sut-ec-mobile の Android 実機キャプチャは `sutec-` ではなく `and-sutec_home` に載る(`and-` = Android の意味を守るため) |

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

**2026-08-15 に足した1枚**(**外部評価者から受け取った**唯一のフィクスチャ):

| ファイル | アーキタイプ | 由来 | 何を代表するか |
|---|---|---|---|
| `ios-browser_yahoo_top` | browser | iOS Safari(Yahoo!天気トップ)/ iOS 27.0 Simulator・xcuitest | **要素上限で切り詰められた実 web ページ**(120 要素・89 件脱落)。代表するのは**自己言及の罠**: この木には `webView` 要素もアドレス欄も**1つも無い**が、同じ画面を `?max=400` で撮ると**両方居る** —— つまり「これは web ページか」の手掛かり自体が上限で落ちている。木の中身で判定する検出器は**切り詰めがひどいほど効かなくなる**(実害: 要素上限の自動撮り直しが2版続けてすり抜けた)。索引形の足場である `#WebView` も同時に消えるので、この1枚は **indexed 0 / unwritable 64** になる |

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

**2026-08-13 の監査ラウンド(長い再利用リスト)で足した1枚**:

| ファイル | アーキタイプ | 由来 | 何を代表するか |
|---|---|---|---|
| `and-apps_list` | dense-list | Android 設定 →「すべてのアプリ」を数画面ぶん送った状態 | **アプリ側が何も公開しない画面**。40 要素すべてが `identifier` を持たず、`scrollable` を申告する要素も1つも無い(型は `Clickable` 14 / `StaticText` 26 だけ)。3つの砦がここで同時に無力になる —— ⑴ **id を前提にした指標が定義すらできない**(前の木の id がどれだけ生き残るかを測る案は `before=0` になる)⑵ **`ft_scroll_to` の逆走査(飛び越しの拾い直し)が走らない**(容器が無いとゲートに入れない)⑶ **scoped index セレクタも書けない**(id を持つ容器が無いので `#container >> .type[n]` の足場が無い)。幾何の検知はほぼ全部0 = **密なリストの陰性対照**でもあり、唯一の `sliver` は画面下端(y 2421 / 画面高 2424)で3pxに切られた行の真陽性 |

**2026-08-13 の監査ラウンド(フォーム / ログイン)で足した1枚**:

| ファイル | アーキタイプ | 由来 | 何を代表するか |
|---|---|---|---|
| `and-form_keyboard` | form | Android 設定 →「ネットワークを追加」で WPA を選び、**キーボードが立ったまま**採取 | **フォームが伸びると操作ボタンがツリーから丸ごと消える**形。`#buttonPanel` は (0,1529 1080x**12**) に潰れ、中身の `保存`/`キャンセル` は**1つも公開されない**(キーボードは y 1541 から)。通常欄(`ph=` と `value` が分離)+ 伏せ字欄 + 有効化条件つきボタンが1画面に揃う唯一の witness。**ただしこれは「行き止まり」ではない** —— `Bench/tasks/and-form-wifi` で測ると **5/5 が完了し、回復はどの run も1手**だった(`ft_scroll_to` に `scrollFrame:"#content_parent"` を添える / `ft_navigate back` でキーボードを閉じる)。**その `#content_parent` はツール自身が `scrollFrameCandidates` で名指ししている**。採取時に「詰む」と書いたのは**手動プローブが自分の助言に従っていなかった**ため(docs/mcp-audit-rounds.md の取り下げ)。misses 3 は全数検分済みの真陽性で、いずれも**容器の中心が子と子の隙間に落ちる**形(`#type` の中心 y=739.5 が `#ssid` の下端 734 と `#security` の上端 809 の間) |

**2026-08-13 の監査ラウンド(モーダル / ダイアログ)で足した1枚**:

| ファイル | アーキタイプ | 由来 | 何を代表するか |
|---|---|---|---|
| `and-dialog_confirm` | dialog | Android 設定のアプリ情報 →「強制停止」の確認ダイアログ | **背景が a11y から丸ごと落ちる**形(直前の画面は 29 要素 → ダイアログでは 6 要素)。画面の大半が木に無いのに**それが正常**な唯一の witness —— 未表現率だけを根拠にする検知(`missingPageContentNote` が URL バーを条件に入れている理由)を、この形で誤発火させないための陰性対照。**幾何の検知も注記も全項目0**で、実アプリで「何も出ない」ことの供給源でもある |

**2026-08-14 の監査ラウンド(append-on-scroll の本物)で足した1枚。コーパス初の実機**:

| ファイル | アーキタイプ | 由来 | 何を代表するか |
|---|---|---|---|
| `ios-news_feed` | feed | **iPhone 15 Pro(実機)/ iOS 26.6** の SmartNews・フィード先頭(xcuitest) | **実アプリのフィード**。実機由来のフィクスチャはこれが1枚目。代表するのは2つで、どちらも自前 SUT に無い —— ⑴ **行が画面幅いっぱい**(`0,y 393xH`)。SUT の行はすべてインセットなので、**全幅でだけ壊れる幾何**を代表していなかった(この形で `emptyDragEndX` が矩形から出られず、`scrollTo` が見つけた記事を**タップしていた**実バグを 2026-08-14 に修正)⑵ **画面外の行 65 件が全部 `(0,103)` にクランプされて木に載る**(120 件中・35 件打ち切り)。`compose-ios-ax-frame-clamp` と同型が UIKit の実アプリで出る。**原点は同じでも大きさが違う**ので、`stackedRefs`(矩形の完全一致が3個以上)は 42 件にしか印を付けず **23 件が無印**で残る = 死角の供給源。無印の行は `overlay`(52 件)側では警告されるが、**名指しする相手が同じくクランプされた別の幽霊**になる(実体は上部カルーセル)|

**2026-08-15 の監査ラウンド(ブラウザ・格子)で足した1枚**:

| ファイル | アーキタイプ | 由来 | 何を代表するか |
|---|---|---|---|
| `and-browser_error_page` | browser | Chrome / `https://nonexistent.invalid/`(`DNS_PROBE_FINISHED_NXDOMAIN`) | **ページが viewport に収まりきり、木がそれを全部公開している**形。`webViewGapNote` がここで **1616px(可視容器の 75%)を2本の帯として「木が落としているかもしれない」と警告していた誤検知の witness** —— スクリーンショットで確かめると帯は本当に空(上はエラーアイコンだけ・下は白紙)で、描かれているテキストは1つ残らず木に在る。**Chrome の既定のエラー画面なのでどの利用者も踏む**。`TreeCoverage.pageExtendsBeyondViewport` の陰性対照で、この webView は**スクロール容器を申告せず `offscreen` も0**(実ページ側は Android が `scrollable=true`・iOS が `offscreen` 103〜120 件)。幾何の検知は overlay=1 だけで、それも**既知クラスの誤検知** —— ホスト名の span `nonexistent.invalid` (63,900 312x47) が、それを含む文 ` にタイプミスがないか確認してください。` (63,900 955x110) に囲まれる = `ios-safari_article` で 10 件受理済みの「折り返す inline テキスト」と同じ形 |

**2026-08-15 の監査(gridWithoutHeaderNote の誤検知)で足した対**(**同じページを両OSで採った対**):

| ファイル | アーキタイプ | 由来 | 何を代表するか |
|---|---|---|---|
| `ios-browser_j1_standings` | browser | Safari / `jleague.jp/standings/j1/`(J1順位表) | **`gridWithoutHeaderNote` の実アプリ誤検知の witness**。検出された 7x2 格子の最上行そのものが列見出し(「順位/クラブ/勝点/試合/勝/分/負/得点」)なのに、room 比のガード(直上の空き=120 / pitch=46 = 2.6倍)だけでは「見出しが抜けた」と誤読していた ——空きの正体は見出しとは無関係の別要素(「Ｊ１」「2026/27」セレクタ)が iOS 側の a11y から落ちている形で、両者は無関係。**同じ木は `webViewGapNote` の真陽性 witness でもある** —— そのセレクタは Android 側の木には在る(下の対で確認できる)ので、iOS だけが本当に公開していない |
| `and-browser_j1_standings` | browser | Chrome / **同じ URL・同じページ** | 上の Android 側。6x2 @ y=1318 で同型の誤検知(最上行「勝点/試合/勝/分/負/得点」が見出しそのもの)。「Ｊ１」「2026/27」セレクタは木に在る = iOS 側だけがそれを a11y から落としていることの対照 |

**2026-08-16 の外部評価(赤羽→立川の乗換案内)で足した対**(**同じ画面の2状態**。
「ft_snapshot の出力が非常に長い」という指摘を、印象ではなく注記の実数で測るための供給源):

| ファイル | アーキタイプ | 由来 | 何を代表するか |
|---|---|---|---|
| `ios-maps_transit_steps` | map | Apple マップ / 経路詳細を**半開きシート**のまま採取(iOS 27.0 Simulator・xcuitest) | **容器の外へ出た行が5つ残る**形。`#TransitDirectionsListView` (8,640 386x226) より上に「出発 / 赤羽駅」の行群(y=554〜639)が居座り、⚠️scroll-leftover が5行に付く —— 評価者が「scroll-leftover が多くノイズ」と言った当人。overlay 1 は浮いている「閉じる」(336,648 42x42)が行の `#DetailButton`(350,640 29x29)の中心を覆う**真陽性**(撃ち分けが本当に曖昧) |
| `ios-maps_transit_steps_expanded` | dense-list | 同じ画面をシート展開まで広げた状態 | **全行が同じ id を共有する密なリスト**(`and-apps_list` = id を1つも持たない密なリスト、の逆の極)。**注記だけで 3,621B = 木(5,658B)の 64%** というコーパス新記録で、内訳は `duplicateIDsNote` 1,810B + `ambiguousLabelsNote` 880B が 74% を占める。**どれも誤検知ではない**(`#DetailButton`×10 `#PrimaryLabel`×8 が実在し、素の `#id` では選べない)= 内容ではなく文面でしか下げられない、の witness。上限を 3200→3700 に上げた記録は `NoteCoverageTests.bytesPerScreenCeiling` |

**展開側は整定を待ってから採ること**(2026-08-16 に踏んだ): グラバーを引いた直後に読むと
`#DetailButton` **だけ**が最終位置より 13〜30pt 下に居る(他の要素は最初から最終位置)。
その一過性の木では overlay が 4 件出て、うち3件は `#PrimaryAccessoryLabel`(時刻)との重なり ——
**整定後は1件**まで減る。連続2回の読みが一致することを確かめてから保存した。
残る1件も **Simulator で実際に撃って裏取りし**、タップは chevron に通った(地図がその停車駅へ
寄ってシートが半開きへ戻った)= `ios-safari_article` の10件と同じ**既知クラスの誤検知**
(装飾の staticText が操作可能要素の中心に重なる形)。

**2026-08-31 の実機監査(Android Compose Scaffold の再配線)で足した1枚**:

| ファイル | アーキタイプ | 由来 | 何を代表するか |
|---|---|---|---|
| `and-sutec_home` | ec | sut-ec-mobile(Android 実機・Jetpack Compose) | **Compose Scaffold の bottomBar が無ラベルで間引かれ、preorder+depth の復元が下部タブをスクロール容器の子に再配線する**形。Android ブリッジは identifier も label も無い `NavigationBar` コンテナを `SnapshotBuilder.shouldInclude` で落とすが、depth の振り直しはしない。結果、木は「タブ5本が `#screen_home`(scrollView)の子として、容器の下端(y=2054)にちょうど接する非交差の行」に見える —— `StepExecutor.isOutsideContainer` と `TapTargetGeometry.outsideDeclaredScroller` の両方がこれを ghost/scrolledOut と誤判定し、DSL の `tap` が無意味な再解決スワイプを繰り返し、`ft_snapshot` が5本とも ⚠️scroll-leftover を出していた(結果 DB で 715 件中 45 件が this)。`StepExecutor.isChromePinnedOutside` の witness で、既存の `sutec-*`(iOS in-app)には無い形 —— あちらは容器の外に単独で浮く行はあっても、**画面の縁に固定された複数要素のバー**という形を持たない |

**採り直すとき**は基準値も一緒に更新する(`SweepHarnessTests.baselines`)。件数が増えたら
まず誤検知を疑い、真陽性だと確かめてから基準値を上げること —— 黙って上げると、
この砦は「現状を追認するだけ」になる。

内容は公開アプリの UI ラベル(店名・広告見出しを含む)。個人データは含まない。

**`ios-news_feed` だけはラベルをマスクしてある**(2026-08-14)。ニュースの見出しと広告コピーが
そのまま残るのを避けたもので、**検知が見ている性質は1つも変えていない**:

- **文字数と UTF-8 バイト数**(注記のバイト量ゲートが見ている。ASCII→ASCII・かな→かな・
  全角数字→全角数字・絵文字→絵文字と、同じバイト幅の文字へ写す)
- **空白と ASCII 記号の位置**(ラベルの区切り構造)/ **数字であること**
- **同一性**(同じラベルは同じに、違うラベルは違うままに。衝突したら添字をずらす)
- **`identifier` は置換しない** —— アプリ内部のビュー id で記事本文でも利用者のデータでもなく、
  `…_articleLinkCell_(null)` という綴り自体がこの盤面の代表する構造(重複 id・`(null)` を含む id)

**検算**: マスク前後で `SweepHarnessTests` / `NoteCoverageTests` / `MCPSelectorDurabilityTests` の
基準値が**1つも動かない**ことを確認済み。次に実文言を含む画面を採るときも同じ規約で落とすこと。
