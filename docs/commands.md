# DSL コマンドリファレンス

シナリオ(`Projects/<name>/Scenarios/*.swift`)で使える全コマンドの説明。読者は**シナリオを書く利用者**。
シナリオの構造(`@TestClass` / `@Test` / `scene` / condition-action-expectation)と**セレクタ記法**
(`#id` `ラベル` `*部分一致*` `.型[n]` `&&` `||` `(a|b)` `!` `>>` `:rightSwitch` など)は
README「Swift DSL」章を参照。コマンド名・引数・挙動は Shirates(Classic) に準拠している。

引数の `sel` はセレクタ式(文字列)。ほぼ全コマンドに**型付きセレクタ(`Sel`)版**も併設されている
(`tap(.id("login_btn"))` 等。意味は文字列版と同一)。

## 共通の引数と挙動

| 引数 | 意味 |
|---|---|
| `optional: true` | 要素が見つからなくても失敗にせずスキップする(既定 false。tap / type / press / tapWithoutScroll のみ) |
| `timeout: 秒` | ロケータ解決の再試行上限。**操作系の省略時は約 0.7 秒**、**検証系の省略時は 5 秒**(実行プロファイルの `defaultTimeout` で変更可)。`0` = 初回スナップショットのみ(出るか不定な optional の空振り短縮に) |
| `requireVisible: false` | FM による可視性確認(覆われ・見切れの検出)を省く。既定 true(FM 未配線時は自動で素通り) |
| `scroll: .down` / `maxSwipes:` | 実行前に**その方向へスクロールしながら要素を探す**(後述「スクロール」)。省略時は現在画面のみ |

- **要素の出現待ちは暗黙**。操作は解決を再試行し、検証はタイムアウトまでポーリング再判定するので、
  `exist` の前に `wait` を置くのは冗長。待ちが足りなければ `timeout:` を上げる
- **失敗セマンティクス**: コマンド NG → **シナリオ中断**(以降のステップは scene を跨いですべてスキップ。
  `tearDown` だけは失敗後でも実行される)。ブロック内の**生 Swift コードはスキップされない**
  ため、失敗後に走らせたくない処理は `procedure { }` に包む
- スクロールの方向は**すべてコンテンツ基準**(`.down` = 下に読み進める = 指は上へ動く)。
  **例外は `swipe` だけ**(生のジェスチャなので指の動き)

## 操作

| コマンド | 説明 |
|---|---|
| `tap(sel, optional:timeout:scroll:maxSwipes:)` | タップ |
| `type("文字列")` | **フォーカス中の要素**へ入力(直前に `tap(入力欄)` でフォーカスしてから使う) |
| `type(sel, "文字列", optional:timeout:scroll:maxSwipes:)` | 要素を指定して入力。日本語もそのまま入る(IME 切替なし) |
| `press(sel, duration: 1.0, optional:timeout:scroll:maxSwipes:)` | 長押し(duration は秒) |
| `swipe(.up / .down / .left / .right)` | 画面全体をスワイプ(**指の動き**) |

## スクロール

| コマンド | 説明 |
|---|---|
| `scrollTo(sel, direction: .down, maxSwipes: 8)` | 要素が見つかるまでスクロール(見つかったら成功。タップはしない) |
| `scrollDown(repeat: 1)` / `scrollUp` / `scrollRight` / `scrollLeft` | 1 画面ぶんスクロール(`repeat:` 回繰り返す) |
| `scrollToBottom(maxSwipes: 50)` / `scrollToTop` / `scrollToRightEdge` / `scrollToLeftEdge` | 端まで送る(**画面が変化しなくなるまで**。maxSwipes は暴走を止める上限で、上限で打ち切ったときはステップに注記が付く) |
| `withScrollDown { … }` / `withScrollUp` / `withScrollRight` / `withScrollLeft` | ブロック内の `tap` / `type` / `press` / `exist` を**すべてスクロール探索**にする(明示の `scroll:` があればそちらが優先) |
| `withoutScroll { … }` | 外側の `withScroll*` を打ち消し、ブロック内は現在画面だけで解決する |
| `tapWithScrollDown(sel, maxSwipes:)` 等 4 方向 | `tap(sel, scroll: .down)` の別名(Shirates と同名) |
| `tapWithoutScroll(sel, optional:timeout:)` | `withScroll*` の中でも**この 1 コマンドだけ**スクロールしない |
| `existWithScrollDown(sel, maxSwipes:)` / `existWithScrollUp` | `exist(sel, scroll: .down)` の別名 |
| `existWithoutScroll(sel, timeout:requireVisible:)` | `withScroll*` の中でも現在画面だけで存在検証 |

