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
| `tap(sel, holdSeconds: 0, timeout:scroll:maxSwipes:containerInference:)` | タップ。`holdSeconds` を 0 より大きくすると長押し(既定 0 = 通常タップ)。**対象がまだ無効なら操作可能になるまで待ってから撃つ**(下記)。`containerInference:` は下記「容器の推測に依存する補正」参照 |
| `select(sel, timeout:requireVisible:scroll:maxSwipes:)` | 要素を**掴むだけ**(デバイス操作なし)。`exist` と違い**検証ではない**ので、レポートに検証ステップとして残らない。値の読み出し(`.text`/`.value`/`.id`)や検証コマンドへのチェーンの起点に使う。**掴めなければ失敗させず空要素を返す** — 「見つからない」も「見つかったが見えない(覆われ・見切れ)」も同じ形で返るので、呼び出し側は `.isEmpty` で分岐する(`exist` はどちらも失敗へ反転するので意味が違う)。**在ることを保証したいなら `exist`**。`requireVisible: false` で可視性照合自体を外す |
| `lastElement` | **直前に掴んだ要素**(引数なし。Shirates(Classic) の `TestDriver.lastElement` 相当)。要素を1つに定めて解決したコマンド(`select` / `exist` / `tap` / `type` / `waitForDisplay` / テキスト・値の検証など)が通るたびに差し替わる。差し替えないのは**要素を1つに定めない** `notExist` / `countIs` と、**セレクタを取らない** `swipe` / `launchApp` 等。**値は掴んだ時点の凍結値**で、掴んだ後にスクロールやタップを挟むと古い値を読む(下記「掴んだ要素の値を読む」)。**scene を跨ぐと空**・**掴めなかったコマンドは空で上書き**・**一度も掴んでいなければ空+警告** |
| `type("文字列", replace: false)` | **フォーカス中の要素**へ入力(直前に `tap(入力欄)` でフォーカスしてから使う)。改行の扱いは下記。**引数はテキストであってセレクタではない** — `type("#email")` のようにセレクタらしい1語(`#` + 識別子・`\|\|` や `>>` を含む)を渡すと実行前に失敗する(黙って `#email` と打ち込んで後段の検証で落ちると原因から遠いため)。その文字列を本当に入力したいなら2引数形 `type("#field", "#email")` を使う。`replace: true` で撃つ前に `clearInput` 相当のクリアをしてから入力する(セレクタ解決が1回で済む) |
| `type(sel, "文字列", timeout:scroll:maxSwipes:replace:)` | 要素を指定して入力。日本語もそのまま入る(IME 切替なし)。改行の扱いは下記。`replace: true` で撃つ前にクリアしてから入力する(下記 `clearInput` 参照) |
| `pressEnter()` | フォーカス中の入力へ Enter/IME アクション(検索・実行・改行)を発火(Shirates(Classic) 準拠) |
| `hideKeyboard()` | ソフトキーボードを閉じる。**Android のみ**(出ているときだけ戻るキーを撃つので冪等)。**iOS は未対応で失敗する** — iOS で閉じたいときは `pressEnter()` を使う(単一行の欄なら閉じる) |
| `clearInput()` | フォーカス中の入力欄を空にする |
| `clearInput(sel, timeout:scroll:maxSwipes:)` | 要素を指定して入力欄を空にする(`type` は追記なので、書き換えるならまず `clearInput`。セレクタ解決を1回で済ませたいだけなら `type(sel, "文字列", replace: true)` で1コマンドに畳める)。**Flutter の iOS は in-app エンジンでは消せず XCUITest 経由になる**(自動フォールバック。1〜2秒かかる) |
| `swipe(.up / .down / .left / .right)` | 画面全体をスワイプ(**指の動き**) |
| `tap(x:y:holdSeconds: 0)` | **座標を直接タップ**(Shirates 準拠)。座標は snapshot の `screen` と同じ座標系で、**iOS = pt / Android = px**(dp ではない)。`holdSeconds` を 0 より大きくすると長押し。**セレクタで指せるならそちらを使う** —— 座標はレイアウトが動いた瞬間に別の物を叩く。要るのは「アプリが要素を1つも公開しない画面」で、実測では操作可能要素の 9.3% が書けるセレクタを持たない。**`ft_batch` でも書ける**(`tap x: 120 y: 640`)。ただし**セレクタと併記はできない** —— どちらを撃ったか読み手に分からなくなるため拒否する |
| `swipePointToPoint(startX:startY:endX:endY:durationSeconds: 1.5)` | 2点間ドラッグ(座標は snapshot の screen と同じ座標系。iOS = pt / Android = px) |
| `swipeElementToElement(開始sel, 終点sel, durationSeconds: 1.5)` | 要素間のドラッグ(スライダー・並べ替え・部分領域のドラッグ用)。**終点はヒール対象外**(始点だけがヒール・フォールバック連鎖を持つ) |
| `swipeBy(sel?, dxRatio:dyRatio:durationSeconds: 1.5)` | 対象の中心から**比率**で指を動かす(**斜め可**。両方を非 0 にすると対角)。比率は対象の幅・高さに対する割合で、符号は指の向き。セレクタ省略 = 画面全体 |
| `doubleTap(sel?)` | ダブルタップ。セレクタ省略 = 画面中心。**`tap` を2回書いても代用できない**(往復で OS のダブルタップ判定時間を超える) |
| `pinchOut(sel?, scale: 2.0, durationSeconds: 0.5)` | 2本指を開く = **拡大**。`scale` は 1 より大きい値のみ |
| `pinchIn(sel?, scale: 0.5, durationSeconds: 0.5)` | 2本指を閉じる = **縮小**。`scale` は 0 より大きく 1 未満のみ |

