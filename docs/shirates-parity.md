# Shirates(Classic)との対応表

ftester の Swift DSL は **Shirates(Classic)に準拠**している(コマンド名・引数名・既定値・挙動を
そのまま踏襲し、独自の「改良」をしない)。この文書は**どこまで揃っていて、何を持たないか**の一覧。

- 読者は**保守者**(利用者向けの全コマンド説明は docs/commands.md)
- 承認済みの差分と、その理由は docs/design.md「Shirates(Classic) 準拠の方針と承認済みの差分」
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
| `tap` | `tap(sel, optional:timeout:scroll:maxSwipes:)` | ✅ |
| `tap(holdSeconds:)` | `press(sel, duration:)` | 🟡 別コマンドに切り出し |
| `tapWithScrollDown/Up/Left/Right` | 同名 | ✅ |
| `tapWithoutScroll` | 同名 | ✅ |
| `select` / `selectWithScroll*` / `selectWithoutScroll` | `exist` が解決要素(`FTElement`)を返す | 🟡 |
| `canSelect` / `canSelectWithScroll*` / `canSelectNot` | 単独コマンドは無い(`ifCanSelect` / `repeatWhileCanSelect` に内包) | 🟡 |
| `existAll` / `canSelectAll` / `dontExistAll` | — | ➖ **実装しない**(ユーザー決定 2026-07-31)。`exist` のチェーンで書く方が保守しやすく、要素ごとに `timeout:` / `scroll:` 等のオプションも指定できる。**再提案しない** |
| `scanElements` / `*InScanResults` | — | ❌ |
| `tapAppIcon` | — | ❌ |
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
| `swipeElementToElementAdjust` / `TestElement.swipeTo*` `swipeOut*` | — | ❌ |
| `flick*` 一族(14種) | — | ❌ |
| `scrollFrame` / マージン / 時間指定 | — | ➖ ブリッジのスワイプが全画面固定(承認済み差分) |
| — | `scrollTo(sel, direction:maxSwipes:)` | 🟢 |

## 存在・画面の検証

| Shirates | ftester | |
|---|---|---|
| `exist` | 同名(戻り値チェーン可) | ✅ |
| `existWithScrollDown/Up` | 同名 | ✅ |
| `existWithScrollLeft/Right` | 別名なし(`exist(sel, scroll: .left)` で可) | 🟡 別名だけ欠落 |
| `existWithoutScroll` | 同名 | ✅ |
| `dontExist` | `notExist(sel, timeout:scroll:maxSwipes:)` | 🟡 **名前が違う** |
| `dontExistWithScrollDown/Up` / `dontExistWithoutScroll` | `notExist(scroll:)` に集約 | 🟡 別名は無い |
| `screenIs` | 同名だが **FM の視覚照合**(Shirates は画面ニックネームの識別要素) | 🟡 意味が違う |
| `screenIsOf` / `isScreen(Of)` / `waitScreen(Of)` / `switchScreen` | — | ➖ 画面ニックネーム機構を持たない |
| `cell` / `cellOf` / `getCell` | セレクタのスコープ `>>` | 🟡 |
| `appIs` / `packageIs` / `isApp` | — | ❌ |
| `verify`(任意内容の検証) | — | ❌ |
| `existImage` / `dontExistImage` / `findImage*` / `imageIs` / `imageContains` | — | ➖ 画像テンプレートマッチングは非対応(切り出し画像の管理が生成に向かない。FM の `screenIs` が代替) |
| — | `countIs(sel, n)`(節ごとの内訳付き) | 🟢 |

## 属性の検証