```swift
tap("設定", scroll: .down)          // 折り返しの下にある項目を探索してからタップ
withScrollDown {
    tap("#row_40")                  // ブロック内は書かなくても探索される
    existWithoutScroll("#header")   // 固定ヘッダは現在画面で確認
}
```

## 存在・状態の検証

| コマンド | 説明 |
|---|---|
| `exist(sel, timeout:requireVisible:scroll:maxSwipes:)` | 存在検証。既定で**実際に見えていること**も確認する。戻り値にチェーン可(後述) |
| `notExist(sel, timeout:)` | **消えるまで待つ**(初回で不在なら即成功)。ダイアログ・ローディングが閉じた確認に |
| `countIs(sel, 個数, timeout:)` | 候補の個数。**ツリー上の件数**で可視性は見ない。`\|\|` は和集合の総数(重複は 1 度だけ)。**ラベルで数えるときは型で絞る**(`.button&&項目` — ボタンと内側のラベルは別要素として両方載るため) |
| `isEnabled(sel)` / `isDisabled(sel)` | 有効/無効の検証(タイムアウトまで状態変化を待つ) |
| `isChecked(sel)` / `isNotChecked(sel)` | チェック状態の検証。iOS はアプリの実装により checked が取れないことがある(取れないままだと run 終了時に警告が出る) |
| `screenIs("画面の説明文")` | FM による**見た目の**画面検証(スクリーンショットと説明文の照合) |

## テキスト・値の検証

`text…` はラベル(表示文字列)、`value…` は入力欄などの値を見る。全コマンド
`(sel, 期待値, timeout:)` の形(肯定形は `requireVisible:` も取る)。

| 肯定 | 否定 | 判定 |
|---|---|---|
| `textIs` / `valueIs` | `textIsNot` / `valueIsNot` | 完全一致 |
| `textContains` / `valueContains` | `textContainsNot` / `valueContainsNot` | 部分一致 |
| `textStartsWith` / `valueStartsWith` | `textStartsWithNot` / `valueStartsWithNot` | 前方一致 |
| `textEndsWith` / `valueEndsWith` | `textEndsWithNot` / `valueEndsWithNot` | 後方一致 |
| `textMatches` / `valueMatches` | `textMatchesNot` / `valueMatchesNot` | 正規表現(**部分一致**。全体一致は `^…$`) |
| `textMatchesDateFormat` / `valueMatchesDateFormat` | — | 日付書式(`"yyyy/MM/dd"` 等・DateFormatter の記法) |
| `textIsNotEmpty` / `valueIsNotEmpty` | `textIsEmpty` / `valueIsEmpty` | 空でない / 空 |

- 要素は在る前提で、**タイムアウトまで値の変化を待つ**(値の変化待ちに使える)
- 否定系と Empty 系は**可視性を見ない**(「見えていないこと」は画面照合できないため)
- **これらに `scroll:` は無い**。静止した画面を詳細に検証するためのもので、条件が揃うまで自動で
  スクロールしてほしくないため。画面外のテキストは先に `scrollTo` で送ってから検証する

`exist` の戻り値には同じ検証をチェーンできる:

```swift
exist("#total")
    .textStartsWith("合計")
    .textEndsWith("円")
    .idIs("total")        // 解決した要素の id 検証
```

チェーンで使えるもの: `.textIs` `.valueIs` `.textStartsWith` `.textEndsWith` `.textIsNot`
`.textIsNotEmpty` `.idIs`。