### まだ触れない画面を叩かない(`tap` は操作可能になるまで待つ)

画面が出た直後は、**要素は木に居るのにまだ触れない**ことがある(読み込み中のフォーム・
検証が通るまで無効なボタン)。`waitForDisplay` は「出たか」しか見ないので待ち切れない。

`tap` は対象が `enabled` でなければ**操作可能になるまで待ってから**撃つ。
待った事実は注記に残る(`waited 1730ms for the target to become enabled` /
機械可読は `waited-for-enabled`)。

- **待ち切れなくても撃つ**。無効な要素をわざと叩いて「反応しない」ことを確かめる書き方は
  正当なので失敗にはしない(従来どおり `the target is disabled …` の注記が出る)
- 予算はステップの `timeout:`、省略時は既定の待ち(5秒)。**待ちたくないときは `timeout: 0`**
- **`&&enabled=` を明示したセレクタでは待たない** —— `#btn&&enabled=false` は
  「無効なものを狙って掴む」宣言なので、待つと必ず予算を捨てる
- **待っている間に湧いた割り込みは閉じる**(`irregularHandler` の宣言があるとき)。
  待ちは撃つまでの時間を伸ばすので、閉じないと**モーダルが被さる窓を自分で広げる**

これが無いと、空振りしたタップは**後段のアサーションが落ちて初めて**分かる(原因から遠い)。

### `tap(入力欄)` → `type("文字列")`(Shirates 伝統の書き方)

**両方書ける**。どちらも同じところへ入る。

```swift
tap("#field"); type("abc")        // 伝統形。フォーカスを作ってから打つ
type("#field", "abc")             // セレクタ形。1コマンドで解決・フォーカス・入力
```

伝統形が Android で落ちることがあった(2026-08-21 の受け手報告)ので、**ツール側で吸収**した。
Android の入力欄は**容器**(Material の `TextInputLayout`)と**中身**(`TextInputEditText`)に
分かれ、**id は容器側に付くことが多い**。`#id` は容器に解決し、容器がタップを吸うと
**入力フォーカスは中身へ移らない** —— そこで `type`(ロケータ無し)は、
**焦点が立っていなければその欄を名指しして入れ直す**:

```
✅ type "abc"(typed into textField (the preceding tap did not put a field in focus))
```

規律は3つ:
- **払うのはタップの直後だけ**(木を1枚読んで焦点を確かめる)。自動フォーカスに任せる書き方や
  `pressEnter` で欄を移った直後の `type` は従来どおり読み足さない
- **推測しない**。入れる先は「叩いた要素そのもの(入力欄なら)」か「その中のただ1つの入力欄」だけ。
  容器の中に欄が2つ以上あるなら**何もしない**(どちらへ入れるべきかツールには言えない)
- **注記に残す**(`type-focus-recovered`)。これが増えている画面は、`#id` が容器を指している

**それでも入らないとき**(欄が一意に決まらない等)はセレクタ形で書く ——
`type(sel, "文字列")` は解決・フォーカス・読み返しまで引き受ける。

### 誰がどこまで面倒を見るか(割り込みに吸われた操作)

| 割り込みが出た時点 | 誰が扱うか |
|---|---|
| ステップの開始時に**もう出ている** | **ツール**(解決の前に閉じ、整定してから読み直す) |
| `suppressHandler { }` の中 | **シナリオ**(そう宣言したので閉じない) |
| **操作可能になるのを待っている間**に湧く | **ツール**(待ちの各周回で閉じる) |
| **操作を送ってから効果が出るまで**の間に湧く | **シナリオ**(下記) |

最後の1つだけがシナリオ側です。タップが着弾済みかどうかは観測から言えないので、
**ツールは撃ち直しません**(届いていた場合に二重実行になる)。落ちたステップに
「吸われたかもしれない」注記が出るだけです。復帰(遷移を確かめて叩き直す等)は
**もう一度実行しても安全な操作にだけ**書くこと。

**`||` の連鎖は「先に書いたほうが勝つ」**(フォールバックは前が解決できなかったときだけ)。
`#txtMailAddress||.textField[1]` は容器の id が引ける限り**常に容器**に解決するので、
中身を狙うなら `.textField[1]` を単独で書く。**注記が出るときはツールが解決先を名乗る**
(`resolved to #txtMailAddress (other)`)ので、どちらを掴んだかはそこで読める。

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
| `scrollToBottom(maxSwipes: 50)` / `scrollToTop` / `scrollToRightEdge` / `scrollToLeftEdge` | 端まで送る(**画面が変化しなくなるまで**。maxSwipes は暴走を止める上限で、上限で打ち切ったときはステップに注記が付く)。**iOS の in-app エンジンは1回で端まで寄せる** —— 下記「端送りの速さはエンジンで決まる」 |
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

### 端送りの速さはエンジンで決まる

`scrollToBottom` 等は「1本振る → 木を読んで動きが止まったか見る」の繰り返しで、
**1ページ進むごとの往復**が所要になる。長文(利用規約・長い規程)ではここがページ数に比例する。
**1ページで進む量と、そもそも往復が要るかはエンジンで違う**:

