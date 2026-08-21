# Shirates(Classic)との対応表

ftester の Swift DSL は **Shirates(Classic)に準拠**している(コマンド名・引数名・既定値・挙動を
そのまま踏襲し、独自の「改良」をしない)。この文書は**どこまで揃っていて、何を持たないか**の一覧。

- 読者は**保守者**(利用者向けの全コマンド説明は docs/commands.md)
- **この文書が準拠状況の正典**。コマンドを足す・名前を変える・意図的に持たないと決めたときは
  ここを更新する。docs/design.md「Shirates(Classic) 準拠の方針と承認済みの差分」は
  **理由の説明が要る代表例**を抜き出した表で、全リストではない(理由の詳述はあちらを参照)
- Shirates 側の出典は `~/github/wave1008/shirates-core`(迷ったらソースを読む)

## 判定の凡例

| | 意味 |
|---|---|
| ✅ | 同名・同義 |
| 🟡 | 相当する機能はあるが名前・形が違う |
| ➖ | **意図的に持たない**(理由は各行。再提案しない) |
| ⏳ | **未実装だが足す価値があると判定済み**(着手が保留。各行に**足す条件**を書く) |
| 🟢 | ftester 独自(Shirates に無い) |

**⏳ に「まだ検討していない」を置かない**(2026-08-21)。この印は以前 ❌ で、「検討して
見送った」と「見ていない」が混ざっていた。`disableHandler` は**理由が1行も無い**まま置かれて
いて、実際には**CAE を跨ぐ制御に必要**だった(ユーザー指摘で採用)。**判定していない行を作らない**
のがこの表の役目 —— 見送るなら ➖ に理由を、足すなら ⏳ に条件を書く。

**印は ❌ ではなく ⏳**(2026-08-21)。❌ はこのリポジトリでは**ステップの失敗**
(`runReducer.ts` / lane / ダッシュボード)なので、同じ記号が製品の出力と表で別の意味を持って
いた。⏳ は待機ログで既に「順番待ち」の意味で使っている。**⏸ を選ばなかった理由**は、幅が
1文字(East Asian Width = N)で表の桁が崩れることと、実行の「一時停止」と衝突すること。
下の「残る穴」表で ⏸ **保留** としていた行も ⏳ に寄せた(同じ状態を2つの印で書かない)。

## 何を足すかの判断基準

**ftester は Claude Code がテストコードを書く前提**なので、Shirates が人間の記述量を減らすために
持っている糖衣(別名族・分岐糖衣・ニックネーム)は**価値がマイナス**になる — コマンドが増えるほど
生成側の選択肢と語彙のブレが増え、生成結果が run ごとに揺れる。足す価値があるのは次のどれか:

1. **今は表現できない**(capability gap。回避策も無い)
2. **回避策はあるが、生成が即興で危ういコードを書く**(環境依存の脆いコードを再発明させる)
3. **失敗したとき人間が読む情報が増える**

---

## 要素の選択・タップ

