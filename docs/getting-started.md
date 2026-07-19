# はじめに（自分のアプリをテストする）

このリポジトリを **クローンして、自分の iOS / Android アプリ向けのテストシナリオを書いて実行する**
ための手引きです。Claude Code に一連を任せる場合は `/ftester-setup` スキルを実行してください
（このドキュメントはその土台であり、手動でも同じ手順を踏めます）。

**未クローンなら最短経路はこちら**: 次の1行で `ftester-setup`（初回導入）と `ftester-update`（更新）の
両スキルを `.claude/skills/` に導入します。あとは Claude Code で `/ftester-setup` を呼ぶと、
clone → ビルド → プロジェクト/プロファイル設定までを自動で行います（以後の更新は `/ftester-update`）。

```bash
curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install-skill.sh | sh
```

## これは何か（先に理解しておくこと）

- foundation-tester は **Swift のツールチェーン**です。VSCode 拡張はその UI 層にすぎません。
- **テストシナリオは Swift コード**（Shirates 風 DSL）で書き、`ftester` に対してコンパイルして実行します。
  つまり利用には **Swift ソース（このリポジトリ）と `swift build` が常に必要**です。VSIX 単体では動きません。
- **テスト対象アプリは外部参照**です。あなたのアプリ本体はこのリポジトリに入れず、ビルド済みの
  `.app` / `.apk` へのパスをプロファイルで指すだけです。
- あなたのシナリオは `Projects/<あなたのプロジェクト名>/Scenarios/` に住みます。

## 必要環境

`swift run ftester doctor` がこれらの導入状況をまとめて確認します。詰まったら随時実行してください。

| 対象 | 要件 | 誰がやるか |
|---|---|---|
| 共通 | macOS 27+、Apple Intelligence 有効（Foundation Models） | **人間のみ**（System 設定で有効化・モデル DL） |
| iOS | Xcode 27+、iOS シミュレータ runtime、xcodegen | Xcode 導入は**人間**／`brew install xcodegen` は自動可 |
| Android（任意） | Android SDK（adb）、エミュレータまたは実機 | 人間（SDK 導入）＋自動（ブリッジ APK ビルド） |
| 拡張ビルド | Node.js v24 系 / npm v11 系 | 自動可 |

> macOS ベータを使う場合は **Xcode を同じベータへ揃えてフルリビルド**すること。
> FoundationModels の ABI 不整合で全バイナリが dyld クラッシュします。

## セットアップ手順

### 1. 前提（人間がやる）

macOS 27+ / Apple Intelligence 有効 / Xcode 27+ 導入済み / iOS シミュレータ runtime を1つ以上導入。
Xcode を初めて入れたら `sudo xcodebuild -license accept` も実行しておく。

### 2. クローンとビルド

```bash
brew install xcodegen            # iOS ブリッジ生成に必要
git clone https://github.com/wave1008/foundation-tester.git
cd foundation-tester
swift build                      # 初回は数分。→ .build/debug/ftester ほか
swift run ftester doctor         # 環境検証。赤が出たら潰してから次へ
```

### 3. 自分のプロジェクトを作る

```bash
swift run ftester project create MyApp --app com.mycompany.myapp
```

- `Projects/MyApp/`（Scenarios/・profiles/apps・machines・runs・reports・docs/testbases）を生成し、
  Package.swift のマーカー区間に `ftester-scenarios-MyApp` ターゲットを自動登録します（手編集不要）。
- プロジェクト名は SPM ターゲット名になるため `^[A-Za-z0-9_][A-Za-z0-9_-]*$`（英数字）。

### 4. マシン（このPC）を登録し、デバイスを定義する

マシンプロファイルは **プロジェクト単位**で `Projects/MyApp/profiles/machines/<マシン名>.json` に置きます。

```bash
swift run ftester machine set "<マシン名>"   # ~/.config/ftester/config.json に登録（クローンごとに必要）
xcrun simctl list devices available          # 使えるシミュレータ名を確認
```

`Projects/MyApp/profiles/machines/<マシン名>.json` を作り、使うデバイスを列挙します
（`profiles/machines/README.md` に雛形あり）:

```json
{
  "ios": {
    "devices": [
      { "name": "メイン機", "simulator": "iPhone 17 Pro", "os": "27.0" }
    ]
  }
}
```

> `machines/` に .json が1つだけならマシン名の自動採用が効くため `machine set` は省略可。
> 複数マシンを1クローンで扱うときだけ `machine set` が必須になります。
> `name`（例「メイン機」）は runs プロファイルから参照されるため ios/android 横断で一意に。

### 5. アプリのパスを自分のビルドに向ける

`Projects/MyApp/profiles/apps/myapp.json` を編集し、`appPath` を**あなたがビルドしたアプリ**へ向けます:

```json
{ "common": { "appName": "MyApp", "autoInstall": true },
  "ios":    { "app": "com.mycompany.myapp", "appPath": "~/builds/MyApp.app" },
  "android":{ "app": "com.mycompany.myapp", "appPath": "~/builds/app-debug.apk" } }
```

`appName`/`autoInstall` は `common`、bundle ID(`app`)と `appPath` は `ios`/`android` セクションに書く
(common に書いた `app`/`appPath` は無視され、validate が警告する)。

### 6. VSCode 拡張をビルド・インストール

```bash
cd vscode-ftester
npm install
npm run install-local   # .vsix 化 → インストール → 到達確認まで一括
```

その後、**VSCode でこの `foundation-tester` フォルダを開き、`Developer: Reload Window` を実行**します
（インストールだけでは反映されません。人間の操作が必要）。プロジェクトが複数あるときは拡張の設定
`ftester.project` を `MyApp` にするか、拡張のプロファイル選択から選びます。

### 7. シナリオを書いて実行

- `Projects/MyApp/Scenarios/` に `.swift` を置く（`_Main.swift` は編集不要のエントリポイント。DSL は
  リポジトリの [README.md](../README.md) 「Swift DSL」節を参照）。
- または拡張の **ライブ操作パネルで操作を録画**するとシナリオを生成できる（`ftester api gen-scenario`）。
- 実行は拡張の Test Explorer、または CLI:

```bash
swift run ftester run --project MyApp --profile ios   # ブリッジ供給・自動インストール込み
```

## 更新のしかた（新しい修正版が出たとき）

このツールは頻繁に更新されます。更新は次の順で行います（Claude Code なら `/ftester-update` で自動実行）:

```bash
cd foundation-tester
git pull
swift run ftester project sync   # Projects/ ↔ Package.swift マーカー区間の再整合
swift build
cd vscode-ftester && npm install && npm run install-local
# 最後に VSCode で Developer: Reload Window（人間）
```

> あなたの `Projects/MyApp/` は git 管理外に置くか別リポジトリで管理すると、`git pull` の衝突を避けられます。

## トラブルシュート

- **まず `swift run ftester doctor`**。FM 可用性・Xcode・xcodegen・シミュレータ・adb の状態を一覧します。
- `xcodegen: No such file or directory` → `brew install xcodegen`。
- 「マシン名が未登録です」→ `swift run ftester machine set "<マシン名>"`、かつ同名の machines/ JSON を用意。
- 全バイナリが dyld クラッシュ → macOS と Xcode のベータ世代を揃えて `swift build` し直す。
- 拡張が更新されない → VSCode の `Developer: Reload Window`、モニターパネルは開き直す。
- Android で adb 未検出 → `export ANDROID_HOME=~/Library/Android/sdk`、`bash AndroidRunner/build.sh`。
