# DSL コマンドリファレンス

シナリオ(`Projects/<name>/Scenarios/*.swift`)で使える全コマンドの説明。読者は**シナリオを書く利用者**。
シナリオの構造(`@TestClass` / `@Test` / `scene` / condition-action-expectation)と**セレクタ記法**
(`#id` `ラベル` `*部分一致*` `.型[n]` `&&` `||` `(a|b)` `!` `>>` `:rightSwitch` など)は
README「Swift DSL」章を参照。コマンド名・引数・挙動は Shirates(Classic) に準拠している。

引数の `sel` はセレクタ式(文字列)。**セレクタを取る全コマンドに型付きセレクタ(`Sel`)版が併設**
されている(`tap(.id("login_btn"))` 等。意味・記録・ヒールは文字列版と同一で、`tapWithScrollDown`
`existWithoutScroll` のような別名族も両方で書ける)。

## 共通の引数と挙動

| 引数 | 意味 |
|---|---|
| `optional: true` | 要素が見つからなくても失敗にせずスキップする(既定 false。tap / type / press / tapWithoutScroll / select のみ) |
| `timeout: 秒` | ロケータ解決の再試行上限。**小数可**(`timeout: 1.2`)。**操作系の省略時は約 0.7 秒**、**検証系の省略時は 5 秒**(実行プロファイルの `defaultTimeout` で変更可。これも小数可)。`0` = 初回スナップショットのみ(出るか不定な optional の空振り短縮に) |
| `requireVisible: false` | FM による可視性確認(覆われ・見切れの検出)を省く。**`exist` は覆われていると失敗へ反転し、`select` は空要素を返す**(意味が違う)。既定 true だが、FM 照合が実際に走るのは実行プロファイルで `falsePositiveCheck: true`(既定 false)にした run のみ(FM 未配線時・`fm:false` 時も自動で素通り) |
| `scroll: .down` / `maxSwipes:` | 実行前に**その方向へスクロールしながら要素を探す**(後述「スクロール」)。省略時は現在画面のみ |

- **要素の出現待ちは暗黙**。操作は解決を再試行し、検証はタイムアウトまでポーリング再判定するので、
  `exist` の前に `wait` を置くのは冗長。待ちが足りなければ `timeout:` を上げる
- **失敗セマンティクス**: コマンド NG → **シナリオ中断**(以降のステップは scene を跨いですべてスキップ。
  `tearDown` だけは失敗後でも実行される)。ブロック内の**生 Swift コードはスキップされない**
  ため、失敗後に走らせたくない処理は `procedure { }` に包む
- **1 コマンド(1 ステップ)の壁時計上限は 120 秒**。超えると NG になり、**その処理はキャンセルされる**
  (途中で止まる。放置すると諦めたはずの操作が後続ステップの最中に効いてしまうため)。
  効くのは `procedure { }` / `doUntilTrue` / `wait` のような長い処理で、
  **`doUntilTrue(waitSeconds:)` にこれより長い値を書いても待てない**。
  長い処理はステップを分けるか、外部プロセスに逃がして完了だけを待つ形にする
- スクロールの方向は**すべてコンテンツ基準**(`.down` = 下に読み進める = 指は上へ動く)。
  **例外は `swipe` だけ**(生のジェスチャなので指の動き)

## 操作

