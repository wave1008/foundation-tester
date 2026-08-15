# DSL コマンドリファレンス

シナリオ(`TestProjects/<name>/scenarios/*.swift`)で使える**操作・検証コマンド**の説明。読者は**シナリオを書く利用者**。
**構造コマンド**(`scenario` / `scene` / `condition` / `action` / `expectation`)と**セレクタ記法**
(`#id` `ラベル` `*部分一致*` `.型[n]` `&&` `||` `(a|b)` `!` `>>` `:rightSwitch` など)は
README「Swift DSL」章を参照。コマンド名・引数・挙動は Shirates(Classic) に準拠している。

引数の `sel` はセレクタ式(文字列)。**対象セレクタを取る全コマンドに型付きセレクタ(`Sel`)版が併設**
されている(`tap(.id("login_btn"))` 等。意味・記録・ヒールは文字列版と同一で、`tapWithScrollDown`
`existWithoutScroll` のような別名族も両方で書ける)。**例外は `scrollFrame:` 引数で、こちらは
文字列のみ**(`scrollDown(scrollFrame: "#list")`。`Sel` 版のコマンドでも同じ)。

## 共通の引数と挙動

| 引数 | 意味 |
|---|---|
| `timeout: 秒` | ロケータ解決の再試行上限。**小数可**(`timeout: 1.2`)。**操作系の省略時は約 0.7 秒**、**`select` と検証系の省略時は 5 秒**(実行プロファイルの `defaultTimeout` で変更可。これも小数可)。`0` = 初回スナップショットのみ(出るか不定な要素を `ifCanSelect` で見るときの空振り短縮に) |
| `requireVisible: false` | FM による可視性確認(覆われ・見切れの検出)を省く。**`exist` は覆われていると失敗へ反転し、`select` は空要素を返す**(意味が違う)。既定 true だが、FM 照合が実際に走るのは実行プロファイルで `falsePositiveCheck: true`(既定 false)にした run のみ(FM 未配線時・`fm:false` 時も自動で素通り) |
| `scroll: .down` / `maxSwipes:` | 実行前に**その方向へスクロールしながら要素を探す**(後述「スクロール」)。省略時は現在画面のみ |

- **要素が見つからなければ失敗**(シナリオ中断)。**唯一の例外は `select`** で、掴めなければ
  失敗させず空要素を返す(`.isEmpty` で分岐する)。**「出るか不定」を表す引数は無い** —
  出るか不定のアプリ内メッセージは `irregularHandler` を setUp で宣言し、
  その場限りの条件分岐は `ifCanSelect(sel) { … }` で包む
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
| `tap(sel, holdSeconds: 0, timeout:scroll:maxSwipes:containerInference:)` | タップ。`holdSeconds` を 0 より大きくすると長押し(既定 0 = 通常タップ)。`containerInference:` は下記「容器の推測に依存する補正」参照 |
| `select(sel, timeout:requireVisible:scroll:maxSwipes:)` | 要素を**掴むだけ**(デバイス操作なし)。`exist` と違い**検証ではない**ので、レポートに検証ステップとして残らない。値の読み出し(`.text`/`.value`/`.id`)や検証コマンドへのチェーンの起点に使う。**掴めなければ失敗させず空要素を返す** — 「見つからない」も「見つかったが見えない(覆われ・見切れ)」も同じ形で返るので、呼び出し側は `.isEmpty` で分岐する(`exist` はどちらも失敗へ反転するので意味が違う)。**在ることを保証したいなら `exist`**。`requireVisible: false` で可視性照合自体を外す |
| `lastElement` | **直前に掴んだ要素**(引数なし。Shirates(Classic) の `TestDriver.lastElement` 相当)。要素を1つに定めて解決したコマンド(`select` / `exist` / `tap` / `type` / `waitForDisplay` / テキスト・値の検証など)が通るたびに差し替わる。差し替えないのは**要素を1つに定めない** `notExist` / `countIs` と、**セレクタを取らない** `swipe` / `launchApp` 等。**値は掴んだ時点の凍結値**で、掴んだ後にスクロールやタップを挟むと古い値を読む(下記「掴んだ要素の値を読む」)。**scene を跨ぐと空**・**掴めなかったコマンドは空で上書き**・**一度も掴んでいなければ空+警告** |
| `type("文字列", replace: false)` | **フォーカス中の要素**へ入力(直前に `tap(入力欄)` でフォーカスしてから使う)。改行の扱いは下記。**引数はテキストであってセレクタではない** — `type("#email")` のようにセレクタらしい1語(`#` + 識別子・`\|\|` や `>>` を含む)を渡すと実行前に失敗する(黙って `#email` と打ち込んで後段の検証で落ちると原因から遠いため)。その文字列を本当に入力したいなら2引数形 `type("#field", "#email")` を使う。`replace: true` で撃つ前に `clearInput` 相当のクリアをしてから入力する(セレクタ解決が1回で済む) |
| `type(sel, "文字列", timeout:scroll:maxSwipes:replace:)` | 要素を指定して入力。日本語もそのまま入る(IME 切替なし)。改行の扱いは下記。`replace: true` で撃つ前にクリアしてから入力する(下記 `clearInput` 参照) |
| `pressEnter()` | フォーカス中の入力へ Enter/IME アクション(検索・実行・改行)を発火(Shirates(Classic) 準拠) |
| `hideKeyboard()` | ソフトキーボードを閉じる。**Android のみ**(出ているときだけ戻るキーを撃つので冪等)。**iOS は未対応で失敗する** — iOS で閉じたいときは `pressEnter()` を使う(単一行の欄なら閉じる) |
| `clearInput()` | フォーカス中の入力欄を空にする |
| `clearInput(sel, timeout:scroll:maxSwipes:)` | 要素を指定して入力欄を空にする(`type` は追記なので、書き換えるならまず `clearInput`。セレクタ解決を1回で済ませたいだけなら `type(sel, "文字列", replace: true)` で1コマンドに畳める)。**Flutter の iOS は in-app エンジンでは消せず XCUITest 経由になる**(自動フォールバック。1〜2秒かかる) |
| `swipe(.up / .down / .left / .right)` | 画面全体をスワイプ(**指の動き**) |
| `swipePointToPoint(startX:startY:endX:endY:durationSeconds: 1.5)` | 2点間ドラッグ(座標は snapshot の screen と同じ座標系。iOS = pt / Android = px) |
| `swipeElementToElement(開始sel, 終点sel, durationSeconds: 1.5)` | 要素間のドラッグ(スライダー・並べ替え・部分領域のドラッグ用)。**終点はヒール対象外**(始点だけがヒール・フォールバック連鎖を持つ) |
| `swipeBy(sel?, dxRatio:dyRatio:durationSeconds: 1.5)` | 対象の中心から**比率**で指を動かす(**斜め可**。両方を非 0 にすると対角)。比率は対象の幅・高さに対する割合で、符号は指の向き。セレクタ省略 = 画面全体 |
| `doubleTap(sel?)` | ダブルタップ。セレクタ省略 = 画面中心。**`tap` を2回書いても代用できない**(往復で OS のダブルタップ判定時間を超える) |
| `pinchOut(sel?, scale: 2.0, durationSeconds: 0.5)` | 2本指を開く = **拡大**。`scale` は 1 より大きい値のみ |
| `pinchIn(sel?, scale: 0.5, durationSeconds: 0.5)` | 2本指を閉じる = **縮小**。`scale` は 0 より大きく 1 未満のみ |