| エンジン | 1回の送り | 長文の所要 |
|---|---|---|
| iOS in-app(UIKit/SwiftUI・WebView) | **端まで一度に寄せる**(`contentOffset` を直接動かす経路で、ジェスチャも慣性も無いため刻む理由が無い) | **文書の長さに依存しない**(実測: 40 行リストの `scrollToTop` が 2.0s → 0.8s) |
| Android の WebView | **CDP でページを一発で飛ばす**(スワイプを撃たない。使えなければジェスチャへ落ちる) | **文書の長さに依存しない**(実測: 6.1s → 2.3s。残りはスクロールではなく端の判定) |
| iOS in-app(Compose / Flutter) | 1回 = 1ページ(UIAccessibility の scroll。刻み幅を選べない API) | ページ数に比例 |
| iOS xcuitest | 実スワイプ(velocity 1500 のフリング。約 1.1 画面) | ページ数に比例 |
| Android(ネイティブ) | 実スワイプ(中央→端の強いストローク。約 1.2 画面) | ページ数に比例。**`maxSwipes` の既定 50 で届かない文書もある**(その場合は上限打ち切りの注記が出る) |

実ジェスチャのエンジンで長文を送るときは `maxSwipes` を上げる。**`flick*` を並べて速くしようとしない** ——
flick は**ジェスチャそのものが目的**のコマンドで端の判定を持たない(着いたかどうかは自分で確かめることになる)。

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

### Android の WebView はスクリーンショットに写らないことがある

**端末のキャプチャが WebView の層を落とす**ことがある(2026-08-20 に自前 SUT で再現。
木には WebView の全要素が実座標で載っているのに、ブリッジの `UiAutomation.takeScreenshot`・
`adb exec-out screencap`・エミュレータの gRPC の**3経路とも同じ空白**を返した)。
**撮り方を替えても直らない**ので、その場合だけ **CDP(`Page.captureScreenshot`)から撮った
ページ画像を、空白の領域へ貼って1枚に合成**する。

- 発動するのは「画面の 45% 以上が1色の帯になっている」ときだけ。写っている画面では何もしない
  (実測: 写っている画面 0.23s / 補完した画面 1.1〜2.2s / 帯のない通常画面 +0.1s)
- **貼る位置は木の `webView` ノード**(あれば)。無いときだけ画像から拾った帯を使い、
  **縦横比がほぼ一致するときに限って**貼る —— アプリの chrome ごと写らず画面全体が1色になる
  端末では、帯だけで決めるとナビゲーションバーの上にページを重ねてしまう
- **アプリ側で WebView のデバッグが有効でないと補えない**
  (`WebView.setWebContentsDebuggingEnabled(true)`。通常は debug ビルドのみ)。
  補えなかったときは**黙らず**、確かめ方(`adb shell cat /proc/net/unix | grep devtools_remote`)
  ごと警告を出す
- 殺しスイッチは `FT_WEBVIEW_DOM=off`(DOM 読みと同じ口)
- **写らないのは間欠的**: 同じ画面でもアプリを起動し直すと写ることがある。到達確認は
  スクリーンショットではなく木のアサーション(`exist` / `notExist`)で書くのが確実

### 画面を覆うモーダル(別ウィンドウ)の扱い

アプリ内メッセージの SDK は、**アプリ本体とは別の `UIWindow`** にカードやバナーを載せることが
あります(`UIAlertController` と違ってキーウィンドウにしない形)。ツール側は次のように扱います。

- **モーダルは木に載る**(`exist` で検証でき、`irregularHandler` で閉じられる)
- **覆われた背面は木から消える** —— 覆いの下にある要素の `exist` は落ち、タップは
  「見つからない」で失敗します。**覆われているのに緑になる**(偽陽性)を残さないためです
- **画面の一部だけを覆う形(上部バナー等)では背面は消えません**。判定は
  「その位置で手前の窓が実際にタッチを受けるか」なので、触れる背面は見えたままです
- **操作もスクリーンショットも手前の窓へ届きます**(タップは対象が載っている窓、
  スクロールと座標タップはいま指が当たる窓、スクリーンショットは可視な窓を重ねて描画)

**判定はタッチが届くかであって、目に見えるかではありません**。素通しの飾り窓
(`isUserInteractionEnabled = false`)は視覚的に隠していても背面を残します。

出るか不定のモーダルは `irregularHandler` を宣言しておけば自動で閉じます(1ステップで
最大10回まで。`maxDismissals:` で変更可)。

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
| `screenLooksLike("画面の説明文")` | FM による**見た目の**画面検証(スクリーンショットと説明文の照合)。実行プロファイルで `fm:false` / `screenLooksLike:false` の場合はスキップ(素通り) |
| `appIs(id, waitSeconds: 15)` | フォアグラウンドのアプリが `id`(iOS=bundle ID / Android=package 名)と一致することの検証。**ニックネーム機構は無く ID を直接書く**(Shirates 準拠だが引数の意味だけ異なる)。`waitSeconds` までポーリング。**Android は失敗時に actual の package 名をメッセージへ含める**(iOS は前面 bundle ID を取得する手段が無いため含まれない) |

