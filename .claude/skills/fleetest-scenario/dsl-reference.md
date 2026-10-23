# fleetest シナリオの DSL リファレンス

fleetest-scenario スキル(SKILL.md)のステップ3「シナリオ .swift を書く」の直前に読む。正典は docs/design.md §10。

### 構造

- `@TestClass` クラス → `@Test("説明")` メソッド(ID は `S0010` 形式)→ `scenario { }`
  → `scene(n, "題")` → **condition / action / expectation**(CAE)の3層。
  - `condition` = 前提(通常 `launchApp()`)、`action` = 操作、`expectation` = 検証。
  - チェーンで書く: `condition { … }.action { … }.expectation { … }`。不要な層は省略可。
- コマンドは**同期・非 throw のモジュールレベル関数**。`try`/`await`/`{ it in }` 不要。カレント
  コンテキストを暗黙参照する。
- 失敗セマンティクス: コマンド NG → **シナリオ中断**(以降のステップは scene を跨いですべてスキップ。
  throw しない。`afterEach` だけは失敗後でも実行される)。
- `@Deleted("理由")` をクラス/メソッドに付けると論理削除(一括実行から除外・完全一致 ID でのみ実行可)。
- `@Draft("理由")` は実装中(未完成)マーク。除外・実行可否の規則は `@Deleted` と同じで、意味だけが違う
  (Deleted=もう使わない / Draft=これから使う)。`fleetest draft-scenario` の生成物にはこちらが付く。

### コマンド

