# foundation-tester 設計書

macOS 27 の Foundation Models framework(オンデバイス 3B モデル)を最大限活用する、
iOS / Android 両対応のアプリ E2E テストツール。iOS を先行実装し、Android は同じ
`AppDriver` 抽象の上に後続実装した(経緯・時系列は §7, §8 参照)。

- 作成日: 2026-07-07 / 最終更新: 2026-07-26
- ステータス: iOS / Android とも実装済み・運用中(GUI 入口は VSCode 拡張に一本化)
- 決定事項: ハイブリッド型 / 自作 XCUITest ブリッジ+自作 Android ブリッジ / シミュレータ優先 / Swift + FoundationModels

---

## 1. 背景と方針

### 1.1 Foundation Models framework(macOS 27 / WWDC 2026)の前提

| 機能 | 内容 | 本ツールでの用途 |
|---|---|---|
| 新オンデバイスモデル (AFM 3) | ロジック・tool calling が大幅改善、Vision(画像入力)対応 | エージェントの頭脳 |
| Guided Generation (`@Generable`) | constrained decoding による型安全な構造化出力。パース失敗が原理的に起きない | 全ての LLM 出力(修復案、レポート) |
| Tool calling (`Tool` プロトコル) | 並列/直列の呼び出しグラフを framework が自動処理 | 画面詳細のオンデマンド取得など補助的に使用 |
| マルチモーダル | 画像+テキスト入力(NSImage/CGImage/CVPixelBuffer/URL) | スクリーンショットの視覚検証・トリアージ |
| Dynamic Profiles | セッション中にモデル・ツール・instructions を切替 | verifier / triager の役割切替 |
| `LanguageModel` プロトコル | オンデバイス / PCC(32K ctx) / Claude / Gemini / MLX を同一 Session API で差替 | 難しい計画立案だけ大型モデルに逃がす保険 |
| 制約: コンテキスト ~4K トークン級 | TN3193 参照。プロンプト+応答で共有 | **設計全体を規定する最重要制約** |
| 制約: ホスト全体で直列化 | 実測でスループットは並列度によらず約1回/秒・レイテンシは並列度に正比例 | 並列実行では FM 呼び出し数が実行時間の下限になる(performance-tuning.md §3.5) |

**可否判定の罠**: `SystemLanguageModel.default.availability` は「端末が対応しているか」しか見ておらず、
モデル資産側の理由で**全呼び出しが失敗していても `.available` を返す**(専用ケース
`.appleIntelligenceNotEnabled` があるのに返さない。2026-07-22 実測)。可否を人へ報告する場所では
実際に1回推論する `FMDoctor.checkLive()` を使う(`ftester doctor` / MCP の `ft_doctor` が採用)。
同期の `FMDoctor.check()` はホットパス用で**可否を保証しない**。

**FM 失敗は握りつぶされる**: occlusion-guard・heal・screenIs はいずれも FM 失敗時に nil を返して
素通りする契約なので、FM が全滅してもテストは緑のまま**機能だけ無効**になる。
`FMHealth`(Sources/FTCore/FMHealth.swift)が呼び出しの回数・レイテンシ・成否を計上し、
実行後に stderr へ警告する。結果 JSON の `fm` にも載る(performance-tuning.md §4.2)。
**これは理論上の話ではない**: 実績値では 6066 呼び出し中 5673 失敗(93.5%)で、
成功を含む run は 582 中 58 しかない。**E2E の「緑」は基本的にツリー一致の緑**であり、
視覚検証を含むとは限らないことを前提に読むこと(切り分け手順は docs/verification.md)。

**全 FM 呼び出しは `FMGate.enter()` を通す**(Sources/FTCore/FMGate.swift)。
①サーキットブレーカ(FM は累積 20〜30 回で死に再起動まで回復しないので、連続 3 回失敗したら
以後呼ばない)②ホスト単位の直列化ロック(FM はホスト全体で直列化される資源)の順に見る。
**新しい FM 呼び出しを足すときは必ずここを通す**(監査点を 1 つに保つのが目的)。
なお**直列化は全滅の防止には効果が無いことが実測で確認済み**(残しているのは p50 が下がるため。
経緯と対照データは docs/verification.md)。

### 1.2 3B モデルに合わせた基本方針: 決定的な再生 + 失敗時のみ FM 介入

小さいモデルに毎ステップ判断させ続ける自律エージェント型は、コンテキスト溢れと
判断ミスが蓄積する。本ツールは **ハイブリッド型** を採る:

1. **実行モード**: 保存済みシナリオ(Swift DSL。§10)を FM なしで決定的に再生。
   高速・安定で CI 向き。
2. **失敗時のみ FM が介入**: ロケータ自己修復、スクリーンショット+ツリー差分の
   トリアージ、自然言語バグレポート生成。

(M2 で計画していた、FM がアプリを自律探索してシナリオを自動生成する explore モード
[`ftester explore` / ExplorerProfile] は廃止済み)

コンテキスト対策の原則:
- アクセシビリティツリーは **圧縮テキスト(set-of-mark 形式)** にして 1 画面ずつ渡す
- セッションは **呼び出し毎に新規作成**し、会話履歴は持ち回らない(§5.1)
- 出力は全て `@Generable` で構造化(自由文を返させない)

---

## 2. 全体アーキテクチャ