| コマンド | 説明 |
|---|---|
| `tap(sel, holdSeconds: 0, optional:timeout:scroll:maxSwipes:)` | タップ。`holdSeconds` を 0 より大きくすると長押し(既定 0 = 通常タップ) |
| `select(sel, optional:timeout:requireVisible:scroll:maxSwipes:)` | 要素を**掴むだけ**(デバイス操作なし)。`exist` と違い**検証ではない**ので、レポートに検証ステップとして残らない。値の読み出し(`.text`/`.value`/`.id`)や検証コマンドへのチェーンの起点に使う。**見つからない**と失敗(無視したいときは `optional: true` = Shirates の `throwsException: false` 相当)。**見つかったが見えない**(覆われ・見切れ)ときは**失敗させず空要素を返す** — 呼び出し側は `.isEmpty` で分岐できる(`exist` は失敗へ反転するので意味が違う)。`requireVisible: false` で可視性照合自体を外す |
| `type("文字列")` | **フォーカス中の要素**へ入力(直前に `tap(入力欄)` でフォーカスしてから使う)。改行の扱いは下記 |
| `type(sel, "文字列", optional:timeout:scroll:maxSwipes:)` | 要素を指定して入力。日本語もそのまま入る(IME 切替なし)。改行の扱いは下記 |
| `pressEnter()` | フォーカス中の入力へ Enter/IME アクション(検索・実行・改行)を発火(Shirates(Classic) 準拠) |
| `hideKeyboard()` | ソフトキーボードを閉じる。**Android のみ**(出ているときだけ戻るキーを撃つので冪等)。**iOS は未対応で失敗する** — iOS で閉じたいときは `pressEnter()` を使う(単一行の欄なら閉じる) |
| `clearInput()` | フォーカス中の入力欄を空にする |
| `clearInput(sel, optional:timeout:scroll:maxSwipes:)` | 要素を指定して入力欄を空にする(`type` は追記なので、書き換えるならまず `clearInput`)。**Flutter の iOS は in-app エンジンでは消せず XCUITest 経由になる**(自動フォールバック。1〜2秒かかる) |
| `swipe(.up / .down / .left / .right)` | 画面全体をスワイプ(**指の動き**) |
| `swipePointToPoint(startX:startY:endX:endY:durationSeconds: 1.5)` | 2点間ドラッグ(座標は snapshot の screen と同じ座標系。iOS = pt / Android = px) |
| `swipeElementToElement(開始sel, 終点sel, durationSeconds: 1.5)` | 要素間のドラッグ(スライダー・並べ替え・部分領域のドラッグ用)。**終点はヒール対象外**(始点だけがヒール・フォールバック連鎖を持つ) |

**`type` の中の `\n`**: **OS 既定の挙動**になる。iOS は Return キー押下として届くので、
複数行の欄なら改行が入り、単一行の欄なら確定アクション(検索・完了など)が発火する
= **どちらになるかはフィールドが決める**。Android も末尾の改行は Enter として送る。
**確定アクションを撃つ意図なら `pressEnter()` を使う**(意図が読み手に伝わる。
`type("腕時計\n")` は「改行を入れたいのか送信したいのか」がコードから読めない)。
エンジン(in-app / XCUITest)によって結果が変わることはない(docs/design.md)。

## スクロール

| コマンド | 説明 |
|---|---|
| `scrollTo(sel, direction: .down, maxSwipes: 8)` | 要素が見つかるまでスクロール(見つかったら成功。タップはしない) |
| `scrollDown(repeat: 1)` / `scrollUp` / `scrollRight` / `scrollLeft` | 1 画面ぶんスクロール(`repeat:` 回繰り返す) |
| `scrollToBottom(maxSwipes: 50)` / `scrollToTop` / `scrollToRightEdge` / `scrollToLeftEdge` | 端まで送る(**画面が変化しなくなるまで**。maxSwipes は暴走を止める上限で、上限で打ち切ったときはステップに注記が付く) |
| `withScrollDown { … }` / `withScrollUp` / `withScrollRight` / `withScrollLeft` | ブロック内の `tap` / `type` / `press` / `exist` を**すべてスクロール探索**にする(明示の `scroll:` があればそちらが優先) |
| `withoutScroll { … }` | 外側の `withScroll*` を打ち消し、ブロック内は現在画面だけで解決する |
| `tapWithScrollDown(sel, maxSwipes:)` 等 4 方向 | `tap(sel, scroll: .down)` の別名(Shirates と同名) |

レポートに出る注記(**失敗ではなく観測**。読み方):