| 分類 | コマンド |
|---|---|
| タップ/入力 | `tap(sel, waitSeconds:)` / `tap(sel, holdSeconds:)`(長押し)/ **入力は `type(sel, text)` で書く**(探す・焦点を立てる・打つ・読み返すまで1ステップ。前に `tap(sel)` や `select(sel)` を置く `tap(sel); type(text)` / `tap(sel).type(text)` / `select(sel).type(text)` はステップが増えるだけなので生成しない)/ `type(text)`(フォーカス中の欄へ。セレクタで指せない欄だけ)/ `select(sel)`(掴むだけ。**掴めなければ空要素**を返し失敗しない)/ `lastElement`(直前に掴んだ要素。**値は掴んだ時点の凍結値**なので、掴んだ直後に読むときだけ使う。離れた場所で使うなら `let e = select(…)` で受ける) |
| スワイプ/スクロール | `swipe(.up/.down/.left/.right)`(**指の動き**。生のジェスチャ)/ 以下は**コンテンツ基準**(`.down` = 下に読み進める): `scrollTo(sel, direction:, maxSwipes:)` / `scrollDown(repeat:)` `scrollUp` `scrollRight` `scrollLeft` / `scrollToBottom(maxSwipes:)` `scrollToTop` `scrollToRightEdge` `scrollToLeftEdge` / `flickCenterToTop/Bottom/Left/Right` `flickLeftToRight/RightToLeft` `flickBottomToTop/TopToBottom`(画面基点・8種。速い1ストロークの生ジェスチャ) |
| スクロールしながら探す | `tap(sel, scroll: .down)` / `exist(sel, scroll: .down)`(**`tapWithScrollDown` のような関数名の別名は無い** = スクロールの指定は `scroll:` だけ)/ ブロックで囲む `withScrollDown { … }` と、打ち消し: 1コマンドだけなら `scroll: .noScroll`(`exist(sel, scroll: .noScroll)`)・ブロックなら `withoutScroll { … }`。**画像系(`findImage` / `existImage`)は別名が無く `scroll:` だけ** |
| 検証 | セレクタを取るのは `exist(sel)` / `notExist(sel)` / `countIs(sel, 個数)` / `screenLooksLike(画面の説明文)` だけ。**要素の属性検証は「掴んでから」書く**: `select(sel).enabledIsTrue()` / `.enabledIsFalse()` / `.checkIsON()` / `.checkIsOFF()` / `.idIs("…")` / `.imageIs("[ラベル]")`(要素の画像の分類。**プロジェクトの `vision/classifiers/DefaultClassifier/` に見本画像があるときだけ**書く = 無ければ必ず失敗する。見本は `ft_capture_element`(MCP)か `fleetest vision capture` で端末から採り、`fleetest vision check` で点検する)。`verify("説明") { … }` は複数アサーションを1ステップに集約(ブロック内0個なら inconclusive = passed でも failed でもない・シナリオは続行) |
| テキスト・値の検証 | **セレクタは取らない**(対象は直前に掴んだ要素)。`select(sel).textIs("期待値")` と書くか、`select(sel)` の次の行に `textIs("期待値")` を書く(**同義**。`lastElement.textIs(…)` も同じ)。種類は `textIs` `textContains` `textStartsWith` `textEndsWith` `textMatches`(正規表現)`textMatchesDateFormat` `textIsEmpty` `textIsNotEmpty` と、**それぞれの否定** `textIsNot` `textContainsNot` … / `value…` も同名で一式。**これらに `scroll:` は無い**(静止画面の検証用。画面外は先に `scrollTo`) |
| 画面に依らない値の検証 | `thisIs` `thisIsNot` `thisIsTrue` `thisContains` `thisMatchesDateFormat` `thisIsGreaterThan` …(API 応答・計算結果に直接生える。失敗は1ステップとして記録される) |
| アプリ制御 | `launchApp(bundleID?)` / `restartApp()` / `terminateApp()` / `home()` / `appSwitcher()` / `installApp(path?)` / `removeApp(id?)` / `appIs(id, waitSeconds:)` / `tapAppIcon(name?)`(ホーム画面のアイコンをタップ。省略時はプロファイルの appName) |
| 待機/分岐 | `wait(秒)` / `waitForDisplay(sel, waitSeconds:)`(表示まで待つ。スクロールしない)/ `waitForClose(sel, waitSeconds:)`(消えるまで待つ。スクロールしない)/ `ifCanSelect(sel, waitSeconds:) { … }.ifElse { … }` / `ios { }` / `android { }` / `procedure("名") { try await … }` |
| 反復 | `repeatWhileCanSelect(sel, maxLoopCount: n) { … }`(解決できる限り繰り返す。上限到達は失敗にしない)/ `doUntilTrue("名", waitSeconds:) { 条件 }`(**アプリ・外部の状態待ち専用**。要素の出現待ちは各コマンドの `waitSeconds:`) |
| 割り込み | `irregularHandler("#promo_modal", dismiss: "#btn_close")` を beforeEach で宣言すると、出るか不定の**アプリ内メッセージ**を出た時点で自動的に閉じる(OS のダイアログはツール側が吸収するので書かない)。**そのモーダル自体を検証・操作したい区間**では `suppressHandler { … }`(1つの CAE ブロックの内側)か `disableHandler()` … `enableHandler()`(**CAE を跨ぐとき**)で自動クローズを止める |
| まとまり | `group("ログイン") { … }`(記録に `[ログイン]` を前置するだけ。実行・失敗の扱いは素の列と同じ) |
| テストデータ・外部 API | `account("[user1].password")` / `data("[order1].item")`(Shirates と同じ。値は `TestProjects/<proj>/dataset/accounts.json`・`data.json` に `{ "[user1]": { "id": "…", "password": "…" } }` の形で置き、その Mac の `~/.config/fleetest/dataset/<proj>/` の同名ファイルが属性単位で上書きする。dry-run はキーをそのまま返す)/ `dataFile("csv/users.csv")`(キーと値で表せない CSV・JSON・画像の `URL`。置き場は同じ `dataset/`・マシン側はファイル単位で差し替え)/ `addMedia("photo.png")`(データセットのフォルダの画像 jpg/jpeg/png/heic/gif・動画 mp4/mov を写真ライブラリへ入れる。iOS Simulator と Android だけ・iOS 実機は失敗・入れたものを消すコマンドは無い)/ `httpRequest(url, method:, headers:, body:, waitSeconds:)`(テストデータを API で準備する。応答の `status` / `text` / `json` を `thisIs` で検証。localhost へはそのまま届く・外部の宛先はその Mac の `sandbox.allowedDomains` に載っているものだけ) |
| 記録 | `screenshot(filename?)`(ファイル名はラベル無し)(現在の画面を撮り、このステップ直後にレポートへ埋め込む) |
| 前後処理 | テストクラスに `func beforeEach()` / `func afterEach()`(引数なし)を書くと各 `@Test` の前後で自動実行 |