**`type` の中の `\n`**: **OS 既定の挙動**になる。iOS は Return キー押下として届くので、
複数行の欄なら改行が入り、単一行の欄なら確定アクション(検索・完了など)が発火する
= **どちらになるかはフィールドが決める**。Android も末尾の改行は Enter として送る。
**確定アクションを撃つ意図なら `pressEnter()` を使う**(意図が読み手に伝わる。
`type("腕時計\n")` は「改行を入れたいのか送信したいのか」がコードから読めない)。
エンジン(in-app / XCUITest)によって結果が変わることはない(docs/design.md)。

**マップ・キャンバス系の画面**(地図・画像ビューア・図面)は、この4つで操作する:
`swipeBy` でパン(斜め含む)・`pinchOut`/`pinchIn` でズーム・`doubleTap` でズームイン。
注意点は3つ:

- **ピンチの対象指定は経路で仕組みが違う**。Android と iOS の in-app は指定領域の中心で
  2本指を合成するが、**iOS の XCUITest は座標指定の多点ジェスチャを持たない**ため
  `accessibilityIdentifier` で要素を引いてピンチする。**id の無い要素を XCUITest 経路で
  指定すると画面全体のピンチに落ち**、ステップに注記が残る
- **iOS はエンジンによって成否が分かれるジェスチャがある**(2026-08-04 に4 SUT で実測)。
  **既定の hybrid なら全フレームワークで動く**(ホストが自動で使い分ける)。Android は全て問題ない:

  | iOS | SwiftUI / UIKit | Compose Multiplatform | Flutter | React Native |
  |---|---|---|---|---|
  | `swipeBy`(斜め含む) | ✅ | ✅ | ✅ | 未実測(想定: uikit 経路 = ✅) |
  | `doubleTap` | ✅ XCUITest | ✅ **in-app のみ** | ✅ | 未実測(想定: uikit 経路 = ✅ XCUITest。SwiftUI/UIKit と同じ合成タッチ非受理) |
  | `pinchOut` / `pinchIn` | ✅ XCUITest | ✅ | ✅ **in-app のみ** | 未実測(想定: uikit 経路 = ✅ XCUITest) |

  「in-app のみ」= **`xcuitest` 単独プロファイルと実機では効かない**(実機は注入不可のため
  XCUITest しか経路が無い)。**MCP の `ft_*` も `profile` を渡せば同じエンジンで動く**
  (渡さないときは接続先ポートのブリッジに従う = in-app ブリッジが動いていれば hybrid。
  README「MCP」参照)。理由は注入側の性質で、どちらも実測で確定している:
  - **XCUITest の `doubleTap` は「離してから次に押すまで」が 0ms**。Compose は 40ms 未満の
    2打目を捨てる仕様なので単タップになる。**ランナー内で2打に分けても直らない** ——
    `XCUICoordinate.tap()` は quiescence 待ちを飛ばしても1打 335ms かかり、今度は判定窓
    (約 300ms)を超える。in-app は合成タッチなので間隔を 80ms に作れる
  - **XCUITest の `pinch` は指の間隔を約 8px しか開かない**(要素指定でも画面全体でも同じ)。
    Compose は間隔の**比**で見るので効くが、Flutter は移動量のしきい値で落ちる
    (`scale: 8.0` のように大きくすると Flutter でも効く = しきい値の問題であることの裏付け)。
    in-app は対象領域の短辺 90% まで開くので届く
  - 逆に **UIKit/SwiftUI は合成タッチを受け付けない**(`UIGestureRecognizer` が受理しない。
    in-app の `press`/`drag` が未対応なのと同じ機構)。in-app 側が 501 を返して XCUITest へ回す
- **倍率は指示どおりに出るとは限らない**。指を領域の外へは置けないので、極端な `scale` は
  「その領域で出せる最大」で頭打ちになる(2本指の間隔で決まるため)。**倍率そのものを検証するより、
  拡大/縮小が起きたことを検証する**方が SUT を跨いで安定する