| Shirates | ftester | |
|---|---|---|
| `tap` | `tap(sel, timeout:scroll:maxSwipes:)` | ✅ |
| `tap(holdSeconds:)` | 同名 | ✅ |
| `tapWithScrollDown/Up/Left/Right` | 同名 | ✅ |
| `tapWithoutScroll` | 同名 | ✅ |
| `select` / `selectWithScroll*` / `selectWithoutScroll` | 同名 | ✅ `exist`(検証)では代用にならないため実装(2026-07-31)。**掴めなければ失敗させず空要素を返す**(見つからないときも、見えないときも同じ。`requireVisible: false` で可視性照合を外せる)。Shirates の `throwsException` に相当する引数は持たない = 常に非 throw |
| `TestDriver.lastElement` / `it` | `lastElement` | ✅ 2026-08-04 ユーザー決定で実装(それ以前は「概念を持たない」が承認済み差分)。要素を1つに定めて解決したコマンドが差し替える(`notExist` / `countIs` とセレクタを取らないコマンドは差し替えない)。**値は掴んだ時点の凍結値**・**掴めなければ空で上書き**・**scene を跨ぐと空**・一度も掴んでいない読み出しは空+警告。`it` の別名は置かない(Swift では読み手が識別子を追えない) |
| `canSelect` / `canSelectWithScroll*` / `canSelectNot` | 単独コマンドは無い(`ifCanSelect` / `repeatWhileCanSelect` に内包) | 🟡 |
| `existAll` / `canSelectAll` / `dontExistAll` | — | ➖ **実装しない**(ユーザー決定 2026-07-31)。`exist` のチェーンで書く方が保守しやすく、要素ごとに `timeout:` / `scroll:` 等のオプションも指定できる。**再提案しない** |
| `scanElements` / `*InScanResults` | — | ➖ **画面全体の棚卸しはシナリオの仕事ではない**(2026-08-21 判定)。要素一覧は `ftester api snapshot` と MCP の `ft_snapshot` にあり、そちらは**書く前に調べる**側の道具。シナリオ内で全要素を走査して条件分岐すると、木の揺れがそのまま実行の揺れになる |
| `tapAppIcon` | `tapAppIcon(name?)` | ✅ 2026-08-03 **`auto` 相当のみ**(`tapAppIconMethod`・マクロ機構は持たない)。名前省略はプロファイルの `appName`(Shirates の `appIconName` 既定=プロファイル、と同義。親が解決して子へ渡す) |
| `tap(x, y)`(座標) | `tap(x:y:holdSeconds:)` | 🟡 2026-08-16 実装。**承認済み差分**: 座標は `Int` ではなく `Double`(ftester の座標コマンドは全部 `Double`。`swipePointToPoint` と揃える)/ `repeat:` `safeMode:` は持たない(Shirates は tap を swipe で合成するための引数だが、ftester はドライバに座標タップの口がある)。単位は iOS = pt / Android = px |
| `tapCenterOfScreen` / `tapTopOfScreen` / `tapCenterOf` / `tapOffset` / `tapDefault` | — | ⏳ **足す**(基準②)。`tap(x:y:)` の上に組めるものばかり(前2つは画面基準、後3つは要素基準)だが、**生成側が座標を自前で計算する**のは脆い。**足す条件**: 座標計算をシナリオに書いた例が出たとき |
| `tapSoftwareKey` | — | ➖ キーボード要素を snapshot から除外しているため tap できない |
| `widget` | セレクタの型語彙 `.widget` | 🟡 |
| `tempSelector` / `tempValue` | — | ➖ 生成側がセレクタを直書きするので間接参照は読みにくさが勝つ |
| `allElements` / `findElements` / `findWebElement(s)` | — | ➖ 同上(2026-08-21 判定)。スナップショットは `ftester api` / MCP 側にあり、DSL からは `countIs` と `exist` の連鎖で表明する |

## 入力・キーボード

| Shirates | ftester | |
|---|---|---|
| `sendKeys` | `type("…")` / `type(sel, "…")` | 🟡 **承認済み差分**: Shirates は `sendKeys` と `clearInput` が別コマンドで結合形を持たないが、ftester は `type(sel, "…", replace: true)` でクリア+入力を1コマンドに畳める(セレクタ解決も1回で済む) |
| `pressEnter` | 同名 | ✅ |
| `clearInput` | 同名(`clearInput()` / `clearInput(sel, …)`) | ✅ |
| `hideKeyboard` | 同名だが **Android のみ**(iOS は 501) | 🟡 iOS は実装手段が無い(下記) |
| `keyboardIsShown` / `keyboardIsNotShown` | 同名 | ✅ 取得元は OS で違う(下記) |
| `pressHome` | `home()` | 🟡 OS 共通で提供 |
| `pressBack` | `back()` | 🟡 **両 OS で提供**(iOS はエッジスワイプ) |
| `pressSearch` / `pressTab` / `pressKeys` / `pressAndroid` | — | ⏳ **足す**(2026-08-21 判定。基準①=今は書けない)。`pressEnter` しか無いので **Tab によるフォーム移動・任意キー・Android のハードキー**が表現できない。`pressSearch` は実質カバー済み(`pressEnter` が `ACTION_IME_ENTER` を撃ち検索アクションとして発火する)。**足す条件**: 受け手がキー操作を要る画面に当たったとき、または Tab 移動を含むフォームが出たとき。ブリッジは既にキー注入を持つので薄く載る |
| `typeChars` | — | ➖ **要らない**(2026-08-21 判定)。1文字ずつ打つのは IME の取りこぼし対策だが、ftester は**読み返して足りない分だけ打ち直す**(`InputInjector` / `verifiesTypedText`)ので、同じ問題を別の層で解いている |

## スクロール・スワイプ

