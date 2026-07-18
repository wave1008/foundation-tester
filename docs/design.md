# foundation-tester 設計書

macOS 27 の Foundation Models framework(オンデバイス 3B モデル)を最大限活用する、
iOS / Android 両対応のアプリ E2E テストツール。iOS を先行実装し、Android は同じ
`AppDriver` 抽象の上に後続実装した(経緯・時系列は §7, §8 参照)。

- 作成日: 2026-07-07 / 最終更新: 2026-07-12
- ステータス: iOS / Android とも実装済み・運用中(GUI 入口は VSCode 拡張に一本化)
- 決定事項: ハイブリッド型 / 自作 XCUITest ブリッジ+自作 Android ブリッジ / シミュレータ優先 / Swift + FoundationModels

---

## 1. 背景と方針

### 1.1 Foundation Models framework(macOS 27 / WWDC 2026)の前提

| 機能 | 内容 | 本ツールでの用途 |
|---|---|---|
| 新オンデバイスモデル (AFM 3) | ロジック・tool calling が大幅改善、Vision(画像入力)対応 | エージェントの頭脳 |
| Guided Generation (`@Generable`) | constrained decoding による型安全な構造化出力。パース失敗が原理的に起きない | 全ての LLM 出力(次アクション、アサーション、修復案、レポート) |
| Tool calling (`Tool` プロトコル) | 並列/直列の呼び出しグラフを framework が自動処理 | 画面詳細のオンデマンド取得など補助的に使用 |
| マルチモーダル | 画像+テキスト入力(NSImage/CGImage/CVPixelBuffer/URL) | スクリーンショットの視覚検証・トリアージ |
| Dynamic Profiles | セッション中にモデル・ツール・instructions を切替 | explorer / verifier / triager の役割切替 |
| `LanguageModel` プロトコル | オンデバイス / PCC(32K ctx) / Claude / Gemini / MLX を同一 Session API で差替 | 難しい計画立案だけ大型モデルに逃がす保険 |
| 制約: コンテキスト ~4K トークン級 | TN3193 参照。プロンプト+応答で共有 | **設計全体を規定する最重要制約** |

### 1.2 3B モデルに合わせた基本方針: 「AI が作り、コードが再生する」

小さいモデルに毎ステップ判断させ続ける自律エージェント型は、コンテキスト溢れと
判断ミスが蓄積する。本ツールは **ハイブリッド型** を採る:

1. **探索・生成モード**: FM エージェントがアプリを探索し、決定的なテストシナリオ
   (Swift DSL。§10)を生成して保存する。LLM を使うのはここ。
2. **実行モード**: 保存済みシナリオを FM なしで決定的に再生。高速・安定で CI 向き。
3. **失敗時のみ FM が介入**: ロケータ自己修復、スクリーンショット+ツリー差分の
   トリアージ、自然言語バグレポート生成。

コンテキスト対策の原則:
- アクセシビリティツリーは **圧縮テキスト(set-of-mark 形式)** にして 1 画面ずつ渡す
- セッションは **1 ステップ = 1 セッション**(履歴は要約した「旅程ログ」だけ持ち回る)
- 出力は全て `@Generable` で構造化(自由文を返させない)

---

## 2. 全体アーキテクチャ

```
┌─ macOS ホスト ────────────────────────────────────────────────────┐
│  ftester CLI / MCP サーバ / VSCode 拡張(共通で ftester api を呼ぶ) │
│  ├─ FTAgent        : FoundationModels エージェント層               │
│  │   ├─ ExplorerProfile   (探索・Swift シナリオ生成)               │
│  │   ├─ VerifierProfile   (マルチモーダル画面検証)                 │
│  │   └─ TriagerProfile    (失敗トリアージ・自己修復)               │
│  ├─ FTDSL          : Swift DSL(§10)/ セレクタ式 / ヒールキャッシュ │
│  ├─ FTCore          : AppDriver プロトコル / StepExecutor(実行機) │
│  ├─ FTBridgeClient  : iOS ブリッジへの HTTP クライアント・起動管理  │
│  └─ FTAndroid        : AndroidDriver + Android ブリッジ管理        │
└──────────────┬─────────────────────────────┬───────────────────────┘
               │ HTTP (localhost:8123〜 —     │ adb forward ⇄ 常駐ブリッジ
               │ シミュレータはホストと       │ (AndroidRunner/。iOS ブリッジと
               │ ネットワークスタック共有)     │  プロトコル完全互換の instrumentation)
┌──────────────▼───────────────┐   ┌──────────▼──────────────────────────┐
│  iOS シミュレータ             │   │  Android エミュレータ / 実機         │
│  FTesterRunnerUITests         │   │  BridgeInstrumentation(常駐)        │
│  (XCUITest 内 HTTP サーバ,    │   │  ├─ QuietWaiter: a11y イベント静穏  │
│   WDA 方式)                   │   │  │   検知で操作応答(固定 sleep 廃止)│
│  └─ XCUIApplication で        │   │  └─ SnapshotBuilder: AccessibilityNodeInfo
│     対象アプリを起動・操作     │   │     直接走査(型語彙を iOS と共通化) │
└────────────────────────────── ┘   └───────────────────────────────────┘
```

**`AppDriver` プロトコル**が唯一のプラットフォーム境界。iOS ブリッジ(Runner/)・Android
ブリッジ(AndroidRunner/)・InApp ブリッジは共通コア 9 エンドポイント(status/session/
snapshot/tap/type/swipe/press/screenshot/terminate)を共有しつつ、iOS は drag/appswitcher/
home を追加した12、Android は locale を追加した10、InApp はコアのみの9という差分があるため、
`FTAgent` / `FTCore` / `FTDSL` はプラットフォーム非依存のまま両OSで動く
(ブリッジ設計の詳細は §4、Swift DSL の詳細は §10)。

```swift
protocol AppDriver {
    func status() async throws -> StatusResponse
    func install(packagePath: String) async throws      // .app / .apk
    func launch(bundleID: String) async throws
    func activate(bundleID: String) async throws         // 状態保持のまま前面化(未起動なら launch)
    func openAppSwitcher() async throws
    func home() async throws
    func snapshot() async throws -> SnapshotResponse     // 圧縮済みツリー
    func tap(ref: Int) async throws
    func tap(x: Double, y: Double) async throws
    func type(ref: Int?, text: String) async throws
    func swipe(_ direction: FTSwipeDirection) async throws
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws
    func press(ref: Int, duration: Double) async throws
    func press(x: Double, y: Double, duration: Double) async throws  // 座標指定ロングプレス
    func screenshot() async throws -> Data               // PNG
    func terminate() async throws
}
```

未対応ドライバ(InAppDriver/SystemUIDriver 等)は activate/openAppSwitcher/home/drag/
座標 press にデフォルト実装(launch へのフォールバック、または 501 エラー)が用意されている
(Sources/FTCore/AppDriver.swift)。

---

## 3. リポジトリ構成

```
foundation-tester/
├── Package.swift                  # CLI とライブラリ (macOS 27+)。マーカー区間にプロジェクト毎の
│                                  # executableTarget を自動生成(§11。ftester project create/sync)
├── Sources/
│   ├── ftester/                   # CLI エントリポイント(+ ProjectCommands / ProfileRunner / Api*Command)
│   ├── FTCore/                    # AppDriver, StepExecutor, ScenarioHost, RunOrchestrator,
│   │                              # TestProject / RunProfile / LocalConfig(§11)
│   ├── FTDSL / FTDSLMacros/       # Shirates 風 Swift DSL とマクロ(§10)
│   ├── FTScenarioRunner/          # ftester-scenarios-<project> の CLI 実装
│   ├── FTAgent/                   # FoundationModels: プロファイル, @Generable 型, Tools
│   ├── FTBridgeClient/            # iOS ブリッジ HTTP クライアント + SimulatorCatalog / BridgeProvisioner
│   ├── FTAndroid/                 # AndroidDriver + AndroidBridge / AndroidDeviceCatalog / ProfileWorkerFactory
│   └── ftester-mcp/               # MCP サーバ(stdio、自前実装)
├── Runner/                        # xcodegen 定義 + iOS ブリッジ本体
│   ├── project.yml                #   xcodegen 用プロジェクト定義
│   ├── FTesterRunnerApp/          #   空のホストアプリ(UIテストの器)
│   └── FTesterRunnerUITests/      #   HTTP サーバ内蔵の常駐 UI テスト(§4.1〜4.2)
├── AndroidRunner/                 # Android ブリッジ本体(§4.5。詳細は AndroidRunner/README.md)
│   ├── src/com/example/ftbridge/  #   BridgeInstrumentation / QuietWaiter / SnapshotBuilder 等(Java のみ)
│   ├── build.sh                   #   prebuilt/ftbridge.apk の再ビルド
│   └── prebuilt/ftbridge.apk      #   同梱 prebuilt APK(初回操作時に自動インストール)
├── Projects/                      # テストプロジェクト(§11)
│   └── SampleApp/
│       ├── profiles/              #   実行プロファイル(apps / machines / runs)
│       ├── Scenarios/             #   Swift DSL シナリオ(SPM ターゲットの path)
│       ├── reports/               #   実行レポート出力先(プロジェクト別)
│       └── .ftester/              #   ヒールキャッシュ等(プロジェクト別)
├── Scripts/bench.swift            # 計測基盤(§9。詳細は docs/performance-tuning.md)
├── SampleApp/                     # 検証用の小さな SwiftUI デモアプリ(テスト対象)
├── vscode-ftester/                # VSCode 拡張。UI 入口はここに一本化(旧 ftester-gui は 2026-07-10 削除)
└── docs/design.md                 # 本書
```

---

## 4. アプリ操作ブリッジ(自作)設計

WebDriverAgent と同じ原理を最小構成で自作する(iOS)。Android にも同じプロトコルで
話す常駐ブリッジを実装しており(§4.5)、`AppDriver` の実装が両OSで揃っている。

### 4.1 常駐のしくみ

