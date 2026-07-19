# foundation-tester

macOS の Foundation Models framework(オンデバイス 3B モデル)を頭脳にした、
iOS / Android アプリの E2E テストツール。

**設計思想: 「AI がテストを作り、コードが決定的に再生する」**

- **生成**: VSCode 拡張のライブ操作パネルで操作を録画すると **Swift のテストシナリオ
  (Shirates 風 DSL)**を生成する(`ftester api gen-scenario`)。複雑なものは Claude Code
  (MCP 経由)に作らせる・手書きする。イレギュラー処理・データ投入は Swift でそのまま書ける
- **実行**: シナリオは LLM なしで決定的に実行する。高速・安定で CI 向き
- **失敗時のみ FM が介入**: ロケータ自己修復(+ヒールキャッシュ)/ スクリーンショットの
  視覚検証(マルチモーダル)/ 失敗原因のトリアージとレポート・修正提案。**すべてオンデバイス —
  アプリの画面情報が Mac の外に出ない**

## 4つのインターフェース

同じコア(Swift DSL + AppDriver + StepExecutor + FM エージェント)の上に、用途別の入口が4つある。
UI は VSCode 拡張(`vscode-ftester/`)に一本化している(セットアップ・機能の詳細は
[vscode-ftester/README.md](vscode-ftester/README.md))。

| 入口 | 起動 | 向いている用途 |
|---|---|---|
| **CLI** `ftester` | `swift run ftester ...`(clone 内)/ ビルド済み `.build/debug/ftester` | CI・回帰テストの定期実行(決定的・無料・exit code) |
| **VSCode 拡張** | [vscode-ftester/](vscode-ftester/README.md)(F5 起動 または .vsix インストール) | 人間の対話操作: シナリオ実行・デバッグ実行・ライブ操作(録画→生成)・デバイスモニター・結果ダッシュボード |
| **MCP** サーバ | Claude Code が自動起動([.mcp.json](.mcp.json)) | エージェント連携: AIによるテスト作成・デバッグ・探索的テスト |
| **Swift DSL** | `Projects/<name>/Scenarios/*.swift` | テスト資産。どの入口で作っても同じ形式で保存・実行される |

役割分担の原則: **探索・判断(知能)はエージェント、操作・実行・検証(決定性)は ftester**。
テスト作成は VSCode 拡張のライブ操作録画(操作を Swift シナリオに変換)か、複雑なものは Claude Code
(MCP 経由)で行い、できた Swift シナリオを CLI/CI で決定的に回す。

## 必要環境