| Shirates | ftester | |
|---|---|---|
| `scrollDown/Up/Left/Right` | 同名(`repeat:`) | ✅ |
| `scrollToBottom/Top/RightEdge/LeftEdge` | 同名(`maxSwipes:`) | ✅ |
| `withScrollDown/Up/Left/Right` / `withoutScroll` | 同名 | ✅ |
| `doUntilScrollStop` | `scrollToBottom` 等の内部実装(静止+2回連続不変化) | 🟡 |
| `swipePointToPoint` | 同名(`durationSeconds:` 既定 1.5 = `Const.SWIPE_DURATION_SECONDS`) | ✅ |
| `swipeElementToElement` | 同名 | ✅ 終点はヒール対象外 |
| `swipeCenterToTop/Bottom/Left/Right` ほか swipe 一族 | `swipe(.up/.down/.left/.right)` 1本 | 🟡 集約 |
| `swipeElementToElementAdjust`、および `swipePointToPoint` / `swipeElementToElement` の `withOffset` `offsetY` `intervalSeconds` `repeat` `safeMode` `marginRatio` `adjust` | — | ➖ ブリッジの drag が**単発ジェスチャ**のため(承認済み差分) |
| `TestElement.swipeTo*` / `swipeOut*`(要素基点) | — | ➖ **`swipeElementToElement` / `swipeBy(sel, …)` で書ける**(2026-08-21 判定)。要素を掴んでから方角へ振る糖衣で、生成側は始点・終点を明示するほうが読める |
| `flickCenterToTop/Bottom/Left/Right` `flickLeftToRight/RightToLeft` `flickBottomToTop/TopToBottom`(8種) | 同名 | ✅ 2026-08-03 **画面基点のみ**。`scrollableElement`/`safeMode` 引数は無い(`scrollFrame` で足りる) |
| `flickAndGo*` 一族 | `scroll*`/`scrollTo` 系で代替 | ➖ 画面遷移トリガの糖衣は生成側の語彙を増やすだけ |
| 要素基点 `TestElement.flickTo*` / `flickOut*` | — | ➖ 同上(2026-08-21 判定)。flick 8種は画面基準で移植済みで、要素基点は `swipeBy(sel, …)` が担う |
| `scrollFrame` | 同名(`scroll*` / `scrollTo` / `withScroll*` / `flick*` の引数。セレクタ式) | ✅ 2026-08-02。**型付きセレクタ(`Sel`)版は持たない = 文字列のみ**(ユーザー決定 2026-08-04・**再提案しない**。1対1を保証するのは対象セレクタまで。理由は design.md) |
| `startMarginRatio` / `endMarginRatio` | 同名 | ✅ **既定値は ftester の実測値**(承認済み差分) |
| `scrollableElement` | — | ➖ `scrollFrame` のセレクタ式で足りる |
| `ScrollDirection.None` | `FTScrollDirection` に相当なし | ➖ 「スクロールしない」は `scroll:` 引数の省略(Optional)が担う |
| `scrollDurationSeconds` / `scrollIntervalSeconds` | — | ➖ フリング前提の実測値を優先(承認済み差分) |
| — | `scrollTo(sel, direction:maxSwipes:)` | 🟢 |
| — | `swipeBy(sel?, dxRatio:dyRatio:)` | 🟢 2026-08-04 **斜めを含む相対ドラッグ**(マップのパン)。Shirates は縦横 4 方向しか持たない |
| — | `doubleTap(sel?)` | 🟢 2026-08-04 ブリッジ側の1操作(往復するとダブルタップ判定時間を超える) |
| — | `pinchOut(sel?, scale:)` / `pinchIn(sel?, scale:)` | 🟢 2026-08-04 2本指ズーム。**Shirates(Classic) にピンチ系は無い**ので名前の準拠先も無い。対象指定は Android=座標合成 / iOS=XCUITest は identifier・in-app は座標。**iOS はエンジンで成否が分かれる**(docs/commands.md の表) |

## 存在・画面の検証