> `screenLooksLike` と偽陽性検証(`requireVisible` / `falsePositiveCheck`)は FM に画像を渡すため
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
`countIs` / `screenLooksLike`）。これらはセレクタを取り続けます（`exist` は掴む側なので当然セレクタが要ります）。

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

### 既定アプリ(bundleID を省略したとき)

`launchApp()` / `restartApp()` / `terminateApp()` / `removeApp()` / `clearAppData()` / `appIs()` が
引数を省略したときの対象は、次の順で決まる:

1. `@TestClass(app: "...")` の明示(**書いてあればこれが勝つ**)
2. 実行プロファイル(`runs/<name>.json` の `app`)→ アプリプロファイル(`apps/<name>.json`)→
   **実行中 platform の `ios.app` / `android.app`**

**通常は `app:` を書かない**。書かなければ同じシナリオが `--profile ios` と `--profile android` で
それぞれのアプリを対象に走る(OS で bundle ID が違っていてもクラスを複製しなくてよい)。
`app:` を書くのは、1プロジェクトに複数アプリのシナリオが混在していてシナリオ側で固定したいときだけ。
明示とプロファイルが食い違うと、明示を採ったうえで run ログに警告が1行出る。

どちらからも決まらないとき(実行プロファイル無しの単独実行など)は明示エラーになる。
`ftester run --app <bundleID>` で渡すか、`--profile` を使う。
`installApp()` の `appPath` も同じくアプリプロファイルの `<platform>.appPath` から解決される。