```
┌─ macOS ホスト ────────────────────────────────────────────────────┐
│  ftester CLI / MCP サーバ / VSCode 拡張(共通で ftester api を呼ぶ) │
│  ├─ FTAgent        : FoundationModels エージェント層               │
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
│       ├── docs/testbases/        #   テスト設計の元資料(仕様・観点)。シナリオの根拠
│       ├── reports/               #   実行レポート出力先(プロジェクト別)
│       └── .ftester/              #   ヒールキャッシュ等(プロジェクト別)
├── Scripts/bench.swift            # 計測基盤(§9。詳細は docs/performance-tuning.md)
├── E2EApp/                        # 自己 E2E の SUT: Compose Multiplatform(→ Projects/E2E)
│   └── docs/ui-contract.md        #   **全 SUT 共通の画面・#id・ラベル契約(唯一の正)**
├── E2EAppIOS/                     # 自己 E2E の SUT: SwiftUI + 一部 UIKit(→ Projects/E2E-iOS)
├── E2EAppAndroid/                 # 自己 E2E の SUT: View/XML + 一部 Compose(→ Projects/E2E-Android)
├── E2EAppFlutter/                 # 自己 E2E の SUT: Flutter(→ Projects/E2E-Flutter)
│                                  #   各 SUT の docs/ui-contract.md には**型語彙と固有の罠だけ**を置く
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
| `GET  /status` | ランナー生存確認・シミュレータ情報。inapp は `applicationState`(active/inactive/background)も返す(背面 suspend 診断用・追加 optional・旧ブリッジは返さず nil) |
| `POST /session` | `{bundleID}` → `XCUIApplication(bundleIdentifier:).launch()` |
| `GET  /snapshot` | アクセシビリティツリーを圧縮 JSON で返す(4.4) |
| `POST /tap` | `{ref}` または `{x,y}` |
| `POST /type` | `{ref, text}`(tap → typeText) |
| `POST /swipe` | `{direction}` or `{fromRef, direction}` |
| `POST /press` | `{ref, duration}` または `{x, y, duration}` 長押し |
| `GET  /screenshot` | `XCUIScreen.main.screenshot()` → PNG |
| `POST /terminate` | 対象アプリ終了 |

上記9個は共通コア。iOS ブリッジはこれに加え `POST /drag`・`POST /appswitcher`・`POST /home` を
実装(計12)、Android ブリッジは `POST /locale` を追加(計10。§4.5)、InApp ブリッジは
共通コアのみ(計9)。

**in-app dylib は「古いまま注入される」事故が起きやすい**(2026-07-27 に実害):
`InAppBridge/build/` は gitignore・手動ビルドなので、ブリッジのソースを直しても
再ビルドしなければ**古いバイナリが注入され続ける**。実際に isChecked 追加と型の役割正規化
(b8a408c)が反映されず、ios-inapp / ios-heal だけ「checked が取れない」「switch 型が出ない」で
落ち続けた。`InAppLauncher.buildIfNeeded` は**存在ではなく鮮度**(`InAppBridge/Sources/*` +
`build.sh` + 共有 DTO の mtime)で判定する — 存在チェックに戻してはいけない。

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
- **操作直後の整定(xcuitest, 2026-07-21)**: XCUITest の tap quiescence は非同期 push 遷移の
  完了前に返り、かつ直近 snapshot をキャッシュするため、操作直後の素取得は遷移前ツリーを返す
  (実測 50%)。対策として、直前が画面変更操作(tap/type/swipe/drag/press/session/…)だった
  snapshot に限り、取得前に短い待機(実測 350ms で staleness 0/10)を入れて遷移後の fresh ツリーを
  返す(`BridgeRouter.settlePending`)。連続 snapshot(操作を挟まない再取得)は据え置きで課金しない。
  固定待機は XCUITest が非同期遷移完了の event-driven な信号を出さないための妥協(要 private の
  quiescence API を使えば event-driven 化できるが未採用)。inapp エンジンは tap 側の `InAppSettle`
  (アニメ整定をイベント駆動で待つ)が既に遷移を待つため対象外。

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

### 4.6 座標系の契約と Compose の frame 制約(2026-07-21)

**tap/press/swipe の x/y は snapshot が返す frame と同一座標系。** 単位はプラットフォーム依存:

| | snapshot の `screen`/`frame` | tap の x/y | 備考 |
|---|---|---|---|
| iOS | **ポイント(pt)** 例 `402x874` | pt(同一空間) | window 座標。スクショの px でも screen px でもない |
| Android | **デバイスピクセル(px)** 例 `1080x2424` | px(同一空間) | |

利用側は snapshot の frame 値をそのまま tap の x/y に渡せる(変換不要)。スクリーンショットの
ピクセル座標とは別物なので、スクショ実測 px を tap に渡してはいけない。

**iOS の既知の制約(Compose Multiplatform 等の高密度・縦スクロール画面):**
ビューポート外(フォールド下)の要素は、iOS アクセシビリティの慣習でスクロールコンテナ下端バンドに
frame がクランプされ(y が実描画より小さく・高さが膨張して)報告されることがある。原因は Compose が
iOS の a11y 層に出す frame 自体で、**xcuitest / inapp どちらのエンジンでも同じ frame を読む**ため
エンジン切替や座標補正では直らない。実害: クランプされた座標/ref をタップすると、そこに実在する別要素
(または余白)に当たり、目的の要素は発火しない。可視領域内の要素の frame は正確。

回避策(利用側。**唯一確実**):
- 対象を `ft_swipe` で可視領域に入れてから `ft_snapshot` し直してタップする(可視セルの frame は正確)
- 小さすぎる要素(〜17pt)より、可能なら大きい親要素/隣接ラベルを狙う

**採らない対策(2026-07-21 実機検証で否定・device -03)**:
identifier ベースの `XCUIElement.tap()`(scroll-to-visible 期待)は効かない。XCUITest の `isHittable` が
Compose では壊れており、クランプされた画面外セルを `hittable=true`(=画面内)と誤認してスクロールせず
クランプ位置を叩き別セルへ誤遷移する。逆に可視の正確セルは `hittable=false` になり `.tap()` が不規則な
自動スクロールを誘発して外す(座標タップなら当たる可視セルを退行させる)。`.tap()`/`isHittable`/`scroll-to-visible`
はいずれも同じ壊れた frame を信じるため救済不能。座標タップ(現行実装)を維持する。

補足: この frame 破綻とは別に、Compose の合成 a11y 要素は `accessibilityActivate()` が発火しないため、
inapp の ref タップも座標フォールバックに落ち、同じ壊れた frame を踏む(座標非依存の起動経路が無い)。

---

## 5. FM エージェント層(FTAgent)設計

### 5.1 セッション戦略(4K トークン運用)

- **1 呼び出し = 1 セッション**。毎回新しい `LanguageModelSession` を作り、
  会話履歴は持ち回さない。渡すのは instructions(役割定義、~200 トークン)+
  その場で必要な入力(壊れたロケータ・失敗ステップの差分・現在画面の圧縮スナップショット等)のみ
- 応答は必ず `@Generable` 型。自由文を返させないことで応答トークンも節約。

### 5.2 主要な @Generable 型

```swift
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
ftester run [--project P] [--profile 名] [--scenario id...] \
    [--heal] [--report-dir ...] [--ports 8123,8124] [--skip-build]
                                           # Swift シナリオの決定的実行(プロファイル実行は§11)
ftester draft-scenario [--project P] [--testbase 資料.md] [--app ...] [--no-fm] [--dry-run]
                                           # テスト設計資料からシナリオ下書きを生成(§17)
ftester project create|list|sync          # テストプロジェクトの作成・一覧・Package.swift 再整合(§11)
ftester profile list                      # 実行プロファイルの一覧と現在マシンでの解決チェック(§11)
ftester machine set|show                  # このマシンの名前(マシンプロファイルの選択キー)の登録・確認
ftester install <パッケージパス>           # .app / .apk のインストール
ftester launch|terminate <bundle-id>      # アプリの起動・終了
ftester snapshot [--json] | tap | type | swipe | press | screenshot
                                           # 手動駆動プリミティブ(圧縮スナップショット・操作。§4.4)
```

実行結果はシナリオ実行毎に `Projects/<name>/reports/scenario-*.md`(§10)へ自動出力される。
集約・分析は別レイヤの `ftester results list/summary/flaky/trend/devices/slow/insights`(§14)で行う。

- **`bridge up` が起動するのは xcuitest ブリッジ(iOS)/デバイス内サーバ(Android)のみ**(in-app ブリッジを
  起動する経路は無い)。プロセスは常駐し、停止は `bridge down` か `devices down` を要する
- **`run --profile` は終了時にブリッジを停止しない**(常駐を残すのが仕様。次の run が版一致なら再利用する。
  詳細・トラブルシュートは docs/getting-started.md「ブリッジの起動・再利用・停止」)

CLI/MCP/VSCode 拡張はいずれも同じ `ftester api ...` 系サブコマンドを経由して呼び出す共通実装(§11.4 参照)。

---

## 7. マイルストーン

| M | 内容 | 完了条件 | 状態 |
|---|---|---|---|
| **M1** | ブリッジ + 手動駆動 | CLI から SampleApp を起動し、curl 相当で tap/type/snapshot/screenshot が通る | 達成済み |
| **M2** | FM 探索によるシナリオ自動生成(`ftester explore`) | — | 廃止済み(§1.2) |
| **M3** | 決定的再生 + 自己修復 + トリアージ | id 変更を仕込んだ SampleApp でシナリオが自己修復され、意図的バグで TriageReport が出る | 達成済み |
| **M4** | Android ブリッジ + ドライバ | `AndroidDriver` で FTAgent/FTCore を無変更のまま Android アプリのシナリオを再生する(実装は自作 instrumentation ブリッジ。UIAutomator2/Appium は不採用。§4.5, §8.7) | 達成済み |

M1・M3・M4 は達成済み(M2 の FM 探索機能は後に廃止。§1.2)。2026-07 には固定 sleep をブリッジ内蔵の a11y 静穏検知に置き換える高速化を実施し、
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

---

## 8.5 M2(FM 探索)は廃止済み

FM がアプリを自律探索してシナリオを生成する explore モード(`ftester explore` / ExplorerProfile)は
廃止した。3B モデルの迷走対策(数値参照の束縛ミス・greedy サンプリングの縮退ループ・ステップ上限・
サルベージ機構等)を含む実装知見はここでは割愛する。

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
  構造が支配的。ドライバ側でクリック可能ノードへ子孫テキストを昇格させて解決する
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
  ACTION_SET_TEXT で IME 不要(ADBKeyboard は不使用)
- ブリッジ単一実装。adb 直叩き経路(uiautomator dump/input/screencap、Unicode IME 自動導入)は持たない。
  操作毎の `/status` 事前プローブも持たず、接続拒否系エラー時のみ自動再プロビジョン+1回リトライする
- 落とし穴: (1) UiAutomation は `am instrument -w` 必須(UiAutomationConnection が am
  プロセス側に住む)→ デバイス内で `&` バックグラウンド化して常駐 (2) a11y 接続は実質1本
  → ブリッジ稼働中は他の a11y クライアント(uiautomator dump 等)が Killed される

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
- **CLI での `Task.detached` fire-and-forget はプロセス終了と競合する**: 短命 CLI(ftester run 等)で
  副作用(adb reboot 等)を detached Task に逃がすと、直後に throw → プロセス即終了する経路で
  **発行前にプロセスが死ぬ**(まさに副作用が最も必要なエラー経路で消える)。発行が速い外部コマンドは
  同期発行にする(実例: 難治型凍結の guest reboot。ProfileWorkerFactory.excludeOrRepairBlankScreenWorkers)。
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

0. **同梱 SUT + 対になるテストプロジェクト**が ftester 自身の機能別 E2E。DSL のコマンド面
   (セレクタ記法・type・press/swipe・scrollTo・暗黙待ちと timeout・ifCanSelect/optional・
   relaunch・ios{}/android{})を 1 機能 1 シナリオで網羅する。
   ネットワーク依存ゼロ・状態は起動ごとにルート正規化する設計で、フリートのロケール差や
   バックエンド死活に左右されない。`Scripts/e2e.sh` が全 SUT を鮮度判定つきで回す。

   **SUT は UI フレームワークごとに4つ**ある。同じ画面・同じ `#id`・同じラベルを4通りの
   実装で作ってあり、`AppDriver` から上(セレクタ解決・スナップショット圧縮)がフレームワークに
   依存しないことを実証する土台になっている:

   | SUT | 実装 | プロジェクト | 対象 OS | 契約 |
   |---|---|---|---|---|
   | `E2EApp/` | Compose Multiplatform | `Projects/E2E` | ios + android | **`E2EApp/docs/ui-contract.md` が唯一の正** |
   | `E2EAppIOS/` | SwiftUI + 一部 UIKit | `Projects/E2E-iOS` | ios | 差分のみ `E2EAppIOS/docs/ui-contract.md` |
   | `E2EAppAndroid/` | View/XML + 一部 Compose | `Projects/E2E-Android` | android | 差分のみ `E2EAppAndroid/docs/ui-contract.md` |
   | `E2EAppFlutter/` | Flutter | `Projects/E2E-Flutter` | ios + android | 差分のみ `E2EAppFlutter/docs/ui-contract.md` |

   **`#id` とラベルは4 SUT で完全に同一、違うのは「型」と「id を露出させる作法」だけ**という設計。
   実測で採取した型の食い違い(いずれも同じ `#id` を指す):

   | 要素 | CMP(iOS) | CMP(Android) | SwiftUI/UIKit | View/XML | Flutter(iOS) | Flutter(Android) |
   |---|---|---|---|---|---|---|
   | ボタン | `button` | `button` | `button` | `button` | `button` | `button` |
   | スイッチ | `switch` | `switch` | `switch` | `switch` | `switch` | `switch` |
   | テキスト | `staticText` | `staticText` | `staticText` | `staticText` | `staticText` | `staticText` |
   | パスワード欄 | `textField` | `secureTextField` | `secureTextField` | `secureTextField` | `textField` | `textField` |
   | チェックボックス | `button` | `checkBox` | `button` | `checkBox` | `switch` | `checkBox` |
   | リスト行 | `button` | `clickable` | `clickable`(UITableView) | `clickable` | `button` | `button` |

   ボタン・スイッチ・テキストが揃っているのは 2026-07-26 の役割正規化の結果(それ以前は
   CMP(Android)のボタン/スイッチが `cell`[現 `clickable` の旧名]、Flutter(Android)の
   テキストが `other` だった)。**チェックボックスとリスト行は揃わない** — iOS 側の a11y が
   役割を出さないため(下記「型は役割に正規化する」)

   id 露出の作法もフレームワークごとに違う: Compose は `testTagsAsResourceId`(Android のみ・
   ダイアログには再適用が必要)、View 系は `android:id`(**実行時に resource-id を作れないため
   動的リストは `res/values/ids.xml` に静的宣言**)、SwiftUI は `.accessibilityIdentifier`
   (**UIAlertController の title/message には効かない**)、Flutter は `Semantics(identifier:)`
   (**`ensureSemantics()` 必須・`MergeSemantics` で畳む必要あり・Slider に畳むと iOS で
   a11y ツリーが丸ごと空になる**)。詳細は各 SUT の `docs/ui-contract.md`。
1. `SampleApp`(ログイン画面 + ホーム画面 + 設定画面の 3 画面 SwiftUI アプリ、
   accessibility identifier 付き)をリポジトリに同梱
2. M1: `ftester bridge up` → `curl localhost:8123/snapshot` で圧縮ツリーが返る
3. M3: SampleApp の identifier を 1 つ改名 → `ftester run --heal` で修復・成功。
   意図的にログインを失敗させるビルド → TriageReport が `appBug` と分類する
4. 性能の検証・回帰比較は `Scripts/bench.swift` の計測基盤で行う。壁時計中央値・
   シナリオ/ステップ内訳・成功率・ホスト CPU/GPU/MEM を `summary.md` に出力し、
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
- `press(duration:)` は長押し秒数(既定 `FlowStep.defaultPressDuration` = 1 秒)。
  ブリッジの `/press` は当初から duration を受け取っていたが、**ホスト側の `FlowStep` に
  duration が無く StepExecutor が 1.0 固定で呼んでいたため、DSL の引数と拡張のパラメーター編集が
  黙って無効化されていた**(2026-07-27 修正)。既定値と同じときは `FlowStep.duration` を nil の
  ままにする(生成コード・ヒールキャッシュを既定ケースで太らせない)
- **要素の出現待ちは暗黙**: `tap` はロケータ解決を再試行(省略時 約0.7秒)し、
  `exist`/`textIs`/`valueIs` は既定タイムアウト(5秒・`--default-timeout` で上書き)まで
  スナップショットを取り直してポーリング再判定する。遷移後の検証直前に固定 `wait` を足すのは冗長で、
  足りなければ各コマンドの `timeout:` を上げるのが本筋。例外は `ifCanSelect`
  (既定 `waitSeconds:0` で即時 1 回判定。待つなら `waitSeconds:` を渡す)。
  `wait(1)` の出番はセレクタで待てない整定(アニメ中の座標ずれ等・下記知見の iOS シート例)に限る
- **型名は先頭小文字**(`.button` / `.staticText`)。ブリッジは `Button` を送ってくるが
  `ElementInfo.normalizedType` がデコード時に畳むため、スナップショット表示・セレクタ記法・
  生成コード・ヒール提案の綴りが一致する(3ブリッジの wire 形式は不変 = 版上げ不要)。
  先頭大文字で書くと `validationError` が実行前に落とす
- セレクタ式は文字列1本。**フィルタを `&&` で AND 合成**し、`||` で**候補集合の和**をとる
  (2026-07-26 に Shirates(Classic) の記法へ、2026-07-27 に `||` の意味も寄せた。
  優先順位は `&&` > `>>` > `||`)。**要素を1つ選ぶコマンドは和集合の先頭**(節の順 →
  節内のツリー順)を採るので、`#id||ラベル` はヒール連鎖としても従来どおり働く。
  唯一の解釈者は `StepExecutor.unionCandidates` / `resolveDetailed`。
  短縮形と完全形の対応:

  | 短縮形 | 完全形 | 意味 |
  |---|---|---|
  | `ラベル` | `text=ラベル` | **完全一致**(暗黙の部分一致フォールバックは無い) |
  | `*語*` / `語*` / `*語` | `textContains=` / `textStartsWith=` / `textEndsWith=` | 部分一致 |
  | — | `textMatches=^…$` | 正規表現(**部分一致**。全体一致は `^…$`) |
  | `#id` | `id=` | id(完全一致) |
  | `#foo*` / `#*foo*` / `#*foo` | `idStartsWith=` / `idContains=` / `idEndsWith=` | id の部分一致(Shirates 準拠) |
  | — | `idMatches=^…$` | id の正規表現(**部分一致**。全体一致は `^…$`) |
  | `.型` | `type=` | 型(先頭小文字) |
  | `[n]` | `pos=n` | 候補内の順番(1 オリジン) |
  | — | `value=` / `placeholder=` | 値・プレースホルダ(`text`/`id` と同じく `Contains`/`StartsWith`/`EndsWith`/`Matches` が使える) |
  | — | `checked=true\|false` / `enabled=true\|false` | 状態(`checked=false` は「オンでない」= 状態を持たない要素も含む) |
  | `(a\|b)` | `text=(a\|b)` | **フィルタ内 OR**(Shirates 準拠。下記) |
  | `!値` | `属性!=値` | **否定フィルタ**(下記。短縮形は `!保存` / `!#id` / `!.button`) |

  一致方法(`Contains`/`StartsWith`/`EndsWith`/`Matches`)を持つのは `text`/`value`/`placeholder`/`id`
  の4属性のみで、`type`/`pos`/`checked`/`enabled` は完全一致だけ。id の否定も text 系と対称
  (`idContains!=` `!#id` が使える)。
  `.型#id` = `.型&&#id`、`.型[n]` = `.型&&[n]` の短縮形。
  **型名に `=` は使えない**(`=` は text= 等のフィルタ名と先頭エスケープに使う)。`.型=ラベル` と
  書くと `=` 以降が型名の一部として never-match になるため、validationError(typeEqualsError)が
  実行前に `.型&&ラベル` を案内して落とす。
  `[n]` は**型に限らずどの組み合わせにも効く**(`#list >> [3]` / `*行*&&[2]`)。
  絞り込み条件が1つも無い節(`[2]` 単独)はスコープの中でしか書けない
- **型エイリアス**: `.input` = `textField|secureTextField` / `.widget` = OS を跨いで保証される役割型
  (`button` `staticText` `textField` `secureTextField` `switch`)。
  **役割不明の `clickable` は `.widget` に入れない**(容器やリスト行を掴まないため)。
  1つの実型で足りる名前(`.label` → `.staticText` 等)はエイリアスにしない = 語彙を増やさない
- **素の文字列は完全一致だけ**。部分一致を暗黙のフォールバックにすると
  **短いラベルが長いラベルに黙って当たる**(`許可` が `通知を許可` に当たる / 別項目の要約にも
  当たって「曖昧解決不能」で throw)ため、部分一致は `*語*` 等で明示させる。
  解決に失敗し**部分一致なら在る**ときは失敗メッセージが `"*語*" と書くと拾える` を出す
  (`StepExecutor.partialMatchHint`)
- **`名前=値` の生ラベル**(SUT の状態表示 `notify=off` 等)はそのまま書ける。
  既知のフィルタ名と紛らわしい名前(前方一致関係・大小文字違い・6文字以上で1文字違い・
  既知の基底名〈`text` `value` `placeholder` `id` `type` `pos` `checked` `enabled`〉を接頭辞に持ち
  直後が大文字で続く名前〈`idPrefix=` `textFoo=` 等〉)のときだけ
  `validationError` が落とす(`textContans=x` の綴り誤りがラベル扱いで黙って緑になるのを防ぐ)。
  `名前!=値` にも同じ規則を使う(`count!=0` は素のラベル)。
  **既知の残穴**: 小文字で続く未知名(`identifier=5` 等)は生ラベルと区別できず素通りする
- **フィルタ内 OR `(a|b)`**(2026-07-27。Shirates 準拠): トークン単位の文字列置換で
  **パース時に節へ展開する**(`(保存|OK)&&.button` → `保存&&.button || OK&&.button`)。
  `||` が和集合になったのでこの等価が成立し、照合・serialize・ヒールは一切変更が要らない。
  `|` を含まない括弧はラベルの一部(`保存(推奨)`)。
  **相対セレクタの引数では括弧を自分で書く**(`:right((保存|OK))`。`:right(...)` の括弧は
  引数の括弧なので `|` の囲みにならない)。展開数の上限は 32(超えると validationError)。
  **既知の非対応**: `(a|b)&&[2]` は「各節の 2 番目」であって「和集合の 2 番目」ではない
  (Shirates は後者。節ごとに `[n]` を持つ ftester の構造をそのまま使うため)
- **否定フィルタ `属性!=値` と短縮形 `!値`**(2026-07-27): `FlowLocator.not` に
  「属性1つだけのロケータ」を並べ、肯定フィルタで絞ったあとに引く(`StepExecutor.candidates`)。
  一致方法も使える(`textContains!=済`)。**短縮形は Shirates 準拠**で、中身を肯定と同じ経路で
  解釈して `not` に入れるだけ(`!保存` = `text!=保存` / `!#id` / `!.button`)。
  `=` エスケープ(`=!先頭が感嘆符のラベル`)で回避できるので記法の衝突は起きない。
  **否定だけの節は validationError で落とす**(「〇〇以外の全要素」は容器やレイアウトノードまで掴む)。
  **`pos` は否定できない**(完全形 `pos!=n`・短縮形 `![2]` の両方を実行前に落とす。
  候補集合を絞れず黙って無視されるため)。
  **否定は「同じ条件を2回書いている」の重複検査から外す**(`attributeName` が nil を返す)。
  肯定の text と否定を並べるのは正当な使い方で、外さないと `.button&&項目&&!#btn_item_2` が
  構文エラーになる(2026-07-27 に E2E で検出)
- **スコープ `祖先 >> 子孫`**: `#list >> .clickable[2]` は `#list` で解決した要素の**子孫だけ**を
  候補にし、序数もスコープ内で数える(画面クロム・スクロール位置で序数がずれる問題への対処)。多段可。
  子孫判定は「スナップショットは pre-order + 元ツリーの depth」という 3 ブリッジ共通の規約に依存する
  (`StepExecutor.descendants`。中間ノードのフィルタや上限打ち切りは pre-order を崩さないので保たれる)。
  **スコープ付きロケータはアサーションのフォールバック連鎖から除外されない**(id/label 無しの
  type+index でも容器に錨があるため。`FlowLocator.isWeakForAssert`)
- **スコープはプラットフォーム非依存**(4 SUT × iOS/Android 実測・2026-07-26)。成立条件は
  「**アプリが容器を a11y ツリーに公開している**」ことだけで、フレームワークの差ではない
  (`#id` が「アプリが identifier を付けていること」を要求するのと同じ性質の要件)。
  容器の公開方法だけがフレームワークごとに違う:

  | フレームワーク | 容器の公開方法 |
  |---|---|
  | Compose Multiplatform | `LazyColumn` 等に `testTag` |
  | SwiftUI + UIKit | `UITableView` の `accessibilityIdentifier` |
  | View/XML | `RecyclerView` の `android:id` |
  | Flutter | `Semantics(container: true, explicitChildNodes: true)`。**`MergeSemantics` で包まない** |

  **畳むと子孫が消えてスコープ対象が無くなる**のが唯一の落とし穴(Flutter の `MergeSemantics`、
  Compose の Box+重ね置き `#pad_swipe` は iOS で子 Text が同 depth に平坦化される)。
  当初「Flutter では使えない」と判断したが、SUT が `MergeSemantics` で畳んでいただけで、
  容器を非マージで公開したら iOS/Android とも入れ子になった(=**フレームワークの制約ではない**)。
  回帰は 4 SUT 共通の `#list_rows >> …`(`Projects/E2E/Scenarios/11_*.swift`・
  `Projects/E2E-*/Scenarios/12_セレクタ拡張.swift`)。
  `notExist` / `countIs` も 4 フレームワーク全てで同一に動く(同実測)
- **相対セレクタ `基準:rightSwitch`**(`right` / `left` / `above` / `below` × 型別接尾辞
  `Button` / `Input` / `Label` / `Image` / `Switch` / `Widget`。Shirates 準拠で**基準が先**):
  基準から見て指定方向にある候補だけに絞る。**id が付いていないアプリで「〇〇の右のスイッチ」を
  指すための主力記法**(id があるなら `#id` が常に優先)。
  - 引数は3形。`通知:rightSwitch` = 型別 / `数量:right(2)` = 近い順の2番目 /
    `#a:below(.button&&項目)` = 任意のフィルタ式(`||` は和集合 = **全節の候補を合わせてから方向で並べ**、
    最も近い1つを採る。`:right(.button||.switch)` は「両者のうち最も近い方」)
  - **基準は `<...>` で囲める**(Shirates の正典形 `<text1>:rightButton`。囲みは構文糖でパース結果は
    囲まない形と同一で、serialize は付けない)。`<` 始まりの節は括弧形式の予約なので、読めない形は
    生ラベルに落とさず検証エラーにする(`<` で始まる生ラベルは `=` エスケープ)。
    スコープは括弧の外(`#row >> <数量>:rightButton`)
  - 接尾辞なしの `:right` の既定フィルタは `.widget`(役割が確定した要素だけ = 容器を掴まない)
  - **連鎖できる**(`見出し:right:belowButton`)。各ステップの結果が次の基準になる
  - 判定規則は3条件のみで調整値を持たない(`StepExecutor.directionalCandidates` が唯一の解釈者):
    ①候補の中心が基準 frame をその軸方向へ伸ばした帯に入る ②候補の中心が基準の中心よりその方向に
    ある ③満たすものを方向軸の中心間距離の昇順に並べ、序数(既定 1)番目を採る(同距離はツリー順)
  - **条件を満たす候補が無ければ解決失敗**(「最も近いものを必ず返す」ことはしない。
    レイアウトが変わったときに黙って別要素を掴むため)。基準自身は候補から除く
  - **スコープは節の中の基準にも対象にも効く**(`#row >> 数量:rightButton` は容器の中だけで解決する)
  - 画面外要素は frame が丸められる環境があるため**可視要素にのみ**有効