## スクロール

| コマンド | 説明 |
|---|---|
| `scrollTo(sel, direction: .down, maxSwipes: 8, containerInference:)` | 要素が見つかるまでスクロール(見つかったら成功。タップはしない)。`containerInference:` は下記「容器の推測に依存する補正」参照 |
| `scrollDown(repeat: 1)` / `scrollUp` / `scrollRight` / `scrollLeft` | 1 画面ぶんスクロール(`repeat:` 回繰り返す) |
| `scrollFrame:` / `startMarginRatio:` / `endMarginRatio:`(`scroll*` / `scrollToBottom` 等 / `scrollTo` の引数。`withScroll*` は `scrollFrame:` のみ取る) | **スクロールさせたい領域**をセレクタ式で指定する(Shirates 準拠)。例: `scrollTo("#row_40", scrollFrame: "#list_rows")`。**どれが容器かは MCP の `ft_snapshot` が行末に出す `scroll` 印**で分かる(2つ以上あるときは先頭でも名指しする。ただし**印が無い = スクロールしない、ではない** —— Compose / Flutter は xcuitest エンジンでは申告できない(in-app は版57から申告できる))。**省略時は画面中央基準の全画面スワイプ**(マージン指定も無視)。`withScrollDown(scrollFrame:) { }` に渡すとブロック内の探索が継承する。**Compose / Flutter の in-app エンジンは領域を切り分けられないため XCUITest へ自動フォールバックする**(そのぶん遅い)。**スクロールできない領域を指定すると、スワイプは成功するが何も動かない** —— 気付けるようにステップへ注記が付く(`the specified scrollFrame is not scrollable` / margin で動かせる幅が潰れた場合は `resolved but leaves nothing to move`)。**画面に1件も無い scrollFrame を指定すると、スワイプを1本も送らずに失敗する**(2026-08-08。`scrollTo` の探索だけでなく `scroll*` / `scrollTo*Edge` 系 / `flick*` / `withScroll*` 配下の探索も同じ。**`select` 系だけは例外**で、掴めなければ空要素を返す契約が優先し skipped になる。以前は黙って全画面スワイプへ退化し、カード上のボタンを発火させる実害があった。探索中に容器が木から消えた場合も失敗になる)。**Compose(CMP)で領域指定が必須だった制限は 2026-08-03 に解消**(容器の外に出る ghost 要素を掴んでいた。docs/verification.md「Compose の探索直後タップ」)|
| `scrollToBottom(maxSwipes: 50)` / `scrollToTop` / `scrollToRightEdge` / `scrollToLeftEdge` | 端まで送る(**画面が変化しなくなるまで**。maxSwipes は暴走を止める上限で、上限で打ち切ったときはステップに注記が付く) |
| `withScrollDown { … }` / `withScrollUp` / `withScrollRight` / `withScrollLeft` | ブロック内の `tap` / `type` / `clearInput` / `select` / `exist` / `notExist` を**すべてスクロール探索**にする(明示の `scroll:` があればそちらが優先)。**`notExist` は意味が変わる** — 探索中に見つかった時点で失敗になる |
| `withoutScroll { … }` | 外側の `withScroll*` を打ち消し、ブロック内は現在画面だけで解決する |
| `withoutContainerInference { … }` | ブロック内のすべてのコマンドで、容器の推測に依存する補正を止める(下記) |
| `tapWithScrollDown(sel, maxSwipes:)` 等 4 方向 | `tap(sel, scroll: .down)` の別名(Shirates と同名) |
| `tapWithoutScroll(sel, timeout:)` | `withScroll*` の中でも**この 1 コマンドだけ**スクロールしない |
| `existWithScrollDown(sel, maxSwipes:)` / `existWithScrollUp` | `exist(sel, scroll: .down)` の別名 |
| `existWithoutScroll(sel, timeout:requireVisible:)` | `withScroll*` の中でも現在画面だけで存在検証 |
| `selectWithScrollDown(sel, maxSwipes:)` 等 4 方向 | `select(sel, scroll: .down)` の別名(Shirates と同名) |
| `selectWithoutScroll(sel, timeout:requireVisible:)` | `withScroll*` の中でも現在画面だけで解決する `select` |

**`*WithScroll*` の別名は `maxSwipes:`(`select` 系は `requireVisible:` も)しか取らない糖衣**です。
`timeout:` や `holdSeconds:` を渡したいときは本体の `scroll:` を使ってください
(`tap(sel, scroll: .down, timeout: 2)`)。`existWithScrollLeft/Right` を置いていないのも同じ理由で、
`exist(sel, scroll: .left)` と書けるためです。**置いていない別名を書いてもコンパイルエラーが
正しい書き方を指します**(`tapWithScrollDown(sel, timeout: 2)` → 「本体の `scroll:` を使え」)。

レポートに出る注記(**失敗ではなく観測**。読み方):

| 注記 | 意味 | 気にするべきか |
|---|---|---|
| `stopped at the limit of N (may not have reached the edge yet)` | `maxSwipes` で打ち切った = 端に着いたとは限らない | **する**。`maxSwipes` を増やすか、そもそも端に着けない画面かを疑う |
| `the screen did not settle (poll limit)` | スワイプ後 600ms 待っても画面の動きが止まらなかった(慣性が長い等)。操作自体は送られている | 通常は不要。**同じ箇所で毎回出るなら**、静止前の座標でタップして flake る余地があるので調べる価値がある |
| `fell back to XCUITest` | in-app エンジンで実行できずフォールバックした(1回あたり数百 ms 遅い) | 通常は不要。多発するなら実行プロファイルのエンジン選択を見直す |