- `FTesterRunnerUITests` に終わらないテスト `testRunServer()` を 1 本だけ置く。
  テスト内で HTTP サーバを起動し、`RunLoop.current.run()` で常駐。
- 起動手順(CLI が内部で実行):
  1. `xcodebuild build-for-testing -project Runner/FTesterRunner.xcodeproj
     -scheme FTesterRunner -destination 'platform=iOS Simulator,name=iPhone 17'`
  2. `xcodebuild test-without-building -xctestrun <derived>.xctestrun ...`
     (環境変数 `FT_PORT=8123` をテスト環境に渡す)
- シミュレータはホストとネットワークスタックを共有するため、テスト内で
  `127.0.0.1:8123` に listen すればホストの `localhost:8123` から直接届く。
  ポート番号は CLI が空きポートを選んで環境変数で注入する。

### 4.2 HTTP サーバ実装

- 依存最小方針に合わせ、**BSD ソケット直書きの極小 HTTP/1.1 サーバ**(~200 行)を
  テストバンドル内に実装する(GET/POST、Content-Length ボディ、JSON のみ)。
  実装が難航した場合の代替は FlyingFox(pure Swift、テストバンドル内動作実績あり)。

### 4.3 エンドポイント

| Method/Path | 動作 |
|---|---|
| `GET  /status` | ランナー生存確認・シミュレータ情報 |
| `POST /session` | `{bundleID}` → `XCUIApplication(bundleIdentifier:).launch()` |
| `GET  /snapshot` | アクセシビリティツリーを圧縮 JSON で返す(4.4) |
| `POST /tap` | `{ref}` または `{x,y}` |
| `POST /type` | `{ref, text}`(tap → typeText) |
| `POST /swipe` | `{direction}` or `{fromRef, direction}` |
| `POST /press` | `{ref, duration}` 長押し |
| `GET  /screenshot` | `XCUIScreen.main.screenshot()` → PNG |
| `POST /terminate` | 対象アプリ終了 |

上記9個は共通コア。iOS ブリッジはこれに加え `POST /drag`・`POST /appswitcher`・`POST /home` を
実装(計12)、Android ブリッジは `POST /locale` を追加(計10。§4.5)、InApp ブリッジは
共通コアのみ(計9)。

### 4.4 スナップショットの圧縮(4K コンテキストへの最重要対策)

`XCUIApplication.snapshot()`(`XCUIElementSnapshot`)を再帰走査して:

1. **フィルタ**: 非表示・サイズ 0・画面外・`Other`/`Group` で情報を持たない中間ノードを除去
2. **属性の絞り込み**: type / identifier / label / value / frame / hittable のみ
3. **要素参照番号(set-of-mark)** を振り、FM には 1 行 1 要素のテキストで渡す:

```
[3]  Button   "ログイン"        id=login_btn  (120,610 180x44)
[4]  TextField "メールアドレス"  id=email      (24,320 342x44) value=""
[7]  StaticText "パスワードが違います"          (24,380 342x20)
```

- 操作 API(tap 等)は `ref` 番号で受け、ランナー側が直近 snapshot の
  ref→要素クエリ対応表を保持して解決する。
- 目標: 一般的な画面で **300〜800 トークン**。超過時は「hittable 要素優先 +
  テキスト要素の先頭 N 件」に切り詰め、`(+12 elements truncated)` を明記。

### 4.5 Android ブリッジ(対になる実装。AndroidRunner/)

iOS ブリッジと同じ WDA 方式を Android の instrumentation として自作したもの。
`AppDriver` の Android 実装(`AndroidDriver`, Sources/FTAndroid/)から見れば
iOS ブリッジと区別なく扱える。

- **常駐 instrumentation**: `am instrument -w` でデバイス内にバックグラウンド常駐させ、
  HTTP サーバ(BridgeInstrumentation)を内蔵する。`AndroidBridge.swift` が初回操作時に
  自動インストール・自動起動するためセットアップ手順は不要
- **共通コア9 + locale の10エンドポイント**: §4.3 の共通コア(status/session/snapshot/
  tap/type/swipe/press/screenshot/terminate)に `POST /locale` を加えた10エンドポイントを話す
  (iOS 固有の drag/appswitcher/home は未実装)ため、共通コア部分はホスト側の `FTBridgeClient`
  相当のクライアントコードを流用できる
- **操作応答 = a11y 静穏後**: 各操作 API は注入後、対象パッケージの a11y イベントが
  一定時間静まるまで応答を保留する(QuietWaiter)。固定 sleep をやめてイベント駆動にした
  2026-07 の高速化はこの仕組みが土台(詳細・実測は [performance-tuning.md](performance-tuning.md))
- **アニメーション自動無効化**: ブリッジ起動時に window/transition/animator の
  アニメーション倍率を 0 に固定し、静穏判定後に screenshot が古い絵を掴む問題を回避する
- 実装・落とし穴の詳細は重複させず [AndroidRunner/README.md](../AndroidRunner/README.md) を参照

---

## 5. FM エージェント層(FTAgent)設計

### 5.1 セッション戦略(4K トークン運用)

- **1 ステップ = 1 セッション**。毎ステップ新しい `LanguageModelSession` を作り、
  以下だけを渡す:
  - instructions: 役割定義(プロファイル毎に固定、~200 トークン)
  - prompt: テスト目標 + **旅程ログ要約**(直近の行動履歴を FM 自身に 3〜5 行へ
    要約させたもの、~150 トークン)+ 現在画面の圧縮スナップショット
- 応答は必ず `@Generable` 型。自由文を返させないことで応答トークンも節約。

### 5.2 主要な @Generable 型

```swift
@Generable
struct NextAction {
    @Guide(description: "実行するアクション種別")
    var kind: ActionKind          // tap, type, swipe, assert, back, done, giveUp
    @Guide(description: "対象要素の参照番号(tap/type/assert 時)")
    var elementRef: Int?
    var text: String?             // type 時の入力文字列
    @Guide(description: "このアクションを選んだ理由(1文)")
    var rationale: String
}

@Generable
struct ScreenAssertion {
    var kind: AssertionKind       // exists, labelEquals, valueContains, screenMatches
    var elementRef: Int?
    var expected: String
}

@Generable
struct LocatorRepair {           // 自己修復: 壊れたロケータの代替案
    var newLocator: FlowLocator
    var confidence: ConfidenceLevel   // high / medium / low
}

@Generable
struct TriageReport {            // 失敗トリアージ
    var failureClass: FailureClass    // appBug, flakiness, locatorDrift, envIssue
    var summary: String               // 日本語1〜2文
    var suggestedFix: String
}
```

### 5.3 プロファイル(Dynamic Profiles で切替)

| プロファイル | 入力 | 出力 | 備考 |
|---|---|---|---|
| **Explorer** | 目標 + 旅程要約 + 圧縮スナップショット | `NextAction` | 探索とフロー生成の主役 |
| **Verifier** | スクリーンショット画像 + 期待状態の記述 | `Verdict(pass/fail + 理由)` | **マルチモーダル**。視覚的アサーション |
| **Triager** | 失敗ステップ + ツリー差分 + スクリーンショット | `TriageReport` / `LocatorRepair` | 失敗時のみ起動 |

- ツール(`Tool` プロトコル)は補助用途に限定: `InspectElementTool`(ref 指定で
  子要素詳細を取得)など、スナップショット切り詰めで失われた情報のオンデマンド取得。
- **エスケープハッチ**: `LanguageModel` プロトコル経由で PCC(32K)や Claude に
  差し替え可能な設計にしておく(`--model pcc|claude` フラグ)。既定はオンデバイス。
- 起動時に `SystemLanguageModel.default.availability` を確認し、Apple Intelligence
  無効時は明確なエラーメッセージを出す(`ftester doctor` コマンド)。

---

## 6. CLI UX

```
ftester doctor                            # FM 可用性・Xcode・シミュレータ・adb の事前チェック
ftester bridge up|down|status [--platform ios|android] [--device ...] [--serial ...]
                                           # ブリッジ(iOS: 常駐 XCUITest / Android: 常駐 instrumentation)の管理
ftester explore <bundle-id> --goal "ログインして商品を購入できることを確認する" \
    [--project P] [--max-steps N] [--out ...]
                                           # 探索 → Projects/<P>/Scenarios/Generated/*.swift を生成(§10)
ftester run [--project P] [--profile 名] [--scenario id...] \
    [--heal] [--report-dir ...] [--ports 8123,8124] [--skip-build]
                                           # Swift シナリオの決定的実行(プロファイル実行は§11)
ftester project create|list|sync          # テストプロジェクトの作成・一覧・Package.swift 再整合(§11)
ftester profile list                      # 実行プロファイルの一覧と現在マシンでの解決チェック(§11)
ftester machine set|show                  # このマシンの名前(マシンプロファイルの選択キー)の登録・確認
ftester install <パッケージパス>           # .app / .apk のインストール
ftester launch|terminate <bundle-id>      # アプリの起動・終了
ftester snapshot [--json] | tap | type | swipe | press | screenshot
                                           # 手動駆動プリミティブ(圧縮スナップショット・操作。§4.4)
```

実行結果は `ftester report` のような集約コマンドではなく、シナリオ実行毎に
`Projects/<name>/reports/scenario-*.md`(§10)へ自動出力される。CLI/MCP/VSCode 拡張は
いずれも同じ `ftester api ...` 系サブコマンドを経由して呼び出す共通実装(§11.4 参照)。

---

## 7. マイルストーン

| M | 内容 | 完了条件 | 状態 |
|---|---|---|---|
| **M1** | ブリッジ + 手動駆動 | CLI から SampleApp を起動し、curl 相当で tap/type/snapshot/screenshot が通る | 達成済み |
| **M2** | FM 探索 → シナリオ生成 | `ftester explore` が SampleApp のログインフローを自動生成する(当初は YAML、2026-07-08 に Swift DSL へ全面移行。§10) | 達成済み |
| **M3** | 決定的再生 + 自己修復 + トリアージ | id 変更を仕込んだ SampleApp でシナリオが自己修復され、意図的バグで TriageReport が出る | 達成済み |
| **M4** | Android ブリッジ + ドライバ | `AndroidDriver` で FTAgent/FTCore を無変更のまま Android アプリを探索・再生する(実装は自作 instrumentation ブリッジ。UIAutomator2/Appium は不採用。§4.5, §8.7) | 達成済み |

