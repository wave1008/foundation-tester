# Shirates(Classic)との対応表

ftester の Swift DSL は **Shirates(Classic)に準拠**している(コマンド名・引数名・既定値・挙動を
そのまま踏襲し、独自の「改良」をしない)。この文書は**どこまで揃っていて、何を持たないか**の一覧。

- 読者は**保守者**(利用者向けの全コマンド説明は docs/commands.md)
- **この文書が準拠状況の正典**。コマンドを足す・名前を変える・意図的に持たないと決めたときは
  ここを更新する。docs/design.md「Shirates(Classic) 準拠の方針と承認済みの差分」は
  **理由の説明が要る代表例**を抜き出した表で、全リストではない(理由の詳述はあちらを参照)
- Shirates 側の出典は `~/github/ldi-github/shirates-core`(迷ったらソースを読む)

## 判定の凡例

| | 意味 |
|---|---|
| ✅ | 同名・同義 |
| 🟡 | 相当する機能はあるが名前・形が違う |
| ➖ | **意図的に持たない**(理由は各行。再提案しない) |
| ❌ | 未実装(足す余地がある) |
| 🟢 | ftester 独自(Shirates に無い) |

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
| `canSelect` / `canSelectWithScroll*` / `canSelectNot` | 単独コマンドは無い(`ifCanSelect` / `repeatWhileCanSelect` に内包) | 🟡 |
| `existAll` / `canSelectAll` / `dontExistAll` | — | ➖ **実装しない**(ユーザー決定 2026-07-31)。`exist` のチェーンで書く方が保守しやすく、要素ごとに `timeout:` / `scroll:` 等のオプションも指定できる。**再提案しない** |
| `scanElements` / `*InScanResults` | — | ❌ |
| `tapAppIcon` | `tapAppIcon(name?)` | ✅ 2026-08-03 **`auto` 相当のみ**(`tapAppIconMethod`・マクロ機構は持たない)。名前省略はプロファイルの `appName`(Shirates の `appIconName` 既定=プロファイル、と同義。親が解決して子へ渡す) |
| `tapCenterOfScreen` / `tapTopOfScreen` / `tapCenterOf` / `tapOffset` / `tapDefault` | — | ❌ |
| `tapSoftwareKey` | — | ➖ キーボード要素を snapshot から除外しているため tap できない |
| `widget` | セレクタの型語彙 `.widget` | 🟡 |
| `tempSelector` / `tempValue` | — | ➖ 生成側がセレクタを直書きするので間接参照は読みにくさが勝つ |
| `allElements` / `findElements` / `findWebElement(s)` | — | ❌(スナップショットは `ftester api` / MCP 側) |

## 入力・キーボード

| Shirates | ftester | |
|---|---|---|
| `sendKeys` | `type("…")` / `type(sel, "…")` | 🟡 |
| `pressEnter` | 同名 | ✅ |
| `clearInput` | 同名(`clearInput()` / `clearInput(sel, …)`) | ✅ |
| `hideKeyboard` | 同名だが **Android のみ**(iOS は 501) | 🟡 iOS は実装手段が無い(下記) |
| `keyboardIsShown` / `keyboardIsNotShown` | 同名 | ✅ 取得元は OS で違う(下記) |
| `pressHome` | `home()` | 🟡 OS 共通で提供 |
| `pressBack` | `back()` | 🟡 **両 OS で提供**(iOS はエッジスワイプ) |
| `pressSearch` / `pressTab` / `pressKeys` / `pressAndroid` | — | ❌ |
| `typeChars` | — | ❌ |

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
| `TestElement.swipeTo*` / `swipeOut*`(要素基点) | — | ❌ |
| `flickCenterToTop/Bottom/Left/Right` `flickLeftToRight/RightToLeft` `flickBottomToTop/TopToBottom`(8種) | 同名 | ✅ 2026-08-03 **画面基点のみ**。`scrollableElement`/`safeMode` 引数は無い(`scrollFrame` で足りる) |
| `flickAndGo*` 一族 | `scroll*`/`scrollTo` 系で代替 | ➖ 画面遷移トリガの糖衣は生成側の語彙を増やすだけ |
| 要素基点 `TestElement.flickTo*` / `flickOut*` | — | ❌ |
| `scrollFrame` | 同名(`scroll*` / `scrollTo` / `withScroll*` / `flick*` の引数。セレクタ式) | ✅ 2026-08-02。**型付きセレクタ(`Sel`)版は持たない = 文字列のみ**(ユーザー決定 2026-08-04・**再提案しない**。1対1を保証するのは対象セレクタまで。理由は design.md) |
| `startMarginRatio` / `endMarginRatio` | 同名 | ✅ **既定値は ftester の実測値**(承認済み差分) |
| `scrollableElement` | — | ➖ `scrollFrame` のセレクタ式で足りる |
| `ScrollDirection.None` | `FTScrollDirection` に相当なし | ➖ 「スクロールしない」は `scroll:` 引数の省略(Optional)が担う |
| `scrollDurationSeconds` / `scrollIntervalSeconds` | — | ➖ フリング前提の実測値を優先(承認済み差分) |
| — | `scrollTo(sel, direction:maxSwipes:)` | 🟢 |