- **構文検証 `FTSelector.validationError`**: パースは失敗しない契約のままなので、
  `:rigth(x)` のような綴り誤り・他ツール記法(`:near` `:parent` 等)・
  既知フィルタ名と紛らわしい未知のフィルタ名(`textContans=` 等。判定規則は前述の「生ラベル」項)・
  型名の `=`・`[abc]` `[0]` の序数・括弧の不整合・条件が空の節は
  **別経路で検出して落とす**。放置すると誤記が label 扱いになり、`notExist` / `countIs(x, 0)` が
  **必ず成功**する(黙って緑になる唯一の経路)。呼ぶのは `FTRuntime.perform`
  (dry-run でもデバイスに触る前に判定)と `ifCanSelect`(perform を通らないため個別に)。
  **既知の残穴**: 括弧を伴わない綴り誤り(`基準:rigthSwitch`)は
  方向名との前方一致・大小文字違いに当たらないと検出できない
- `||` と `>>` と `&&` の分割は**括弧の外だけ**(`:right(...)` の中は割らない)。
  結合の強さは `&&` > `>>` > `||`。ラベルに `>>` `&&` `:right` `*` を含めるときは `=` エスケープ
  (`=A >> B`)。パースは失敗しない契約は不変
- **木構造セレクタ(`:parent` / `:child` / `:sibling` 等)は実装しない**(2026-07-26 決定)。
  `祖先 >> 子孫` のスコープでほぼ代替でき、語彙を増やすと生成側の誤用が増えるため。再提案しない
- **フローベース相対セレクタ(Shirates の `:flow` / `:input` / `:label` / `:inner` / `:vflow`)は
  実装しない**(2026-07-26 決定・再提案しない)。「ウィジェットを垂直位置でグループ分けし各行を
  左→右に走査」する規則は、**同じ行とみなす閾値という根拠の無い調整値**を1つ要求する
  (中心 y の差 20pt か 10pt かで掴む要素が変わり、iOS/Android の frame の 2〜3pt 差でも割れる)。
  相対セレクタが調整値ゼロなのは帯を**基準自身の frame** から取っているからで、この性質を壊さない。
  ツリー順(pre-order)で定義すれば調整値は不要だが、ツリーの形はフレームワークごとに違うので
  「見た目の次の入力欄」と食い違う。**方向セレクタで取れなかった実例が出てから**再検討する
- **一致品質(exact/substring)は記法ではなく掴んだ要素で決まる**(`StepExecutor.quality`)。
  `*ログイン*` が `"ログインに失敗しました"` を掴めば substring、`"ログイン"` を掴めば exact。
  読み手は**hybrid の tap アクションだけ**で、primary が substring 止まりなら fallback を照会し
  fallback の exact を優先する(§performance-tuning「フォールバック検証の偽陽性」)
- **inapp の tap は activate 不発時に「整定待ち→要素取り直し→再 activate」で粘る**(2026-07-27)。
  Compose iOS は**画面遷移直後、要素が AX ツリーに載っていても accessibilityActivate がまだ
  配線されておらず false を返す**ことがあり、その瞬間の合成タッチも無反応(成否検知不能)で
  タップが黙って空振りする(実測: sut-ec-mobile お気に入り一覧→詳細で 2/15 失敗)。
  `InAppBridge.tapByRef` が InAppSettle(イベント駆動・cap 800ms)で遷移の整定を待ってから
  ツリーを取り直して再 activate し(+250ms でもう1回)、それでも不発なら従来どおり合成タッチへ。
  待ちはメインをブロックしない(asyncAfter)ので遷移自体は進む。**再試行は activate false の
  ときだけ**発生し通常経路のコストはゼロ。恒常的に activate false の要素(合成タッチで動くもの)は
  最大 ~1s 遅くなるが正しさ優先。レポート注記「要素を取り直して再実行」で観測できる。
  修正後: シナリオ×15 + フルスイート×3 で失敗ゼロ・救済発火4回
- **inapp の type は Compose Multiplatform でも通る**(2026-07-21 更新。それ以前は XCUITest 切替が
  必要だった)。Compose は「フォーカスアンカーの OverlayInputView(入力セレクタ非応答)」と
  「実際のキーボード受け口 IntermediateTextInputUIView(UIKeyInput 準拠・isFirstResponder)」が
  **別ウィンドウの別ビュー**のため、first responder を1つ捕まえるだけでは前者を拾って 409 になる。
  現実装(InAppInput.m)は「insertText: に応答し かつ isFirstResponder のビュー」を全ウィンドウから
  探して最優先で挿入する(実測 253〜358ms。XCUITest attach 経路 1.0〜1.3s の約1/4)。
  - `preferTypeDriver`(Compose 検出時に最初から attach)は廃止(常に false)。
    `/status` の `uiFramework` 申告は情報として残存
  - 安全網: inapp type が 409 なら `typeDriver`(`AppAttachDriver`)でリアクティブ切替
    (`StepOutcome.driverFallback` に記録。**ロケータの `passedViaFallback` とは別物**で、
    セレクタ更新の提案は出さない=セレクタは正しくドライバが変わっただけ)。
    409 メッセージには first responder 診断が付く
  `AppAttachDriver` は XCUITest ブリッジへ `/session {activate:true}`(実行中アプリを再起動せず
  状態保持で attach)→ snapshot → type(ref は typeDriver 側 snapshot で取り直す。ref 名前空間は
  ブリッジごとに独立)。**springboard 参照の SystemUIDriver(fallbackDriver)はアプリ要素を一切
  見られないため type の受け皿にできない**(実測: snapshot は SBSwitcherWindow 等8要素のみ)。
  用途を混ぜないこと。engine=inapp 単独(xcuiPort 無し)ではこの経路は無く、409 メッセージが
  xcuitest プロファイルへ誘導する
- **`type` の `\n` は iOS では XCUITest 経路へ回す**(2026-07-28。`StepExecutor` の type 2経路):
  `typeText` は改行を **Return キー押下**として発火するので **iOS 既定の挙動そのもの**になり、
  「改行を入れるか確定アクションを撃つか」をフィールドが決める。in-app の `insertText` は改行の解釈が
  フレームワーク任せで OS 既定と揃わない(Compose は完全一致 `"\n"` だけアクション化、Flutter は握り潰す)。
  **`\n` を含まない入力は両経路で結果が同じ**なので、この振り分けは**エンジン間の観測可能な差を生まない**
  (エンジンはツール内部の最適化であり、シナリオから見えてはいけない)。判定は `typeDriver` の有無だけで
  行い、プラットフォーム判定は書かない(`typeDriver` は iOS hybrid でしか設定されないため自動的に
  iOS 限定。条件を二重に持つと将来ずれる)。**ロケータ無しの `type`** も同じ規則で回るが、ref が無く
  attach 前だと 409 になるため `AppAttachDriver.type(ref: nil)` に activate 再試行を入れてある
  (ref 有りには入れない — activate が refFrames をクリアする)