| コマンド | 説明 |
|---|---|
| `launchApp(bundleID?, url:?)` | 起動(省略時は**この run の既定アプリ** = 実行プロファイル → アプリプロファイルの `<platform>.app`。`@TestClass(app:)` が書かれていればそちらが勝つ)。**起動済みでも前面化ではなく、常にプロセスを終了してから起動し直す**(Android はブリッジが force-stop+起動、iOS は terminate 込み launch。エントリー画面から始まる)。`url:` を渡すと起動直後にその URL を配送する(配送の詳細・制約は `openURL` を参照) |
| `openURL(url)` | 起動済みのアプリへ URL(ディープリンク)を配送し、今の画面の上に遷移を積む(**アプリを再起動しない** = warm 配送。`launchApp(url:)` は逆に先にプロセスを再起動してから配送する)。配送はホスト側の外部コマンドで行う(ブリッジは経由しない): iOS シミュレータ = `simctl openurl` / iOS 実機 = `devicectl device process openURL` / Android = `adb shell am start -W -a android.intent.action.VIEW -d '<url>' <package>`。**カスタムスキーム前提** —— Universal Links/App Links(`https://`)は AASA/assetlinks.json の取得状態に左右され、シミュレータでは Safari に流れることがある。未起動のアプリに撃つと OS がアプリを起動して開くが、想定用途ではない。**iOS の in-app エンジンでは未起動のまま撃つと dylib が注入されずブリッジが死ぬ**ため、ドライバがブリッジ無応答を検知して注入起動してから配送し直す(利用者が意識する必要はないが、**cold start 検証そのものは in-app エンジンでは表現できない**)。iOS シミュレータでは配送直後に SpringBoard が出す初回の確認アラート(「"<表示名>"で開きますか?」。以後は端末+アプリの組で同意が永続する)を xcuitest/hybrid エンジンでは自動了承するが、**in-app エンジン単独では SpringBoard を見られないため自動了承できない**(初回は手動でアラートを閉じるか、事前に一度 xcuitest/hybrid で同意を済ませておく)。遷移は非同期なので直後の検証は通常どおりポーリングで待つ |
| `restartApp(bundleID?)` | 終了してから起動(プロセス内状態のリセットに)。省略時の既定アプリは `launchApp()` と同じ解決 |
| `terminateApp()` | 終了 |
| `installApp(path?)` | アプリをインストール(iOS: `.app` / Android: `.apk` または `.apks`。`.apks` は bundletool が要る)。**実行はオーケストレータ(親プロセス)が行う**。パス省略時は実行プロファイルの `appPath` を親が解決する(明示引数 > プロファイル)。プロファイルにも `appPath` が無ければ明示エラー。iOS の in-app/hybrid エンジンでは simctl install で常駐ブリッジが道連れに終了するが、直後の `launchApp()` が再注入し直すので、続けて `launchApp()` を呼べば問題ない。オーケストレータ無しの単独実行(`ftester-scenarios run` を直接叩く等)では従来どおり明示引数が必須(省略時は明示エラー) |
| `removeApp(id?)` | アプリをアンインストール。省略時は起動中アプリの既定 bundleID/package(`launchApp()` 引数なしと同じ解決)。**入れ直しても権限は戻らない**(iOS シミュレータ実測): 削除→再インストールしても TCC(位置情報等)の許可が残り、許可ダイアログは**再び出ない**。実機の挙動とは違うので「入れ直せば初回状態」を前提にしたシナリオは書けない —— 権限から戻したいなら `clearAppData()`。**自分自身の SUT を消すと、以降のシナリオ実行と in-app ブリッジが壊れる**ので、テスト対象アプリに対して呼ぶのは慎重に |
| `clearAppData(bundleID?)` | アプリは残しデータだけ消す(再インストール不要)。初回起動・オンボーディング・権限ダイアログの再現に使う。**権限(iOS の TCC / Android の実行時権限)も未許可へ戻す**ので、権限ダイアログが再び出る。**iOS はシミュレータ専用**(実機は失敗する)。Android は `pm clear` 相当。**NSUserDefaults / SharedPreferences は消える**(iOS は cfprefsd の入れ直しまで行う)。**キーチェーン(iOS)/ Keystore(Android)に置いた値は消えない** — オンボーディング判定をそこに置いているアプリは初回起動が再現しない |
| `home()` | ホーム画面へ |
| `back()` | 前の画面へ戻る(Android = 戻るキー / iOS = **ナビゲーションバーの戻るボタン、無ければ左端エッジスワイプ**)。**Android はキーボードが開いていると1回目がキーボードを閉じるのに消費される**(OS 仕様)。**iOS で確実に戻れるのはシステムのナビゲーションバーを持つ画面だけ** —— UIKit/SwiftUI は戻るボタン(`BackButton`)を押すので決定的。持たない画面(Compose/Flutter の独自ナビ)はエッジスワイプに落ち、**interactive pop に対応していなければ戻れない**(そのときはアプリ内の戻るボタンを `tap` する)。エッジスワイプは成立しないと同じタッチが下の要素へ渡るので、**戻れない画面で撃たない** |
| `appSwitcher()` | アプリスイッチャーを開く |
| `rotateTo(.landscape)` | 画面を回す。向きは **`.portrait` / `.landscape` の2つだけ**。**契約は「アプリの UI がその向きになること」**で、デバイスがどう傾いているかではない —— テストが観測できる frame と画面サイズは iOS / Android とも、Compose / SwiftUI / View-XML / Flutter / React Native のどれでもアプリ座標系で返るので、跨いで同じ意味を持つのはここまで(左右の区別は観測できないので語彙に置かない)。回した後は**向きが実際に変わるまで待ってから返る**(要求直後は古い向きが読める)。**回転を使ったシナリオは終了時に元の向きへ自動で戻る**(Android は自動回転の設定も戻す)。**アプリが横向きを許可していないと回らない**(iOS は Info.plist の `UISupportedInterfaceOrientations`、Android は `screenOrientation`)。iOS はその接続が使っているエンジンで回し、Android はホスト側の adb(`user_rotation`)で回すので実機でも効く。**Android は自動回転を切る**(切らないと角度が保持されない。実測)。MCP の `ft_rotate` は戻さないので、探索の後は自分で戻すか端末を初期化する |
| `tapAppIcon(name?)` | ホーム画面のアプリアイコンをタップ(Shirates の `auto` 相当のみ。`tapAppIconMethod` 等のマクロ機構は無い)。**名前省略時はアプリプロファイルの `appName`**(親が解決して渡す。無ければ明示エラー)。手順: `home()`(iOS はもう1回)→ 現在画面で探索 → 見つからなければ Android はドロワーを開いて `flickCenterToTop` で最大8回スクロール探索、iOS は `flickRightToLeft` で最大5ページ送り(2回連続不変化でも打ち切り)。最後まで見つからなければ失敗(`"App icon not found.(name)"`) |
| `screenshot(filename:?)` | 現在の画面を撮り、レポートのこのステップ直後に埋め込む。ファイル名省略時はステップ連番(`.png`)。**ラベル無しの `screenshot("a.png")` でも書ける**(Shirates は Kotlin の位置引数で同じ形が通るため)。Shirates の `force`/`onChangedOnly`/`withXmlSource` は無い。**Android の WebView 画面**は端末のキャプチャに中身が写らないことがあり、その場合だけ CDP から撮ったページ画像を合成する(下記) |

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
| `@TestClass(platform:)` / `@Test(platform:)` | **対象 OS の宣言**(`"ios"` / `"android"`)。両方あるとメソッド側が勝つ。宣言した OS を回さない実行プロファイルでは**そのシナリオを実行せず skipped(対象外)として記録する**(失敗ではなく、exit code も汚さない)。「iOS では意味がないテスト」(Wi-Fi プロキシ設定など)を、`ios { }` を空にして緑にする代わりに意図として残すためのもの。**実行プロファイルを使う run でだけ効く** —— `--ports` / `--serial` の直指定は「この run が回す OS の集合」を宣言しないので従来どおり |
| `@Deleted("理由")` | テストクラスまたは `@Test` メソッドに付けて**論理削除**する。一覧には「削除済み」として残り(GUI は「削除済みを非表示にする」で切替)、全実行・フォルダ実行・クラス名指定の一括実行から**除外**される。完全一致 ID の明示指定でだけ実行できる。コードは残るので復活はアノテーションを外すだけ |
| `irregularHandler(検出sel, dismiss: 閉じるsel?, maxDismissals: 10)` | **出るか不定のアプリ内メッセージ**(お知らせ・キャンペーン)を宣言すると、以降どのステップでも出た時点で自動的に閉じる。`dismiss` 省略時は検出したものをタップ。setUp で 1 回宣言するのが定石。閉じたことはステップの注記に残る(**1ステップで最大10回**まで閉じる。`maxDismissals:` で宣言ごとに変えられる。長いステップの最中に2度目が湧いても閉じ切れる。2回閉じても同じものが残っていれば「閉じられていない」と判断して打ち切り、注記に残す)。**OS のシステムダイアログ(権限の許可等)はこれでは閉じない** —— 下の §システムダイアログ(iOS)参照 |

```swift
func setUp() {
    irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
}
```