M1〜M4 は全て達成済み。2026-07 には固定 sleep をブリッジ内蔵の a11y 静穏検知に置き換える高速化を実施し、
Android シナリオで約 33%、iOS シナリオで約 27% 所要を短縮した(§8.7.1、詳細は
[パフォーマンスチューニングガイド](performance-tuning.md))。

---

## 8. リスクと対策

| リスク | 対策 |
|---|---|
| Apple Intelligence 未有効 / FM 利用不可 | `ftester doctor` で `availability` を事前診断。`LanguageModel` 差替(PCC/Claude)を用意 |
| 4K コンテキスト超過 | スナップショット圧縮 + 1 ステップ 1 セッション + 応答の構造化。`contextSizeExceeded` 捕捉時は要素数を半減させて再試行 |
| 巨大な画面ツリーで snapshot が遅い | ランナー側でフィルタしてから返す(ホストに生ツリーを送らない) |
| xcodebuild ランナーの不安定さ | `bridge up` にヘルスチェック+自動再起動。`/status` ポーリング |
| Vision 入力の HW 要件(AFM 3 Core Advanced) | ホストは Apple Silicon Mac 前提なので通常問題なし。`doctor` で検査 |
| 3B の判断ミス(探索の迷走) | ステップ上限・同一画面ループ検出をコード側で強制。`giveUp` アクションを用意 |

---

## 8.5 M2実装で得た知見(3Bモデルの実測特性)

SampleApp での反復実験(2026-07-07)で判明した、オンデバイス3Bモデルの特性と対策:

| 実測された弱点 | 採った対策 |
|---|---|
| **数値参照の束縛ミスが頻発**([4]と[5]の取り違え、[1]への固執) | `elementRef: Int` を廃止し `elementText: String`(label/idのテキストコピー)+コード側のスコアリング解決に変更。テキストコピーはLLMの得意技 |
| 「tapしてから入力」の癖で入力欄タップを繰り返す | 入力欄へのtapは実行せず、typeTextの使い方を旅程ログで教示 |
| StaticText/NavigationBar など非対話要素への無意味なタップ | タップ可能型ホワイトリストで実行前拒否+この画面でassert可能なテキスト例を提示 |
| 入力済み欄への再入力(メール欄にパスワード追記) | 未入力欄がちょうど1つなら自動リダイレクト、複数なら候補提示で拒否 |
| greedyサンプリングの縮退ループ(rationale暴走→コンテキスト超過) | `maximumResponseTokens` 制限+リトライは温度サンプリングに切替 |
| greedyは毎回同じ轍を踏む | 進捗なし2回で温度0.9に切替(轍からの脱出) |
| 目標だけでは手順を維持できない(パスワード入力を飛ばす) | 探索開始時に一度だけテスト計画(定型形式)を生成し毎ステップに提示 |
| 最終assertの対象選択に失敗しがち | **サルベージ機構**: 停滞時にゴール文中の「」内文字列を画面と照合し、コード側で検証・記録してフローを完成させる |
| 過去ステップの参照番号を再利用する | 旅程ログは番号でなく要素の実体(型+ラベル)で記録 |
| 効果のなかったタップがフローに残る | 画面変化なし検出時に直前のtapステップを自動巻き戻し |

原則: **「ナビゲーションはモデル、検証と安全はコード」**。ガードレールは拒否するだけでなく、旅程ログで「正しい手」を毎回教えることで次の判断を誘導する。

## 8.6 M3実装で得た知見

- **マルチモーダルAPI**(macOS 27): `Attachment(cgImage)` が `PromptRepresentable` なので
  Promptビルダーに画像を直接混ぜられる。`session.respond(generating:options:) { "説明文"; Attachment(cgImage) }`。
  Package の最低プラットフォームを macOS 27 に上げる必要がある
- **screenMatches(視覚検証)は実用レベル**: 「果物の商品名と価格が並ぶリスト」の一致/不一致を
  スクリーンショットから正しく判定し、不一致時は理由(エラーメッセージの存在)も説明できた
- **アサーションに type+index フォールバックは危険**(実測で偽陽性発生): 別画面の無関係な要素に
  マッチする。再生器は assert 解決時に id/label を持たないフォールバックを除外する
- **自己修復は elementText 方式で安定**: 壊れた `id=login_btn` に対し「サインイン」ボタンを
  high confidence で提案・修復できた。修復フローは `dirty: true` + note に修復理由を残す
- **トリアージは分類の目安を instructions に明記する**: 「エラーメッセージが見える→appBug」等の
  ヒントがないと locatorDrift に誤分類しがち。また縮退ループ対策として要約・修正案は
  文数で強制的に切る(summary 2文、suggestedFix 1文)

## 8.7 M4実装で得た知見(Android)

- **adb 直叩きで十分**: `uiautomator dump`(ツリー)+ `input tap/text/swipe` + `screencap` で
  AppDriver を完全実装できた。UIAutomator2 サーバや Appium は不要(依存ゼロ方針を維持)
- **型語彙を iOS と揃える**: Android クラス名(EditText/TextView/Switch...)を iOS 側の
  型名(TextField/StaticText/Switch...)へマップすることで、FM プロンプト・ガードレール・
  Flow DSL が完全共通化できた。**FTAgent と FTCore は1行も変えずに Android で動いた**
- **リスト行のテキスト昇格**: Android は「クリック可能な無名コンテナ+非クリックのテキスト子」
  構造が支配的。ドライバ側でクリック可能ノードへ子孫テキストを昇格させ、さらに Explorer 側にも
  「テキスト要素→それを包含する最小のタップ可能要素」への幾何リダイレクトを追加(両OS共通の保険)
- **CLI プロセスは短命**: iOS はランナー常駐だが Android ドライバは CLI 内に住むため、
  ref→座標対応表を一時ファイルに永続化して手動駆動コマンドをまたげるようにした
- 既知の制限: `adb input text` は ASCII 中心(日本語はIME経由が必要)。実機は `--serial` 指定
- **クロスパッケージ画面は launchApp の前面判定を壊す**(2026-07-14 実例、以後ブリッジ側で自動復旧):
  Android 16 の設定「セキュリティとプライバシー」は別パッケージ(SafetyCenter/permissioncontroller)の
  画面で、開いたまま残ると force-stop は bundleID しか殺さないため以後の
  `launchApp("com.android.settings")` が「画面が表示されませんでした」で全滅する罠があった。
  `handleLaunch` は前面判定タイムアウト時、前面に居座るパッケージ(bundleID/ブリッジ自身/HOME を
  除く)を force-stop+HOME で掃除して1回だけ再試行するようになり、カスケード全滅はしなくなった
  (事後復旧であり予防ではない。ストール自体は初回1回は起きうる)。手動復旧は
  `adb shell am force-stop com.google.android.permissioncontroller`+HOME のまま残す(フォールバック)。
  検証(2026-07-18、Pixel 9a/Android 16 実機): 設定→「Security & privacy」タップで SafetyCenter を
  settings と同一タスクに積んで launchApp settings すると、v6 は 10s タイムアウトで error・SafetyCenter
  居座り、v7 は同条件で自己復旧して settings 前面化(前面判定タイムアウト→掃除+再試行の before/after 確認済み)

### 8.7.1 更新(2026-07-08): Android もブリッジ化

snapshot の 2 秒(uiautomator dump 自体のコスト)がフロー実行の支配項になったため、
iOS と同型の常駐ブリッジを追加した(`AndroidRunner/`、自作 instrumentation APK)。

- **共通コア部分は iOS ブリッジと同一プロトコル**(§4.5) → ホストは `BridgeClient` を無改修で流用
  (`adb forward tcp:0 tcp:8123` 経由)。AppDriver/FTAgent/FTCore は引き続き無変更
- 純フレームワーク API の Java のみ(androidx/gradle 不要、SDK 付属ツールでビルド、
  prebuilt APK を同梱)。初回操作時に自動インストール・自動起動(`AndroidBridge.swift`)
- 実測: snapshot 2.0s → 8.7ms(中央値)、フロー8本 87s → 38s。日本語 type も
  ACTION_SET_TEXT で IME 不要になった(ADBKeyboard はフォールバック専用に降格)
- adb 直叩き経路は削除せず自動フォールバックとして維持(`FT_ANDROID_NO_BRIDGE=1` で強制)
- 落とし穴: (1) UiAutomation は `am instrument -w` 必須(UiAutomationConnection が am
  プロセス側に住む)→ デバイス内で `&` バックグラウンド化して常駐 (2) a11y 接続は実質1本
  → ブリッジ稼働中は uiautomator dump が Killed される。フォールバック前に必ず force-stop

**2026-07-12追記**: adb 直叩きフォールバック(uiautomator dump/input/screencap、Unicode IME 自動導入)は
削除し、ブリッジ単一実装とした(高速化計画 Phase 1)。あわせて操作毎の冗長な `/status` 事前プローブも廃止し、
接続拒否系エラー時のみ自動再プロビジョン+1回リトライする方式に変更した。

## 8.8 並列実行の実装知見

- **ポート注入**: FT_PORT はビルド時に xctestrun へ焼き込まれるため、並列化は
  「xctestrun のコピーに PropertyListSerialization で FT_PORT を書き換えて注入」で実現
  (ビルド1回で任意台数)。**コピーは必ず元と同じ Build/Products/ に置くこと** —
  `__TESTROOT__` は xctestrun ファイルの場所基準で解決される(別の場所に置くと
  "Missing test product" で起動失敗する。実測済み)
- **コールドブート直後は危険**: 起動直後のシミュレータに並列負荷をかけると
  アクセシビリティ IPC がタイムアウトし(kAXErrorIPCTimeout)、ランナーごと落ちる。
  ウォームアップ(launch+snapshot 1周)後は安定
