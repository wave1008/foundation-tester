# クイックスタート

セットアップ完了後、サンプルアプリを相手にテストシナリオを作り、実行するまでの最短手順です。
シナリオを手で書く必要はありません。

## 1. サンプルアプリを用意する

テスト対象として、EC 買い物アプリのサンプル
[sut-ec-mobile](https://github.com/wave1008/sut-ec-mobile)(Compose Multiplatform・iOS / Android 両対応)
を使います。

### AIアシスタントで実行

```text
https://github.com/wave1008/sut-ec-mobile をこのフォルダの隣に clone して、
1. サーバを起動(/health が ok を返すまで確認)。このセッションを閉じても動き続けるように起動する(nohup などで)
2. Android の debug APK をビルド
3. iOS Simulator 向け(arm64 のみ、署名なし)をビルド
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
# iOS Simulator(-destination の name は手元にある Simulator の名前にする)
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

アプリプロファイルと実行プロファイルを作成します。

### AIアシスタントで実行

```text
このフォルダの隣にある sut-ec-mobile のアプリ(ビルド済み)向けに、fleetest のプロファイルを作成して。
1. iOS と Android それぞれのアプリプロファイルと実行プロファイルを fleetest profile setup で作成(JSON は手で書かない)
2. fleetest profile list で、アプリとデバイスまで解決されることを確認
設定値: アプリの表示名は SUT Store、アプリ ID は iOS / Android とも com.sutec.mobile、アプリのパスは sut-ec-mobile のビルド済みの .app(iOS Simulator 向け)と .apk、デバイスは自動選択(--auto-device)。
利用できる Simulator / Emulator が無ければ作成してよい。
完了条件: 作成した実行プロファイルの名前を報告。テストの実行は不要。
```

実行プロファイルの名前はプラットフォーム名(`ios` と `android`)になります。

<details>
<summary><b>手動で実行(クリックで詳細表示)</b></summary>

作業フォルダに戻って実行します。

```bash
# iOS
../foundation-tester/.build/debug/fleetest profile setup --platform ios --app-id com.sutec.mobile --auto-device \
  --app-path ../sut-ec-mobile/build/ios-sim/Build/Products/Debug-iphonesimulator/iosApp.app

# Android
../foundation-tester/.build/debug/fleetest profile setup --platform android --app-id com.sutec.mobile --auto-device \
  --app-path ../sut-ec-mobile/composeApp/build/outputs/apk/debug/composeApp-debug.apk
```

`--app-path` にビルドしたアプリを渡すと、実行時にデバイスへ自動でインストールされます。
`--auto-device` は、このマシンで利用可能な Simulator/Emulator を自動で選びます(起動していない
ものは実行時に自動で起動します)。実行プロファイルの名前はプラットフォーム名(`ios` と `android`)になります。

セットアップはテストプロジェクトを作りません。AIアシスタントは `TestProjects/default/` が無ければ先に作ります。
手で進めるときは、上のコマンドの前に `fleetest project create default --platform <ios|android|both>` を実行します
(VSCode 拡張も Reload Window 後の起動時に作ります)。

</details>

プロファイルの詳細は[プロファイル](./reference/project/profiles_ja.md)。

## 3. テストシナリオを作る

ログイン画面を対象に、探索的テストを作成してみましょう。

### AIアシスタントで実行

```text
sut-ec-mobile(SUT Store)のログイン画面だけを対象に、探索的テストを作成して。
```

AIアシスタントはデバイス上でアプリを起動し、ログイン画面を操作しながら要素を読み取って、
見つけた挙動をテストシナリオに落とします。
iOS と Android のどちらで探索するかは、指示に添えると確実です(例:「…ログイン画面だけを対象に、
Android で探索的テストを作成して。」)。

## 4. デバイスで実行する

作成したテストシナリオを実行してみましょう。

### AIアシスタントで実行

```text
作成したシナリオを iOS で実行して
```

※Android で作ったシナリオなら「Android で実行して」と頼みます。

<details>
<summary><b>手動で実行(クリックで詳細表示)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --profile ios
```

`--profile` には、ステップ2で用意した実行プロファイルの名前(`ios`。Android なら `android`)を渡します。
アプリ・デバイス・実行時設定はそこから解決されます。

VSCode からは **Test Explorer** でシナリオを選び、**実行**をクリックします。

</details>

## 5. 結果を見る

実行のたびに `TestProjects/<プロジェクト>/reports/` にシナリオごとの Markdown
レポートが出ます。

レポートを要約し、エラーを分析してみましょう。

### AIアシスタントで実行

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
