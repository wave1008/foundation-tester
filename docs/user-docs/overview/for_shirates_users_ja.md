# Shirates 利用者向け

Fleetest の Swift DSL は Shirates(Classic)の慣習に準拠しています。コマンド名・引数名・
既定値・挙動をそのまま踏襲し、独自の改良はしていません。Shirates を知っていれば、ほぼ
そのまま書き始められます。

このページは、同名で使えるもの・名前が違うもの・持たないもの・fleetest にしか無いものを
順に一覧します。

## 構造の対応

| Shirates | fleetest |
|---|---|
| `scenario` / `case` / `condition` / `action` / `expectation` | `scenario` / `scene` / `condition` / `action` / `expectation` |
| `UITest` クラス | `@TestClass` を付けたクラス |
| `@Testrun` | 実行プロファイル(`profiles/runs/<name>.json`) |

## 同名でそのまま使えるもの

| 分類 | コマンド |
|---|---|
| タップ・要素選択 | `tap`(+`holdSeconds:`)、`tapWithScrollDown/Up/Left/Right`、`tapWithoutScroll`、`select`、`selectWithScroll*`、`selectWithoutScroll` |
| 存在検証 | `exist`、`existWithScrollDown/Up`、`existWithoutScroll`、`appIs` |
| テキスト・値の検証 | `textIs` / `textIsNot` / `textContains(Not)` / `textStartsWith(Not)` / `textEndsWith(Not)` / `textMatches(Not)` / `textMatchesDateFormat` / `textIsEmpty` / `textIsNotEmpty`、`valueIs…` も同じ10種一式 |
| 任意の値の検証 | `thisIs` / `thisIsNot` / `thisIsTrue` / `thisIsFalse` / `thisIsEmpty` / `thisIsNotEmpty` / `thisIsBlank` / `thisIsNotBlank` / `thisContains(Not)` / `thisStartsWith(Not)` / `thisEndsWith(Not)` / `thisMatches(Not)` / `thisMatchesDateFormat` / `thisIsGreaterThan(OrEqual)` / `thisIsLessThan(OrEqual)` |
| スクロール | `scrollDown/Up/Left/Right`(+`repeat:`)、`scrollToBottom/Top/RightEdge/LeftEdge`(+`maxSwipes:`)、`withScrollDown/Up/Left/Right`、`withoutScroll` |
| フリック | `flickCenterToTop/Bottom/Left/Right`、`flickLeftToRight/RightToLeft`、`flickBottomToTop/TopToBottom` |
| スワイプ | `swipePointToPoint`、`swipeElementToElement` |
| 分岐・反復 | `ifCanSelect { }.ifElse { }`、`doUntilTrue`、`ios { }` / `android { }` |
| 割り込み制御 | `suppressHandler { }` / `useHandler { }` / `disableHandler()` / `enableHandler()` |
| アプリ制御 | `launchApp` / `terminateApp` / `restartApp` / `installApp` / `removeApp` |
| 待機 | `wait` / `waitForDisplay` / `waitForClose` |
| 記録・フロー | `procedure`、`screenshot`、`verify`、`@Deleted` |

## 名前・形が違うもの

| Shirates | fleetest | 備考 |
|---|---|---|
| `dontExist` | `notExist(sel, timeout:scroll:maxSwipes:)` | `exist` の否定として読みやすい |
| `sendKeys` | `type("…")` / `type(sel, "…")` | `type(sel, "…", replace: true)` で「クリアしてから入力」を1コマンドに畳める(Shirates は2コマンドに分かれる) |
| `pressBack` | `back()` | 両 OS で使える(iOS はナビゲーションバーの戻るボタンが無ければエッジスワイプに落ちる) |
| `pressHome` | `home()` | 両 OS で使える |
| `irregularHandler { }`(ラムダ登録) | `irregularHandler(sel, dismiss:, maxDismissals:)` | ラムダではなくセレクタで宣言する形。出るか不定のアプリ内モーダルを出るたびに自動で閉じる |
| `goPreviousApp` | `appSwitcher()` | アプリスイッチャーを開くだけで、直前のアプリへの切り替えまでは行わない |
| `displayedIs` | `requireVisible:` 引数 + 実行プロファイルの `falsePositiveCheck` | 可視性の確認は独立したアサーションではなく、各コマンドの引数として指定する |

