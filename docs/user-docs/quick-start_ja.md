# クイックスタート

[in English](quick-start.md)

fleetest をインストールし、サンプルアプリを対象にシナリオを作って実行するまでの最短手順です。
シナリオを手で書く必要はありません。

## 1. 環境

本ツールは Apple silicon の Mac、macOS 26+ で動作します。環境の詳細は[環境](overview/environments_ja.md)を参照してください。

## 2. 事前準備

以下をインストールしてください。

- **Xcode 26+**
  - <https://apps.apple.com/jp/app/xcode/id497799835>
  - インストールしたら Xcode のアプリを一度起動し、コンポーネントのダウンロードを済ませてください。
- **Homebrew**
  - <https://brew.sh/ja/>
- **VSCode**
  - <https://code.visualstudio.com/docs/setup/mac>
- **Android SDK(adb・Command-line Tools)**(Android をテストする場合)
  - <https://developer.android.com/studio/install?hl=ja>
- **AIアシスタント(Claude Code など)**
  - MCP に対応した AIアシスタントをインストールしてください。Claude Code や Codex の場合は VSCode 拡張からインストールできます。

## 3. fleetest のインストール

1. Finder で**テスト専用の新規フォルダ**を作成します

2. 作成したフォルダを VSCode で開きます

3. AIアシスタント(Claude Code 拡張など)を起動して次のように指示します

```text
https://github.com/wave1008/foundation-tester をこのフォルダの隣に clone して
../foundation-tester/.claude/skills/fleetest-setup/SKILL.md の手順でセットアップして。
```

4. **Claude Code 以外の AIアシスタント**を使う場合は、セットアップの途中で MCP を登録するか聞かれるので、登録してください

5. インストールが完了したら、VSCode を再起動します

6. VSCode の左下のステータスバーに表示される **fleetest mobile** をクリックします。デバイスモニターが開きます

7. AIアシスタントへ「fleetest doctor を実行して結果を報告して」と指示し、エラーが出ないことを確かめます

## 4. サンプルアプリの準備

