# fleetest mobile

Claude Codeを前提とした macOS専用の iOS / Android アプリの E2E テストツール。

**fleetest** は `fleet` + `test` であり、*fleet*(すばやい)の最上級でもある。名前に畳み込んだ
3つが、そのまま特徴になっている。

- **fleet** — シミュレータ・エミュレータ・実機、さらに SSH 越しの別の Mac まで含めた
  **デバイスフリート**で並列実行する。シナリオはワーカーへ自動で分配される
- **fleetest** — 再生に LLM を挟まないので、実行時間を決めるのはモデルではなく**デバイス**。
  長いシナリオから先に投入して末尾の空きを潰す
- **free** — **テスト実行は無料**。クラウドのデバイスファームも実行ごとの API 課金も無い。
  失敗時に介入するモデルもオンデバイス

**設計思想: 「AI がテストを作り、コードが決定的に再生する」**

- **生成**: VSCode 拡張のライブ操作パネルで操作を録画すると **Swift のテストシナリオ
  (Shirates 風 DSL)**を生成する(`fleetest api gen-scenario`)。複雑なものは Claude Code
  (MCP 経由)に作らせる・手書きする。イレギュラー処理・データ投入は Swift でそのまま書ける
- **実行**: シナリオは LLM なしで決定的に実行する。高速・安定で CI 向き
- **失敗時のみ FM が介入**: ロケータ自己修復(+ヒールキャッシュ)/ スクリーンショットの
  視覚検証(マルチモーダル)/ 失敗原因のトリアージとレポート・修正提案。**すべてオンデバイス —
  アプリの画面情報が Mac の外に出ない**。**FM の機能は experimental で、現時点では英語のみ**
  (Mac のシステム言語を英語にする必要がある。日本語サポートは 2027 年の見込み)

## 4つのインターフェース

同じコア(Swift DSL + AppDriver + StepExecutor + FM エージェント)の上に、用途別の入口が4つある。
UI は VSCode 拡張(`vscode-fleetest/`)に一本化している(セットアップ・機能の詳細は
[vscode-fleetest/README.md](vscode-fleetest/README.md))。

| 入口 | 起動 | 向いている用途 |
|---|---|---|
| **CLI** `fleetest` | `swift run fleetest ...`(clone 内)/ ビルド済み `.build/debug/fleetest` | CI・回帰テストの定期実行(決定的・無料・exit code) |
| **VSCode 拡張** | [vscode-fleetest/](vscode-fleetest/README.md)(F5 起動 または .vsix インストール) | 人間の対話操作: シナリオ実行・デバッグ実行・ライブ操作(録画→生成)・デバイスモニター・結果ダッシュボード |
| **MCP** サーバ | Claude Code が自動起動([.mcp.json](.mcp.json)) | エージェント連携: AIによるテスト作成・デバッグ・探索的テスト |
| **Swift DSL** | `TestProjects/<name>/scenarios/*.swift` | テスト資産。どの入口で作っても同じ形式で保存・実行される |

役割分担の原則: **探索・判断(知能)はエージェント、操作・実行・検証(決定性)は fleetest**。
テスト作成は VSCode 拡張のライブ操作録画(操作を Swift シナリオに変換)か、複雑なものは Claude Code
(MCP 経由)で行い、できた Swift シナリオを CLI/CI で決定的に回す。

## 必要環境