- **フローは解像度非依存**: ロケータ再生なので iPhone 17 Pro(402pt)で生成したフローが
  Pro Max(440pt)でそのまま通る(実測済み)
- 実測(M1 Max): 3フロー(iOS×2 + Android×1)逐次 55.2秒 → iOS 2ワーカー+Android 1ワーカー並列で
  31.2秒。壁時間は最長フローに漸近する(理想スケーリング)
- **サブプロセス kill と `waitUntilExit()` の reap 競合(1本の詰まりが run 全体を凍結)**:
  `ScenarioHost.run` の watchdog kill で `Process.isRunning` を使うと内部の `waitpid` が子を
  **reap** し、直後の `waitUntilExit()` が終了通知を取りこぼして**永久ハング**する(SIGTERM を
  無視した子で実測: ワーカー全体が `waitUntilExit` で停止)。**生存確認は reap しない `kill(pid, 0)`**
  を使うこと(`process.isRunning` は使わない)。この凍結は 90s watchdog を超えるシナリオでのみ
  顕在化する潜在バグで、hybrid の suspend 誤ルーティング(performance-tuning §6.4)が引き金だった。
- **hybrid の in-app suspend**: system-UI シナリオと in-app シナリオを混在実行すると、背面の
  注入先アプリが iOS に suspend され in-app ブリッジが無応答になる。ドライバ選択は provision 時の
  注入先 bundleID で分岐する(詳細と対策は performance-tuning §6.4「suspend 時のルーティング」)。
- **規模並列(20台級)は timeout flaky を生む**: 競合で画面ロードが遅れ、本来通る `exist` が既定
  タイムアウトを超えて落ちる(実測: 自動入力画面の Switch ロード遅延、Files/連絡先の初回起動、
  Wi-Fi 詳細の描画等が単発で NG)。**規模ランの単発失敗を「シナリオ不良」と即断しない**。切り分けは
  当該シナリオを空き機 1 台で `heal:false` 再実行し、決定的ラベル破綻か flaky かを分ける(20台の失敗
  17件中、実バグは陳腐化ラベル2系統のみで残りは flaky/ロケール/デバイス状態だった。2026-07-16)。
  空き機は fleet(モニター所有)に触れず別途起動: Android は空き AVD を `-port 5590 -no-window` で
  起動→`ft_run_scenario --serial`、iOS は空きシムを boot→一時 machine/run プロファイル
  (`iosInappEngine:false`=xcuitest、fleet と衝突しない空きポートを device.port に明示)→`--profile`。

## 9. 検証方法(E2E)

1. `SampleApp`(ログイン画面 + ホーム画面 + 設定画面の 3 画面 SwiftUI アプリ、
   accessibility identifier 付き)をリポジトリに同梱
2. M1: `ftester bridge up` → `curl localhost:8123/snapshot` で圧縮ツリーが返る
3. M2: `ftester explore com.example.sampleapp --goal "ログインする"` →
   `Projects/<project>/Scenarios/Generated/*.swift` が生成され、人間が読んで妥当
4. M3: SampleApp の identifier を 1 つ改名 → `ftester run --heal` で修復・成功。
   意図的にログインを失敗させるビルド → TriageReport が `appBug` と分類する
5. 性能の検証・回帰比較は `Scripts/bench.swift` の計測基盤で行う。壁時計中央値・
   シナリオ/ステップ内訳・成功率・ホスト CPU/GPU/ANE/MEM を `summary.md` に出力し、
   変更前後を比較する。手順・指標の読み方は
   [パフォーマンスチューニングガイド](performance-tuning.md)を参照

## 10. Swift DSL への全面移行(2026-07-08)

テスト記述を YAML フローから **Shirates 風の Swift DSL** に全面移行した(YAML は廃止、Yams 依存も除去)。
動機: イレギュラー処理(不定ダイアログ等)やデータセットアップを「コード」で書けるようにするため。

### 記述形式

- `@TestClass(app:platform:)` クラス + `@Test` メソッド + `scene(n)`(Shirates の case 相当)
  + `condition/action/expectation`(CAE)の3層構造
- `@Deleted("コメント")` で論理削除(Shirates の @Deleted 相当)。テストクラスまたは
  `@Test` メソッドに付与する。一覧には「削除済み」として残り(GUI は「削除済みを非表示にする」で
  非表示切替可)、全実行・フォルダ実行・クラス名指定の一括実行から除外される。
  完全一致 ID の明示指定でのみ実行可能。コードは残るため復活はアノテーションを外すだけ
- コマンド(tap/type/exist/…)は**同期・非 throw のモジュールレベル自由関数**。
  `try await` も `{ it in }` も不要。カレント実行コンテキストを暗黙参照する
- tap/type/press は `optional:`(見つからなくても失敗にしない)に加え `timeout:`
  (ロケータ解決の再試行待ち上限秒。0=リトライなし。省略時は既定の約0.7秒)を取る。
  出るか不定な optional ステップの空振り短縮用(performance-tuning §5)
- セレクタ式は文字列1本: `#id` / `ラベル` / `.Type[n]`(n は 1 オリジン。1番目は [1] 省略で `.Type`、明記も可)/ `.Type#id` / `.Type=ラベル`、`||` でフォールバック連鎖
- **label マッチは完全一致優先→無ければ部分一致(`contains`)**(`StepExecutor.match`)。短いラベルが
  長いラベルに誤マッチする(`ラベル"許可"` が `"通知を許可"` に当たる)。区別したい要素が同一画面に
  共存するときは `#id` か `.Type=ラベル` で型を絞る。id マッチは常に完全一致
- **短いラベルは別項目の要約(summary)にも contains 一致し「曖昧解決不能」で throw する**:
  例 `"ディスプレイ"` は行 `"ディスプレイとタップ"` と、無関係な `"ユーザー補助"` の要約
  `"ディスプレイ、操作、音声"` の両方に当たる。実 UI の完全ラベルに寄せる(`"ディスプレイとタップ"`)か
  一意な部分文字列にする(2026-07-16 実測)
- **`||英語` フォールバックはデバイスが英語ロケールのときだけ発火する**(実 UI が日本語なら英語候補は
  一切当たらない)。ja-JP フリートでは日本語プライマリが唯一の頼りで、OS 改名で陳腐化すると即ハード失敗する
  (英語ロケール機なら英語 FB で延命するため「たまに緑」に見えて切り分けを誤らせる)。
  プライマリは対象 OS/ロケールの実ラベルに合わせて維持する
- **`exist`/`textIs`/`valueIs` は非スクロール**(現在画面のみ判定)。一覧の折り返し下にある項目は
  直前に `scrollTo(セレクタ, maxSwipes:)` で送ってから確認する

### 実行アーキテクチャ

- `Scenarios/` を SPM の実行ターゲット(ftester-scenarios)としてコンパイル。
  マクロが生成する登録クラス(NSObject 派生)を objc ランタイム走査
  (メッセージ送信なしの class_getSuperclass のみ)で自動発見する
- **1 プロセス = 1 シナリオ実行**のサブプロセス方式。ホスト(CLI/GUI/MCP)は ScenarioHost 経由で
  起動し、NDJSON イベント(FTCore/ScenarioEvent)を受信。ビルドはホスト側で1回だけ
- シナリオ本体は**専用スレッドで同期実行**し、async の StepExecutor/AppDriver へは
  セマフォで橋渡し(FTSync)。ブロックするのは専用スレッドのみで協調プールは塞がない
- 失敗セマンティクス: コマンド NG → 同一 scene 内の以降のコマンドは自動スキップ → 次の scene へ
  (throw を使わない Shirates 的中断)

### 自己修復の再設計(ヒールキャッシュ)

YAML 時代の healedFlow 書き戻しに代わり、解決順を
**プライマリ → フォールバック → キャッシュ(.ftester/heal-cache.json)→ FM ヒール**とした。
キー = シナリオID + file:line + 旧セレクタ文字列。2回目以降は FM なしで決定的に通過し、
ソース位置付きの修正提案をレポートに出し続ける(ソース自動書換はしない。
人がソースを直すとキー不一致でキャッシュは自然に無効化)。

### 実装で得た知見

- **swift-syntax 603 + prebuilts**: マクロ導入によるクリーンビルド増は SwiftPM の
  prebuilt swift-syntax が効き、初回全体で +20 秒程度に収まった(増分ビルドへの影響なし)
- **objc_copyClassList 走査**は Swift の日本語クラス名でも問題なし(String(describing:) で取得)
- **extension マクロのテスト**は MacroSpec(conformances:) を渡さないと protocols が空になり
  「conformance 済み」判定で extension が生成されない(assertMacroExpansion の仕様)
- **`.macro` ターゲットには Package.swift 冒頭の `import CompilerPluginSupport` が必要**
- iOS 27 のパスワード保存シートはタップ時にアニメーション中で座標がずれることがある →
  シナリオ側で `wait(1)` を挟むのが確実(コードで書けるようになった利点)
- 3B FM のヒールは誤要素(NavigationBar 等)を高確信で選ぶことがある。キャッシュは誤ヒールも
  固定化するため、修正提案を人がレビューしてソースを直すループが前提

---

## 11. テストプロジェクトと実行プロファイル(2026-07-08)

シナリオのフラット配置(リポジトリ直下 Scenarios/)と UserDefaults 頼みの実行設定を廃止し、
**テストプロジェクト**(Projects/<name>/)と**組み合わせ型の実行プロファイル**(JSON)に移行した。

### 11.1 テストプロジェクト

`Projects/<name>/` = シナリオ+プロファイル+レポートを持つ器。プロジェクト毎に SPM の
executableTarget `ftester-scenarios-<name>`(path: `Projects/<name>/Scenarios`)が対応する。

- **Package.swift のマーカー区間自動生成**: `// === ftester projects begin/end ===` の区間を
  `ftester project create/sync` が全置換で再生成する(手編集禁止)。書換後に
  `swift package dump-package` で検証し、失敗時は元内容へロールバック(PackageManifestEditor)。
  マニフェスト内容自体が変わるため SwiftPM のマニフェストキャッシュ stale が構造的に起きない
  (Package.swift 内で FileManager 走査して動的生成する案はキャッシュ stale リスクで却下)
