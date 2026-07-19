# はじめに（自分のアプリをテストする）

**自分の iOS / Android アプリ向けのテストシナリオを書いて実行する**ための手引きです。
Claude Code に一連を任せる場合は `/ftester-setup` スキルを実行してください
（このドキュメントはその土台であり、手動でも同じ手順を踏めます）。

**最短経路（Claude Code）**: 次の1行で `ftester-setup`（初回導入）・`ftester-update`（更新）・
`ftester-profiles`（マシン/アプリ/実行プロファイルの一括作成）・`ftester-scenario`（テストシナリオ作成）の
各スキルを `.claude/skills/` に導入します。
あとは Claude Code で `/ftester-setup` を呼ぶと、ツールの clone → ビルド → あなたのプロジェクト作成 →
プロファイル設定までを自動で行います（以後の更新は `/ftester-update`）。

```bash
curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install-skill.sh | sh
```

## これは何か（先に理解しておくこと）

- foundation-tester は **Swift のツールチェーン**です。VSCode 拡張はその UI 層にすぎません。
- **テストシナリオは Swift コード**（Shirates 風 DSL）で書き、`ftester` に対してコンパイルして実行します。
  つまり利用には **Swift ソース（このリポジトリ）と `swift build` が常に必要**です。VSIX 単体では動きません。
- **テスト対象アプリは外部参照**です。あなたのアプリ本体はこのリポジトリに入れず、ビルド済みの
  `.app` / `.apk` へのパスをプロファイルで指すだけです。
- あなたのシナリオは `Projects/<あなたのプロジェクト名>/Scenarios/` に住みます（場所は下の「構成」次第）。

## 構成は2通り

| | 外部パッケージ構成（**既定・受け手向け**） | clone 構成（保守者/PoC 向け） |
|---|---|---|
| あなたの作業場所 | テスト専用の**新規ディレクトリ** | foundation-tester のクローンの中 |
| Projects の住処 | あなたのディレクトリ（ツールと分離・自分の git で管理可） | クローンの `Projects/` |
| foundation-tester | 横に clone した「**ツール**」（CLI・拡張のみ） | 作業場所そのもの |
| プロジェクト作成 | `ftester init` | `ftester project create` |

以降、**TOOL_ROOT** = foundation-tester クローン（`swift build` / `doctor` / 拡張ビルドを行う場所。CLI は
`TOOL_ROOT/.build/debug/ftester`）、**WORK_DIR** = `Projects/` が住む作業ディレクトリ、と呼びます。
外部構成では両者は別（WORK_DIR = 自分のディレクトリ・TOOL_ROOT = 横の `foundation-tester`）、
clone 構成では同一です。

## 必要環境

`ftester doctor` がこれらの導入状況をまとめて確認します。詰まったら随時実行してください。

| 対象 | 要件 | 誰がやるか |
|---|---|---|
| 共通 | macOS 27+、Apple Intelligence 有効（Foundation Models） | **人間のみ**（System 設定で有効化・モデル DL） |
| iOS | Xcode 27+、iOS シミュレータ runtime、xcodegen | Xcode 導入は**人間**／`brew install xcodegen` は自動可 |
| Android（任意） | Android SDK（adb）、エミュレータまたは実機 | 人間（SDK 導入）＋自動（ブリッジ APK ビルド） |
| 拡張ビルド | Node.js v24 系 / npm v11 系 | 自動可 |

> macOS ベータを使う場合は **Xcode を同じベータへ揃えてフルリビルド**すること。
> FoundationModels の ABI 不整合で全バイナリが dyld クラッシュします。

## セットアップ手順（手動）

Claude Code に任せるなら上の curl → `/ftester-setup` が下記を自動で行います。以下は手動での同等手順です。

### 1. 前提（人間がやる）

macOS 27+ / Apple Intelligence 有効 / Xcode 27+ 導入済み / iOS シミュレータ runtime を1つ以上導入。
Xcode を初めて入れたら `sudo xcodebuild -license accept` も実行しておく。

### 2. ツール（foundation-tester）を用意する