- **要素が見つからなければ失敗**(シナリオ中断)。**唯一の例外は `select`**(空要素を返す。`.isEmpty` で分岐)。
  「出るか不定」を表す引数は無いので、アプリ内メッセージは `irregularHandler`、その場限りの分岐は
  `ifCanSelect(sel) { … }` で書く。`waitSeconds:` = ロケータ再試行の上限秒(0=即諦め、省略=約0.7秒)で、
  `ifCanSelect` / `select` の空振り短縮に使う。
- **`wait(秒)` は原則不要**。`tap` はロケータ解決を約0.7秒(`waitSeconds:` でその秒数)まで再試行し、
  `exist`/`textIs`/`valueIs` は既定タイムアウト(5秒・実行プロファイルの `--default-timeout` で上書き)まで
  ポーリング再判定する。要素の**出現待ち**はこれらが暗黙にこなすので、遷移後の `exist` 直前などに
  `wait` を入れても冗長。待ちが足りなければ `exist(sel, waitSeconds:)` / `tap(sel, waitSeconds:)` を上げる。
- **`ifCanSelect` だけは既定で即時判定**(`waitSeconds:0`)。遷移直後に分岐条件を待ちたいときは
  先行 `wait` ではなく `ifCanSelect(sel, waitSeconds:)` を使う(解決できたら即進む)。
- **`type` は Compose Multiplatform / Flutter 等(UIKit の入力欄を持たないアプリ)でもそのまま書いてよい**。
  iOS の既定の inapp モードが Compose を自動判定し、type だけ XCUITest ブリッジ実行に切り替える(tap/exist は
  高速な in-app ブリッジのまま)。Android は常に inapp で type 可。type の前の `tap(入力欄)` は両 OS 共通で入れておく
  (Android inapp のフォーカス確立に必要)。
- **パスワード・アカウントをシナリオに直書きしない**。`account()` で受け取り、値は `dataset/accounts.json` に置く
  (本物のパスワードを git に入れたくないなら、🧑 にその Mac の `~/.config/fleetest/dataset/<proj>/accounts.json` へ
  置いてもらう)。データセットファイルが無ければ、作る前に 🧑 に値を聞く(推測した値を置かない)。
  `account()` の値をレポートで `***` に伏せるのはマシン側の `redactAccountValues` で、**既定は伏せない**。
  `~/.config/fleetest/` はエージェントが書かない(🧑 が書く)
- **ファイル直下に `var` を書かない**(Swift 6 で `is not concurrency-safe` のコンパイルエラー)。各 `@Test` は
  別プロセスで動くので値は持ち越せない。変えない値は `let`、テスト間の受け渡しは `writeMemo` / `readMemo`
- 同じ手順を関数に切り出して使い回してよい(private func。例: 不定ダイアログの `dismiss…IfAny()`)。
- `procedure` は任意 Swift(データ準備等)を1ステップとして記録。throw すると NG 扱いでシナリオ中断。

### セレクタ式(文字列1本・`||` は候補の和)

- `#id` — id 完全一致(最も頑健。可能なら第一候補)
- `ラベル` — label(**完全一致のみ**。完全形 `text=ラベル`)
- `*語*` / `語*` / `*語` — 部分一致 / 前方一致 / 後方一致。**部分一致は必ずこの記法で明示する**
  (素の文字列は完全一致しかしない)。正規表現は `textMatches=^…$`(部分一致。全体一致は `^…$`)
- `.型` / `.型[2]` — 型(+順番、**1 オリジン**。1番目は [1] 省略可)。
  **型名は先頭小文字**(`.button` / `.staticText`)。スナップショットが返す綴りと同じ。
  先頭大文字で書くと実行前に構文エラーになる
- `.型#id` — 型で絞った id(`&&` 合成の短縮形)。型とラベルの併用は `.型&&ラベル`
- `A&&B&&…` — **AND 合成**。属性は `text` `value` `placeholder` `id` `type` `pos` `checked` `enabled`
  (`*語*` 等の一致方法は `textContains=` のように接尾辞で書ける)。
  例: `.textField&&value=太郎` / `.switch&&checked=true` / `*保存*&&.button&&enabled=true`
- `.input` / `.widget` — 型エイリアス(`.input` = textField|secureTextField /
  `.widget` = OS 共通の役割型5つ。役割不明の `clickable` は含まない)
