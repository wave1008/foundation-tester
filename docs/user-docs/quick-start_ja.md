# クイックスタート

セットアップ完了後、サンプルアプリを相手にテストシナリオを作り、実行するまでの最短手順です。
シナリオを手で書く必要はありません。
`TestProjects/` を含む作業フォルダがまだ無ければ、先に[はじめに](getting-started_ja.md)の
`/fleetest:fleetest-setup` を済ませてください。

## 1. サンプルアプリを用意する

テスト対象には、EC 買い物アプリのサンプル
[sut-ec-mobile](https://github.com/wave1008/sut-ec-mobile)(Compose Multiplatform・iOS / Android 両対応)
を使います。作業フォルダの隣にダウンロードしてビルドします。このアプリは商品と画像をサーバから
取得するので、サーバも起動しておきます。

### AI アシスタントで実行

```text
https://github.com/wave1008/sut-ec-mobile をこのフォルダの隣に clone して、
1. サーバを起動(/health が ok を返すまで確認)
2. Android の debug APK をビルド
3. iOS シミュレータ向け(arm64 のみ、署名なし)をビルド
前提: JDK 17 と Apple Container が必要。無ければ Homebrew で入れてよい。
シェルの設定ファイルは変更しない。
完了条件: 成果物のパスを報告。インストールと起動確認は不要。
```

<details>
<summary><b>手動で実行(クリックで詳細表示)</b></summary>

JDK 17 と Apple Container(`brew install container`)が要ります。

```bash
git clone https://github.com/wave1008/sut-ec-mobile.git
cd sut-ec-mobile
```

サーバは別のターミナルで起動したままにします。

```bash
./scripts/dev-server.sh    # http://localhost:8090
```

続けてアプリをビルドします。

```bash
# iOS シミュレータ(-destination の name は手元にあるシミュレータの名前にする)
xcodebuild -project iosApp/iosApp.xcodeproj -scheme iosApp -configuration Debug \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/ios-sim CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
#   -> build/ios-sim/Build/Products/Debug-iphonesimulator/iosApp.app

# Android
./gradlew :composeApp:assembleDebug
#   -> composeApp/build/outputs/apk/debug/composeApp-debug.apk
```

サーバの起動方法の詳細は sut-ec-mobile の `server/README.md` にあります。

</details>

## 2. プロファイルを用意する

実行には2つのプロファイルが必要です —— 対象アプリを定めるアプリプロファイル、使うデバイスを
列挙する実行プロファイル。アプリ ID は iOS / Android とも `com.sutec.mobile` です。

### AI アシスタントで実行

```text
このフォルダの隣にある sut-ec-mobile のアプリ(ビルド済み)向けに、fleetest のプロファイルを作成して。
1. iOS と Android それぞれのアプリプロファイルと実行プロファイルを fleetest profile setup で作成(JSON は手で書かない)
2. fleetest profile list で、アプリとデバイスまで解決されることを確認
設定値: アプリの表示名は SUT Store、アプリ ID は iOS / Android とも com.sutec.mobile、アプリのパスは sut-ec-mobile のビルド済みの .app(iOS シミュレータ向け)と .apk、デバイスは自動選択(--auto-device)。
利用できるシミュレータ / エミュレータが無ければ、作成せずに報告する。
完了条件: 作成した実行プロファイルの名前を報告。テストの実行は不要。
```

実行プロファイルの名前はプラットフォーム名(`ios` と `android`)になります。

<details>
<summary><b>手動で実行(クリックで詳細表示)</b></summary>

作業フォルダに戻って実行します。

```bash
fleetest profile setup --platform ios --app-id com.sutec.mobile --auto-device \
  --app-path ../sut-ec-mobile/build/ios-sim/Build/Products/Debug-iphonesimulator/iosApp.app
```

`--app-path` にビルドしたアプリを渡すと、実行時にデバイスへ自動でインストールされます。
`--auto-device` は、このマシンで利用可能なシミュレータ/エミュレータを自動で選びます。
このコマンドでは実行プロファイルの名前はプラットフォーム名(ここでは `ios`)になります。

</details>

プロファイルの詳細は[プロファイル](./project/profiles_ja.md)。

## 3. テストシナリオを作る

どちらの進め方でも、`TestProjects/<プロジェクト>/scenarios/` に Swift ファイルができます。
セレクタは実画面から採られます。書かれる内容を読みたいときは
[セレクタ式](./selector/selector_expression_ja.md)を参照してください。

### AI アシスタントで実行

```text
sut-ec-mobile(SUT Store)のログイン画面だけを対象に、探索的テストを作成して。
```

AI アシスタントはデバイス上でアプリを起動し、ログイン画面を操作しながら要素を読み取って、
見つけた挙動をテストシナリオに落とします。別の画面を対象にするときは、画面名を替えてください。

<details>
<summary><b>手動で実行(クリックで詳細表示)</b></summary>

VSCode 拡張のデバイスモニターを開き、「ライブ操作」タブで録画します。画面に映ったアプリを
そのまま操作すると、操作した内容がシナリオとして生成されます。

</details>

## 4. デバイス無しで検証する(dry-run)

デバイスに触れる前に dry-run を実行します。セレクタの構文誤り・到達しない scene・検証の無い
`expectation` を数秒で検知します。

### AI アシスタントで実行

```text
作成したシナリオを dry-run で検証して
```

<details>
<summary><b>手動で実行(クリックで詳細表示)</b></summary>

```bash
fleetest run --dry-run
```

</details>

## 5. デバイスで実行する

### AI アシスタントで実行

```text
作成したシナリオを ios プロファイルで実行して
```

<details>
<summary><b>手動で実行(クリックで詳細表示)</b></summary>

```bash
# クローン構成(foundation-tester のクローン内で作業している場合)
swift run fleetest run --profile ios

# 外部パッケージ構成(TestProjects/ を持つ別の作業フォルダ)
../foundation-tester/.build/debug/fleetest run --profile ios
```

`--profile` には、ステップ2で用意した実行プロファイルの名前を渡します(上のコマンドなら `ios`。
`--run <名前>` を指定した場合はその名前)。アプリ・デバイス・実行時設定はそこから解決されます。

VSCode からは **Test Explorer** でシナリオを選び、**実行**をクリックします。

</details>

## 6. 結果を見る

実行のたびに、成否を問わず `TestProjects/<プロジェクト>/reports/` にシナリオごとの Markdown
レポートが出ます。ステップごとの結果とスクリーンショット、失敗時は失敗メッセージと失敗時点の
要素一覧、自己修復の提案が載ります。

### AI アシスタントで実行

```text
今の実行結果を要約して。失敗があればレポートから原因を調べて
```

<details>
<summary><b>手動で実行(クリックで詳細表示)</b></summary>

`reports/` のレポートを開きます。VSCode では Test Explorer が成否を直接表示し、そこからレポートを
開けます。

</details>

### Link
- [index](index_ja.md)