```bash
brew install xcodegen            # iOS ブリッジ生成に必要
git clone https://github.com/wave1008/foundation-tester.git
cd foundation-tester
swift build                      # 初回は数分。→ .build/debug/ftester ほか（これが TOOL_ROOT）
swift run ftester doctor         # 環境検証。赤が出たら潰してから次へ
```

- **外部パッケージ構成**: この clone は「ツール」。テスト用の新規ディレクトリの**隣**に置くのが自然です
  （例 `../foundation-tester`）。以降の作業は自分のディレクトリ（WORK_DIR）で行います。
- **clone 構成**: この clone の中で以降を進めます（TOOL_ROOT = WORK_DIR = このディレクトリ）。

### 3. 自分のプロジェクトを作る

- **外部パッケージ構成**: テスト専用の**新規ディレクトリ**（`Package.swift` が無い場所）に移り、
  TOOL_ROOT をローカルパス依存として引くパッケージを作ります:

```bash
# WORK_DIR（テスト専用ディレクトリ）で
../foundation-tester/.build/debug/ftester init \
  --ftester-path ../foundation-tester --name MyApp --app com.mycompany.myapp
```

  → WORK_DIR に `Package.swift`（ftester をローカルパス依存で引く）と `Projects/MyApp/` が生成されます。
  ローカルパス依存なので `swift build` はネットワーク不要・TOOL_ROOT を `git pull` すれば ftester も更新されます。
  以降 `ftester …` は `../foundation-tester/.build/debug/ftester …` を指します。

- **clone 構成**: クローン（= WORK_DIR）で:

```bash
swift run ftester project create MyApp --app com.mycompany.myapp
```

いずれも `Projects/MyApp/`（Scenarios/・profiles/apps・machines・runs・reports・docs/testbases）と
Package.swift のターゲット `ftester-scenarios-MyApp` が自動生成・登録されます（手編集不要）。
プロジェクト名は SPM ターゲット名になるため `^[A-Za-z0-9_][A-Za-z0-9_-]*$`（英数字）。

### 4. プロファイル（マシン/アプリ/実行）を用意する

以降のプロファイルは **WORK_DIR の `Projects/MyApp/profiles/`** に住みます。Claude Code なら
`/ftester-profiles` がこの3つを一括作成します（iOS/Android を選び、アプリの表示名・ID・パスを聞き、
デバイスは利用可能な最新 OS の仮想デバイスを自動採用（無ければ作成）または指定に従う）。手動なら以下。

**マシンプロファイル**（このPCのデバイス定義。`Projects/MyApp/profiles/machines/<マシン名>.json`）:

```bash
ftester machine set "<マシン名>"        # ~/.config/ftester/config.json に登録（machines/ が1つなら省略可）
xcrun simctl list devices available     # 使えるシミュレータ名を確認
```

```json
{ "ios": { "devices": [ { "name": "メイン機", "simulator": "iPhone 17 Pro", "os": "27.0" } ] } }
```

> `name`（例「メイン機」）は runs プロファイルから参照されるため ios/android 横断で一意に。

**アプリプロファイル**（`Projects/MyApp/profiles/apps/myapp.json`。`appPath` を自分のビルドへ向ける）:

```json
{ "common": { "appName": "MyApp", "autoInstall": true },
  "ios":    { "app": "com.mycompany.myapp", "appPath": "~/builds/MyApp.app" },
  "android":{ "app": "com.mycompany.myapp", "appPath": "~/builds/app-debug.apk" } }
```

`appName`/`autoInstall` は `common`、bundle ID(`app`)と `appPath` は `ios`/`android` セクションに書きます
（common に書いた `app`/`appPath` は無視され validate が警告する）。`appPath` の相対パスは
**WORK_DIR（そのプロジェクトの Package.swift があるディレクトリ）基準**で解決されます。`~`・絶対パスも可。

### 5. VSCode 拡張をビルド・インストール

拡張は **TOOL_ROOT 側**から入れます:

```bash
cd <TOOL_ROOT>/vscode-ftester   # clone 構成なら cd vscode-ftester
npm install
npm run install-local           # .vsix 化 → インストール → 到達確認まで一括
```

その後 **VSCode で WORK_DIR を開き**（外部構成: あなたのテストパッケージのフォルダ／clone 構成:
`foundation-tester` フォルダ）、**`Developer: Reload Window`** を実行します（インストールだけでは反映されません）。

- **外部パッケージ構成では** 設定 `ftester.binaryPath` を TOOL_ROOT の CLI に向けます
  （ワークスペース相対 `../foundation-tester/.build/debug/ftester` または絶対パス。設定値が実在すればそれを、
  無ければ PATH の `ftester` を使う）。clone 構成では既定 `.build/debug/ftester` のままで可。
- プロジェクトが複数あるときは `ftester.project` を `MyApp` にするか、拡張のプロファイル選択から選びます。

### 6. シナリオを書いて実行

- Claude Code なら `/ftester-scenario` が、対象アプリをライブ操作して実セレクタを採取しながら
  シナリオ（`.swift`）を1本作成し、コンパイル検証まで通します。
- 手書きするなら `Projects/MyApp/Scenarios/` に `.swift` を置く（`_Main.swift` は編集不要のエントリポイント。
  DSL はリポジトリの [README.md](../README.md) 「Swift DSL」節を参照）。
- または拡張の **ライブ操作パネルで操作を録画**するとシナリオを生成できる（`ftester api gen-scenario`）。
- 実行は拡張の Test Explorer、または CLI（**WORK_DIR で**）:

```bash
ftester run --project MyApp --profile ios   # ブリッジ供給・自動インストール込み
```

（外部構成では `ftester` = `../foundation-tester/.build/debug/ftester`、clone 構成は `swift run ftester run …`。）

## 更新のしかた（新しい修正版が出たとき）

Claude Code なら `/ftester-update` が構成を判定して自動実行します。手動は次の順:

```bash
# 1) ツールを更新（TOOL_ROOT で）
cd <TOOL_ROOT>            # 外部構成: 横の foundation-tester ／ clone 構成: そのクローン
git pull
swift build

# 2) 受け手側へ反映
#   外部構成（ローカルパス依存）: WORK_DIR で再ビルドするだけ（版の付け替え不要）
cd <WORK_DIR> && swift build --product ftester-scenarios-MyApp
#   clone 構成: swift run ftester project sync（Projects/ ↔ Package.swift の再整合）

# 3) 拡張を入れ直す（TOOL_ROOT で）→ 最後に VSCode で Developer: Reload Window（人間）
cd <TOOL_ROOT>/vscode-ftester && npm install && npm run install-local
```

> 外部パッケージ構成なら、あなたの `Projects/` はツールのクローンと別ディレクトリなので `git pull` の衝突は
> そもそも起きません。clone 構成で1つのクローンに Projects を置く場合は、Projects を git 管理外/別リポジトリに
> すると衝突を避けられます。git 依存（`.package(url:…)`）で引いている場合のみ、WORK_DIR の `from:` 版を
> 上げて `swift package update` します（ローカルパス依存では不要）。

## トラブルシュート

- **まず `ftester doctor`**（clone 構成は `swift run ftester doctor`）。FM 可用性・Xcode・xcodegen・
  シミュレータ・adb の状態を一覧します。FM の可否だけを exit code で見たいときは `ftester doctor --fm-only`。
- `xcodegen: No such file or directory` → `brew install xcodegen`。
- 「マシン名が未登録です」→ `ftester machine set "<マシン名>"`、かつ同名の machines/ JSON を用意。
- 全バイナリが dyld クラッシュ → macOS と Xcode のベータ世代を揃えて `swift build` し直す。
- 拡張が更新されない → VSCode の `Developer: Reload Window`、モニターパネルは開き直す。外部構成では
  `ftester.binaryPath` が TOOL_ROOT の CLI を指しているかも確認。
- Android で adb 未検出 → `export ANDROID_HOME=~/Library/Android/sdk`、`bash AndroidRunner/build.sh`。