- `祖先 >> 子孫` — **スコープ**。`#list >> .clickable[2]` = `#list` の子孫だけを候補にし、序数もその中で数える
  (画面クロム・スクロール位置で `.型[n]` がずれる問題の対処。多段可)。
  **容器がアプリ側で a11y ツリーに公開されている必要がある**(`#id` と同じ性質の要件で、
  フレームワークの差ではない)。公開されていない/畳まれている容器はスコープに使えないので、
  実スナップショットで「容器が要素として出ている」「行がその子になっている」を確認してから書く
- `基準:rightSwitch` — **相対セレクタ(基準が先・対象が後)**。基準から見てその方向にある候補だけに
  絞る。**id が無い要素を隣のラベルから指す**ための記法(`通知:rightSwitch` = ラベル `通知` と
  同じ行にあるスイッチ)。方向は `right` / `left` / `above` / `below`、型別接尾辞は
  `Button` / `Input` / `Label` / `Image` / `Switch` / `Widget`。
  引数で序数(`数量:right(2)` = 近い順2番目)や任意フィルタ(`#a:below(.button&&項目)`)も書け、
  `見出し:right:belowButton` と連鎖もできる。基準は `<...>` で囲んでもよい(Shirates 正典形。
  `<変更&&.button>:right(数量)`。囲みは任意で、パース結果は囲まない形と同じ)。
  規則は3つだけ:
  ①候補の中心が基準の帯(right/left なら y 範囲、above/below なら x 範囲)に入る
  ②候補の中心が基準の中心よりその方向 ③その中で近い順(同距離はツリー順先頭)。
  **該当が無ければ失敗**する(近いものを勝手に選ばない)。可視要素にのみ有効。
  スコープと併用すると**基準も対象も容器の中**で解決する(`#row >> 数量:rightButton`)
- `=ラベル` — `#` や `.` で始まる**生ラベル**を label として扱うエスケープ
  (`>>` `&&` `:right` `*` を含むラベルもこれで書く)
- **綴り誤り・未対応記法は実行前にエラー**になる(`:near` `:parent` 等の他ツール記法、未知の
  フィルタ名 `textContans=`、型名の `=`、`[abc]`、閉じない括弧)。
  黙ってラベル扱いにはならないので、通れば構文は正しい
- `A||B` — **候補の和集合**(Shirates 準拠)。`tap` は節の順で最初の候補に着地するので
  「id 優先・ラベルは代替」の書き方はそのまま通る。`countIs` は**和の総数**(同じ要素が複数の節に
  当たっても1度だけ)。例: `tap("#login_btn||ログイン||.button")`
- `(a|b)` — **フィルタ内 OR**。`保存||OK` と等価(`.button&&(許可|項目)` のように型と併用できる)。
  相対の引数では括弧を自分で書く(`:right((保存|OK))`)
- `!値` / `属性!=値` — **否定**(`.button&&!キャンセル` = キャンセル以外のボタン)。
  `!#id` `!.型` も可。**否定だけの節は書けない**(「〇〇以外の全要素」は容器まで掴むため)

### セレクタ選定の罠(そのまま踏む。design.md §10 実測)

- **部分一致を安易に使うと誤マッチする**。`"*許可*"` は `"通知を許可"` にも当たる。素の文字列は
  完全一致なので、まず**実 UI の完全ラベル**をスナップショットから採って素で書く。
  部分一致(`*語*`)は動的な文字列を含むときだけにし、一意になる部分文字列を選ぶ。
- **`||英語` フォールバックは英語ロケール機でのみ発火**。ja-JP フリートでは日本語プライマリが唯一の
  頼り。プライマリを対象 OS/ロケールの実ラベルに合わせて維持する(OS 改名で即ハード失敗)。
- **id を一切公開しないアプリ**では label/型でしか指せず、戻る/アイコンボタン等の**無ラベル要素は
  `.型[n]`(順序依存で脆い)でしか指せない**。position で採取し、指定にコメントを添える。id があれば
  頑健なので、テスト容易性の改善提案(主要導線への accessibilityIdentifier 付与)も併せて伝えてよい。
  - **`.型[n]` は画面状態で指す要素が変わる**(一覧では削除ボタン、空表示では別ボタン/タブ 等)。
    容器の id があるなら `#容器 >> .型[n]` でスコープを付けると画面クロムやスクロール位置の影響を切れる。
    破壊的・index 指定の tap は、**意図した状態のみ出るマーカーで `ifCanSelect` ガード**してから撃つ。
  - **件数不定の一括操作は `repeatWhileCanSelect(sel, maxLoopCount: n) { … }`** を使う(セレクタが解決
    できる限り繰り返す。上限到達は失敗にしない)。上限は想定最大件数に合わせる。