## 画面に依らない値の検証(thisIs 系)

API 応答・計算結果など**デバイスに触れない値**の検証。文字列・数値・Bool・Optional に直接生え、
失敗すれば他のコマンドと同じく 1 ステップとして記録されシナリオを中断する。

```swift
let 合計 = try await fetchTotal()        // procedure { } 内で取得した値など
合計.thisContains("1,200")
合計.thisStartsWith("合計")
(10 * 3).thisIs(30)
"2026/07/27".thisMatchesDateFormat("yyyy/MM/dd")
在庫数.thisIsGreaterThan(0)
```

| コマンド | 判定 |
|---|---|
| `thisIs(値)` / `thisIsNot(値)` | 一致 / 不一致 |
| `thisIsTrue()` / `thisIsFalse()` | Bool |
| `thisIsEmpty()` / `thisIsNotEmpty()` | 空文字 |
| `thisIsBlank()` / `thisIsNotBlank()` | 空白のみ(空文字も blank) |
| `thisContains(Not)` / `thisStartsWith(Not)` / `thisEndsWith(Not)` | 部分・前方・後方一致 |
| `thisMatches(Not)` / `thisMatchesDateFormat` | 正規表現 / 日付書式 |
| `thisIsGreaterThan(OrEqual)` / `thisIsLessThan(OrEqual)` | 数値比較(数値に解釈できなければ失敗) |

## アプリ・OS 操作

| コマンド | 説明 |
|---|---|
| `launchApp(bundleID?)` | 起動(省略時は `@TestClass(app:)` のアプリ)。起動済みなら前面化 |
| `relaunchApp(bundleID?)` | 終了してから起動(プロセス内状態のリセットに) |
| `terminateApp()` | 終了 |
| `home()` | ホーム画面へ |
| `appSwitcher()` | アプリスイッチャーを開く |

## 待機・分岐・反復

| コマンド | 説明 |
|---|---|
| `wait(秒)` | 固定待ち。**要素の出現待ちには使わない**(暗黙待ちで足りる)。出番はセレクタで待てない整定(アニメ中の座標ずれ等)だけ |
| `ifCanSelect(sel, waitSeconds: 0) { … }.ifElse { … }` | セレクタが解決できたらブロック実行。**既定は即時 1 回判定**(待つなら `waitSeconds:`)。出るか不定のダイアログの無害化に |
| `ios { … }` / `android { … }` | 対象 OS のときだけ実行 |
| `repeatWhileCanSelect(sel, max: 10, waitSeconds: 0) { … }` | セレクタが解決できる限り繰り返す(件数不定の一括操作に)。上限到達は失敗にしないが記録に残る |
| `doUntilTrue("説明", waitSeconds: 10, intervalSeconds: 0.5, maxLoopCount: 100) { 条件 }` | 条件(`() async throws -> Bool`)が true になるまで繰り返す。**アプリ・外部の状態待ち専用**(要素の出現待ちは各コマンドの `timeout:`)。throw したらリトライせず即 NG |

## 構造化・前後処理・割り込み

| コマンド | 説明 |
|---|---|
| `group("名前") { … }` | 記録に `[名前]` を前置するだけのまとまり(実行・失敗の扱いは素の列と同じ) |
| `procedure("説明") { try await … }` | 任意の Swift(データ投入等)を 1 ステップとして記録。throw は NG としてシナリオ中断 |
| `func setUp()` / `func tearDown()` | テストクラスに書くと各 `@Test` の前後で自動実行。**tearDown は失敗後でも実行される** |
| `irregularHandler(検出sel, dismiss: 閉じるsel?)` | **出るか不定のアプリ内メッセージ**(お知らせ・キャンペーン)を宣言すると、以降どのステップでも出た時点で自動的に閉じる。`dismiss` 省略時は検出したものをタップ。setUp で 1 回宣言するのが定石。**OS 側のダイアログは書かなくてよい**(ツール側で吸収する)。閉じたことはステップの注記に残る |

```swift
func setUp() {
    irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
}
```