- **iOS の Enter はフレームワークごとに受け口が違う**(2026-07-28 実測。吸収は
  `FTPressEnterOnComposeFirstResponder` の1箇所): Compose は `insertText("\n")` が IME アクションに
  変換される。**UITextField は変換されない**ので UIKit が Return で行うこと自体を再現する
  (`textFieldShouldReturn:` + `EditingDidEndOnExit`。SwiftUI の `onSubmit` もこの経路)。
  UITextView は Return = 改行挿入なのでそのまま `insertText("\n")`。
  **`type` の末尾改行もこの関数を通す**(「type の末尾改行 = pressEnter」が契約なので分岐を割らない)。
  **Flutter は engine の私有 API へアクションを配送する**: `insertText("\n")` は engine に
  握り潰され(文字も入らずアクションも出ないのに 200 が返る最悪の形)、hybrid の xcuitest
  フォールバックも **in-app の合成タッチが立てたフォーカスに届かない**ため、in-app で完結させるしかない。
  `[view textInputDelegate]` → `flutterTextInputView:performAction:withClient:` を
  `returnKeyType`(UIKit の公開 enum)からの逆写像で呼ぶ。**私有 API なので各段で存在確認し、
  欠けたら 409 に縮退する**(E2EAppFlutter/docs/ui-contract.md。退行の検知はシナリオ 18 が唯一)
- **Android の Enter はキーイベントでは届かない**(2026-07-28 実測): ソフトキーボードが出ていると
  `input keyevent 66`(gRPC の名前付き "Enter" も同じ)は **View/XML の `EditText` に到達しない**
  (IME が消費する)。`adb shell ime disable <id>` で IME を止めると同じキーで発火する。
  **Compose の入力欄は同条件でも発火する**ため、Compose だけで検証すると気付けない。
  そこで `pressEnter`(と `type` の末尾改行)は **a11y の `ACTION_IME_ENTER`**(ブリッジの
  `/pressEnter` → `InputInjector.pressImeEnter`)を既定にし、404/409/501 のときだけキーイベントへ
  落とす。Shirates も Android は `mobile: performEditorAction` = エディタアクション直実行で、機構は同じ。
  受け側に届く actionId が経路で違う(a11y = フィールドの imeOptions / キーイベント = `IME_NULL`)ので、
  SUT 側は**両方受理**する必要がある(E2EAppAndroid/docs/ui-contract.md)
- **短いラベルは別項目の要約(summary)にも contains 一致し「曖昧解決不能」で throw する**:
  例 `"ディスプレイ"` は行 `"ディスプレイとタップ"` と、無関係な `"ユーザー補助"` の要約
  `"ディスプレイ、操作、音声"` の両方に当たる。実 UI の完全ラベルに寄せる(`"ディスプレイとタップ"`)か
  一意な部分文字列にする(2026-07-16 実測)
- **`||英語` フォールバックはデバイスが英語ロケールのときだけ発火する**(実 UI が日本語なら英語候補は
  一切当たらない)。ja-JP フリートでは日本語プライマリが唯一の頼りで、OS 改名で陳腐化すると即ハード失敗する
  (英語ロケール機なら英語 FB で延命するため「たまに緑」に見えて切り分けを誤らせる)。
  プライマリは対象 OS/ロケールの実ラベルに合わせて維持する
- **既定は非スクロール**(現在画面のみ判定)。一覧の折り返し下にある項目は
  `tap`/`exist` の `scroll:` 引数(または `withScrollDown { }`)で探索するか、
  直前に `scrollTo(セレクタ, maxSwipes:)` で送ってから確認する。
  テキスト検証(`textIs` 等)は探索手段を持たない(次項)
- **テキスト検証コマンド(`textIs` / `valueIs` / `textContains` / `textMatches` /
  `textStartsWith` / `textEndsWith` / `textIsNot` / `textIsEmpty` / `textIsNotEmpty`)に
  `scroll:` を足さない**(ユーザー決定 2026-07-27)。これらは**静止した画面のテキストを詳細に
  検証する**ためのもので、条件を満たすまで自動でスクロールする挙動は**望まれていない**。
  `exist` と `tap` が `scroll:` を持つのは「在るか」を探す・操作するコマンドだから。
  一貫性を理由に対称化しないこと(**再提案しない**)

### Shirates(Classic) 準拠の方針と承認済みの差分(2026-07-27)

**コマンド名・引数名・既定値・挙動は Shirates(Classic) をそのまま踏襲する**。独自の「改良」を
しない — 差分を作るときは実装前にユーザーへ提示して判断を仰ぐ(経緯: 独自アレンジを重ねて
指摘を受けた)。迷ったら `~/github/wave1008/shirates-core` のソースを読んでから書く。
以下は**提示済み・承認済みの差分**の全リスト(これ以外の挙動差は準拠漏れ = バグとして扱う):

| 差分 | 理由 |
|---|---|
| `FTScrollDirection` に `None` が無い | 「スクロールしない」は引数の省略(Optional)が担う |
| スクロールに scrollFrame・マージン・時間指定が無い | ブリッジのスワイプが全画面固定のため |
| `(a\|b)&&[2]` は「各節の2番目」(Shirates は和集合の2番目) | 節ごとに `[n]` を持つ ftester の構造をそのまま使う |
| `!` 短縮形で序数を否定できない(`![2]`) | 候補集合を絞れず黙って無視されるため実行前エラーにする |
| テキスト検証(`textIs` 等)に `scroll:` が無い | ユーザー決定(上記「再提案しない」項) |
| `thisIs` 系が素の値にも直接生える(`FTValue` 転送) | Swift は非 Optional に `Any?` 拡張が生えない(言語制約の吸収であり挙動差ではない) |
| 相対セレクタの引数の `(a\|b)` は括弧を自分で書く | `:right(...)` の括弧が引数の括弧で `\|` の囲みにならないため |
| フローベース相対セレクタ(`:flow` 等)を持たない | 根拠の無い調整値を要求する(上記 2026-07-26 決定・再提案しない) |
| `pressEnter` の iOS 実装がソフトキー tap ではなく `typeText("\n")`(xcuitest)/`insertText("\n")`(inapp) | キーボード要素をスナップショットから除外しているため tap できない。観測できる挙動(Return キー相当)は同等 |

### 型付きセレクタ(Sel。2026-07-27)

セレクタ式は文字列1本なので、綴り誤りをコンパイラが捕まえられない(実行前の `validationError` が
唯一の防波堤)。これを型で潰す**併設経路**として `Sel`(Sources/FTDSL/Sel.swift)を追加した。
**文字列版は一切変えていない**(署名・ステップ説明文・記録すべて同じ)。

```swift
tap(.id("login_btn"))                            // #login_btn
tap(.id("login_btn").or(.text("ログイン")))        // #login_btn||ログイン
tap(.id("list").find(.type(.cell).nth(2)))       // #list >> .cell[2]
tap(.text("通知").right(.switch))                 // 通知:rightSwitch
textIs(.id("txt_result"), "dialog=none")
```

- **引数の型が具体型なので先頭ドットで書ける**(`tap(.id(...))`)。`some FTSelectorConvertible`
  のような総称にすると leading-dot が効かなくなるため、各コマンドは String 版と `Sel` 版の
  **2 つの具体オーバーロード**を持ち、共通の impl(FTSelector を取る)へ畳む
- 組み立てるのは**文字列版と同じ `FlowLocator`**。解決・実行・レポート・ヒールは完全に共通で、
  実行エンジンは分岐しない(`SelTests` が全構文について「文字列版と同じ FlowLocator になること」を固定)
- フィルタ系メソッド(`text`/`type`/`nth` 等)は常に「**現在の対象**」に AND する:
  相対ステップより前なら基準(アンカー)、後ならそのステップの対象。`nth` も同様に、
  相対ステップの後では ordinal(近い順)になる
- `exact` は match モードを**持たせない**(文字列版 `parseNamedFilter` と同じ正規化)。
  揃えないと同じ意味のセレクタが型付き版だけ別構造になり、比較・往復・ヒールキャッシュが割れる
- 表示テキスト(レポート・ヒールキャッシュのキー)は `FTSelector.serialize` で**記法へ戻す**。
  `FlowLocator.summary` は表示用で型が `.button` ではなく `button`(=ラベル)に化けるため使わない
- 型付き経路は `FTSelector.structured` が立ち、実行時の構文検証を**通さない**
  (綴りはコンパイラが保証済み。かつラベルに `>>` 等の予約文字が入っても再パースで別物にならない)
- 型名は `SelType` の静的メンバ(OS 共通契約の5型 + エイリアス + 頻出型)。語彙に無いものは
  `.custom("...")`(先頭小文字へ正規化)

### 否定・状態・個数のアサーション(2026-07-26)

- **`notExist`** は「消えるまで待つ」。初回で不在なら即成功、在ればタイムアウトまで消滅を待つ
  (`exist` の poll と対称)。可視性(occlusion)は見ない — ツリーから消えたことが唯一の判定。
  hybrid では **不在を確定する側でだけ** `fallbackDriver` を1回照会する(pass 経路の固定費 1 回。
  システム UI のダイアログが primary の snapshot に映らないため。miss 毎に払う `exist` 側とは事情が逆)
- **`isChecked` / `isNotChecked`**(セレクタの `checked=` も同じ源)は `ElementInfo.checked` を見る。
  取得元は **iOS = accessibility の selected trait**(`XCUIElementSnapshot.isSelected` / in-app は
  `UIAccessibilityTraits.selected`)、**Android = `AccessibilityNodeInfo.isChecked`**。
  Compose iOS は Switch の `value` を出さない(実測)ので selected trait が唯一の経路。
  **true のときだけ送る**(省略 = オフ、または状態を持たない要素)。
  **iOS 側は UI 実装依存**(2026-07-26 の 4 SUT 実測): Compose は selected trait を出すので取れるが、
  **SwiftUI/UIKit と Flutter の checkbox は出さない** → `checked` が nil のままで
  `isChecked` / `checked=true` が当たらない。**Android 側は 4 SUT とも取れる**。
  iOS も含めて確実に見たいならアプリ側の echo Text を `textIs` で見る
- **状態フィルタ(`checked=` / `enabled=`)は型ではなく `#id` と併用する**(2026-07-26 実測)。
  同じ役割の要素でも型は SUT で割れるため(コントロール画面の無効ボタンは CMP では `button`、
  View/XML では `clickable`)、`.button&&enabled=false` のような型との AND は SUT 固有の式になる。
  `#btn_always_disabled&&enabled=false` なら 4 SUT 共通で通る
- **`isEnabled` / `isDisabled`** は `ElementInfo.enabled`(3 ブリッジとも埋めている)を見る。
  タイムアウトまで状態変化を待つ。「見つからない」と「状態が違う」を別メッセージで返す
- **`countIs`** は**ツリー上の**候補の個数。**可視性は見ない**(覆われた要素も折り返しの下の
  要素も1件に数える)。`exist` が(偽陽性検証を有効にした run で)可視性まで確認するのと
  **意図的に違う**: 件数ぶん FM を
  直列で呼ぶことになり(ホスト全体で約1回/秒)、リスト検証が実用的な速度でなくなるため。
  `requireVisible` 引数も持たせない。`||` は**候補集合の和**を数える(同じ要素が複数の節に
  マッチしても1度だけ)。スコープと併用してリスト件数を数えるのが主用途。
  **失敗時は節ごとの内訳を出す**(`実際 4(内訳: text=許可 2件 / text=別名 2件)`)。
  総数だけだと「どの節が想定より多く拾ったのか」が分からず、直すのに snapshot の取り直しが要る。
  重複は先に現れた節に数えるので**内訳の合計は必ず表示件数と一致する**(`StepExecutor.unionByClause`)。
  **親子で同じ条件に当たっているとき**(ボタンとその内側の Text)は、直し方まで添える
  (`型で絞ると 3 件(例 .button&&…)`)。フレームワーク一般の性質で利用者は必ず一度は踏むが、
  メッセージが無いと `countIs("項目", 3)` が 6 を返す理由に辿り着けない(`StepExecutor.nestingHint`)
- **失敗メッセージのロケータ表示は節を `||` で連ねる**(`FlowStep.locatorSummary`)。
  以前は他の節を `(fallback: …)` と呼んでいたが、`||` が和集合になった今は
  「片方だけ使われる」という誤った期待を与えるため用語ごと直した(2026-07-27)

### 部分一致・正規表現・反復(2026-07-26)

- **`textContains` / `textMatches` / `textStartsWith` / `textEndsWith`** は `textIs` と同じ経路
  (可視性ガードつき)。`textMatches` は**部分一致の正規表現**(全体一致は `^...$`)。
  occlusion-guard には**実際に一致した部分文字列**を渡す(パターン文字列は画面に出ないため。
  `StepExecutor.matchedText` が唯一の判定者)