**条件判定も割り込みを閉じてから答える**(`ifCanSelect` / `repeatWhileCanSelect`)。
覆われた要素は木から落ちるので、閉じずに不成立を確定すると**分岐が黙って飛ぶ** ——
失敗ではなく**誤った経路**として現れるため、落ちる場所は原因から遠くなる(2026-08-20 の実害)。
閉じたことは不成立でも判定の記録に残る(`(dismissed the interruption …)` と
注記 `interruption-dismissed`)。**「覆いを閉じたうえで無かった」と「覆われたまま無いことにした」は
別物**なので、後者を黙って返さない。

```swift
// 待ちのコマンドを前に置いて割り込みを閉じさせる、という回避策はもう要らない
ifCanSelect("いますぐ利用する", waitSeconds: 10) { … }
```

### シナリオ自身がモーダルを扱う区間(`suppressHandler`)

宣言済みの割り込みを**自動で閉じない**区間を作る(Shirates 準拠の名前)。
モーダルそのものを検証したい・別のボタンを押したいときに使う。

```swift
func setUp() {
    irregularHandler("#promo_modal", dismiss: "#btn_promo_close")   // 宣言は setUp のままでよい
}

suppressHandler {
    exist("#promo_modal")          // 出たことを検証する
    tap("#btn_promo_detail")       // 自分で操作する
}                                   // 抜けたら自動クローズが戻る
```

- **ブロック形**なので、途中で失敗しても抑止は必ず戻る
- 入れ子の `useHandler { }` で、区間の内側だけ自動クローズを戻せる
- **CAE のブロックを跨ぐときは `disableHandler()` / `enableHandler()`**(下記)
- **止まるのは「ツールが閉じること」だけ** —— 割り込みが出ること自体はアプリの都合なので、
  抑止しても「送った操作が吸われる」形は変わらない(下の表)
- **抑止したまま落ちた**ときだけ、失敗の注記に
  `a declared interruption was on screen but automatic closing is suppressed here` が出る
  (抑止の危険は「抑止したまま忘れる」。成功しているステップには何も足さない)
- **OS のシステムダイアログ(権限の許可等)はこれでは止まらない** —— あちらは実行プロファイルの
  `iosAlertHandler` による自動押下で別の機構(§システムダイアログ)。
  そもそも要求した要素が解決できるときは自動押下は走らない = シナリオの操作は奪われない

これが無いと「`irregularHandler` を宣言する場所をずらす」回避策になる。

**CAE を跨ぐときは命令形**(`suppressHandler { }` は1つのブロックの内側にしか置けない):

```swift
condition {
    disableHandler()
    exist("#promo_modal")       // 出たことだけ確かめておく
}.action {
    tap("#btn_promo_detail")    // 別のブロックでも止まったまま
}.expectation {
    exist("#detail_screen")
    enableHandler()             // ここから自動クローズが戻る
}
```

- `useHandler { }` は**どちらの抑止も**一時的に戻す
- `enableHandler()` は**ブロック形の抑止までは解除しない**(ブロックは出口で必ず戻るので、
  内側から外すと入れ子の意味が壊れる)
- **戻し忘れはシナリオの終わりまで効く**。中断した場合、その後の画面操作は tearDown だけなので、
  片付けが割り込みに吸われうる点だけ意識する(気になるならブロック形を使う)

### 割り込みが「操作を吸った」ときの扱い

閉じたあとは**画面が落ち着くのを待ってから木を取り直す**ので、消えるアニメーションの最中の
木を掴んで「閉じたのに同じステップで解決できない」になることはない(待つのは実際に閉じた
ステップだけで、宣言があっても割り込みが出ない run の所要は変わらない)。

面倒を見るのは**ステップ開始の時点で出ている割り込み**まで。**送った操作の効果が出るまでの
間に湧いた割り込み**は、そのタップが着弾済みかどうかを観測から言えないので、
**ツールは撃ち直さない**(届いていた場合に二重実行になる。送信・購入のような不可逆な操作では
取り返しがつかない)。代わりに、割り込みを閉じたステップが落ちたときだけ注記が出る:

```
the interruption appeared during this step — an interaction sent just before it
may have been swallowed by it (nothing was re-sent: repeating it could double-fire)
```

**復帰はシナリオ側**に書く(`ifCanSelect` で戻ったか確かめて叩き直す等)。
**もう一度実行しても安全な操作にだけ**置くこと —— 遷移やアイコンのタップは安全だが、
確定・送信・支払いに同じ形の再試行を置かない(安全かどうかを判断できるのは書き手だけなので、
ツールはここに踏み込まない)。

## 座標タップをいつ使うか

**セレクタで指せるなら常にセレクタ**。そのうえで、用途で重みが変わる(2026-08-16 ユーザー方針):

| 用途 | 方針 |
|---|---|
| **テストを実装する**(シナリオに残す) | **セレクタが最優先**。座標は「アプリが要素を公開しない」等でどうしても書けないときだけ。`ft_draft_scenario` は座標の行に「セレクタへ置き換えよ」という行末コメントを付けて出す |
| **アドホックな MCP 実行**(Claude Code が調べる・動かす) | セレクタを優先するが、**座標のほうが早く解けるならそれでよい**。実行時間の短縮を優先する |

