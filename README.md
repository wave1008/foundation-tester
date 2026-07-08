# foundation-tester

macOS の Foundation Models framework(オンデバイス 3B モデル)を頭脳にした、
iOS / Android アプリの E2E テストツール。

**設計思想: 「AI がテストを作り、コードが決定的に再生する」**

- **生成**: 自然言語のゴールを渡すと、FM エージェントがアプリを実際に操作しながら探索し、
  **Swift のテストシナリオ(Shirates 風 DSL)**を自動生成する。すべてオンデバイス —
  アプリの画面情報が Mac の外に出ない
- **実行**: シナリオは LLM なしで決定的に実行する。高速・安定で CI 向き。
  イレギュラー処理・データセットアップは Swift コードでそのまま書ける
- **失敗時のみ FM が介入**: ロケータ自己修復(+ヒールキャッシュ)/ スクリーンショットの
  視覚検証(マルチモーダル)/ 失敗原因のトリアージとレポート・修正提案

## 4つのインターフェース

同じコア(Swift DSL + AppDriver + StepExecutor + FM エージェント)の上に、用途別の入口が4つある。

| 入口 | 起動 | 向いている用途 |
|---|---|---|
| **CLI** `ftester` | `swift run ftester ...` | CI・回帰テストの定期実行(決定的・無料・exit code) |
| **GUI** ftester Studio | `swift run ftester-gui` | 人間の対話操作: シナリオ実行・ライブ操作・FM探索 |
| **MCP** サーバ | Claude Code が自動起動([.mcp.json](.mcp.json)) | エージェント連携: AIによるテスト作成・デバッグ・探索的テスト |
| **Swift DSL** | `Projects/<name>/Scenarios/*.swift` | テスト資産。どの入口で作っても同じ形式で保存・実行される |

役割分担の原則: **探索・判断(知能)はエージェント、操作・実行・検証(決定性)は ftester**。
テスト作成は GUI の FM 探索(オンデバイス・無料)か、複雑なものは Claude Code(MCP 経由)で行い、
できた Swift シナリオを CLI/CI で決定的に回す。

## 必要環境

