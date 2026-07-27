# はじめに（自分のアプリをテストする）

**自分の iOS / Android アプリ向けのテストシナリオを書いて実行する**ための手引きです。
Claude Code に一連を任せる場合は `/ftester-setup` スキルを実行してください
（このドキュメントはその土台であり、手動でも同じ手順を踏めます）。

**最短経路（Claude Code プラグイン・推奨）**: ターミナルで次の2コマンドを実行すると、
`ftester-setup`（初回導入）・`ftester-update`（更新）・`ftester-profiles`（マシン/アプリ/実行プロファイルの
一括作成）・`ftester-scenario`（テストシナリオ作成）・`ftester-mcp`（MCP のみ登録）の各スキルが
プラグインとして入ります（スキルはマーケットプレイス経由で**自動更新**。`claude` CLI が無ければ
`brew install claude-code`）:

```bash
claude plugin marketplace add wave1008/foundation-tester
claude plugin install ftester@foundation-tester --scope user
```

user スコープなので、プラグインは **VSCode の Claude Code 拡張にもそのまま反映**されます
（開いているウィンドウへは Reload Window で反映）。あとはテスト専用の**新規ディレクトリ**を VSCode で
開いて Claude Code パネルから `/ftester:ftester-setup` を呼ぶ（または「ftester をセットアップして」と
依頼する）と、ツールの clone → ビルド → あなたのプロジェクト作成 → プロファイル設定までを自動で行います
（以後の更新は `/ftester:ftester-update`）。版を固定したい場合は
`claude plugin marketplace add https://github.com/wave1008/foundation-tester.git#<タグ>`。

> 導入コマンドをターミナルで実行するのは、**VSCode 拡張のパネルでは `/plugin` スラッシュコマンドが
> 使えない**ためです（「/plugin isn't available in this environment.」になる）。ターミナルの対話
> セッションやデスクトップアプリで導入するなら `/plugin marketplace add wave1008/foundation-tester` →
> `/plugin install ftester@foundation-tester` でも同じです。

プラグイン機構を使えない場合の代替（スキルをカレントの `.claude/skills/` にコピーする。自動更新なし・
呼び出し名は `/ftester-setup` 等の名前空間なし）:

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
| 共通 | macOS 27+、Apple Intelligence 有効（Foundation Models）。**システム言語は英語**（下記） | **人間のみ**（System 設定で有効化・モデル DL） |
| iOS | Xcode 27+、iOS シミュレータ runtime、xcodegen | Xcode 導入は**人間**／`brew install xcodegen` は自動可 |
| Android（任意） | Android SDK（adb）、エミュレータまたは実機 | 人間（SDK 導入）＋自動（ブリッジ APK ビルド） |
| 拡張ビルド | Node.js v24 系 / npm v11 系 | 自動可 |

> macOS ベータを使う場合は **Xcode を同じベータへ揃えてフルリビルド**すること。
> FoundationModels の ABI 不整合で全バイナリが dyld クラッシュします。

> **Apple Intelligence が設定に出てこない場合**: システム言語が日本語（ja-JP）だと
> Apple Intelligence の設定項目自体が現れないことがあります（macOS 27.0 beta で確認）。
> 設定ペインが「Apple Intelligence と Siri」ではなく「Siri」単独になり、設定の検索で
> "Apple Intelligence" を引いても結果ゼロになります。
> **システム言語を English (United States) に変える**と項目が現れます（地域は日本のままで可）。
>
> 確認は `ftester doctor --fm-only`。実際に 1 回推論して可否を判定し、exit code に反映します
> （✅ + exit 0 なら利用可）。**macOS の API は「利用可能」と報告しながら全呼び出しが失敗する
> ことがある**ため、設定画面の見た目ではなくこのコマンドで確認してください。
>
> FM が使えないと、自己修復・`screenIs`・偽陽性検証（実行プロファイルで
> `falsePositiveCheck: true` を有効にした場合の `exist` の可視性確認）が
> **無言で素通り**します（テストは緑のまま機能だけ無効）。実行時に警告が出ますが、
> 事前に doctor で確認するのが確実です。