- プロジェクト間はビルド隔離される(1 プロジェクトのコンパイルエラーが他を止めない)。
  バイナリ毎に objc 走査が分かれるため、シナリオ一覧のプロジェクト別化は発見ロジック無変更で成立
- プロジェクト名は SPM ターゲット名になるため `^[A-Za-z0-9_][A-Za-z0-9_-]*$`(日本語はクラス名側で使う)
- `--project` 省略時の解決: Projects/ が 1 つならそれ → LocalConfig.defaultProject → 候補一覧付きエラー
- CLI: `ftester project create <name> [--app <bundleID>]` / `project list` / `project sync`
  (手動コピーや git pull 後の Projects/ ↔ マーカー区間の再整合)

### 11.2 プロファイルは 3 種の組み合わせ

`Projects/<name>/profiles/` 配下。共通設定の継承ではなく**部品の参照合成**で表現する。

**アプリケーションプロファイル** `apps/<name>.json` — common(共通)→ ios/android の後勝ちマージ。
`appName` はユーザーがアプリを識別する表示名。パッケージはフラットな `appPath`・`autoInstall`:

```json
{ "common":  { "appName": "サンプルアプリ", "app": "com.example.sampleapp" },
  "ios":     { "appPath": "~/builds/SampleApp.app", "autoInstall": true },
  "android": { "appPath": "builds/app-debug.apk" } }
```

**マシンプロファイル** `machines/<マシン名>.json` — ファイル名がマシン名(`M1 Max(64GB).json` 等)。
1 ファイルに ios / android セクションを書き、そのマシンで使えるデバイスを `name` 付きで列挙。
マシン別ファイルなので UDID / AVD などマシン固有の実体をそのまま書ける:

```json
{ "ios":     { "devices": [ { "name": "メイン機", "simulator": "iPhone 17 Pro", "os": "27.0" } ] },
  "android": { "devices": [ { "name": "エミュ1", "avd": "Pixel_9" },
                            { "name": "エミュ2", "avd": "Pixel 8(Android 14)" } ] } }
```

- デバイス名は 1 ファイル内(ios+android 横断)で一意(重複はロード時エラー)
- iOS: `simulator` 名+`os`(または `udid` 直指定。`port` で固定も可)
- Android: `avd`(AVD の ID と表示名(config.ini の avd.ini.displayname)のどちらでも可。
  起動中エミュレータの AVD 名と照合して adb serial に解決。未起動はヒント付きエラー。
  serial 直指定は廃止 — serial は起動順で変わるためプロファイルに書かない)

**実行プロファイル** `runs/<name>.json` — アプリ+デバイス名リスト+実行時設定。
platform フィールドは持たず、**iOS/Android のデバイス名を混在させれば両OS同時実行**になる:

```json
{ "app": "sampleapp",
  "devices": [ { "name": "メイン機" }, { "name": "サブ機" }, { "name": "エミュ1" } ],
  "heal": false, "reportDir": "reports", "defaultTimeout": 5,
  "wipeDataOnBloat": true, "wipeDataThresholdGB": 8 }
```

`wipeDataOnBloat`(既定 true)は実行開始時に Android AVD の wipe 対象
(userdata/cache/snapshots)合計が `wipeDataThresholdGB`(既定 8。**Play イメージは wipe 直後の
再構築だけで 2〜4GB になるため 4GB 以下はスラッシング**、実測 2026-07-17)超過なら Wipe Data してから
実行する(AndroidDataWiper.swift。ゲストは初期化されるが、アプリは appPath があれば強制
再インストール、ロケールは下記 `locale` が再ブート後に自動適用される)。

`locale`(既定 "ja_JP")は Android エミュレータのブート完了時(device-up と wipe 後の再起動)に
適用される。**Play イメージは root/`setprop`/`settings put system system_locales`/emulator の
`-change-locale` が全て無効**(実測 2026-07-17)のため、適用はブリッジの `POST /locale`
(BridgeRouter.java: shell 権限借用 CHANGE_CONFIGURATION + IActivityManager.
updatePersistentConfiguration、要 `hidden_api_policy=1`=ブリッジ起動時に自動設定)で行う。
一致時は no-op、変更は再起動を跨いで永続。iOS には影響しない。device-up 経由の既定は
DeviceBooter.defaultLocale(実行プロファイルの locale が届くのは wipe 再起動経路のみ)。

### 11.3 解決規則(ProfileResolver)

1. **マシン決定**: `FT_MACHINE` 環境変数 > 登録名(`ftester machine set`、
   `~/.config/ftester/config.json`)> machines/ が 1 ファイルならそれを自動採用 > エラー。
   設定を UserDefaults にしないのは CLI/MCP/VSCode 拡張(内部で `ftester api` を呼ぶ)の
   複数プロセスでドメインを揃えて共有するため
2. **デバイス解決**: 実行プロファイルの各 name を現在マシンのマシンプロファイル(ios→android の順)
   から引く。このマシンに無い name は**スキップ+警告**(実行プロファイルをマシン非依存で使い回すため)。
   1 台も解決できなければエラー。Android は `AndroidDeviceCatalog.resolveSerial` が
   **AVD ID 完全一致**でのみ serial を引き、不一致は throw(代役フォールバック無し)。
   → **profile 外のはぐれエミュレータは profile 実行には一切混入しない**(ワーカー0件)。
   ただし serial 未指定の対話コマンド(`ft_status`/`ft_snapshot` 等)は adb の全デバイスから
   **最若番ポートを既定**にするため、はぐれ高 Android 機があると診断画面がそれになり切り分けを誤らせる。
   規模ランの調査前に `adb -s <serial> emu kill` で掃除する(2026-07-16)
3. **アプリ解決**: common → デバイスの platform セクションの後勝ちマージ。`app`(bundle ID)必須
4. **並列数 = 解決後のデバイス数**(maxParallel は存在しない)。プラットフォーム毎にワーカーを立て、
   RunOrchestrator の platform 別キューで両OS同時並列実行
5. platform 未指定(@TestClass 両対応)のシナリオは iOS ワーカーがいれば ios キューへ
6. 未知キーは警告(タイポ検出)。相対パスはプロジェクトルート基準、チルダ展開あり
7. 合成後は必須検証済みの `ResolvedProfile` になり、実行コードはこれだけを見る

### 11.4 実行フロー(ftester run --project P --profile ios)

1. ProfileResolver で合成 → CLI 明示引数(--heal/--report-dir 等)が最終上書き
2. `ScenarioHost.build(project:)`(ホスト 1 回。入力の BuildFingerprint が前回ビルドと一致すれば
   スキップ=無変更の再実行で no-op build ~2.6s を払わない。performance-tuning §3.2)。
   `ftester api run` の並列実行経路ではワーカー供給(3〜4)をビルドと並行に開始する
3. **デバイス供給**: iOS は BridgeProvisioner がポート範囲(8123〜)を短タイムアウトで並行スキャンし、
   /status のデバイス名 × simctl の UDID 照合で**稼働中ブリッジを再利用**、不足分は空きポートを採番して
   BridgeLauncher(xctestrun FT_PORT 注入)で起動・waitUntilReady。シミュレータの新規作成はしない
   (同名複数の曖昧時は UDID 明記を推奨)。Android は AndroidDeviceCatalog で avd 照合。
   コールド起動は「プランニング(ポート採番、直列)→ 共有ビルド(dylib/xctestrun、直列)→
   起動(デバイス単位で並列。hybrid の 2 ブリッジはデバイス内直列)」(performance-tuning §3.2)
4. **自動インストール**: `appPath` あり+`autoInstall`(既定 true)→ オーケストレータ投入前に
   各ワーカーへ並行 install(差分判定=installedIsCurrent も並列。失敗ワーカーは離脱、
   残ワーカーがキューを引き継ぐ)
5. RunOrchestrator で並列実行。ワーカーラベル=デバイスの論理名。レポートは
   `Projects/<P>/reports/`、ヒールキャッシュは `--project-dir` 経由で `Projects/<P>/.ftester/` に分離
6. `defaultTimeout` はランナーの `--default-timeout` → FTDriveCore に渡り、
   exist/textIs/valueIs の `timeout: Int? = nil` の既定値になる
7. ワーカー構築(供給+インストール)は ProfileWorkerFactory(FTAndroid)に共通化され、
   CLI(ProfileRunner)と `ftester api run`(VSCode 拡張など UI 入口向けの共通経路)が共用する

### 11.5 インターフェース

- CLI: `ftester run [--project P] [--profile 名] [--scenario ...]`(profile 未指定時は従来どおり
  手動 --ports/--serial)、`ftester profile list`(解決結果と整合チェック)、`ftester machine set/show`
- **GUI(SwiftUI 版 `ftester-gui`)は 2026-07-10 に削除**。対話的 UI は VSCode 拡張
  (`vscode-ftester/`)に一本化した。プロジェクト/実行プロファイルの選択はコマンドパレット
  (「ftester: プロジェクトを選択」「ftester: 実行プロファイルを選択」、`ftester.project` /
  `ftester.profile` 設定)、プロファイル JSON の編集・保存時検証は問題パネル(Diagnostics)で行う。
  内部的には CLI と同じ `ftester api ...` サブコマンドを呼ぶため、解決ロジック(ProfileResolver 等)
  は CLI と共通(詳細は [vscode-ftester/README.md](../vscode-ftester/README.md))
- MCP: `ft_list_scenarios` / `ft_run_scenario` に `project` / `profile` 引数、`ft_list_projects` 追加。
  ft_run_scenario は 1 シナリオ実行なので profile からはシナリオの platform に合う先頭デバイス・
  heal・reportDir のみ利用

### 11.6 移行と後方互換

- 旧 `Scenarios/` は `Projects/SampleApp/Scenarios/` へ git mv(同一コミットでアトミック移行。
  レガシーレイアウトのランタイムサポートは持たない)