```swift
tap("設定", scroll: .down)          // 折り返しの下にある項目を探索してからタップ
withScrollDown {
    tap("#row_40")                  // ブロック内は書かなくても探索される
    existWithoutScroll("#header")   // 固定ヘッダは現在画面で確認
}
```

### 容器の推測に依存する補正

`tap`/`scrollTo` などの座標解決は、見切れ判定・掴み直し・救済ドラッグ・見えている部分を撃つ座標補正・
壊れた座標の候補除外といった「容器の推測」に依存する補正を行う。**既定で有効**だが、想定外の画面構成
(独自のスクロールコンテナ実装など)で補正が裏目に出るときだけ切れる。3段階のどこで切るかを選べる:

| 単位 | 方法 |
|---|---|
| run 全体(**最上位の殺しスイッチ**) | 環境変数 `FT_CONTAINER_INFERENCE=off`。これを立てると下の3つは全部無視して無効 |
| 1 コマンド | `tap(sel, containerInference: false)` / `scrollTo(sel, containerInference: false)` |
| ブロック | `withoutContainerInference { … }`(`tap`/`exist`/`select` など全コマンドに効く) |
| 実行プロファイル全体 | 実行プロファイルの `containerInference: false`(VSCode 拡張のプロファイルタブからも設定できる) |

環境変数を除けば、明示引数 > ブロックの文脈 > 実行プロファイルの既定 の順。

## フリック

Shirates 準拠のコマンド名(`flick*`)。**画面(または `scrollFrame`)基点の8方向**。`scroll*` は
コンテンツ基準(要素が見つかるまで探索)なのに対し、flick は**指を1回速く動かすだけ**の生ジェスチャで、
低レベル実装は `swipe`/`scroll*` と同じ(等速の1ストローク)だが既定の `durationSeconds`/
`intervalSeconds` が短い(Shirates の `FLICK_DURATION`/`INTERVAL_SECONDS` 準拠)。

| コマンド | 説明 |
|---|---|
| `flickCenterToTop/Bottom/Left/Right(scrollFrame:durationSeconds: 0.25 repeat: 1 intervalSeconds: 0.3)` | 画面(または `scrollFrame`)の中央を起点に4方向へ払う |
| `flickLeftToRight/RightToLeft(scrollFrame:startMarginRatio:durationSeconds: 0.25 repeat: 1 intervalSeconds: 0.3)` | 端から端へ横方向。`startMarginRatio` 省略時は `scrollRight` 等と同じ既定(実測値 0.2) |
| `flickBottomToTop/TopToBottom(scrollFrame:startMarginRatio:durationSeconds: 0.25 repeat: 1 intervalSeconds: 0.3)` | 端から端へ縦方向 |

- `scrollableElement` 引数は無い(`scrollFrame` のセレクタ式で足りる)
- Shirates の `flickAndGo*` 一族(画面遷移トリガ)・要素基点の `TestElement.flickTo*`/`flickOut*` は未実装(docs/shirates-parity.md)

## 存在・状態の検証

| コマンド | 説明 |
|---|---|
| `exist(sel, timeout:requireVisible:scroll:maxSwipes:)` | 存在検証。偽陽性検証を有効にした run(実行プロファイル `falsePositiveCheck: true`)では**実際に見えていること**も確認する。戻り値にチェーン可(後述) |
| `waitForDisplay(sel, waitSeconds: 15)` | 要素が表示されるまで待つ(**スクロールしない**)。戻り値は `FTElement`(`exist` と同様チェーン可)。見つからなければ失敗しシナリオ中断。**判定は `exist` と同じ可視性込み**(コマンド名 displayed の意味に沿わせている)で、**`exist` の `requireVisible: false` に当たる逃げ道は無い** — 覆われ検出を外したいなら `exist(sel, requireVisible: false, timeout: 15)` を使う |
| `waitForClose(sel, waitSeconds: 15)` | 要素が消えるまで待つ(**スクロールしない**)。`sel` は省略不可(Shirates の直前セレクタ再利用の省略形は無い。`lastElement` はあるが、待ち対象がソース上で読めなくなるため引数は必須のまま) |
| `notExist(sel, timeout:scroll:maxSwipes:)` | **消えるまで待つ**(初回で不在なら即成功)。ダイアログ・ローディングが閉じた確認に。`scroll:` 指定時は**その方向へスクロールしながら探し、見つかった時点で不在検証を失敗させる**(`exist(scroll:)` の裏返し。見つからなければ従来どおり現在のビューポートでの消滅待ちに進む) |
| `countIs(sel, 個数, timeout:)` | 候補の個数。**ツリー上の件数**で可視性は見ない。`\|\|` は和集合の総数(重複は 1 度だけ)。**ラベルで数えるときは型で絞る**(`.button&&項目` — ボタンと内側のラベルは別要素として両方載るため) |
| `enabledIsTrue()` / `enabledIsFalse()` | 有効/無効の検証(タイムアウトまで状態変化を待つ)。**対象は直前に掴んだ要素**(`select("#btn").enabledIsTrue()`) |
| `checkIsON()` / `checkIsOFF()` | チェック状態の検証。**対象は直前に掴んだ要素**。iOS はアプリの実装により checked が取れないことがある(取れないままだと run 終了時に警告が出る)。**Android は `isChecked` と `isSelected` の両方を見る**(2026-08-07) — タブや選択行は `isChecked` を立てず `isSelected` だけで選択状態を出すため、以前はこの種の要素で永久に通らなかった |
| `keyboardIsShown(timeout:)` / `keyboardIsNotShown(timeout:)` | ソフトキーボードの表示/非表示の検証。開閉はアニメーションを伴うためタイムアウトまでポーリングする。**「非表示」を確定できるのは iOS in-app と Android だけ** — iOS の xcuitest エンジンは「キーボードを見た/不明」しか言えないため、`keyboardIsNotShown` は失敗する(キーボードが見えていれば「keyboard is still shown」、見ていなければ「cannot determine the keyboard state」。不明を非表示と読んで嘘の成功にしない設計) |
| `screenIs("画面の説明文")` | FM による**見た目の**画面検証(スクリーンショットと説明文の照合)。実行プロファイルで `fm:false` / `screenIs:false` の場合はスキップ(素通り) |
| `appIs(id, waitSeconds: 15)` | フォアグラウンドのアプリが `id`(iOS=bundle ID / Android=package 名)と一致することの検証。**ニックネーム機構は無く ID を直接書く**(Shirates 準拠だが引数の意味だけ異なる)。`waitSeconds` までポーリング。**Android は失敗時に actual の package 名をメッセージへ含める**(iOS は前面 bundle ID を取得する手段が無いため含まれない) |