## 存在・画面の検証

| Shirates | ftester | |
|---|---|---|
| `exist` | 同名(戻り値チェーン可) | ✅ |
| `existWithScrollDown/Up` | 同名 | ✅ |
| `existWithScrollLeft/Right` | 別名なし(`exist(sel, scroll: .left)` で可) | ➖ **置かない**(下記「別名族が取る引数」) |
| `existWithoutScroll` | 同名 | ✅ |
| `dontExist` | `notExist(sel, timeout:scroll:maxSwipes:)` | 🟡 **名前が違う** |
| `dontExistWithScrollDown/Up` / `dontExistWithoutScroll` | `notExist(scroll:)` に集約 | 🟡 別名は無い |
| `screenIs` | 同名だが **FM の視覚照合**(Shirates は画面ニックネームの識別要素) | 🟡 意味が違う |
| `screenIsOf` / `isScreen(Of)` / `waitScreen(Of)` / `switchScreen` | — | ➖ 画面ニックネーム機構を持たない |
| `cell` / `cellOf` / `getCell` | セレクタのスコープ `>>` | 🟡 |
| `appIs` | `appIs(id, waitSeconds: 15)` | ✅ 2026-08-03 **ニックネーム機構が無く ID を直接書く**(Shirates はニックネーム解決込み)。Android は失敗時 actual を付ける |
| `packageIs` | `appIs` で代用 | ➖ **実装しない**(ユーザー決定 2026-08-03。いったん実装後に削除)。ニックネームが無い ftester では `appIs` が ID 直指定のため Android で**完全に同じ検査**になる。**再提案しない** |
| `isApp` | — | ❌ |
| `verify`(任意内容の検証) | `verify(message) { }` | ✅ 2026-08-03 ブロック内のアサーション1つ以上が全成功で passed。**アサーション0個は inconclusive**(passed でも failed でもない・シナリオは中断しない。Shirates の `MANUAL` 相当は持たない。ユーザー決定 2026-08-03) |
| `existImage` / `dontExistImage` / `findImage*` / `imageIs` / `imageContains` | — | ➖ 画像テンプレートマッチングは非対応(切り出し画像の管理が生成に向かない。FM の `screenIs` が代替) |
| — | `countIs(sel, n)`(節ごとの内訳付き) | 🟢 |

## 属性の検証

| Shirates | ftester | |
|---|---|---|
| `textIs/IsNot/Contains(Not)/StartsWith(Not)/EndsWith(Not)/Matches(Not)/MatchesDateFormat/IsEmpty/IsNotEmpty` | 全て同名 | ✅ 全対称 |
| `valueIs…` 一式(同10種) | 全て同名 | ✅ 全対称 |
| `idIs` | 同名(`FTElement` チェーン) | ✅ |
| `accessIs…` 一式 | `#id` に統合 | 🟡 |
| `enabledIsTrue/False` | `enabledIsTrue()` / `enabledIsFalse()` | ✅ 2026-08-04 糖衣形を同名で踏襲(旧 `isEnabled`/`isDisabled` から改名)。**生文字列の親形 `enabledIs(expected:)` は持たない**(下記 ➖) |
| `checkIsON` / `checkIsOFF` | `checkIsON()` / `checkIsOFF()` | ✅ 2026-08-04 同名で踏襲(旧 `isChecked`/`isNotChecked` から改名) |
| `enabledIs(expected:)` / `checkedIs(expected:)`(生文字列の親形) | — | ➖ **持たない**。生値比較は OS 依存(checked は Android "true"/"false"・iOS "1"/"")で、ftester が持つ正規化済み Bool と衝突する。糖衣形(`enabledIsTrue/False`・`checkIsON/OFF`)は OS 差を吸収済みで正規化と一致する。Shirates 自身も `checkIsON/OFF` の中でこの OS 差を吸収している。**再提案しない** |
| `selectedIs(True/False)` | — | ➖ iOS の selected trait は `checked` に写像している |
| `displayedIs` | `requireVisible:` + `falsePositiveCheck` | 🟡 |
| `classIs(Not)` | セレクタの `.型` で絞る | 🟡 |
| `attributeIs(Not)` / `buttonIsActive(Not)` | — | ❌ |

## 任意の値の検証(thisIs 系)