- **否定・`value` 側の全対称**(2026-07-27。Shirates 準拠): `text*` の各モードに `*Not` を、
  さらに `text*` の全てに `value*` を対で持つ(`textIsNot` `textContainsNot` `textStartsWithNot`
  `textEndsWithNot` `textMatchesNot` `textIsEmpty` `textIsNotEmpty` `textMatchesDateFormat` と、
  同名の `value…` 一式)。判定は `StepExecutor.negativeAssertSatisfied` に**1箇所だけ**置く。
  要素は在る前提でタイムアウトまで**値の変化を待つ**。
  **否定系と Empty 系は可視性(occlusion)を見ない** — 「見えていないこと」「空であること」は
  画面照合できないため(`requireVisible` 引数も持たせない)。「見つからない」と「条件不成立」は
  別メッセージ。`*MatchesDateFormat` は `DateFormatter`(`en_US_POSIX` 固定)で解釈できるかを見る
- **`thisIs` 系**(`ValueAssertions.swift`。`Optional where Wrapped == Any` の拡張):
  **デバイスに触れない**値の検証(API 応答・計算結果)。`thisIs/thisIsNot/thisIsTrue/thisIsFalse/
  thisIsEmpty/thisIsNotEmpty/thisIsBlank/thisIsNotBlank/thisContains(Not)/thisStartsWith(Not)/
  thisEndsWith(Not)/thisMatches(Not)/thisMatchesDateFormat/thisIsGreaterThan(OrEqual)/
  thisIsLessThan(OrEqual)`。1件=1ステップとして記録し、失敗は DSL コマンドと同じくシナリオを中断する
  (`FTDriveCore.handleFailure` を通す)。`FTElement.idIs` も同じ意味で「解決した要素の id」を見る。
  **Swift 固有の事情**: Shirates は `Any?` の拡張だが、Swift は非 Optional の値に Optional の拡張が
  生えない(`"abc".thisIs(…)` が型解決できない)。実装は `Any?` 側に1つだけ置き、
  素の値へは `FTValue` プロトコルの転送メソッドで生やす(利用者に `let v: Any? =` を書かせない)
- **`repeatWhileCanSelect(sel, max:)`** はセレクタが解決できる限り本体を繰り返す(上限 max)。
  各周回は `group` と同じ規約で `[名前 #n]` を前置して記録する。上限到達は失敗にしないが、
  **打ち切ったことは記録に出す**(`→ 10 回(上限に達したため打ち切り。まだ残っている可能性があります)`)。
  これが無いと「ちょうど 10 件だった」のか「まだ残っている」のかが後から読めない。
  dry-run は canSelect が常に true を返すため **1 周だけ**回してステップ列挙に留める
- **`doUntilTrue(title, waitSeconds:intervalSeconds:maxLoopCount:)`**(2026-07-27。Shirates 準拠の名前):
  任意の Swift 条件が true になるまで繰り返す。**アプリ・外部の状態待ち専用**で、要素の出現待ちは
  各コマンドの `timeout:` を使う(こちらは記録が1ステップに畳まれ、失敗時の情報が減るため)。
  action が throw したら**リトライせず**即 NG(状態待ちと実行時エラーを混ぜない)。
  dry-run は performCustom の既定どおり body を実行しない
- **`tap(scroll:)` / `press(scroll:)` / `type(scroll:)` / `exist(scroll:)`**
  (2026-07-27。Shirates の `tapWithScrollDown` 相当。別名も併設 = 下記「スクロールの語彙」):
  コマンド名の変種を増やさず引数で表す。**探索は同じステップに畳む**(`FlowStep.direction` /
  `maxSwipes` を tap/exists 自身に載せ、`StepExecutor.runScrollSearch` が解決前に走る)。
  実体は `scrollTo` コマンドと共有するので挙動は1箇所にしかない。
  探索終端の空打ちドラッグ(iOS)は**触る点が手前の要素に取られないときだけ**打つ
  (`pointIsTakenByFrontElement`。取られると覆っている要素が反応する。
  verification.md「スクロールした直後のタップ」)。
  **別ステップにしない理由**: 利用者が書いたのは1コマンドなので記録も1行にする。
  合成ステップは**ソース行を持たない**ためステップ表から編集できず、説明の要る状態になる
  (2026-07-27 に一度その形で入れて、直した)。
  見つからなければ「N 回スクロールしても要素が見つかりません」で失敗(optional なら skipped)。
  既定のスワイプ上限は `FlowStep.defaultMaxSwipes`

### スクロールの語彙(2026-07-27。Shirates 準拠)

**DSL のスクロールは全て「コンテンツ基準」**(`FTScrollDirection`。`.down` = 下に読み進める =
指は上へ動く)。**唯一の例外が `swipe(.up)`** で、これは生のジェスチャなので指の動き
(`FTSwipeDirection`)のまま。両者の写像は `FTScrollDirection.swipe` の**1箇所だけ**に置く
(`FlowStep.direction` はブリッジへ渡るジェスチャ側の語彙。DSL 引数を保存しないので、
コード生成 `ScenarioCodeGen` は逆写像して `direction: .down` を書き戻す)。

- **コマンド**: `scrollDown/Up/Right/Left(repeat:)`(1画面ずつ)/
  `scrollToBottom/Top/RightEdge/LeftEdge(maxSwipes:)`(画面が変化しなくなるまで。
  `StepExecutor` の `scroll` / `scrollToEdge` アクション)/ `scrollTo(セレクタ, direction:maxSwipes:)`
- **端の判定は「静止してから比較」+「2回連続で変化なし」**(`settledSignature`)。
  フリングの減速中に撮ると動いていないように見え、さらに Android では次のスワイプが
  **フリングの停止だけに消費されて 1 回空振りする**。1回の不変化で打ち切ると途中で止まる
  (2026-07-27 実測: `scrollToTop` が row_22 付近で停止した)。署名は型・ラベル・**x と y**
  (横スクロールでは y が動かない)。ref はスナップショット毎に振り直されるので使わない
- **`maxSwipes` は暴走を止める上限で終了条件ではない**(端用の既定は `defaultMaxEdgeSwipes` = 50)。
  上限で抜けたときは**ステップに注記を出す**(黙って成功にすると「scrollToBottom したのに
  末尾が無い」の原因が読めない)
- `scrollDown(repeat: N)` は**各スワイプの間で静止を待つ**(待たないと同じ理由で空振りし、
  N 画面ぶん進まない)
- **ブロック**: `withScrollDown { }` 系は `FTDriveCore.scrollContextStack` に積み、
  ブロック内の `tap`/`type`/`press`/`exist` が `scroll:` 未指定なら**その向きで探索**する。
  `withoutScroll { }` と `tapWithoutScroll` / `existWithoutScroll` は積んだ文脈を1段打ち消す。
  明示の `scroll:` 引数が常に最優先(`FTDriveCore.effectiveScroll`)
- **`textIs` 等の検証コマンドに `scroll:` は持たせない**(ユーザー決定 2026-07-27)。
  静止した画面を詳細に検証するためのもので、条件が揃うまで自動でスクロールする挙動は望まれていない。
  **再提案しない**
- Shirates の `scrollFrame` / マージン / 時間指定は**持たない**(ブリッジのスワイプが全画面固定のため。
  ユーザー了承済みの差分)

### 失敗時に返す情報(2026-07-26)

- **解決失敗のメッセージに「近い候補」を最大3件**添える(`StepExecutor.candidateHint`。
  id の部分一致 → ラベルの部分一致 → 同型の順)。直すための snapshot 取り直しを1往復減らす
- **レポートに失敗時点の要素一覧**を折りたたみで載せる(`SceneRecordData.failureElements`)。
  スクリーンショットからは `#id` を読めないため、機械が直すための一次情報はこちら
- **「`isNotChecked` で通ったが checked を一度も観測できなかったセレクタ」を run 終了時に警告**する
  (2026-07-27)。ブリッジは checked を**true のときだけ送る**ので、状態を持たない要素
  (ただのボタン等)や状態を報告しない実装(**iOS の SwiftUI / Flutter の checkbox**)を指すと
  `isNotChecked` は**何を書いても成功する**。notExist の id typo と同じ構造の穴なので同じ扱いにする
  (一度でも checked を観測できたセレクタは警告しない = 正しい使い方を潰さない)
- **`scene` 番号の重複を警告**する(2026-07-27)。番号は利用者が手で振るのでコピペで重複しやすく、
  レポートに同じ番号が並ぶとどちらの結果か読み手が判別できない。
  **失敗にはしない**(番号は実行順にも結果にも影響しないため、既存シナリオを止めない)
- **「否定側でしか使われず一度も解決できなかった `#id`」を run 終了時に警告**する
  (`FTDriveCore.warnAboutNeverResolvedIDs`)。`notExist` / `countIs(x, 0)` は id の綴り誤りでも
  成功するため、構文検証では捕まらないこの穴の最後の砦
- **`ifCanSelect` の不成立は `.skipped` で記録**し、最後まで不成立だった分岐は同じく警告に出す
  (`.passed` にすると「セレクタが腐って毎回飛んでいる」状態が緑のまま見えなくなる)
- **アプリより手前にある別プロセスの window を失敗時に添える**(Android のみ。2026-07-27)。
  `AndroidForegroundWindows` が `dumpsys window windows` を z 順に読み、アプリの window より
  手前で `isVisible=true` かつ別パッケージのものを返す。**アプリの a11y ツリーには他プロセスの
  window が出ない**ため、覆われていても要素一覧は正常に見え、`tap` は成功扱いで返る
  (この穴に実際に2度落ちた。docs/verification.md「操作は ✅ なのに画面が変わらないとき」)。
  常時可視の装飾(StatusBar / Taskbar / NavigationBar / 画面装飾)とアプリ自身の別 window は
  除外し、アプリの window を特定できないときは黙る(誤った断定をしない)。
  配線は `FTScenarioRunner` からの closure 注入(FTDSL は FTAndroid に依存しないため)
- **対象を覆っているアプリ内要素を失敗メッセージに添える**(2026-07-27。`StepExecutor.coveringHint`)。
  アプリ内メッセージ・モーダルは**同一プロセスなので上の別 window 検出では捕まらない**。
  判定は `OcclusionSuspicion.covering`(ツリーのみの幾何。FM もスクショも不要 = FM が落ちていても効く)。
  **過検出寄りなので判定は変えず文言を足すだけ**にする(ステップの成否には触らない)

### 割り込みハンドラ(アプリ内メッセージ。2026-07-27)

- **`irregularHandler("#promo_modal", dismiss: "#btn_promo_close")`** を宣言すると、以降どのステップでも
  出た時点で閉じてから本来の操作を続ける(`StepExecutor.dismissInterruption`)。
  各所に `ifCanSelect` を撒く必要がなくなる
- **宣言の寿命はシナリオ1本**(ハンドラは `FTDriveCore` が持つ = 1プロセス1シナリオ)。
  `setUp()` に書けば各 `@Test` の前に自動で入るので実質1箇所で済む。
  setUp を持たないクラスでは `@Test` ごとに書く
- **アクションでも検証でも発火する**。割り込みは `exist` / `textIs` の**待機中にこそ出る**ので、
  アクション側だけだと宣言した意味が半分失われる(ポーリングの各周回で照合する)
- **閉じ方はアプリ作者しか知らないのでツールは推測しない**。宣言が無ければ何もしない。
  OS 側のダイアログ(権限・IME の案内)は**ここに書かせない** — ツールが吸収する範囲
  (デバイス設定での抑止 + 別 window の検出)。両者を混ぜると責任の所在がぼやける
- **アプリ内メッセージを自動で閉じる相手にしてはいけない理由**: 「今後表示しない」「購入」「削除」が
  閉じるボタンの隣にあり得る。押し間違えるとアプリの状態が壊れ、以降のシナリオを汚す。
  同じ理由で **FM に閉じ方を選ばせるのもアプリ内には広げない**
- **評価は操作前のスナップショットへの照合だけ**(追加のスナップショットを取らない)。
  正常系のコストはゼロで、閉じた後にだけ取り直す
- **閉じたことは必ずステップの注記に出す**(`割り込み … を閉じました`)。黙って閉じると
  「毎回出続けている」異常に気付けなくなる。1ステップにつき1回だけ発火(閉じても消えない相手で
  無限に回らないため)

### 共通ステップとライフサイクル(2026-07-26)

- **`group("名前") { }`** は記録の見え方だけを変える(実行・失敗セマンティクスは素の列と同一)。
  内側のステップ説明に `[名前]`(入れ子は `[外/内]`)を前置する。前置は `FTDriveCore.recordStep` の
  1 点でだけ行い、**修正提案の description は素のまま**(ソース行との照合に使うため)。
  拡張のステップ表から編集できるよう `StepCommandText.parse` が前置を剥がす(要同期)
- **`setUp()` / `tearDown()`**: 同じクラスに引数なし・非async・非throws で書くと `@TestClass` マクロが
  各 `@Test` の run クロージャに織り込む(基底クラスからの継承は見ない)。ライフサイクル無しの
  クラスの生成コードは従来どおり(`X().method()` の 1 式のまま)
  - **setUp の失敗はシナリオごと中断**する。`scene(n)` の入口は `sceneAborted` を毎回 false に戻すため、
    scene をまたいで効く `scenarioAborted` へ昇格させている(ここを外すと setUp 失敗が無視される)
  - **tearDown は失敗後でも実行**する(中断フラグを一時解除 → 実行後に「元の中断」と「片付け中の失敗」の
    OR で復元)。片付けが飛ぶと後続シナリオを汚すため。ただし**画面凍結・ユーザー中断(debug stop)では
    実行しない**(前者は別デバイスで振り直すので無駄、後者は「止めた」のに片付けで再び止まるのが不合理)