> `screenIs` と偽陽性検証(`requireVisible` / `falsePositiveCheck`)は FM に画像を渡すため
> **macOS 27+ が必要**。macOS 26 では自動でスキップ/素通りになる(現在の可否は `ftester doctor`)。

## テキスト・値の検証

`text…` はラベル(表示文字列)、`value…` は入力欄などの値を見る。

**対象は「直前に掴んだ要素」で、セレクタは検証コマンドに渡しません**(2026-08-04)。
まず `select`(または `exist` / `tap` など)で掴み、そのうえで検証します。
**次の3つはまったく同じ意味**で、記録されるステップもデバイス往復の回数も同じです:

```swift
select("#btn_ok").textIs("OK")                  // 戻り値へチェーン
select("#btn_ok"); lastElement.textIs("OK")     // 掴んだ要素を明示
select("#btn_ok"); textIs("OK")                 // 暗黙(直前に掴んだ要素)
```

引数は `(期待値, timeout:)`(肯定形は `requireVisible:` も取る)。
**セレクタを渡す形 `textIs("#btn_ok", "OK")` はありません**(コンパイルエラーになります)。

| 肯定 | 否定 | 判定 |
|---|---|---|
| `textIs` / `valueIs` | `textIsNot` / `valueIsNot` | 完全一致 |
| `textContains` / `valueContains` | `textContainsNot` / `valueContainsNot` | 部分一致 |
| `textStartsWith` / `valueStartsWith` | `textStartsWithNot` / `valueStartsWithNot` | 前方一致 |
| `textEndsWith` / `valueEndsWith` | `textEndsWithNot` / `valueEndsWithNot` | 後方一致 |
| `textMatches` / `valueMatches` | `textMatchesNot` / `valueMatchesNot` | 正規表現(**部分一致**。全体一致は `^…$`) |
| `textMatchesDateFormat` / `valueMatchesDateFormat` | — | 日付書式(`"yyyy/MM/dd"` 等・DateFormatter の記法) |
| `textIsNotEmpty` / `valueIsNotEmpty` | `textIsEmpty` / `valueIsEmpty` | 空でない / 空 |

- **比較は「見た目が完全に一致していれば同じ」**(2026-08-09)。実データには目に見えない文字が
  紛れるので(ゼロ幅・双方向制御・ソフトハイフン等)、それらは無視する。一方**見た目が違うものは
  別物**として扱う —— 半角スペースと全角スペースは違うし、連続空白も両端の空白も残す。
  `👨‍👩‍👦` と `👨👩👦`、`❤️` と `❤` も別物(結合子・異体字セレクタは書記素クラスタを作るので残す)。
  **`strict: true` を渡すと一切正規化しない**(`textIs("OK", strict: true)`)。
  **肯定・否定・空判定・`idIs`・`thisIs` のすべてが同じ規則**を通る —— 片方だけ素の比較だと
  「`textIs("x")` が通るのに `textIsNot("x")` も通る」という矛盾した組が作れてしまう。
  空判定は見た目基準なので、**ゼロ幅だけの文字列は「空」**(空白は幅があるので空ではない)。
  `id` も正規化する —— 実アプリの id には日本語が現れる(Apple マップのキーボード候補が
  `焼いて` 等をそのまま identifier にしている実測)。
  不一致で落ちたときは、失敗文が**どちらの規則なら一致したか**を必ず言う ——
  `(normalized comparison: matches / strict comparison: does not match)` なら、
  差は見えない文字だけなので `strict: true` を外すか期待値を直せばよい。
  **セレクタの照合は規則が違う**(あちらは「見つける」ためのものなので、両端をトリムし、
  空白の種類を問わず吸収し、連続空白を1つに畳む)
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

**「その要素」を検証するコマンドはすべてチェーンできます**（`textIs` / `textContains` /
`textMatches` などテキストの全対称、`valueIs` 以下の value の全対称、`enabledIsTrue` / `enabledIsFalse` /
`checkIsON` / `checkIsOFF`、掴んだ要素の id を見る `idIs`）。**同じ集合がそのまま暗黙形
(1引数の自由関数)にもなっています** — チェーンで書けるものは必ず暗黙形でも書けます。