- ルート `reports/` の既存成果物は履歴として残置。旧 `.ftester/heal-cache.json` も放置で無害
  (キー不一致なら FM が再ヒールするだけ)

---

## 12. デバイスモニターの画面配信と自己修復(2026-07-14)

### 12.1 画面配信は3段フォールバック

**H.264+WebCodecs(既定)→ MJPEG ストリーミング → スクリーンショットポーリング**の順に落ちる。

- **H.264 経路**: helper(`ftester-simstream`=IOSurface→VTCompressionSession HWエンコード /
  `ftester-androidstream`=screenrecord の H.264 をトランスコード無しでパススルー)が
  10バイトヘッダの v2 レコードを stdout へ → 拡張が Uint8Array のまま webview へ転送 →
  `VideoDecoder`(HWデコード)→ canvas。デコードは全チャンク(P フレーム連鎖のため)、
  canvas 描画のみ約 15fps に間引く。ワイヤ形式・ping の契約は
  `Sources/ftester-simstream/main.m`・`ftester-androidstream/main.m`・
  `vscode-ftester/src/deviceStream.ts` の3ファイル同期(詳細はそのコメント)
- **フォールバック**: webview の `codecError`(WebCodecs 非対応/デコード失敗)でデバイス単位に
  MJPEG へ自動復帰(設定 `ftester.streamCodec` で恒久切替も可)。ストリーミング自体の連続失敗は
  従来どおりポーリングへ(`onFailure`)。フォールバック状態はパネル単位のメモリ(開き直しでリセット)
- **monitor のスクショポーリング抑制**: タイルがストリーミング表示中のデバイスは、拡張が
  `suppressFrames`(stdin 制御)で monitor 側の生成ごと止める(受信後の間引きは競合吸収の
  安全弁として残置)。契約は `Sources/ftester/ApiMonitorCommand.swift` 冒頭

### 12.2 ブリッジ死の検知と自己修復

XCUITest ランナーは HTTP サーバだけ死んで xcodebuild 親が残ることがある(2026-07-14 実例)。

- **watchdog**(`vscode-ftester/src/monitorBridgeWatchdog.ts`): 一度 connected になったデバイスが
  booted(実体は起動中・ブリッジ無応答)へ降格して連続5観測(約10秒)続いたら `device-up` を
  自動投入。実行レーン稼働中は保留・クールダウン3分・2回失敗で諦めて表示(`ftester.autoRepairBridge`
  既定 ON)。タイルは「ブリッジ応答なし/ブリッジ再起動中…/復旧失敗」を区別表示
- **残骸掃除**: `BridgeLauncher.startDetached` は起動前に同一ポートの xctestrun
  (`FTesterRunner-<port>.xctestrun`)を掴む旧 xcodebuild を kill する(他ポートはパス不一致で不干渉)

### 12.3 実測(M1 Max、詳細は performance-tuning.md §4.1)

- Android エミュレータは headless(-no-window)だと hw.gpu.mode=auto が SwiftShader(CPU描画)へ
  落ちるため **DeviceBooter は `-gpu host` で起動**(モーション時 qemu 約3コア→約1/3)。
  gfxstream+host Vulkan(MoltenVK)は `-gpu host` の時点で既定有効で、HWUI の Vulkan 化は
  効果なし(§6 不採用表)
- **ただし `-gpu host` が画面凍結(白フレーム固着)の根本原因**(headless + macOS 27 / emulator
  36.5.10。切り分け実測 2026-07-17。performance-tuning.md §7 参照)。swiftshader_indirect は免疫だが
  CPU 約3倍。そこで **基本 host・凍結が軽量修復で治らない個体だけ per-device で swiftshader_indirect
  再起動**にフォールバックする(§12.4 の watchdog ラダー)。`bootOne(gpuMode:)`→`startEmulator`、
  CLI は `ftester api device-up --gpu swiftshader_indirect`。swangle_indirect は screencap 0B で不採用
- H.264 化で webview Renderer 30-65%(瞬時)→ 8.4%(65秒平均)、helper モーション時
  Android 5.2%→1.0%。monitor は suppressFrames で常時 11%→約2%

### 12.4 ゲスト OS 健全性の検知と自己修復(2026-07-16)

adb 接続は生きているがゲスト側が不健全(Wi-Fi 無効・ゲスト時計の凍結)なまま同じシナリオが
落ち続けた実害(フリート起動直後から2時間)への対策。ブリッジ死(12.2)とは検知面が別:
デバイスは connected のままなので、ゲスト OS を直接プローブする。

- **プローブ**(`Sources/FTAndroid/AndroidHealthProbe.swift`): monitor が connected な Android
  エミュレータ(`emulator-*` のみ。実機は Wi-Fi オフが意図的でありうるため対象外)へ 30 秒間隔で
  `cmd wifi status` / `date +%s` / `screencap -p`(PNG サイズで一様フレーム=描画ウェッジを検出。
  a11y は生きたまま画面だけ死ぬ症状で、guest 再起動でのみ回復)を実行。2回連続観測で確定・
  正常1回で即クリア(AndroidHealthDebounce)。確定異常は monitorDevices の
  `health: ["wifi-disabled"|"clock-skew"|"blank-screen"]` で拡張へ伝搬
  (契約は `vscode-ftester/src/monitorModel.ts` 冒頭。拡張は未知の種別も再起動修復に倒す)
- **watchdog**(`vscode-ftester/src/monitorHealthWatchdog.ts`): 異常種別ごとに修復ラダーが分かれる。
  ライフサイクルキュー busy 中は保留(起動/停止処理との競合回避)。テスト実行中は保留しない
  (ユーザー決定 2026-07-17: 凍結は実行完了を待たず即修復。実行中の該当デバイスは再起動で落ちるが
  凍結済みで証跡が撮れないため許容)。設定 `ftester.autoRepairDeviceHealth` は
  **既定 OFF**(autoRepairBridge と異なり、Wi-Fi をわざと切ったテスト環境を勝手に上書きしないため)。
  検出通知(タイルの警告バッジ)は設定 OFF でも出す。
  - **wifi-disabled 単独**: まず `adb shell cmd wifi set-wifi-enabled enabled`(軽量修復、クールダウン 120s)。
  - **blank-screen(画面凍結)**: ストリームヘルパー再起動(`restartStream`。読み出し再開で一時回復。
    クールダウン 120s)→ 効かなければ **CPU 描画へフォールバック**(`forceCpuRender`→`MonitorDeviceOps`
    が個別 device-up に `--gpu swiftshader_indirect` を付与。セッション中維持)→ それでも駄目なら failed。
    **host 再起動は挟まない**(実測で host 再起動は治らず再凍結=無駄。§12.3・performance-tuning.md §7)。
  - **clock-skew 等その他**: down→up の host 再起動(`enqueueRestart`。クールダウン 5分・2回失敗で諦め)。
  - **無限ループ対策**: 「異常なし1回」ではエピソード(試行回数の記憶)を破棄せず、健全が 10 分持続して
    初めて破棄する(ブート直後の一時健全で restartAttempts が毎回リセットされ MAX 到達しなかった実害対策)。
- **証跡の白フレーム無効化**(`BlankFrameDetector`=FTCore、PNG デコードして一様性で判定。サイズ判定と違い
  縮小スクショでも誤検知しない): テスト実行の失敗時証跡スクショ(`FTRuntime.handleFailure`、Android のみ)が
  白フレームなら最大3回撮り直し、それでも白ければ `evidenceBlank` を立ててレポートに警告表示。実行前は
  恒常白のデバイスをワーカーからディスパッチ除外(`ProfileRunner`、短時間の連続 probe でフラップと区別)