| Shirates | ftester | |
|---|---|---|
| `thisIs/thisIsNot/thisIsTrue/thisIsFalse` | 同名 | ✅ |
| `thisIsEmpty/NotEmpty/Blank/NotBlank` | 同名 | ✅ |
| `thisContains(Not)/StartsWith(Not)/EndsWith(Not)/Matches(Not)/MatchesDateFormat` | 同名 | ✅ |
| `thisIsGreaterThan(OrEqual)/LessThan(OrEqual)` | 同名 | ✅ |
| `assertEquals` / `assertEqualsNot` | — | ❌ `thisIs` と重複 |

**この群だけは完全準拠**(Swift の言語制約を `FTValue` 転送で吸収した点だけが差分)。

## 分岐・反復

| Shirates | ftester | |
|---|---|---|
| `ifCanSelect { }` | 同名 + `.ifElse { }` | ✅ **「出るか不定」の唯一の表現手段**(`optional:` 廃止後。アプリ内メッセージは `irregularHandler`) |
| `ifCanSelectNot` | `.ifElse` で代替 | 🟡 |
| `doUntilTrue` | 同名(引数名も準拠) | ✅ |
| `android` / `ios` | 同名 | ✅ |
| `ifTrue` / `ifFalse`(Boolean) | 素の Swift `if` | ➖ 分岐の語彙を増やすと生成側の誤選択が増える |
| `ifScreenIs(Not)` / `ifStringIs` / `ifContains` 等 | — | ➖ 同上 |
| `ifCheckON/OFF` | — | ➖ 同上 |
| `ifImageExist(Not)` / `ifImageIs(Not)` | — | ➖ 画像非対応 |
| `emulator` / `simulator` / `virtualDevice` / `realDevice` | — | ➖ 実機/仮想の差はツール側で吸収する方針 |
| `platformName` / `isAndroid` / `isiOS` ほかプロパティ | — | ❌ |
| `osaifuKeitai(Not)` / `specialTag` / `stub(Not)` / `arm64` / `intel` | — | ➖ 対象外 |
| — | `repeatWhileCanSelect(sel, max:)` | 🟢 |

## 同期

| Shirates | ftester | |
|---|---|---|
| `wait` | 同名 | ✅ |
| `waitForDisplay` | `waitForDisplay(sel, waitSeconds: 15)` | ✅ 2026-08-03 スクロールしない・戻り値 `FTElement`。Shirates の `throwsException` に相当する引数は持たない(常に失敗として記録する) |
| `waitForClose` | `waitForClose(sel, waitSeconds: 15)` | ✅ 2026-08-03 **`expression` 省略不可**(Shirates の直前セレクタ再利用の省略形は不採用) |
| `usingWaitSeconds` | `timeout:` 引数 / 実行プロファイル `defaultTimeout` | 🟡 |
| `waitScreen` / `waitScreenOf` | — | ➖ 画面ニックネーム機構を持たない |

## アプリ・OS 操作

| Shirates | ftester | |
|---|---|---|
| `launchApp` / `terminateApp` | 同名 | ✅ |
| `restartApp` | 同名 | ✅ 旧名 `relaunchApp` から改名済み(2026-07-31。下記「名前の相違」) |
| `installApp` / `removeApp` | `installApp(path?)` / `removeApp(id?)` | ✅ 2026-08-03 DSL 化。`installApp` は実行をオーケストレータ(親プロセス)へ委譲し、パス省略時は実行プロファイルの `appPath` を解決する(Shirates の `appPackageFile` 既定に一致)。オーケストレータ無しの単独実行だけ引数必須(省略時は明示エラー)。`removeApp` は id 省略を実行中アプリの既定 bundleID/package に解決する |
| `isAppInstalled` / `launchAppByShell` | CLI 側(`ftester install`)。DSL には無い | ❌ |
| `goPreviousApp` | `appSwitcher()`(スイッチャーを開くだけ) | 🟡 |
| `internetOn/Off` / `wiFiOn/Off` / `mobileOn/Off` | — | ❌ |
| `shell` / `shellAsync` | `procedure { }` 内で任意 Swift | 🟡 |
| `screenshot` | `screenshot(filename:?)` | ✅ 2026-08-03 **`filename` のみ**(他3引数は Shirates の auto-screenshot 機構の制御で、ftester は毎操作の自動撮影を持たない)。画像はレポートの該当ステップ直後に埋め込む。失敗時の証跡・MCP `ft_screenshot` とは別経路 |
| — | `home()` / `back()` | 🟢 OS 差を吸収した1コマンド |
| — | `clearAppData(bundleID?)` | 🟢 再インストール不要でアプリデータ**と権限**を消す。初回起動・オンボーディング・権限ダイアログのテストが書ける(iOS はシミュレータ専用。キーチェーン/Keystore の値は残る) |

## 記述子・レポート・テストフロー

