# dry-run(No-Load-Run)

[in English](dry_run.md)

`fleetest run --dry-run`(Shirates の No-Load-Run 相当)は、**デバイスにも FM にも触れず**、
シナリオのステップを列挙・検証します。デバイス実行の最中や後でしか気づけない誤りを、数秒で
検知できます。

```bash
fleetest run --dry-run --scenario ログインテスト
```

MCP は同じ検証を `ft_dry_run` で提供し、VSCode 拡張は `fleetest api run --dry-run`
(Test Explorer の「実行 (dry-run)」)経由で実行します。

## 検知できるもの

| 問題 | 検知の仕組み |
|---|---|
| セレクタの構文誤り | どのデバイス呼び出しよりも先にセレクタ式のパーサが走る |
| `ifCanSelect { }` / `.ifElse { }` の中の誤り | dry-run では条件の成否に関わらず**両方のブロックを実行する**ので、どちらの中の構文誤り・未知の `#id` も返る |
| `expectation { }` にアサーションが1つも無い | `verify` がアサーションを数える方法と同じ(`exist`/`notExist`/`textIs` 以下・`thisIs` 系・`appIs`。`select` は数えない)。シナリオ全体でアサーションが**0本**ならさらに強い警告になる |
| 撮った画面のどこにも存在しない `#id` | プロジェクトのセレクタ台帳(`<プロジェクト>/.fleetest/selector-inventory.json`。シナリオ執筆中の `ft_snapshot` 呼び出しで貯まる)と突き合わせて判定する |
| プロファイルのデバイスでは動かないコマンド(`--profile` を付けたときだけ) | 通ったステップのコマンドを、そのシナリオを受け持ちうるデバイス(同じ OS の全台)のエンジンと種別に照らす。下の表 |

最後の項目の補足: 実際に撮った画面についてしか警告しません — 対象の画面(あるいはプラットフォーム)の
記録が台帳に無ければ、推測せず黙ります。台帳が薄いうちも黙ります — 警告が出るのはそのシナリオが
触る `#id` の**2/3以上**が既に台帳にあるときだけです(1画面しか撮っていない状態だと、既存シナリオの
大半を誤って疑ってしまうため)。判定対象は**完全一致の `#id` だけ**で、ワイルドカード(`#row_*`)と
ラベルは対象外です(ラベルは文言変更で変わるのが普通のため)。

dry-run は静的解析ではなく、デバイス呼び出しだけを素通りさせてシナリオを実際に実行します。そのため、
チェック対象のプラットフォームで実行されなかった `ios { }` / `android { }` ブロックの中身は検知できません
(両方の OS を確かめるには、それぞれのプラットフォームで dry-run します)。

## プロファイルのデバイスでは動かないコマンド

`--profile` を付けると、次のコマンドがそのプロファイルの該当デバイスで動かないときに警告を出します
(⚠️ の行。dry-run の合否は変わりません)。デバイス実行では、そのステップで初めて失敗するものです
(`fold` / `unfold` / `hinge` は、折りたためないデバイスでは従来どおり撃たずに対象外(skipped)になります)。
VSCode 拡張の dry-run では、警告は出力パネルに出ます(Test Explorer の各テストの結果には出ません)。

| デバイス | 警告するコマンド |
|---|---|
| iOS で `engine: inapp` を指定したデバイス | `home` / `back` / `appSwitcher` / `tapAppIcon` / `fold` / `unfold` / `hinge` / `swipePointToPoint` / `swipeBy` / `swipeElementToElement` / `hold` / `gesture` / `waitForSettle` |
| iOS の実機 | `fold` / `unfold` / `hinge` / `addMedia` |

```
⚠️ Login.S0010: home at 01_login.swift:30 cannot run on device "iPhone 17 Pro-01" — its engine is inapp, which cannot hand this command to XCUITest (use hybrid or xcuitest for that device)
```

警告するのは**コマンドの名前だけで決まるもの**です。次のものは dry-run からは分からないので警告しません。

- 引数で決まるもの: `tap(holdSeconds:)`(0 より大きい長押し)・`appIs` / `launchApp` / `restartApp` に別のアプリを渡したとき
- アプリの UI フレームワークで決まるもの: `doubleTap` / `pinchOut` / `pinchIn`(UIKit / SwiftUI / RN)・`swipe` / `flick*` / `scroll*`・
  Flutter の `clearInput` / `pressEnter`
- `iosAlertHandler` と SpringBoard のダイアログを指すセレクタ(`engine: inapp` では掴めない)

既定のエンジン(hybrid)は in-app にできない操作を XCUITest へ回すので、上の表の iOS の in-app の行は出ません。

## しないこと

- デバイス/Simulator/Emulator には一切接続せず、FM も呼びません。
- `--profile` はデバイスの用意には使われません。platform を宣言していないシナリオで `ios { }` / `android { }` の
  どちらを検証するかを、プロファイルのデバイスから決めます(iOS のデバイスがあれば `ios`、無ければ `android`。
  VSCode 拡張の dry-run と同じ規則)。プロファイルを使わないときは `--platform` で決まり、上のコマンドの照合もしません。
  MCP の `ft_dry_run` はプロファイルを取らないので、この照合をしません。
- レポートは書かず、結果は後で `--failed` が拾う対象にもなりません。

`--scenario` / `--folder` / `--project` / `--quiet` は通常実行と同じように効き、検証に失敗すれば
exit code `1` になります。そのため `--scenario` を付けない `fleetest run --dry-run` は、
プロジェクト全体をデバイス実行の前に安く通す関門として使えます。

### Link
- [index](../../index_ja.md)