| 注記 | 意味 | 気にするべきか |
|---|---|---|
| `stopped at the limit of N (may not have reached the edge yet)` | `maxSwipes` で打ち切った = 端に着いたとは限らない | **する**。`maxSwipes` を増やすか、そもそも端に着けない画面かを疑う |
| `the screen did not settle (poll limit)` | スワイプ後 600ms 待っても画面の動きが止まらなかった(慣性が長い等)。操作自体は送られている | 通常は不要。**同じ箇所で毎回出るなら**、静止前の座標でタップして flake る余地があるので調べる価値がある |
| `fell back to XCUITest` | in-app エンジンで実行できずフォールバックした(1回あたり数百 ms 遅い) | 通常は不要。多発するなら実行プロファイルのエンジン選択を見直す |
| `tapWithoutScroll(sel, optional:timeout:)` | `withScroll*` の中でも**この 1 コマンドだけ**スクロールしない |
| `existWithScrollDown(sel, maxSwipes:)` / `existWithScrollUp` | `exist(sel, scroll: .down)` の別名 |
| `existWithoutScroll(sel, timeout:requireVisible:)` | `withScroll*` の中でも現在画面だけで存在検証 |
| `selectWithScrollDown(sel, maxSwipes:)` 等 4 方向 | `select(sel, scroll: .down)` の別名(Shirates と同名) |
| `selectWithoutScroll(sel, optional:timeout:requireVisible:)` | `withScroll*` の中でも現在画面だけで解決する `select` |

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
| `exist(sel, timeout:requireVisible:scroll:maxSwipes:)` | 存在検証。偽陽性検証を有効にした run(実行プロファイル `falsePositiveCheck: true`)では**実際に見えていること**も確認する。戻り値にチェーン可(後述) |
| `notExist(sel, timeout:scroll:maxSwipes:)` | **消えるまで待つ**(初回で不在なら即成功)。ダイアログ・ローディングが閉じた確認に。`scroll:` 指定時は**その方向へスクロールしながら探し、見つかった時点で不在検証を失敗させる**(`exist(scroll:)` の裏返し。見つからなければ従来どおり現在のビューポートでの消滅待ちに進む) |
| `countIs(sel, 個数, timeout:)` | 候補の個数。**ツリー上の件数**で可視性は見ない。`\|\|` は和集合の総数(重複は 1 度だけ)。**ラベルで数えるときは型で絞る**(`.button&&項目` — ボタンと内側のラベルは別要素として両方載るため) |
| `isEnabled(sel)` / `isDisabled(sel)` | 有効/無効の検証(タイムアウトまで状態変化を待つ) |
| `isChecked(sel)` / `isNotChecked(sel)` | チェック状態の検証。iOS はアプリの実装により checked が取れないことがある(取れないままだと run 終了時に警告が出る) |
| `keyboardIsShown(timeout:)` / `keyboardIsNotShown(timeout:)` | ソフトキーボードの表示/非表示の検証。開閉はアニメーションを伴うためタイムアウトまでポーリングする |
| `screenIs("画面の説明文")` | FM による**見た目の**画面検証(スクリーンショットと説明文の照合)。実行プロファイルで `fm:false` / `screenIs:false` の場合はスキップ(素通り) |

> `screenIs` と偽陽性検証(`requireVisible` / `falsePositiveCheck`)は FM に画像を渡すため
> **macOS 27+ が必要**。macOS 26 では自動でスキップ/素通りになる(現在の可否は `ftester doctor`)。

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

**セレクタを取って「その要素」を検証するコマンドはすべてチェーンできる**（`textIs` / `textContains` /
`textMatches` などテキストの全対称、`valueIs` 以下の value の全対称、`isEnabled` / `isDisabled` /
`isChecked` / `isNotChecked`、それに掴んだ要素の id を見る `.idIs`）。引数は自由関数版と同じです。

チェーンできないのは**要素を1つに定めないコマンド**だけです（`notExist` / `countIs` / `screenIs`）。
これらは掴んだ要素に対する検証ではないためです。

### 掴んだ要素の値を読む(`.text` / `.value` / `.id`)

`exist` の戻り値からは**値そのもの**も取り出せる。期待値をシナリオに書き切れないとき
(注文番号を控えて後の画面で照合する・画面に出ている合計を計算に使う)に使う。