- **実行中の凍結による結果取り消し+別デバイス再実行**(`RunOrchestrator.runWorker`。2026-07-17):
  シナリオが失敗した直後にそのワーカーの Android デバイスを `isDeviceFrozen`(注入プローブ=
  `AndroidHealthProbe.isPersistentlyBlank`。FTCore→FTAndroid は循環のため呼び出し側=ftester ターゲットが注入。
  未注入時は常に false)で確認し、凍結していれば `RunRecorder.discardLast` で直前の記録を取り消し、
  `ScenarioQueue.requeue`(上限 `MAX_FREEZE_RETRIES`=1。item を末尾へ戻す)で別ワーカーへ振り直す。
  凍結ワーカーは `.workerFailed` を出してその実行から離脱する(残りの正常機で消化)。上限到達時は
  `recordSkipped`+`failed` として確定。再実行の通知は新イベントを足さず既存の `.step`(synthetic)で行う。
  monitor 側の自動 CPU フォールバック(§12.4)とは別プロセス・別機構(こちらは実行結果の振り直し)
  - **凍結の検知契機は2つ**: (1) **スクショ時の明示シグナル**(即時・確実)= サブプロセスが白フレームを
    確定した瞬間(`StepExecutor` の screenMatches 画面検証、および失敗時証跡の `evidenceBlank` 確定)に
    `FTDriveCore.markDeviceFrozen` が `scenarioAborted` を立ててシナリオを打ち切り、NDJSON イベント
    `deviceFrozen`(文字列 kind。`ScenarioHost.run`/`ScenarioRunnerMain`/`ApiRunCommand`/MCP は無改修で素通し)を
    emit。ホストの `ScenarioRunner.runOne` がこれを検知して戻り値 `ScenarioOutcome.frozen` を返し、事後
    プローブ無しで即振り直す。白フレームの screenMatches は従来 `.skipped`(検証されず継続=結果汚染)だったのを
    この経路に変更。(2) **失敗後の事後プローブ**(上記の `isDeviceFrozen`)= タイムアウト/ハング等で
    `deviceFrozen` を出さずに死んだ凍結を拾う保険。runOne は `.passed`/`.failed`/`.frozen` を返し、
    runWorker は `.frozen` は即・`.failed` はプローブ確認で振り分ける。事後プローブは
    `AndroidHealthProbe.isBlankObserved`(窓内=既定 4×2s に一度でも blank で凍結扱い)を使う —
    `isPersistentlyBlank`(非 blank で即健全)だと約25秒周期のフラッピングの回復側を引いて見逃す
    (実測 2026-07-18。isPersistentlyBlank は実行前の恒常白除外用として存続)
  - **iOS はブリッジ接続不能も振り分け対象**(2026-07-18): ブリッジのウェッジ(シナリオ途中から全ステップ
    「ドライバに接続できません」)は Android のプローブでは拾えず通常失敗になっていた(実測: 1ワーカーで
    2件連鎖)。`.failed` 時に `/status` を2回(2s 間隔)確認し、両方失敗なら「ブリッジ接続不能」として
    同じ discard+requeue+離脱へ。復帰(reviveWorker)は BridgeProvisioner.provision を通るため、
    ウェッジしたブリッジの再供給も試みられる
  - **Android は iOS ブリッジ供給の完了を待たず開始**(`RunOrchestrator.lateWorkers`。2026-07-18):
    run 開始時のワーカー構築は iOS ブリッジ供給(壊れたブリッジの置き換え=数十秒)を含み、従来は
    全ワーカーがその完了待ちだった(実測: 開始→最初のシナリオが 10s→81s に悪化)。対策として
    ProfileWorkerFactory を buildAndroidWorkers(数秒)/buildIOSWorkers(供給込み)に分割し、
    Android を初期ワーカーとして即時開始、iOS は lateWorkers(platforms 宣言+provider)として
    供給完了後に task group へ合流する(group スコープ内の await は既存子タスクを止めない)。
    workersReady はレーン構成の**全置換**(runLaneModel.applyWorkers)のため1回だけ・全ワーカー分を
    宣言する(iOS は供給前でも id="ios:論理名" が確定。detail「ブリッジ供給中...」のプレースホルダ)。
    label→id 変換は WorkerIDMap(NSLock)で iOS 合流時に merge。iOS 供給失敗は run を落とさず
    iOS シナリオのみワーカー不在ドレインで失敗確定(Android の結果は生きる)。CLI(ProfileRunner)も同構成
  - **iOS ブリッジの実行前プレフライトは不採用**(ユーザー決定 2026-07-18): ウェッジ機で
    `scenarioTimeout`(90s)を失うのを実行前の status 確認で回避する試み。①「item を取ってから
    5s×2 判定→振り直し+離脱」は 10台同時の AX スパイク(一過性の遅さ)で9台一斉離脱・freeze-retry
    上限到達の失敗まで発生、②「取る前に 2s 即断・無応答中は取らずに回復待ち(60s)」も負荷時の
    誤判定で品質が安定せず撤去。**ウェッジの検知は失敗後の事後チェック(bridgeUnreachable/
    deviceUnreachable/deviceFrozen → 振り直し)のみで行う**(ウェッジ機の1件は 90s を失うが確実)。
    再提案しないこと
  - **withDeadline は「先着で確定・遅い方を待たない」レースにする**(2026-07-18): 当初 `withTaskGroup`+
    `cancelAll` で実装したが、構造化並行はスコープ終端で全子タスクの完了を待つため、op(ウェッジ機への
    `status`=URLSession)がキャンセルに即応しないと期限側が勝っても遅い方を待ち続け、**run 全体が5分以上
    アイドル固着した実害**(全スレッドパーク・子プロセスもソケットも無いデッドロック)。対策として
    `withCheckedContinuation`+`DeadlineGuard`(継続を一度だけ resume)で、先に終わった方で即確定し op が
    ハングしても放置(URLSession の timeout で自然消滅)する。これで死活確認・プレフライト・warmup が
    確実に期限内で返る
  - **死活確認系の await は必ず短期限**(`RunOrchestrator.withDeadline`。2026-07-18): ウェッジしたブリッジは
    **接続を受けたまま応答しない**ため、BridgeClient の既定 120s/リクエストに任せると status 確認・ウォームアップ・
    復帰 provision が 120s×N 直列に積み重なり、全シナリオ記録済みなのに run が数分〜十数分終わらない
    (実測: 8141/8142 への ESTABLISHED 固着で Test Explorer が 69/75 のまま停止)。対策: 死活確認は
    withDeadline(タスクレース+cancelAll。URLSession await はキャンセルで解ける)で bridgeUnreachable=5s、
    warmup status=10s・snapshot=15s、復帰 provision(ProfileWorkerFactory.buildWorker)=60s に制限
  - **振り直しの監査記録(freezeRetries)**(2026-07-18): 成功した振り直しはシナリオ記録に痕跡を残さない
    (discard 後に別ワーカーの pass で上書き)ため、`RunSummary.freezeRetries` に「シナリオ: 理由
    (元ワーカー、試行 n/1 or 上限到達)」を集約し、run.json の `freezeRetries` に永続化+CLI 末尾に表示
  - **ワーカー・サーキットブレーカ**(2026-07-18): 凍結/消失の個別プローブに当てはまらない不良(ブリッジの
    ウェッジ・ANR 連発等)で死んだワーカーへシナリオを投げ続ける事故を防ぐ一般化。同一ワーカーで通常失敗が
    `WORKER_FAILURE_CIRCUIT_THRESHOLD`(=3)連続したら原因不明でも離脱+現シナリオ振り直し(`.passed` で
    カウンタリセット)。凍結/消失判定はこのブレーカの前段(既知の即離脱)、ブレーカは後段の保険
  - **凍結だけでなく「実行中のデバイス消失」も振り分け対象**(2026-07-18): watchdog の実行中再起動や
    エミュレータのクラッシュで adb からデバイスが消える(`device offline`→`not found`)と、runner の
    固定ワーカーは以降のシナリオを全部即失敗させる(実測: 1台消失で11件連鎖失敗)。これを拾うため
    `.failed` 時に `isDeviceUnreachable`(注入=`AndroidDeviceCatalog.connectedSerials` に serial が居ないか。
    取得失敗時は誤振り分け回避で false)を **凍結プローブより先に**確認し、消失していれば同じ
    discard+requeue+離脱へ流す(理由表示「デバイス消失(offline/未検出)」)。`isDeviceFrozen`/`isDeviceUnreachable`
    の注入は `ProfileRunner`・`ApiRunCommand` の両並列経路で行う
- **劣化ワーカーの可視化**(`RunSummary.degradedWorkers`。2026-07-18): 連鎖失敗が結果 JSON を掘るまで見えなかった
  問題への観測性。RunOrchestrator が離脱(凍結/消失/連続失敗/接続不能)を `DegradedWorkerCollector` で集約し
  `RunSummary.degradedWorkers`(「label: 理由」)に載せる。`RunRecorder.finish` 経由で run.json の `degradedWorkers`
  に永続化(空は nil 省略)し、CLI(ProfileRunner の print / ApiRunCommand の logStderr)にも末尾サマリを出す
- **動的ワーカープール(復帰デバイスの再参加)**(`RunOrchestrator.superviseWorker`。2026-07-18): 従来ワーカー集合は
  実行開始時固定で、離脱したデバイスは監視側が再起動しても同一実行に戻れなかった(構造的限界)。`runWorker` の戻り値を
  `WorkerExit{completed/retired}` にし、離脱時は `superviseWorker` が同じタスクスロット内で `reviveWorker`(注入クロージャ=
  ftester 側が `ProfileWorkerFactory.buildWorker(forLogicalName:)` を `REVIVE_TIMEOUT`=90s・5s 間隔でポーリング+アプリ再導入)を
  呼び、復帰できたら新ワーカーでキュー消化を再開。`MAX_WORKER_REVIVES`=2・`ScenarioQueue.hasItems()` ガードで暴走と
  無駄な再供給を防ぐ。動的タスク追加はせず withTaskGroup 構造は不変(=安全)。FTCore→FTAndroid 循環回避のため
  再供給は注入(既存 isDeviceFrozen 等と同じ)。**注**: 実行開始時の接続失敗も retired 扱いのため、開始時から不在の
  デバイスは最大 MAX_WORKER_REVIVES×REVIVE_TIMEOUT 分ポーリングする(他ワーカーと並行なので run はブロックしない)
- **個別デバイス操作の2台並行**(`monitorModel.ts` スケジューラ化。2026-07-18): 右クリック起動/停止の
  ライフサイクルキューを完全直列から「running(実行中)+jobs(FIFO 待機列)」のスケジューラに変更。
  device ジョブは `DEVICE_LIFECYCLE_MAX_CONCURRENT`(=2)まで同時実行、bulk/restartBatch は単独占有
  (内部で2台並行するため重ねると全体上限2を超える)。追い越しはしない(先頭が開始できない間は後続も
  待つ=投入順保証)。同一デバイス名のジョブは同時に実行しない(enqueueRestart の down→up ペアの逐次性)。
  かつての完全直列の根拠(並行 provision の waitUntilReady 失敗・ゾンビブリッジ)は ProvisionLock が
  供給を直列化する現在は解消済み。down 系の monitor pause は参照カウント化
  (`MonitorDeviceOps.monitorPauseDepth`。0→1 で pause、1→0 で resume)
- **デバイス再起動命令のロバスト化**(`MonitorDeviceOps.runDeviceOpAttempt`。2026-07-18): 再起動(`enqueueRestart`
  の down→up)の **up が失敗するとデバイスが下がったまま放置**され、watchdog も offline を blank-screen として
  拾えず二度と復旧しなかった。対策として up 失敗時は `deviceUpMaxRetries`(=2、`deviceUpRetryDelayMs`=3s 間隔)
  まで再試行してからキューを進める(down は再試行しない)。試行の終端は `settle(failed)` に集約し、
  ジョブ単位の `finishOnce` で `finishLifecycleQueueHead` を1回だけ呼ぶ