### 実行アーキテクチャ

- `Scenarios/` を SPM の実行ターゲット(ftester-scenarios)としてコンパイル。
  マクロが生成する登録クラス(NSObject 派生)を objc ランタイム走査
  (メッセージ送信なしの class_getSuperclass のみ)で自動発見する
- **1 プロセス = 1 シナリオ実行**のサブプロセス方式。ホスト(CLI/GUI/MCP)は ScenarioHost 経由で
  起動し、NDJSON イベント(FTCore/ScenarioEvent)を受信。ビルドはホスト側で1回だけ
- シナリオ本体は**専用スレッドで同期実行**し、async の StepExecutor/AppDriver へは
  セマフォで橋渡し(FTSync)。ブロックするのは専用スレッドのみで協調プールは塞がない
- 失敗セマンティクス: コマンド NG → **シナリオ全体を中断**(以降のステップは scene を跨いで
  すべて skipped。throw を使わない Shirates 的中断)。tearDown だけは失敗後でも実行される。
  2026-07-27 変更(ユーザー決定): 以前は scene 単位のスキップで次の scene へ進んでいたが、
  失敗後の画面状態は不定で、続けても壊れた前提の擬陽性/擬陰性を生むだけのため廃止
  (`abortScenarioOnFailure()` も既定化に伴い撤去)
- **登録不要の単発実行**: `ftester run-file <path.swift>`(Sources/ftester/RunFileCommand.swift)。
  `ftester project create/sync` で Package.swift へ登録していない .swift をそのまま実行する。
  実装は「対象プロジェクトの `Scenarios/_runfile/` へコピー → 通常どおり `RunScenarios` へ委譲 →
  実行後に撤去」だけで、**ビルド・プロファイル・レポート・ヒール・並列は通常 run と完全に同一**。
  - シナリオを**解釈実行**する軽量モードは採らない。実行エンジンが2本になると意味論が必ず分岐し、
    生 Swift・`procedure`・ホスト言語の制御構造という DSL 最大の資産を単発実行だけ失う
  - ファイルが既に登録済みターゲットの中にあるならコピーしない(重複クラス定義になる)。
    `_disabled/` はコンパイル対象外なので、退避したままの単発実行はステージ側に回る
  - 実行するシナリオはファイル内の `@TestClass` から拾う(`--scenario` で明示も可)
  - `_runfile/` は実行の前後で消す。SIGKILL 等で残った場合は次の run-file の開始時掃除まで
    そのプロジェクトの通常 run にも混ざる(.gitignore 済み)

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
- **xcuitest の `launchApp` も既定で simctl 化**(FastLaunchDriver・2026-07-21)。
  XCUIApplication.launch()(約4.6s)の代わりに simctl terminate+launch+activate 接続(約2.4s)で
  再起動する(シナリオ wall −14〜19%)。`FT_NO_FAST_LAUNCH=1` で従来動作へ戻せる。
  attachOnly(整定なし接続)を launch に使わない理由は performance-tuning §6
- **inapp の `launchApp` は毎回 `simctl launch --terminate-running-process` で terminate+relaunch する
  が、アプリのデータは消さないためアプリがディスクへ永続化した直前ルートを復元し得る**(プロセス
  再利用ではない)。決定的なナビ状態リセットはアプリ側の責務で、ツールは状態リセットの注入
  (`SIMCTL_CHILD_FT_RESET` 等)を意図的に提供しない(ユーザー決定・2026-07-20)。
  シナリオ側は scene1 で対象タブをルートへ正規化して吸収する
- **inapp は Compose Multiplatform(iOS)の swipe/scrollTo/press を駆動できない**
  (2026-07-22・`Projects/E2E` で切り分け確定)。同一アプリ・同一シナリオの両エンジン差分:
  - inapp: `tap`/`type` は通る。`swipe` 4方向・`scrollTo`・`press`(長押し)が**すべて無反応**
  - xcuitest: 同じシナリオが**全て成功**

  原因は2段構えで、**合成タッチの品質の問題ではない**:
  1. `/swipe` の主経路はタッチ合成ではなく **`UIScrollView.contentOffset` の直接操作**
     (UIKit/SwiftUI ではジェスチャ認識器が合成タッチを受理しないため、意図的にこうしてある)。
     Compose の画面にも**本体のスクロールとは無関係な UIScrollView が存在する**ので、
     それを動かしても描画は一切変わらず、エラーも出ない = **黙った空振り**になっていた
  2. 経路を合成タッチ(`FTSynthSwipe`/`FTSynthPress`)へ向け直しても Compose は受理しない。
     イベント間でランループを回す・moved の HID マスクに RANGE|TOUCH を足す・静止 moved を
     刻みながら押下保持する、はいずれも**効果なし**(実験済み・不採用)。単発 down/up の
     `FTSynthTap` だけが通る

  対処は3層(1 はブリッジ側、2〜3 はホスト側)。**UIKit/SwiftUI 側の経路は一切変えていない**:
  1. **ブリッジ**: Compose 検出時の `/swipe` `/press` は **501**(`InAppBridge.handleSwipe`/`handlePress`。
     判定は `/status` と同じ `compose-resources` マーカー)。黙って空振りするより
     「12回スクロールしても見つかりません」のような誤診断を防ぐ方が価値が高い。
     **409 ではなく 501 なのは意図的**: 409 はキーウィンドウ不在等の一時的競合にも使われるため、
     フォールバック判定に使うと「アプリが前面に無い」状況を隠して別画面を操作しかねない
     (`/terminate` が既に 501=このエンジンでは未対応 を返している慣習に合わせた)
  2. **事前ルーティング**(2026-07-23): hybrid は in-app と XCUITest の両ブリッジを張るので、
     起動時プローブの **`/status.unsupportedActions`**(ブリッジが「この対象アプリでは実行できない」
     アクション名を申告する。Compose なら `["swipe","press"]`)に該当し typeDriver ありなら
     swipe/press/scrollTo のスワイプを**最初から** typeDriver(`AppAttachDriver`)へ回す
     (`StepExecutor.gesturesViaTypeDriver`)。409 の往復はゼロ
  3. **事後 501 キャッチ**: プローブ不達で 2 が立たなかった場合の安全網。1回 501 を受けたら
     ラッチして以降は直接 typeDriver へ(`scrollTo` は maxSwipes 回まわるので毎回往復させない)。
     `type` の 409 安全網と同じ形。**press は ref がブリッジごとに別名前空間**なので
     typeDriver 側で snapshot し直して再解決する(`pressViaTypeDriver`)

  これにより **hybrid では Compose でもジェスチャが通る**(`Projects/E2E` の `ios-inapp` が
  18/18・37.3s。導入前は3シナリオ失敗・93.9s)。tap/type/スナップショットは高速な in-app のまま。
  409 が表面化するのは **typeDriver が無い構成**(engine=inapp 単独・xcuiPort 無し)だけで、
  そのときはメッセージが xcuitest プロファイルへ誘導する。
  なお `type` の事前ルーティング(`preferTypeDriver`)は別物で廃止済み — Compose でも inapp の
  type が可能かつ高速(266ms vs attach 1.0〜1.3s)なため。ジェスチャは inapp が**不可能**なので
  トレードオフの向きが逆になり、事前ルーティングが常に得になる
- **XCUITest のセッション消失は snapshot 境界でだけ自動回復する**(`SessionRecoveryDriver`)。
  ランナー再起動で `BridgeRouter.requireApp()` が 409 を返すと以前は全操作が落ちていた。
  この経路の 409 はセッション消失専用(409 を投げる箇所が1つしかない)なので状態コードだけで判定でき、
  `activate`(**`launch` ではない**。launch はアプリを再起動してナビ状態を飛ばす)で張り直す。
  **ref を使う操作(tap/type/press の ref 指定)は再試行しない**: セッション確立は `refFrames` を
  クリアするため、同じ ref での再試行は別要素を操作しかねない。セッションだけ張り直して 409 を返し、
  次のステップの snapshot で ref が振り直されて復帰する(StepExecutor は各アクションの前に必ず
  snapshot するので、実際の損失は最大1ステップ)。ref を使わない操作(snapshot/screenshot/swipe/
  座標指定 tap/press/drag/home/appSwitcher)だけ 1 回再試行する。
  in-app/hybrid 経路には入れない(InAppDriver の 409 は意味が違う)
- **`.型[n]` の n は「現在画面に見えている同型要素のツリー順」**。圧縮スナップショットは画面外要素を
  含まないため、序数は**スクロール位置と画面クロム(戻るボタン・下部タブ)に依存する**。
  レイアウト変更で黙ってずれるので、序数セレクタは実スナップショットで採取してから書く
- **型は「役割」に正規化する**(2026-07-26)。ブリッジが返す型はネイティブのクラス名ではなく役割で、
  **OS を跨いで保証されるのは `button` / `staticText` / `textField` / `secureTextField` / `switch` の5つ**。
  Android 側の正規化規則は 3 つ(`SnapshotBuilder`):
  ① clickable なノードが**同一 bounds の無名 `android.widget.Button` 子**を持てば `button`
     (Compose は Role.Button をこの形でしか出さない。testTag が付く当のノードは `android.view.View`)
  ② `checkable` な汎用ノードは `switch`(Compose の Role.Switch は legacy className を持たない)
  ③ 葉 + contentDesc のみの汎用ノードは `staticText`(Flutter は canvas 描画でテキストも
     `android.view.View`。これが無いと **id を振っていないテキストが丸ごと落ち**、ラベルを
     アンカーにした方向セレクタが使えない)
- **`checkBox` / `slider` / リスト行は揃えられない**(iOS 側が役割を出さない: Compose の Checkbox/Radio は
  iOS で `button`、Slider は `other`。2026-07-26 に同一アプリ・同一画面で実測)。**型で指さず `#id` を使う**。
  これは「情報が無い側に合わせるしかない」ケースで、ブリッジ実装では解消できない
- **Android は「別ウィンドウ」に描画される UI(`AlertDialog` 等)にテスト用 id が出ない**
  (2026-07-22 実測)。`testTagsAsResourceId` はルートに1回付ければ子孫全体に効くが、ダイアログは
  ルートの子孫ではないため効かず、**ダイアログ内だけ `#id` が全滅する**(ラベルは引ける)。
  アプリ側でダイアログにも `Modifier.semantics { testTagsAsResourceId = true }` を再適用させる。
  iOS は testTag が自動で accessibilityIdentifier になるため起きない(Android 固有)
- **偽陽性検証を有効にした run(実行プロファイル `falsePositiveCheck: true`。既定 OFF)では、
  `exist`/`textIs` は既定 `requireVisible: true` のため、ソフトキーボードに覆われた要素は
  「偽陽性(occlusion)」で失敗する**。入力を伴う画面では検証対象・操作対象を入力欄より**上**に置く
  (Projects/E2E のテキスト入力画面がこの配置。2026-07-22 実測)
- **inapp ブリッジは注入先アプリのプロセス内常駐**なので、アプリがクラッシュ/終了すると HTTP が
  `DriverError.bridgeConnectionRefused`(「Could not connect」)になる。xcuitest/Android はブリッジが
  別プロセスのためこの切断は起きない(inapp 固有)。切断時は `InAppDriver` がホストの
  `~/Library/Logs/DiagnosticReports` から対象 bundleID の直近 `.ips` を探し、レポートのエラー行に
  クラッシュレポートのパスと終了理由を1行で添付する(`SimulatorCrashReport`。JSON 形式優先・旧テキスト
  形式もフォールバック解析)。`.ips` が**見つからない**ときは「OS 終了/メモリ圧/自発終了・混在実行の
  suspend の可能性」を切り分け文言として添える(クラッシュ以外の切断と区別する)

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
`appName`(表示名)と `autoInstall` は **common のみ**採用、bundle ID(`app`)と `appPath` は
**ios/android セクションのみ**採用(common に書くと merging で無視され validate が警告する):

```json
{ "common":  { "appName": "サンプルアプリ", "autoInstall": true },
  "ios":     { "app": "com.example.sampleapp", "appPath": "~/builds/SampleApp.app" },
  "android": { "app": "com.example.sampleapp", "appPath": "builds/app-debug.apk" } }
```

`appPath` の相対パスは**リポジトリルート**基準(上例の `builds/app-debug.apk` は `<repoRoot>/builds/...`)。
`~` 展開・絶対パスも可。ビルド成果物は Projects/ 外に置くのが普通なためプロジェクト基準にしていない。

`healthCheckURL`(common のみ・任意)— アプリが依存するバックエンドの死活確認 URL。実行開始前に
3秒タイムアウトで到達確認し、不達なら警告する(実行はブロックしない)。バックエンド停止中は
アプリが非同期処理でクラッシュし「Application is not running」で全滅して原因が見えにくいため
(2026-07-21 実害)、入口で気づけるようにする。

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
  **エミュレータの** serial 直指定は廃止 — serial は起動順で変わるためプロファイルに書かない)

**実機**(`kind: "physical"`。省略時は `"virtual"` = シミュレータ/エミュレータ)。
識別子は iOS が `udid`、Android が `serial`(実機の serial は起動順で変わらないので直接書く):

```json
{ "ios":     { "devices": [ { "name": "iPhone 実機", "kind": "physical",
                              "udid": "00008130-000A1B2C3D4E5678" } ] },
  "android": { "devices": [ { "name": "Pixel 実機", "kind": "physical",
                              "serial": "14141JEC204922" } ] } }
```