| Shirates | ftester | |
|---|---|---|
| `procedure` | 同名(1ステップとして記録) | ✅ |
| `@Deleted` | 同名マクロ | ✅ |
| `describe` / `caption` / `comment` / `target` / `output` / `codeblock` | `scene` の説明文に集約 | 🟡 |
| `macro` | Swift の関数 | ➖ |
| `silent` / `info` / `warn` | — | ➖ |
| `manual` / `knownIssue` | — | ➖ **入れない**(生成側が赤を黙らせる逃げ道になり、「失敗はシナリオ全体を中断」の規律と衝突する) |
| `must` / `should` / `want`、`SKIP` / `MANUAL` / `NOTIMPL` | — | ➖ 運用の話でコード生成の能力と無関係 |
| `irregularHandler`(lambda 登録) | `irregularHandler(検出sel, dismiss:)` | 🟡 宣言形が違う |
| `onScreen` ハンドラ / `onError` ハンドラ | — | ❌ |
| — | `group("名前") { }` / `setUp()` / `tearDown()` | 🟢 |

## データストレージ・キャッシュ

| Shirates | ftester | |
|---|---|---|
| `writeMemo` / `readMemo` / `clearMemo` / `memoTextAs` | Swift 変数 + `exist().text` | ➖ |
| `account` / `app` / `data` / `dataPattern` | — | ➖ |
| `clipboard` / `readClipboard` / `writeClipboard` | — | ❌ コピー機能自体をテストする時だけ必要 |
| `disableCache` / `refreshCache` / `syncCache` / `onDirectAccess` 等 | 内部で自動管理(利用者に露出しない) | ➖ 露出すると生成側が性能問題を誤った手段で解こうとする |
| `disableHandler` / `enableHandler` / `suppressHandler` / `useHandler` | — | ❌ |
| `withContext` | — | ❌ |

## セレクタ記法

| Shirates | ftester | |
|---|---|---|
| 直接フィルタ(`text` `id` `class` `value` `checked` `enabled` `pos` 等) | 同等(`access` は `id` に統合) | 🟡 |
| フィルタ内 OR `(a\|b)` | 同名記法 | ✅ 差分2つ: **`(a\|b)&&[2]` は「各節の2番目」**(Shirates は和集合の2番目。節ごとに `[n]` を持つ ftester の構造をそのまま使う)/ **相対セレクタの引数では括弧を自分で書く**(`:right((保存\|OK))`。`:right(...)` の括弧は引数の括弧で `\|` の囲みにならない)。展開数が 32 に達したら validationError |
| 否定フィルタ `属性!=値` / 短縮形 `!値` | 同名記法 | ✅ ただし**序数は否定できない**(`pos!=n` も短縮形 `![2]` も実行前エラー。候補集合を絞れず黙って無視されるため) |
| 相対セレクタ(方向ベース `:right` `:above` + `Button/Image/Input/Label/Switch`) | 同等(`:rightSwitch` 等) | ✅ |
| 相対セレクタ(`:inner*`) | スコープ `>>` | 🟡 |
| 相対セレクタ(`:next*` / `:pre*`) | — | ❌ |
| 相対セレクタ(フローベース `:flow` `:vflow`) | — | ➖ 根拠の無い調整値を要求する(2026-07-26 決定) |
| 相対セレクタ(XML ベース `:parent` `:child` `:sibling` `:ancestor` `:descendant`) | — | ❌ **祖先方向**は行単位の検証で効く |
| ニックネーム(セレクタ/画面/データセット) | — | ➖ 生成側は直書きでき、腐ってもヒールと再採取で直る。間接参照は読み取りコストが勝つ |
| クラスエイリアス・スペシャルフィルタ | 型語彙 `SelType` で部分的に | 🟡 |
| タイトルセレクタ / Web タイトルセレクタ | — | ❌ |
| — | 型付きセレクタ `Sel`(`.id("x").right(.switch)`) | 🟢 |

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
| `hideKeyboard()` | **Android のみ**。iOS は 501 で失敗する(`XCUIKeyboardKey.escape` / `resignFirstResponder` / nil ターゲット `sendAction` を実機で試して3手とも不発。Compose の入力受け口が自前でフォーカスを保持し UIKit の標準手段が届かない)。iOS で閉じるなら `pressEnter()` |
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
| **祖先方向の相対セレクタ**(`:parent`) | ⏸ **保留**(ユーザー決定 2026-07-31)。id を持つのが子ラベルだけの行を「行として」検証するときに効くが、タップは座標が最前面に当たるので現状でも大きくは困らない。**シナリオを書いていて実際に必要になった時点で提案する**(それまで再提案しない) |
| `notExist` の別名族・`existWithScrollLeft/Right` | ➖ **置かない**(上記「別名族が取る引数」で決着。2026-08-02)|