理由は非対称だから: シナリオは**後から何度も実行される**のでレイアウト変更で壊れる書き方は負債になるが、
その場限りの操作は**壊れる前に終わる**。`ft_tap` の座標応答も、この2つを踏まえた文言になっている
(「探索中はこれでよい。シナリオに残すならセレクタへ」)。

## システムダイアログ(iOS)

位置情報・通知の許可や「"◯◯"で開きますか?」は **SpringBoard が別プロセスで描く**ので、
**アプリのアクセシビリティツリーには最初から現れない**。`irregularHandler` は
アプリ内の要素しか見ないので、これらには効かない。

**既定では自動で閉じるのは1つだけ** —— `openURL` の初回確認アラート(端末+アプリの組で同意は
永続する)。権限ダイアログは**既定では**自動了承しない(許可/拒否はテストの意図そのもの)。
毎回同じ答えでよいなら、実行プロファイルに**押してよいラベルを並べる**と自動で押す(下記)。

| エンジン | 書き方 |
|---|---|
| **hybrid**(実行プロファイルの既定) | **普通に書ける** —— `tap("許可")` のように、アプリ側で解決できないセレクタはホストが SpringBoard 参照セッションへ照会して掴む(`exist` / `textIs` / `ifCanSelect` / `repeatWhileCanSelect` も同じ。**`ifCanSelect` 系は 2026-08-19 まで照会していなかった** = 出るか不定のダイアログを書けなかった)。**既定では自動で閉じないので、出る画面では明示的に書くこと** |
| **xcuitest 単独** | この照会経路を持たないので掴めない。ダイアログを操作する必要があるシナリオは hybrid で回す |
| **inapp 単独** | 同上(注入先アプリのプロセスしか見えない) |

```swift
// 位置情報の許可が出る画面(hybrid)
tap("#request_location")
ifCanSelect("Appの使用中は許可", waitSeconds: 3) {
    tap("Appの使用中は許可")     // 出なければ何もしない(同意済みの2回目以降)
}
```

### 自動で押す(`iosAlertHandler`)

**シナリオの中で、出るアラートを1枚ずつ予告する**(2026-08-22 に登録関数方式へ。
実行プロファイルの JSON 宣言 `iosSystemAlertButtons` は廃止 —— 残っていれば
プロファイル検証が警告で行き先を案内する):

```swift
iosAlertHandler(alert: "*写真ライブラリ*", button: "許可しない")
iosAlertHandler(alert: "*トラッキング*||*track your activity*",
                   button: "許可||Allow")                        // 日英両対応(`||` で候補)
```

**`alert`(どのアラートか)は必須**。ボタンのラベルだけでは「なんのウィンドウの
ボタンか」が読めず、無関係のアラート(別アプリの許可要求が前面に出る形)を押し得る。

**`alert` も `button` もセレクタと同じ記法**(端末の言語で題名もボタンも変わるため
`||` で候補を並べ、`*` で一致方法を選ぶ): bare = 完全一致 / `x*` = 前方 / `*x` = 後方 /
`*x*` = 部分。題名にはアプリ名が埋め込まれる(「“サンプル.stub”が…」)ので、
実用上 `alert` は `*x*` で書くことになる。`button` の bare = 完全一致は
`"許可"` が「許可しない」を押す事故を防ぐ —— `*許可*` と書けば部分一致になるが、
その危険も含めて書き手の選択になる。`#id` / `.type` は受けない(SpringBoard の題名に
対して意味を持たない)。

**1回の呼び出し = 1枚のアラートの予告**。押せたら登録は外れ、全部外れたら監視も止まる
(登録が無い間は判定の往復を1回も払わない)。同じアラートを2枚待つなら2回呼ぶ。
**アラートが出る操作の前に呼ぶ**こと
(`setUp()` に書けば各 `@Test` の前に登録される。`irregularHandler` と同じ寿命 = シナリオ1本)。

**登録順に試し、先に成立したものを押す**。押すのは「シナリオが要求した要素が、アプリ側でも
SpringBoard 側でも解決できなかった」ときだけ —— アラートを `tap("許可")` や `ifCanSelect` で
自分で操作しているシナリオからは奪わない。登録が無ければ何もしない(従来どおり)。

**`ifCanSelect` の不成立でも押す**(閉じたうえで要求された要素を見直す)。ここを押さないと、
オンボーディングのガード列が**アラートの上を全部素通りして `not met` になり**、後続の
`exist` 系で押下が効いた頃には one-shot の窓が過ぎて手遅れになる:

```swift
// アラートが被さっていても、この列は素通りせずに進む
ifCanSelect("#btnStart||はじめる") { tap("#btnStart||はじめる") }
ifCanSelect("#btnAgree||同意する") { tap("#btnAgree||同意する") }
```

**ラベルは完全一致で、ツールは既定ボタンを推測しない。** 位置情報の許可は
「1回だけ許可 / Appの使用中は許可 / 許可しない」のように**どれが是認かが文脈で変わり**、
並びもラベルもロケールと OS 版で変わる。推測して取り違えると、症状は
「意図しない権限のまま run が緑で進む」= 沈黙になる。だから押してよいラベルは書かれた分だけとし、
一覧に無いボタンには触らない(部分一致もしない —— `"許可"` の指定が **"許可しない" を押す**)。
**自動拒否も同じ仕組み**で、並べるラベルを拒否側にするだけ。`engine=hybrid` のときだけ効く。

