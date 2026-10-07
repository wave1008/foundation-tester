# テストコードを書くときの便利機能

[in English](helpers.md)

シナリオはサンドボックスの中で動くので、普段の Swift の書き方(一時フォルダに書く・環境変数を読む・`URLSession` で
通信する)がそのままでは通らない場面があります。fleetest は、その代わりになる機能を用意しています。
どれもサンドボックスの中でそのまま動きます。

| やりたいこと | 使う機能 |
|---|---|
| ファイルを書く・残す | `TestLog.directoryForLog` / `TestLog.directoryForTemp` |
| アカウント・パスワード・入力値を使う | `account()` / `data()` |
| CSV・JSON・画像をファイルのまま使う | `dataFile()` |
| 写真・動画をデバイスに入れる | `addMedia()` |
| API でテストデータを用意する・後片付けする | `httpRequest` / `fleetestURLSession` |
| シナリオ間で値を渡す | `writeMemo` / `readMemo` |
| 秘密をレポートに残さない | `redactAccountValues` |
| 外部の Swift パッケージを使う | `fleetestScenarioDependencies` |
| run の前後に DB やスタブサーバを用意する | `setup.sh` / `teardown.sh` |

## ファイルを書く(TestLog)

書けるのは `TestLog` の2つのフォルダ(とその下)だけです。`NSTemporaryDirectory()` には書けません。

```swift
let csv = TestLog.directoryForLog.appendingPathComponent("prices.csv")     // レポートと一緒に残る
try? "name,price\n".write(to: csv, atomically: true, encoding: .utf8)

let work = TestLog.directoryForTemp.appendingPathComponent("unzipped")     // シナリオの終わりに消える
```

詳細: [出力フォルダと一時フォルダ(TestLog)](../reference/commands/test_log_ja.md)

## アカウントとテストデータ(account, data)

シナリオに直書きせず、JSON ファイルから引きます。リポジトリに入れてよい値はプロジェクトの `dataset/` に、
パスワードなどはこの Mac の `~/.config/fleetest/dataset/<プロジェクト名>/` に置きます(属性単位で上書きされます)。
シェルの環境変数はシナリオに渡らないので、トークンもこちらに置きます。

```swift
type("#login_id", account("[account1].id"))
type("#login_password", account("[account1].password"))
```

詳細: [テストデータ・アカウント(account, data)](../reference/commands/dataset_ja.md)

## ファイルを使う(dataFile)・写真を入れる(addMedia)

多数の行の CSV・API に送る本文・画像は、データセットのフォルダにファイルとして置きます。この Mac 側
(`~/.config/fleetest/dataset/<プロジェクト名>/`)にあればそちらを、無ければプロジェクトの `dataset/` を使います。

```swift
let body = (try? String(contentsOf: dataFile("api/new_order.json"), encoding: .utf8)) ?? ""
addMedia("img/avatar.png")   // 写真を選ぶ画面のテストに(iOS 実機には入れられません)
```

`addMedia` で送れるのはデータセットのフォルダの中のファイルだけです。

詳細: [テストデータ・アカウント(account, data)](../reference/commands/dataset_ja.md)

## 外部と通信する(httpRequest, fleetestURLSession)

宛先を `allowedDomains` で許可したうえで、`httpRequest` を使います。サンドボックスのプロキシを設定済みです。

```swift
let response = httpRequest("https://api.example.com/orders", method: "POST",
                           headers: ["Content-Type": "application/json"],
                           body: #"{"item": "widget"}"#)
response.status.thisIs(201)
```

`URLSession` を自分で使うときは、`URLSession.shared` ではなく `fleetestURLSession` を使います
(プロキシが設定済みの `URLSession` です)。

詳細: [HTTP リクエスト(httpRequest)](../reference/commands/http_request_ja.md)・[シナリオから外部へ通信する](../reference/writing/network_access_ja.md)

## シナリオ間で値を渡す(memo)

`setUpDevice()` で用意した値を、同じデバイスの他のシナリオへ渡します。ファイルを自分で書いて受け渡す必要はありません。

詳細: [メモ(writeMemo, readMemo, clearMemo, memoTextAs)](../reference/commands/memo_ja.md)

## 秘密をレポートに残さない(redactAccountValues)

既定では、`type(account("[account1].password"))` の値はステップの説明・実行ログ・レポートにそのまま残ります。
この Mac の `~/.config/fleetest/config.json` に `"redactAccountValues": true` を書くと、`account()` の値を `***` に伏せます。
スクリーンショットに写った文字は伏せられません。

詳細: [テストデータ・アカウント(account, data)](../reference/commands/dataset_ja.md)

## 外部の Swift パッケージを使う

ワンタイムパスワードの生成や JSON の処理などのパッケージは、`Package.swift` の `dependencies:` と
`fleetestScenarioDependencies` の2箇所に書くとシナリオから import できます。読み込んだライブラリのコードも、
シナリオと同じサンドボックスの中で動きます(依存のビルドだけは外で動くので、信頼できるパッケージだけを足してください)。

詳細: [テストプロジェクトの作成](../reference/project/creating_project_ja.md)

## run の前後で処理を走らせる(setup.sh, teardown.sh)

テスト対象のアプリが依存する DB・スタブサーバのように、サンドボックスの中ではできない準備は、
`TestProjects/<プロジェクト>/workspace/scripts/setup.sh` / `teardown.sh` に書きます。これらは run の開始時と
終了時にサンドボックスの外で走ります(MCP の `ft_run_scenario` では走りません)。

詳細: [自分で機能を足す](../reference/writing/extending_ja.md)

## デバイスの操作は DSL のコマンドで

`adb`・`simctl`・`devicectl` をシナリオから直接呼ぶと、fleetest 本体が決まった形のものだけを代わりに実行し、
それ以外は断ります。アプリのインストール・起動・データの消去・URL を開くといった操作は、
DSL のコマンド([installApp](../reference/commands/install_app_ja.md)・[launchApp](../reference/commands/launch_app_ja.md) など)を使ってください。

## 関連

- [アクセスできるフォルダと通信先](access_ja.md) —— 書ける場所・読めない場所・通信先・設定ファイル
- [サンドボックスの考え方](sandbox_ja.md)

### Link
- [index](../index_ja.md)