- **GPU 再起動と一括起動の単一キュー統合(`devices-up --restart`)**(2026-07-18): 本質要件は
  「操作種別を問わず**同時2台まで**」(2台同時でホスト CPU がほぼ飽和するため)。ジョブを分けると
  ジョブ境界がバリアになり並行枠が遊ぶ(例: CPU 機3台の再起動の端数1台の間、未起動機が待つ)。
  そこで「全て起動」は `devicesUp{restartNames}` 1メッセージ→ bulk up 1ジョブ→
  `ftester api devices-up --restart A --restart B` とし、**DeviceBooter.bootAll の単一キュー**に
  再起動アイテム(先頭。起動済みでもスキップせず shutdownOne→bootOne[host GPU])と通常ブート
  アイテム(restart 対象は除外=同一機の二重処理防止)を混載、既存の2ワーカーが消化する。
  NDJSON に `deviceStopping`(--restart 機の down 開始)を追加(検証: monitorModel.ts
  `isDevicesUpEvent`。受信時にそのデバイスだけ stopDeviceStreams)。cpuRenderNames の解除は
  `MonitorDeviceOps.bulkUpWithRestarts`。右クリック単発「GPUで再起動」は従来どおり
  `restartBatch` ジョブ(`ftester api devices-restart`、`isDevicesRestartEvent`)を使う
- **一括 down の per-device 反映(`api devices-down`)**(2026-07-19): monitor は down 中 pause で
  状態スキャンごと止まる(→タイルが全台落ちてからまとめて「未起動」化していた)。対策として **profile 指定の
  bulk down を NDJSON 化**(`deviceStopping`/`deviceFinished`。停止ロジックは `shutdownProfile` と同一で回帰なし)、
  拡張は `deviceFinished` ごとにそのタイルだけ offline を先行反映(`deviceDownFinished` → resume 後に本物の
  state で上書き)。profile 無しの down は従来の全掃討 `devices down` のまま。詳細は performance-tuning.md §3.4
- **「プロセス」タブ(常駐プロセス一覧・停止)**(2026-07-19): `ps` の ftester 関連常駐を分類表示
  (`residentProcesses.ts`)。Android ブリッジは**エミュレータ内 `am instrument`= ホスト `ps` に出ない**ため
  `adb forward --list` から情報行を合成(ホスト PID 無し→PID 列は `(遅延起動)`/デバイス内 PID `(12345)`)。
  「すべて強制終了」の掃討スコープは**ユーザー決定**で: ① iOS ブリッジ/ランナー・in-app・モニター/
  host-metrics/stream を停止し **iOS シミュレータと Android エミュ本体(qemu)は残す**(デバイスタブの領域。
  `bridge down --all`=sim を残す/`bridge down --platform android`=qemu を残す/残余 SIGKILL は
  **この workspace 由来のみ**=workspaceRoot/binaryDir を含むコマンド。machine-wide 巻き込み回避)、
  ② **MCP サーバ(mcp)は表示・掃討とも対象外**(セッション保護)、③ 掃討後に `restartAll()` で
  monitor/host-metrics を**自動再起動**(止めたままだとデバイスタブが状態更新を失い凍結するため)

- **監視と実行の協調(run-lease)**(2026-07-18): monitor(watchdog)と run は別プロセスで無協調のため、
  watchdog が実行中デバイスに破壊的再起動をかけて run のワーカーを壊していた。対策として run→monitor 方向の
  lease を追加(`Sources/FTBridgeClient/RunLease.swift`=`MonitorLease` と対。`run-<key>.lease`)。`ftester api run`
  (RunOrchestrator)がワーカー担当デバイス(serial/udid)へ 5s ハートビートで write、離脱・完了時に remove
  (FTCore→FTBridgeClient は循環のため `writeRunLease`/`removeRunLease` クロージャ注入。`RunLeaseKeys` actor で
  管理)。`ftester api monitor` が `RunLease.isFresh` を読んでデバイスイベントに `inRun` を載せ、拡張の
  `monitorHealthWatchdog` が **clock-skew 等の host 再起動分岐のみ inRun 中は保留**(restartAttempts/cooldown を
  動かさず見送る)。**blank-screen(CPU フォールバック再起動)と wifi 修復は inRun でも実行**(凍結はデータ汚染で
  即対応が要件、wifi は非破壊)。凍結で run のワーカーが壊れる分は §12.4 の requeue が回復する

## 13. 実行の相乗りガードと launch 事前検査(2026-07-16)

デモ凍結事故(ライブモニター稼働中のシムへ外部 run が相乗り→ launch ハング→ 60s watchdog で
ランナー死→ストリーム凍結)の再発防止として2つのガードを入れた。

### 13.1 MonitorLease(占有ガード、B1)

「このデバイスはモニターが現役で見ている」をプロセス横断で判定するハートビート lease。

- **書き手**: `ftester api monitor` が監視サイクル毎に `.ftester/monitor-<key>.lease` を更新
  (key: iOS=シミュレータ UDID / Android=adb serial。中身=モニター pid、mtime=ハートビート)。
  終了時に削除するが、消し忘れても pid 死亡または mtime 15s 超で自動失効(stale lease 無害化)
- **読み手**: 外部 run(`ft_run_scenario`)のみ。iOS は `BridgeProvisioner.provision(externalRun:force:)`
  内、Android は provision を通らないため MCPServer でインライン判定。fresh lease があれば
  明確なエラーで拒否、`force` で上書き可。内部パス(device-up・プロファイル run)は
  `externalRun=false` 既定で挙動不変(デモ自身の run はモニターと共存する設計のため)
- 実装: `Sources/FTBridgeClient/MonitorLease.swift`(判定3条件: ファイル存在+pid 生存+mtime 15s 以内)

### 13.2 launch 事前検査(LaunchPreflightDriver)

未インストールの bundleID を `XCUIApplication.launch()` すると quiescence 待ちで main queue が
ハングし、60s watchdog でランナーごと死ぬ(XCUITest API はメインスレッド必須のため
サーバ側での非致死化は不可能と確認済み)。

- `launch` 前に `simctl get_app_container <udid> <bundleID>` で導入確認し、未導入は launch を
  呼ばず即時エラーにする(ランナーは生存)。システムアプリも判定可(実測)。確認済み
  bundleID はインスタンス内キャッシュ
- 配線: xcuitest エンジンのシナリオ実行時、`DriverConnection.udid` が届く場合のみ
  `ScenarioRunnerMain` が BridgeClient をラップ。udid 供給元は ProfileWorkerFactory / MCPServer
- 教訓: 当初「2ランナー競合」を凍結の主犯と推定したが、本番構成の通し run で監視中シムに
  第2ランナーが共存しても凍結しないことを確認。主犯は「未導入 app の launch」

## 14. 実行結果のファイルベース DB(2026-07-17)

シナリオ実行結果を git 管理下の `Projects/<name>/results/` に蓄積し、分散チーム(複数マシン・
複数ブランチ)の結果をコミット・マージで合流させる。サーバ DB は使わない。

### 14.1 マージ安全性(設計の核)

**1 run = 1 ディレクトリ、1 シナリオ実行 = 1 ファイルの追加専用レイアウト**。
runID = `<yyyyMMdd-HHmmss(UTC)>Z-<マシン名>-<乱数4hex>` をディレクトリ名にするため、
異なるマシン・異なる実行は必ず別パスに書き、git 上は常に純粋な追加になる
(同一秒・同一マシンの二重起動は乱数 4hex で分離)。JSONL 追記型は同一ファイルへの
複数ブランチ追記で必ず衝突するため不採用。

検証済み(2026-07-17): 2 ブランチで同一シナリオ集合を同時刻に実行→マージで、
コンフリクトゼロ・全 run が合流・`ftester results list` が統合結果を返すことを確認。

- レイアウト: `results/runs/<YYYY-MM>/<runID>/run.json + scenarios/<シナリオID>.json`
  (月別シャーディングで走査範囲を限定。間引きは月ディレクトリごと git rm)
- run.json のみ実行完了時に同一プロセスが 1 回上書き(finishedAt・集計)。finishedAt 欠落=
  未完了 run(クラッシュ検出に利用)。scenarios/ は追加専用(同一 run 内の再実行は `~2` 連番)
- スキーマ詳細・フィールド一覧は `Projects/SampleApp/results/README.md`(データと同居させる)

### 14.2 記録パス

全実行経路(api run 直列/プロファイル/並列、ftester run 直列/並列/ProfileRunner)は
`ScenarioHost.run` に合流するため、レコード生成フックはそこ 1 点
(`ScenarioEvent` 列を `ScenarioRecordBuilder` で畳み込み)。run 単位のメタ(runID・プロファイル・
trigger)は CLI エントリでしか分からないため、`RunRecorder` を CLI エントリで生成して注入する。

- 実装: `Sources/FTCore/RunRecord.swift`(DTO+Builder)/ `RunResultsStore.swift`(I/O・月別走査)/
  `RunRecorder.swift`(発番・NSLock 直列化)。書き込みは全て best-effort(実行を止めない)
- dry-run・debug 実行は記録しない(last-results と同判断)。ftester-scenarios 直叩き・MCP 経路は対象外
- レコード粒度: 成否・所要時間・worker・scene 別合否は常時、ステップ詳細・fixSuggestions・
  errorLogs(インフラ失敗の切り分け用)は失敗時のみ。スクリーンショットは含めない
  (reports/ への相対パス参照のみ。reports/ は gitignore のまま)

### 14.3 分析

- 集計は `Sources/FTCore/RunResultsQuery.swift` の純関数に集約(閾値定数も同ファイル冒頭)。
  CLI(`ftester results list/summary/flaky/trend/devices/slow/insights`)と
  拡張向け `ftester api results`(1 行 JSON)の両方がこれを使う
- ダッシュボード: `vscode-ftester/src/dashboardPanel.ts` + `src/webview/dashboard/`。
  ペイロード契約は `ApiResultsCommand.swift` ⇔ `dashboardModel.ts` で同期
- スキーマ進化: 全ファイルに schemaVersion。フィールド追加は Optional でバージョン据え置き、
  読み側は自分より新しい version をスキップ。既存ファイルの書き換えマイグレーションは
  しない(git 履歴とマージ安全性を壊すため)
- インデックス/キャッシュは未導入(月別プルーニング+全走査で当面十分。遅くなったら
  `.ftester/` 配下に再構築可能キャッシュを足す)