| Shirates | ftester | |
|---|---|---|
| `exist` | 同名(戻り値チェーン可) | ✅ |
| `existWithScrollDown/Up` | 同名 | ✅ |
| `existWithScrollLeft/Right` | 別名なし(`exist(sel, scroll: .left)` で可) | ➖ **置かない**(下記「別名族が取る引数」) |
| `existWithoutScroll` | 同名 | ✅ |
| `dontExist` | `notExist(sel, timeout:scroll:maxSwipes:)` | 🟡 **名前が違う** |
| `dontExistWithScrollDown/Up` / `dontExistWithoutScroll` | `notExist(scroll:)` に集約 | 🟡 別名は無い |
| `screenIs` / `screenIsOf` / `isScreen(Of)` / `waitScreen(Of)` / `switchScreen` | — | ➖ 画面ニックネーム機構を持たない。**`screenIs` は `UnavailableCommands` が受け止める**(同名だった FM の視覚照合は 2026-08-21 に `screenLooksLike` へ改名した) |
| — | `screenLooksLike(説明文)` | 🟢 FM の視覚照合(スクリーンショットと自然文の照合)。Shirates に対応物は無い |
| `cell` / `cellOf` / `getCell` | セレクタのスコープ `>>` | 🟡 |
| `appIs` | `appIs(id, waitSeconds: 15)` | ✅ 2026-08-03 **ニックネーム機構が無く ID を直接書く**(Shirates はニックネーム解決込み)。Android は失敗時 actual を付ける |
| `packageIs` | `appIs` で代用 | ➖ **実装しない**(ユーザー決定 2026-08-03。いったん実装後に削除)。ニックネームが無い ftester では `appIs` が ID 直指定のため Android で**完全に同じ検査**になる。**再提案しない** |
| `isApp` | — | ➖ **`appIs` と重複**(2026-08-21 判定)。Shirates の `isApp` は真偽を返す形だが、ftester は分岐に `ifCanSelect` / Swift を使うので、検証は `appIs`(失敗させる)側に一本化する |
| `verify`(任意内容の検証) | `verify(message) { }` | ✅ 2026-08-03 ブロック内のアサーション1つ以上が全成功で passed。**アサーション0個は inconclusive**(passed でも failed でもない・シナリオは中断しない。Shirates の `MANUAL` 相当は持たない。ユーザー決定 2026-08-03) |
| `existImage` / `dontExistImage` / `findImage*` / `imageIs` / `imageContains` | — | ➖ 画像テンプレートマッチングは非対応(切り出し画像の管理が生成に向かない。FM の `screenLooksLike` が代替) |
| — | `countIs(sel, n)`(節ごとの内訳付き) | 🟢 |

## 属性の検証

| Shirates | ftester | |
|---|---|---|
| `textIs/IsNot/Contains(Not)/StartsWith(Not)/EndsWith(Not)/Matches(Not)/MatchesDateFormat/IsEmpty/IsNotEmpty` | 全て同名 | ✅ 全対称。**2026-08-04 以降セレクタを取らない**(対象は直前に掴んだ要素 = Shirates の `it`/`lastElement` と同じ考え方)。`select("#x").textIs("OK")` / `select("#x"); textIs("OK")` の2形が同義 |
| `valueIs…` 一式(同10種) | 全て同名 | ✅ 全対称(対象の扱いは `textIs` と同じ) |
| `idIs` | 同名(チェーン / 暗黙形の両方) | ✅ 2026-08-04 に自由関数版(`select("#x"); idIs("x")`)も追加 |
| `accessIs…` 一式 | `#id` に統合 | 🟡 |
| `enabledIsTrue/False` | `enabledIsTrue()` / `enabledIsFalse()` | ✅ 2026-08-04 糖衣形を同名で踏襲(旧 `isEnabled`/`isDisabled` から改名)。**生文字列の親形 `enabledIs(expected:)` は持たない**(下記 ➖) |
| `checkIsON` / `checkIsOFF` | `checkIsON()` / `checkIsOFF()` | ✅ 2026-08-04 同名で踏襲(旧 `isChecked`/`isNotChecked` から改名) |
| `enabledIs(expected:)` / `checkedIs(expected:)`(生文字列の親形) | — | ➖ **持たない**。生値比較は OS 依存(checked は Android "true"/"false"・iOS "1"/"")で、ftester が持つ正規化済み Bool と衝突する。糖衣形(`enabledIsTrue/False`・`checkIsON/OFF`)は OS 差を吸収済みで正規化と一致する。Shirates 自身も `checkIsON/OFF` の中でこの OS 差を吸収している。**再提案しない** |
| `selectedIs(True/False)` | — | ➖ iOS の selected trait は `checked` に写像している |
| `displayedIs` | `requireVisible:` + `falsePositiveCheck` | 🟡 |
| `classIs(Not)` | セレクタの `.型` で絞る | 🟡 |
| `attributeIs(Not)` / `buttonIsActive(Not)` | — | ➖ **木が持つ属性は固定集合**(2026-08-21 判定)。`ElementInfo` にある物は専用の検証(`textIs`/`valueIs`/`enabledIs*`/`checkIs*`)で表明でき、無い属性は**任意名で聞かれてもブリッジが答えられない**。新しい属性が要るなら、まず供給側(ブリッジ)に足す話になる |

## 任意の値の検証(thisIs 系)

| Shirates | ftester | |
|---|---|---|
| `thisIs/thisIsNot/thisIsTrue/thisIsFalse` | 同名 | ✅ |
| `thisIsEmpty/NotEmpty/Blank/NotBlank` | 同名 | ✅ |
| `thisContains(Not)/StartsWith(Not)/EndsWith(Not)/Matches(Not)/MatchesDateFormat` | 同名 | ✅ |
| `thisIsGreaterThan(OrEqual)/LessThan(OrEqual)` | 同名 | ✅ |
| `assertEquals` / `assertEqualsNot` | — | ➖ **`thisIs` と重複**(2026-08-21 判定)。同じことを2通りで書けると生成側の語彙が揺れる |