チェーンできない = 暗黙形も無いのは**要素を1つに定めないコマンド**だけです（`exist` / `notExist` /
`countIs` / `screenIs`）。これらはセレクタを取り続けます（`exist` は掴む側なので当然セレクタが要ります）。

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
    .expectation { select("#txt_confirm_order_id").textIs(注文番号 ?? "") }
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
if e.isNotEmpty { 合計 = e.text }   // 無い・見えていなければ空要素なので読まない
```

- `.text` は要素の表示テキスト(ラベル)、`.value` は値、`.id` は identifier
- **検証したくない(レポートに検証ステップを残したくない)ときは `exist` の代わりに `select` を使う**。
  `select` は掴むだけで可視性照合の対象にもならない。使い方は同じ(`select("#txt_total").text`)

### チェーンした検証の初回判定(掴んだ値を先に見る)

`exist(…)` / `select(…)` / `lastElement` にチェーンした検証は、**まず掴んだ時点の値で判定**し、
満たしていればデバイスを見に行きません（ステップは通常どおり記録され、説明に
`(from the grabbed value)` が付きます）。**満たしていなければ従来どおり**取り直しながら
タイムアウトまでポーリングします。

```swift
exist("#txt_total").textIs("1,200")   // 掴んだ値が "1,200" なら往復 0 回
tap("#btn_reload")
lastElement.textIs("1,500")           // 掴んだ値は古い → 取り直して "1,500" になるまで待つ
```

- **3つの書き方すべてに効きます**（チェーン / `lastElement.textIs(…)` / 暗黙の `textIs(…)`）。
  掴んでいない状態で暗黙形を書くと空要素 + 警告になり、検証は落ちます
- **`checkIsON` / `checkIsOFF` は対象外**です（「checked を実際に観測したか」の追跡が
  デバイス経路にあり、飛ばすと *状態を持たない要素を指している* 誤用警告が出なくなるため）
- **可視性照合が走る run（実行プロファイルの `falsePositiveCheck: true`）では対象外**です
  （見えているかは掴んだ値から言えないので、覆われ検出が静かに消えないようデバイスを見ます）
- **注意**: 掴んでから時間が空くほど「古い値のまま通る」向きの誤りが増えます。とくに
  `lastElement` は掴んだ場所から離れるほど危険です（`textIs` は *期待どおりになるまで待つ* 検証なので、
  古い値が偶然期待に一致すると待たずに通ります）

### 直前に掴んだ要素(`lastElement`)

戻り値を受けていなくても、**直前に掴んだ要素**は `lastElement` で読めます。

```swift
select("#txt_total")
lastElement.text.thisContains("1,200")     // 変数に受けなくても読める
tap("#btn_order")
lastElement.idIs("btn_order")              // 操作コマンドも掴んだ要素を差し替える
```

- **差し替えるのは要素を1つに定めて解決したコマンド**(`select` / `exist` / `tap` / `type` /
  `waitForDisplay` / テキスト・値の検証など)。**`notExist` / `countIs` は差し替えません**
  (要素を1つに定めないため。直前に掴んだ要素がそのまま残ります)。
  セレクタを取らないコマンド(`swipe` / `launchApp` 等)も差し替えません
- **`.text` / `.value` / `.id` は掴んだ時点の凍結値**です(`exist` の戻り値と同じ契約)。
  **掴んでから読むまでにスクロール・タップを挟むと、古い値・古い座標を読みます**。
  値を読むのは掴んだ直後だけにし、離れた場所で使うなら変数に受けてください
  (`let e = select(…)`。そのほうが読み手にも「いつの値か」が見えます)
- `.textIs(…)` 等の**チェーンは掴んだ値で先に判定し、満たしていなければ取り直します**
  (下記「チェーンした検証の初回判定」)
- **掴めなかったコマンドは空要素で上書きします**(前の要素が残ると、別の要素の値を
  「今掴んだもの」として読んでしまうため)。**scene を跨ぐと空**になります
- **一度も掴んでいない状態で読むと空要素+警告**が出ます(黙って通る形にしないため)。
  その空要素にチェーンした検証は必ず落ちます

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

## 検証していないシナリオの検知

`expectation { }` に**アサーションが1つも無い**と、レポートとログに警告が出ます(失敗にはしません)。
`action` に全部書いて `expectation` には `tap` だけ置いた・`exist` のつもりで `select` を置いた、は
どちらもコンパイルも実行も通り、**アプリがどう壊れても緑**になるためです。
**シナリオ全体でアサーションが0本**ならさらに強い警告が出ます。

- 数えるのは `exist` / `notExist` / `textIs` 以下の検証コマンドと `thisIs` 系・`appIs`
  (= `verify` が数えるものと同じ)。`select` は検証ではないので数えません
- **`ios { }` / `android { }` / `ifCanSelect { }` の中身が実行されなかった**ときは警告しません
  (中に何が書かれているかは実行しないと分からないため。`expectation { android { notExist(…) } }`
  を iOS で回しても黙ります)
- **`ftester run --dry-run`(MCP は `ft_dry_run`)ならデバイス無しで判定できます**。
  デバイスを触る前にここで落とすのが安上がりです

## `#x` は placeholder も引く

`#x` は **identifier で1件も引けなかったときだけ** placeholder が `x` の要素を引きます
(2026-08-15)。入力欄は**指す手段が経路で割れる**ためです —— HTML の id は
XCUITest が読む a11y には出ませんが placeholder は出ますし、Android は WebView の版で
id と placeholder が入れ替わります。同じ欄が実行エンジンや OS 版で指せたり指せなかったり
するのを、シナリオ側ではなくセレクタ側で吸収します。

```swift
type("#WebView 入力", "hello123")   // id が無い WebView の入力欄も placeholder で掴める
```

- **identifier が当たったらそちらだけ**を使います(placeholder は受け皿)。混ざらないので
  `#x[2]` の序数や `countIs` が経路で変わることはありません
- placeholder だけを狙いたいときは従来どおり `placeholder=x` と書けます

## セレクタの綴り誤りの検知(dry-run)

`ft_snapshot` で撮った画面の `#id` はプロジェクトの台帳
(`<プロジェクト>/.ftester/selector-inventory.json`)に貯まり、**dry-run がシナリオ中の `#id` と
突き合わせて**、どのスナップショットにも無い id を警告します(失敗にはしません)。