| 対象 | 要件 |
|---|---|
| 共通 | macOS 27+、Apple Intelligence 有効(Foundation Models) |
| iOS | Xcode 27+、iOS シミュレータ、[xcodegen](https://github.com/yonaskolb/XcodeGen)(`brew install xcodegen`) |
| Android(任意) | Android SDK(adb)、エミュレータまたは実機 |

## インストール(使う: Claude Code に任せる)

**自分のアプリのテストを書くだけ**なら、Claude Code に一式(clone → ビルド → 拡張導入 → プロジェクト設定)を
任せられる。空のフォルダで次の1行を実行してスキルを導入し、Claude Code で `/ftester-setup` を呼ぶだけ:

```bash
curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install-skill.sh | sh
```

- この1行が `.claude/skills/` に **`ftester-setup`(初回導入)・`ftester-update`(更新)・
  `ftester-profiles`(マシン/アプリ/実行プロファイルの一括作成)** の各スキルを置く
  (この時点では clone しない=大きな取得の前にレビューできる)。版を固定するなら `FTESTER_REF=<tag>` を前置。
- `/ftester-setup`(既定=**外部パッケージ構成**): foundation-tester を横に `git clone` → `swift build`
  (ツールの CLI)→ `npm run install-local`(VSCode 拡張)→ **いま開いているディレクトリ**を `ftester init` で
  テストパッケージ化(あなたのプロジェクトは自分のディレクトリの `Projects/` に住み、ツールの clone とは分離)。
  仕上げに `/ftester-profiles` を呼んでプロファイルを作る。検証ゲートと人間チェックポイント付き。
- 以後、修正版の取り込みは `/ftester-update`、テスト対象やデバイスの追加は `/ftester-profiles`。
- 手順の全体像・手動でのやり方・トラブルシュートは [docs/getting-started.md](docs/getting-started.md)。

> **配布はソースビルド前提**(バイナリ配布はしない)。ツール本体(CLI)も VSCode 拡張(.vsix)も、この clone から
> `swift build` / `npm run install-local` でビルドして入れる。下記「セットアップ(クローン直後)」は、その clone 内で
> **手動で同じ手順を踏む/本体を改造する**場合の詳細。リリース手順は [docs/releasing.md](docs/releasing.md)。

## セットアップ(新しい環境へクローンした直後)

`doctor` が各ステップの導入状況を確認できるので、詰まったら随時 `swift run ftester doctor` を実行する。

```bash
# 1. iOS ブリッジ生成に必要な xcodegen を入れる(未導入だと bridge/device-up が
#    「xcodegen: No such file or directory」で失敗する)
brew install xcodegen

# 2. 本体をビルド(全プロダクト。ftester 本体＋映像ストリーミングヘルパー
#    ftester-simstream / ftester-androidstream ＋ MCP サーバをまとめて生成)
swift build

# 3. 事前診断(FM 可用性・Xcode・xcodegen・シミュレータ・adb をまとめて確認)
swift run ftester doctor

# 4. このマシンの名前を登録する(★必須。登録情報は ~/.config/ftester/config.json に
#    保存されリポジトリには入らないため、クローンごとに必要。未登録だと machines/ が
#    複数あるとき device-up 等が「マシン名が未登録です」で失敗する)
swift run ftester machine set "<マシン名>"   # profiles/machines/<マシン名>.json のファイル名と一致させる

# 5. (プロファイル実行や VSCode 拡張を使う場合)このマシン向けのデバイス定義を用意する
#    profiles/machines/<マシン名>.json に UDID/AVD などの実体を書く(既存例をコピーして編集)
```

VSCode 拡張(デバイスモニター・ライブ操作・結果ダッシュボードなどの UI)を使う場合は、続けて拡張をビルド・インストールする(Node.js v24 系 / npm v11 系):

```bash
cd vscode-ftester
npm install
npm run install-local   # パッケージ(.vsix)化 → インストール → 反映には VSCode の Reload Window が必要
```

拡張の開発(F5 で Extension Development Host を起動)やデバッグの詳細は
[vscode-ftester/README.md](vscode-ftester/README.md) を参照。

Android(任意)を使う場合の追加手順:

```bash
export ANDROID_HOME=~/Library/Android/sdk   # adb が PATH に無ければ設定(doctor が検出)
bash AndroidRunner/build.sh                  # 常駐ブリッジ APK を生成(doctor が導入状況を表示)
```

- macOS ベータを使う場合は **Xcode を同じベータへ揃えてフルリビルド**する
  (FoundationModels の ABI 不整合で全バイナリが dyld クラッシュするため)
- 手動コピー・別リポジトリからの移行などで `Projects/` を持ち込んだ場合は
  `swift run ftester project sync` で Package.swift のマーカー区間を再生成する

## クイックスタート

```bash
# 1. 事前チェック(FM 可用性・Xcode・シミュレータ・adb)
swift run ftester doctor

# 2. iOS ブリッジを常駐させる(初回は数分。--with-sample-app でデモアプリ付き)
swift run ftester bridge up --with-sample-app

# 3. シナリオを用意する(下記いずれか)
#    - VSCode 拡張のライブ操作パネルで操作を録画 → Projects/<name>/Scenarios/Generated/*.swift を生成
#      (生成直後にビルド検証され、失敗コードは Scenarios/_disabled/ に隔離される)
#    - Projects/<name>/Scenarios/ に Swift DSL で手書きする(下記「Swift DSL」参照)
#    - Claude Code(MCP 経由)に作らせる

# 4. 決定的実行(LLM なし。失敗があれば exit code 1)
swift run ftester run                         # 全シナリオ(プロジェクトが1つなら --project 省略可)
swift run ftester run --scenario ログインテスト  # クラス名 or クラス名.メソッド名で指定
swift run ftester run --profile ios           # 実行プロファイル(ブリッジ供給・自動インストール込み)
```

## コマンド一覧

| コマンド | 説明 |
|---|---|
| `doctor` | FM・Xcode・シミュレータ・adb の事前診断 |
| `bridge up / down / status` | iOS ブリッジ(常駐 XCUITest ランナー)の管理 |
| `run [--scenario <id>...]` | シナリオの決定的実行(`--project`、`--profile` プロファイル実行、`--folder` フォルダ指定、`--failed` 失敗のみ、`--heal` 自己修復、`--report-dir`、`--ports` 並列、`--skip-build`) |
| `project create / list / sync` | テストプロジェクトの作成・一覧・Package.swift 再整合 |
| `devices up / down` | 実行プロファイルのデバイスを一括起動・停止(ブリッジ供給込み) |
| `results list / summary / flaky / trend / devices / slow / insights` | 実行結果の集約・分析(reports/ を横断) |
| `init` | 外部パッケージ構成の scaffold(受け手ディレクトリを ftester テストパッケージ化。curl 入口の `/ftester-setup` 既定経路) |
| `profile list` | 実行プロファイルの一覧と現在マシンでの解決チェック |
| `machine set / show` | このマシンの名前(マシンプロファイルの選択キー)の登録・確認 |
| `install <パッケージパス>` | .app / .apk のインストール |
| `launch / terminate <bundle-id>` | アプリの起動・終了 |
| `snapshot [--json]` | 画面の要素一覧(圧縮形式)を表示 |
| `tap --ref N` / `tap --x --y` | タップ |
| `type --ref N "text"` | テキスト入力 |
| `swipe up\|down\|left\|right` / `press --ref N` | スワイプ・長押し |
| `screenshot -o file.png` | スクリーンショット保存 |

共通オプション: `--platform ios|android`(既定 ios)、`--serial <adb serial>`(Android 複数台時)、
`--port <n>`(iOS ブリッジ)。

## テストプロジェクトと実行プロファイル

テストは **テストプロジェクト**(`Projects/<name>/` = シナリオ+プロファイル+レポートの器)で管理する。
プロジェクト毎に SPM ターゲット `ftester-scenarios-<name>` が対応し、`ftester project create/sync` が
Package.swift のマーカー区間を自動更新する(プロジェクト間はビルド隔離)。

```
Projects/SampleApp/
├── profiles/
│   ├── apps/sampleapp_ios.json    # アプリ: appName/autoInstall は common、bundle ID(app)と appPath は ios/android
│   ├── machines/M1 Max.json       # マシン別デバイス定義(ファイル名 = マシン名)
│   └── runs/ios.json              # 実行プロファイル(アプリ+デバイス名リスト+実行時設定)
├── Scenarios/                     # Swift DSL(_Main.swift / Generated/ / _disabled/)
├── reports/                       # 実行レポート(プロジェクト別)
└── .ftester/heal-cache.json       # ヒールキャッシュ(プロジェクト別)
```

**実行プロファイル**はアプリとデバイスの組み合わせ。デバイスはマシンプロファイルの `name` で参照し、
**iOS/Android のデバイスを混在させれば 1 回の実行で両OS同時にテストできる**:

```jsonc
// profiles/runs/all.json
{ "app": "sampleapp",
  "devices": [ { "name": "メイン機" }, { "name": "サブ機" }, { "name": "エミュ1" } ],
  "heal": false, "reportDir": "reports", "defaultTimeout": 5 }

// profiles/machines/M1 Max.json — マシン毎に UDID/AVD などの実体を書く
// (avd は AVD の ID と表示名のどちらでも可)
{ "ios":     { "devices": [ { "name": "メイン機", "simulator": "iPhone 17 Pro", "os": "27.0" } ] },
  "android": { "devices": [ { "name": "エミュ1", "avd": "Pixel 9(Android 16)" } ] } }
```

```bash
swift run ftester machine set "M1 Max"                    # このマシンの名前を登録(machines/ の選択キー)
swift run ftester run --project SampleApp --profile all   # 解決 → ブリッジ供給 → 自動インストール → 並列実行
```

- マシン決定: `FT_MACHINE` 環境変数 > 登録名 > machines/ に 1 ファイルならそれを自動採用
- このマシンに定義がないデバイス name はスキップ+警告(実行プロファイルはマシン非依存で使い回せる)
- **並列数 = 解決後のデバイス数**。iOS は稼働中ブリッジを再利用し、不足分だけ自動起動する
- アプリプロファイルに `appPath`(.app/.apk)があれば実行前に自動インストール(`autoInstall: false` で無効)
- `--profile` 省略時は従来どおり(手動 `--ports`/`--serial`、稼働中デバイスへの分配)

### 並列実行

シミュレータ1台につきブリッジ1本(別ポート)を立て、`run --ports` でシナリオを分配する。
Android シナリオがあれば専用ワーカーも同時に走る(1シナリオ=1サブプロセスで分離)。

```bash
# デバイス毎にブリッジを起動(ビルドは1回で共有される)
swift run ftester bridge up --device "iPhone 17 Pro"                          # port 8123
swift run ftester bridge up --device "iPhone 17 Pro Max" --port 8124 --skip-build
xcrun simctl install "iPhone 17 Pro Max" <対象アプリ.app>   # 各デバイスにアプリを入れる

swift run ftester run --ports 8123,8124          # シナリオをワーカーに自動分配
swift run ftester bridge down --all              # 全ブリッジ停止
```

- 実測(M1 Max): 3本逐次 55.2秒 → 2+1並列 31.2秒(壁時間 ≒ 最長シナリオ)
- 目安の並列数: iOS 2 + Android 2 が sweet spot(performance-tuning.md §3.1 実測。3+3 は利得ゼロ)
- 注意: **コールドブート直後のシミュレータはアクセシビリティ IPC がタイムアウトしやすい**
  (kAXErrorIPCTimeout でランナーが落ちる)。ワーカーは開始時に snapshot ウォームアップを
  自動で行うが、それでも落ちる場合は `bridge up` 後に一度 `launch`+`snapshot` してから実行する
- VSCode 拡張(`vscode-ftester/`)でも実行プロファイル(`ftester.profile`)経由で同じ並列実行が
  できる(詳細は [vscode-ftester/README.md](vscode-ftester/README.md) の「並列実行とログレーン」)
- 決定的再生は FM を呼ばないため並列スケールする。screenMatches・トリアージは
  オンデバイス FM(マシンに1本)に律速される点に注意

### Android

エミュレータ/実機を接続しておけば(`adb devices`)、同じコマンドに `--platform android` を
付けるだけ。**セットアップ不要** — 初回操作時にデバイス常駐ブリッジ(AndroidRunner/、
iOS ブリッジとプロトコル互換の instrumentation サーバ)が自動インストール・自動起動され、
snapshot が uiautomator dump の約2秒からミリ秒オーダーになる。

- 手動管理(任意): `ftester bridge up|down|status --platform android [--serial S]`
  (`up` は接続中全デバイスへのプリウォームにも使える)。`doctor` が導入状況を表示
- ブリッジ起動時に window/transition/animator アニメーションを自動で無効化する
  (screenshot が静穏判定後も古い絵を掴む問題の回避)
- 注意: ブリッジ稼働中は `uiautomator dump` を手で叩けない(a11y 接続は実質1本の排他)

Android シナリオも iOS と同様に `--platform android` を付けて実行する
(`swift run ftester run --platform android` / 実行プロファイルにエミュレータ name を含める)。

#### 日本語入力(非 ASCII テキスト)

ブリッジ経由では `ACTION_SET_TEXT` で入力するため、日本語もそのまま入る(IME 切替なし)。

## Swift DSL(Projects/<name>/Scenarios/)

テストは Shirates 風の Swift DSL で書く。**`try await` もクロージャ引数も不要** —
コマンドは同期・非 throw の自由関数で、`scenario → scene → condition/action/expectation`(CAE)
の3層構造を持つ。プロジェクトの `Scenarios/` に .swift を置いて `swift build` すれば自動発見される。

```swift
import FTDSL

@TestClass(app: "com.example.sampleapp")        // platform: "ios"/"android"(省略 = 両OS対応)
class ログインテスト {

    @Test("ログインとエラー表示")
    func S0010() {
        scenario {
            scene(1, "正しい認証情報でログインできる") {
                condition {
                    launchApp()
                }.action {
                    type("#email", "test@example.com")
                    type("#password", "password123")
                    tap("#login_btn||ログイン")          // || = フォールバック連鎖
                    tap("今はしない", optional: true)     // optional = 無ければスキップ
                }.expectation {
                    exist("#welcome_text||ようこそ")
                    screenIs("ログイン後のホーム画面が表示されている")  // FM マルチモーダル検証
                }
            }
            scene(2, "誤ったパスワードはエラー表示") {
                condition { relaunchApp() }
                .action {
                    type("#email", "test@example.com")
                    type("#password", "wrong")
                    tap("#login_btn")
                }.expectation {
                    exist("#login_error").textIs("メールアドレスまたはパスワードが違います")
                }
            }
        }
    }
}
```

**セレクタ式**(`||` でフォールバック連鎖。優先度: id > label > type+index):

| 記法 | 意味 |
|---|---|
| `#login_btn` | accessibility id |
| `ログイン` | ラベル(完全一致 → 部分一致) |
| `.Button` / `.Button[2]` | 型+順番(**1 オリジン**。`.Button[2]` = 2番目の Button。1番目は `[1]` を省略して `.Button` と書く。`[1]` と明記しても可) |
| `.Switch#ID` / `.Switch=ラベル` | 型と id/label の併用(値検証などで型を絞る) |
| `=#で始まる生ラベル` | `=` エスケープで label 扱い |

**コマンド**: `tap` `type` `press` `swipe` `scrollTo` / `exist` `textIs` `valueIs`
`screenIs`(FM 視覚検証)/ `launchApp` `relaunchApp` `terminateApp` `wait` /
分岐 `ifCanSelect { }.ifElse { }`・`ios { }`・`android { }` / 任意コード `procedure("...") { try await ... }`

**イレギュラー処理・データセットアップはコードでそのまま書ける**のが YAML 時代との最大の違い:

```swift
condition {
    launchApp()
    ifCanSelect("許可しない", waitSeconds: 2) {   // 出るか不定のダイアログ
        tap("許可しない")
    }
    procedure("テストデータを API で投入") {       // 任意 Swift(try/await 可)。1ステップとして記録
        try await seedTestData()
    }
}
```

- 失敗セマンティクス: コマンド NG → 同一 scene 内の以降のコマンドは自動スキップし、
  次の scene へ進む(`abortScenarioOnFailure()` でシナリオ中断に変更可)。
  ブロック内の生 Swift コードはスキップされないため、失敗後に走らせたくない処理は `procedure { }` に包む
- レポートは成否問わず `Projects/<name>/reports/scenario-*.md` に出力(scene → CAE → ステップ階層、
  トリアージ、失敗スクリーンショット、**修正提案**)
- **自己修復とヒールキャッシュ**: `--heal` 時、壊れたセレクタは FM が修復して続行し、
  結果は `Projects/<name>/.ftester/heal-cache.json` に保存される。**2回目以降は FM なしで決定的に通過**し、
  レポートに「`Projects/SampleApp/Scenarios/LoginTest.swift:17` — セレクタ "#email_input" を
  "#email||.TextField[0]" に変更してください」のようなソース位置付き修正提案を出し続ける
  (ソースの自動書換はしない。人がソースを直すとキー不一致でキャッシュは自然に無効化される)
- **dry-run**: `swift run ftester-scenarios-<プロジェクト名> run --scenario <id> --dry-run` で
  デバイスに触れずステップ列挙だけ行える(Shirates の No-Load-Run 相当。レビュー・生成コードの確認用)

## UI(VSCode 拡張)

シナリオ実行・デバッグ実行(ブレークポイント/ステップ実行)・ライブ操作・デバイスモニター・
ライブ操作(録画→シナリオ生成)・結果ダッシュボード・自己修復候補の確認・プロファイル編集支援と
いった対話的な UI は、VSCode 拡張(`vscode-ftester/`)に一本化している。CLI と同じ `ftester api ...` サブコマンド経由で
ftester 本体を呼び出すため、挙動は CLI・MCP と共通のモジュールに基づく。

**デバイス画面はヘッドレス映像ストリーミングで表示する**: デバイスモニター・ライブ操作の
画面は、変化駆動でフレーム(JPEG)を配信する常駐ヘルパー(iOS: `ftester-simstream` /
Android: `ftester-androidstream`)経由でほぼリアルタイムに更新する。ScreenCaptureKit を
使わずシミュレータ/エミュレータの画面を低負荷で流すヘッドレス方式で、静止画面では
フレームをほぼ出さない。設定タブのトグル(`monitor.pollingMode`)で従来のポーリング
(一定間隔の静止画取得)方式にも切り替えられる(ヘルパー未ビルド時は自動でポーリングに
フォールバック)。

セットアップ手順・各機能の詳細・設定一覧(`ftester.*`)は
[vscode-ftester/README.md](vscode-ftester/README.md) を参照。

## MCP サーバ(エージェント連携)

`ftester-mcp` は同じ機能を MCP(Model Context Protocol)ツールとして公開する stdio サーバ。
リポジトリ直下の [.mcp.json](.mcp.json) に登録済みのため、**このディレクトリで Claude Code を
開くと自動で `ftester` サーバが使える**(初回はビルドが走る)。

| ツール | 内容 |
|---|---|
| `ft_status` / `ft_doctor` | 接続確認 / FM 可用性 |
| `ft_launch` / `ft_terminate` | アプリ起動・終了 |
| `ft_snapshot` | 画面要素一覧(set-of-mark 圧縮形式) |
| `ft_tap` / `ft_type` / `ft_swipe` / `ft_press` | 画面操作 |
| `ft_screenshot` | スクリーンショット(画像を返す — エージェントの視覚検証用) |
| `ft_list_scenarios` / `ft_run_scenario` | シナリオ一覧 / 決定的実行(`project`・`profile`・`heal` オプション付き。自動ビルド込みで、コンパイルエラーはそのまま返る=エージェントが直せる) |
| `ft_list_projects` | テストプロジェクトと実行プロファイルの一覧 |

全ツールに `platform: ios|android` を指定可能。探索(explore 相当)はツール化していない —
スナップショットと操作プリミティブがあれば、クライアント側のエージェント自身が探索できるため。
役割分担は「エージェント=知能(探索・判断)、ftester=決定性(操作・再生・検証)」。

## アーキテクチャ

```
ftester CLI / MCP ──(サブプロセス)──▶ ftester-scenarios-<project>(プロジェクトのシナリオを発見・実行)
      │                                        │  FTDSL   (Swift DSL: @TestClass/@Test マクロ・コマンド・レポート)
      │                                        │  FTAgent (FoundationModels: 視覚検証 / 修復 / トリアージ)
      │                                        │  FTCore  (ステップモデル / AppDriver 抽象 / StepExecutor)
      │                                        ▼
      ├─ HTTP (localhost:8123) ──▶ iOS シミュレータ内の常駐 XCUITest
      │                            (WebDriverAgent 方式・依存ゼロの自作ブリッジ)
      └─ adb forward ⇄ 常駐ブリッジ ──▶ Android エミュレータ / 実機
         (AndroidRunner/)
```

- プラットフォーム境界は `AppDriver` プロトコルのみ。**FM エージェントと再生器は iOS/Android 完全共通**
  (Android の UI 型は iOS と同じ語彙にマップ)
- スナップショットはドライバ側でフィルタし、`[3] Button "ログイン" id=login_btn` 形式の
  圧縮テキストに変換(オンデバイスモデルの 4K トークン制約対策)
- 3B モデルの弱点(数値参照の束縛ミス・反復癖など)は、テキスト参照+コード側ガードレールで補う。
  実測に基づく設計知見は[設計書 8.5〜8.8 節](docs/design.md)を参照

## プロジェクト構成

```
Projects/          テストプロジェクト(コミットして資産化する)
  SampleApp/
    profiles/        実行プロファイル(apps / machines / runs。JSON)
    Scenarios/       テストシナリオ(Swift DSL)
      _Main.swift      ランナーへの委譲(編集不要)
      Generated/       ライブ操作の録画(gen-scenario)が生成したシナリオ
      _disabled/       コンパイル対象外の退避場所(並列デモ・生成失敗コードの隔離先)
    reports/         実行レポート(プロジェクト別)
    .ftester/        ヒールキャッシュ等(プロジェクト別)
Sources/
  ftester/         CLI(swift-argument-parser。project/machine/profile コマンド含む)
  ftester-mcp/     MCP サーバ(stdio / JSON-RPC、自前実装)
  ftester-simstream/     iOS シミュレータ画面のヘッドレス映像ストリーミング(変化駆動で JPEG を stdout 配信)
  ftester-androidstream/ Android 画面のヘッドレス映像ストリーミング(iOS 版とフレームプロトコル互換)
  FTDSL/           Swift DSL 本体(コマンド・セレクタ式・発見・レポート・コード生成・ヒールキャッシュ)
  FTDSLMacros/     @TestClass / @Test マクロ実装(swift-syntax はここに閉じる)
  FTScenarioRunner/ ftester-scenarios-<project> の CLI 実装(list / run・NDJSON イベント)
  FTCore/          ステップモデル / AppDriver / StepExecutor / プロジェクト・プロファイルモデル(FM 非依存・外部依存ゼロ)
  FTAgent/         FM エージェント(Explorer / Healer / Verifier / Triager)
  FTBridgeClient/  iOS ブリッジの HTTP クライアントと起動管理・SimulatorCatalog・BridgeProvisioner
  FTAndroid/       Android ドライバ(常駐ブリッジ)・AndroidDeviceCatalog・ProfileWorkerFactory
Runner/            xcodegen 定義 + ブリッジ本体(HTTP サーバ内蔵 UI テスト)
SampleApp/         検証用 SwiftUI デモアプリ(test@example.com / password123)
vscode-ftester/    VSCode 拡張(UI 入口。詳細は vscode-ftester/README.md)
docs/              設計書・実装知見
```

## パフォーマンス(実測値)

| 操作 | 実測 | 補足 |
|---|---|---|
| ブリッジ `/status` | 13ms | HTTP サーバ自体のオーバーヘッドはほぼゼロ |
| スナップショット(iOS) | 約 80〜90ms(初回/画面遷移直後は約 250ms) | XCUITest のツリー取得コストが本体(performance-tuning.md §8) |
| スナップショット(Android) | 中央値 8.7ms | 常駐ブリッジ(AndroidRunner/) |
| MCP ツール呼び出し | +0ms 相当 | ブリッジ直叩きと差なし(常駐プロセス) |
| シナリオ実行(launch+タップ+検証×2、Android) | 約 2.2秒 | 整定はブリッジの a11y イベント静穏検知(固定待ちなし。2026-07 高速化で 4.9秒→2.2秒) |

- `swift run ftester ...` は毎回 SwiftPM のチェックで **約1.6秒** 上乗せされる。
  連続実行するときは `.build/debug/ftester ...` を直接叩くと速い(MCP は常駐なので無関係)
- FM の応答時間: screenMatches(視覚検証)数秒、修復・トリアージ数秒(すべてオンデバイス・無料)
- 計測手順・調整ノブ・設計原則(不採用の施策含む)は
  [パフォーマンスチューニングガイド](docs/performance-tuning.md)を参照

## トラブルシューティング

- **オンデバイスモデル: 利用不可** → システム設定で Apple Intelligence を有効化(`doctor` が理由を表示)
- **ドライバに接続できません** → iOS: `bridge up` を先に実行(ログは `.ftester/bridge-<ポート>.log`)。
  Android: `adb devices` で接続確認
- **シナリオのコンパイルエラーで実行できない** → `swift build --product ftester-scenarios-<プロジェクト名>`
  のエラーを修正する。ライブ操作録画(gen-scenario)の生成不良は Scenarios/_disabled/ に自動隔離される
- **プロジェクトが認識されない(手動コピーや git pull 後)** → `ftester project sync` で
  Package.swift のマーカー区間を再生成する(`project list` が未登録を警告する)
- **マシンプロファイルが見つからない** → `ftester machine show` で登録名と
  `profiles/machines/` の対応を確認(`machine set "<マシン名>"` で登録)
- **Android の snapshot が遅い** → `ftester bridge status --platform android`・`doctor` で
  ブリッジの導入・起動状況を確認。`ftester bridge up --platform android` で強制再セットアップできる
- **Android の日本語入力が入らない** → ブリッジが `ACTION_SET_TEXT` で入力するため通常は IME 不要。
  入らない場合はブリッジの導入状況(`doctor`)を確認