- iOS 実機の `udid` は `xcrun devicectl list devices` の **`hardwareProperties.udid`**
  (`00008130-...` 形式。同じ一覧の Identifier 列(UUID)とは別物で、`xcodebuild -destination id=`
  が受け付けるのは前者だけ。Identifier を書いても解決はする)。Android 実機の `serial` は
  `adb devices` の左列(WiFi 接続なら `192.168.1.23:5555` 形式)
- 拡張のデバイスピッカー(「+既存から選択」)が接続中の実機を出すので、手書きしなくてよい
- **iOS 実機は engine が `xcuitest` に固定される**(dylib 注入は実機不可なので `iosInappEngine`
  の既定 hybrid を無視する。`engine: "inapp"` を明示すると検証エラー)
- `devices up/down` は**端末そのものを起動・停止しない**(接続確認+ブリッジの供給/停止だけ)。
  モニターのタイル右クリックも実機ではラベルが「ブリッジを起動/停止」になる
- **iOS 実機の `state: "booted"` は「端末は接続済みだがブリッジが1本も無い」**の意味
  (`ApiMonitorCommand.iosState`。シミュレータの booted=起動済みとは意味が違う)。実機のブリッジは
  自動供給されないのでこの状態は待っても変わらない ⇒ モニタータイルは**未起動として表示**し、
  右クリックも「ブリッジを起動」を出す(`deviceTiles.js` の `bridgeNotRunning`)。
  Android 実機の booted は「adb は見えるがブート未完了」= 本当に遷移途中なので対象外
- ライブ映像は実機だけ **`ftester-devicepoll`**(スクショのポーリング → MJPEG)を使う。
  `ftester-simstream` は CoreSimulator 私有 API で iOS 実機に使えず、`ftester-androidstream`
  (screenrecord)は Android 実機だと静止画面でフレームが流れないため(詳細 docs/verification.md)
- 実機で成立しない機能は静かに無効化される: iOS の録画(`simctl io recordVideo`)、
  Reduce Motion 自動設定、autoInstall の差分スキップ(コンテナを読めないため毎回インストール)。
  Android 実機は録画(`adb screenrecord`)も従来どおり動く
- `model` / `os` は実機では**表示専用**(登録時に控えるだけで同定には使わない。端末を挿し替えても
  追随しない)。iOS シミュレータの `simulator`/`os` だけは実体解決に使う値なので意味が違う
- 実機の要件と罠(iOS の署名・LAN/USB 経路、Android の画面ロック)は docs/verification.md

**実行プロファイル** `runs/<name>.json` — アプリ+デバイス名リスト+実行時設定。
platform フィールドは持たず、**iOS/Android のデバイス名を混在させれば両OS同時実行**になる:

```json
{ "app": "sampleapp",
  "devices": [ { "name": "メイン機" }, { "name": "サブ機" }, { "name": "エミュ1" } ],
  "fm": true, "heal": false, "reportDir": "reports", "defaultTimeout": 5,
  "wipeDataOnBloat": true, "wipeDataThresholdGB": 8 }
```

`fm`(既定 true)は FM(Foundation Models)機能の親スイッチ。false にすると自己修復(heal)・
偽陽性検証(exist 等の FM 視覚照合)・`screenIs`・失敗時トリアージを含む FM 呼び出しを一切行わない
(子ランナーへは `--no-fm` 等で伝搬し、delegate 自体を作らない)。個別トグルは `heal` / `screenIs`
(既定 true)と `falsePositiveCheck`(偽陽性検証。**既定 false** — FM コストと誤反転リスクのため
オプトイン)。親が false なら個別指定に関わらず全て無効。screenIs を無効にした run では該当ステップは
skip(素通り)になり、FM 利用不可時と同じ扱い。UI はデバイスタブの実行プロファイル設定
「FM(Foundation Model)」セクション(親チェックボックス ON のときだけ個別トグルを表示)。

`wipeDataOnBloat`(既定 true)は実行開始時に Android AVD の wipe 対象
(userdata/cache/snapshots)合計が `wipeDataThresholdGB`(既定 8。**Play イメージは wipe 直後の
再構築だけで 2〜4GB になるため 4GB 以下はスラッシング**、実測 2026-07-17)超過なら Wipe Data してから
実行する(AndroidDataWiper.swift。ゲストは初期化されるが、アプリは appPath があれば強制
再インストール、ロケールは下記 `locale` が再ブート後に自動適用される)。

`recoverCpuFallbackToGpu`(既定 false)を true にすると、実行開始時に**画面凍結で CPU 描画
(swiftshader)へ落ちた Android エミュレータを GPU(`-gpu host`)で起動し直す**
(AndroidGpuRecovery.swift。`dumpsys SurfaceFlinger` で現に CPU の個体だけが対象、1台ずつ直列)。
GPU モードは emulator の**起動引数で固定**されるためプロセス再起動が必須で、該当機1台につき
run 開始が約1分延びる(ゲスト再起動では戻らない)。戻した先で再び凍結すればモニターの watchdog が
また CPU に落とす(§12.4 の既知トレードオフ)。UI はデバイスタブの実行プロファイル設定
「CPUフォールバックをGPUに回復する」。拡張側の記憶(`MonitorDeviceOps.cpuRenderNames`)は
モニターが再検出した renderMode を見て `syncCpuRenderNames` が落とす(run 側の復帰は拡張の外で
起きるため、これが無いと次の個別 device-up が再び swiftshader で起こしてしまう)。

`record`(既定 false)を true にすると、各ワーカー(デバイス)で run 全体を録画し続けつつ
(iOS: `simctl io recordVideo` の .mov / Android: `screenrecord` の 180 秒セグメント群)、
ファイナライズ時に**テスト関数(シナリオ)ごとに1本の mp4**へ壁時計区間で切り出して
`<runDir>/recordings/` に保存する(AVAssetReader/Writer で該当区間だけ半分解像度+低 bitrate の
H.264 に再エンコード。VFR ソースの区間頭フレーム欠落は直前サンプルの retime で補う)。拡張側との
契約は `recordings/index.json`(schemaVersion 2。VideoRecordingCoordinator.swift・
RecordingIndex.swift・RecordingWallClock.swift)。録画自体の失敗は run を失敗させない。

ファイナライズのエクスポートは同時 2 本に制限し、クリップ 1 本ごとに期限 `max(60秒, ソース総尺)`
を切る(ホスト HW エンコーダ[AVE]の無応答で `finishWriting` が永久待ちし run がハングした実害
2026-07-27 への保護)。期限超過はエンコーダ無応答とみなして**その run の残りクリップを断念**し、
run 自体は完了させる。期限側は敗者 task に触れず放置する(`cancelWriting` は固着した VT セッション
のロックで共倒れし得る)。診断手順は docs/verification.md「録画(record:true)の検証」。

録画の付随設定(すべて `record: true` のときのみ意味を持つ): `recordFailuresOnly`(既定 false)
は true で成功したシナリオのクリップを保存せず失敗(frozen 含む)分のみ残す。`recordBitrateKbps`
(既定 1500)は再エンコードの bitrate(kbps)で AVVideoAverageBitRateKey と Android screenrecord
`--bit-rate` の両方に適用。`recordFullResolution`(既定 false)は true で半分解像度化(iOS 再エンコード
時の縮小・Android `screenrecord --size`)をスキップしフル解像度のまま出力する。

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
6. 未知キーは警告(タイポ検出)。相対パスのチルダ展開あり。基準は用途で異なる:
   `appPath` はリポジトリルート基準、`reportDir` はプロジェクトルート基準(RunProfile.resolve)
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
   起動(デバイス単位で並列。hybrid の 2 ブリッジはデバイス内直列)」(performance-tuning §3.2)。
   **run は終了時にブリッジを停止しない**(常駐を残すのが仕様。次の run が再利用する)
4. **自動インストール**: `appPath` あり+`autoInstall`(既定 true)→ オーケストレータ投入前に
   各ワーカーへ並行 install(差分判定=installedIsCurrent も並列。失敗ワーカーは離脱、
   残ワーカーがキューを引き継ぐ)
5. RunOrchestrator で並列実行。ワーカーラベル=デバイスの論理名。レポートは
   `Projects/<P>/reports/`、ヒールキャッシュは `--project-dir` 経由で `Projects/<P>/.ftester/` に分離
   - **シナリオの振り分けは platform 別の静的分配**(ワークスティールではない)。
     `ProfileRunner` は iOS デバイスが1台でもあれば既定 platform を `ios` にし、
     `RunOrchestrator` は `@TestClass` の `platform:` **未指定**シナリオをその既定 platform の
     キューにだけ入れる。自分の platform のキューが無いワーカーは1本も受け取らずに終わる。
     → **両OSのデバイスを供給する実行プロファイル(`all` 等)を使っても、platform 未指定の
     シナリオは片方の OS でしか走らない**(供給された他方のデバイスは空回り)。
     platform 非依存に書いたシナリオを両OSで回すなら `--profile ios` と `--profile android` を
     別々に実行する。シナリオ数や負荷には依存しない決定的な挙動(2026-07-22 実測)
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
  **実行/デバッグ実行は `ftester.profile` 未指定なら実行せず、デバイスタブでの指定を促す通知
  (「デバイスタブを開く」= `ftester.showDeviceMonitor`)を出す**(未指定だとブリッジ自動供給の無い
  直接ポート接続に落ち、全シナリオが接続拒否で即失敗するため。ユーザー決定 2026-07-26。
  dry-run とライブ操作パネル連動は実デバイスを要さない/解決済みのため除外)
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
- **壊れたレコードを webview へ流さない**: 長さ前置きのバイナリ列は helper が書き込み途中で死ぬと
  境界がズレ、以降**自力復帰せず**ゴミの寸法+非 JPEG を吐き続ける。v1 パーサは寸法・長さの足切りと
  JPEG SOI 照合で desync を検出し、未知 KIND と同じく helper を kill して張り直す
  (`deviceStream.ts` の `handleProtocolDesync`)。タイル側もヘッダ由来の寸法を信用せず
  **デコードできた画像の実寸だけ**でアスペクト比を決める(壊れたフレーム1枚でタイル幅が
  異常に広がったまま戻らない実害。2026-07-26)

### 12.2 ブリッジ死の検知と自己修復

XCUITest ランナーは HTTP サーバだけ死んで xcodebuild 親が残ることがある(2026-07-14 実例)。

- **watchdog**(`vscode-ftester/src/monitorBridgeWatchdog.ts`): 一度 connected になったデバイスが
  booted(実体は起動中・ブリッジ無応答)へ降格して連続5観測(約10秒)続いたら `device-up` を
  自動投入。実行レーン稼働中は保留・クールダウン3分・2回失敗で諦めて表示(`ftester.autoRepairBridge`
  既定 ON)。タイルに出すのは諦めた後(failed)だけで、文言は実機「デバイス未接続」/仮想機
  「接続できません」(内部語ではなくユーザーの取れる行動が分かる語にする。ftester 出力への
  誘導はホバーのツールチップへ退避。`deviceTiles.js` の `bridgeWatchLabel`)
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
  `health: ["wifi-disabled"|"clock-skew"|"blank-screen"|"metal-errors"]` で拡張へ伝搬
  (契約は `vscode-ftester/src/monitorModel.ts` 冒頭。拡張は未知の種別も再起動修復に倒す)。
  **`metal-errors` だけは拡張側で落とす**(表示も修復もしない。`monitorHealthWatchdog` の
  actionable フィルタ。ホスト GPU ドライバ由来で全機に同時に出る背景現象で個体の異常を表さない=
  タイルに出すのが不適切。フリート全数検証の実データは performance-tuning.md §7。
  Swift 側は記録・分析のため載せ続ける契約のまま)
- **watchdog**(`vscode-ftester/src/monitorHealthWatchdog.ts`): 異常種別ごとに修復ラダーが分かれる。
  ライフサイクルキュー busy 中は保留(起動/停止処理との競合回避)。テスト実行中は保留しない
  (ユーザー決定 2026-07-17: 凍結は実行完了を待たず即修復。実行中の該当デバイスは再起動で落ちるが
  凍結済みで証跡が撮れないため許容)。設定 `ftester.autoRepairDeviceHealth` は
  **既定 OFF**(autoRepairBridge と異なり、Wi-Fi をわざと切ったテスト環境を勝手に上書きしないため)。
  検出通知(タイルの警告バッジ)は設定 OFF でも出す。
  - **wifi-disabled 単独**: まず `adb shell cmd wifi set-wifi-enabled enabled`(軽量修復、クールダウン 120s)。
  - **blank-screen(画面凍結)**: **画面リセット(`runDisplayRepair`=sleep/wake keyevent ~4s。
    固着した合成バッファの無効化→再合成で直す最軽量修復。readback が効かない個体にも効く。
    クールダウン 60s)**→ ストリームヘルパー再起動(`restartStream`。読み出し再開で一時回復。
    クールダウン 120s)→ 効かなければ **CPU 描画へフォールバック**(`forceCpuRender`→`MonitorDeviceOps`
    が個別 device-up に `--gpu swiftshader_indirect` を付与。セッション中維持。bulk devices-up も
    `--cpu-render` で維持)→ それでも駄目なら failed。
    **host 再起動は挟まない**(実測で host 再起動は治らず再凍結=無駄。§12.3・performance-tuning.md §7)。
    run 経路(CLI/api run)は watchdog と独立に、実行前トリアージ「blank 検出→sleep/wake 修復→
    不発なら guest reboot を同期発行しブート完了待ち→再判定して**本 run で使う**(まだ blank の
    個体だけ除外)」と実行中修復を持つ(`ProfileWorkerFactory.excludeOrRepairBlankScreenWorkers` /
    `AndroidHealthProbe.observeBlankAndRepair`。修復/除外は run.json の
    blankRepairs/blankExclusions に記録される。guest reboot は emulator プロセスを再起動しないので
    serial は変わらず、ワーカーの再構築は不要)。
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

