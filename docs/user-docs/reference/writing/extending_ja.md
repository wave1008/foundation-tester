# 自分で機能を足す

組み込みのコマンドだけでは足りないとき、fleetest 本体を改造せずに自分のプロジェクトの中で機能を足す方法を
まとめます。足し方は大きく5つです。どれもシナリオ(`.swift`)か、テストプロジェクトのファイルに書きます。

| やりたいこと | 足し方 | 詳細 |
|---|---|---|
| 繰り返す手順をまとめたい | Swift の関数(独自コマンド) | [独自コマンド](../testclass/custom_commands_ja.md) |
| DSL に無い処理を1ステップにしたい | `procedure { }` | [記述子](../commands/descriptors_ja.md) |
| テストデータ・外部のサーバとつなぎたい | `account()` / `data()` / `dataFile()` / `httpRequest` | [テストデータ・アカウント](../commands/dataset_ja.md)・[HTTP リクエスト](../commands/http_request_ja.md) |
| ライブラリを使いたい・共通部品を共有したい | `Package.swift` に依存を足す | [テストプロジェクトの作成](../project/creating_project_ja.md) |
| run の前後に DB やスタブサーバを用意したい | 開始/終了スクリプト | このページの[run の前後で処理を走らせる](#run-の前後で処理を走らせる) |

## 1. 手順を関数にまとめる

ログイン・前提状態の用意・画面ごとの定番操作など、何度も出る手順は**素の Swift 関数**にします。
`@FTCommand("説明")` を付けると、その関数がコマンドの一覧(`ft_dsl_commands`)に載るので、シナリオを書く AIアシスタントが
同じ手順を手で書き直さずに再利用するようになります。一覧に載るのは名前・呼び出し方・説明文だけで、この Mac の
AIアシスタントに返すだけです(外部には出ません。MCP から実行できるようにもなりません)。

```swift
@FTCommand("メールとパスワードでログインし、ホーム画面まで進む")
func login(user: String, password: String) {
    tap("#login_email")
    type(user)
    tap("#login_password")
    type(password)
    tap("#btn_login")
    exist("#home_title")
}
```

掴んだ要素に対して働くヘルパーは `extension FTElement` に書くと、`select("#x").tapAndConfirm("#y")` の形で
チェーンできます。

よくある使い方:

- **アプリ固有の状態を作る関数**: 「ログイン済み」「カートが空」「初回チュートリアルを済ませた」など、
  チームの取り決めをここに閉じ込めます。
- **画面ごとのまとまり**: 画面ごとに関数をファイルへ分けます(Page Object に近い形)。`@FTCommand` を付けられるのは
  トップレベルの関数と `extension` の中のメソッドだけで、`class` / `struct` の中には付けられません。
- **定番部品の操作**: 日付ピッカー・途中まで払うスワイプ・[`gesture`](../commands/gestures_ja.md) で組んだ独自のマルチタッチなど。
  部品ごとの癖は [UI 部品ごとの書き方と癖](ui_component_patterns_ja.md) にあります。

レポートに並ぶのは関数の中の個々のコマンドで、関数の名前は出ません。まとまりとして見せたいときは
`group("名前") { }` で包みます。

## 2. DSL に無い処理を1ステップにする

`procedure("説明") { ... }` の中には任意の Swift(`try` / `await` を含む)を書けて、レポートには1ステップとして残ります。
中で throw すると、コマンドの失敗と同じようにシナリオが中断します。

```swift
procedure("テスト用の注文を API で作る") {
    try await seedTestOrder()   // 自分で書いた async 関数
}
```

画面に依らない値(API の応答・計算結果など)の検証には [`thisIs` 系](../commands/any_value_assertion_ja.md)を使います
(`response.status.thisIs(201)` など)。

- 前のステップが失敗した後に走らせたくない処理は、必ず `procedure { }` に包みます(包まない素の Swift は、
  前のステップが失敗していても実行されます)。
- 出るか分からないアプリ内のお知らせ・キャンペーンは、`beforeEach()` で
  [`irregularHandler`](../commands/irregular_handler_ja.md) を宣言しておくと自動で閉じます。
  割り込みに吸われたかもしれない操作をツールは撃ち直さないので、復帰が要るなら関数で書きます。
  **もう一度実行しても安全な操作(画面遷移のタップなど)だけ**にしてください。送信・購入を撃ち直すと二重に実行されることがあります。
- クラスの前後処理は `beforeEach()` / `afterEach()`、デバイスごとに1回だけの準備と片付けは
  `setUpDevice()` / `tearDownDevice()` に書きます。

## 3. テストデータ・外部のサーバとつなぐ

| 関数 | 使いどころ |
|---|---|
| `account()` / `data()` | アカウントや入力値を JSON から引きます。パスワードなどはこの Mac の設定側に置き、リポジトリに入れません |
| `dataFile()` | CSV・JSON・画像などをファイルのまま使います |
| `addMedia()` | 写真・動画をデバイスの写真ライブラリへ入れます(iOS 実機には入れられません) |
| `httpRequest` / `fleetestURLSession` | API でテストデータを用意する・後片付けする・サーバ側の状態を読む |
| [`writeMemo` / `readMemo`](../commands/memo_ja.md) | `setUpDevice()` で用意した値を他のシナリオへ渡す |

よくある使い方:

- テストの前に API でユーザーや注文を作り、`afterEach()` で消す
- 認証メールやワンタイムパスワードを受信箱の API から取ってきて入力する
- 画面に出た値を、サーバ側の値と突き合わせる

シナリオは既定では Mac の外へ通信できません。宛先をこの Mac の設定で許可してから使います
([シナリオから外部へ通信する](network_access_ja.md))。

## 4. ライブラリと共通部品を足す

外部の Swift パッケージ(ワンタイムパスワードの生成・暗号・JSON の処理など)や、複数のテストプロジェクトで
共有する自前のターゲットは、`Package.swift` の `dependencies:` と `fleetestScenarioDependencies` の2箇所に書くと
シナリオから import できます。書き方は[テストプロジェクトの作成](../project/creating_project_ja.md)の
「シナリオで使う依存を足す」にあります。

足した依存のビルド(マクロ・ビルドプラグインを含む)はサンドボックスの外で動きます。信頼できるパッケージだけを足してください。

## run の前後で処理を走らせる

テスト対象のアプリが依存する DB・スタブサーバなどを、run の前に起こして後で片付けるには、
テストプロジェクトのワークスペースにスクリプトを置きます。

| ファイル | 走るとき |
|---|---|
| `TestProjects/<プロジェクト>/workspace/scripts/setup.sh` | run の開始時。デバイスに触る前 |
| `TestProjects/<プロジェクト>/workspace/scripts/teardown.sh` | run の終了時 |

- **置けば実行されます**(プロファイルに書く項目はありません)。無ければ何もしません。
- **`setup.sh` が 0 以外で終わると、run を止めます**(シナリオは1本も走りません)。そのときも `teardown.sh` は走ります。
  `teardown.sh` の失敗は警告だけで、結果は赤になりません。
- 実行権が無ければ `/bin/sh` で起動します。実行権があれば shebang に従います(Python などでも書けます)。
- タイムアウトはありません。出力の無い時間が 60 秒を超えるたびに警告が1行出ます。
- スクリプトに渡る環境変数は `FT_HOOK`(`setup` / `teardown`)・`FT_WORKSPACE`・`FT_PROJECT`・`FT_PROFILE`・
  `FT_REPORT_DIR`・`FT_IOS_DEVICES`・`FT_ANDROID_DEVICES`(空白区切りのデバイス名)です。値が無いときも変数自体は渡ります。
  Emulator の adb serial・Simulator の UDID は渡りません(必要なら `adb devices` などを自分で呼びます)。
- [リモート実行](../../fleet/remote_runners_ja.md)へ送った run では、スクリプトはランナー機の上で走ります。
  ssh 越しに起こしたプロセスは同じ機械の他のアドレス(コンテナの仮想ネットワーク・LAN)へ繋げないことがあるので、
  依存サービスには `127.0.0.1` で繋いでください。
- スクリプトはサンドボックスの外で動きます。`fleetest run` と MCP の `ft_start_run` では走りますが、
  `ft_run_scenario`(シナリオを1本だけ回す MCP ツール)では走りません。

## 結果を自分の仕組みに流す

- **CI**: `fleetest run --junit <パス>` の JUnit XML と exit code を CI に渡します([CI で回す](../../in_action/ci_ja.md))。
- **集計・通知**: 結果 JSON([スキーマ](../../../results-json.md))を読んで、自前のダッシュボードやチャットへの通知に流します。
  `fleetest results` で集計できる範囲は[結果の分析](../running/results_analysis_ja.md)にあります。

## 足せないもの

| できないこと | 理由・代わりの方法 |
|---|---|
| デバイスへの新しい種類の操作・新しく取得する情報 | ドライバとブリッジの機能なので、fleetest 本体の変更が要ります。組み込みのコマンドを組み合わせて書けるものだけが、自分で足せる範囲です |
| シナリオから任意のファイルを書く・ホームの秘密を読む | シナリオはサンドボックスの中で動きます。書くときは [`TestLog.directoryForLog` / `directoryForTemp`](../commands/test_log_ja.md) を使います |
| シナリオから他のアプリを起こす・adb や simctl を直接使う | 決まった操作だけを fleetest 本体が代わりに行います。adb はこの Mac の設定 `allowDirectAdb` で開けられます([アクセスできるフォルダと通信先](../../security/access_ja.md)) |
| 独自コマンドを `ft_batch` で実行する | `ft_batch` が実行するのは組み込みのコマンドだけです。独自コマンドはシナリオの `.swift` に書いて実行します |
| シェルの環境変数(トークンなど)をシナリオで読む | シナリオには fleetest が使う変数しか渡りません。秘密は `account()` のこの Mac 側のファイルに置きます |

### Link
- [index](../../index_ja.md)