**この群だけは完全準拠**(Swift の言語制約を `FTValue` 転送で吸収した点だけが差分)。

## 分岐・反復

| Shirates | ftester | |
|---|---|---|
| `ifCanSelect { }` | 同名 + `.ifElse { }` | ✅ **「出るか不定」の唯一の表現手段**(`optional:` 廃止後。アプリ内メッセージは `irregularHandler`) |
| `ifCanSelectNot` | `.ifElse` で代替 | 🟡 |
| `doUntilTrue` | 同名(引数名も準拠) | ✅ |
| `android` / `ios` | 同名 | ✅ |
| `ifTrue` / `ifFalse`(Boolean) | 素の Swift `if` | ➖ 分岐の語彙を増やすと生成側の誤選択が増える |
| `ifScreenIs(Not)` / `ifStringIs` / `ifContains` 等 | — | ➖ 分岐の語彙を増やすと生成側の誤選択が増える(`ifTrue` と同じ理由)。条件は素の Swift `if` と `ifCanSelect` の2つに絞る |
| `ifCheckON/OFF` | — | ➖ 同上(分岐の語彙を増やさない)。チェック状態で分ける必要があるなら `ifCanSelect(":checked" 相当のセレクタ)` か Swift 側で書く |
| `ifImageExist(Not)` / `ifImageIs(Not)` | — | ➖ **画像マッチングを持たない**(テンプレート画像の管理と閾値調整が要り、端末差で腐る)。見た目の検証は `screenLooksLike`(FM)と要素の検証で書く |
| `emulator` / `simulator` / `virtualDevice` / `realDevice` | — | ➖ 実機/仮想の差はツール側で吸収する方針 |
| `platformName` / `isAndroid` / `isiOS` ほかプロパティ | — | ➖ **`ios { }` / `android { }` で足りる**(2026-08-21 判定)。値が要る場面は Swift 側で書ける。真偽値を配ると「片方だけ通る」書き方が増え、どの OS で何を検証したかが読めなくなる |
| `osaifuKeitai(Not)` / `specialTag` / `stub(Not)` / `arm64` / `intel` | — | ➖ **Shirates 固有の運用タグ**(特定端末機能・スタブ構成・CPU 種別で実行を分ける)。ftester の実行の絞り込みは実行プロファイルと `@Test(platform:)` が担う |
| — | `repeatWhileCanSelect(sel, max:)` | 🟢 |

## 同期

| Shirates | ftester | |
|---|---|---|
| `wait` | 同名 | ✅ |
| `waitForDisplay` | `waitForDisplay(sel, waitSeconds: 15)` | ✅ 2026-08-03 スクロールしない・戻り値 `FTElement`。Shirates の `throwsException` に相当する引数は持たない(常に失敗として記録する) |
| `waitForClose` | `waitForClose(sel, waitSeconds: 15)` | ✅ 2026-08-03 **`expression` 省略不可**(Shirates の直前セレクタ再利用の省略形は不採用。`lastElement` は 2026-08-04 に実装済みだが、待ち対象がソース上で読めなくなるため待ち系には省略形を置かない) |
| `usingWaitSeconds` | `timeout:` 引数 / 実行プロファイル `defaultTimeout` | 🟡 |
| `waitScreen` / `waitScreenOf` | — | ➖ 画面ニックネーム機構を持たない |

## アプリ・OS 操作