サンプルアプリ
([sut-ec-mobile](https://github.com/wave1008/sut-ec-mobile)。Compose Multiplatform の EC 買い物アプリ)を
セットアップします。

### AIへの指示文

```text
https://github.com/wave1008/sut-ec-mobile をこのフォルダの隣に clone して、このフォルダで bash ../sut-ec-mobile/fleetest/prepare.sh を実行して。
```

<details>
<summary><b>手動で実行(クリックで詳細表示)</b></summary>

作業フォルダで実行します。

```bash
git clone https://github.com/wave1008/sut-ec-mobile.git ../sut-ec-mobile
bash ../sut-ec-mobile/fleetest/prepare.sh
```

テストプロジェクトの名前を変えるときは、`bash ../sut-ec-mobile/fleetest/prepare.sh <名前>` のように渡します。

</details>

## 5. プロファイルを用意する

アプリプロファイルと実行プロファイルを作成します。

### AIへの指示文

iOS の場合:

```text
sut-ec-mobile の iOS アプリをビルドし、プロファイルを作成して。アプリの表示名は「SUT Store」。デバイスは2台にして。
ビルドには JDK 17〜24 が必要。無ければ Homebrew で JDK 17 をインストールしてよい。シェルの設定ファイルは変更しないで。
```

Android の場合:

```text
sut-ec-mobile の Android アプリをビルドし、プロファイルを作成して。アプリの表示名は「SUT Store」。デバイスは2台にして。
ビルドには JDK 17〜24 が必要。無ければ Homebrew で JDK 17 をインストールしてよい。シェルの設定ファイルは変更しないで。
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
(AIアシスタントへ指示したときは自動で作られます。VSCode 拡張も VSCode の再起動後の起動時に作ります)。

```bash
../foundation-tester/.build/debug/fleetest project create project1

# iOS
../foundation-tester/.build/debug/fleetest profile setup --platform ios --app-id com.sutec.mobile.ios --auto-device --app-name "SUT Store" \
  --app-path ../sut-ec-mobile/build/ios-sim/Build/Products/Debug-iphonesimulator/iosApp.app

# Android
../foundation-tester/.build/debug/fleetest profile setup --platform android --app-id com.sutec.mobile.android --auto-device --app-name "SUT Store" \
  --app-path ../sut-ec-mobile/composeApp/build/outputs/apk/debug/composeApp-debug.apk
```

`--app-name` を省略するとプロジェクト名になり、ホーム画面のアイコン名と食い違って実行の開始時に警告が出ます。
`--app-path` にビルドしたアプリを渡すと、実行時にデバイスへ自動でインストールされます。
`--auto-device` は、最新の iOS ランタイムと最新の Pixel を使う Simulator/Emulator を自動で選びます
(足りなければ作成します。iOS のランタイムが未導入のときは数 GB をダウンロードするので数分〜数十分かかります。
起動していないものは実行時に自動で起動します)。アプリプロファイルの名前は `ios-app`・`android-app`、実行プロファイルの名前は `ios-run`・`android-run` になります。
手で登録するのは1台です。2台目は VSCode 拡張のデバイスモニターの「プロファイル」タブにある「デバイスを追加」で足せます。

</details>

成功すると、AIアシスタントが実行プロファイル名(`ios-run` など)を報告し、VSCode のデバイスモニターの「プロファイル」タブにその実行プロファイルが並びます。

プロファイルの詳細は[プロファイル](./reference/project/profiles_ja.md)。

## 6. シナリオを作る

ログイン画面を対象に、探索的テストを作成してみましょう。

### AIへの指示文

```text
sut-ec-mobile(SUT Store)のログイン画面だけを対象に、探索的テストを iOS で作成して。アプリを日本語モードに切り替える処理は setUpDevice に書いて。シナリオのファイル名を報告したら終わりにして。
```

`setUpDevice` は、テストの前にデバイスごとに1回だけ行う準備を書く場所です(ここでは言語の切り替え)。
Android の場合は「iOS で」を「Android で」に読み替えてください。

AIアシスタントはデバイス上でアプリを起動し、ログイン画面を操作しながら要素を読み取って、
見つけた挙動をシナリオに落とします。
AIアシスタントは探索の前に、compose.yaml に宣言したサーバーを `ft_services` で起こします。

<details>
<summary><b>手動で探索するとき(クリックで詳細表示)</b></summary>

サーバーを手で起こしてから探索し、終わったら止めます。

```bash
../foundation-tester/.build/debug/fleetest services up --profile ios-run
../foundation-tester/.build/debug/fleetest services down --profile ios-run
```

</details>

## 7. デバイスで実行する

作成したシナリオを実行してみましょう。
実行のたびに fleetest がサーバーを起動し、終わったら止めます。先に起こしてあったサービスは引き取ります。

### AIへの指示文

```text
作成したシナリオを iOS で実行して。
```

※Android で作ったシナリオなら「Android で実行して」と指示します。

<details>
<summary><b>手動で実行(クリックで詳細表示)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --profile ios-run
```

`--profile` には、ステップ5で用意した実行プロファイルの名前(`ios-run`。Android なら `android-run`)を渡します。
アプリ・デバイス・実行時設定はそこから解決されます。

VSCode からは **Test Explorer** でシナリオを選び、**実行**をクリックします。
初めて実行する前に、コマンドパレットの `fleetest: 実行プロファイルを選択` で使う実行プロファイル(例: `ios-run`)を
選んでおきます。選んでいないと、実行は始まらずにエラーになります。

</details>

## 8. 結果を見る

実行のたびに `TestProjects/<プロジェクト>/reports/` にシナリオごとの Markdown
レポートが出ます。

失敗したときは、サーバーのログが `TestProjects/<プロジェクト>/results/runs/<月>/<runID>/services/server.log` に残ります。

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

## 9. トラブルシュート

問題が起きたら AIアシスタントに相談してください。よくある症状と切り分けは
[トラブルシューティング](in_action/troubleshooting_ja.md)にまとめてあります。

次へ: [AIアシスタントへの指示の仕方](tutorial/asking_ai_ja.md)

### Link
- [index](index_ja.md)