## セットアップ手順（手動）

Claude Code に任せるなら、上のプラグイン(または curl)で入れた `/ftester-setup` が下記を自動で行います。
以下は手動での同等手順です。

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

  → WORK_DIR に `Package.swift`（ftester をローカルパス依存で引く）と `Projects/MyApp/`、
  `.vscode/settings.json`（拡張の `ftester.binaryPath`/`ftester.project` を自動設定）が生成されます。
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
`/ftester-profiles` がこの3つを一括作成します（iOS/Android を選び、アプリの表示名・ID を聞き（パスは聞かない）、
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

**実機を使う場合**は `kind: "physical"` を付け、iOS は `udid`（`xcrun devicectl list devices` の
`hardwareProperties.udid`。`00008130-...` の形で、同じ一覧の Identifier 列とは別物です）、
Android は `serial`（`adb devices` の左列）を書きます。
VSCode 拡張のモニター →「マシンプロファイル」→「+既存から選択」なら、接続中の実機が一覧に出るので
手書き不要です:

```json
{ "ios":     { "devices": [ { "name": "iPhone 実機", "kind": "physical",
                              "udid": "00008130-000A1B2C3D4E5678" } ] },
  "android": { "devices": [ { "name": "Pixel 実機", "kind": "physical",
                              "serial": "14141JEC204922" } ] } }
```

実機とシミュレータでは `.app` の実体が違う（実機は署名済み・`-sdk iphoneos` ビルド）ため、
**実機は専用の apps/runs プロファイルに分ける**のが確実です。事前準備:

- **Android**: 端末の画面ロックを「なし」にする（PIN/パターンは adb から解除できず、
  ロック中は全シナリオが launch で落ちます）
- **iOS**: Apple Developer の Team ID を `~/.config/ftester/config.json` の `developmentTeam` に
  設定。**Team ID は署名証明書の OU** です（`security find-identity` の括弧内は証明書 ID で、
  これを入れると `No Account for Team` で落ちます）:
  `security find-certificate -c "Apple Development: <you>" -p | openssl x509 -noout -subject`
- **iOS**: 端末側は「このコンピュータを信頼」＋ Developer Mode の有効化。さらに
  設定 → 一般 → VPN とデバイス管理 からデベロッパ App の証明書を「信頼」する操作が要ります
  （初回だけでなく、**証明書が作り直されると再度必要**です）
- **iOS**: 端末のロックを解除しておく（設定 → 画面表示と明るさ → 自動ロック を「なし」に。
  ロック中は xcodebuild が待機したまま進みません）
- **iOS**: `brew install libimobiledevice` を入れて **USB で接続**する（USB トンネル経由になり、
  LAN 経由より 1 往復が 48ms → 4.7ms で **run 全体が約 25% 速くなります**。未導入か、端末が
  WiFi 接続のみの場合は LAN 経由に自動で落ち、Mac と端末が同一ネットワークにある必要があります）

詳細と罠は docs/verification.md の「実機（kind: physical）の検証」。

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

- **外部パッケージ構成では** `ftester init` が WORK_DIR の `.vscode/settings.json` に
  `ftester.binaryPath`（TOOL_ROOT の CLI）と `ftester.project` を生成済みなので、通常は設定操作は不要です
  （既存の settings.json がコメント付き等でマージできなかった場合は init が警告を出すので手動設定:
  ワークスペース相対 `../foundation-tester/.build/debug/ftester` または絶対パス。設定値が実在すればそれを、
  無ければ PATH の `ftester` を使う）。clone 構成では既定 `.build/debug/ftester` のままで可。
- プロジェクトが複数あるときは `ftester.project` を切り替えるか、拡張のプロファイル選択から選びます。