- **既定は現在画面のみ**(非スクロール)。折り返しの下にある項目は `tap(sel, scroll: .down)` /
  `exist(sel, scroll: .down)` で探索するか、先に `scrollTo(sel, maxSwipes:)` で送る。
  **テキスト検証(`textIs` 等)は自動でスクロールしない**ので、先に送ってから確認する。
- **`wait` が要るのはアニメーション整定だけ**。要素は在るのにタップ座標がアニメ中でずれる場合
  (メニュー展開・シート表示・表示切替の直後の `tap` 等)に限って `wait(1)` を挟む。**要素の出現待ちには
  使わない**(上記の暗黙ポーリングで足りる。`exist` 前の `wait` は削る)。
- **出るか不定なダイアログは `ifCanSelect` で無害化**(素で tap すると出ない環境で失敗する)。
- **状態を変える操作(表示切替・トグル等)は同一 @Test 内で元に戻す**(他シナリオへ副作用を残さない)。
  特に**実行を跨いで残る保存状態**(登録・作成・変更したデータ等)は、戻さないと次回実行の擬陽性源になる
  (冒頭でリセット、または末尾で削除する)。
- **擬陽性を避ける**: expectation は「その action が起きなければ落ちる」ものにする。実行を跨いで残る状態を
  presence だけで確認すると、前回の残留で緑になり action の失敗を見逃す。**基準化→action→検証**の形にする
  (例: 空にする→空マーカーを確認→追加→存在確認、または件数/合計の**差分**)。**基準化の直後に基準到達を
  必ずアサート**してから action する(リセットが黙って失敗すると擬陽性が戻る)。なお**プロセス終了での
  リセットは効かない/未対応のことがある**(terminate が in-app ドライバで不可等)。アプリ内のリセット手段を
  確立し、実際に空/初期になることを確かめてから使う。
- **状態依存の入口はガードする**: 空状態のみ出る CTA・初回だけの導線・不定の再開画面は `ifCanSelect` で
  分岐して吸収する。前提をコメントで断るだけにしない(条件が崩れると不可解に落ちる)。
- **launchApp が直前画面から再開する**アプリは、一覧/先頭画面へ正規化してから進める
  (`ifCanSelect("#詳細ビュー") { tap("#BackButton") }` 等)。
- **WebView(Web コンテンツ)内は規約が違う**(スナップショットに `.webView` 型が出たらこの画面):
  **`#id`(HTML の `id`)が使えるかは読み取り経路で決まる**。DOM を読める経路(iOS の inapp モード /
  Android のアプリ内 WebView・ブラウザ)と、a11y が id を出す構成(Android WebView 150 以降)では
  使える。**iOS の xcuitest モードでは出ない**(WebKit が HTML id を a11y へ渡さない)。
  id が使えない構成では表示テキスト・`aria-label`・型で指す。**リンクは `.link` と `.staticText` の
  2要素で重複して出る**ので `.link&&ラベル` と型で絞る。**入力欄は `#id||#placeholder の値` の
  2節で書く**のが確実(Android は WebView の版で id と placeholder が入れ替わるため)。
  中身が現れるまで初回は数秒かかることがあるため、**遷移直後の検証は `waitSeconds:` を長めに**
  (実測: 内蔵 HTML で 2〜8 秒。実ページ+通信ならさらに延びる)。id を採取しようとして
  スナップショットに無くても、アプリ側の不備ではなく仕様(改善提案の対象にしない)。

### 命名・配置

- ファイル: `TestProjects/<proj>/scenarios/<日本語可>.swift`(`_Main.swift` は触らない = エントリポイント)。
- クラス名は日本語可。@Test メソッド名 `S0010`/`S0020`/…(10刻み)。実行 ID は `クラス名.メソッド名`。
- 深い階層に置いてよい(`scenarios/Demo/…`)。objc 走査で自動発見される。