| Shirates | ftester | |
|---|---|---|
| `launchApp` / `terminateApp` | 同名 | ✅ |
| `restartApp` | 同名 | ✅ 旧名 `relaunchApp` から改名済み(2026-07-31。下記「名前の相違」) |
| `installApp` / `removeApp` | `installApp(path?)` / `removeApp(id?)` | ✅ 2026-08-03 DSL 化。`installApp` は実行をオーケストレータ(親プロセス)へ委譲し、パス省略時は実行プロファイルの `appPath` を解決する(Shirates の `appPackageFile` 既定に一致)。オーケストレータ無しの単独実行だけ引数必須(省略時は明示エラー)。`removeApp` は id 省略を実行中アプリの既定 bundleID/package に解決する |
| `isAppInstalled` / `launchAppByShell` | CLI 側(`ftester install`)。DSL には無い | ➖ **導入はシナリオの外**(2026-08-21 判定)。実行プロファイルの `appPath` + `autoInstall` が run の前に面倒を見るので、シナリオが導入状態を分岐に使う形は増やさない(`installApp` / `removeApp` は明示的に操作したいとき用に既にある) |
| `goPreviousApp` | `appSwitcher()`(スイッチャーを開くだけ) | 🟡 |
| `internetOn/Off` / `wiFiOn/Off` / `mobileOn/Off` | — | ⏳ **足す**(2026-08-21 判定。基準①=回避策が無い唯一の項目)。**通信断の状態を作れない**ので、オフライン時の表示・再試行・エラーダイアログを検証できない。**実害**: 受け手のアプリは規約画面を外部サイトから読み、通信が失敗するとエラーダイアログを出す —— それが偶発的にテストを落とすのに、**意図的に再現することも防ぐこともできない**。**Android のみ**(`adb shell svc wifi/data`)で、**iOS シミュレータはホストのネットワークを共有するため同等の手段が無い**(実機も同様)。足すときは 🟡(Android 限定)として書く |
| `shell` / `shellAsync` | `procedure { }` 内で任意 Swift | 🟡 |
| `screenshot` | `screenshot(filename:?)` / `screenshot(_:)` | ✅ 2026-08-03(位置引数版は 2026-08-20 追加。Kotlin は名前付き引数を位置でも渡せるので `screenshot("a.png")` がそのまま通る)**`filename` のみ**(他3引数は Shirates の auto-screenshot 機構の制御で、ftester は毎操作の自動撮影を持たない)。画像はレポートの該当ステップ直後に埋め込む。失敗時の証跡・MCP `ft_screenshot` とは別経路 |
| — | `home()` / `back()` | 🟢 OS 差を吸収した1コマンド |
| — | `clearAppData(bundleID?)` | 🟢 再インストール不要でアプリデータ**と権限**を消す。初回起動・オンボーディング・権限ダイアログのテストが書ける(iOS はシミュレータ専用。キーチェーン/Keystore の値は残る) |
| — | `openURL(url)` / `launchApp(url:)` | 🟢 2026-08-08 ディープリンク配送。**アプリを再起動せず**今の画面の上に遷移を積む(warm)。Shirates に対応物は無い |
| — | `rotateTo(.landscape)` | 🟢 2026-08-10 画面回転。**Shirates に対応物は無い**(src/doc を全文検索して確認)。向きは portrait / landscape の2値のみ —— 契約は「アプリの UI がその向きになること」で、物理的な左右はテストから観測できないため語彙に置かない。回転を使ったシナリオは終了時に元の向きへ自動で戻る |

## 記述子・レポート・テストフロー

| Shirates | ftester | |
|---|---|---|
| `procedure` | 同名(1ステップとして記録) | ✅ |
| `@Deleted` | 同名マクロ | ✅ |
| `describe` / `caption` / `comment` / `target` / `output` / `codeblock` | `scene` の説明文に集約 | 🟡 |
| `macro` | Swift の関数 | ➖ **Swift の関数で足りる**(手順のまとまりは `group("名") { }` が記録側を担う)。独自のマクロ機構は間接参照が増えるだけ |
| `silent` / `info` / `warn` | — | ➖ **ログの出し分けは持たない**。レポートに残るのは**ステップ**で、任意の情報行を足せると「検証していないのに書いてある」記録が増える |
| `manual` / `knownIssue` | — | ➖ **入れない**(生成側が赤を黙らせる逃げ道になり、「失敗はシナリオ全体を中断」の規律と衝突する) |
| `must` / `should` / `want`、`SKIP` / `MANUAL` / `NOTIMPL` | — | ➖ 運用の話でコード生成の能力と無関係(**`@TestClass(platform:)` / `@Test(platform:)` はこれとは別物** —— 赤を黙らせる逃げ道ではなく、既にある platform 軸の粒度を細かくしたもの) |
| `irregularHandler`(lambda 登録) | `irregularHandler(検出sel, dismiss:, maxDismissals: 10)` | 🟡 宣言形が違う |
| — | `iosAlertHandler(alert:, button:)` | 🟢 OS のシステムアラート(権限・ATT = SpringBoard の別プロセス)を1枚ずつ予告して押す。in-app の木に載らないので `irregularHandler` では扱えない形。押せたら登録が外れ、全部外れたら監視も止まる |
| `onScreen` ハンドラ / `onError` ハンドラ | — | ➖ **失敗時の収集はツールが持つ**(2026-08-21 判定)。`onError` 相当(スクショ・木・ログ末尾・FM トリアージ)は失敗経路が自動で残すので、利用者が書く余地は無い。`onScreen`(画面ごとの前処理)はニックネーム/画面定義の機構込みで、ftester は画面を宣言しない |
| — | `group("名前") { }` / `setUp()` / `tearDown()` / `@Test(platform:)`(対象OS宣言。対象外は skipped 記録) | 🟢 |

## データストレージ・キャッシュ