- **撮っていない画面については何も言いません**(台帳が無い・そのプラットフォームの記録が無いときも同様)。
  「知らない」を「間違い」と言わないための設計で、セレクタを実画面から採る原則は変わりません
- **台帳が薄いうちも黙ります**。警告が出るのは**そのシナリオが触る `#id` の 2/3 以上が台帳に在るとき**
  だけです(綴り誤りは「多数の正しい id に少数の誤り」という形で出るため)。1画面しか撮っていない
  状態で既存シナリオを一括 dry-run すると、他画面の id を全部疑って**44/47 が誤警告**になったため
  (2026-08-03 の実測)
- 対象は**完全一致の `#id` だけ**。ワイルドカード(`#row_*`)とラベルは対象外です
  (ラベルは文言変更で普通に変わるため)
- 台帳は identifier に加えて **placeholder も貯めます**。`#x` は identifier で引けなければ
  placeholder を引く(下記)ので、台帳は「`#` で指せる名前の集合」です
- 台帳は**和集合で増える**だけで、消えた id が残っても警告が増えることはありません

## まとめて検証(verify)

```swift
verify("注文情報が正しい") {
    select("#txt_order_id").textIs(注文番号 ?? "")
    exist("#txt_order_total")
}
```

`verify(message) { }` はブロックを実行し、**1ステップ(check)として `message` を記録する**。ブロック内で
`exist` / `textIs` などのアサーション系コマンドが**1つ以上**実行され、全て成功すれば passed。
**アサーションが0個の場合は passed でも failed でもなく inconclusive(結論なし)になる**
(検証したつもりで何も検証していないことに気付かせる。Shirates の `MANUAL` 相当は持たない方針のまま)。
inconclusive はシナリオを中断しない。レポート・ログには ❓ とともに理由が出て、弱い修正提案も残る。
ブロック内のコマンドが失敗した場合は通常どおりシナリオが中断する
(その失敗が verify 自身の失敗としても記録される)。

## アプリ・OS 操作

| コマンド | 説明 |
|---|---|
| `launchApp(bundleID?, url:?)` | 起動(省略時は `@TestClass(app:)` のアプリ)。**起動済みでも前面化ではなく、常にプロセスを終了してから起動し直す**(Android はブリッジが force-stop+起動、iOS は terminate 込み launch。エントリー画面から始まる)。`url:` を渡すと起動直後にその URL を配送する(配送の詳細・制約は `openURL` を参照) |
| `openURL(url)` | 起動済みのアプリへ URL(ディープリンク)を配送し、今の画面の上に遷移を積む(**アプリを再起動しない** = warm 配送。`launchApp(url:)` は逆に先にプロセスを再起動してから配送する)。配送はホスト側の外部コマンドで行う(ブリッジは経由しない): iOS シミュレータ = `simctl openurl` / iOS 実機 = `devicectl device process openURL` / Android = `adb shell am start -W -a android.intent.action.VIEW -d '<url>' <package>`。**カスタムスキーム前提** —— Universal Links/App Links(`https://`)は AASA/assetlinks.json の取得状態に左右され、シミュレータでは Safari に流れることがある。未起動のアプリに撃つと OS がアプリを起動して開くが、想定用途ではない。**iOS の in-app エンジンでは未起動のまま撃つと dylib が注入されずブリッジが死ぬ**ため、ドライバがブリッジ無応答を検知して注入起動してから配送し直す(利用者が意識する必要はないが、**cold start 検証そのものは in-app エンジンでは表現できない**)。iOS シミュレータでは配送直後に SpringBoard が出す初回の確認アラート(「"<表示名>"で開きますか?」。以後は端末+アプリの組で同意が永続する)を xcuitest/hybrid エンジンでは自動了承するが、**in-app エンジン単独では SpringBoard を見られないため自動了承できない**(初回は手動でアラートを閉じるか、事前に一度 xcuitest/hybrid で同意を済ませておく)。遷移は非同期なので直後の検証は通常どおりポーリングで待つ |
| `restartApp(bundleID?)` | 終了してから起動(プロセス内状態のリセットに) |
| `terminateApp()` | 終了 |
| `installApp(path?)` | アプリをインストール。**実行はオーケストレータ(親プロセス)が行う**。パス省略時は実行プロファイルの `appPath` を親が解決する(明示引数 > プロファイル)。プロファイルにも `appPath` が無ければ明示エラー。iOS の in-app/hybrid エンジンでは simctl install で常駐ブリッジが道連れに終了するが、直後の `launchApp()` が再注入し直すので、続けて `launchApp()` を呼べば問題ない。オーケストレータ無しの単独実行(`ftester-scenarios run` を直接叩く等)では従来どおり明示引数が必須(省略時は明示エラー) |
| `removeApp(id?)` | アプリをアンインストール。省略時は起動中アプリの既定 bundleID/package(`launchApp()` 引数なしと同じ解決)。**自分自身の SUT を消すと、以降のシナリオ実行と in-app ブリッジが壊れる**ので、テスト対象アプリに対して呼ぶのは慎重に |
| `clearAppData(bundleID?)` | アプリは残しデータだけ消す(再インストール不要)。初回起動・オンボーディング・権限ダイアログの再現に使う。**権限(iOS の TCC / Android の実行時権限)も未許可へ戻す**ので、権限ダイアログが再び出る。**iOS はシミュレータ専用**(実機は失敗する)。Android は `pm clear` 相当。**NSUserDefaults / SharedPreferences は消える**(iOS は cfprefsd の入れ直しまで行う)。**キーチェーン(iOS)/ Keystore(Android)に置いた値は消えない** — オンボーディング判定をそこに置いているアプリは初回起動が再現しない |
| `home()` | ホーム画面へ |
| `back()` | 前の画面へ戻る(Android = 戻るキー / iOS = **ナビゲーションバーの戻るボタン、無ければ左端エッジスワイプ**)。**Android はキーボードが開いていると1回目がキーボードを閉じるのに消費される**(OS 仕様)。**iOS で確実に戻れるのはシステムのナビゲーションバーを持つ画面だけ** —— UIKit/SwiftUI は戻るボタン(`BackButton`)を押すので決定的。持たない画面(Compose/Flutter の独自ナビ)はエッジスワイプに落ち、**interactive pop に対応していなければ戻れない**(そのときはアプリ内の戻るボタンを `tap` する)。エッジスワイプは成立しないと同じタッチが下の要素へ渡るので、**戻れない画面で撃たない** |
| `appSwitcher()` | アプリスイッチャーを開く |
| `rotateTo(.landscape)` | 画面を回す。向きは **`.portrait` / `.landscape` の2つだけ**。**契約は「アプリの UI がその向きになること」**で、デバイスがどう傾いているかではない —— テストが観測できる frame と画面サイズは iOS / Android とも、Compose / SwiftUI / View-XML / Flutter / React Native のどれでもアプリ座標系で返るので、跨いで同じ意味を持つのはここまで(左右の区別は観測できないので語彙に置かない)。回した後は**向きが実際に変わるまで待ってから返る**(要求直後は古い向きが読める)。**回転を使ったシナリオは終了時に元の向きへ自動で戻る**(Android は自動回転の設定も戻す)。**アプリが横向きを許可していないと回らない**(iOS は Info.plist の `UISupportedInterfaceOrientations`、Android は `screenOrientation`)。iOS はその接続が使っているエンジンで回し、Android はホスト側の adb(`user_rotation`)で回すので実機でも効く。**Android は自動回転を切る**(切らないと角度が保持されない。実測)。MCP の `ft_rotate` は戻さないので、探索の後は自分で戻すか端末を初期化する |
| `tapAppIcon(name?)` | ホーム画面のアプリアイコンをタップ(Shirates の `auto` 相当のみ。`tapAppIconMethod` 等のマクロ機構は無い)。**名前省略時はアプリプロファイルの `appName`**(親が解決して渡す。無ければ明示エラー)。手順: `home()`(iOS はもう1回)→ 現在画面で探索 → 見つからなければ Android はドロワーを開いて `flickCenterToTop` で最大8回スクロール探索、iOS は `flickRightToLeft` で最大5ページ送り(2回連続不変化でも打ち切り)。最後まで見つからなければ失敗(`"App icon not found.(name)"`) |
| `screenshot(filename:?)` | 現在の画面を撮り、レポートのこのステップ直後に埋め込む。ファイル名省略時はステップ連番(`.png`)。Shirates の `force`/`onChangedOnly`/`withXmlSource` は無い |

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
| `@Deleted("理由")` | テストクラスまたは `@Test` メソッドに付けて**論理削除**する。一覧には「削除済み」として残り(GUI は「削除済みを非表示にする」で切替)、全実行・フォルダ実行・クラス名指定の一括実行から**除外**される。完全一致 ID の明示指定でだけ実行できる。コードは残るので復活はアノテーションを外すだけ |
| `irregularHandler(検出sel, dismiss: 閉じるsel?)` | **出るか不定のアプリ内メッセージ**(お知らせ・キャンペーン)を宣言すると、以降どのステップでも出た時点で自動的に閉じる。`dismiss` 省略時は検出したものをタップ。setUp で 1 回宣言するのが定石。閉じたことはステップの注記に残る。**OS のシステムダイアログ(権限の許可等)はこれでは閉じない** —— 下の §システムダイアログ(iOS)参照 |