```swift
var 注文番号: String?

scene(2, "注文を確定して注文番号を控える") {
    action { tap("#btn_order") }
    .expectation {
        textStartsWith("#txt_order_id", "注文番号:")   // ← 先に**値を確定させてから**読む
        注文番号 = exist("#txt_order_id").text
    }
}
scene(3, "確認画面にも同じ注文番号が出る") {
    action { tap("#tab_orders") }
    .expectation { textIs("#txt_confirm_order_id", 注文番号 ?? "") }
}

exist("#txt_total").text.thisContains("1,200")   // thisIs 系へそのまま繋がる
```

- 値は **`exist` が照合した時点のもの**で、`.text` を読んでも**画面を取り直さない**
  (追加のデバイス往復もステップ記録も発生しない)。最新の値が要るなら `exist` を書き直す
- **更新途中の画面をいきなり読まない**。要素自体は先に存在するので `exist` は即座に成功し、
  **古い値を掴む**。上の例のように `textIs` / `textStartsWith` 等で値を確定させてから読む
- **要素を掴めなかったとき・失敗後にスキップされたとき・dry-run では nil**
  (「掴めなかったのに値が読める」状態を作らないため)
- **掴めたかどうかは `.isEmpty` / `.isNotEmpty` で見る**(Shirates の `TestElement.isEmpty` 相当)。
  `.text == nil` で代用しない — **ラベルを持たない要素を掴んだとき**に「空」と誤判定する

```swift
let e = select("#txt_total")
if e.isNotEmpty { 合計 = e.text }   // 見えていなければ空要素なので読まない
```

- `.text` は要素の表示テキスト(ラベル)、`.value` は値、`.id` は identifier
- **検証したくない(レポートに検証ステップを残したくない)ときは `exist` の代わりに `select` を使う**。
  `select` は掴むだけで可視性照合の対象にもならない。使い方は同じ(`select("#txt_total").text`)

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
| `restartApp(bundleID?)` | 終了してから起動(プロセス内状態のリセットに) |
| `terminateApp()` | 終了 |
| `clearAppData(bundleID?)` | アプリは残しデータだけ消す(再インストール不要)。初回起動・オンボーディング・権限ダイアログの再現に使う。**権限(iOS の TCC / Android の実行時権限)も未許可へ戻す**ので、権限ダイアログが再び出る。**iOS はシミュレータ専用**(実機は失敗する)。Android は `pm clear` 相当。**キーチェーン(iOS)/ Keystore(Android)に置いた値は消えない** — オンボーディング判定をそこに置いているアプリは初回起動が再現しない |
| `home()` | ホーム画面へ |
| `back()` | 前の画面へ戻る(Android = 戻るキー / iOS = 左端エッジスワイプ)。**Android はキーボードが開いていると1回目がキーボードを閉じるのに消費される**(OS 仕様)。**iOS はスワイプバック対応のナビゲーション(NavigationStack 等)を持つ画面でのみ戻れる**(独自ナビのアプリには効かない。アプリ内の戻るボタンを `tap` する) |
| `appSwitcher()` | アプリスイッチャーを開く |

## 待機・分岐・反復

| コマンド | 説明 |
|---|---|
| `wait(秒)` | 固定待ち。**要素の出現待ちには使わない**(暗黙待ちで足りる)。出番はセレクタで待てない整定(アニメ中の座標ずれ等)だけ |
| `ifCanSelect(sel, waitSeconds: 0) { … }.ifElse { … }` | セレクタが解決できたらブロック実行。**既定は即時 1 回判定**(待つなら `waitSeconds:`。小数可)。出るか不定のダイアログの無害化に |
| `ios { … }` / `android { … }` | 対象 OS のときだけ実行 |
| `repeatWhileCanSelect(sel, max: 10, waitSeconds: 0) { … }` | セレクタが解決できる限り繰り返す(件数不定の一括操作に)。上限到達は失敗にしないが記録に残る |
| `doUntilTrue("説明", waitSeconds: 10, intervalSeconds: 0.5, maxLoopCount: 100) { 条件 }` | 条件(`() async throws -> Bool`)が true になるまで繰り返す。**アプリ・外部の状態待ち専用**(要素の出現待ちは各コマンドの `timeout:`)。throw したらリトライせず即 NG。`waitSeconds` は下記の 120 秒上限を超えられない |

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