| Shirates | ftester | |
|---|---|---|
| `writeMemo` / `readMemo` / `clearMemo` / `memoTextAs` | Swift 変数 + `exist().text` | ➖ **Swift の変数で足りる**(掴んだ値は `select(…).text` で読める)。専用の記憶域はスコープが曖昧になり、どこで書いた値かを追えなくなる |
| `account` / `app` / `data` / `dataPattern` | — | ➖ **テストデータの外部化は持たない**(Shirates は JSON のデータセットを引く)。ftester は Swift のリテラル・定数で書く —— 生成側が直書きでき、間接参照は読み取りコストが勝つ |
| `clipboard` / `readClipboard` / `writeClipboard` | — | ⏳ **足す**(2026-08-21 判定。基準①)。コピー・ペースト機能そのものを検証する画面でだけ要る。**足す条件**: そういう画面が受け手に出たとき(それまでは無くても回る) |
| `disableCache` / `refreshCache` / `syncCache` / `onDirectAccess` 等 | 内部で自動管理(利用者に露出しない) | ➖ 露出すると生成側が性能問題を誤った手段で解こうとする |
| `disableHandler` / `enableHandler` / `suppressHandler` / `useHandler` | 同名4つ | ✅ 2026-08-21。**両方要る**: ブロック形は出口で必ず戻る一方、**1つの CAE ブロックの内側にしか置けない** —— `condition` で止めて `expectation` で戻す形は命令形でしか書けない(ユーザー指摘)。入れ子可・抑止したまま落ちたら注記に出る |
| `withContext` | — | ➖ **概念ごと要らない**(2026-08-21 判定)。Appium の native/web コンテキスト切替に相当するが、ftester は**WebView を透過的に扱う**(木は a11y、足りなければ DOM。docs/design.md §木はどこから来るか)ので、利用者が切り替える場面が無い |

## セレクタ記法

| Shirates | ftester | |
|---|---|---|
| 直接フィルタ(`text` `id` `class` `value` `checked` `enabled` `pos` 等) | 同等(`access` は `id` に統合) | 🟡 |
| フィルタ内 OR `(a\|b)` | 同名記法 | ✅ 差分2つ: **`(a\|b)&&[2]` は「各節の2番目」**(Shirates は和集合の2番目。節ごとに `[n]` を持つ ftester の構造をそのまま使う)/ **相対セレクタの引数では括弧を自分で書く**(`:right((保存\|OK))`。`:right(...)` の括弧は引数の括弧で `\|` の囲みにならない)。展開数が 32 に達したら validationError |
| 否定フィルタ `属性!=値` / 短縮形 `!値` | 同名記法 | ✅ ただし**序数は否定できない**(`pos!=n` も短縮形 `![2]` も実行前エラー。候補集合を絞れず黙って無視されるため) |
| 相対セレクタ(方向ベース `:right` `:above` + `Button/Image/Input/Label/Switch`) | 同等(`:rightSwitch` 等) | ✅ |
| 相対セレクタ(`:inner*`) | スコープ `>>` | 🟡 |
| 相対セレクタ(`:next*` / `:pre*`) | — | ⏳ **足す**(2026-08-21 判定。基準②)。「同じ行の次のセル」は方向セレクタ(`:right` 等)で幾何的に近似できるが、**折り返す一覧や段組では別の行を掴む**ので、生成側が座標感覚で書いた脆いセレクタになりやすい。**足す条件**: 木の順序で隣を指したい実例が出たとき(方向セレクタで外した報告が1件でも来たら) |
| 相対セレクタ(フローベース `:flow` `:vflow`) | — | ➖ 根拠の無い調整値を要求する(2026-07-26 決定) |
| 相対セレクタ(XML ベース `:parent` `:child` `:sibling` `:ancestor` `:descendant`) | — | 🟡 **祖先方向はスコープ `>>` で書ける**(2026-08-21 判定)。`#row_3>>.button` が `:descendant` 相当。**残る穴は `:parent`(子から親を指す)**で、行の一部(ラベル)を起点に行全体を掴む形が書けない —— **足す条件**は `:next*` と同じ(実例が出たとき) |
| ニックネーム(セレクタ/画面/データセット) | — | ➖ 生成側は直書きでき、腐ってもヒールと再採取で直る。間接参照は読み取りコストが勝つ |
| クラスエイリアス・スペシャルフィルタ | 型語彙 `SelType` で部分的に | 🟡 |
| タイトルセレクタ / Web タイトルセレクタ | — | ➖ **`screenLooksLike` と `exist` で足りる**(2026-08-21 判定)。画面の同定は `screenLooksLike`(FM)か、その画面にしか無い要素の `exist` で書く。タイトル文字列は言語・A/B で変わるため、指定の軸としては弱い |
| — | 型付きセレクタ `Sel`(`.id("x").right(.switch)`) | 🟢 |
| `#x` = アクセシビリティ id のみ | `#x` は **identifier で1件も引けなければ placeholder** を引く | 🟢 **意図的に広げた**(2026-08-15 ユーザー指示)。入力欄は指す手段が経路で割れる —— HTML の id は XCUITest が読む a11y に出ないが placeholder は出る / Android は WebView の版で id と placeholder が**入れ替わる**。Shirates は Appium 一本で経路が割れないためこの問題を持たない。**identifier が当たったらそちらだけ**を使うので、`#x[2]` の序数と `countIs` は経路で変わらない |