| Shirates | ftester | |
|---|---|---|
| `textIs/IsNot/Contains(Not)/StartsWith(Not)/EndsWith(Not)/Matches(Not)/MatchesDateFormat/IsEmpty/IsNotEmpty` | 全て同名 | ✅ 全対称 |
| `valueIs…` 一式(同10種) | 全て同名 | ✅ 全対称 |
| `idIs` | 同名(`FTElement` チェーン) | ✅ |
| `accessIs…` 一式 | `#id` に統合 | 🟡 |
| `enabledIs` / `enabledIsTrue/False` | `isEnabled` / `isDisabled` | 🟡 |
| `checkedIs` / `checkIsON` / `checkIsOFF` | `isChecked` / `isNotChecked` | 🟡 |
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
| `ifCanSelect { }` | 同名 + `.ifElse { }` | ✅ |
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
| `waitForDisplay` | 暗黙待ち(各コマンドの `timeout:` ポーリング) | 🟡 |
| `waitForClose` | `notExist`(消えるまで待つ) | 🟡 |
| `usingWaitSeconds` | `timeout:` 引数 / 実行プロファイル `defaultTimeout` | 🟡 |
| `waitScreen` / `waitScreenOf` | — | ➖ 画面ニックネーム機構を持たない |

## アプリ・OS 操作

| Shirates | ftester | |
|---|---|---|
| `launchApp` / `terminateApp` | 同名 | ✅ |
| `restartApp` | `restartApp` | 🟡 **名前が違う** |
| `installApp` / `removeApp` / `isAppInstalled` / `launchAppByShell` | CLI 側(`ftester install`)。DSL には無い | ❌ |
| `goPreviousApp` | `appSwitcher()`(スイッチャーを開くだけ) | 🟡 |
| `internetOn/Off` / `wiFiOn/Off` / `mobileOn/Off` | — | ❌ |
| `shell` / `shellAsync` | `procedure { }` 内で任意 Swift | 🟡 |
| `screenshot` | ステップごとに自動取得 + MCP `ft_screenshot` | 🟡 |
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

また `press` の意味が反転している: Shirates の `press*` はハードキー/キーボード
(`pressBack` `pressEnter` …)で、長押しは `tap(holdSeconds:)`。ftester は `press(sel, duration:)`
= 長押しかつ `pressEnter()` も持つため、`press` 族の中で意味が2系統に割れている。

## OS で挙動が割れるもの(利用者に見える差)

| コマンド | 差 |
|---|---|
| `hideKeyboard()` | **Android のみ**。iOS は 501 で失敗する(`XCUIKeyboardKey.escape` / `resignFirstResponder` / nil ターゲット `sendAction` を実機で試して3手とも不発。Compose の入力受け口が自前でフォーカスを保持し UIKit の標準手段が届かない)。iOS で閉じるなら `pressEnter()` |
| `back()` | iOS は**スワイプバック対応のナビ**(NavigationStack 等)を持つ画面でのみ戻れる。独自ナビのアプリではアプリ内の戻るボタンを `tap` する。Android はキーボードが開いていると1回目がキーボードを閉じるのに消費される(OS 仕様) |
| `keyboardIsShown` / `keyboardIsNotShown` | 取得元が OS で違う(iOS xcuitest = AX ツリーの `.keyboard` / iOS in-app = `UITextEffectsWindow` の可視判定 / Android = ホストが `dumpsys` の `InputMethod` window を見る)。**IME が別プロセスの window でアプリの a11y ツリーに出ない**ため |
| `clearInput(sel)` | **Flutter の iOS は in-app エンジンでは消せず XCUITest 経由**になる(自動フォールバック。1〜2秒)。engine への editing state 配送は3回実測して不採用(design.md) |

## 足す価値がある残り

**capability gap は無い**(今は書けないテストが無い状態)。残りはどれも「あると便利」の範疇で、
**こちらから実装を提案しない**:

| 項目 | 状態 |
|---|---|
| **祖先方向の相対セレクタ**(`:parent`) | ⏸ **保留**(ユーザー決定 2026-07-31)。id を持つのが子ラベルだけの行を「行として」検証するときに効くが、タップは座標が最前面に当たるので現状でも大きくは困らない。**シナリオを書いていて実際に必要になった時点で提案する**(それまで再提案しない) |
| `notExist` の別名族・`existWithScrollLeft/Right` | ⏸ 引数で書けるので不要(人間のタイプ量削減が目的の糖衣)|