## 15. 外部パッケージ配布と mint 配布の履歴(2026-07-19・07-20 外部構成を既定化)

**現状(正典)**: onboarding の既定は**外部パッケージ構成**(受け手ディレクトリを `ftester init` で
テストパッケージ化し、Projects は受け手側に住む。foundation-tester は横に clone した「ツール」=
TOOL_ROOT)。clone 構成(クローンの中で直接シナリオを管理)は保守者/PoC 向け。入口は **Claude Code
プラグイン**(ターミナルで `claude plugin marketplace add wave1008/foundation-tester` →
`claude plugin install ftester@foundation-tester --scope user`。受け手は VSCode の Claude Code 拡張前提で、
拡張パネルでは /plugin スラッシュコマンドが使えないため CLI 形式が正。
スキルはマーケットプレイス経由で自動更新・版固定は `#<tag>`)、フォールバックが curl ワンライナー
(`Scripts/install-skill.sh` がスキルを .claude/skills/ へコピー。自動更新なし)→ いずれも
`/ftester-setup`(プラグインでは `/ftester:ftester-setup`)が構成を自動判定し、受け手ディレクトリは
外部構成へ分岐、クローン内は clone 構成。CLI・VSCode 拡張とも TOOL_ROOT の clone から `swift build` /
`npm run install-local` でビルドする(バイナリ配布はしない)。mint は廃止(VSIX はバイナリ配布しないため
clone がどのみち必須で、CLI だけ mint 経由にすると二重取得になるだけだったため)。

**配布アダプタの方針(他エージェントツールへの将来展開)**: 導入 runbook の正典は
`.claude/skills/<name>/SKILL.md`(ツール中立の markdown 手順書。特定エージェント専用機能に依存させない)。
Claude Code 向けは `.claude-plugin/`(plugin.json の `skills` が正典ディレクトリを**参照するだけ**の薄い
アダプタ。複製しない。整合は `vscode-ftester/test/claudePlugin.test.mjs` が検証)。他ツール(Codex/Cursor 等)へ
展開するときも、同じ runbook を各ツールの規約位置から参照/変換する薄いアダプタを足す(runbook 本体は共有し、
ツールごとに手順書を複製しない)。
**ローカル検証の罠**: `/plugin` は VSCode 拡張パネルでは使えない(ターミナル CLI かデスクトップアプリ)。
`claude plugin marketplace add <ローカルパス>` は git clone ではなく**作業ツリーを丸ごとコピー**する
(gitignore を無視するため `.build/` 約8GB も入りキャッシュが約13GBに膨れる)。検証後は
`claude plugin uninstall ftester@foundation-tester` + `claude plugin marketplace remove foundation-tester`
で登録を外し、**キャッシュ実体は remove 後も残る**(実測)ので
`~/.claude/plugins/cache/foundation-tester` を手動削除する。GitHub 経由の本番導入は git clone なので
生成物は含まれない。
以下は外部パッケージ構成(`ftester init`)の実装詳細。

受け手が foundation-tester を clone せず、**自分の Swift パッケージが ftester を SPM 依存として引いて**
自分のアプリのシナリオを書ける構成(以下「外部パッケージ構成」)。clone してその中でシナリオを管理する構成を「clone 構成」と呼ぶ。

- **公開 products**: `Package.swift` の `products:` に `.library`(FTScenarioRunner / FTDSL / FTCore)と
  `.executable`(ftester)。受け手のシナリオターゲットはこれを `.product(package: "foundation-tester")` で引く。
- **`ftester init`**: 受け手の Package.swift(空マーカー区間 + swift5Mode + ftester 依存)を書き、
  `ProjectScaffold.createAndRegister` が最初のプロジェクトを登録。内外は `isExternalPackage`
  (`Sources/FTScenarioRunner` の有無)で自動判定し、`PackageManifestEditor` が内部=target 参照 /
  外部=`.product` 参照のスタンザを生成する(`project sync` も同じ判定)。
- **repoRoot の二役分離**: シナリオビルドは `ScenarioHost.packageRoot()`(= 受け手パッケージ。Package.swift
  のみ上方探索)。ブリッジ資産(`Runner/`・`InAppBridge/`)は `RepoRoot.find()`。後者の解決順は
  ① 実行ディレクトリ上方の Package.swift+Runner/(clone 構成)② 受け手パッケージの `.build/checkouts/*/Runner/`
  (外部パッケージ構成の git 依存。swift build が展開・CLI の導入方法に依らず永続)③ `#filePath` からのツールソース
  (local path 依存 / 自前ビルド)。下流(BridgeProvisioner/DevicesCommand/InApp/LiveBridge)は無変更。
- **mint 配布(採用していたが廃止)**: `mint install wave1008/foundation-tester@<ver>`。**罠(記録)**: mint は
  temp でビルドしてバイナリのみ残しソースを消すため CLI の `#filePath` は死ぬ → ブリッジは上記②(受け手の
  checkout)で解決する必要があった。よって外部パッケージ構成は **git 依存必須**(ブリッジ用に Runner/ を含む
  checkout が要る)。ソース無し mint バイナリで bridge up→/status ready を実機実証済みだったが、CLI/VSIX の
  二重取得の無駄から mint 自体を廃止(現状は上記「正典」参照)。**制約(継続)**: XCUITest ブリッジは SPM
  ライブラリ化できないため「ソースビルド配布」前提(prebuilt をソースの無い別マシンへ運ぶと Runner/ 解決不能)。
- **拡張**: `binaryPath` は実在しなければ PATH フォールバック(`binaryPathResolve.ts`)で外部パッケージ構成の
  CLI(自前ビルドの PATH 登録先)を発見する。
- **版**: git タグ(版ピン用)/ 拡張 package.json / プロトコル版(compatCheck)は独立。リリースは
  `Scripts/release.sh`(docs/releasing.md)。

## 16. エミュレータ操作の gRPC 制御(2026-07-25)

Android エミュレータへの操作は**既定で emulator 内蔵の gRPC(EmulatorController)経由**、失敗時は
adb へ自動フォールバックする(ユーザー決定 2026-07-25)。動機は PoC 実測: スクショ 48ms vs adb
140〜250ms(3〜6倍)、キー注入 1.2ms vs 215ms、run 起動オーバーヘッド 3.2s→0.6s、adb 経路死亡個体
への修復・停止の到達性。

### 16.1 構成(3層)

| 層 | 場所 | 役割 |
|---|---|---|
| ディスカバリ | `FTEmulatorGrpc/EmulatorEndpoints` | `~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini` から serial→port/token/avd.id を解決(pid 生存確認付き。トークンはブート毎に変わる) |
| RPC | `FTEmulatorGrpc/EmulatorGrpcSession`(grpc-swift-2) | 単発 RPC(接続は呼び出し毎)。認証は `authorization: Bearer <grpc.token>` のみ |
| 振り分け | `FTAndroid/EmulatorControl` | emulator なら gRPC・実機/失敗個体は adb。**失敗した pid は同一ブート中 adb 固定**(再ブートで自動復帰)。殺しスイッチ `FT_EMULATOR_CONTROL=adb` |

**gRPC を話すのは Swift だけ**。拡張は自前の gRPC クライアントを持たず、画面凍結修復を
`ftester api repair-display`(`ApiRepairDisplayCommand`)へ委譲する(以前は `emulatorGrpc.ts` +
`emulatorEndpoints.ts` に proto コピー・ディスカバリ・blank 判定の第二実装があり、閾値と手順を
言語間で同期する必要があった)。proto は `third_party/emulator-proto/`(vendored・再生成手順は
同 README。Swift スタブは生成物をコミット)。

### 16.2 置き換え済みの操作と残存 adb

- gRPC 化済み: blank プローブ/sleep-wake 修復(AndroidHealthProbe)・停止=setVmState SHUTDOWN
  (DeviceBooter/DataWiper/DevicesCommand)・serial→AVD 名=ディスカバリ読み・bootCompleted
  (booted=true のみ確定、他は getprop 再確認)・難治型 reboot の adb 不達時 RESET・
  home「GoHome」/appSwitcher「AppSwitch」/drag・press のタッチ合成(AndroidDriver)
- adb 残存(原理的に置き換え不可): ブリッジ到達の `adb forward`+localhost HTTP・shell 系
  (am/pm/settings/getprop/cmd wifi/dumpsys)・install・pull・実機の全操作

### 16.3 罠(実測で確定・変更時に踏み直さないこと)

- **wake は KEY_POWER(evdev 116)**。KEY_WAKEUP(143) は emulator のキー変換欠落で不発。
  sleep は KEY_SLEEP(142・非トグル)→直後の POWER トグルは安全
- **blank 判定に gRPC PNG のサイズ閾値を使わない**(emulator エンコーダは一様黒でも 51KB。
  30KB 閾値は adb 較正)。gRPC 経路は ImageIO デコード+`uniformFrame` の画素一様判定
- **grpc-swift は約10MB の単一メッセージ受信で接続切断される**(RGBA 直取り不可。PNG で受けて
  ホスト側デコードにしている理由)
- grpc-swift v2 の正リポジトリは **grpc/grpc-swift-2.git**(grpc-swift.git の 2.x タグは旧系)

### 16.4 iOS 側の相当実装: simctl→CoreSimulator 直叩き(2026-07-25)

iOS には emulator gRPC に相当する公開 RPC が無いため、同型の勝ち筋は **simctl のプロセス起動固定費の
排除**。`FTCoreSimShim`(ObjC・dlopen+objc_msgSend、ftester-simstream と同作法)が
CoreSimulator.framework を直接叩き、`SimulatorCatalog.devices()` が直叩き優先・simctl フォールバックで
振り分ける。殺しスイッチ **`FT_SIMULATOR_CONTROL=simctl`**。

- 実測(シミュレータ 210 台): 列挙 6ms vs simctl 567ms(92倍)・全台 state 読み 0.03ms。
  初期化(dlopen+SimServiceContext)は初回のみ ~470ms=常駐(monitor)で償却
- 保持する deviceSet ハンドルは boot/shutdown に live 追従(再初期化不要)
- セレクタ欠落(Xcode 版差)は列挙ごと nil → simctl へ(部分的な混在結果を返さない)。
  等価性は UDID/booted 集合の完全一致を live テストで担保
  (Tests/FTBridgeClientTests/SimulatorCatalogCoreSimTests.swift、FT_LIVE_SIM=1)
- ステップ実行(tap ~490ms)は XCUITest エンジン内部コストでこの施策の対象外。
  HID 注入バイパスは評価済み不採用(backboardd クラッシュ)・再提案しない

## 17. テストベースからのシナリオ下書き生成(2026-07-26)

`Projects/<name>/docs/testbases/*.md`(テスト設計の元資料)を Swift DSL シナリオの**下書き**に
落とす。`ftester draft-scenario`。ライブ操作の記録生成(§10 の gen-scenario)は実セレクタを持つが、
こちらは設計資料しか無いのでセレクタは全て TODO プレースホルダになる。

### 17.1 二段構え(FM → 決定的パーサ)

| 層 | 実装 | 役割 |
|---|---|---|
| 構造化(FM) | `FTAgent/TestbaseDrafter` | 資料 → `ScenarioDraft`(scene の並び + CAE ごとの自然言語手順)。1呼び出し1セッション |
| 構造化(決定的) | `FTCore/TestbaseOutline.parse` | 見出し(`#`=説明 / `##`=scene)・`### 前提`・行頭ラベル(`前提:`/`Given:`)・「〜こと」で CAE に振り分け |
| レンダリング | `FTDSL/ScenarioDraftCodeGen` | 手順文 → コマンド候補(語彙の包含判定のみ・**FM 不使用=決定的**)+ Swift ソース |

**FM が不可用・失敗・出し損ないのときは決定的パーサへ落ちる**(`--no-fm` で常に決定的)。
4K 制約のため FM へ渡すのは先頭 2400 文字だけで、超過時は警告する(全文要約より「頭から確実に」)。

### 17.2 生成物の性質(壊さないこと)

- 生成クラスには **`@Deleted` を付ける** → 一括実行から外れる(一覧には残る)。人が TODO を実セレクタへ
  置き換えてから `@Deleted` を外す運用。出力先は `Scenarios/Drafts/`(SPM ターゲットに含まれるので
  **下書きもコンパイル対象**。`ScenarioCodeGen.writeValidated` でビルド検証し、失敗時は `_disabled/` へ隔離)
- プレースホルダは `#TODO` = **決して解決できない id**。埋め忘れたまま `@Deleted` を外すと
  「ロケータを解決できません」で確実に落ちる(空実装で緑になる方が危険なので意図的)
- 手順文は必ずコマンド行の末尾コメントに残す(写像が外れても元の意図が読める)
- `--name` 明示時は重複回避の連番が付かないため、同名ファイルがあれば上書きせずエラーにする