---

## 名前の相違(判断済み)

方針は「コマンド名は Shirates をそのまま踏襲」。相違は次のとおり処理した:

| ftester | Shirates | |
|---|---|---|
| `restartApp` | `restartApp` | ✅ **揃えた**(旧名 `relaunchApp` から改名。2026-07-31) |
| `notExist` | `dontExist` | ➖ **`notExist` を維持**(ユーザー決定 2026-07-31)。`notExist` は否定の意味が読み取りやすく、`exist` との対称も保てる。**再提案しない** |
| `optional:` 引数なし | `throwsException: false` | ➖ **全廃**(ユーザー決定 2026-08-02)。空振りを許す引数が操作系にあると腐ったセレクタが緑で残る。代替は `irregularHandler` / `ifCanSelect`、値を読む用途は `select` の空要素。**再提案しない** |

## OS で挙動が割れるもの(利用者に見える差)

| コマンド | 差 |
|---|---|
| `hideKeyboard()` | **Android のみ**。iOS は 501 で失敗する(`XCUIKeyboardKey.escape` / `resignFirstResponder` / nil ターゲット `sendAction` をデバイス上で試して3手とも不発。Compose の入力受け口が自前でフォーカスを保持し UIKit の標準手段が届かない)。iOS で閉じるなら `pressEnter()` |
| `back()` | iOS は**スワイプバック対応のナビ**(NavigationStack 等)を持つ画面でのみ戻れる。独自ナビのアプリではアプリ内の戻るボタンを `tap` する。Android はキーボードが開いていると1回目がキーボードを閉じるのに消費される(OS 仕様) |
| `keyboardIsShown` / `keyboardIsNotShown` | 取得元が OS で違う(iOS xcuitest = AX ツリーの `.keyboard` / iOS in-app = `UITextEffectsWindow` の可視判定 / Android = ホストが `dumpsys` の `InputMethod` window を見る)。**IME が別プロセスの window でアプリの a11y ツリーに出ない**ため |
| `clearInput(sel)` | **Flutter の iOS は in-app エンジンでは消せず XCUITest 経由**になる(自動フォールバック。1〜2秒)。engine への editing state 配送は3回実測して不採用(design.md) |
| `tapAppIcon` | 見つからないときの探索方法が OS で違う: Android はドロワーを開いて `flickCenterToTop` で最大8回スクロール探索、iOS は `flickRightToLeft` で最大5ページ送り(2回連続で画面が変化しなければ打ち切り) |

## 別名族が取る引数(2026-08-02 に仕様として固定)

`tapWithScroll*` / `existWithScroll*` / `selectWithScroll*` は **`maxSwipes:`(select 系は
`requireVisible:` も)しか取らない糖衣**で、本体の全引数は生やさない。`existWithScrollLeft/Right`
を置かないのも同じ判断。**理由**: 別名は「Shirates と同名で書ける」ことだけが価値で、引数が要る
場面では本体の `scroll:` の方が短く読みやすい(`tap(sel, scroll: .down, timeout: 2)`)。
別名にも全引数を生やすと、同じことを2通りで書ける組み合わせが増え、**生成側の語彙のブレ**になる
(この文書冒頭の「何を足すかの判断基準」そのもの)。**引数の欠落を不整合として再提案しない。**

## 足す価値がある残り

**capability gap は無い**(今は書けないテストが無い状態)。残りはどれも「あると便利」の範疇で、
**こちらから実装を提案しない**:

| 項目 | 状態 |
|---|---|
| **祖先方向の相対セレクタ**(`:parent`) | ⏳ **保留**(ユーザー決定 2026-07-31)。id を持つのが子ラベルだけの行を「行として」検証するときに効くが、タップは座標が最前面に当たるので現状でも大きくは困らない。**シナリオを書いていて実際に必要になった時点で提案する**(それまで再提案しない) |
| `notExist` の別名族・`existWithScrollLeft/Right` | ➖ **置かない**(上記「別名族が取る引数」で決着。2026-08-02)|