### 6. シナリオを書いて実行

- Claude Code なら `/ftester-scenario` が、対象アプリをライブ操作して実セレクタを採取しながら
  シナリオ（`.swift`）を1本作成し、コンパイル検証まで通します。
- 手書きするなら `Projects/MyApp/Scenarios/` に `.swift` を置く（`_Main.swift` は編集不要のエントリポイント。
  DSL はリポジトリの [README.md](../README.md) 「Swift DSL」節（セレクタ記法）と
  [docs/commands.md](commands.md)（全コマンドの引数・挙動）を参照）。
- または拡張の **ライブ操作パネルで操作を録画**するとシナリオを生成できる（`ftester api gen-scenario`）。
- 実行は拡張の Test Explorer、または CLI（**WORK_DIR で**）:

```bash
ftester run --project MyApp --profile ios   # ブリッジ供給・自動インストール込み
```

（外部構成では `ftester` = `../foundation-tester/.build/debug/ftester`、clone 構成は `swift run ftester run …`。）

書き捨ての1本を試すだけなら、プロジェクトに登録せずそのまま実行できます（プロファイル・レポート・
自己修復は `--project` のものを借ります）:

```bash
ftester run-file ~/tmp/新しい画面.swift --project MyApp --profile ios
```

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

## アンインストール

導入物は3層あり、それぞれ外す場所が違います（不要なものだけ選んで実施）:

- **Claude Code プラグイン（`/ftester:*` スキル）**: ターミナルで実行します
  （**VSCode の GUI からは外せません**。拡張ビューに出るのは下の VSCode 拡張だけです）:

  ```bash
  claude plugin uninstall ftester@foundation-tester
  claude plugin marketplace remove foundation-tester   # マーケットプレイス登録ごと外す場合
  ```

  キャッシュの実体が残ることがあるので、残っていたら `~/.claude/plugins/cache/foundation-tester` を
  削除します。curl（フォールバック）で導入した場合は、代わりに各ディレクトリの
  `.claude/skills/ftester-*` を削除します。
- **VSCode 拡張（vscode-ftester）**: VSCode の拡張ビューからアンインストール。
- **ツール本体（TOOL_ROOT の clone）**: `foundation-tester` ディレクトリを削除。マシン名の登録が不要なら
  `~/.config/ftester/config.json` も削除します。あなたの WORK_DIR（`Projects/` のシナリオ・プロファイル）は
  ツールと分離したあなたの資産なので、消すかどうかは自由です。

## トラブルシュート

- **まず `ftester doctor`**（clone 構成は `swift run ftester doctor`）。FM 可用性・Xcode・xcodegen・
  シミュレータ・adb の状態を一覧します。FM の可否だけを exit code で見たいときは `ftester doctor --fm-only`。
- `xcodegen: No such file or directory` → `brew install xcodegen`。
- 「マシン名が未登録です」→ `ftester machine set "<マシン名>"`、かつ同名の machines/ JSON を用意。
- 全バイナリが dyld クラッシュ → macOS と Xcode のベータ世代を揃えて `swift build` し直す。
- 拡張が更新されない → VSCode の `Developer: Reload Window`、モニターパネルは開き直す。外部構成では
  `ftester.binaryPath` が TOOL_ROOT の CLI を指しているかも確認。
- Android で adb 未検出 → `export ANDROID_HOME=~/Library/Android/sdk`、`bash AndroidRunner/build.sh`。
- iOS の `type` だけ「(409): フォーカスされた入力欄がありません」→ アプリが Compose Multiplatform /
  Flutter 等(UIKit の入力欄を持たない)のときの症状。既定の実行プロファイル(hybrid)なら Compose は
  自動判定して type を XCUITest 実行に切り替えるので通常は起きない(tap/exist は影響なし)。起きるのは
  engine=inapp を明示したプロファイルのみ → `iosInappEngine` 既定(hybrid)に戻すか xcuitest にする。