**押したら run ログに残る**(何を押したかまで出す)。権限は後に響く状態なので、自動で
変えておいて痕跡が無いのは沈黙になる —— **対象アプリと無関係のアラート**(別アプリの許可要求が
キューされていて前面に出ることがある)を押していても、記録が無ければ後から気付けない:

```
ℹ️ pressed "アプリの使用中は許可" on the system alert "“マップ”に位置情報の使用を許可しますか?" (iosAlertHandler)
```

### 覆われている間は操作しない(2026-08-21)

**`iosAlertHandler` の登録が残っている間だけ働く。** 登録があるとき、OS のアラートが
アプリを覆っている間はそのアプリへの操作と検証が通らない。覆いが消える(または登録した
ボタンで閉じられる)のを待ち、待ち切れなければ `failureKind=system-ui-covered` で落ちる:

```
❌ 6. [action] tap "#btn_freeze_3s"
   system UI is covering the app (“FT E2E iOS”に写真ライブラリへのアクセスを許可しますか?).
   The in-app engine could still reach the app, but a person could not, so the step was not
   performed. None of the registered iosAlertHandler entries (Appの使用中は許可)
   matched a button on it.
   Buttons on this alert: 「写真を選択」 / 「フルアクセスを許可」 / 「許可しない」.
   Register the one you want pressed with iosAlertHandler(...), or dismiss it in the scenario.
```

**そのアラートに実際に在るボタン**を出す(2026-08-20 受け手依頼)。ラベルは完全一致なので、
これが無いと**正解の文字列を知る手段が画面の連続撮影しかない**(数秒で消えるアラートは
捕まらない)。ボタンは題名と同じ1往復で読めているので、出さない理由が無い。
読めなかったときは黙らず「読めなかった」と書く —— 「出していない」のか「読めなかった」のかで
次の一手が変わる。

**登録が無い実行は1往復も払わない**。アラートが出る操作は書き手が知っているので直前に
登録でき、登録しない実行に毎ステップの費用(約 73ms)を負わせない。言い換えると、
**登録は「押すボタン」であると同時に「次にアラートが出る」という予告**でもある。
登録したのに一致するボタンが無ければ、素通りさせずに止める。

**アラートが重なっていても順に閉じる**(位置情報の直後に ATT など。1枚閉じたら戻らずに
確かめ直す)。**押しても消えない画面で無限に回ることはない**(ステップの `timeout` が打ち切る)。

**なぜ要るか**: in-app のタップは `accessibilityActivate`(要素への直接のメソッド呼び出し)か
自プロセスの窓への合成タッチで、**OS のイベント経路を通らない**。だからアラートが覆っていても
届いてしまい、**人手では不可能な操作**が通ったまま run が緑になる(受け手報告 2026-08-20)。
in-app の木は自プロセスしか見えないのでレポートにも痕跡が残らなかった。
**Android は元から影響を受けない**(木の根が active window なので、ダイアログが出ると
アプリの要素が木から消える)。

**検証も同じ扱い**: 検証が緑になった時点で覆われていたら、まず宣言で閉じてみて、
閉じられたら**晴れた画面で判定し直す**(覆いの下で出した緑は根拠にならない)。
閉じられないときだけ失敗にする。

**奪わない**: 対象が SpringBoard 側の木で解決できるとき(`tap("許可")` / `exist("許可しない")`)は
止めない。シナリオ自身がアラートを操作しているので、これを止めると権限アラートを扱うシナリオが
1本も書けなくなる。`iosAlertHandler` の登録で閉じられる場合も、閉じてから先へ進む
(注記 `waited-for-system-ui`)。

**判定は XCUITest ランナーに聞く**(`GET /systemalert`)ので、**ランナーが居る構成が要る**
(`engine=hybrid` / `xcuitest`)。`engine=inapp` 単独は判定を持たない = 従来どおり通る。
費用は1往復あたり約 73ms(アラート無しのとき。実測 2026-08-21)で、払うのは
**操作の直前**と**検証が緑になったとき**の各1回。ポーリングの周回ごとには払わず、
**検証が失敗したときは聞かない**(既に止まるので往復を足す価値がない)。
**`applicationState` では判定できない** —— アラート表示中でも `active` を返す端末があり、
同じアラートで端末により割れることを実測した。

**アラートを出すシナリオは、そのシナリオ内で閉じること。** 閉じずに終わると SpringBoard 側に
残り、**同じデバイスに載る後続シナリオが全部この失敗になる**(下記)。

**残ったアラートは run を跨ぐ**。SpringBoard が描くので、アプリを終了しても
アンインストールしても画面に残る。run 開始時に
画面にアラートが居ると**警告が出る**(自動では閉じない):

```
⚠️ iPhone 17 Pro(iOS 27.0)-01: an alert is already on screen before the run starts — …
```

**権限を毎回同じ状態から始めたいなら `clearAppData()`** —— アプリのデータに加えて権限(TCC)も
未許可へ戻すので、ダイアログが再び出る(iOS はシミュレータ専用)。

**MCP(`ft_*`)で詰まったとき**は `ft_launch bundleId: com.apple.springboard` —— 非破壊で
SpringBoard に attach するだけなので、`ft_snapshot` でダイアログを読んで ref で叩ける。
終わったら `ft_launch <対象アプリ>` で戻る。座標で叩くと画面サイズや OS 版が変わった瞬間に壊れる。