| 対象 | 要件 |
|---|---|
| 共通 | macOS 26+。Apple Intelligence(Foundation Models)は**任意** — heal・FM 視覚検証・シナリオ生成に使う。後から有効化すればそのまま使える |
| iOS | Xcode 26+、iOS シミュレータ、[xcodegen](https://github.com/yonaskolb/XcodeGen)(`brew install xcodegen`) |
| Android(任意) | Android SDK(adb)、エミュレータまたは実機 |

> macOS 26 では FM の**視覚検証だけ**が使えない(画像入力 API が macOS 27+)。
> occlusion-guard(偽陽性チェック)と `screenLooksLike` は自動で無効になり、他は制限なく動く。
>
> **FM の機能は experimental で、2026 年内は英語でしか使えない**(日本語サポートは 2027 年の
> 見込み)。**Mac のシステム言語が英語である必要があり**、`ja-JP` だと呼び出しが全て失敗する。
> `availability` は available を返したまま失敗するので、実際に推論する
> `fleetest doctor --fm-only` で確認する。詳細は
> [docs/user-docs/overview/environments_ja.md](docs/user-docs/overview/environments_ja.md)。

## インストール(使う: 自分のアプリのテストを書く)

**Claude Code に任せる(推奨)**: ターミナルでプラグインを入れ、テスト用の新規フォルダを VSCode で開いて
`/fleetest:fleetest-setup` を呼ぶ(`claude` CLI が無ければ `brew install claude-code`):

```bash
claude plugin marketplace add wave1008/foundation-tester
claude plugin marketplace update foundation-tester
claude plugin install fleetest@foundation-tester --scope user
```

> `marketplace update` は、既にマーケットプレイスを追加済みの機械のために要る ——
> `add` は「already on disk」で**何も取得しない**ので、古いキャッシュのままだと
> `Plugin "fleetest" not found` で落ちる。新規導入なら no-op。
>
> **改名前の `ftester@foundation-tester` を入れている場合は、先に消してください。**
> プラグイン名が変わったので新旧が同居し、古い `/ftester:*` スキルは既に存在しない
> コマンド(`ftester`)と状態ディレクトリ(`.ftester/`)を指したまま残ります。
> marketplace 名(`foundation-tester`)は変えていないので、追加し直す必要はありません。
>
> `claude plugin uninstall ftester@foundation-tester`

**エージェント無しで入れる**: 同じ機械作業を1コマンドで行うインストーラ(冪等):

```bash
mkdir -p ~/my-app-tests && cd ~/my-app-tests
curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install.sh \
  | bash -s -- --name MyApp --app com.example.myapp
```

- プラグインが提供するスキル: `fleetest-setup`(初回導入)・`fleetest-update`(更新)・`fleetest-profiles`
  (マシン/アプリ/実行プロファイル)・`fleetest-scenario`(シナリオ作成)・`fleetest-mcp`(MCP のみ)・
  `fleetest-remote-setup`(別の Mac をランナー機にする)。
  版を固定するなら `claude plugin marketplace add https://github.com/wave1008/foundation-tester.git#<tag>`。
  プラグイン機構が無い環境向けの代替は
  `curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install-skill.sh | sh`。
- 既定は**外部パッケージ構成**: ツール(この clone)と、あなたの `TestProjects/` が住むテスト用フォルダを分ける。
- 事前準備・インストール・更新・アンインストールの手順は [docs/user-docs/getting-started_ja.md](docs/user-docs/getting-started_ja.md)。
  導入後の使い方(プロファイル・シナリオ・実行)は**利用者向けドキュメント [docs/user-docs/index_ja.md](docs/user-docs/index_ja.md)**([English](docs/user-docs/index.md))と [docs/commands.md](docs/commands.md)。

> **配布はソースビルド前提**(バイナリ配布はしない)。CLI も VSCode 拡張(.vsix)も clone から
> `swift build` / `npm run install-local` でビルドして入れる。下記「セットアップ(クローン直後)」は
> **その clone 内で作業する/本体を改造する**場合の手順。リリースは [docs/releasing.md](docs/releasing.md)。

## セットアップ(新しい環境へクローンした直後)

`doctor` が各ステップの導入状況を確認できるので、詰まったら随時 `swift run fleetest doctor` を実行する。

```bash
# 1. iOS ブリッジ生成に必要な xcodegen を入れる(未導入だと bridge/device-up が
#    「xcodegen: No such file or directory」で失敗する)
brew install xcodegen

# 2. 本体をビルド(全プロダクト。fleetest 本体＋映像ストリーミングヘルパー
#    fleetest-simstream / fleetest-androidstream ＋ MCP サーバをまとめて生成)
swift build

# 3. 事前診断(FM 可用性・Xcode・xcodegen・シミュレータ・adb をまとめて確認)
swift run fleetest doctor

# 4. (プロファイル実行や VSCode 拡張を使う場合)デバイス定義を用意する
#    profiles/machines/<名前>.json に UDID/AVD などの実体を書き(既存例をコピーして編集)、
#    実行プロファイルの "machine" でその名前を指す
```

VSCode 拡張(デバイスモニター・ライブ操作・結果ダッシュボードなどの UI)を使う場合は、続けて拡張をビルド・インストールする(Node.js v24 系 / npm v11 系):

```bash
cd vscode-fleetest
npm install
npm run install-local   # パッケージ(.vsix)化 → インストール → 反映には VSCode の Reload Window が必要
```

拡張の開発(F5 で Extension Development Host を起動)やデバッグの詳細は
[vscode-fleetest/README.md](vscode-fleetest/README.md) を参照。

Android(任意)を使う場合の追加手順:

```bash
export ANDROID_HOME=~/Library/Android/sdk   # adb が PATH に無ければ設定(doctor が検出)
bash AndroidRunner/build.sh                  # 常駐ブリッジ APK を生成(doctor が導入状況を表示)
```

- macOS ベータを使う場合は **Xcode を同じベータへ揃えてフルリビルド**する
  (FoundationModels の ABI 不整合で全バイナリが dyld クラッシュするため)
- 手動コピー・別リポジトリからの移行などで `TestProjects/` を持ち込んだ場合は
  `swift run fleetest project sync` で Package.swift のマーカー区間を再生成する

## クイックスタート

```bash
# 1. 事前チェック(FM 可用性・Xcode・シミュレータ・adb)
swift run fleetest doctor

# 2. iOS ブリッジを常駐させる(初回は数分。--with-sample-app でデモアプリ付き)
swift run fleetest bridge up --with-sample-app

# 3. シナリオを用意する(下記いずれか)
#    - VSCode 拡張のライブ操作パネルで操作を録画 → TestProjects/<name>/scenarios/Generated/*.swift を生成
#      (生成直後にビルド検証され、失敗コードは scenarios/_disabled/ に隔離される)
#    - TestProjects/<name>/scenarios/ に Swift DSL で手書きする(下記「Swift DSL」参照)
#    - Claude Code(MCP 経由)に作らせる

# 4. 決定的実行(LLM なし。失敗があれば exit code 1)
swift run fleetest run                         # 全シナリオ(プロジェクトが1つなら --project 省略可)
swift run fleetest run --scenario ログインテスト  # クラス名 or クラス名.メソッド名で指定
swift run fleetest run --profile ios           # 実行プロファイル(ブリッジ供給・自動インストール込み)
```

## コマンド一覧

| コマンド | 説明 |
|---|---|
| `doctor` | FM・Xcode・シミュレータ・adb の事前診断 |
| `bridge up / down / status` | iOS ブリッジ(常駐 XCUITest ランナー)の管理 |
| `run [--scenario <id>...]` | シナリオの決定的実行(`--project`、`--profile` プロファイル実行、`--folder` フォルダ指定、`--failed` 失敗のみ、`--heal` 自己修復、`--report-dir`、`--ports` 並列、`--skip-build`、`--no-lpt` 投入順を ID 順に固定、`--lpt-history-runs` 実績を読む run 数、`--broadcast` 選んだシナリオを実行プロファイルの**全デバイスで1回ずつ**回す(ブロードキャスト。warmup 向け。供給・フック・復帰・レポートは通常 run と同じで、結果は台ごとに `worker` で区別)、`--quiet`/`--junit` CI 向け出力、`--enable-animations` アプリのアニメーションを残す、`--fast-input` iOS xcuitest の quiescence 待ちを飛ばす)。**`--dry-run` はデバイスに触れずステップを列挙・検証する**(下記「dry-run」) |
| `run-file <path.swift>...` | Package.swift に**登録していない** .swift をそのまま実行(プロファイル・レポート・自己修復は `--project` のものを借りる。`--profile`、`--scenario`、`--heal`、`--ports`) |
| `project create / list / sync` | テストプロジェクトの作成・一覧・Package.swift 再整合 |
| `devices up / down` | 実行プロファイルのデバイスを一括起動・停止(ブリッジ供給込み) |
| `results list / summary / flaky / trend / devices / slow / insights` | 実行結果の集約・分析(reports/ を横断) |
| `draft-scenario` | テストベース(`docs/testbases/*.md`)からシナリオの下書きを生成(`--testbase`、`--app`、`--platform`、`--no-fm` で FM 不使用、`--dry-run`) |
| `init` | 外部パッケージ構成の scaffold(`--platform` で作る run 雛形を絞る)(受け手ディレクトリを fleetest テストパッケージ化。スキル入口 `/fleetest-setup` の既定経路) |
| `profile setup` | マシン/アプリ/実行プロファイルを整合させて作成(冪等。`--platform`、`--device-name`、`--simulator`/`--avd`、`--app-id`、`--auto-device` は既存デバイスから自動選定(iOS は iPad を除外)) |
| `profile list` | 実行プロファイルの一覧と現在マシンでの解決チェック |
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

テストは **テストプロジェクト**(`TestProjects/<name>/` = シナリオ+プロファイル+レポートの器)で管理する。
プロジェクト毎に SPM ターゲット `fleetest-scenarios-<name>` が対応し、`fleetest project create/sync` が
Package.swift のマーカー区間を自動更新する(プロジェクト間はビルド隔離)。

```
TestProjects/SampleApp/
├── profiles/
│   ├── apps/sampleapp_ios.json    # アプリ: autoInstall は common、appName/bundle ID(app)/appPath は ios/android
│   ├── machines/M2Ultra.json     # マシン別デバイス定義(ファイル名 = マシン名)
│   └── runs/ios.json              # 実行プロファイル(アプリ+デバイス名リスト+実行時設定)
├── scenarios/                     # Swift DSL(_Main.swift / Generated/ / _disabled/)
├── reports/                       # 実行レポート(プロジェクト別)
└── .fleetest/heal-cache.json       # ヒールキャッシュ(プロジェクト別)
```

**実行プロファイル**はアプリとデバイスの組み合わせ。デバイスはマシンプロファイルの `name` で参照し、
**iOS/Android のデバイスを混在させれば 1 回の実行で両OS同時にテストできる**:

```jsonc
// profiles/runs/all.json
// FM 機能のトグル: fm(親スイッチ)/ heal / screenLooksLike は既定 true、
// falsePositiveCheck(偽陽性検証)だけ既定 false(詳細は docs/design.md §11.2)
{ "app": "sampleapp",
  "devices": [ { "name": "simulator1" }, { "name": "simulator2" }, { "name": "emulator1" } ],
  "fm": true, "heal": true, "reportDir": "reports", "defaultTimeout": 5 }

// profiles/machines/M2Ultra.json — マシン毎に UDID/AVD などの実体を書く
// (avd は AVD の ID と表示名のどちらでも可)
{ "ios":     { "devices": [ { "name": "simulator1", "simulator": "iPhone 17 Pro", "os": "27.0" } ] },
  "android": { "devices": [ { "name": "emulator1", "avd": "Pixel 9(Android 16)" } ] } }
```

```bash
swift run fleetest run --project SampleApp --profile all   # 解決 → ブリッジ供給 → 自動インストール → 並列実行
```

- マシン決定: 実行プロファイルの `machine` > `FT_MACHINE` 環境変数 > machines/ に 1 ファイルならそれ
  (複数あって `machine` 未指定なら候補を挙げて停止する)
- マシンプロファイルに `"host": "<登録名>"` を書くと、そのデバイスは**別の Mac 上にある**ものとして
  扱われ、実行プロファイルを選ぶだけでそのマシンへ SSH でディスパッチされる
  (省略 = 手元。導入は [docs/remote-runner-setup.md](docs/remote-runner-setup.md))
- `host` は**デバイス1台ずつにも書ける**(トップレベルは既定)。**一意なのは (host, name)** なので
  別の機械に同名のデバイスが居てよく、**手元10台 + リモート10台を1回の run で**回せる
  (ホストごとに分かれて走り、シナリオは台数で重み付けて配られる)
- このマシンに定義がないデバイス name はスキップ+警告(実行プロファイルはマシン非依存で使い回せる)
- **並列数 = 解決後のデバイス数**。iOS は稼働中ブリッジを再利用し、不足分だけ自動起動する
- アプリプロファイルに `appPath`(.app/.apk)があれば実行前に自動インストール(`autoInstall: false` で無効)
- `--profile` 省略時は従来どおり(手動 `--ports`/`--serial`、稼働中デバイスへの分配)

### 並列実行

シミュレータ1台につきブリッジ1本(別ポート)を立て、`run --ports` でシナリオを分配する。
Android シナリオがあれば専用ワーカーも同時に走る(1シナリオ=1サブプロセスで分離)。

```bash
# デバイス毎にブリッジを起動(ビルドは1回で共有される)
swift run fleetest bridge up --device "iPhone 17 Pro"                          # port 8123
swift run fleetest bridge up --device "iPhone 17 Pro Max" --port 8124 --skip-build
xcrun simctl install "iPhone 17 Pro Max" <対象アプリ.app>   # 各デバイスにアプリを入れる

swift run fleetest run --ports 8123,8124          # シナリオをワーカーに自動分配
swift run fleetest bridge down --all              # 全ブリッジ停止
```

- 実測(M1 Max): 3本逐次 55.2秒 → 2+1並列 31.2秒(壁時間 ≒ 最長シナリオ)
- 目安の並列数: iOS 2 + Android 2 が sweet spot(performance-tuning.md §3.1 実測。3+3 は利得ゼロ)
- 注意: **コールドブート直後のシミュレータはアクセシビリティ IPC がタイムアウトしやすい**
  (kAXErrorIPCTimeout でランナーが落ちる)。ワーカーは開始時に snapshot ウォームアップを
  自動で行うが、それでも落ちる場合は `bridge up` 後に一度 `launch`+`snapshot` してから実行する
- VSCode 拡張(`vscode-fleetest/`)でも実行プロファイル(`fleetest.profile`)経由で同じ並列実行が
  できる(詳細は [vscode-fleetest/README.md](vscode-fleetest/README.md) の「並列実行とログレーン」)
- 決定的再生は FM を呼ばないため並列スケールする。screenMatches・トリアージは
  オンデバイス FM(マシンに1本)に律速される点に注意

### Android

エミュレータ/実機を接続しておけば(`adb devices`)、同じコマンドに `--platform android` を
付けるだけ。**セットアップ不要** — 初回操作時にデバイス常駐ブリッジ(AndroidRunner/、
iOS ブリッジとプロトコル互換の instrumentation サーバ)が自動インストール・自動起動され、
snapshot が uiautomator dump の約2秒からミリ秒オーダーになる。

- 手動管理(任意): `fleetest bridge up|down|status --platform android [--serial S]`
  (`up` は接続中全デバイスへのプリウォームにも使える)。`doctor` が導入状況を表示
- ブリッジ起動時に window/transition/animator アニメーションを自動で無効化する
  (screenshot が静穏判定後も古い絵を掴む問題の回避)
- 注意: ブリッジ稼働中は `uiautomator dump` を手で叩けない(a11y 接続は実質1本の排他)

Android シナリオも iOS と同様に `--platform android` を付けて実行する
(`swift run fleetest run --platform android` / 実行プロファイルにエミュレータ name を含める)。

#### 日本語入力(非 ASCII テキスト)

ブリッジ経由では `ACTION_SET_TEXT` で入力するため、日本語もそのまま入る(IME 切替なし)。

## Swift DSL(TestProjects/<name>/scenarios/)

テストは Shirates 風の Swift DSL で書く。**`try await` もクロージャ引数も不要** —
コマンドは同期・非 throw の自由関数で、`scenario → scene → condition/action/expectation`(CAE)
の3層構造を持つ。プロジェクトの `scenarios/` に .swift を置いて `swift build` すれば自動発見される。
**対象アプリはコードに書かない** —— 実行プロファイル(`runs/<name>.json`)→ アプリプロファイル
(`apps/<name>.json`)→ 実行中 platform の `ios.app` / `android.app` から解決されるので、
OS で bundle ID が違っても同じシナリオを `--profile ios` / `--profile android` で回せる
(コード側で固定したいときだけ `@TestClass(app: "...")` と書く。そちらが勝つ)。

```swift
import FTDSL

@TestClass                                      // 対象アプリは実行プロファイルが決める
                                                // platform: "ios"/"android"(省略 = 両OS対応。
                                                // 宣言した OS を回さない run では skipped 扱い)
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
                    tap("#login_btn||ログイン")          // || = 候補集合の和(節の順に先に見つかった方)
                    ifCanSelect("今はしない") {            // 出るか不定のシートは条件分岐で包む
                        tap("今はしない")
                    }
                }.expectation {
                    exist("#welcome_text||ようこそ")
                    screenLooksLike("ログイン後のホーム画面が表示されている")  // FM マルチモーダル検証
                }
            }
            scene(2, "誤ったパスワードはエラー表示") {
                condition { restartApp() }
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

**セレクタ式**(`||` は**候補集合の和**。要素を1つ選ぶときは節の順に先に見つかった方を使うので、
`#id||ラベル` はヒール連鎖としても働く。優先度: id > label > type+index):

| 記法 | 意味 |
|---|---|
| `#login_btn` | accessibility id(完全一致)。**identifier で1件も引けなければ placeholder を引く**(入力欄は経路で id と placeholder が入れ替わるため。docs/commands.md) |
| `#login*` / `#*login*` / `#*btn` | id の前方一致 / 部分一致 / 後方一致(完全形は `idStartsWith=` `idContains=` `idEndsWith=`) |
| `ログイン` | ラベル(**完全一致のみ**。完全形は `text=ログイン`) |
| `*ログイン*` / `ログイン*` / `*ログイン` | 部分一致 / 前方一致 / 後方一致(完全形は `textContains=` `textStartsWith=` `textEndsWith=`) |
| `textMatches=^行 [0-9]+$` / `idMatches=^row_[0-9]+$` | 正規表現(**部分一致**。全体一致は `^…$` を書く) |
| `.button` / `.button[2]` | 型+順番(**1 オリジン**。`.button[2]` = 2番目の Button。1番目は `[1]` を省略して `.button` と書く。`[1]` と明記しても可) |
| `.switch#ID` / `.switch&&ラベル` | 型と id/label の併用(値検証などで型を絞る) |
| `#save&&.button&&enabled=true` | **`&&` で AND 合成**。属性は `text` `value` `placeholder` `id` `type` `pos` `checked` `enabled`。一致方法(`Contains`/`StartsWith`/`EndsWith`/`Matches`)を持つのは `text`/`value`/`placeholder`/`id` の4属性のみ、`type`/`pos`/`checked`/`enabled` は完全一致のみ |
| `(保存\|OK)` / `text=(保存\|OK)` | **フィルタ内 OR**。`保存\|\|OK` と等価(相対の引数では `:right((保存\|OK))` と括弧を自分で書く) |
| `.button&&text!=キャンセル` / `.button&&!キャンセル` | **否定フィルタ**(`!値` は短縮形)。`textContains!=` `!#id` `!.button` も可。**否定だけの節・序数の否定は書けない** |
| `.input` / `.widget` | 型エイリアス(`.input` = textField\|secureTextField / `.widget` = OS 共通の役割型5つ) |
| `#list >> .clickable[2]` | **スコープ**(祖先 >> 子孫)。序数はスコープ内で数えるので画面クロムやスクロール位置でずれない。**容器がアプリの a11y ツリーに公開されている必要**があり、畳まれた容器(Flutter の `MergeSemantics` 等)は子孫が消えるため使えない |
| `通知:rightSwitch` | **相対セレクタ**(**基準が先**)。基準の帯に入り、その方向にある最も近い候補。該当が無ければ失敗する(id が無い要素を隣のラベルから指す) |
| `数量:right(2)` / `#a:below(.button&&項目)` / `見出し:right:belowButton` | 序数 / 任意フィルタ / 連鎖 |
| `<変更&&.button>:right(数量)` | 基準の `<...>` 囲み(Shirates 正典形・任意。基準の範囲を目で追いやすくする) |
| `=#で始まる生ラベル` | `=` エスケープで label 扱い(`>>` `&&` `:right` `*` を含むラベルもこれで書く) |

結合の強さは `&&` > `>>` > `||`。綴り誤りや未対応記法(`:near` `:parent` 等)、
`[abc]` のような序数、閉じない括弧は**実行前に構文エラー**になる
(黙ってラベル扱いにしない。誤記が `notExist` を素通りして緑になるのを防ぐため)。
**未知のフィルタ名**(`名前=値`)は生ラベルとして書ける(`notify=off` 等)が、既知フィルタ名と
紛らわしいとき(前方一致関係・大小文字違い・6文字以上で1文字違い・既知の基底名の直後に
大文字が続く形 `idPrefix=` 等)だけ実行前エラーになる。

**WebView(Web コンテンツ)内の要素**: ネイティブの WebView(iOS: WKWebView / Android:
android.webkit.WebView)の中身も同じセレクタ・同じコマンドで操作できるが、規約が3点だけ違う:

- **`#id`(HTML の `id`)が使えるかは読み取り経路で決まる**。DOM を読める経路
  (iOS の既定エンジン / Android のアプリ内 WebView・ブラウザ)と、a11y が id を出す構成
  (Android WebView 150 以降)では使える。**iOS の `engine: xcuitest` では出ない**
  (WebKit が HTML id を a11y へ渡さない)
- **リンクは `.link` と `.staticText` の2要素で重複して出る**(両 OS 共通)。同じラベルが
  2つ並ぶため、ラベル単独では曖昧になる → `.link&&ラベル` と型で絞る
- **入力欄は `#id||#placeholder の値` の2節で書く**のが確実。`#x` は identifier で引けなければ
  placeholder を引くので、この2節で「id だけ出る構成」「placeholder だけ出る構成」の両方を覆える
  (Android は WebView の版で **id と placeholder が入れ替わる**。片方だけに書くと他方の端末で
  「セレクタが見つからない」になる)

コンテナは `.webView` 型で出る(`.webView >> …` のスコープ起点にできる)。中身が
a11y/DOM に現れるまで初回は数秒かかることがあるため、**画面遷移直後の検証は `timeout:` を
長めに**取る。iOS の既定エンジン(hybrid)では中身の読み取り・委譲を自動で行うので
利用者側の書き分けは不要。

**型付きセレクタ(併設)**: 同じ意味を型で書ける。綴り誤りは**コンパイルエラー**になり、補完も効く。
文字列版と同じロケータに畳まれるだけなので、混在させても実行・レポート・自己修復は変わらない。

```swift
tap(.id("login_btn").or(.text("ログイン")))       // #login_btn||ログイン
tap(.id("list").find(.type(.cell).nth(2)))      // #list >> .cell[2]
tap(.text("通知").right(.switch))                // 通知:rightSwitch
exist(.type(.button).text("保存", .contains))    // .button&&textContains=保存
```

`.id` `.text(_, .exact|.contains|.startsWith|.endsWith|.matches)` `.value` `.placeholder` `.type`
`.checked` `.enabled` `.nth`(1 オリジン)/ 合成 `.or` `.find` / 相対 `.right` `.left` `.above` `.below`
(`matching:` で任意フィルタ、`nth:` で近い順)。型名は `.button` `.staticText` `.textField`
`.secureTextField` `.switch` と `.input` `.widget` `.cell` `.image` `.clickable`、語彙外は `.custom("…")`。
フィルタは常に「現在の対象」に効く(相対の**後**ならその相対先、前なら基準)。

**コマンド**の一覧・引数・挙動は **docs/commands.md** を参照(操作 `tap` `type` `swipe` `flick` 系 `pressEnter` /
スクロール `scrollTo`・`scrollDown` 系・`withScrollDown { }` / 検証 `exist` `notExist` `countIs` `appIs`・
`textIs`/`valueIs` の全対称(否定 `…Not`・`…IsEmpty`・`…MatchesDateFormat`。**セレクタは取らず直前に掴んだ要素を見る**)・`screenLooksLike`(FM 視覚検証)・
`verify(message) { }`(アサーション集約)/ 素の値の検証 `thisIs` 系 / アプリ制御・待機
(`waitForDisplay`/`waitForClose` 含む)・分岐・反復 / `procedure` `group` `irregularHandler` 等)。
特に効く規約だけ抜粋:

- **要素の出現待ちは暗黙**(`wait` は原則不要。足りなければ各コマンドの `timeout:` を上げる。
  秒は**小数可** — `timeout: 1.2` / `waitSeconds: 0.5`)
- **属性の検証は「掴んでから」書く**(`select("#msg").textIs("完了")`。`select("#msg")` の次の行に
  `textIs("完了")` と書いても同義 = 対象は直前に掴んだ要素。`textIs("#msg", "完了")` は書けない)
- **画面の値は `exist` / `select` の戻り値から読める**(`exist("#txt_total").text` / `.value` / `.id`)。
  期待値を書き切れないとき(控えた注文番号を後の画面で照合する等)に使う。
  値は `exist` した時点のもので**再取得しない**ので、更新途中の画面は先に `textIs` 等で確定させてから読む
- 折り返しの下は `tap("設定", scroll: .down)` / `exist(…, scroll: .down)` で**スクロールしながら探す**
  (方向はコンテンツ基準。`swipe(.up)` だけは指の動き)。**テキスト検証は自動スクロールしない**
- **マップ・キャンバス系**(地図・画像ビューア・図面)は `swipeBy(dxRatio:dyRatio:)` でパン
  (**両軸を非 0 にすると斜め**)・`pinchOut` / `pinchIn` でズーム・`doubleTap` でズームイン。
  **iOS はエンジンで成否が分かれるジェスチャがある**(既定の hybrid なら全て動く。
  `xcuitest` 単独と実機に残る穴は docs/commands.md の表)
- **出るか不定のアプリ内メッセージ**は `irregularHandler` を setUp で1回宣言すると自動で閉じる
  (OS 側のダイアログは書かなくてよい — ツール側で吸収する)。**1ステップで最大10回**まで閉じ、
  回数は `maxDismissals:` で変えられる。**アプリ本体とは別の `UIWindow` に載るモーダル**も
  木に載り、**覆われた背面は木から消える**(覆われたまま緑になるのを防ぐ。docs/commands.md)
- テストクラスの `func setUp()` / `func tearDown()` は各 `@Test` の前後で自動実行。
  **tearDown は失敗後でも実行される**

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

- 失敗セマンティクス: コマンド NG → **シナリオ中断**(以降のステップは scene を跨いですべてスキップ。
  tearDown だけは失敗後でも実行される)。
  ブロック内の生 Swift コードはスキップされないため、失敗後に走らせたくない処理は `procedure { }` に包む
- レポートは成否問わず `TestProjects/<name>/reports/scenario-*.md` に出力(scene → CAE → ステップ階層、
  トリアージ、失敗スクリーンショット、**修正提案**)
- **自己修復とヒールキャッシュ**: 自己修復が有効な実行(**`--profile` 実行では実行プロファイルの
  `heal` が既定 ON** / **プロファイルを使わない `fleetest run` は既定 OFF**。CLI からは
  `--heal` で ON・`--no-heal` で OFF に上書きできる。両方の同時指定はエラー)では、
  壊れたセレクタは FM が修復して続行し、
  結果は `TestProjects/<name>/.fleetest/heal-cache.json` に保存される。**2回目以降は FM なしで決定的に通過**し、
  レポートに「`TestProjects/SampleApp/scenarios/LoginTest.swift:17` — セレクタ "#email_input" を
  "#email||.textField[0]" に変更してください」のようなソース位置付き修正提案を出し続ける
  (ソースの自動書換はしない。人がソースを直すとキー不一致でキャッシュは自然に無効化される)
- **dry-run**: `fleetest run --dry-run`(Shirates の No-Load-Run 相当)。**デバイスにも FM にも
  触れず**、セレクタの構文誤り・到達しない scene・アサーション0の `expectation`・
  **撮った画面に実在しない `#id`** を数秒で落とす(実測: 76 シナリオで 3.4 秒)。
  `--scenario` / `--folder` / `--project` / `--quiet` はそのまま効き、**失敗があれば exit code 1**。
  デバイスを1台も使わないので `--profile` は使われない(`--platform` だけが
  `ios { }` / `android { }` の分岐を決める)。レポートは書かず、`--failed` の判断材料にもならない。
  MCP は `ft_dry_run`、VSCode 拡張は `fleetest api run --dry-run` 経由で同じ検証を行う

## UI(VSCode 拡張)

シナリオ実行・デバッグ実行(ブレークポイント/ステップ実行)・ライブ操作・デバイスモニター・
ライブ操作(録画→シナリオ生成)・結果ダッシュボード・自己修復候補の確認・プロファイル編集支援と
いった対話的な UI は、VSCode 拡張(`vscode-fleetest/`)に一本化している。CLI と同じ `fleetest api ...` サブコマンド経由で
fleetest 本体を呼び出すため、挙動は CLI・MCP と共通のモジュールに基づく。

**ライブ操作の割り当て**: 画面をクリック = タップ / 500ms 以上ホールド = 長押し /
ドラッグ = スワイプ / **Alt(Option)+クリック = ダブルタップ** / ツールバーの **拡大・縮小** =
画面全体のピンチ。ダブルタップを「素早く2回クリック」にしていないのは、パネルの1クリックを
既にタップとして送っているため —— 2回目を待つ設計にすると通常のタップが毎回遅くなる。
**iOS の Compose(ダブルタップ)と Flutter(ピンチ)は XCUITest 経路では届かない**
(docs/commands.md の表。ライブ操作は実行プロファイルのエンジンに従う)。

**デバイス画面はヘッドレス映像ストリーミングで表示する**: デバイスモニター・ライブ操作の
画面は、変化駆動でフレーム(JPEG)を配信する常駐ヘルパー(iOS: `fleetest-simstream` /
Android: `fleetest-androidstream`)経由でほぼリアルタイムに更新する。ScreenCaptureKit を
使わずシミュレータ/エミュレータの画面を低負荷で流すヘッドレス方式で、静止画面では
フレームをほぼ出さない。設定タブのトグル(`monitor.pollingMode`)で従来のポーリング
(一定間隔の静止画取得)方式にも切り替えられる(ヘルパー未ビルド時は自動でポーリングに
フォールバック)。

セットアップ手順・各機能の詳細・設定一覧(`fleetest.*`)は
[vscode-fleetest/README.md](vscode-fleetest/README.md) を参照。

## MCP サーバ(エージェント連携)

`fleetest-mcp` は同じ機能を MCP(Model Context Protocol)ツールとして公開する stdio サーバ。
リポジトリ直下の [.mcp.json](.mcp.json) に登録済みのため、**このディレクトリで Claude Code を
開くと自動で `fleetest` サーバが使える**(初回はビルドが走る)。

| ツール | 内容 |
|---|---|
| `ft_status` | 接続確認。**宛先**(どのシミュレータ/エミュレータか。Android は serial と AVD 名)と、**session のアプリが今も前面か**まで返す(session はブリッジが掴んでいるアプリで、ホームへ戻っても変わらない)。Android で `serial` を省略して複数台つながっているときは、失敗せず**全台を一覧**で返す(読み取り専用なので。操作系は従来どおり曖昧なら断る) |
| `ft_doctor` | FM 可用性。使えないときは**止まる機能(self-healing / triage / screenLooksLike / occlusion-guard)と代わりの書き方**まで返す |
| `ft_launch` / `ft_terminate` | アプリ起動・終了 |
| `ft_install` | アプリをパッケージファイルからインストールする(iOS: `.app` バンドル / Android: `.apk`) |
| `ft_snapshot` | 画面要素一覧(set-of-mark 圧縮形式)。**`waitFor` を渡すと出るまでホスト側で待つ**(セレクタ記法は DSL と同じ。既定 5 秒)。**対象アプリが前面に居なければ先頭で警告する**(XCUITest の木はセッションのアプリに閉じているので、別アプリが前面でも同じ木を返してしまう。**iOS 実機では OS が前面状態を正しく申告しないため警告は出ない**)。**スクロール容器の外に取り残された要素(ghost)は先頭と各行で名指しする**(`⚠️scroll-leftover`) —— 一覧の見た目は普通の行と同じだが、その座標には別のものが描かれていることがある。**スクロール容器の行には `scroll` を付ける**(`scrollFrame:` に指定できる領域。**2つ以上あるときだけ**先頭でも名指しする)—— ただし**印が無い = スクロールしない、ではない**(Compose / Flutter の in-app は自前描画で申告できない)。撮った `#id` は `<プロジェクト>/.fleetest/selector-inventory.json` に貯まり、`ft_dry_run` の綴り誤り照合に使われる。**同じ id の大群(地図の POI など。非操作の葉が20件以上)は1行に畳む** —— 見出しに続けて「ラベル[ref]」の索引が出るので ref では撃てる。frame まで要るときは `expandBulk: true`。**上限で要素が落ちたときは先頭で言う**(何件・何が落ちたか。内訳は iOS のブリッジが申告する) —— 落ちた要素は木から消えているので `waitFor` も `ft_scroll_to` も一生見つけられない。**ラベルも id も無い clickable には `#容器 >> .clickable[n]` を添える**(id を持つ祖先があるときだけ。無ければ従来どおり「ref か座標しかない」)。**同じラベルが複数に当たるときは「代わりに書けるセレクタ」を一致ごとに出す**(`#id` > 一意ラベル > `#容器 >> .型[n]`。書けないものは「—」で明示する = 無言のケースを作らない。**勧める前にサーバ自身が引いて当人が返ることを確かめている**)。**打ち切ったときは枠を食っている id 群まで名指しする**(`#VKPointFeature が 119 件中 87 件` のように)—— 読み手にできる手は「それを描いている物を畳む」なので、原因を当てさせない。**`interactiveOnly: true` でレイアウト専用の行を隠す**(ラベルも値も持たず、操作もスクロールもしない要素。密な画面では半分以上が消える)—— ref も frame も変わらず、隠れた行も ref では撃てる |
| `ft_tap` / `ft_type` / `ft_swipe` / `ft_long_press` | 画面操作(`ft_type` は `pressEnter: true` で入力後に Enter/IME アクションまで撃つ。`text` を省けば Enter だけ)。**ref は撃つ直前に撮り直して照合する** —— 動いていれば今の位置へ撃ち直し、消えていれば撃たずに理由を返す。スクロール残像は撃つが、**何に当たったかもしれないかを警告に添える**(黙って別の要素を叩かない)。**ref を撃つ操作系は「その操作を再現するセレクタ」を必ず返す**(`tap [40] done (selector: #btn_add)`)—— ref はセッション限りの番号でシナリオには書けないため。安定セレクタが無ければ「無い」と明示し、座標には出さない(再現できる根拠が無い)。**操作7ツール(`ft_tap` / `ft_type` / `ft_swipe` / `ft_drag` / `ft_double_tap` / `ft_long_press` / `ft_pinch`)は `snapshotAfter: true` で結果の一覧まで一緒に返す** —— 操作のたびに `ft_snapshot` を撃つ往復が消える(`waitFor` を併せて渡せば、結果の画面に目的のセレクタが出るまで待ってから返す)。長押しの秒数は DSL と同語彙の `holdSeconds`(`ft_long_press`) |
| `ft_scroll_to` | セレクタが出るまでスクロールして、**撮り直した一覧を返す**。`ft_swipe` + `ft_snapshot` の繰り返しより確実で、探索そのものは DSL の `scrollTo` と同じ実装(整定・容器基準の刻み・飛び越しの拾い直し)。`scrollFrame` でスクロールする容器を指定できる(候補は `ft_snapshot` の `scroll` 印)。**半開きのシートの中でリストが動かなくなったら、グラバーを引き上げて1度だけやり直す**(判定は DSL と共有の `StepNote.sheetCollapsed`。やり直したことは note で言う)—— グラバーを名前で特定できないときは何もしない(当てずっぽうのドラッグで地図やリストを動かさない) |
| `ft_batch` | **DSL の手を並べて1回の承認で実行する**(`"steps": "tap '#a'; type '#field' 'abc'; scrollTo '#btn' direction: .down"`)。構文は最小記述の1つだけ —— 引数は引用符(`'…'`/`"…"` 等価)+空白区切り・手は `;` か改行。正形の括弧・カンマ・配列は書き換え方を添えて拒否する。operation/scroll コマンドのみ(launchApp 等は `ft_launch` へ誘導)・対象はセレクタ指定(ref 不可)・全手を実行前に検証し、最初の失敗で止まってその画面を返す(成功時は最後の画面を1回だけ)。通ったバッチは `ft_draft_scenario` がそのまま正形の DSL にする |
| `ft_rotate` | デバイスを回転し、**新しい向きの画面一覧を返す**(回転の整定を待つので frame は新座標系。回転前の ref は解決しなくなる)。シナリオの `rotateTo()` と違い**終了時に向きを戻さない**ので、次の作業へ渡す前に自分で戻す。Android は自動回転を off にして off のままにする(戻さないと角度が定着しないため) |
| `ft_navigate` | 戻る / ホーム / タスク切替(3操作を1ツールに束ねている) |
| `ft_open_url` | ディープリンクの URL を配送する(**アプリを再起動せず**、今の画面の上に遷移が積まれる。`ft_launch` は逆に必ず再起動する)。画面遷移を飛ばして目的の画面から探索を始めるときに使う。配送は非同期なので、素の `ft_snapshot` を直後に撃つと遷移前の画面を掴むことがある。**`snapshotAfter: true` は着地(木が変わること)を待ってから読む**(2026-08-16。目的地固有の物を待ちたいなら `waitFor`、待たずに読むなら `waitForChange: false`) |
| `ft_clear_input` | 入力欄を空にする(`ft_type` は追記なので、置き換えるならまず消す)。**パスワード欄は追記できない**(読みが伏せ字なので追記すると伏せ字が本文に入る)ため、Android は 422 で断る = 先にここを通す |
| `ft_clear_app_data` | アプリのデータと権限を消す(iOS はシミュレータのみ)。**シナリオは `clearAppData()` から始まる**ので、探索も同じ初期状態から行う。アプリは止まるので後で `ft_launch` |
| `ft_dsl_commands` | **DSL コマンドの索引**(名前と署名)。シナリオを書く前に引いて、存在しないコマンドを書かないようにする。デバイスに触らない |
| `ft_double_tap` / `ft_pinch` / `ft_drag` | マップ・キャンバス系の操作(ダブルタップ / ズーム / **斜めを含む任意方向のドラッグ**)。**`ft_drag` は `fromRef`(要素の中心から)と `dx`/`dy`(移動量)でも書ける** —— 半開きのボトムシートを広げるのに、グラバーの frame を読んで座標を組む必要がない。**`ft_pinch` は `ref` でも `x`/`y` でも対象を指せる** —— 地図は要素として木に無いので、シートが半分出ている画面で対象を省くと指が画面全体に開いて**シートのほうが掴まれる**(実測)。座標を honour できるのは **Android と iOS in-app だけ**(XCTest に座標ピンチが無い)で、iOS の XCUITest エンジンでは**全画面へ退化したことを戻り値で言う**。iOS は Compose のダブルタップと Flutter のピンチがエンジン依存なので、**`profile` を渡して実行と同じエンジンで試す**(docs/commands.md の表) |
| `ft_screenshot` | スクリーンショット(画像を返す — エージェントの視覚検証用) |
| `ft_list_scenarios` / `ft_run_scenario` | シナリオ一覧 / 決定的実行(`project`・`profile`・`heal` オプション付き。自動ビルド込みで、コンパイルエラーはそのまま返る=エージェントが直せる) |
| `ft_dry_run` | **デバイス不要**の検証(数秒)。セレクタの構文誤り・到達しない scene・アサーション0の expectation・**`ft_snapshot` で撮った画面に実在しない `#id`** をデバイス実行の前に落とす |
| `ft_list_projects` | テストプロジェクトと実行プロファイルの一覧 |
| `ft_draft_scenario` | **探索した操作列を Swift シナリオの下書きにして返す**(ファイルには書かない — 置き場所はスキルの仕事)。各手は「そのとき MCP が推奨したセレクタ」で書かれ、**セレクタを解決できなかった手は TODO コメントとして残る**(消すと下書きが実際の手順と食い違う)。既定の範囲は直近の `ft_launch` 以降(`all: true` で全体)。**expectation は空の骨格で出る** —— アサーションは推測で作らず、`ft_dry_run` の「アサーションの無い expectation」検出が作者に埋めさせる(dry-run がそこを指摘するのは意図した設計)。**応答は使った手を番号付きで並べる** —— 探索は行き止まりや撃ち直しも本筋と同じ忠実さで記録するので、その一覧を見て `drop: [n, …]`(番号は一覧のもの)や `lastN: k` で回り道を落としてから採用する |
| `ft_list_devices` / `ft_list_apps` / `ft_logs` | 端末・アプリ・ログの棚卸し。**`ft_list_apps` の既定は user アプリだけ**なので、地図やブラウザのような**プリインストール(system)は出ない** —— `filter:`(id と表示名の部分一致・大小無視)を渡すと system も併せて探し、`includeSystem: true` なら全部を `[system]` 付きで並べる。表示名が出るのは iOS だけ(Android の `pm` は package 名しか返さない)。**`ft_list_devices` はブリッジの無い iOS 機に「no bridge — MCP からは操作不可」と書く**(動いているのに触れない機が行の見た目では分からなかった) |

**実機(iPhone / Android 端末)**: 画面操作系(`ft_tap` / `ft_type` / `ft_swipe` / `ft_scroll_to` /
`ft_long_press` / `ft_double_tap` / `ft_pinch` / `ft_drag` / `ft_navigate` / `ft_snapshot` / `ft_screenshot`)は
そのまま使える。**シミュレータ/エミュレータ専用の操作は自動で振り分ける**:
`ft_install` は iOS 実機なら `devicectl`(シミュレータは `simctl`)、`ft_clear_app_data` は
iOS 実機では 501 で断る(devicectl に同等手段が無い。Android は実機でも `pm clear` が効く)。
in-app エンジンは注入できないので実機では選ばれない。Android のエミュレータ gRPC 制御も
実機では自動的に adb 経路へ落ちる。**`profile` を渡すと端末の UDID まで分かる**ので、
渡しておくのが確実(渡さないときはブリッジが名乗るデバイス名から引き当てる)。

**iOS のエンジン**: `profile` を渡せば実行プロファイルのエンジンに追従する。渡さないときは
**接続先ポートのブリッジに従う** —— in-app ブリッジが動いていればそれを主にした hybrid を組み
(実行の既定と同じ)、XCUITest ブリッジならそのまま使う。in-app 側が実装できない操作
(ホーム / タスク切替 / ドラッグ / 座標長押し)は XCUITest ブリッジへ自動で回るので、
どちらでも全ツールが使える。**実機は注入できない**ので常に XCUITest。
なお in-app 経路で `ft_navigate` の `home` / `appSwitcher` を撃つと対象アプリが背面化し、
その中に住む in-app ブリッジが suspend されて応答しなくなる。**その間は全ツールが自動的に
XCUITest ブリッジ側へ寄る**(読みが少し遅くなるだけで止まらない。`ft_launch` で戻すと元に戻る)。

全ツールに `platform: ios|android` を指定可能。**`profile` を渡すと実行プロファイルのエンジン(既定 hybrid = in-app 優先)で動く** —— 探索と実行で snapshot の内容もジェスチャの成否も揃うので、マップ系を触るときは必ず渡す。探索(explore 相当)はツール化していない —
スナップショットと操作プリミティブがあれば、クライアント側のエージェント自身が探索できるため。
役割分担は「エージェント=知能(探索・判断)、fleetest=決定性(操作・再生・検証)」。

## アーキテクチャ

```
fleetest CLI / MCP ──(サブプロセス)──▶ fleetest-scenarios-<project>(プロジェクトのシナリオを発見・実行)
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
TestProjects/          テストプロジェクト(コミットして資産化する)
  SampleApp/
    profiles/        実行プロファイル(apps / machines / runs。JSON)
    scenarios/       テストシナリオ(Swift DSL)
      _Main.swift      ランナーへの委譲(編集不要)
      Generated/       ライブ操作の録画(gen-scenario)が生成したシナリオ
      _disabled/       コンパイル対象外の退避場所(並列デモ・生成失敗コードの隔離先)
    reports/         実行レポート(プロジェクト別)
    .fleetest/        ヒールキャッシュ等(プロジェクト別)
Sources/
  fleetest/         CLI(swift-argument-parser。project/machine/profile コマンド含む)
  fleetest-mcp/     MCP サーバ(stdio / JSON-RPC、自前実装)
  fleetest-simstream/     iOS シミュレータ画面のヘッドレス映像ストリーミング(変化駆動で JPEG を stdout 配信)
  fleetest-androidstream/ Android 画面のヘッドレス映像ストリーミング(iOS 版とフレームプロトコル互換)
  FTDSL/           Swift DSL 本体(コマンド・セレクタ式・発見・レポート・コード生成・ヒールキャッシュ)
  FTDSLMacros/     @TestClass / @Test マクロ実装(swift-syntax はここに閉じる)
  FTScenarioRunner/ fleetest-scenarios-<project> の CLI 実装(list / run・NDJSON イベント)
  FTCore/          ステップモデル / AppDriver / StepExecutor / プロジェクト・プロファイルモデル(FM 非依存・外部依存ゼロ)
  FTAgent/         FM エージェント(Explorer / Healer / Verifier / Triager)
  FTBridgeClient/  iOS ブリッジの HTTP クライアントと起動管理・SimulatorCatalog・BridgeProvisioner
  FTAndroid/       Android ドライバ(常駐ブリッジ)・AndroidDeviceCatalog・ProfileWorkerFactory
Runner/            xcodegen 定義 + ブリッジ本体(HTTP サーバ内蔵 UI テスト)
SampleApp/         検証用 SwiftUI デモアプリ(test@example.com / password123)
vscode-fleetest/    VSCode 拡張(UI 入口。詳細は vscode-fleetest/README.md)
docs/              設計書・実装知見
```

## CI で回す

`fleetest run --profile <名前> --quiet --junit reports/junit.xml` が exit code(0/1)と
JUnit XML を出す。self-hosted の Mac(Jenkins・AWS EC2 Mac 等)前提・
Apple Intelligence 不要(FM 系は自動スキップ。GitHub ホストランナーはサポート外)。
Jenkins の例と flaky の扱いは [docs/ci.md](docs/ci.md)。

実行結果は `<project>/results/runs/<年月>/<runID>/` に JSON で貯まる。
落ちた run を「条件フェーズ(共有フローや端末の準備)で落ちたのか / 検証フェーズ
(テスト内容)で落ちたのか」で仕分けるための欄 —— `failedSteps[].section` / `command` /
`failureKind` / `notes`、run.json の `workerAnomalies` —— は
[docs/results-json.md](docs/results-json.md)(jq のレシピつき)。

## パフォーマンス(実測値)

| 操作 | 実測 | 補足 |
|---|---|---|
| ブリッジ `/status` | 13ms | HTTP サーバ自体のオーバーヘッドはほぼゼロ |
| スナップショット(iOS) | 約 80〜90ms(初回/画面遷移直後は約 250ms) | XCUITest のツリー取得コストが本体(performance-tuning.md §8) |
| スナップショット(Android) | 中央値 8.7ms | 常駐ブリッジ(AndroidRunner/) |
| MCP ツール呼び出し | +0ms 相当 | ブリッジ直叩きと差なし(常駐プロセス) |
| シナリオ実行(launch+タップ+検証×2、Android) | 約 2.2秒 | 整定はブリッジの a11y イベント静穏検知(固定待ちなし。2026-07 高速化で 4.9秒→2.2秒) |

- `swift run fleetest ...` は毎回 SwiftPM のチェックで **約1.6秒** 上乗せされる。
  連続実行するときは `.build/debug/fleetest ...` を直接叩くと速い(MCP は常駐なので無関係)
- FM の応答時間: screenMatches(視覚検証)数秒、修復・トリアージ数秒(すべてオンデバイス・無料)
- 計測手順・調整ノブ・設計原則(不採用の施策含む)は
  [パフォーマンスチューニングガイド](docs/performance-tuning.md)を参照

## トラブルシューティング

- **オンデバイスモデル: 利用不可** → システム設定で Apple Intelligence を有効化(`doctor` が理由を表示)
- **ドライバに接続できません** → iOS: `bridge up` を先に実行(ログは `.fleetest/bridge-<ポート>.log`)。
  Android: `adb devices` で接続確認
- **シナリオのコンパイルエラーで実行できない** → `swift build --product fleetest-scenarios-<プロジェクト名>`
  のエラーを修正する。ライブ操作録画(gen-scenario)の生成不良は scenarios/_disabled/ に自動隔離される
- **プロジェクトが認識されない(手動コピーや git pull 後)** → `fleetest project sync` で
  Package.swift のマーカー区間を再生成する(`project list` が未登録を警告する)
- **マシンプロファイルが見つからない** → 実行プロファイルの `"machine"` が
  `profiles/machines/<名前>.json` と一致しているか確認する
- **Android の snapshot が遅い** → `fleetest bridge status --platform android`・`doctor` で
  ブリッジの導入・起動状況を確認。`fleetest bridge up --platform android` で強制再セットアップできる
- **Android の日本語入力が入らない** → ブリッジが `ACTION_SET_TEXT` で入力するため通常は IME 不要。
  入らない場合はブリッジの導入状況(`doctor`)を確認