| 対象 | 要件 |
|---|---|
| 共通 | macOS 27+、Apple Intelligence 有効(Foundation Models) |
| iOS | Xcode 27+、iOS シミュレータ、[xcodegen](https://github.com/yonaskolb/XcodeGen)(`brew install xcodegen`) |
| Android(任意) | Android SDK(adb)、エミュレータまたは実機 |

## クイックスタート

```bash
# 1. 事前チェック(FM 可用性・Xcode・シミュレータ・adb)
swift run ftester doctor

# 2. iOS ブリッジを常駐させる(初回は数分。--with-sample-app でデモアプリ付き)
swift run ftester bridge up --with-sample-app

# 3. FM エージェントにテストを作らせる → Projects/<name>/Scenarios/Generated/*.swift が生成される
#    (生成直後にビルド検証され、失敗コードは Scenarios/_disabled/ に隔離される)
swift run ftester explore com.example.sampleapp \
  --goal "メールアドレス test@example.com、パスワード password123 でログインし、ホーム画面に「ようこそ」が表示されることを確認する"

# 4. 決定的実行(LLM なし。失敗があれば exit code 1)
swift run ftester run                         # 全シナリオ(プロジェクトが1つなら --project 省略可)
swift run ftester run --scenario ログインテスト  # クラス名 or クラス名.メソッド名で指定
swift run ftester run --profile ios           # 実行プロファイル(ブリッジ供給・自動インストール込み)
```

ゴール文のコツ: 入力値は具体的に書く。**確認したい文言は「」で囲む**
(「」内はエージェントが停滞した場合のコード側検証にも使われる)。

## コマンド一覧

| コマンド | 説明 |
|---|---|
| `doctor` | FM・Xcode・シミュレータ・adb の事前診断 |
| `bridge up / down / status` | iOS ブリッジ(常駐 XCUITest ランナー)の管理 |
| `explore <bundle-id> --goal "..."` | FM 探索による Swift シナリオ生成(`--project` `--max-steps` `--out`) |
| `run [--scenario <id>...]` | シナリオの決定的実行(`--project`、`--profile` プロファイル実行、`--heal` 自己修復、`--report-dir`、`--ports` 並列、`--skip-build`) |
| `project create / list / sync` | テストプロジェクトの作成・一覧・Package.swift 再整合 |
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
│   ├── apps/sampleapp.json        # アプリ: appName・bundle ID・appPath(common/ios/android)
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

- 実測(M4 Mac): 3本逐次 55.2秒 → 2+1並列 31.2秒(壁時間 ≒ 最長シナリオ)
- 目安の並列数: M1 Max 10コアで iOS 6〜8 / Android 3〜4(RAM より CPU が先に律速)
- 注意: **コールドブート直後のシミュレータはアクセシビリティ IPC がタイムアウトしやすい**
  (kAXErrorIPCTimeout でランナーが落ちる)。ワーカーは開始時に snapshot ウォームアップを
  自動で行うが、それでも落ちる場合は `bridge up` 後に一度 `launch`+`snapshot` してから実行する
- GUI(ftester Studio)でも同じ並列実行ができる — 設定のポート範囲内で稼働中のブリッジへ
  「全実行」が自動分配する
- 決定的再生は FM を呼ばないため並列スケールする。screenMatches・トリアージは
  オンデバイス FM(マシンに1本)に律速される点に注意

### Android

エミュレータ/実機を接続しておけば(`adb devices`)、同じコマンドに `--platform android` を
付けるだけ。**セットアップ不要** — 初回操作時にデバイス常駐ブリッジ(AndroidRunner/、
iOS ブリッジとプロトコル互換の instrumentation サーバ)が自動インストール・自動起動され、
snapshot が uiautomator dump の約2秒からミリ秒オーダーになる。ブリッジに接続できない環境では
adb 直叩き(uiautomator dump / input)へ自動フォールバックする。

- 手動管理(任意): `ftester bridge up|down|status --platform android [--serial S]`
  (`up` は接続中全デバイスへのプリウォームにも使える)。`doctor` が導入状況を表示
- 緊急スイッチ: `FT_ANDROID_NO_BRIDGE=1` でブリッジを使わず従来経路に固定(A/B 計測にも使う)
- 注意: ブリッジ稼働中は `uiautomator dump` を手で叩けない(a11y 接続の排他。ドライバは
  フォールバック時に自動でブリッジを止めてから dump する)

```bash
swift run ftester explore com.android.settings --platform android \
  --goal "「Network & internet」を開いて、「Internet」が表示されることを確認する"
```

#### 日本語入力(非 ASCII テキスト)

ブリッジ経由では `ACTION_SET_TEXT` で入力するため、日本語もそのまま入る(IME 切替なし)。

ブリッジ不達のフォールバック時のみ、`adb input text` の ASCII 制限を回避するため
Unicode 対応 IME([ADBKeyBoard](https://github.com/senzhk/ADBKeyBoard)、GPL-2.0)経由で入力する:

- 初回の日本語入力時に APK を `~/.ftester/ADBKeyboard.apk` へダウンロードし、
  対象デバイスへ自動インストール・IME 自動切替する(`doctor` で導入状況を確認可能)
- 切り替え前の IME は保存され、`terminate` 時に自動復元される
- ASCII のみのテキストは従来どおり `input text` 直接(IME 切替なしで速い)
- オフライン環境では手動配置: `curl -fsSL https://github.com/senzhk/ADBKeyBoard/raw/master/ADBKeyboard.apk -o ~/.ftester/ADBKeyboard.apk`
  (または環境変数 `FT_ADBKEYBOARD_APK=<APKパス>` で任意の場所を指定)

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

## GUI(ftester Studio)

```bash
swift run ftester-gui                       # リポジトリルートから起動
FT_PORTS=8123-8130 swift run ftester-gui    # ポート範囲を指定して起動(設定より優先)
FT_AUTORUN=1 swift run ftester-gui          # 起動と同時に全実行(スモークテスト・デモ用)
FT_TAB=3 swift run ftester-gui              # 初期タブ指定(0:実行 1:ライブ 2:探索 3:設定)
```

SwiftUI 製の macOS アプリ。**iOS と Android は切替なしで同時に扱う** — 起動時に設定の
ポート範囲をスキャンして稼働中の iOS ブリッジを、`adb devices` から Android デバイスを
自動発見し、ツールバーの「対象デバイス」ピッカーに並ぶ。4タブ構成:

- **シナリオ実行** — サイドバー上部の**プロジェクト Picker** で切替(**+ ボタンで新規プロジェクト作成** —
  CLI の `project create` と同じ雛形生成+Package.swift 登録)、選択プロジェクトの
  シナリオ一覧(platform・実行状態バッジ)、実行+自己修復トグル、ライブ実行ログ、失敗時トリアージ表示。
  「再読込」でシナリオをビルドして一覧を更新(コンパイルエラーはそのまま表示)。
  ツールバーの**実行プロファイル Picker** でプロファイルを選ぶと、実行時にデバイス供給
  (ブリッジ自動起動)・自動インストール込みで走る(供給ログは system レーンに表示)。
  「プロファイルなし」では従来どおり**稼働中の全デバイスへシナリオを動的に分配して並列実行**
  (iOS ブリッジ毎のワーカー + Android も adb デバイス毎のワーカー、CLI の `run --ports`
  と同じオーケストレータ。実行は 1 シナリオ = 1 サブプロセスで分離)。
  ログはワーカー毎のレーンに分かれて流れる。
  Android は複数エミュレータを起動しておくだけで並列対象になる
- **ライブ操作** — 対象デバイスのスクリーンショットを**クリックした位置をそのままタップ**
  (デバイス座標へ自動変換)、要素一覧(行クリックで tap)、スワイプ・起動・終了
- **FM探索** — ゴールを書いて探索開始 → ExplorerAgent の進捗をライブ表示 →
  Swift シナリオが選択プロジェクトの Scenarios/Generated/ に生成・ビルド検証され、
  一覧からそのまま実行できる(対象デバイスの platform がシナリオに記録される)
- **プロファイル** — 選択プロジェクトの profiles/(アプリ / マシン / 実行)を一覧して編集する。
  **実行プロファイル(runs/)はフォーム UI** — アプリを Picker で選び、現在マシンの
  マシンプロファイルに定義されたデバイスをチェックで選択(iOS/Android 混在可)、
  heal・レポート先・既定タイムアウトを設定(「JSONで編集」で生 JSON にも切替可)。
  アプリ / マシンプロファイルは JSON をその場で編集。保存時の検証は実行時と同じ
  Codable モデルで行われ、型エラー・必須欠落・デバイス名重複・未知キー(タイポ)を表示。
  実行プロファイルは現在マシンでの解決チェック(参照切れ・スキップされるデバイス)まで行う。
  各セクションの + で雛形から新規作成、右クリックで削除・Finder 表示
- **設定** — 下記

CLI・MCP と同じモジュールを使うため挙動は完全に同一。

### 設定ペイン(ポート範囲とブリッジ管理)

設定は今後の拡張を見込んで独立タブに集約している。

- **このマシン** — マシン名(`profiles/machines/<マシン名>.json` の選択キー)。
  `~/.config/ftester/config.json` に保存され、CLI の `machine set/show` と共有される
- **並列実行** — **開始ポート番号と最大並列数**を設定(既定 8123 / 8、UserDefaults に
  永続化)。開始ポートから並列数ぶんのポートをスキャンして稼働中のブリッジへフローを
  動的に分配する。ポートを個別に指定する必要はない。**ポートは iOS ブリッジ専用の
  概念**で、Android には適用されない(adb 接続デバイスを自動検出して直接駆動する)
- **ブリッジ管理** — 稼働中/起動中のブリッジが自動で並ぶ。「ブリッジを追加」で
  **範囲内の空きポートが自動で割り当てられ**、シミュレータを選んで起動・停止できる
  (CLI の `bridge up` と同じ `BridgeLauncher`。ビルド済みなら数十秒、初回のみ数分)。
  起動完了後は自動でスナップショットのウォームアップを行う(コールドブート対策)。
  行末のゴミ箱ボタンで**削除**(稼働中なら停止してから一覧から除去)できる

### デバイスモニター(ScreenCaptureKit)

フロー実行タブの右ペインに、**実行中のシミュレータ/エミュレータの画面を並べてライブ表示**する。

- シミュレータ(Xcode 27 の Device Hub / 旧 Simulator.app)と Android エミュレータ(qemu)の
  ウィンドウを ScreenCaptureKit で ~10fps ストリーム。ポートの `/status` のデバイス名と
  ウィンドウタイトルを照合し、タイルに `ios:8123` などのワーカーバッジを付ける
- **ウィンドウが見つからないデバイス(ヘッドレス起動など)は黄色バッジのフォールバックタイル**になり、
  ブリッジの `/screenshot` を2秒間隔でポーリング表示する
- 新しいウィンドウは5秒毎の再列挙で自動検出。タブ切替中はストリームを停止して CPU を節約

**画面収録の権限が必要。** `swift run` で起動した場合、権限は親のターミナル
(Terminal / VS Code)に付与される。初回はシステム設定 > プライバシーとセキュリティ >
画面収録でターミナルを許可し、**ターミナルを再起動**してから GUI を起動し直すこと。

### ブリッジ管理パネル

ツールバーの「ブリッジ管理」(iOS 時のみ表示)から、ポート欄の各ポートについて
シミュレータを選んで **bridge up / down を GUI から実行**できる(CLI の `bridge up` と同じ
`BridgeLauncher` を使用)。ビルド済みなら数十秒、初回のみ build-for-testing で数分かかる。
起動完了後は自動でスナップショットのウォームアップを行う(コールドブート対策)。

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
ftester CLI / GUI / MCP ──(サブプロセス)──▶ ftester-scenarios-<project>(プロジェクトのシナリオを発見・実行)
      │                                        │  FTDSL   (Swift DSL: @TestClass/@Test マクロ・コマンド・レポート)
      │                                        │  FTAgent (FoundationModels: 探索 / 視覚検証 / 修復 / トリアージ)
      │                                        │  FTCore  (ステップモデル / AppDriver 抽象 / StepExecutor)
      │                                        ▼
      ├─ HTTP (localhost:8123) ──▶ iOS シミュレータ内の常駐 XCUITest
      │                            (WebDriverAgent 方式・依存ゼロの自作ブリッジ)
      └─ adb forward ⇄ 常駐ブリッジ ──▶ Android エミュレータ / 実機
         (AndroidRunner/。不達時は adb 直叩きへ自動フォールバック)
                                   (uiautomator dump / input / screencap)
```

- プラットフォーム境界は `AppDriver` プロトコルのみ。**FM エージェントと再生器は iOS/Android 完全共通**
  (Android の UI 型は iOS と同じ語彙にマップ)
- スナップショットはドライバ側でフィルタし、`[3] Button "ログイン" id=login_btn` 形式の
  圧縮テキストに変換(オンデバイスモデルの 4K トークン制約対策)
- 3B モデルの弱点(数値参照の束縛ミス・反復癖など)は、テキスト参照+コード側ガードレールで補う。
  実測に基づく設計知見は[設計書 9.5〜9.7 節](docs/ios-test-tool-design.md)を参照

## プロジェクト構成

```
Projects/          テストプロジェクト(コミットして資産化する)
  SampleApp/
    profiles/        実行プロファイル(apps / machines / runs。JSON)
    Scenarios/       テストシナリオ(Swift DSL)
      _Main.swift      ランナーへの委譲(編集不要)
      Generated/       explore が生成したシナリオ
      _disabled/       コンパイル対象外の退避場所(並列デモ・生成失敗コードの隔離先)
    reports/         実行レポート(プロジェクト別)
    .ftester/        ヒールキャッシュ等(プロジェクト別)
Sources/
  ftester/         CLI(swift-argument-parser。project/machine/profile コマンド含む)
  ftester-gui/     GUI「ftester Studio」(SwiftUI macOS アプリ)
  ftester-mcp/     MCP サーバ(stdio / JSON-RPC、自前実装)
  FTDSL/           Swift DSL 本体(コマンド・セレクタ式・発見・レポート・コード生成・ヒールキャッシュ)
  FTDSLMacros/     @TestClass / @Test マクロ実装(swift-syntax はここに閉じる)
  FTScenarioRunner/ ftester-scenarios-<project> の CLI 実装(list / run・NDJSON イベント)
  FTCore/          ステップモデル / AppDriver / StepExecutor / プロジェクト・プロファイルモデル(FM 非依存・外部依存ゼロ)
  FTAgent/         FM エージェント(Explorer / Healer / Verifier / Triager)
  FTBridgeClient/  iOS ブリッジの HTTP クライアントと起動管理・SimulatorCatalog・BridgeProvisioner
  FTAndroid/       Android ドライバ(adb 直叩き)・AndroidDeviceCatalog・ProfileWorkerFactory
Runner/            xcodegen 定義 + ブリッジ本体(HTTP サーバ内蔵 UI テスト)
SampleApp/         検証用 SwiftUI デモアプリ(test@example.com / password123)
docs/              設計書・実装知見
```

## パフォーマンス(実測値)

| 操作 | 実測 | 補足 |
|---|---|---|
| ブリッジ `/status` | 13ms | HTTP サーバ自体のオーバーヘッドはほぼゼロ |
| スナップショット(iOS) | 約 250ms | XCUITest のツリー取得コストが本体 |
| スナップショット(Android) | 中央値 8.7ms | 常駐ブリッジ(AndroidRunner/)。フォールバックの `uiautomator dump` は約 2.0秒 |
| MCP ツール呼び出し | +0ms 相当 | ブリッジ直叩きと差なし(常駐プロセス) |
| フロー実行(4ステップ+スクロール6回) | 約 30秒 | 大半はステップ間の安定待ち(0.6〜0.8秒×N)と起動待ち |

- `swift run ftester ...` は毎回 SwiftPM のチェックで **約1.6秒** 上乗せされる。
  連続実行するときは `.build/debug/ftester ...` を直接叩くと速い(GUI/MCP は常駐なので無関係)
- FM の応答時間: 探索1ステップ数秒、screenMatches 数秒(すべてオンデバイス・無料)

## トラブルシューティング

- **オンデバイスモデル: 利用不可** → システム設定で Apple Intelligence を有効化(`doctor` が理由を表示)
- **ドライバに接続できません** → iOS: `bridge up` を先に実行(ログは `.ftester/bridge-<ポート>.log`)。
  Android: `adb devices` で接続確認
- **explore が中断した** → 到達分のシナリオは `// TODO: 探索未完了` コメント付きで
  プロジェクトの Scenarios/Generated/ に生成されるので、Swift を直接編集して仕上げられる(id セレクタ推奨)
- **シナリオのコンパイルエラーで実行できない** → `swift build --product ftester-scenarios-<プロジェクト名>`
  のエラーを修正する。explore の生成不良は Scenarios/_disabled/ に自動隔離される
- **プロジェクトが認識されない(手動コピーや git pull 後)** → `ftester project sync` で
  Package.swift のマーカー区間を再生成する(`project list` が未登録を警告する)
- **マシンプロファイルが見つからない** → `ftester machine show` で登録名と
  `profiles/machines/` の対応を確認(`machine set "<マシン名>"` で登録)
- **Android の snapshot が遅い(約2秒)** → ブリッジ不達で adb 直叩きにフォールバックしている。
  stderr の警告と `ftester bridge status --platform android`・`doctor` を確認。
  `ftester bridge up --platform android` で強制再セットアップできる
- **Android の日本語入力が入らない** → 通常はブリッジが IME 不要で入力する。フォールバック時は
  Unicode IME(ADBKeyBoard)を自動導入して入力する。失敗する場合はネットワーク
  (初回の APK ダウンロード)と `doctor` の IME 導入状況を確認。
  オフラインなら `~/.ftester/ADBKeyboard.apk` に手動配置(「Android > 日本語入力」参照)