```swift
func setUp() {
    irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
}
```

## システムダイアログ(iOS)

位置情報・通知の許可や「"◯◯"で開きますか?」は **SpringBoard が別プロセスで描く**ので、
**アプリのアクセシビリティツリーには最初から現れない**。`irregularHandler` は
アプリ内の要素しか見ないので、これらには効かない。

**自動で閉じるのは1つだけ** —— `openURL` の初回確認アラート(端末+アプリの組で同意は永続する)。
権限ダイアログは自動了承しない(許可/拒否はテストの意図そのものなので、ツールが勝手に決めない)。

| エンジン | 書き方 |
|---|---|
| **hybrid**(実行プロファイルの既定) | **普通に書ける** —— `tap("許可")` のように、アプリ側で解決できないセレクタはホストが SpringBoard 参照セッションへ照会して掴む(`exist` / `textIs` も同じ)。**自動では閉じないので、出る画面では明示的に書くこと** |
| **xcuitest 単独** | この照会経路を持たないので掴めない。ダイアログを操作する必要があるシナリオは hybrid で回す |
| **inapp 単独** | 同上(注入先アプリのプロセスしか見えない) |

```swift
// 位置情報の許可が出る画面(hybrid)
tap("#request_location")
ifCanSelect("Appの使用中は許可", waitSeconds: 3) {
    tap("Appの使用中は許可")     // 出なければ何もしない(同意済みの2回目以降)
}
```

**権限を毎回同じ状態から始めたいなら `clearAppData()`** —— アプリのデータに加えて権限(TCC)も
未許可へ戻すので、ダイアログが再び出る(iOS はシミュレータ専用)。

**MCP(`ft_*`)で詰まったとき**は `ft_launch bundleId: com.apple.springboard` —— 非破壊で
SpringBoard に attach するだけなので、`ft_snapshot` でダイアログを読んで ref で叩ける。
終わったら `ft_launch <対象アプリ>` で戻る。座標で叩くと画面サイズや OS 版が変わった瞬間に壊れる。