## 持たないもの — 代わりにこう書く

| Shirates | fleetest での代替 |
|---|---|
| ニックネーム(セレクタ/画面/データセットのニックネーム) | セレクタを直接書く(間接参照の機構は無い) |
| `screenIs` / `screenIsOf` / `isScreen(Of)` / `waitScreen(Of)` / `switchScreen` | `screenLooksLike("説明文")`(FM 視覚検証)、またはその画面にしか無い要素への `exist(sel)` |
| `existImage` / `dontExistImage` / `findImage*` / `imageIs` / `imageContains`(画像テンプレートマッチング) | `screenLooksLike("説明文")`(FM マルチモーダル視覚検証) |
| `macro` | 素の Swift 関数 |
| `manual` / `knownIssue` | 無い —— 失敗したコマンドは必ずシナリオを中断する。失敗を「想定内」として黙らせる逃げ道は無い |
| `must` / `should` / `want`、`SKIP` / `MANUAL` / `NOTIMPL` | 無い —— OS 限定のテストは `@TestClass(platform:)` / `@Test(platform:)` を使う |
| データセット(`account` / `app` / `data` / `dataPattern`) | Swift のリテラル・定数をシナリオに直接書く |
| `canSelect` 単独 | `ifCanSelect { }` か `repeatWhileCanSelect(sel, max:) { }` に包んで使う |
| `existAll` / `canSelectAll` / `dontExistAll` | 個別の `exist` をチェーンで並べる(要素ごとに `timeout:` / `scroll:` を指定できる) |
| `tempSelector` / `tempValue` | 呼び出し箇所にセレクタを直接書く |
| `withContext`(native/web コンテキスト切替) | 不要 —— WebView の中身も同じセレクタ・同じコマンドで透過的に読める |

## fleetest 独自のコマンド

Shirates に対応物が無いもの:

| コマンド | 内容 |
|---|---|
| `screenLooksLike("説明文")` | スクリーンショットと自然文を照合する FM マルチモーダル視覚検証 |
| `countIs(sel, n)` | 一致する要素数を検証する |
| `scrollTo(sel, direction:, maxSwipes:)` | セレクタが解決するまでその方向へスクロールする |
| `swipeBy(sel?, dxRatio:dyRatio:)` | 対象のサイズに対する比率で相対ドラッグ(斜め可。地図のパンに使う) |
| `doubleTap(sel?)` | 本物のダブルタップ(`tap` を2回書いても往復で判定時間を超えるため代用できない) |
| `pinchOut(sel?, scale:)` / `pinchIn(sel?, scale:)` | 2本指のピンチズーム |
| `clearAppData(bundleID?)` | 再インストール不要でアプリのデータと権限を消す(初回起動・権限ダイアログのテストに) |
| `openURL(url)` / `launchApp(url:)` | ディープリンク配送(アプリ再起動あり・なしの両方) |
| `rotateTo(.landscape)` | 画面を回転する。シナリオ終了時に元の向きへ自動で戻る |
| `iosAlertHandler(alert:, button:)` | iOS のシステムアラート(権限確認等)を自動で閉じる(別プロセスなので `irregularHandler` では扱えない) |
| `@Draft("理由")` | 実装中(未完成)マーク。`@Deleted` と同様に一括実行から除外されるが、完全一致 ID なら実行できる |
| `group("名前") { }` | 一連のステップをレポート上でラベル付けする。実行・失敗の扱いは変わらない |
| 型付きセレクタ(`Sel`) | `tap(.id("login_btn").or(.text("ログイン")))` —— 文字列版と同じロケータだが、綴り誤りがコンパイルエラーになる |
| `#id` は `placeholder` も引く | identifier で一致する要素が無ければ `#id` は `placeholder` の値も見に行く(入力欄の指し方が経路によって異なるため) |
| セレクタ内の `\|\|` | 候補の和集合 —— `tap` は最初に見つかった候補に着地するので、`"#id\|\|ラベル"` は「id を優先し、無ければラベル」と読める |

### Link
- [index](../index_ja.md)
