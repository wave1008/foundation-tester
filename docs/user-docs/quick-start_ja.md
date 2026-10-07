# クイックスタート

[はじめに(インストール)](getting-started_ja.md)が済んだ後、サンプルアプリを対象にテストシナリオを作り、実行するまでの最短手順です。
シナリオを手で書く必要はありません。

## 1. サンプルアプリを用意する

テスト対象として、EC 買い物アプリのサンプル
[sut-ec-mobile](https://github.com/wave1008/sut-ec-mobile)(Compose Multiplatform・iOS / Android 両対応)
を使います。

### AIへの指示文

```text
https://github.com/wave1008/sut-ec-mobile をこのフォルダの隣に clone して、サーバを起動して。
サーバはこのセッションを閉じても止まらないよう、nohup などで起動して。
JDK 17 と Apple Container が必要。無ければ Homebrew でインストールしてよい。
シェルの設定ファイルは変更しないで。アプリはビルドしなくてよい。
/health が ok を返したら、完了を報告して。
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

サーバの起動方法の詳細は sut-ec-mobile の `server/README.md` にあります。

</details>

## 2. プロファイルを用意する

アプリプロファイルと実行プロファイルを作成します。

### AIへの指示文

iOS の場合:

```text
sut-ec-mobile の iOS アプリをビルドし、プロファイルを作成して。デバイスは2台にして。
```

Android の場合:

```text
sut-ec-mobile の Android アプリをビルドし、プロファイルを作成して。デバイスは2台にして。
```

<details>
<summary><b>手動で実行(クリックで詳細表示)</b></summary>

sut-ec-mobile のフォルダでアプリをビルドします。

```bash
# iOS Simulator(-destination の name は手元にある Simulator の名前にする)
xcodebuild -project iosApp/iosApp.xcodeproj -scheme iosApp -configuration Debug \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/ios-sim CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
#   -> build/ios-sim/Build/Products/Debug-iphonesimulator/iosApp.app

# Android
./gradlew :composeApp:assembleDebug
#   -> composeApp/build/outputs/apk/debug/composeApp-debug.apk
```

作業フォルダに戻って実行します。テストプロジェクトはインストールでは作られないので、最初に作ります
(AIアシスタントに頼んだときは自動で作られます。VSCode 拡張も Reload Window 後の起動時に作ります)。

```bash
../foundation-tester/.build/debug/fleetest project create project1

# iOS
../foundation-tester/.build/debug/fleetest profile setup --platform ios --app-id com.sutec.mobile.ios --auto-device \
  --app-path ../sut-ec-mobile/build/ios-sim/Build/Products/Debug-iphonesimulator/iosApp.app

# Android
../foundation-tester/.build/debug/fleetest profile setup --platform android --app-id com.sutec.mobile.android --auto-device \
  --app-path ../sut-ec-mobile/composeApp/build/outputs/apk/debug/composeApp-debug.apk
```

`--app-path` にビルドしたアプリを渡すと、実行時にデバイスへ自動でインストールされます。
`--auto-device` は、最新の iOS ランタイムと最新の Pixel を使う Simulator/Emulator を自動で選びます
(足りなければ作成します。iOS のランタイムが未導入のときは数 GB をダウンロードするので数分〜数十分かかります。
起動していないものは実行時に自動で起動します)。アプリプロファイルの名前は `ios-app`・`android-app`、実行プロファイルの名前は `ios-run`・`android-run` になります。
手で登録するのは1台です。2台目は VSCode 拡張のデバイスモニターの「プロファイル」タブにある「デバイスを追加」で足せます。

</details>

プロファイルの詳細は[プロファイル](./reference/project/profiles_ja.md)。

## 3. テストシナリオを作る

ログイン画面を対象に、探索的テストを作成してみましょう。

### AIへの指示文

```text
sut-ec-mobile(SUT Store)のログイン画面だけを対象に、探索的テストを作成して。アプリを日本語モードに切り替える処理は setUpDevice に書いて。
```

AIアシスタントはデバイス上でアプリを起動し、ログイン画面を操作しながら要素を読み取って、
見つけた挙動をテストシナリオに落とします。

## 4. デバイスで実行する

作成したテストシナリオを実行してみましょう。

### AIへの指示文

```text
作成したシナリオを iOS で実行して。
```

※Android で作ったシナリオなら「Android で実行して」と頼みます。

<details>
<summary><b>手動で実行(クリックで詳細表示)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --profile ios-run
```

`--profile` には、ステップ2で用意した実行プロファイルの名前(`ios-run`。Android なら `android-run`)を渡します。
アプリ・デバイス・実行時設定はそこから解決されます。

VSCode からは **Test Explorer** でシナリオを選び、**実行**をクリックします。
初めて実行する前に、コマンドパレットの `fleetest: 実行プロファイルを選択` で使う実行プロファイル(例: `ios-run`)を
選んでおきます。選んでいないと、実行は始まらずにエラーになります。

</details>

## 5. 結果を見る

実行のたびに `TestProjects/<プロジェクト>/reports/` にシナリオごとの Markdown
レポートが出ます。

レポートを要約し、エラーを分析してみましょう。

### AIへの指示文

```text
今の実行結果を要約し、失敗があればレポートから原因を調べて。
```

<details>
<summary><b>手動で実行(クリックで詳細表示)</b></summary>

`reports/` のレポートを開きます。VSCode では Test Explorer が成否を直接表示し、そこからレポートを
開けます。

</details>

### Link
- [index](index_ja.md)
- [はじめに(インストール)](getting-started_ja.md)
