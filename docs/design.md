# fleetest mobile 設計書

Foundation Models framework(オンデバイス 3B モデル。macOS 26+、視覚検証は 27+)を最大限活用する、
iOS / Android 両対応のアプリ E2E テストツール。iOS を先行実装し、Android は同じ
`AppDriver` 抽象の上に後続実装した(経緯・時系列は §7, §8 参照)。

- 作成日: 2026-07-07 / 最終更新: 2026-08-11
- ステータス: iOS / Android とも実装済み・運用中(GUI 入口は VSCode 拡張に一本化)
- 決定事項: ハイブリッド型 / 自作 XCUITest ブリッジ+自作 Android ブリッジ / シミュレータ優先 / Swift + FoundationModels

---

## 1. 背景と方針

### 1.1 Foundation Models framework(macOS 26+ / 画像入力は macOS 27 = WWDC 2026)の前提

| 機能 | 内容 | 本ツールでの用途 |
|---|---|---|
| 新オンデバイスモデル (AFM 3) | ロジック・tool calling が大幅改善、Vision(画像入力)対応 | エージェントの頭脳 |
| Guided Generation (`@Generable`) | constrained decoding による型安全な構造化出力。パース失敗が原理的に起きない | 全ての LLM 出力(修復案、レポート) |
| Tool calling (`Tool` プロトコル) | 並列/直列の呼び出しグラフを framework が自動処理 | 画面詳細のオンデマンド取得など補助的に使用 |
| マルチモーダル | 画像+テキスト入力(NSImage/CGImage/CVPixelBuffer/URL) | スクリーンショットの視覚検証・トリアージ |
| Dynamic Profiles | セッション中にモデル・ツール・instructions を切替 | verifier / triager の役割切替 |
| `LanguageModel` プロトコル | オンデバイス / PCC(32K ctx) / Claude / Gemini / MLX を同一 Session API で差替 | 難しい計画立案だけ大型モデルに逃がす保険 |
| 制約: コンテキスト ~4K トークン級 | TN3193 参照。プロンプト+応答で共有 | **設計全体を規定する最重要制約** |
| 制約: ホスト全体で共有される資源 | 許可枠(既定5、環境変数で上書き可)で制限される。並列度が枠を超えるとレイテンシが伸びる(performance-tuning.md §3.5) | 並列実行では FM 呼び出し数と枠が実行時間の下限に効く(performance-tuning.md §3.5) |

**可否判定の罠**: `SystemLanguageModel.default.availability` は「端末が対応しているか」しか見ておらず、
モデル資産側の理由で**全呼び出しが失敗していても `.available` を返す**(専用ケース
`.appleIntelligenceNotEnabled` があるのに返さない。2026-07-22 実測)。可否を人へ報告する場所では
実際に1回推論する `FMDoctor.checkLive()` を使う(`fleetest doctor` / MCP の `ft_doctor` が採用)。
同期の `FMDoctor.check()` はホットパス用で**可否を保証しない**。

**FM 失敗は握りつぶされる**: occlusion-guard・heal・screenLooksLike はいずれも FM 失敗時に nil を返して
素通りする契約なので、FM が全滅してもテストは緑のまま**機能だけ無効**になる。
**ただし黙らない**(2026-08-23): occlusion-guard(`exist` の既定 `requireVisible`)は **FM に訊いたのに
判定が返らなかったステップ**に `StepNote.visibilityGuardSkipped`(`visibility-guard-skipped`)を立て、
結果 JSON の `notes` から run 横断で数えられる(立てるのは FM まで到達した回だけ。マスタースイッチ OFF・
macOS 26・インクゲートで省いた回は「訊く必要が無かった」)。同時に **requireVisible は2段**になった:
Tier-0 幾何 = 収まる軸の中心が画面外なら不可視(`TapTargetGeometry.offscreenScrollGateCentre`。
スクロール探索の「見つかった」ゲート・逆走査 `reverseSweep`・MCP の `ft_scroll_to` 再照合と同じ述語で、
**文言は呼び手ごと**)→ Tier-1〜 FM。iOS の木は画面外の要素も frame ごと残し、FM 側は crop が
画像の外に落ちると nil(素通り)なので、**通り過ぎた要素への exist は FM が生きていても FM では
塞がらなかった**(2026-08-20 受け手報告・横スクロール区画)。幾何の段は FM の有無に依らず
`falsePositiveCheck` の下で効く(`StepExecutor.visibilityGuardActive` が唯一の入口。FTRuntime の
保持値の高速経路もこれを見る)。
**launch 直後の未描画画面は「覆い」と見分けられない**(2026-09-03): `restartApp` / `launchApp` は
木が引けた時点で戻るので、a11y の木は新インスタンスの要素を返しているのに画面はまだ
launch storyboard(全画素同一)ということが起きる。負荷の高いランナーでは描画が既定の待ち窓に
間に合わず、occlusion-guard が**正しく**「見えていない」と言って赤になる(実測: crop 265x100 が
全画素 (255,255,255))。そこで launch 系コマンドの直後だけ `StepExecutor.firstFrameGatePending` を
一度きり立て、**最初に FM の可視性判定が返った回**で消費する(可視でも消費 = 描画済みなら猶予は
要らない)。不可視かつ crop の `RegionInk.luminanceStdDev` が **`StepExecutor.firstFrameBlankStdDevCeiling`
(= 1.0。8-bit 輝度の量子化1段階未満 = ディザ・圧縮の揺らぎしか無く構造が無い、の定義であって
調整値ではない)未満**なら、そのステップの deadline を
**一度だけ**同じ式(`step.timeout ?? FlowStep.defaultWaitSeconds`)で延ばして待ち直し、
`first-frame-pending` を立てる。延ばしても一様色のままなら従来どおり赤にして `first-frame-timeout`
を添える。**通る経路は増やさない**(flip は返し続ける) —— 変えるのは待つ長さだけなので、
誤った緑は1つも作らない。**厳密 0 では本番の crop に効かなかった**(2026-09-04 のフル E2E で
M1Max の launch storyboard は min=253 / max=255 = stdDev ≈ 0.1 で猶予が一度も付かず赤。
`nearBlankPNG` の対照と、上限をリテラルで固定するテストで縛る)。**stdDev は Tier-1 のインク足切りを通らない経路(幾何が疑い有り・閾値 0)
では未計算**なので、門が開いている回だけ測り直す(この取りこぼしは実装直後のレビューで見つけた)。

**FM 判定の控え `VisibilityVerdictMemo`**(2026-09-04): occlusion-guard の FM 判定を、
**FM への入力そのもの**(スクショのバイト列の hash・frame・screen・期待文字列)を鍵に控える。
「読む回数を減らす」変更なので、2回目の読みが担っていた砦を列挙した —— ①画面が変わった
(→ バイト列が変わり鍵が外れるので控えは効かない)②要素が動いた(→ frame が変わり鍵が外れる)
③期待値が違う(→ 鍵が外れる)④FM の死活・ブレーカの回復(→ nil は控えないので次は必ず訊く)。
残るのは「同じ画像・同じ領域・同じ文字列に FM が違う答えを返す」だけで、FM は同一画像に
決定的(92_screenLooksLike の実測)なのでそこに砦は無い。**控えは直近のスクショ1枚ぶん**
(バイト単位で変わった瞬間に丸ごと捨てる = 上限の定数を置かない)。効く場面は `select(...).textIs(...)`
のように同じ要素を続けて確かめる書き方 —— textIs が保持値を再検証するのは「検査を静かに消さない」
ための設計(FTRuntime の保持値の高速経路)で、控えはその検査を**同じ答えで**満たすだけ。
起点: E2E-iOS ジェスチャ S0010 は FM 60 回中ほぼ半分がこの重複で、M1Ultra(vision ≈ 2.6s/回)では
158s = 180s の予算超えで kill された(FM の遅さは M1Ultra の性質で、09-01 から同じ)。

`FMHealth`(Sources/FTCore/FMHealth.swift)が呼び出しの回数・レイテンシ・成否を計上し、
実行後に stderr へ警告する。結果 JSON の `fm` にも載る(performance-tuning.md §4.2)。
**これは理論上の話ではない**: 実績値では 6066 呼び出し中 5673 失敗(93.5%)で、
成功を含む run は 582 中 58 しかない。**E2E の「緑」は基本的にツリー一致の緑**であり、
視覚検証を含むとは限らないことを前提に読むこと(切り分け手順は docs/verification.md)。

**全 FM 呼び出しは `FMGate.enter()` を通す**(Sources/FTCore/FMGate.swift)。
①サーキットブレーカ(FM は累積 20〜30 回で死に再起動まで回復しないので、連続 3 回失敗したら
以後呼ばない)②ホスト単位の許可枠(`FMLock`。FM はホスト全体で共有される資源で、既定5枠。
詳細と実測は performance-tuning.md §3.5)の順に見る。
**新しい FM 呼び出しを足すときは必ずここを通す**(監査点を 1 つに保つのが目的)。
なお**ロックの有無自体は全滅の防止には効果が無いことが実測で確認済み**(残しているのは p50 が
下がるため。経緯と対照データは docs/verification.md)。

### 1.2 3B モデルに合わせた基本方針: 決定的な再生 + 失敗時のみ FM 介入

小さいモデルに毎ステップ判断させ続ける自律エージェント型は、コンテキスト溢れと
判断ミスが蓄積する。本ツールは **ハイブリッド型** を採る:

1. **実行モード**: 保存済みシナリオ(Swift DSL。§10)を FM なしで決定的に再生。
   高速・安定で CI 向き。
2. **失敗時のみ FM が介入**: ロケータ自己修復、スクリーンショット+ツリー差分の
   トリアージ、自然言語バグレポート生成。

(M2 で計画していた、FM がアプリを自律探索してシナリオを自動生成する explore モード
[`fleetest explore` / ExplorerProfile] は廃止済み)

コンテキスト対策の原則:
- アクセシビリティツリーは **圧縮テキスト(set-of-mark 形式)** にして 1 画面ずつ渡す
- セッションは **呼び出し毎に新規作成**し、会話履歴は持ち回らない(§5.1)
- 出力は全て `@Generable` で構造化(自由文を返させない)

---

## 2. 全体アーキテクチャ

```
┌─ macOS ホスト ────────────────────────────────────────────────────┐
│  fleetest CLI / MCP サーバ / VSCode 拡張(共通で fleetest api を呼ぶ) │
│  ├─ FTFoundationModels        : FoundationModels エージェント層               │
│  │   ├─ ReplayAssist      (ロケータ修復・画面検証・トリアージ)     │
│  │   └─ OcclusionVerifier / FMDoctor / ScenarioNamer / TestbaseDrafter │
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
│  FleetestRunnerUITests         │   │  BridgeInstrumentation(常駐)        │
│  (XCUITest 内 HTTP サーバ,    │   │  ├─ QuietWaiter: a11y イベント静穏  │
│   WDA 方式)                   │   │  │   検知で操作応答(固定 sleep 廃止)│
│  └─ XCUIApplication で        │   │  └─ SnapshotBuilder: AccessibilityNodeInfo
│     対象アプリを起動・操作     │   │     直接走査(型語彙を iOS と共通化) │
└────────────────────────────── ┘   └───────────────────────────────────┘
```

**`AppDriver` プロトコル**が唯一のプラットフォーム境界。iOS ブリッジ(Runner/)・Android
ブリッジ(AndroidRunner/)・InApp ブリッジは共通コア 13 エンドポイント(status/session/
snapshot/tap/type/clear/pressEnter/swipe/press/doubletap/pinch/screenshot/terminate)を
共有しつつ、XCUITest は drag/appswitcher/home/hidekeyboard/appstate/rotate を追加した19、
Android は locale/settle を追加した15、InApp は hidekeyboard/appstate/rotate を追加した16
という差分がある(唯一の正は §4.3 の表 = `Tests/FTCoreTests/BridgeContractTests.swift`)。
`FTFoundationModels` / `FTCore` / `FTDSL` はプラットフォーム非依存のまま両OSで動く
(ブリッジ設計の詳細は §4、Swift DSL の詳細は §10)。

```swift
// 抜粋(全定義は Sources/FTCore/AppDriver.swift)
protocol AppDriver {
    func status() async throws -> StatusResponse
    func install(packagePath: String) async throws       // .app / .apk
    func launch(bundleID: String) async throws
    func snapshot() async throws -> SnapshotResponse     // 圧縮済みツリー
    func tap(ref: Int) async throws
    func tap(x: Double, y: Double) async throws
    func type(ref: Int?, text: String) async throws
    func swipe(_ direction: FTSwipeDirection) async throws
    func screenshot() async throws -> Data               // PNG
    func terminate() async throws
    // ほかに uninstall / activate / openAppSwitcher / home / back / clearInput /
    // hideKeyboard / clearAppData / openURL / pressEnter / drag / press /
    // doubleTap / pinch / rotate / snapshot(bypassingCache:) / isAppForeground 等
}
```

未対応ドライバ(InAppDriver/SystemUIDriver 等)は activate/openAppSwitcher/home/drag/
座標 press にデフォルト実装(launch へのフォールバック、または 501 エラー)が用意されている
(Sources/FTCore/AppDriver.swift)。

---

## 3. リポジトリ構成

```
foundation-tester/
├── Package.swift                  # CLI とライブラリ (macOS 26+。視覚系のみ 27+)。マーカー区間にプロジェクト毎の
│                                  # executableTarget を自動生成(§11。fleetest project create/sync)
├── Sources/
│   ├── fleetest/                   # CLI エントリポイント(+ ProjectCommands / ProfileRunner / Api*Command)
│   ├── FTCore/                    # AppDriver, StepExecutor, ScenarioHost, RunOrchestrator,
│   │                              # TestProject / RunProfile / LocalConfig(§11)。
│   │                              # セレクタ文法(FTSelector)・コマンド索引(CommandIndex)・
│   │                              # コード生成(ScenarioCodeGen)もここ = DSL ランタイム非依存
│   ├── FTRemote/                  # SSH ディスパッチ・ランナー登録簿・dispatch.lock・占有(docs/remote-runner.md)。
│   │                              # 利用側は fleetest CLI だけ = 受け手のシナリオ実行バイナリにはリンクしない
│   ├── FTDSL / FTDSLMacros/       # Shirates 風 Swift DSL とマクロ(§10)。
│   │                              # コマンド本体・FTRuntime・下書き生成(ScenarioDraftCodeGen)
│   ├── FTScenarioRunner/          # fleetest-scenarios-<project> の CLI 実装
│   ├── FTFoundationModels/                   # FoundationModels: プロファイル, @Generable 型, Tools
│   ├── FTBridgeClient/            # iOS ブリッジ HTTP クライアント + SimulatorCatalog / BridgeProvisioner
│   ├── FTAndroid/                 # AndroidDriver + AndroidBridge / AndroidDeviceCatalog / ProfileWorkerFactory
│   └── fleetest-mcp/               # MCP サーバ(stdio、自前実装)
├── Runner/                        # xcodegen 定義 + iOS ブリッジ本体
│   ├── project.yml                #   xcodegen 用プロジェクト定義
│   ├── FleetestRunnerApp/          #   空のホストアプリ(UIテストの器)
│   └── FleetestRunnerUITests/      #   HTTP サーバ内蔵の常駐 UI テスト(§4.1〜4.2)
├── AndroidRunner/                 # Android ブリッジ本体(§4.5。詳細は AndroidRunner/README.md)
│   ├── src/com/example/ftbridge/  #   BridgeInstrumentation / QuietWaiter / SnapshotBuilder 等(Java のみ)
│   ├── build.sh                   #   prebuilt/ftbridge.apk の再ビルド
│   └── prebuilt/ftbridge.apk      #   同梱 prebuilt APK(初回操作時に自動インストール)
├── TestProjects/                      # テストプロジェクト(§11)
│   └── SampleApp/
│       ├── profiles/              #   実行プロファイル(apps / machines / runs)
│       ├── scenarios/             #   Swift DSL シナリオ(SPM ターゲットの path)
│       ├── docs/testbases/        #   テスト設計の元資料(仕様・観点)。シナリオの根拠
│       ├── reports/               #   実行レポート出力先(プロジェクト別)
│       └── .fleetest/              #   ヒールキャッシュ等(プロジェクト別)
├── Scripts/bench.swift            # 計測基盤(§9。詳細は docs/performance-tuning.md)
├── E2EAppCMP/                     # 自己 E2E の SUT: Compose Multiplatform(→ TestProjects/E2E-CMP)
│   └── docs/ui-contract.md        #   **全 SUT 共通の画面・#id・ラベル契約(唯一の正)**
├── E2EAppIOS/                     # 自己 E2E の SUT: SwiftUI + 一部 UIKit(→ TestProjects/E2E-iOS)
├── E2EAppAndroid/                 # 自己 E2E の SUT: View/XML + 一部 Compose(→ TestProjects/E2E-Android)
├── E2EAppFlutter/                 # 自己 E2E の SUT: Flutter(→ TestProjects/E2E-Flutter)
├── E2EAppRN/                      # 自己 E2E の SUT: React Native(→ TestProjects/E2E-RN)
│                                  #   各 SUT の docs/ui-contract.md には**型語彙と固有の罠だけ**を置く
├── SampleApp/                     # 検証用の小さな SwiftUI デモアプリ(テスト対象)
├── vscode-fleetest/                # VSCode 拡張。UI 入口はここに一本化(旧 fleetest-gui は 2026-07-10 削除)
└── docs/design.md                 # 本書
```

---

## 4. アプリ操作ブリッジ(自作)設計

WebDriverAgent と同じ原理を最小構成で自作する(iOS)。Android にも同じプロトコルで
話す常駐ブリッジを実装しており(§4.5)、`AppDriver` の実装が両OSで揃っている。

### 4.1 常駐のしくみ

- `FleetestRunnerUITests` に終わらないテスト `testRunServer()` を 1 本だけ置く。
  テスト内で HTTP サーバを起動し、`RunLoop.current.run()` で常駐。
- 起動手順(CLI が内部で実行):
  1. `xcodebuild build-for-testing -project Runner/FleetestRunner.xcodeproj
     -scheme FleetestRunner -destination 'platform=iOS Simulator,name=iPhone 17'`
  2. `xcodebuild test-without-building -xctestrun <derived>.xctestrun ...`
     (環境変数 `FT_PORT=8123` をテスト環境に渡す)
- シミュレータはホストとネットワークスタックを共有するため、テスト内で
  `127.0.0.1:8123` に listen すればホストの `localhost:8123` から直接届く。
  ポート番号は CLI が空きポートを選んで環境変数で注入する。
- **無通信 TTL(2026-07-30)**: 最終リクエストから `FT_BRIDGE_TTL` 秒(既定 7200・`0` で無効)
  無通信のブリッジは自主終了する(iOS/Android 共通。忘れられたゾンビのデバイス占有防止)。
  心拍は**全リクエスト**(/status 含む)なので、モニターのポーリングが続く限り失効しない。
  既定値の定義は `BridgeAPI.bridgeTTLSecondsDefault`(Java 側と `AndroidBridgeVersionSyncTests`
  が同期を検出)。in-app ブリッジは対象外(対象アプリと運命を共にする。ゾンビ対策は
  provision の reclaim 側)。自主終了はホスト側の pid ファイルを消せないため、provision が
  採番前に死んだランナーの pid ファイルを回収する(`BridgeLauncher.sweepStalePidFiles`。
  残すと `assignPort` が使用中とみなし採番がドリフトする)。
- **実機の自動ロックは端末側で切る(2026-09-05 ユーザー決定)**。実機は run の待ちの最中に
  自動ロックされ、以後の launch が `denied by SBMainWorkspace ... reason: Locked` で拒否されて
  run ごと死ぬ。**ツールは起こさない** —— **設定 → 画面表示と明るさ → 自動ロック → なし**に
  しておくのが実機を使う前提。
  **かつてはランナーが 25 秒ごとに `press(.home)` を撃っていた(版 81〜88)が、廃止した**:
  合成した入力は実機では本物の HID で、無害だという前提が OS の版で反転する
  (iOS 26.5.2 では SpringBoard に届かず、26.6 では届いて**対象アプリが run の途中で
  ホーム画面へ落ちた**)。端末の画面設定は端末の持ち主が決めるものなので、ツールが
  入力を合成して覆すのをやめた。
  ホストから自動ロック設定を書き換える手段は無い(`devicectl device settings` は
  appearance/audio/biometrics/voiceover だけ)ので、**設定するのは人**。
  ロックされたまま起動しようとした場合は `IOSPhysicalDeviceLock` と
  `IOSDeviceTransport.blockingCondition` が名指しで止める。
  処理中(`inFlight > 0`)は撃たない(accept スレッドと XCUITest を同時に叩かないため)
- **容器推定は scrollable 申告の祖先を優先する(2026-08-23)**: `StepExecutor.clippingContainer` は
  「同じ深さの子を2つ以上持つ直近の祖先」を容器とみなす規則(Compose iOS は xcuitest で scrollable を
  申告できないための近似)だが、申告のある木ではそれが**カード**を容器に選ぶ(カルーセル > カード >
  ラベル+バッジ)。クリップするのはカードではなくスクロール容器なので、祖先の連鎖に
  `scrollable == true` があれば最も近いそれを正とする(`nearestScrollableAncestor`)。申告の無い木は
  従来どおり。見切れ判定・回復ドラッグ・タップの座標補正・ghost 判定・MCP の RefGuard が同じ関数を
  使うので、変えるときは 5 SUT のフル E2E で退行を見る(受け手の最小再現: 横カルーセルの右縁で
  見切れた項目への `exist(scroll: .right)` がカードを viewport にして送れず not-found になっていた)。
  **同じ最小再現で見つかった第2の穴**: 見切れ回復の `slowDrag` とヒント跳躍の `hintDrag` が
  `driver.drag` を直に呼んでいて、in-app エンジンは drag を実装しない(501)ので失敗扱い → 全画面
  スワイプに落ちていた = **利用者の既定 hybrid では見切れ回復のドラッグが一度も出ていなかった**
  (MCP は `HybridFallbackDriver` が drag を転送するので `ft_scroll_to` は同じ画面で通った。
  run と MCP で結果が割れたらドライバ合成の差を疑う)。座標ドラッグは
  `StepExecutor.dragWithFallback` が唯一の入口(501 → typeDriver へ latch。空打ち emptyDrag と同じ規律)
- **起動前にポートの LISTEN 実体を確かめる(2026-08-23)**: `scanRunningBridges` は /status 応答で
  稼働中を数えるが、in-app ブリッジは注入先アプリが背面だと TCP は受け付けて HTTP に答えない
  = ポートを掴んだまま「空き」に見える(全シミュレータはホストの loopback を共有するので
  ポートは台を跨いで一意)。`executeBridge` は記録の有無に関わらず `PortHolder.stopIfOwnedBridge`
  で占有者を確かめ、自分たちの資産(シミュレータ内アプリ・残骸ランナー・iproxy)なら止め、
  無関係なら in-app は撃たずに `portInUse` で名指しして落とす。旧ブリッジの停止手段は
  `StaleBridgeStop.decide`(.inapp 記録 → simctl terminate / .pid → ランナー停止 / 記録無し →
  PortHolder)。`.inapp` の記録は ready 待ちの**前**に書く(中断で記録の無い残骸を作らない)。
  切り分けは docs/verification.md「never joined」の節
- **登録の無いシステムアラートも黙らない(2026-08-23)**: `SystemUIGate` の毎ステップ判定は
  `iosAlertHandler` の登録がある間だけ(費用を登録した人だけが払う。0ec9b245)。登録漏れは
  人為ミスとして起こり続けるので、**launch 系の直後の最初の触る操作**と**ステップの失敗時**に
  限って1回 `GET /systemalert` を聞き、前面にあれば注記 `system-alert-present` と文言(題名・
  ボタン)を残す。止めない・閉じない(新しい検知は警告から。閉じるのはシナリオの責務)。
  失敗文言に題名が出るので、時間切れの仕分けが「アラートだった」で即決まる。**MCP も同じ形**
  (2026-08-31): `ft_launch` / `ft_open_url` / `ft_install` / `ft_clear_app_data` の直後の**最初の
  `ft_snapshot` で1回**、`ft_tap` の ref 照合では毎回聞き、前面にあれば題名・ボタンを名指しして
  SpringBoard へ attach する手順を出す(SpringBoard に attach 中は出さない)。判定は `SystemUIGate` の1箇所
- **起動元の自己申告と doctor の刈り取り(2026-07-30)**: 3ブリッジとも `/status` で起動元
  (`ownerRepo`。iOS xcuitest はホスト上で停止できる `ownerPid` も)と直前の無通信秒数
  (`idleSeconds`)を申告する(注入経路: xctestrun 環境変数 / `-e owner` / SIMCTL_CHILD)。
  doctor は管理外ブリッジの処遇を `UnmanagedBridgeTriage`(唯一の判定者)で決める:
  **自動停止は「自リポジトリの旧版」「起動元リポジトリが消滅した確定ゾンビ」の2行だけ**。
  実在する別ワークスペースの所有物と起動元不明(旧ブリッジ)は報告のみ(他人の資産を殺さない)。

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
| `POST /swipe` | `{direction}` or `{fromRef, direction}`。用途つきの任意項目あり(下記「スクロールの語彙」) |
| `POST /press` | `{ref, duration}` または `{x, y, duration}` 長押し |
| `POST /doubletap` | `{ref}` または `{x,y}`。**2回の /tap では代用できない**(往復で OS のダブルタップ判定時間を超える) |
| `POST /pinch` | `{scale, frame?, identifier?, durationSeconds?}` 2本指ズーム。**対象の指定が経路で違う**ので両方を運ぶ(Android と in-app は `frame` の中心で合成・XCUITest は座標指定の多点ジェスチャを持たず `identifier` で要素を引く) |
| `POST /clear` | `{ref}` 省略可(省略時はフォーカス中の入力欄)。入力欄のクリア |
| `POST /pressEnter` | Return キー相当(受け口ごとの機構は §10) |
| `GET  /screenshot` | `XCUIScreen.main.screenshot()` → PNG |
| `POST /terminate` | 対象アプリ終了 |

上記13個は3実装共通のコア。差分は次のとおり(**唯一の正は
`Tests/FTCoreTests/BridgeContractTests.swift` のルート表**。ここはその写し):

| ブリッジ | 共通コアへの追加 | 計 |
|---|---|---|
| XCUITest(Runner/) | `POST /drag`・`POST /appswitcher`・`POST /home`・`POST /hidekeyboard`・`POST /appstate`・`POST /rotate`・`GET /hittable`・`GET /systemalert`・`GET /systemui/covering`・`GET /systemui/snapshot`・`POST /systemui/tap`・`POST /systemui/drag`・`POST /systemui/swipe` | 26 |
| Android(AndroidRunner/) | `POST /locale`・`POST /settle`(§4.5) | 15 |
| InApp | `POST /hidekeyboard`・`POST /appstate`・`POST /rotate` | 16 |

`/hidekeyboard` は iOS の2実装だけが持つが、**中身は 501 を返すだけ**(iOS に実装手段が無い。
§10「キーボードの観測と `hideKeyboard`」)。Android は `hideKeyboard` をホスト側の
戻るキーで実現するのでルートを持たない。

`/systemui/*` は XCUITest ランナーだけが持つ、SpringBoard(別プロセス)を読む・叩く口。
**`POST /session springboard` + `GET /snapshot` との違いはセッションを触らないこと**だけで、
返る木は同じ。ref は専用の名前空間(ランナーの `systemRefFrames`)に振り、
`app` / `sessionBundleID` / `refFrames` のどれにも書かない。

`POST /systemui/drag` / `POST /systemui/swipe` は**座標の原点を SpringBoard に取る**ジェスチャ
(`POST /appswitcher` / `POST /home` と同じ理由)。呼び手の `tapAppIcon` は直前に `home()` を
撃っているので、セッションのアプリを原点にする `/drag`・`/swipe` では、**背面なら**座標解決が
`Find the Application` を約45秒リトライして**ランナーごと落ち**、**未起動なら** `requireLiveApp`
の 503 で弾かれる。逆に `/tap` 側を SpringBoard へ寄せてはいけない —— あちらの 503 は
「アプリが死んでいる」の申告で、ホストが復帰の判定に使っている。

ref を引く表が2つあるので、**呼び手は直前に撮った木と同じ名前空間の口だけを叩く**。
`SystemUIDriver` は scoped で撮った回の ref を `/systemui/tap` へ回し、座標へ落とせない
操作(`type` / `clearInput` —— ランナーが要素そのものを引いて読み返す)は 422 で断る。
素通しすると**両方の名前空間が 1 から採番される**ため、番号がアプリ側の `refFrames` で
引き当たり、システム UI を操作したつもりで無関係なアプリの要素へ届く。

**なぜ要るか**(2026-08-25): `engine=xcuitest` は**ブリッジが1本しかなく、主ドライバと
共有している**。旧経路はセッションを springboard へ移し ref 表を空にするので、権限アラートを
閉じた次のステップが SpringBoard の木を読んで `cannot resolve the locator` で落ちた
(E2E-iOS の `16_システムアラート.swift` で実測)。hybrid はフォールバックが別ブリッジなので
巻き添えが無く、旧経路のままでも正しく動いていた —— **同じホストのコードが、エンジンによって
壊れたり壊れなかったりしていた**。ホスト側で「見た後に張り直す」ことでも塞げるが、
戻し忘れが**次のステップで**沈黙して失敗する形になるため、ブリッジ側に不変条件を置いた。

**アラートの有無で撮る/撮らないを分けない**: この口はホーム画面の走査(`tapAppIcon`)にも使う。
SpringBoard は system shell なので背面に回らず、`requireForegroundApp` が防いでいる
「背面アプリの木を読むとランナーごと落ちる」形には当たらない。

旧ランナー(版 < 79)は 404 を返し、`SystemUIDriver` が旧経路へ落ちる。

`POST /rotate` は iOS の2実装だけが持つ(`{orientation}` → 整定後の実際の向き、整定しなければ
`422`)。Android は adb(`AndroidDriver`)で直接行うためルートを持たない。

**回転の契約は「アプリの UI がその向きになること」**(2026-08-10 ユーザー決定)。デバイスがどう
傾いているかではない —— テストが観測できる frame と画面サイズは、iOS も Android も、
Compose / SwiftUI / View-XML / Flutter / React Native のどれでも**アプリ座標系**で返る
(PoC で全部実測)。跨いで同じ意味を持つのはここまでなので、**語彙は portrait / landscape の2値**に
限る。`landscapeLeft` / `landscapeRight` は**置かない** —— 物理的な左右はテストから観測できず、
どう定義しても検証できない。実際、置いていた間は **iOS が厳密に一致を求める一方 Android は
「窓が横長か」しか見ておらず、同じ `.landscapeRight` の要求が Android では左横向きでも成功していた**。
検証できない区別を語彙に置かない。
実装上の帰結: 各ブリッジは**要求をどちらか一方の landscape へ写し、読みでは左右をまとめる**
(片側しか landscape と認めないと、OS がもう一方を選んだ回に整定が永久に一致せず 422 になる)。
Android の整定判定は**スナップショットの画面サイズ**で行う = 表示だけ回ってアプリが縦のままの形を
成功にしない。

**エラーの status はホスト側の分岐に使われる契約**(ブリッジ実装とホストで同期が必要。
`DriverError.isEngineIncapable` / `AppAttachDriver` / `SessionRecoveryDriver`):

| status | 意味 | ホストの反応 |
|---|---|---|
| `501` / `404`(本文 `not found:`) | このエンジンでは**原理的に不可** | XCUITest へフォールバック(§10 の「in-app で不可・XCUITest で可」) |
| `404`(ref 不明) | スナップショット取り直しが要る本物の失敗 | 失敗(フォールバックしない。本文前置で 501 系と区別) |
| `409` | 一時的競合(キーウィンドウ不在・セッション消失) | セッション消失だけ `SessionRecoveryDriver` が張り直す。**フォールバック判定に使わない** |
| `422` | セッションはあるが**今のこの画面では実行できない**(フォーカス欄が無い・クリアしきれない・type の読み返しが期待値に届かない・**中身のあるマスク欄への追記**) | 失敗。`clearInput` だけ 409 と同様に typeDriver へ回す(`isClearInputFallback`) |
| `503` | セッションはあるが**対象アプリが起動していない** | `AppAttachDriver` が activate して1回再試行 |

**XCUITest ランナーは 409 を `requireApp()` の1箇所からしか投げてはいけない**(`SessionRecoveryDriver`
がこの経路の 409 を無条件に「セッション消失」と読み、activate を撃つため)。同じ「今は無理」を
表したいときは 422 を使う。in-app ブリッジは逆に 409 を一時的競合へ広く使ってよい
(あちらは `SessionRecoveryDriver` で包まれない)。2026-07-31 に `handleClear` が 409 を足して
この不変条件が破れ、clearInput の正当な失敗が「ランナーが再起動した可能性」と誤報告された
(実害)。以後 `BridgeRouterStatusContractTests` が 409/503/501 の本数を数えて守る

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
- 目標: 一般的な画面で **300〜800 トークン**。上限は `BridgeAPI.maxSnapshotElements`(120)で、
  超過分は `(+12 elements truncated)` と件数だけ出す。**打ち切りは描画の省略ではなく
  配列そのものからの脱落**なので、`waitFor` も `scrollTo` も打ち切り後しか見ない
  (だから MCP の失敗文は打ち切りを名指しする。`MCPServer.truncationHint`)。
- **呼び手が1回だけ上限を引き上げられる**(版 65。`GET /snapshot?max=<n>` / MCP は
  `ft_snapshot maxElements:`。天井 `BridgeAPI.maxSnapshotElementsCeiling`=400、
  解釈は `resolvedSnapshotElementLimit` の1箇所 = ホスト・3ブリッジで同じ規則)。
  **一発限り**にするのは、上げたままだと以後の整定ループ・探索の各周回まで重い木を引くため
  (`AppDriver.raiseElementLimitOnNextSnapshot`。**ラッパードライバは転送必須**)。
  なぜ要るか(2026-08-12・ブラウザ監査の実測): web ページは広告リンクだけで tier0 が枠を埋め、
  間引きは tier1(ラベル付きの本文)から捨てるので、**画面に写っている表の行が丸ごと消える**。
  tenki.jp の2週間天気では 248 候補中 128 件が脱落し、**その全部が labelled** ——
  `ft_scroll_to` が落ちた行を探して2回で 101 秒を空費した(`maxElements: 400` なら1回で全行入る)。
  **間引きの優先度そのものは変えない**(同じ規則がネイティブのリスト行にも当たるため。
  却下履歴は `BridgeSnapshotThinning.bulkGroupMinimum` のコメントと同型)。
- **探索中の打ち切りは最終木からは分からない**: 目的の行が画面に入っていた周回で上限に
  当たっていても、通り過ぎた先の最終画面が上限内なら注記は黙る。`ScrollSearchResult.
  maxTruncatedDuringSearch` が周回ごとに記録し、失敗した探索だけ `StepNote.truncatedDuringSearch`
  として運ぶ(MCP はこれで「不在の証拠にするな」と言う)。
- **DSL の否定判定も上限を上げる**(2026-08-15)。上限は**読み手が読み切れる量**として決めた値
  なのに、読み手の居ないシナリオ実行が同じ木で「不在」「件数」を結論していた ——
  間引かれた要素は木の上で存在しない要素と1文字も違わないので、`notExist`/`countIs` が
  **黙って誤った成功**になる(`StepExecutor.retakenAtElementLimitCeiling`)。規律は3つ:
  **①切り詰められた木で不在を結論しない**(天井まで上げて撮り直す)/
  **②一度当たったらこの検証の残りも天井で撮る**(`needsCeiling` の latch。毎周2枚払わず、
  判定に使う木が常に天井のものになるので失敗文言が嘘にならない)/
  **③天井でも足りなければ「判定不能」で落とす**(「見つからない」と言わない。
  送られていないだけの要素を「無い」と報告するのがこの欠陥そのもの)。
  探索中の打ち切り(上記)も同じ理由で `notExist(scroll:)` を通さない ——
  通り過ぎた画面の木はもう手元に無く、撮り直しでは救えないため。
- **間引きは優先度順**(2026-08-07。ここは長く「hittable 優先」と書いてあったが、実装は
  両 OS とも先着順だった)。低い帯から順に、**同じ帯の中では preorder の後ろから**捨てる。
  **並べ替えはしない** —— `RefGuard.lineage` が preorder+depth でツリーを復元し、
  ref の大小を z-order の代理に使うため:

  | 帯 | 中身 | 捨てる順 |
  |---|---|---|
  | tier2 | ラベルも identifier も持たない | 最初 |
  | tier3 = bulk | 同一 identifier が20件以上・非操作(自身が scrollable なら除く) | 2番目 |
  | tier1 | ラベルか identifier を持つ | 3番目 |
  | tier0 | 操作可能(clickable/入力欄など)か scrollable な容器 | 最後 |

  **tier2 を bulk より先に捨てる**(2026-08-08 に変更。旧順は bulk が最初だった)。
  ラベル付き同一 identifier 群(bulk)は、ラベルも id も無い装飾(tier2)より本物のコンテンツ
  である見込みが高いので、超過時は装飾から削る。POI 洪水のような大群の捲れは、tier2 が
  少ない画面では次に bulk が捨てられるので従来どおり保たれる。

  **bulk に「スクロール容器の外」という条件は置かない**(2026-08-08 に撤廃)。Apple マップの
  地図 POI(`id=VKPointFeature` ×67〜77、画面により変動)は地図=スクロール容器の中に居るため
  旧条件では bulk を素通りしてラベル付き tier1 になり、**preorder 前方(地図は木の先頭)に
  居るため同 tier 内では最後まで残って**、後方のカード内容から先に落ち、経路画面で 84 件の
  切り詰めを起こした。ラベルの異同は条件に入れない(同一 id ×20 はそれ自体が「塊」の証拠)。**scrollable な要素はどの帯でも捨てない**(cap 免除。容器が
  木から落ちると scrollFrame 解決が全滅する — 下記「scrollFrame の fail-fast」)。
  **この cap 免除は Swift 側(iOS の xcuitest ランナー・in-app dylib・WebView DOM マージ)だけが持つ**。
  Android の `SnapshotBuilder`(Java、tier0〜2 のみ)は tier0 を最後に捨てる点は同じだが、
  scrollable の cap 免除は持たない。また Compose/Flutter を xcuitest エンジンで撮った木は
  スクロール容器が `.other` として出て `scrollable` を申告できず(in-app なら申告できる)、
  この免除には最初から乗らない。

  - 規則の定義元は **`BridgeSnapshotThinning`(`Sources/FTCore/BridgeDTO.swift`)**。
    XCUITest ランナーと in-app dylib が共有する。**Android は Java で書けないため
    `SnapshotBuilder.selectByPriority` に個別実装**していて、**tier3 だけ持たない**
    (下記のとおり Android では発火しなかったため。足すときは Swift 側を正として写す)
  - 先着順だと落ちるのは preorder 末尾で、**害の形は OS で違った**。Android(Material)は
    app bar と FAB が末尾に出るので**戻るボタンが画面に出ているのに木から消える**
    (実測: 発車一覧が 142 要素で `#nav_button` が引けない)。iOS は chrome が木の前方なので
    残り、代わりに**詳細シートの中身**が落ちる
  - **tier3(bulk)は iOS のために足した**。Apple マップの打ち切り画面は tier2 が 0 件で、
    枠の 75% を同一 identifier の装飾ピン(`id=VKPointFeature` ×90)が占めるため、
    tier0〜2 だけでは中身が落ち続けた。**スクロール容器の中の大群(=長いリスト)は降格しない**
    のが誤検知よけで、この判定は**生のツリーの再帰でしか採れない**(容器自体は identifier が
    無いとフィルタで落ちるので、出力済みの配列から親を辿ると正当なリストを bulk と誤る)
  - 誤検知の確認は**コーパス14本**(iOS/Android・2種の地図アプリ・4 SUT の実画面)で全数。
    発火は狙いの `VKPointFeature` ×90 の1件だけで、**Android は1画面も発火しなかった**
    (Google マップを含む)
  - **打ち切りは「何件」ではなく「何が」落ちたかを申告する**(2026-08-09。
    `SnapshotResponse.truncatedTiers` / `BridgeSnapshotThinning.droppedByTier`。版60)。
    実測(Apple マップの経路プランナー): 候補 211 件のうち **91 件が脱落**し、残った 120 件の
    **56% が地図の POI** だった。ここで「間引きの方針が妥当か」を議論しようとしたが、
    `truncatedCount` は件数しか言わないので **落ちた 91 件が飾りなのか操作要素なのかを
    ホストから知る手段が無かった**(残った側しか届かないため、後から再構成もできない)。
    そこで捨てた本人が tier ごとの内訳を申告する。キーは番号ではなく語彙
    (`operable` / `labelled` / `decoration` / `bulk`)—— 番号を外へ出すと、捨てる順を変えた
    瞬間にホストの表示が嘘になる。**iOS の2ブリッジだけが申告する**(Android の
    `SnapshotBuilder` は tier3 を持たず語彙が揃わない。tier3 が iOS 限定なのと同じ理由)。
    ホストは `ft_snapshot` / `ft_scroll_to` の**先頭 note** で出す —— `(+91 elements truncated)`
    は 120 行の一覧のいちばん下にしか出ておらず、いちばん重い事実がいちばん読まれない位置にあった。
    **捨てる順(tier)自体はまだ変えていない**: 上の 91 件が何だったかは、この申告が入った
    ブリッジで採り直してから判断する(見積りで順序を触らない)
  - **打ち切りに掛からなくても、大群は読む側の邪魔になる**(2026-08-09)。Apple マップの
    1画面は `id=VKPointFeature` が 42〜67 件あり、**一覧の 47〜58% がこれ**で、本物の UI が
    毎回下半分へ押し込まれていた。そこで**描画側でも畳む**:
    `SnapshotRenderer.render(collapsingBulk:)` が「同一 id が `bulkGroupMinimum`(=20。
    ブリッジの bulk tier と同じ値)以上・すべて `other` の葉・非スクロール」群を
    **見出し1行 + 「ラベル[ref]」の索引**に畳む。**frame は落とすが ref は全件残す**
    —— 実測で `#VKPointFeature` の ref タップは場所カードを開くので、消してはいけない。
    **印(⚠️scroll-leftover 等)が付いた要素も畳む**(2026-08-10): タップ時に RefGuard が
    改めて警告するので、snapshot 時点の個別列挙は冗長 —— 地図 POI 231件中40件が印付きという
    だけで出力の半分を個別行が占めていた。見出しに旗ごとの件数を添える
    (`38 ⚠️scroll-leftover, 1 ⚠️offscreen among them`)。`ghostNote` の先頭注記も畳まれた ref を
    個別列挙せず、`(+N folded into the ×M id=… line below)` で件数だけ言う(判定は render と
    同じ `SnapshotRenderer.foldedGroups` を共有し、二重実装を避ける)。
    `ft_snapshot` は既定で畳み `expandBulk: true` で全行に戻す。`ft_scroll_to` は常に畳む
    (答えは「探した1つがどこに居るか」なので大群を並べる意味が無い)。**間引き(ブリッジ)と
    畳み(描画)は別物** —— 前者は配列から消し、後者は見せ方を変えるだけ
  - **注記も同じ理由で畳む**(2026-08-12 の実アプリ監査)。減らすのは2形だけ:
    ① **記号だけのラベルは曖昧ラベル一覧に出さない**(`MCPServer.isSymbolOnlyLabel`)——
    実測(Google マップの経路詳細)では区切りの `" · "` ×3 が代替セレクタ付きで注記の上位を
    占めていた。**飾り葉フィルタ(`isDecorativeLeaf`)を広げて対応しない** ——
    あちらは `type == "other"` の判定で、staticText まで飾り扱いにすると見出しや値という
    正当なセレクタ対象が消える。判定は「Unicode の英数字(L\*/N\*)を1文字も含まない」で、
    仮名・漢字も語に含める。② **leftover / offscreen の注記は最外の行だけ名指す**
    (`MCPServer.outermost`)—— 実測(Apple マップの経路詳細)では leftover 8 件のうち 7 件が
    先頭行の子孫で、1つのはみ出しを 8 回読ませていた。子孫を撃つときは祖先も必ず同じ状態
    なので安全上の情報は減らず、**行そのものに付く ⚠️ 印は従来どおり全行に出る**
    (落とした件数は `(+N descendant row(s) of these, same flag)` で言う)
  - **bulk 群は要素上限の勘定に入れない**(版 61。2026-08-09)。上限は「読み手が選ぶ対象」に
    使い切らせるためのものなのに、実測(Apple マップの経路手順)では `#VKPointFeature` が
    保持 119 件中 87 件 = 73% を占め、操作可能要素とラベル持ち要素をその分だけ押し出していた。
    `BridgeSnapshotThinning.indicesToKeep` は **bulk を予算から外し**(`bulkExemptCeiling` = 400 の
    安全弁つき)、残りにだけ tier2 → tier1 → tier0 の掃き出しを掛ける。
    **捨てるのではなく外す**ので、ref タップ・SelectorInventory への記録・expandBulk の展開は
    従来どおり効く。件数は `SnapshotResponse.bulkExemptCount` で申告し、ホストは
    「上限を超えているのは異常ではない」と言える(超えた一覧を見て木が壊れていると読ませない)。
    **iOS の2ブリッジだけ**(Android は tier3 を持たないので nil = 従来動作へ縮退)
  - **「畳める群を先に捨てる」は却下**(2026-08-09 に実装して撤回)。動機は実測
    (Apple マップの経路手順で `#VKPointFeature` が **119 件中 87 件 = 73%**)だが、
    **同じ述語はリストの行にも当たる** —— 同一 id ×20 以上の行は普通にあり、群の尾を先に
    落とすと 30 行のリストの 21 行目以降が**無ラベル装飾より先に**消える。
    tier2 → tier3 の順序はまさにそれを防ぐために選ばれており(`BridgeSnapshotThinning`)、
    地図 POI とリスト行を木から見分ける手掛かりは無い(祖先ベースの区別は版 58 で一度失敗済み)。
    **代わりに原因を名指しする**: 打ち切ったときだけ `MCPServer.capHogNote` が
    「`#VKPointFeature` が 119 件中 87 件(73%)」と添える —— 読み手に取れる手は
    「それを描いている物を畳む」だけなので、**方針を変えずに手掛かりだけ渡す**。
    実地確認(2026-08-09・Apple マップ)では、この画面の打ち切り 164 件は内訳が
    **全件 bulk** で、間引き自体は正しく動いていた(仮説だった「本物の UI が押し出される」は
    起きていなかった)
  - **レイアウト専用の行を隠す `interactiveOnly`**(2026-08-09)。`ft_snapshot` の任意引数で、
    「ラベルも値もプレースホルダも持たず、操作可能な型でもスクロール容器でもない」要素を
    描画から落とす(`SnapshotRenderer.isSubstantive`)。実測では Google マップ Android の
    1画面 88 行のうち大半が `#navigation_bar_item_icon_container` `#fab_icon` `#TextStackView`
    のような**子と同じ矩形のレイアウト容器**で、実地確認でも 9〜18 行が消えた。
    **隠すのは描画だけ**(ホストが覚える木は素のまま)なので ref も frame も動かず、
    隠れた行も `ft_tap` で撃てる。**印の付いた行は隠さない** —— 印は行ごとに読ませるためにある
- **比較前の正規化は用途で2つに割れる**(`FTCore/TextNormalization`。2026-08-09 のユーザー決定)。
  求められるものが逆を向いているため、1つの規則では両立しない:

  | | セレクタでフィルタ(`.selector`) | テキストと期待値の比較(`.text`) | `strict` |
  |---|---|---|---|
  | 目的 | **見つける**(寛容に寄せる) | **確かめる**(見た目が一致すれば同じ) | 一切正規化しない |
  | 単独クラスタの不可視文字 | 削除 | 削除 | そのまま |
  | クラスタ内の制御文字(ZWJ・異体字・結合文字) | **残す** | **残す** | そのまま |
  | 空白の種類 | 全部 U+0020 へ | **NBSP だけ**(全角・thin space は別物) | そのまま |
  | 連続空白 / 両端 | 畳む / トリム | そのまま | そのまま |

  **判定は列挙で持たない**: 「そのクラスタが `Cf`/`Cc` だけで出来ていて、かつ White_Space でない」
  なら落とす。単独で立つ不可視文字(ZWSP・BOM・双方向制御・ソフトハイフン・C0)はこれで落ち、
  可視文字と同じクラスタに居る制御文字は残る —— **数え漏らした文字にも自動で効く**。
  例外は**末尾に余った結合子**(ZWJ/ZWNJ)で、繋ぐ相手が無いので落とす。実データの根拠は
  Google マップの `"…中央線\u{200D}\u{FEFF}"`(見た目は `"中央線"` そのもの)。
  異体字セレクタは末尾でも残す(直前の文字の見え方を変えるので繋ぐ相手が要らない)。
  タブ・改行・NEL は分類上 `Cc` だが White_Space なので**消さずに寄せる**
  (順序を逆にすると `"A\tB"` が `"AB"` になる。2026-08-09 にテストで検出)。
  描画(`SnapshotRenderer`)は `.text` を通す —— 印字は「画面で見えているもの」を写すため。
  **アサーション側は 2026-08-09 まで正規化ゼロだった**(素の `==`)ので、ゼロ幅1文字で
  `textIs` が落ちるのに同じ文字列のセレクタは当たる、という経路ごとに答えの違う状態だった。
  `strict: true` は DSL の引数 → `FlowStep.strictText` → `StepExecutor.textNormalization` で届く。
  **不一致の失敗文は「どちらの規則なら一致したか」を必ず出す**(`normalizationVerdict`) ——
  見えない差で落ちたのか本当に違う文字列なのかで、読み手の次の一手が変わる
- **「書けるセレクタ」は1箇所で決める**(`MCPServer.SelectorNaming`。2026-08-09)。
  優先順は **一意な `#id` > 一意なラベル > 型で絞る `.型&&ラベル` >
  スコープで絞る `#容器 >> ラベル` > スコープ記法 `#容器 >> .型[n]` > 書けない(nil)**。
  曖昧ラベル注記(B)と操作系の戻り値(E)と下書き生成(F)が同じ実装を通るので、
  「注記が勧めた式」と「シナリオに書かれる式」が食い違わない。
  **勧める前に自分で引く**: 候補を組み立てただけでは書けているか分からず、実際に
  ラベルを `"…"` で囲んで出していた版は**引用符ごと literal になって1件も当たらなかった**
  (実アプリ 18 枚へ当てて発覚)。`picksExactly` が DSL 本体の `matchDetailed` で解決し、
  当人が返ることを確かめてから返す。**`resolvedCandidates` は使わない** ——
  あちらは `[n]` を適用する前の候補列なので、正しいスコープ記法を「曖昧」と誤判定する
- **索引に落ちる前に絞る**(2026-08-12 の実アプリ監査)。`&&`(AND 合成)と `>>`(スコープ)は
  DSL の記法にあるのに候補に無く、「一意な id も一意なラベルも無い」を即 `#容器 >> .型[n]` へ
  落としていた —— 実測(Google マップの検索候補)では `#typed_suggest_container >> .clickable[3]`
  しか書けず、**候補の件数が変わると別の駅を選ぶ**。新しい2形は位置に依存しないので `.stable`。
  **既存の提案は1件も動かさない**(`#id` と一意ラベルより後ろへ入れる)—— 実アプリ・自前 SUT の
  コーパス 974 要素で確認: `indexed 326 → 157` / `書けない 38 → 18` / **既に stable だった行の
  変化 0 件**。
  **`.stable` を名乗る式は候補が1件だけであること**まで確かめる(`picksOnlyOne`)——
  `picksExactly` は `matchDetailed` の先頭一致を見るだけなので、**曖昧な式でも群の1件目には
  true を返す**。添字なしの新形をそれだけで採ると、1件目にだけ「一意に指せる」と嘘の助言が出る
  (2026-08-12 に既存テストが実際に捕まえた。この検査だけでコーパスの偽提案が 19 件消えた)。
  **`[n]` を含む式には使わない**(`resolvedCandidates` は添字適用前なので必ず複数)ため、
  検査は**綴りではなく耐久性**で選ぶ。スコープの解決規則(`uniqueScopeID`)は
  `.型[n]` 版とラベル版で共有する —— 2箇所に持つと別の容器を指しはじめる。
  **候補は数え上げで足切りしてから検証する**: 候補1つの検証は木2周で、当たらない候補まで
  並べると注記1本の生成が実アプリ画面で **29ms → 116ms** になる(2026-08-12 に実測)。
  「型×ラベル」の出現数は `SelectorNaming.init` の1周で持ち、スコープ内の出現数は
  候補を組む直前に1回だけ数える。**ゲートは取り分を1件も削らない**(コーパスの格付けは
  ゲート有無で完全に同一)ので、増えるのは速さだけ。
  **`=` 逃がしは素で書けない形のときだけ後ろに足す**(`needsEscaping`)——
  順序を入れ替えてはいけない: `asWritten` は逃がしを外した形を返すので、逃がし形を先に採ると
  **注記の文字列と下書きのコードが食い違う**(実測: ラベル `" ·"` で注記 `" ·"`・コード `"·"`)。
  判定は2種類で、**意味が変わる形**(`#`/`.` 始まり・演算子)と**綴りが往復しない形**
  (前後の空白)の両方を見る
- **「書ける」と「壊れにくい」を混ぜない**(`MCPServer.Durability`。2026-08-10)。
  優先順は「書けるか」で並んでいるが、`#容器 >> .型[n]` の `[n]` は**同じ型の兄弟が
  1つ増減しただけで別要素を指す**。無印で同じ一覧に並べると生成器は先頭を採るだけなので、
  **添字付きにだけ印を付ける**(一覧は `~`・単発の戻り値は但し書き・下書きは行末コメント)。
  印を付けるかは**候補の出所**で決まる(`Durability` は候補と一緒に組み立てる)——
  要素側の事情を後から持ち込むと、同じセレクタに対して注記と戻り値で言うことが割れる。
  **綴りで判定しない**: `#容器 >> .clickable` は `[` が無くても位置依存(= 添字付き)で、
  逆に `#容器 >> ラベル` は `>>` があっても位置に依存しない(2026-08-12)。
  どちらも「綴りを見れば分かる」と考えた版が取りこぼした。
  **安定側には何も付けない**: 全行にコメントが付くと読み飛ばされ、危ない行が埋もれる。
  **単発の戻り値の但し書きは初回だけ満額**(`reproductionNote` の `once("indexedSelectorCaution", …)`。
  2026-08-10)。id の薄いアプリ(地図等)ではタップのたび同じ index-based 注意が繰り返され、
  id を足せない他社アプリ相手ではノイズになる。**セレクタ自体は毎回出す**(縮むのは但し書きだけ)
- **下書きは刈り込める**(`InteractionLog.prune`。2026-08-10)。記録は「やったこと」であって
  「意図」ではないので、行き止まりのタップも試し打ちも同じ忠実さで載る。どちらも成功した操作なので
  自動では見分けられず、**番号を見せて選ばせる**(`drop:` / `lastN:`)。
  **番号は絞り込んだ後の並びに振る** —— 一覧を見て選ぶ道具なので、見えている番号と落ちる手が
  一致していなければ意味がない。範囲外の指定は**黙って無視せず**警告する(番号を1つ外しただけで
  別の手が落ちるので、効かなかったことに気付けないと誤った下書きを持ち帰る)
- **宛先は入口で1つに畳む**(`MCPServer.foldingUDIDIntoPort`。2026-08-10)。`udid` は
  `call(tool:args:)` で `port` へ解決してから配る。**機ごとの記憶は `engineKey` で引く**
  (`lastSnapshots` / `launchedBundleIDs` / `uiFrameworkHints` / `connections` /
  `pendingWarnings` / `udids` / `engines` の7つ)が、`engineKey` は生の引数しか見ないので、
  畳まないと udid で指した機が全部 `port=nil` の同じキーへ落ちる。
  実測した3症状(すべて同じ根): ft_status が `@ port …` を出さない / allowVersionSkew の
  警告が出ない / 機A に Preferences・機B に Maps を launch した後、機A への ft_open_url が
  com.apple.Maps へ配ると申告する(Android では intent の宛先なので実際に誤配送する)。
  **新しい宛先の指し方を足すときは、ここで畳めているかを必ず見る** ——
  ドライバのキャッシュだけ直しても記憶の側は揃わない。
  **セッション内デバイス記憶も同じ入口で畳む**(`MCPServer.foldInRememberedDevice`。2026-08-12)——
  当初 `driver(_:)` 内で適用していたが、キャッシュキーと `engineKey` が生の引数を見るため
  「明示切替後の省略呼び出しが旧デバイスのキャッシュ済みドライバを引く」
  「明示 port で採った ref が省略呼び出しから見えない」の2症状を生んだ(上と同根)。
  適用条件は「udid/port/serial のどれも有効値で来ていない、かつ profile なし」で、
  判定は Android と同じ空文字規則(`argsGaveIOSTarget` / `argsGaveAndroidTarget`。
  `udid: ""` は省略扱い —— キー存在で見ると自動解決の結果を「利用者が選んだ」として記憶してしまう)。
  規律は4つ: **① iOS は port だけ注入する**(udid まで注入すると毎呼び出しに全ポート走査 +
  `reconcilePort` が走り、ブリッジが busy(quiescence 中は /status 無応答)なだけで hard fail する)/
  **② 注入した呼び出しは記憶を再記録しない**(`deviceFromMemoryKey` マーカー。再記録すると
  ポート再利用で別の機に化けたとき記憶が黙って乗り換わる)/ **③ platform も記憶する**
  (`lastExplicitPlatform`。platform 省略の既定は ios なので、これが無いと直前まで Android を
  driving していても省略呼び出しが iOS へ行く)/ **④ 注入は応答へも注記する**(ターゲットごとに
  初回だけ。stderr は MCP クライアントに見えない)。
  `forgetConnection` は一致する記憶も消す —— 消さないと、死んで別ポートに建ち直った
  ブリッジへ省略呼び出しが永久に再ダイヤルする。Android の死亡判定は
  `AndroidSerialResolver.connectedSerials()` の再照会(`androidSerialVanished` = 純粋関数)。
  **曖昧なら適用せず拒否する**(2026-08-13。`isAmbiguousMemory` / `rememberedDeviceRefusal`)——
  2026-08-12 は「2台以上なら毎回注記しつつ直近へ流す」だったが、**注記は事故を1件も止めなかった**。
  監査19(serial だけの呼び出しが黙って iOS へ)・監査20(キャッシュ命中で記憶が更新されない)・
  udid 2台の記憶混線は**3件とも「2台以上を触ったセッション」でだけ**起きており、逆に1台しか
  触っていないセッションは原理的に外しようがない。**記憶が安全なのは、それが一意なときちょうど**
  なので、そこを境に警告から拒否へ格上げした(1台のセッションの手数は変わらない)。
  拒否は候補を名指しする —— 断るだけだと読み手は総当たりで udid を試し、結局どれかの機を操作する
- **キーが指す機が変わったら、そのキーの状態は全部捨てる**(`MCPServer.forgetDeviceState`。2026-08-13)。
  `engineKey` は `direct:ios:<port>:<serial>` で、**iOS のポートはセッション中に動く**
  (監視が別ポートで建て直す。実測: -03 が 8128→8126)ので、死んだポートは後で別のシミュレータに
  再利用され得る。`forgetConnection` が `drivers`/`connections`/`connectedPorts` しか消して
  いなかったため、`lastSnapshots` と `refGenerations` は**前の機の木**、`launchedBundleIDs` は
  **前の機で起動したアプリ**のまま生き残っていた(古い ref が別の機の木を起点に解決され、
  `ft_open_url` が前の機のアプリへ配送する)。**出力がずれるだけの記憶と違い、これは操作が
  別物へ届く型**なので後始末を1箇所に固める。**`nextRefBase` だけは残す**(単調増加の不変条件。
  0 へ戻すと捨てた世代と同じ base が再配布され、世代管理が防いでいる「番号は同じだが別要素」を
  後始末の側から作る)。版ズレ拒否は `drivers[key]` だけを nil にするので、`driver(_:)` の
  iOS 生成側でも **udid の変化**(port ではなく機そのもの)を見て同じ後始末を撃つ
- **版ズレは既定で拒否**(2026-08-09 に警告から格上げ)。MCP の出力はシナリオへ書く文字列を
  供給するためにあるので、**古いブリッジの出す古い注記から誤ったセレクタが書き込まれる**ほうが
  「セッションが止まる」より高くつく。ゲートは `driver(_:)` の1箇所(`enforceVersion`)なので
  デバイスを掴む全ツールに掛かり、`ft_status` は「失敗するが理由と直し方を返す」。
  **どちらが新しいかを明示する**(対処が変わる)。押し通しは `allowVersionSkew: true` で、
  その回以降は**毎回**警告が付く(1度言って黙らない)
- **操作直後の整定(xcuitest, 2026-07-21)**: XCUITest の tap quiescence は非同期 push 遷移の
  完了前に返り、かつ直近 snapshot をキャッシュするため、操作直後の素取得は遷移前ツリーを返す
  (実測 50%)。対策として、直前が画面変更操作(tap/type/swipe/drag/press/session/…)だった
  snapshot に限り、取得前に短い待機(実測 350ms で staleness 0/10)を入れて遷移後の fresh ツリーを
  返す(`BridgeRouter.settlePending`)。連続 snapshot(操作を挟まない再取得)は据え置きで課金しない。
  固定待機は XCUITest が非同期遷移完了の event-driven な信号を出さないための妥協(要 private の
  quiescence API を使えば event-driven 化できるが未採用)。inapp エンジンは tap 側の `InAppSettle`
  (アニメ整定をイベント駆動で待つ)が既に遷移を待つため対象外。

**value の正規化: placeholder がそのまま来る欄は空にする**(2026-08-06)。
WebKit は空の `<input>` の AXValue に placeholder を入れて返す(UIKit の入力欄は入れない)ため、
正規化しないと **iOS の WebView だけ `value="WebView 入力"`** になり `valueIs("")` が通らない。
**Android の同じ欄は empty で返る**ので、経路で割れていた。判定は `clearInput` の
`remainingText` と同じ規則(`value == placeholderValue` なら空)。

**重複ノードの畳み込み**(2026-08-06。規則は `Sources/FTCore/SnapshotDedupe.swift`)。
iOS の AX ツリーは**ラッパと実体を両方出す**ことがあり、実測で3形あった:
UIKit の Switch(`id=sw_notify 61x28` と無名の `63x28`)/ `UIAlertController` の各ボタン
(同一 frame・同一 id で2つ)/ キーボードの `#dictation`。**Android のブリッジは1つで返す**。
実害は「`.button[n]` の序数が見え方とずれる」と「同じ id が複数候補になる」。
落とす条件は**型が同じ・位置がほぼ同じ(2pt)・情報を足していない**の3つとも成り立つときだけ
(内側が id やラベルを新しく持つ形は落とさない = 指せる要素を消さない)。
**ラベルが違えば落とさない** —— 同じ矩形へクランプされた行(`行 09`〜`行 40` が `行 01` の
位置に畳まれる形)は重複ではなく「描かれていない残骸」で、扱いは MCP 側の警告(§MCP)。

### 4.4.1 WebView の中身(2026-07-29)

WebView(iOS=WKWebView / Android=android.webkit.WebView)の中身は、経路ごとに見え方が違う。

| 経路 | 中身の取得 | 備考 |
|---|---|---|
| Android ブリッジ | a11y の仮想ツリー | リンクは Chromium の `chromeRole`(非ローカライズ)で `link` に正規化。**全ノードを `refresh()`** してから読む(WebView は DOM 変更の a11y 反映が 4〜8 秒遅れ、ネイティブ画面でも IME 等が前面だと数秒古いツリーが返る) |
| iOS xcuitest | a11y ツリー | 中身が現れるまで **約 2.3 秒**(WebContent プロセスの a11y 起動待ち) |
| iOS in-app(uikit ホスト) | **DOM を JS で走査** | `InAppWebViewDOM` + `WebViewDOM.javaScript`。1往復・隔離ワールド |
| iOS in-app(Compose / Flutter ホスト) | **DOM を JS で走査**(2026-08-02 から) | interop が合成タッチと `insertText` を横取りするので**読めても操作は届かない**。読みは DOM のまま、**ref を使う操作だけ座標へ解決して XCUITest の実タッチ**へ回す(`webViewPath: "dom-interop"`。performance-tuning.md §3.13)。画面ごとの委譲は DOM が全く読めない構成だけに残る |

- **a11y ツリーは in-app からは見えない**(Web コンテンツの AX は WebContent プロセスが提供する)。
  そこで in-app は `evaluateJavaScript` で DOM を1往復読み、a11y 経路と同じ DTO へ写す。
  可視性(display/visibility/aria-hidden/0px/画面外/`elementFromPoint` の被り)は JS 側で自前判定する。
  **被りを見る点は「見えている部分」の中心**(素の中心ではない。2026-08-25)——
  ページがスクロールして上端に少しだけ残った入力欄は素の中心が viewport の外にあり、
  `elementFromPoint` は viewport 外の点に null を返すので、**触れる要素が木から丸ごと落ちる**。
  a11y 経路は残すので、それは「同じページで経路により見え方が割れる」= この経路が
  避けるために存在する状態そのものになる(witness: E2E-CMP の WebView シナリオが5回中4回赤)。
- **操作は DOM でやらない**。`element.click()` や value 代入は user activation・IME・`:active` を壊すので、
  DOM から得た矩形を画面座標へ変換して**合成タッチ**を打つ(ref に AX ノードを紐付けない =
  `tapByRef` が座標へ落ちる、という既存経路をそのまま使う)。
- **`dom-interop` では ref を XCUITest へ渡さない**。委譲先は自分が最後に撮った別 snapshot の
  ref 名前空間を持つため、混ぜると別要素を指す(「返す snapshot と ref の名前空間を一致させる」
  不変条件)。ホストが ref → 矩形中心 → 座標に解決してから渡す。
- **画面に入るとき1回だけ委譲側を暖める**(`delegated.snapshot()`)。これが XCUITest の attach を
  兼ねており、省くと**最初の座標タップが 200 を返しても効かない**。1画面1回に留めること
  (毎 snapshot 撃つと委譲と同じコストに戻る)。
- **DOM 由来の要素は `ElementInfo.web = true`** で申告する。ホスト(`WebViewDelegatingDriver`)は
  これを見て委譲要否を決める。**幾何で「中に何か居るか」を見てはいけない**: Compose iOS の
  interop 容器は WebView と同じ矩形を持つため、中身と誤認して委譲が止まる(2026-07-29 実害)。
- **中身が出ないまま待ちが尽きたら木がそう名乗る**(2026-08-15。`WebViewPath.delegatedEmpty`)。
  委譲直後は XCUITest 側の WebView AX 活性化に時間がかかるので中身ゼロの木を待つが、
  上限(`contentWaitMs` = 5000)は **Simulator の実測 2.3s に対する余裕**でしかなく、
  hybrid は実機でも動く —— 13_WebView のシナリオ自身が「SUT により最大 約8秒」と書いている。
  尽きたときに黙って空の木を返すと**否定アサーションは必ず通る**(空の木に要素は無い)。
  木からは「AX がまだ公開されていない」と「本当に空のページ」を区別できないので**判定は変えず**、
  `StepNote.webViewNotRendered`(通った回にも残る)と失敗文言で名乗る。
  値の定義元は `FTCore.WebViewPath`(**BridgeDTO には置かない** —— あちらはブリッジの
  ソース集合で、触ると3ブリッジの指紋が動く)。
- **効果**(E2E-iOS / ios-inapp・4 run で再現): WebView 画面の検証 1 手が **450ms → 4ms**、
  シナリオ全体 **27.2s → 10.3〜11.0s**。委譲中は XCUITest 経由で 1 手 378ms かかっていた。
- **委譲中でもスクロールだけは in-app で行う**(2026-08-01)。interop が横取りするのは**タッチ**で、
  WKWebView の中の `WKScrollView` は本物の `UIScrollView` なので `contentOffset` は素通しで効く。
  `InAppBridge.handleSwipe` は compose/flutter + `scroll=true` のとき、AX 経路より先に**画面中央を
  覆う `WKScrollView`** を探して動かす(中央で絞るのは小さな埋め込み WebView のために画面本体の
  スクロールを奪わないため)。端では 501 でなく **no-op 200**(501 だと XCUITest の実スワイプへ
  ラッチして下端タップが不安定になる)。ホスト側は `WebViewDelegatingDriver.swipe(_:forScroll:)` が
  委譲中でも primary を先に試し、501 なら委譲先へ落とす。**ref を使わない操作なので名前空間の
  不変条件は崩れない — ref を伴う操作を同じ理屈で in-app へ回してはいけない**。
  効果は CMP/Flutter の WebView シナリオが **41s → 24s**(docs/performance-tuning.md §3.11)
- **クロスオリジン iframe は読めない**(main frame の JS からは触れない)。数を数えて
  `SnapshotResponse.note` で申告する(黙って要素ゼロにしない)。
- 殺しスイッチ `FT_WEBVIEW_DOM=off`(ホストの環境変数。`SIMCTL_CHILD_` で注入先へ引き渡す)。
- **DOM 経路の可否は WKWebView 単位で決める**(`WebViewDOM.isInteropHosted`)。祖先に
  `FlutterView` / `FlutterTouchInterceptingView` / `androidx.compose.ui.*` が居れば interop 配下 =
  読めても操作が届かないので使わない。**アプリ単位で判定してはいけない**: UIKit アプリの
  Flutter add-to-app や CMP 画面混在では、アプリは uikit なのに中の WebView だけ interop 配下になる
  (逆に1画面のためにアプリ全体で DOM 経路を捨てることにもなる)。目印は実測の祖先チェーンから採った
  (SwiftUI の `UIKitPlatformViewHost` は "PlatformView" を含むので雑な部分一致は禁物)。

**hitTest による名前非依存の判定は不採用**(2026-07-29 に実測。再提案しないこと):
WebView 中心点の `window.hitTest` が当の WebView かその子孫を返すかで interop を見分けられないか
測ったが、**3構成を分離できない**。Flutter は名前に反して**ヒットテストを WebView へ通し**
(`FlutterTouchInterceptingView` はジェスチャレコグナイザ側でタッチを食う)、
selfOrDescendant=true になってネイティブと区別が付かない。CMP だけは `OverlayInputView` が
ヒットテストを奪うので false になる。祖先のジェスチャレコグナイザ数も
ネイティブ 6 / CMP 9 / Flutter 12 で閾値に使えない。よってクラス名の目印を維持し、
取りこぼしは**失敗文言の注記**(`StepExecutor.webViewPathHint`)で追跡可能にする方針とする。

**失敗文言に経路を添える**(`SnapshotResponse.webViewPath`)。DOM 経路の未検出は
「無反応タップが成功として記録され、2ステップ先で別の文言で落ちる」形で出るため、
落ちた側に経路を書かないと追跡コストが跳ね上がる。**経路は snapshot を返したドライバが名乗る**:
要素の形から推測すると、webView 型を出すが web フラグを持たない **Android が
「XCUITest へ委譲」を名乗る**(2026-07-29 実害)。申告が無ければ何も足さない。

**`#id` は WebView 内でも使える**(旧「確定仕様: 使えない」は 2026-08-14 に撤回。
撤回の根拠と現在の供給源は §木はどこから来るか)。**意味は構成によらず id の完全一致**で、
変わるのは意味ではなく**供給の有無**だけ。供給できるのは DOM に届く経路(iOS in-app /
Android のアプリ内 WebView・ブラウザ)と、a11y が id を出す構成(Android WebView 150 以降)。

**撤回前の根拠は2つとも誤りだった**(記録として残す。同じ誤診を繰り返さないため):
「Android は id を出さない」は **WebView 124 限定**の観測を一般則として書いたもので、
150 は `viewIdResourceName` に出す(そのうえ 124 と 150 は **id と placeholder が入れ替わる**。
`AndroidWebViewVersions.swift`)。「CDP は対象アプリの協力が要る」も誤りで、
**debuggable なら `setWebContentsDebuggingEnabled(true)` 無しでソケットが開く**
(2026-08-15 に呼ばないビルドで対照を取って実測)。**リリースビルドは対象外でよい**
(id が難読化されるので id で指すテストは元からデバッグビルドの活動)。

**HTML id を供給できない構成は iOS xcuitest だけ**(WebKit は HTML id を a11y へ出さない)。
そこでは**黙って不一致にせず、構成を名指しして落とす**(`#id` の意味を構成ごとに変えない、
という原則は維持する)。

**`#x` は identifier で引けなければ placeholder を引く**(2026-08-15 ユーザー指示。
判定は `StepExecutor.candidates` の1箇所)。**構成ごとに意味を変える例外ではない** ——
規則はどの OS・エンジンでも同じで、`#` が指す名前の集合が「identifier ∪(identifier で
引けないときの)placeholder」になる。入力欄はまさにここが経路で割れる(xcuitest は HTML id を
出さないが placeholder は出す / Android は WebView の版で **id と placeholder が入れ替わる**)ので、
シナリオ側に分岐を書かせない。**identifier が1件でも当たったらそちらだけ**を使う ——
混ぜると `#x[2]` の序数と `countIs` が経路で変わる(静かに別の要素を指す)。
台帳(`SelectorInventory`)も placeholder を貯める = dry-run が実在する欄を誤警告しない。`css=` のような**別記法を `#id` に相乗りさせない**方針も維持
—— css は DOM への問い合わせなので届く構成が `#id` よりさらに狭く(xcuitest と
非 debuggable が外れる)、相乗りさせると `#id` の適用範囲まで狭く見える。

**スクロールヒント(Android の WebView・2026-07-29 実装)**: Chromium は**全ドキュメントの
ノードをツリーに載せる**(画面外は extras の `offscreen=true`・実座標は `unclippedTop/Bottom`。
`isVisibleToUser` は true のままなので明示的に除外しないと通常要素に漏れる)。ブリッジはこれを
`SnapshotResponse.offscreen`(実座標付き・ref=0)として返し、ホストのスクロール探索が
「目的の要素がどの方向・何 px 先か」を知って、固定幅スワイプ(実測 1.05s / 974px)を
少数の長距離ドラッグ(0.44s / 1500px+)へ置き換える(`StepExecutor.offscreenJump` /
`offscreenEdgeJump` / `dragGesture`)。較正は持たず、毎スナップショット(25ms)で測り直す
自己補正。**ヒントは要素解決に使わない**(見えない要素へ exist/tap が当たる)し、
**不在の根拠にもしない**(ネイティブのリストは画面外を載せないため)。
効果(scrollTo 中央値・android プロファイル): ネイティブ 10.2s→3.7s / CMP 8.7s→5.9s /
Flutter は中立(9.5s。ドラッグ後の再計測サイクルが重く相殺。退行はない)。

**iOS(XCUITest ランナー・2026-08-04 実装)**: XCUITest も WKWebView 配下は**全ドキュメントの
ノードを実座標のまま**ツリーに載せる(旧記述「画面外ノードを出さない」は誤り —
`BridgeRouter.shouldInclude` の画面交差ガードが落としていただけ。クランプも無い: 画面 402x874 に
対し y=2784 や y=-1200 が取れ、スクロール量に追従する)。Android と同じ契約
(ref=0・elements に混ぜない)で供給する。**hybrid には流さない**: WebView 委譲中の snapshot は
`WebViewDelegatingDriver` が offscreen を落とす(in-app の contentOffset 短絡 1.5s の方が速く、
ヒントが乗ると跳躍 = XCUITest 実ドラッグが優先されて遅くなる方向に挙動が変わるため)。
効果(WebView シナリオ・ios-xcuitest・アイドル3周 A/B): scrollTo 9.3〜9.6s→6.5〜7.3s
(全 SUT −22〜31%)/ scrollToTop CMP・Flutter 10.9〜11.0s→9.1〜9.2s(−16%)・SwiftUI 中立
(fling 2〜3回で足りる距離では跳躍の節約が settle コストに埋まる)。残る床は scrollToEdge の
毎周 `settledSignature`(WebView は snapshot 1枚 300〜500ms・減速中比較の実害由来で外せない)。

**未着手の副産物**: `AccessibilityNodeInfo` extras の `targetUrl`(リンクの href。
同ラベルのリンクを区別する手段になり得る)。

### 4.5 Android ブリッジ(対になる実装。AndroidRunner/)

iOS ブリッジと同じ WDA 方式を Android の instrumentation として自作したもの。
`AppDriver` の Android 実装(`AndroidDriver`, Sources/FTAndroid/)から見れば
iOS ブリッジと区別なく扱える。

- **常駐 instrumentation**: `am instrument -w` でデバイス内にバックグラウンド常駐させ、
  HTTP サーバ(BridgeInstrumentation)を内蔵する。`AndroidBridge.swift` が初回操作時に
  自動インストール・自動起動するためセットアップ手順は不要
- **共通コア13 + locale/settle の15エンドポイント**: §4.3 の共通コア(status/session/snapshot/
  tap/type/clear/pressEnter/swipe/press/doubletap/pinch/screenshot/terminate)に `POST /locale`・
  `POST /settle` を加えた15エンドポイントを話す(iOS 固有の drag/appswitcher/home/hidekeyboard/
  appstate/rotate は未実装)
  ため、共通コア部分はホスト側の `FTBridgeClient` 相当のクライアントコードを流用できる
- **操作応答 = a11y 静穏後**: 各操作 API は注入後、対象パッケージの a11y イベントが
  一定時間静まるまで応答を保留する(QuietWaiter)。固定 sleep をやめてイベント駆動にした
  2026-07 の高速化はこの仕組みが土台(詳細・実測は [performance-tuning.md](performance-tuning.md))
- **アニメーション自動無効化**: ブリッジ起動時に window/transition/animator の
  アニメーション倍率を 0 に固定し、静穏判定後に screenshot が古い絵を掴む問題を回避する
- **報告する `screen` はディスプレイ全体・フィルタの基準はアクティブウィンドウの根**
  (2026-08-06 に分離)。両方をウィンドウの根で兼ねていたため、**ダイアログが出ている間だけ
  `screen` がダイアログの DecorView**(実測 1024x427 / 735x386)になり、同じ応答に入っている
  要素座標(y=1342 等)がそれをはみ出す自己矛盾した木を返していた。実害はもう1つあり、
  `BridgeRouter` はこれを `lastScreen` として覚え**既定の全画面スワイプとピンチの座標を作る**
  ので、ダイアログを撮った直後の swipe が画面上部の狭い帯を払うことになる。
  ディスプレイは `Resources.getSystem()` の DisplayMetrics から採る(Context を持ち回らない。
  取れなければ従来値へ落とす)。**フィルタ側を display に替えてはいけない** ——
  「画面の大半を覆う容器を落とす」0.85 の意味が変わり、ダイアログの中身の出方が動く
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

**採らない対策(2026-07-21 実測で否定・シミュレータ -03)**:
identifier ベースの `XCUIElement.tap()`(scroll-to-visible 期待)は効かない。XCUITest の `isHittable` が
Compose では壊れており、クランプされた画面外セルを `hittable=true`(=画面内)と誤認してスクロールせず
クランプ位置を叩き別セルへ誤遷移する。逆に可視の正確セルは `hittable=false` になり `.tap()` が不規則な
自動スクロールを誘発して外す(座標タップなら当たる可視セルを退行させる)。`.tap()`/`isHittable`/`scroll-to-visible`
はいずれも同じ壊れた frame を信じるため救済不能。座標タップ(現行実装)を維持する。
**「クランプ」という機構の言い方は 2026-08-03 に不正確と分かった**(実採取では、画面外の行は
ビューポート内へ寄せられるのではなく**容器の外にラベル無しで並ぶ**)。この実験の結論
(`.tap()`/`isHittable` を使わない)は変わらないが、**機構を前提に何かを組むなら採り直すこと**。

補足: この frame 破綻とは別に、Compose の合成 a11y 要素は `accessibilityActivate()` が発火しないため、
inapp の ref タップも座標フォールバックに落ち、同じ壊れた frame を踏む(座標非依存の起動経路が無い)。

---

## 5. FM 呼び出し層(FTFoundationModels)設計

### 5.1 セッション戦略(4K トークン運用)

- **1 呼び出し = 1 セッション**。毎回新しい `LanguageModelSession` を作り、
  会話履歴は持ち回さない。渡すのは instructions(役割定義、~200 トークン)+
  その場で必要な入力(壊れたロケータ・失敗ステップの差分・現在画面の圧縮スナップショット等)のみ
- 応答は必ず `@Generable` 型。自由文を返させないことで応答トークンも節約。

### 5.2 主要な @Generable 型

```swift
// Sources/FTFoundationModels/ReplayAssist.swift(抜粋。@Guide の全文はソース参照)
@Generable
struct LocatorRepairSuggestion {   // 自己修復: 壊れたロケータの代替案
    var elementText: String        // 現在の要素一覧から label か id= 値を逐語コピー
    var confidence: RepairConfidence  // high / medium / low
    var rationale: String          // 英語1文
}

@Generable
struct TriageSuggestion {          // 失敗トリアージ
    var failureClass: FailureClass    // appBug, flakiness, locatorDrift, envIssue
    var summary: String               // 英語1〜2文
    var suggestedFix: String          // 英語1文
}
```

### 5.3 実装(Sources/FTFoundationModels/ の5ファイル)

| 実装 | 役割 |
|---|---|
| `ReplayAssist.swift`(`FMReplayDelegate`) | 再生失敗時のみ呼ばれるフック群: ロケータ自己修復(`LocatorRepairSuggestion`)・スクリーンショットの画面検証(`ScreenVerdict`。**マルチモーダル**)・失敗トリアージ(`TriageSuggestion`) |
| `OcclusionVerifier.swift` | アサーションがツリー通過した直後の、遮蔽による誤った緑の排除(マルチモーダル。要素 frame にクロップして渡す) |
| `FMDoctor.swift` | FM 可用性判定。`check()` は同期・可否を保証しない / `checkLive()` は実際に1回推論する(§1.1 の罠) |
| `ScenarioNamer.swift` | 記録操作(ライブ操作タブ)からのシナリオ名生成 |
| `TestbaseDrafter.swift` | テスト設計資料 → シナリオ下書き(§17)。FM 不可用時は決定的パーサへ落ちる |

- 全 FM 呼び出しは `FMGate.enter()` を通す(§1.1)。出力の実例・運用知見は §8.6。

---

## 6. CLI UX

```
fleetest doctor                            # FM 可用性・Xcode・シミュレータ・adb の事前チェック
fleetest bridge up|down|status [--platform ios|android] [--device ...] [--serial ...]
                                           # ブリッジ(iOS: 常駐 XCUITest / Android: 常駐 instrumentation)の管理
fleetest run [--project P] [--profile 名] [--scenario id...] \
    [--heal] [--report-dir ...] [--ports 8123,8124] [--skip-build]
                                           # Swift シナリオの決定的実行(プロファイル実行は§11)
fleetest draft-scenario [--project P] [--testbase 資料.md] [--app ...] [--no-fm] [--dry-run]
                                           # テスト設計資料からシナリオ下書きを生成(§17)
fleetest project create|list|sync          # テストプロジェクトの作成・一覧・Package.swift 再整合(§11)
fleetest profile list                      # 実行プロファイルの一覧と現在マシンでの解決チェック(§11)
fleetest install <パッケージパス>           # .app / .apk のインストール
fleetest launch|terminate <bundle-id>      # アプリの起動・終了
fleetest snapshot [--json] | tap | type | swipe | press | screenshot
                                           # 手動駆動プリミティブ(圧縮スナップショット・操作。§4.4)
```

実行結果はシナリオ実行毎に `TestProjects/<name>/reports/scenario-*.md`(§10)へ自動出力される。
集約・分析は別レイヤの `fleetest results list/summary/flaky/trend/devices/slow/insights`(§14)で行う。

- **`bridge up` が起動するのは xcuitest ブリッジ(iOS)/デバイス内サーバ(Android)のみ**(in-app ブリッジを
  起動する経路は無い)。プロセスは常駐し、停止は `bridge down` か `devices down` を要する
- **`run --profile` は終了時にブリッジを停止しない**(常駐を残すのが仕様。次の run が版一致なら再利用する。
  利用者向けのコマンドは README「コマンド一覧」)

CLI/MCP/VSCode 拡張はいずれも同じ `fleetest api ...` 系サブコマンドを経由して呼び出す共通実装(§11.4 参照)。

---

## 7. マイルストーン

| M | 内容 | 完了条件 | 状態 |
|---|---|---|---|
| **M1** | ブリッジ + 手動駆動 | CLI から SampleApp を起動し、curl 相当で tap/type/snapshot/screenshot が通る | 達成済み |
| **M2** | FM 探索によるシナリオ自動生成(`fleetest explore`) | — | 廃止済み(§1.2) |
| **M3** | 決定的再生 + 自己修復 + トリアージ | id 変更を仕込んだ SampleApp でシナリオが自己修復され、意図的バグで TriageReport が出る | 達成済み |
| **M4** | Android ブリッジ + ドライバ | `AndroidDriver` で FTFoundationModels/FTCore を無変更のまま Android アプリのシナリオを再生する(実装は自作 instrumentation ブリッジ。UIAutomator2/Appium は不採用。§4.5, §8.7) | 達成済み |

M1・M3・M4 は達成済み(M2 の FM 探索機能は後に廃止。§1.2)。2026-07 には固定 sleep をブリッジ内蔵の a11y 静穏検知に置き換える高速化を実施し、
Android シナリオで約 33%、iOS シナリオで約 27% 所要を短縮した(§8.7.1、詳細は
[パフォーマンスチューニングガイド](performance-tuning.md))。

---

## 8. リスクと対策

| リスク | 対策 |
|---|---|
| Apple Intelligence 未有効 / FM 利用不可 | `fleetest doctor` で `availability` を事前診断。`LanguageModel` 差替(PCC/Claude)を用意 |
| 4K コンテキスト超過 | スナップショット圧縮 + 1 ステップ 1 セッション + 応答の構造化。`contextSizeExceeded` 捕捉時は要素数を半減させて再試行 |
| 巨大な画面ツリーで snapshot が遅い | ランナー側でフィルタしてから返す(ホストに生ツリーを送らない) |
| xcodebuild ランナーの不安定さ | `bridge up` にヘルスチェック+自動再起動。`/status` ポーリング |
| Vision 入力の HW 要件(AFM 3 Core Advanced) | ホストは Apple Silicon Mac 前提なので通常問題なし。`doctor` で検査 |

---

## 8.5 M2(FM 探索)は廃止済み

FM がアプリを自律探索してシナリオを生成する explore モード(`fleetest explore` / ExplorerProfile)は
廃止した。3B モデルの迷走対策(数値参照の束縛ミス・greedy サンプリングの縮退ループ・ステップ上限・
サルベージ機構等)を含む実装知見はここでは割愛する。

## 8.6 M3実装で得た知見

- **マルチモーダルAPI**(macOS 27+): `Attachment(cgImage)` が `PromptRepresentable` なので
  Promptビルダーに画像を直接混ぜられる。`session.respond(generating:options:) { "説明文"; Attachment(cgImage) }`。
  **Attachment だけが macOS 27+ で、FM 本体(テキスト・`@Generable`)は macOS 26+**。Package の最低は
  macOS 26 に置き、視覚系(occlusion-guard / screenLooksLike)を実行時に落とす:
  判定の単一点は `FTCore/FMVisionSupport.swift`(StepExecutor が呼ぶ前に skip/素通りへ)で、
  実 API 側は `FTFoundationModels` の `#available(macOS 27, *)` が保険。triage はテキストのみで継続する
- **screenMatches(視覚検証)は実用レベル**: 「果物の商品名と価格が並ぶリスト」の一致/不一致を
  スクリーンショットから正しく判定し、不一致時は理由(エラーメッセージの存在)も説明できた
- **アサーションに type+index フォールバックは危険**(実測で誤った緑が発生): 別画面の無関係な要素に
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
  Flow DSL が完全共通化できた。**FTFoundationModels と FTCore は1行も変えずに Android で動いた**
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
  (`adb forward tcp:0 tcp:8123` 経由)。AppDriver/FTFoundationModels/FTCore は引き続き無変更
- 純フレームワーク API の Java のみ(androidx/gradle 不要、SDK 付属ツールでビルド、
  prebuilt APK を同梱)。初回操作時に自動インストール・自動起動(`AndroidBridge.swift`)
- 実測: snapshot 2.0s → 8.7ms(中央値)、フロー8本 87s → 38s。日本語 type も
  ACTION_SET_TEXT で IME 不要(ADBKeyboard は不使用)
- ブリッジ単一実装。adb 直叩き経路(uiautomator dump/input/screencap、Unicode IME 自動導入)は持たない。
  操作毎の `/status` 事前プローブも持たず、接続拒否系エラー時のみ自動再プロビジョン+1回リトライする
- 落とし穴: (1) UiAutomation は `am instrument -w` 必須(UiAutomationConnection が am
  プロセス側に住む)→ デバイス内で `&` バックグラウンド化して常駐 (2) a11y 接続は実質1本
  → ブリッジ稼働中は他の a11y クライアント(uiautomator dump 等)が Killed される

### Android のテキスト注入の規律(2026-07-31)

`InputInjector` の3経路(`setTextAppendingAt` / `clearTextAt` / `setTextAppending`)が守る規律。
**破ると「入ったのに値が壊れる」「成功を返すのに入っていない」が高負荷でだけ出る**
(8台並列で約40%再現・単独実行では8回中0回。解決後は10周×37シナリオで0件)。

- **`performAction(ACTION_SET_TEXT)` の `true` は「受理された」であって「入った」ではない**。
  タップがキーボードに吸われてフォーカスが立っていない Compose の TextField は、受理しても
  反映しない(a11y ノードは座標で見つかるので受理はされる)。**必ず読み返して確認する**
- **`combined` は最初の確定読みから1回だけ作る**。再発火は常に同じ値=構造的に冪等。
  読み返すたびに作り直すと、**パスワード欄の a11y 読みはマスクされている**ため伏せ字を値として
  書き込み(`password=•••…secret42`)、遅延適用と重なれば二重追記になる(`hello123hello123`)
- **中身のあるマスク欄へは追記そのものを撃たない**(`rejectMaskedAppend`。2026-08-06 追加)。
  上の規律は「作り**直す**と伏せ字を書く」だったが、**初回構築も同じ穴**だった ——
  追記は `既存の読み + text` を書き戻す形で、パスワード欄の「既存の読み」は伏せ字そのもの。
  実測: 空欄へ `abc` → 続けて `def` で、アプリ側の echo が **`•••def`** になり、
  ツールは "Typed" と成功を返した(値が壊れたことは後段の検証まで分からない)。
  読める術が無い以上ここは追記できないので **422 で弾く** ——
  置換したいなら呼び手が先に `clearInput` する(空への置換は冪等で安全)。
  空欄への1回目は `current` が空なので従来どおり通る。
  **弾いた判断は `catch (RuntimeException)` で再試行に化けさせない**(BridgeException だけ
  先に再スローする)。しないと 4 秒待って「ノードが無効化された」という無関係な 500 になる
- **適用確認はマスク欄だけ長さ一致**で見る(値そのものは読めない)
- **SET_TEXT はフォーカスが立っているときだけ撃つ**。立たないときは座標でなく `ACTION_CLICK`
  でフォーカスを要求する(キーボードの開閉で adjustResize が走ると**座標は当てにならない**)。
  猶予後の未フォーカス発火は最後の1回だけ・検証付き
- **対象の追跡は `ref` → resource-id 表**(`SnapshotBuilder.Result.refIds`)で毎周回取り直す。
  点だけを頼ると再レイアウトで別ノードに化ける
- **フォーカス済みでも 700ms 反映されないなら IME セッションが腐っている**(前のアプリ
  インスタンスに紐づいた残留)。BACK で IME を閉じ、最新 bounds の中心を**実タップ**して
  張り直す。`ACTION_CLICK` では張り直らない(実測)。BACK は
  `UiAutomation.getWindows()` に `TYPE_INPUT_METHOD` があるときだけ撃つ(無いと画面が戻る)
- **`performAction` / ノード読みは try/catch で「取り直し」に変換**する。レイアウト変化中の
  ノードは内部で NPE を投げる
- **読む前に `AccessibilityNodeInfo.refresh()` する**(2026-07-31 追加)。a11y ノードは
  キャッシュから供給されるので、`getRootInActiveWindow()` を毎周回取り直しても
  **`getText()` は変更前の値を返し続ける**ことがある。とくに WebView(Chromium)は DOM 変更の
  a11y イベントを数秒遅れて出す。取り直さないと「SET_TEXT は効いているのに読みが古く、
  期限切れで 500」= **実際には入っているのに失敗**になる(WebView 入力欄で 20% 再現。
  期限時のノードは `focused=true` で `text=""` なのに、ホストのスナップショットは
  `hello123` を読めていた)。`SnapshotBuilder.collect` が `insideWebView` で同じことを
  していたのに、注入側だけ漏れていた。**副産物として速くなる**: 確認が即座に成立するので
  WebView の type は 2,000→300ms、通常欄も中央値 864→520ms
  (キャッシュが古いあいだ待っていたぶんが消えた)
- **この規律は WebView 限定ではない**(2026-08-01 に範囲を拡大)。IME 等が前面にあると
  ネイティブ画面でも数秒古いツリーが返り、**アプリは正しいのに検証だけが落ちる**
  (逆に、遷移前の状態を期待するアサーションは**誤って成功する**)。`SnapshotBuilder.collect` は
  全ノードで `refresh()` する。**`isVisibleToUser()` より前に呼ぶこと** —— 可視性が古いと
  実際は見えているノードがサブツリーごと消え、`getChild()` も古い子リストを返す

**評価して不採用(再提案しない)**: `ACTION_FOCUS` でフォーカスを立てる案は **NPE を誘発して
失敗率が 2/5 → 5/5 に悪化**した(フォーカス移動でノードが無効化される)。ホスト側での事前・事後の
キーボード回避(閉じてから打つ/失敗したら閉じて再試行)は**発動しても効果が無い** —
対策はブリッジの注入ループ内でなければ届かない。

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
- **期限付き実行(`withDeadline` / `raceWithDeadline`)に `withTaskGroup` を使わない**: 構造化並行は
  スコープ終端で**敗者 task の完了を待つ**ため、ウェッジした op(無応答ブリッジ・固着した VT セッション)
  から離脱できず期限そのものが効かなくなる。だから非構造化 Task + 1回限りガード
  (`DeadlineGuard` / `RecordingRaceGuard`)で組む。
  **その代償が前方参照の競合**: op 勝利時に満期スリーパーを cancel するには task 参照を前方参照する
  必要があり、`Task { }` の本体は囲みの同期区間と**並行に開始し得る**ので素の `var` では競合する
  (「代入は同期区間で完了するのでレースしない」は成り立たない。ThreadSanitizer で実測・2026-07-30 修正)。
  `DeadlineTaskBox` は lock で守り、**代入前に来た cancel を覚えて後から適用する**
  (取りこぼすとスリーパーが seconds 秒居座り、この箱を置いた目的が消える)。
  前方参照を持たない `RecordingSupport.raceWithDeadline` にはこの箱が要らない
- **CLI での `Task.detached` fire-and-forget はプロセス終了と競合する**: 短命 CLI(fleetest run 等)で
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

0. **同梱 SUT + 対になるテストプロジェクト**が fleetest 自身の機能別 E2E。DSL のコマンド面
   (セレクタ記法・type・tap(holdSeconds:)/swipe・scrollTo・暗黙待ちと timeout・ifCanSelect/select・
   relaunch・ios{}/android{})を 1 機能 1 シナリオで網羅する。
   ネットワーク依存ゼロ・状態は起動ごとにルート正規化する設計で、フリートのロケール差や
   バックエンド死活に左右されない。`Scripts/e2e.sh` が全 SUT を鮮度判定つきで回す。

   **SUT は UI フレームワークごとに5つ**ある。同じ画面・同じ `#id`・同じラベルを5通りの
   実装で作ってあり、`AppDriver` から上(セレクタ解決・スナップショット圧縮)がフレームワークに
   依存しないことを実証する土台になっている:

   | SUT | 実装 | プロジェクト | 対象 OS | 契約 |
   |---|---|---|---|---|
   | `E2EAppCMP/` | Compose Multiplatform | `TestProjects/E2E-CMP` | ios + android | **`E2EAppCMP/docs/ui-contract.md` が唯一の正** |
   | `E2EAppIOS/` | SwiftUI + 一部 UIKit | `TestProjects/E2E-iOS` | ios | 差分のみ `E2EAppIOS/docs/ui-contract.md` |
   | `E2EAppAndroid/` | View/XML + 一部 Compose | `TestProjects/E2E-Android` | android | 差分のみ `E2EAppAndroid/docs/ui-contract.md` |
   | `E2EAppFlutter/` | Flutter | `TestProjects/E2E-Flutter` | ios + android | 差分のみ `E2EAppFlutter/docs/ui-contract.md` |
   | `E2EAppRN/` | React Native | `TestProjects/E2E-RN` | ios + android | 差分のみ `E2EAppRN/docs/ui-contract.md` |

   **`#id` とラベルは5 SUT で完全に同一、違うのは「型」と「id を露出させる作法」だけ**という設計。
   実測で採取した型の食い違い(いずれも同じ `#id` を指す):

   | 要素 | CMP(iOS) | CMP(Android) | SwiftUI/UIKit | View/XML | Flutter(iOS) | Flutter(Android) | RN(iOS) | RN(Android) |
   |---|---|---|---|---|---|---|---|---|
   | ボタン | `button` | `button` | `button` | `button` | `button` | `button` | `button` | `button` |
   | スイッチ | `switch` | `switch` | `switch` | `switch` | `switch` | `switch` | `switch` | `switch` |
   | テキスト | `staticText` | `staticText` | `staticText` | `staticText` | `staticText` | `staticText` | `staticText` | `staticText` |
   | パスワード欄 | `textView` | `secureTextField` | `secureTextField` | `secureTextField` | `textField` | `textField` | `secureTextField` | `secureTextField` |
   | チェックボックス | `button` | `checkBox` | `button` | `checkBox` | `switch` | `checkBox` | `other` | `checkBox` |
   | リスト行 | `button` | `clickable` | `clickable`(UITableView) | `clickable` | `button` | `button` | `button`(TaggedButton) | `button`(TaggedButton) |

   ボタン・スイッチ・テキストが揃っているのは 2026-07-26 の役割正規化の結果(それ以前は
   CMP(Android)のボタン/スイッチが `cell`[現 `clickable` の旧名]、Flutter(Android)の
   テキストが `other` だった)。**チェックボックスとリスト行は揃わない** — iOS 側の a11y が
   役割を出さないため(下記「型は役割に正規化する」)。**RN はパスワード欄・リスト行が
   ネイティブ SUT(SwiftUI/View)と同型で揃う**(RCTUITextField/ReactEditText がそれぞれ
   `UITextField`/`EditText` 派生のため。詳細は `E2EAppRN/docs/ui-contract.md`)

   **入力欄は「エンジン間で揃える」ところまでが担保**で、OS 間では揃わない(2026-08-06 実測)。
   iOS の自前描画フレームワーク(Compose / Flutter)の入力欄は UIKit の `UITextField` ではないので、
   in-app ブリッジのクラス判定を素通りして `other` に落ちていた —— **in-app だけ `other`・
   xcuitest は `textView`** という食い違いで、MCP で探索した型がシナリオで通らなかった。
   判定を**テキスト入力 trait(`1<<18`)**に足し、`UITextInput` 準拠で分けることで
   XCUITest の `elementType` と一致させた(`InAppSnapshot.elementType`):

   | | 要素クラス | traits | UITextInput | in-app / xcuitest とも |
   |---|---|---|---|---|
   | Compose | `AccessibilityElement` | `1<<47｜1<<18` | 非準拠 | `textView` |
   | Flutter | `TextInputSemanticsObject` | `1<<37｜1<<18` | 準拠 | `textField` |

   上位ビットはフレームワーク固有なので見ない。**マスクの有無は iOS のこの2系統では型に出ない**
   (Compose も Flutter も secure にならない)ので、跨 OS で入力欄を指すときは `#id` を使う。
   UIKit/SwiftUI は従来どおりクラス判定が先に効き `textField` / `secureTextField` / `textView` に分かれる。
   **React Native の入力欄はこのクラス判定がそのまま効く**(`RCTUITextField` が `UITextField` 派生・
   Android の `ReactEditText` が `EditText` 派生のため、trait 分岐を新設する必要が無かった。
   2026-08-08 実測)。既存経路のみで `textField` / `secureTextField` / `textView`
   (multiline は Android のみ `textField` のまま。詳細は `E2EAppRN/docs/ui-contract.md`)

   **Android は「見切れた要素の型が変わらない」ことも担保**(2026-08-06)。Compose の役割は
   同一矩形の無名子ノード(役割マーカー)で表現されるが、**見切れると親とマーカー子は独立に
   クリップされる**ため、矩形の完全一致を条件にしていると引き上げに失敗し、
   **同じ Composable が可視状態によって `button` と `clickable` を行き来していた**。実測3形:

   | 見切れ方 | 親 | マーカー子 |
   |---|---|---|
   | 右端(`#tag_04`) | `(987,1972)-(1080,2119)` | `(987,1972)-(1038,2119)`(子が狭い) |
   | 下端(`#btn_scroll_top`) | `(42,378)-(278,441)` | `(42,378)-(278,504)`(**子のほうが大きい**) |
   | 上端(`#row_07`) | `(42,441)-(1038,559)` | `(42,504)-(1038,559)`(原点が違う) |

   「子は親に内包される」も「原点は動かない」も成り立たない。**成り立つのは辺の共有**
   (切れていない側は必ず一致する = 3形とも3辺一致・角で切れれば2辺)なので、条件は
   **2辺以上の一致 + 面積が3倍以内**(`SnapshotBuilder.looksLikeRoleMarker`)。
   装飾(行の中のアイコン)は0〜1辺しか一致しない —— ここを緩めすぎると**リスト行が `image` になる**

   id 露出の作法もフレームワークごとに違う: Compose は `testTagsAsResourceId`(Android のみ・
   ダイアログには再適用が必要)、View 系は `android:id`(**実行時に resource-id を作れないため
   動的リストは `res/values/ids.xml` に静的宣言**)、SwiftUI は `.accessibilityIdentifier`
   (**UIAlertController の title/message には効かない**)、Flutter は `Semantics(identifier:)`
   (**`ensureSemantics()` 必須・`MergeSemantics` で畳む必要あり・Slider に畳むと iOS で
   a11y ツリーが丸ごと空になる**)、React Native は `testID`(iOS は `accessibilityIdentifier`・
   Android は 0.65 以降 `resource-id` にマップ。Modal 内にも届く)。詳細は各 SUT の `docs/ui-contract.md`。
1. `SampleApp`(ログイン画面 + ホーム画面 + 設定画面の 3 画面 SwiftUI アプリ、
   accessibility identifier 付き)をリポジトリに同梱
2. M1: `fleetest bridge up` → `curl localhost:8123/snapshot` で圧縮ツリーが返る
3. M3: SampleApp の identifier を 1 つ改名 → `fleetest run --heal` で修復・成功。
   意図的にログインを失敗させるビルド → TriageReport が `appBug` と分類する
4. 性能の検証・回帰比較は `Scripts/bench.swift` の計測基盤で行う。壁時計中央値・
   シナリオ/ステップ内訳・成功率・ホスト CPU/GPU/MEM を `summary.md` に出力し、
   変更前後を比較する。手順・指標の読み方は
   [パフォーマンスチューニングガイド](performance-tuning.md)を参照

## 10. Swift DSL への全面移行(2026-07-08)

テスト記述を YAML フローから **Shirates 風の Swift DSL** に全面移行した(YAML は廃止、Yams 依存も除去)。
動機: イレギュラー処理(不定ダイアログ等)やデータセットアップを「コード」で書けるようにするため。

### 記述形式

- `@TestClass(app:platform:)` クラス + `@Test(_:platform:)` メソッド + `scene(n)`(Shirates の case 相当)
  + `condition/action/expectation`(CAE)の3層構造
- **`app:` は通常書かない**(2026-08-19)。既定アプリは
  **実行プロファイル → アプリプロファイル → 実行中 platform の `ios.app` / `android.app`** から
  解決される(`FTCore.ScenarioAppResolution` が唯一の定義元。親が `--app` で子へ渡す)。
  これで**同じシナリオを `--profile ios` と `--profile android` で別 bundle ID の
  アプリに対して回せる**(OS で ID が違うアプリのためにクラスを複製しなくてよい)。
  `app:` を書いた場合は**そちらが勝つ** —— 1プロジェクトに複数アプリのシナリオが混在する構成を
  壊さないため(実行プロファイル側にシナリオを絞り込む仕組みが無く、プロファイルを常に勝たせると
  別アプリのシナリオが**黙って**誤ったアプリを起動する)。食い違いは警告1行だけ出す。
  どちらからも決まらなければ明示エラー(`fleetest run --app <bundleID>` が逃げ道。
  **dry-run だけは代替表記で通す** —— デバイスに触らず bundle ID を使わないので、
  ここで落とすと「実行プロファイル無しでは構文検査もできない」になる)
- **`@Test(platform:)`** はメソッド単位の対象 OS 宣言(クラスの `platform:` より優先)。
  宣言した OS を回さない実行プロファイルでは**キュー投入前に外して skipped(対象外)として記録する**
  (`FTCore.PlatformApplicability`)。**複数の機械にまたがる分散(host 混在プロファイル /
  `--fleet --split`)でも同じ判定**を fleet 全体の OS 和集合で掛けてから割り当てる
  (`FleetSplit.applicability`。2026-08-23 まで割り当てが throw して1本も走らなかった。
  分散の親は recorder を持たないので、スキップは記録ではなくログに出る)。**失敗に数えない** —— 以前はクラス側の `platform:` すら
  「担当ワーカーなし」に落ちて失敗として数えられており、「そのOSでは対象外」を表現する手段が
  無かった。記録は `ScenarioSkipKind` で**意図された対象外**と**インフラ都合の未実行**を
  区別する(混ぜると「緑だが1本も走っていない」run を見分けられなくなる)
- `@Deleted("コメント")` で論理削除(Shirates の @Deleted 相当)。テストクラスまたは
  `@Test` メソッドに付与する。一覧には「削除済み」として残り、全実行・フォルダ実行・クラス名指定の一括実行から除外される。
  完全一致 ID の明示指定でのみ実行可能。コードは残るため復活はアノテーションを外すだけ
- `@Draft("コメント")` で実装中(未完成)マーク。テストクラスまたは `@Test` メソッドに付与する。
  除外・実行可否の規則は `@Deleted` と同一(全実行・フォルダ実行・クラス名指定からは除外、
  完全一致 ID なら実行可)で、**違うのは意味だけ**(Deleted=もう使わない / Draft=これから使う)。
  `fleetest draft-scenario` の生成物にはこちらが付く
- コマンド(tap/type/exist/…)は**同期・非 throw のモジュールレベル自由関数**。
  `try await` も `{ it in }` も不要。カレント実行コンテキストを暗黙参照する。
  **DSL スレッド外(Task / 別スレッド)からの呼び出しは fatalError にしない**(2026-07-29)。
  1プロセス=1シナリオなので落とすと**レポートごと消える**。`FTDriveCore.recordThreadViolation` が
  失敗ステップを**1 run につき1回だけ**記録してシナリオを中断し、以降は既存の skip 経路へ乗せる
  (`handleFailure` は呼ばない = スクショ・FM トリアージを別スレッドから走らせない)。
  **core 未初期化だけは fatalError のまま**(記録先そのものが無くレポートを残す手段がない)
- **上と対になるロックが2つある**(どちらも「落とさずレポートを残す」ための最低条件。
  排他しないと `record.scenes` の append と `record.scenes[last]` への代入が競って
  **レポートを残すどころかプロセスが落ちる**):
  - `FTDriveCore.stateLock`(**再帰**): `record` 全体・`scenarioAborted`・`deviceFrozen`。
    DSL スレッド以外に、①違反スレッド ②`executor.onDeviceFrozen`(FTSync の detached Task 上)
    が触る。再帰にしてあるのはロック下の処理が `scenarioAborted` を触るため(`markDeviceFrozen`)
  - `FTRuntime.lock`: `core` / `dslThread`。**tearDown の書き込みと違反スレッドの読みが競る**
    (素の Optional への同時読み書きは実際に落ち得る)。
    **`stateLock` より先に取り、握ったまま core を呼ばない**(ロック順序を一方向に保つ)
  - **他の実行状態(`groupStack` / `scrollContextStack` / `currentSection`)は DSL スレッド専有のまま**で、
    違反スレッドが中断検知の前に触り得るのは受容した残存リスク(記録の見え方が乱れるだけで
    結果は壊れない)。検証は `swift test --sanitize=thread --filter FTDSLTests`
    (**ロックの正しさは目視では担保できない**。触ったら必ず TSan を通すこと)
- **要素が見つからなければ失敗(シナリオ中断)。唯一の例外は `select`** で、掴めなければ
  失敗させず空要素を返す(`FTElement.isEmpty`)。**「出るか不定」を表す引数は持たない**
  (`optional:` は 2026-08-02 に全廃。`irregularHandler` と `ifCanSelect` に一本化した。下記)
- tap/type/select は `timeout:`(ロケータ解決の再試行待ち上限秒。0=リトライなし。
  省略時は tap/type が約0.7秒・select は `defaultTimeout`)を取る。
  出るか不定の要素を `ifCanSelect` で見るときの空振り短縮用(performance-tuning §5)
- **秒は全て小数(Double)**(2026-07-29。`timeout:` / `waitSeconds:` / `defaultTimeout` /
  `--default-timeout`。`FlowStep.timeout` も `Double?`)。`timeout: 1.2` が書ける。
  表示は `FTSeconds.format`(FTCore)が唯一の生成元で `5.0s` ではなく `5s`・`1.2s` と出す
  (`StepDescription.formatSeconds` はここへ委譲)。
  `ifCanSelect` のポーリングは残り時間と 0.25 秒の小さい方で待つ(**0.5 秒固定だとサブ秒の待ちが
  丸められる**)。`waitSeconds: 0` = 即時1回判定の契約は不変
- `tap(holdSeconds:)` は長押し秒数(既定 `FlowStep.defaultTapHoldSeconds` = 0 = 通常タップ。
  Shirates 準拠)。`holdSeconds` が 0 より大きいときだけ StepExecutor がブリッジの `/press` へ回す。
  既定値と同じときは `FlowStep.duration` を nil のままにする(生成コード・ヒールキャッシュを
  既定ケースで太らせない)
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
- **画面には出ているのに当たらない**残りの形として、**本文が複数ノードに割れている**ときは
  失敗メッセージが `the text is split across N elements ("2026年" + "2月18日")` を出す
  (`StepExecutor.splitTextHint`。DSL と MCP が共有)。Web の本文は `<span>` や強調で普通に割れ、
  **インラインだけの塊は DOM 側で1ノードへ畳んでいる**(`WebViewDOMSnapshot.isInlineTextBlock`)が、
  間に役割を持つ要素やブロック級の子が挟まると畳めない。**畳めないものを無理に畳むと
  操作対象を潰す**ので、木は変えず言葉で伝える。繋いで見るのは**連続する最大4件**まで
  (増やすと偶然の連結で当たる)。受け手報告 2026-08-20 の実例: 画面末尾に見えている
  「2026年2月18日 改訂」が木では3ノードで `*2026年2月18日*` が両 OS とも空振りした。
  **実体は表組みの行**(3セルが同じ y・x が連続・interactive 要素なし)で、
  **行そのものは要素として出ない**(セルが別々に出る)。したがって
  **「まとめている要素に書け」と言ってはいけない** —— 全体を含む要素は木に1つも無く
  (この助言が出る条件そのもの)、利用者は存在しない逃げ道を探すことになる。
  **表組みの行を1ノードへ畳む案は採らない**: セル単位のアサーションを潰すうえ、
  畳んでも連結の仕方(空白を挟むか)で利用者の書いた文字列に一致するとは限らない
- **ゼロ幅文字は照合前に両辺から除去する**(2026-08-07。`FlowMatchMode.matches`。
  U+200B/200C/200D/FEFF/2060。正規表現のパターンだけは書き換えない)。実データに紛れており
  **画面にもスナップショット出力にも見えない**ので、完全一致が落ちても原因に辿り着けない
  (実測: Google マップの路線名は `​​中央線​` で `"中央線"` が当たらない)。
  `SnapshotRenderer` も出力から同じ集合を除去する = **出したものは必ず一致する**
  (除去しないと、一覧からコピーした文字列に不可視文字が入って .swift へ埋まる)。
  **走査は Character でなく Unicode スカラ単位** —— Character は書記素クラスタなので
  ZWJ は隣接文字と融合し、Character 比較では素通りする
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
  引数の括弧なので `|` の囲みにならない)。**展開数が 32 に達したら validationError**
  (`FTSelector.maxExpansion`。実際に書けるのは 31 通りまで)。
  **既知の非対応**: `(a|b)&&[2]` は「各節の 2 番目」であって「和集合の 2 番目」ではない
  (Shirates は後者。節ごとに `[n]` を持つ fleetest の構造をそのまま使うため)
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
  | React Native | `FlatList`/`ScrollView` に `testID`。**iOS は id 付きラッパー(`RCTScrollView`・非 scrollable)と実 scroll ノードが同 frame で別要素に割れるため、ホスト側の正規化で統合する**(両エンジン) |

  **畳むと子孫が消えてスコープ対象が無くなる**のが唯一の落とし穴(Flutter の `MergeSemantics`、
  Compose の Box+重ね置き `#pad_swipe` は iOS で子 Text が同 depth に平坦化される)。
  当初「Flutter では使えない」と判断したが、SUT が `MergeSemantics` で畳んでいただけで、
  容器を非マージで公開したら iOS/Android とも入れ子になった(=**フレームワークの制約ではない**)。
  回帰は 4 SUT 共通の `#list_rows >> …`(`TestProjects/E2E-CMP/scenarios/09_否定と個数と方向セレクタ.swift`・
  `TestProjects/E2E-*/scenarios/06_待機とタイムアウト.swift` の旧 12_セレクタ拡張 ブロック)。
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
  fallback の exact を優先する(§performance-tuning「フォールバック検証の誤検知」)
- **inapp の tap は activate 不発時に「整定待ち→要素取り直し→再 activate」で粘る**(2026-07-27)。
  Compose iOS は**画面遷移直後、要素が AX ツリーに載っていても accessibilityActivate がまだ
  配線されておらず false を返す**ことがあり、その瞬間の合成タッチも無反応(成否検知不能)で
  タップが黙って空振りする(実測: sut-ec-mobile お気に入り一覧→詳細で 2/15 失敗)。
  `InAppBridge.tapByRef` が InAppSettle(イベント駆動・cap 800ms)で遷移の整定を待ってから
  ツリーを取り直して再 activate し(+250ms でもう1回)、それでも不発なら従来どおり合成タッチへ。
  待ちはメインをブロックしない(asyncAfter)ので遷移自体は進む。**再試行は activate false の
  ときだけ**発生し通常経路のコストはゼロ。恒常的に activate false の要素(合成タッチで動くもの)は
  最大 ~1s 遅くなるが正しさ優先。レポート注記「要素を取り直して再実行」で観測できる。
- **Compose/Flutter のスクロールは UIAccessibility の scroll アクションで駆動する**(2026-07-31)。
  両者は `UIScrollView` を持たないので `contentOffset` 経路が無く、合成タッチの drag も受理
  されないが、**VoiceOver が使う `accessibilityScroll` は実装している**
  (Compose = `AccessibilityElement` / Flutter = `SemanticsObjectContainer`)。1回 = 1ページで、
  実測では XCUITest の実スワイプより**距離が長く**(row_01→27 対 row_01→16)、
  **1回あたり 106ms 対 456ms**。scrollToTop の中央値は 5,304→1,714ms。
  - **`swipe` を `unsupportedActions` に申告しない**: 可否は「目的と画面」で割れる
    (スクロール目的=可 / ジェスチャ目的=不可)ので、一律申告では表現できない。
    判定は `handleSwipe` に一本化し、不可なら 501 を返してホストにフォールバックさせる
  - **スクロール目的の swipe だけ AX 経路へ流す**(`SwipeRequest.scroll`)。DSL の `swipe`
    (ジェスチャ自体が目的)を混ぜると、**ジェスチャ検出パッドの上でもスクロール可能な親が
    受理してしまい**、パッドに届かないまま 200 を返す(2026-07-31 に E2E-Flutter の
    ジェスチャ画面が 2/2 で黙って空振りした)
  - **包むドライバは `swipe(_:forScroll:)` を必ず素通しする**。既定実装は自分の `swipe(_:)` を
    呼ぶので、受けないと**フラグが最初のラッパーで落ちて**経路が丸ごと不発になる
    (実際に落として、フルスイート2周ぶん「緑だが遅いまま」を測ってしまった)。
    `SwipeForScrollForwardingTests` がソース走査で守る
- **整定の打ち切りは黙って返さない**(2026-07-31)。整定待ちは3層にあり(ホストの
  `settledSignature` = 6 poll / in-app の `InAppSettle` = cap 2,500ms / XCUITest ランナーの
  `captureSettled` = budget 350ms)、**どれも収束と打ち切りを同じ顔で返していた**。そのため
  「常態的に上限へ張り付いているのに緑」が誰にも見えず、実際に2件を長く見逃した
  (ラベル振れによる `scrollToEdge` の非収束 / scroll edge effect による in-app の 2.5 秒張り付き)。
  唯一申告していた `scrollToEdge` の `stopped at the limit of N` が、その2件を見つける入口になった。
  以後3層とも note で申告する(ブリッジは `OKResponse.note` / `SnapshotResponse.note`、
  ホストは `StepOutcome.driverFallback`)。**打ち切りは失敗ではない**ので status は 200 のまま
- **整定は「視覚効果パラメータ」を動きと数えない**(2026-07-31)。`InAppSettle` は無アニメが
  100ms 続いたら整定とみなすが、iOS26/27 の scroll edge effect(スクロール縁のぼかし)が
  `CABackdropLayer` の `filters.gaussianBlur.inputRadius` を 0.25s で animate し続けるため、
  **無限反復ではなく既存の除外(match/punchout/SDF)にも掛からず**、静止区間が一度も作れない。
  結果 Compose iOS では launch 直後の 1〜2 アクションが毎回 cap 2500ms に張り付いていた
  (実測 actionMs 2,521ms。温まった後の同じ操作は 107ms。SwiftUI/Flutter には出ない)。
  `keyPath` が `filters.` / `backdropFilters.` で始まるアニメーションは無視する。
  **位置・不透明度・transform は除外しない**ので本物の遷移待ちは従来どおり効く
  (この修正で CMP の in-app スイートは 74s→57s)。
  同種の問題は「cap 打ち切りが常態化しても黙っている」ため見つけにくい —— 疑ったら
  `InAppSettle` に一時 NSLog を入れて `xcrun simctl spawn <udid> log stream` で層と
  キーを1回採るのが早い(手順は docs/verification.md)
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
  `FTPressEnterOnComposeFirstResponder` の1箇所。**名前は Compose 由来だが実態は
  Compose / UITextField(UITextView)/ Flutter の3経路を吸収する** —— 改名すると
  ブリッジ指紋が変わり版上げと入力系 E2E が要るので見送っている): Compose は `insertText("\n")` が IME アクションに
  変換される。**UITextField は変換されない**ので UIKit が Return で行うこと自体を再現する
  (`textFieldShouldReturn:` + `EditingDidEndOnExit`。SwiftUI の `onSubmit` もこの経路)。
  UITextView は Return = 改行挿入なのでそのまま `insertText("\n")`。
  **この関数を通るのは `pressEnter` だけ**(`type` の `\n` は上記のとおり XCUITest へ回るので
  in-app の `handleType` には届かない。engine=inapp 単独=xcuiPort 無しのときだけ来る)。
  **React Native は `RCTUITextField`/`RCTUITextView` が UIKit 派生なのでこの UITextField/UITextView
  経路をそのまま通る**(新しい分岐は不要。2026-08-08 実測。E2EAppRN/docs/ui-contract.md)。
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

### アプリのライフサイクルと OS 分岐

- `launchApp(bundleID?)` / `restartApp(bundleID?)` / `terminateApp()` / `clearAppData(bundleID?)`
  はロケータを取らず、`FTDriveCore.performCustom` でドライバを直接呼ぶ(スナップショットも
  セレクタ解決も挟まない)。bundleID 省略時はこの run の既定アプリ(上記 ScenarioAppResolution)。
  `restartApp` は terminate の失敗を無視して launch する(既に落ちている状態から呼べる)
- **器のディレクトリ名は `TestProjects/<name>/scenarios/`**(2026-08-05 に `Projects/` /
  `Scenarios/` から改名。profiles / reports / results / docs と大小を揃えた)。
  **旧名も解決する**: `ProjectStore.projectsDir` は `TestProjects/` が無ければ `Projects/`、
  `TestProject.scenariosDir` は `scenarios/` が無ければ `Scenarios/` を見る
  (既に導入済みの受け手は旧名のままで、`Projects`→`TestProjects` は大小が違うので
  macOS でも解決できない)。`Scripts/preflight.sh` も両方を見る
- **`home` の機構は iOS 実機とシミュレータで違う**: シミュレータは `XCUIDevice.press(.home)`、
  **実機は springboard の下端フリック**(`press(.home)` が実機では ok を返すのに効かない。
  2026-08-05 実測)。フリックは**速さでホーム/アプリスイッチャーが分かれる**ので数値を変えない
  (下端から 1/4 強・0.08 秒相当・press 0.05)。判定は `/appstate` ではできない
  (実機の `XCUIApplication.state` はスイッチャー表示中でも foreground を返す)
- **`clearAppData` の機構は OS で違う**: Android = `pm clear` / iOS = データコンテナの中身を
  削除 + **cfprefsd の入れ直し** + `simctl privacy reset all`。**中身の削除だけでは
  NSUserDefaults が戻る**(cfprefsd がドメインを抱えていて、次の起動で消したはずの値を配り
  plist を書き直す。2026-08-05 実測: 消して起動を3回で launch_count が 2→3→4)。
  `launchctl kickstart -k system/com.apple.cfprefsd.xpc.daemon` で 3/3 初期化される。
  **順序は「ファイルを消してから入れ直す」**(先に入れ直すとディスクの旧値を読み直す)。
  `defaults delete` は効かず(サンドボックスのドメインが見えない)、`killall` はシムに無い。
  `ClearAppDataContractTests` が2段の欠落を検出する。
- **simctl / devicectl の対象特定は `BridgeClient.resolveTarget` に一本化**(install /
  uninstall / clearAppData)。`/status` はデバイス名しか返さないので名前で引き当てるが、
  **名前をそのまま simctl へ渡さない**: 実機に繋がっているとき「Invalid device」という
  的外れな失敗になり、**同名のシミュレータが起動していればそちらを操作してしまう**。
  引き当ては booted シミュレータ優先 → 実機(devicectl 一覧は**必要になったときだけ**引く。
  数百 ms かかる)→ どちらでもなければ従来どおり名前。実機と分かれば install/uninstall は
  devicectl・clearAppData は 501。`DeviceTargetResolutionTests` が規則を固定する**権限はコンテナの外(TCC.db)にある**ので後者を省くと
  「Android では権限ダイアログが出るのに iOS では出ない」という OS 差が黙って生まれる
  (`pm clear` は権限もリセットする)。**iOS はシミュレータ専用**(実機は devicectl に同等手段が
  無く 501)。1件でも消せなければ失敗させる(部分削除を「消えた」と言わない)。
  キーチェーン/Keystore の値は残るので、そこに初回起動判定を置くアプリでは再現しない
- `ifCanSelect(セレクタ, waitSeconds:) { }.ifElse { }`: 「出るか不定」の唯一の表現手段
  (`optional:` 全廃後)。既定 `waitSeconds: 0` = 即時1回判定。**`FTRuntime.perform` を
  通らないので構文検証を個別に呼ぶ**(上記 `validationError` 項)
- `ios { } / android { }`: 対象 OS のときだけ実行する。**中身が実行されなかったことは警告しない**
  (ブロックに何が書かれているかは実行しないと分からないため)

### ディープリンク配送(`openURL`/`launchApp(url:)`。2026-08-09)

- `openURL(url)` = 起動済みアプリへの warm 配送(**再起動しない**)。`launchApp(bundleID?, url:)` は
  restartApp 相当の再起動 → 同じ配送を1コマンドにまとめたもの
- **配送はホスト側の外部コマンドで行い、ブリッジを経由しない**(ブリッジ版を上げる必要が無い):
  iOS シミュレータ = `xcrun simctl openurl` / iOS 実機 = `xcrun devicectl device process openURL`
  (**未実行検証**)/ Android = `adb shell am start -W -a android.intent.action.VIEW -d '<url>' <package>`
- **Android は URL をシングルクォートで包む**(`adb shell` の先はデバイス側シェルなので、
  クォート無しだと URL 内の `&` でコマンドが切れる)。**package は必ず付ける**
  (明示パッケージは解決先をそのアプリに固定し、App Links の検証状態に依存させない)
- **`am start` の失敗判定は `Error:` の有無だけ**。`Warning: Activity not started, intent has
  been delivered to currently running top-most instance.` は**成功**(singleTop アプリへの
  warm 配送の通常応答)。ここを失敗扱いにすると Flutter/RN への配送が全滅する

### openURL 後の SpringBoard 確認アラート自動了承(iOS。2026-08-09)

- iOS 27 のシミュレータはカスタムスキームの `openurl` に対し「"<表示名>"で開きますか?」の
  確認アラートを出すことがある(アプリが前面でも・スキーム登録が1アプリだけでも出る)。
  **同意は端末+アプリの組で永続する**(以後は無警告で配送される)
- **アラートはアプリスコープのスナップショットに1要素も現れない** —— `com.apple.springboard` へ
  attach したときだけ木に出る(既存の springboard 参照 SystemUIDriver/fallbackDriver と同じ経路。
  「type の受け皿にできない」制約とは別用途)。アプリ側から見ると「何も起きなかった」ようにしか
  見えず、沈黙して失敗する
- fleetest の対処: `openURL` 直後に springboard へ attach → アラートを同定 → 確定ボタンを押す →
  対象アプリへ戻す。**`(デバイス, bundleID)` ごとにプロセス内で1回だけ**試みる
- **同定条件**(3つとも満たさなければ何も押さない): アラートの label が**表示名を引用符で
  囲んだ形**(`"名前"`)を含む / ボタンが**ちょうど2つ** / 押すのは**ツリー順で最後**
  (右側=確定)。**素の部分一致にしてはいけない** —— 表示名は互いの部分文字列になり得る
  (`FT E2E` ⊂ `FT E2E RN`。iOS の4 SUT が同居する E2E シミュレータで実際に起き得る形)
- **in-app エンジン単独では自動了承できない**(in-app ブリッジの `/session` は自分の bundle
  以外を 409 で拒否するため springboard を見られない)。hybrid 構成では XCUITest 側の接続が
  受け持つ。4 SUT の `ios-inapp` プロファイル全緑で hybrid 経路の動作を確認済み

### Shirates(Classic) 準拠の方針と承認済みの差分(2026-08-04 更新)

**コマンド名・引数名・既定値・挙動は Shirates(Classic) をそのまま踏襲する**。独自の「改良」を
しない — 差分を作るときは実装前にユーザーへ提示して判断を仰ぐ(経緯: 独自アレンジを重ねて
指摘を受けた)。迷ったら `~/github/wave1008/shirates-core` のソースを読んでから書く。

**準拠状況の正典は [shirates-parity.md](shirates-parity.md)**(何が揃っていて何を持たないかの
全リスト)。**コマンドを足す・名前を変えるときに更新するのは向こう**で、こちらの表は
**理由の説明が要る代表例**を抜き出したもの(挙動差を見つけたら、まず parity に載っているかを見る。
載っていない挙動差は準拠漏れ = バグとして扱う):

| 差分 | 理由 |
|---|---|
| `FTScrollDirection` に `None` が無い | 「スクロールしない」は引数の省略(Optional)が担う |
| スクロールの時間指定(`scrollDurationSeconds` / `scrollIntervalSeconds`)が無い | 現行のフリング前提の実測値(Android 300ms・端送り 150ms+fling / iOS 端送り velocity 1500)を捨てることになるため。**間隔は固定 sleep でなく静止待ち**で担保する。`scrollFrame` とマージンは 2026-08-02 に実装済み(既定値だけ fleetest の実測で決める) |
| `(a\|b)&&[2]` は「各節の2番目」(Shirates は和集合の2番目) | 節ごとに `[n]` を持つ fleetest の構造をそのまま使う |
| `!` 短縮形で序数を否定できない(`![2]`) | 候補集合を絞れず黙って無視されるため実行前エラーにする |
| テキスト検証(`textIs` 等)に `scroll:` が無い | ユーザー決定(上記「再提案しない」項) |
| `thisIs` 系が素の値にも直接生える(`FTValue` 転送) | Swift は非 Optional に `Any?` 拡張が生えない(言語制約の吸収であり挙動差ではない) |
| 相対セレクタの引数の `(a\|b)` は括弧を自分で書く | `:right(...)` の括弧が引数の括弧で `\|` の囲みにならないため |
| `scrollFrame:` に型付きセレクタ(`Sel`)版が無い(String 固定) | ユーザー決定 2026-08-04・**再提案しない**。1対1を保証するのは**対象セレクタ**まで。`scrollTo` は対象と `scrollFrame` の両方を取るためオーバーロードが 2×2 になり、他20コマンドと合わせて語彙が増える割に、`scrollFrame` は生成コードにほとんど出ない(下記「型付きセレクタ」) |
| フローベース相対セレクタ(`:flow` 等)を持たない | 根拠の無い調整値を要求する(上記 2026-07-26 決定・再提案しない) |
| `pressEnter` の iOS 実装がソフトキー tap ではない(xcuitest = `typeText("\n")` / inapp = 受け口ごとに Compose は `insertText("\n")`・UIKit は delegate 再現・Flutter は engine への配送) | キーボード要素をスナップショットから除外しているため tap できない。受け口で機構が違うのは iOS 側の事情(上記「iOS の Enter は…」)。観測できる挙動(Return キー相当)はいずれも同等 |
| `back()` は Shirates の `pressBack`(Android 専用)を home()/appSwitcher() と同列の OS 差吸収コマンドとして両 OS 提供(iOS はエッジスワイプ) | iOS に物理バックが無く、コマンド語彙を OS で割らない方針 |
| `swipePointToPoint` / `swipeElementToElement` に withOffset・offsetY・intervalSeconds・repeat・safeMode・marginRatio・adjust が無い | ブリッジの drag が単発ジェスチャのため |
| `optional:` 引数を持たない(Shirates は `throwsException: false`) | ユーザー決定 2026-08-02・**再提案しない**。「出るか不定」はアプリ内メッセージなら `irregularHandler`、その場限りなら `ifCanSelect { }` で表す。空振りを黙って許す引数が操作系に付いていると、腐ったセレクタが緑のまま残る。掴めないことが答えになり得る `select` だけは失敗させず空要素を返す |
| `notExist`(Shirates は `dontExist`) | 否定の意味が読み取りやすく `exist` との対称も保てる(ユーザー決定 2026-07-31・**再提案しない**) |
| `existAll` / `dontExistAll` を持たない | `exist` のチェーンで書く方が保守しやすく、要素ごとに `timeout:` / `scroll:` を指定できる(ユーザー決定 2026-07-31・**再提案しない**) |
| `clearInput` がソフトキー/Appium clear 機構ではない(xcuitest=末尾タップ+delete 連打 / inapp=first responder のテキスト置換 / Android=ACTION_SET_TEXT "") | キーボード要素を snapshot から除外しているため(pressEnter と同じ事情) |
| キーボード可視の取得元がエンジンで違う(iOS xcuitest=AX ツリーの `.keyboard` ノード / iOS in-app=`UITextEffectsWindow` の可視判定 / Android=ホストが見る dumpsys の InputMethod window) | IME が別プロセスの window でアプリの a11y ツリーに出ないため(iOS の2経路の事情は下記「キーボードの観測と `hideKeyboard`」) |
| `waitForDisplay` / `waitForClose` に `throwsException` が無い(タイムアウトは常に失敗として記録) | `optional:` 全廃(2026-08-02)と同じ方針。空振りを許すと腐ったセレクタが緑のまま残る(2026-08-03 承認) |
| `waitForClose` の expression 省略(Shirates の直前セレクタ再利用)は不可 | 2026-08-04 に `lastElement`(暗黙の要素保持)を実装したので当初の理由(概念が無い)は消えたが、**省略形は引き続き置かない** —— 待っている対象がソース上で読めなくなり、直前のコマンド次第で待ち先が変わる。値の読み出しと違って**待ちは何を待つかが読めることが要**(2026-08-03 承認の判断を維持) |
| `waitForDisplay` の判定は `exist` と同じ可視性込み(Shirates は `safeElementOnly=false` のツリー存在判定) | コマンド名の意味(displayed)に沿い、既存の exists 検証機構をそのまま使う(2026-08-03 承認) |
| 待ち系(`waitForDisplay`/`waitForClose`/`appIs`)のポーリング間隔が `PollBackoff`(100→1000ms)である(Shirates は 0.2s 固定) | ポーリングは既存機構の再利用が契約(PollBackoff.swift「コピペ禁止」)。既定の待ち秒数 15.0(`WAIT_SECONDS_ON_ISSCREEN`)は踏襲(2026-08-03 承認) |
| `screenshot` が `force`/`onChangedOnly`/`withXmlSource` を持たない(`filename:` のみ) | この3引数は Shirates の auto-screenshot 機構(毎操作の自動撮影・変化なしスキップ・XML dump)の制御で、fleetest はその機構自体を持たない(撮るのは失敗時の証跡と `screenshot()` の明示呼び出しだけ)。画像はレポートの該当ステップ直後に埋め込む(2026-08-03 承認) |
| `flick*` は画面基点の8種のみで、`scrollableElement`/`safeMode` を持たない。`flickAndGo*` 一族・要素基点 `flickTo*`/`flickOut*` は持たない | 領域指定は `scrollFrame` のセレクタ式で足りる(既存の scroll 系と同じ判断)。`flickAndGo*` は scroll 系の別名で語彙を増やすだけ(2026-08-03 承認) |
| `verify` が Shirates の `MANUAL` 相当(強制 passed 化)を持たず、アサーション0個は**ステップ状態 inconclusive** | 2026-08-03 ユーザー決定。MANUAL の語彙は持たない(`manual`/`knownIssue` を入れない既存方針と同根)が、失敗にもしない。passed でも failed でもない中間状態(`StepResult.Status.inconclusive`)として理由つきで記録し、シナリオは中断しない。弱い修正提案も残す |
| `appIs` はニックネーム解決を持たず ID(iOS=bundle ID / Android=package)を直接書く | fleetest はアプリのニックネーム機構自体を持たない(既存方針。2026-08-03 承認) |
| `packageIs` を持たない | 2026-08-03 ユーザー決定(いったん実装後に削除)。ニックネームが無い fleetest では `appIs` が ID 直指定のため Android で完全に同じ検査になり、同じことを2通りで書ける語彙になる。**再提案しない** |
| `tapAppIcon` が `auto` 相当のみ(method 切替・マクロ機構なし) | 対象は実質エミュレータ/シミュレータで `auto` の分岐だけで足りる。名前省略時の既定は installApp と同じ形で親が解決する(`--app-name` = プロファイルの `appName`。2026-08-03 決定。実行自体は子のまま — UI 操作は「1シナリオ=1プロセス=1ドライバ」の子の責務で、親が同じランナーを叩くと二重クライアントの事故型になる) |
| `installApp` の実行主体がオーケストレータ(親プロセス)である | 2026-08-03 ユーザー決定。子(シナリオサブプロセス)は install の依頼だけを親へ送り(stdin/stdout RPC)、親が実行プロファイルの `appPath` を解決して実インストールする。パス解決の優先順は明示引数 > プロファイルの `appPath`(Shirates の `appPackageFile` 既定に一致)。オーケストレータ無しの単独実行だけ、子が直接 `driver.install` を呼ぶ従来経路にフォールバックする(パス解決は 明示引数 > `--app-path` > 明示エラー)。iOS in-app/hybrid ではインストールで in-app ブリッジが道連れになるが、次の `launchApp()` が再注入する(注記は実行中の ℹ️ ログにのみ出る。保存レポートには残らない) |
| `enabledIs(expected:)`/`checkedIs(expected:)`(生文字列親形)を持たず、糖衣形 `enabledIsTrue/False`・`checkIsON/OFF` のみ | 生値比較は OS 依存(checked の iOS "1"/"")で、正規化済み Bool と衝突する。糖衣形は OS 差を吸収済みで fleetest の正規化と一致(2026-08-04 ユーザー決定。旧 `isEnabled` 系4名からの改名も同決定 — Is 後置の社内語彙とも揃う) |

### `clearInput` の受け口ごとの機構と Flutter の縮退(2026-07-30)

嘘の成功(消えていないのに 200)を構造的に潰すため**3層**で守る:

1. **実行**: 受け口ごとに機構が違う。UITextField/UITextView は `.text = ""` + 変更通知の明示発火
   (`.text` 代入は `insertText:` と違い `EditingChanged`/通知を自動発火しない)/ その他 UITextInput
   (Compose の `IntermediateTextInputUIView` 等)は全文書レンジへ `replaceRange:withText:@""`
2. **受け口の自己検証**: 置換後に**読み返して**空を確認する。読み返せない受け口
   (`ftRemainingTextLength` が `NSNotFound`)は**空に見えても成功を主張しない** → 409
3. **ホストの事後検証**: `StepExecutor` が clear 後に値を確認し、残っていれば typeDriver へ、
   それでも残れば失敗。ref 無し版は `ElementInfo.focused` で対象を突き合わせる
   (`focused` を足したのはこのため。特定できないときは検証をスキップ = 検証不能を失敗にしない)

**Flutter iOS の in-app は非対応**(409 → xcuitest フォールバック)。**engine への editing state 配送は
評価のうえ不採用**(3回のデバイス実測):`flutterTextInputView:updateEditingClient:withState:` は実在し
(ランタイムのメソッド列挙で確認)、client も state のキー集合も正しいが、**Dart 側の
`TextEditingController` は空にならない**。`replaceRange` も view のローカル状態しか変えない
(併用すると engine への旧値の再通知が同期配送を上書きする挙動も観測)。**推測で私有 API を
積み増さない**方針(pressEnter の Flutter 対応と同じ規律)に従い、409 で既知の縮退へ落とす。
**pressEnter と違い clear は xcuitest フォールバックが届く**(ref 有/無とも実測。1.1〜2.2s)ので
機能は成立する。**再提案しない**(やるなら Flutter engine 側の公開経路が増えたとき)。

`type(sel, "…", replace: true)` はこの3層をそのまま使う(`StepExecutor` の `performClearInput`/
`performClearInputFocused` を type の前処理としても呼ぶだけ)。clear が失敗すれば type は撃たない。

### キーボードの観測と `hideKeyboard`(2026-07-30。keyboardFrame は 2026-08-08)

**観測(`keyboardIsShown` / `keyboardIsNotShown`)は3経路すべてで動く**が、取得元が OS で違う:

- **iOS xcuitest**: AX ツリー走査中に `.keyboard` ノードを見たか(`app.keyboards` クエリは使わない
  — キーボードが別プロセス扱いでタイムアウトする。`handleType` のコメントと同じ事情)。
  **「非表示」を確定できない**(見なかった = 不明で `keyboardShown == nil`)ため、
  `keyboardIsNotShown` はこのエンジンでは通らない(下記の nil 規約どおり明示的に失敗する)
- **iOS in-app**: **`UITextEffectsWindow` の可視判定**。キーボードはキーウィンドウの外に載るので
  AX ツリー走査では見つからない(閉じても window は残るため、画面内に張り出しているかで見る)。
  **非表示を false で確定できる唯一の iOS 経路**(2026-08-08 に一度 nil へ潰して
  `keyboardIsNotShown` を壊した — false を送り続けるのが契約)
- **Android**: ホスト側が `dumpsys window windows` の `InputMethod` window を見る(IME は別プロセスの
  window でアプリの a11y ツリーに出ない)。**dumpsys は固定費なので毎 snapshot では叩かない** —
  `AppDriver.captureKeyboardStateOnNextSnapshot()` を assert の直前に呼んだときだけ払う。
  採らなかった snapshot は `keyboardShown == nil` = 不明で、**nil を「非表示」と解釈しない**
  (`keyboardIsNotShown` が黙って通る嘘の成功になるため、明示的に失敗させる)

**キーボードが覆う実矩形は別フィールド `SnapshotResponse.keyboardFrame`**(2026-08-08。
取得元・罠・読み手は上記「ソフトキーボードの遮蔽」の表)。keyboardShown が可視性の Bool、
keyboardFrame が遮蔽警告用の矩形で、**申告できる条件が違う**(例: in-app は通知値が無いと
frame を申告しないが shown は言える)ため統合しない。

**`hideKeyboard` は Android のみ**(戻るキー。**出ているときだけ撃つ** — 出ていないと画面が戻って
しまうので、dumpsys で可視を確かめてから送る。これで冪等が保てる)。

**iOS は実装手段が無く 501 で明示的に未対応**(3手すべてデバイス上で不発。2026-07-30):
`XCUIKeyboardKey.escape` の `typeText` / 掴んだ responder への `resignFirstResponder` /
**nil ターゲットの `sendAction(resignFirstResponder)`** のいずれもキーボードが閉じない
(Compose の入力受け口が自前でフォーカスを保持するため UIKit の標準手段が届かない)。
残る手段は「キーボード上端より上の空白点をタップ」だが、**透明なタップ領域を踏む副作用**があり
`hideKeyboard` が副作用を持つコマンドになるため採らない(ユーザー決定)。
iOS で閉じたいときは `pressEnter()`(単一行の欄なら閉じる)。**再提案しない**。

### 型付きセレクタ(Sel。2026-07-27)

セレクタ式は文字列1本なので、綴り誤りをコンパイラが捕まえられない(実行前の `validationError` が
唯一の防波堤)。これを型で潰す**併設経路**として `Sel`(Sources/FTDSL/Sel.swift)を追加した。
**文字列版は一切変えていない**(署名・ステップ説明文・記録すべて同じ)。

```swift
tap(.id("login_btn"))                            // #login_btn
tap(.id("login_btn").or(.text("ログイン")))        // #login_btn||ログイン
tap(.id("list").find(.type(.cell).nth(2)))       // #list >> .cell[2]
tap(.text("通知").right(.switch))                 // 通知:rightSwitch
select(.id("txt_result")).textIs("dialog=none")   // 検証はセレクタを取らない(下記)
```

- **引数の型が具体型なので先頭ドットで書ける**(`tap(.id(...))`)。`some FTSelectorConvertible`
  のような総称にすると leading-dot が効かなくなるため、各コマンドは String 版と `Sel` 版の
  **2 つの具体オーバーロード**を持ち、共通の impl(FTSelector を取る)へ畳む
- **対象セレクタを取るコマンドは String / Sel が1対1**(2026-07-29 に非対称を解消)。
  Shirates 由来の別名族(`tapWithScrollDown/Up/Right/Left` `tapWithoutScroll` /
  `existWithScrollDown/Up` `existWithoutScroll` /
  `selectWithScrollDown/Up/Right/Left` `selectWithoutScroll`)にも Sel 版がある。
  **片方だけ足さない** — `Sel` を選ぶと別名族が使えない状態は「型付き経路を選ぶと機能が減る」
  ことを意味し、生成側を Sel 既定に寄せられなくなる。取りこぼしは
  `Tests/FTDSLTests/SelOverloadParityTests.swift` がソース走査で検出する
- **`scrollFrame:` 引数だけは String 固定**(Sel 版を持たない。ユーザー決定 2026-08-04・
  **再提案しない**)。1対1の対象は**対象セレクタ**であって全てのセレクタ式引数ではない。
  理由: `scrollTo` は対象と `scrollFrame` の両方を取るのでオーバーロードが 2×2 になり、
  他20コマンド(`scroll*` / `scrollToEdge` 系 / `withScroll*` / `flick*`)と合わせて語彙が一気に増える。
  一方で `scrollFrame` は**生成コードにほとんど出ない引数**(生成側は文字列版を出す既定)なので、
  「型付き経路を選ぶと機能が減る」の実害が最も小さい場所。
  `SelOverloadParityTests.testScrollFrameRemainsStringOnly` がこの決定を固定する
- **別名族は `maxSwipes:`(`select*` は `requireVisible:` も)しか取らない**(2026-08-02 に仕様として
  固定)。本体の全引数は生やさない — 別名の価値は「Shirates と同名で書ける」ことだけで、引数が
  要る場面では本体の `scroll:` の方が短い(`tap(sel, scroll: .down, timeout: 2)`)。全引数を生やすと
  同じことを2通りで書ける組み合わせが増え、生成側の語彙のブレになる。
  `existWithScrollLeft/Right` を置かないのも同じ判断。**引数の欠落を不整合として再提案しない**
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
- **生成側(`ScenarioCodeGen` / explore 生成 / `/fleetest-scenario`)は文字列版を出す。
  Sel を既定にしない**(ユーザー決定 2026-07-30・**再提案しない**)。生成コードは
  **人が必要に応じてカスタマイズする前提**で、`Sel` は型指定を好む人のためのシンタックスシュガー
  という位置づけ。したがって `Sel` の利用が少ないこと自体は想定どおりで、「未使用だから撤去/既定化」
  という判断にはならない。**再検討条件**: 人がカスタマイズしない領域の生成が出てきたとき
  (そこは綴りをコンパイラに任せられるので `Sel` で生成する余地がある)

### 掴んだ要素の値の読み出し(2026-07-29)

`exist` の戻り値 `FTElement` から `.text` / `.value` / `.id` で**値そのもの**を取れる
(Shirates の `TestElement.text` 相当)。これが無いと期待値をシナリオに書き切るしかなく、
「注文番号を控えて後の画面で照合」「画面の合計を読んで計算に使う」が書けなかった。

- **新しいコマンドを足さない**。`exist` が既に解決した要素を持ち帰るだけなので、
  **追加のデバイス往復もステップ記録も発生しない**(`CommandDispatchTests` が
  「exist 1 回 = スナップショット 1 回」を固定している)
- 経路: `StepExecutor.resolvedElementThisStep`(`observedCheckedThisStep` と**同じ受け渡し形**)
  → `StepOutcome.resolvedElement` → `FTDriveCore.perform` が返す `PerformResult.element` →
  `FTElement.matched`。**成功時しか立てない** — 失敗・スキップ・dry-run・
  対象が1つに定まらない assert(`notExist` / `countIs` / `screenLooksLike`)では nil。
  アクション(tap 等)は解決時点で立ててしまうので `execute` が `isSuccess` で落とす
  (「掴めなかったのに値が読める」を作らないための契約)
- **再取得しない**(値の出所は最初の `exist` に固定)。最新の値が要るなら `exist` を書き直す
- 型は `String?`。`ValueAssertions` の `FTValue`(`Optional: FTValue where Wrapped: FTValue`)に
  乗るので `exist("#total").text.thisContains("1,200")` がそのまま書ける
- `checked` / `enabled` の**値**は足していない(語彙を増やさない。検証は `.checkIsON` / `.enabledIsTrue` で足りる)
- **チェーンは網羅する**(2026-07-30): セレクタを取り「その要素」を検証する自由関数は
  **すべて同名で `FTElement` にも生やす**。一部だけだと「どれがチェーンできるか」に規則が無く、
  書いてみてコンパイルエラーで気付くことになる。例外は要素を1つに定めない
  `notExist` / `countIs` / `screenLooksLike` のみ。**検証コマンドを足すときは両方に足す** —
  取りこぼしは `vscode-fleetest/test/ftElementChainSync.test.mjs` が検出し、
  繋ぎ先の取り違え(`textContains` が `textStartsWith` を呼ぶ等)は
  `Tests/FTDSLTests/FTElementChainTests.swift` が実行して検出する(**形と挙動で担当が違う**)

### 暗黙の要素保持(`lastElement`。2026-08-04)

戻り値を受けていなくても直前に掴んだ要素を読める(Shirates の `TestDriver.lastElement` 相当)。
**鮮度のリスクを承知したうえでのユーザー決定**(2026-08-04。それ以前は「概念を持たない」が承認済み差分だった)。

- **更新点は1か所**: `Commands.swift` の共通経路 `perform(_:_:step:…)`。セレクタを取るコマンドは
  全部ここを通るので個々のコマンドに書き足さない(足し忘れると「どのコマンドで差し替わるか」の
  規則が崩れ、読み手が追えなくなる)。保持先は `FTDriveCore.lastResolvedElement`(DSL スレッド専有)
- **差し替えないのは要素を1つに定めないステップだけ**(`definesSingleElement`: `notExists` / `count`)。
  値の出所は `PerformResult.element` = 上記「掴んだ要素の値の読み出し」と同じ経路なので、
  **凍結・成功時のみ・dry-run は nil** の契約もそのまま継承する
- **掴めなかったときは空要素で上書きする**。前の要素を残すと**別要素の値を「今掴んだもの」として
  読む**ことになり、失敗が沈黙する(「空の結果は成功と見分けがつかない」と同じ型)
- **scene の切り替わりで捨てる**(`runScene`)。前の画面の要素は値も座標も古い
- **一度も掴んでいない読み出しは空要素 + 1回だけの警告**(`warnLastElementUnavailable`)。
  返す空要素には実在しないセレクタを持たせてあるので、チェーンした検証は必ず落ちる
- 規律の固定は `Tests/FTDSLTests/LastElementTests.swift`(差し替える/差し替えない・空になる条件)

### チェーンした検証の初回判定は掴んだ値で行う(2026-08-04)

`exist(…).textIs(…)` は**掴んだ時点の値で先に判定し、満たしていれば実機を見に行かない**。
満たしていなければ何もせず通常経路へ落ちる = 従来どおり取り直しながらポーリングする。
**ユーザー決定**(2026-08-04。それ以前はチェーンも毎回セレクタから解決し直していた)。

- **判定できるアサートの表は `FTCore/HeldElementAssert`**。比較そのものは
  `StepExecutor.matchedText` / `negativeAssertSatisfied` を**呼ぶ**(独自に書くと、同じアサートが
  チェーン経路と実機経路で違う答えを出す)。値ベース(text/value/id/enabled)だけが対象
- **除外**: `exists` / `notExists` / `count`(今の画面の話で過去の値から言えない)、
  `checked` / `notChecked`(実機経路が「checked を観測したか」を追跡しており、飛ばすと
  `checkIsOFF` の誤用警告が消える)、`screenMatches` / `keyboard*`(要素の値を見ていない)
- **可視性照合が走る設定では高速経路に入らない**(`visibilityWouldBeChecked`)。条件は
  `occlusionFlip` の入口のうちステップ非依存の部分と同じものを見る。飛ばすと
  falsePositiveCheck 有効の run で誤った緑の検出が**静かに1つ消える**
- 記録は通常どおり1ステップだが、説明に `(from the grabbed value)` を付ける
  (レポートで「取り直していない判定」を見分けられるようにするため。durationMs は 0)
- **残る危険は「古い値が偶然期待に一致して待たずに通る」向き**。`textIs` は本来
  「そうなるまで待つ」検証なので、`lastElement` のように掴んだ場所から離れるほど確率が上がる。
  承知のうえでの決定で、docs/commands.md にも注意として書いてある
- 規律の固定は `Tests/FTDSLTests/HeldValueAssertTests.swift`(往復回数で「見に行っていない」ことを
  直接数える。**古い値では不一致 → 取り直して一致** も必ず通す)

### 検証の対象は「直前に掴んだ要素」に固定(2026-08-04)

`textIs("#btn_ok", "OK")` の形(セレクタを取る検証の自由関数)を**廃止**し、対象は
`lastElement` に固定した。**ユーザー決定**。3つの書き方が同義になる:

```swift
select("#btn_ok").textIs("OK")                  // FTElement のメソッド(判定の実体)
select("#btn_ok"); lastElement.textIs("OK")     // 保持要素を明示
select("#btn_ok"); textIs("OK")                 // 暗黙(トップレベルの自由関数。委譲のみ)
```

- **対象は31コマンド**(text/value の全対称26 + `enabledIsTrue/False` + `checkIsON/OFF` + `idIs`)。
  **`exist` / `notExist` / `countIs` / `screenLooksLike` はセレクタを取り続ける** —— 要素を1つに定めない
  (`exist` は掴む側なので当然セレクタが要る)
- **判定の実体は `FTElement` のメソッド1か所**。自由関数は `lastElement.<同名>` へ委譲するだけで、
  ステップ記録も往復回数も一致する(`HeldValueAssertTests.testTheThreeFormsAreEquivalent` が固定)
- **セレクタを取る形の unavailable スタブは置かない**(未リリースで移行案内は不要・ユーザー決定
  2026-08-04)。`textIs("#id", "OK")` はコンパイラの素のエラー(`extra argument in call`)になる
- **1引数形にセレクタらしい期待値が来たら実行前に落とす**(`expectedLooksLikeSelector`)。
  `textIsNot("#btn_ok")` のような書き方は「そのテキストではない」が常に真で**黙って緑**になる。
  逃げ道はチェーン形(対象が明示なので曖昧さが無い)
- 3つの書き方の対応は `vscode-fleetest/test/ftElementChainSync.test.mjs` がソース走査で見張る
  (FTElement のメソッド集合 = 委譲する自由関数の集合。旧形の復活も検出する)
- **コード生成も新形で出す**(`ScenarioCodeGen` / `ScenarioDraftCodeGen`)。索引
  (`CommandIndex`)は signature を `select(selector).textIs(expected, ...)` の形で載せ、
  summary に「対象は直前に掴んだ要素」と明記する —— 生成側は JSON しか見ないため

### 否定・状態・個数のアサーション(2026-07-26)

- **`notExist`** は「消えるまで待つ」。初回で不在なら即成功、在ればタイムアウトまで消滅を待つ
  (`exist` の poll と対称)。可視性(occlusion)は見ない — ツリーから消えたことが唯一の判定。
  **`scroll:` を渡す(または `withScroll*` ブロックに入れる)と意味が変わる**: その向きへ
  探索しながら探し、**見つかった時点で失敗**する(`exist(scroll:)` の裏返し)。
  見つからなければ従来どおり現在のビューポートでの消滅待ちに進む。
  hybrid では **不在を確定する側でだけ** `fallbackDriver` を1回照会する(pass 経路の固定費 1 回。
  システム UI のダイアログが primary の snapshot に映らないため。miss 毎に払う `exist` 側とは事情が逆)
- **`checkIsON` / `checkIsOFF`**(セレクタの `checked=` も同じ源)は `ElementInfo.checked` を見る。
  取得元は **iOS = accessibility の selected trait**(`XCUIElementSnapshot.isSelected` / in-app は
  `UIAccessibilityTraits.selected`)、**Android = `AccessibilityNodeInfo.isChecked`**。
  Compose iOS は Switch の `value` を出さない(実測)ので selected trait が唯一の経路。
  **true のときだけ送る**(省略 = オフ、または状態を持たない要素)。
  **iOS 側は UI 実装依存**(2026-07-26 の 4 SUT 実測): Compose は selected trait を出すので取れるが、
  **SwiftUI/UIKit と Flutter の checkbox は出さない** → `checked` が nil のままで
  `checkIsON` / `checked=true` が当たらない。**Android 側は 4 SUT とも取れる**。
  iOS も含めて確実に見たいならアプリ側の echo Text を `textIs` で見る
- **状態フィルタ(`checked=` / `enabled=`)は型ではなく `#id` と併用する**(2026-07-26 実測)。
  同じ役割の要素でも型は SUT で割れるため(コントロール画面の無効ボタンは CMP では `button`、
  View/XML では `clickable`)、`.button&&enabled=false` のような型との AND は SUT 固有の式になる。
  `#btn_always_disabled&&enabled=false` なら 4 SUT 共通で通る
- **`enabledIsTrue` / `enabledIsFalse`** は `ElementInfo.enabled`(3 ブリッジとも埋めている)を見る。
  タイムアウトまで状態変化を待つ。「見つからない」と「状態が違う」を別メッセージで返す
- **`countIs`** は**ツリー上の**候補の個数。**可視性は見ない**(覆われた要素も折り返しの下の
  要素も1件に数える)。`exist` が(偽陽性検証を有効にした run で)可視性まで確認するのと
  **意図的に違う**: 件数ぶん FM を
  呼ぶことになり(FM は許可枠で制限される共有資源。performance-tuning.md §3.5)、
  リスト検証が実用的な速度でなくなるため。
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
- **`tap(scroll:)` / `type(scroll:)` / `exist(scroll:)`**
  (2026-07-27。Shirates の `tapWithScrollDown` 相当。別名も併設 = 下記「スクロールの語彙」):
  コマンド名の変種を増やさず引数で表す。**探索は同じステップに畳む**(`FlowStep.direction` /
  `maxSwipes` を tap/exists 自身に載せ、`StepExecutor.runScrollSearch` が解決前に走る)。
  実体は `scrollTo` コマンドと共有するので挙動は1箇所にしかない。
  探索終端の空打ちドラッグ(iOS)は**触る点が手前の要素に取られないときだけ**打つ
  (`pointIsTakenByFrontElement`。取られると覆っている要素が反応する。
  verification.md「スクロールした直後のタップ」)。
  **打つ相手の判定(`shouldEmptyDrag`)を起動時プローブの締切に預けない**(2026-08-15):
  あの締切は「suspend したアプリは TCP を受理して答えない」を素早く諦めるための値で、
  冷えた実機ブリッジが収まる保証は無い。外れて `uiFramework` が nil になると
  「不明なら打つ」へ倒れ、RN では横抜き 4pt が `pressRetentionOffset`(既定20pt)に収まって
  `onPress` が成立する = **`scrollTo` しただけで行が選択される**(E2E-RN S0100 を
  プローブ無応答で回して再現。`selected=row_40`)。自己申告が取れなければ
  **バンドルのマーカー**(`AppBundleInspector.detect(appPath:udid:bundleID:physical:)` =
  デバイスの応答が要らない)へ落とし、それも無ければ**盲打ちであることを run に残す**
  (判断は変えない —— 打たない側へ倒すと Compose の探索直後タップが容器に吸われる)。
  **別ステップにしない理由**: 利用者が書いたのは1コマンドなので記録も1行にする。
  合成ステップは**ソース行を持たない**ためジャンプも修正提案の照合もできず、説明の要る状態になる
  (2026-07-27 に一度その形で入れて、直した)。
  見つからなければ「N 回スクロールしても要素が見つかりません」で失敗(`select` だけは空要素を返して skipped)。
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
  (2026-07-27 実測: `scrollToTop` が row_22 付近で停止した)。署名は型と **x と y**
  (横スクロールでは y が動かない)。ref はスナップショット毎に振り直されるので使わない
- **署名にラベルを入れてはいけない**(2026-07-31 実測)。SwiftUI List では、静止画面でも
  画面外の再利用セル 2 件が取得のたびに別の行のラベルを名乗り、A↔B で交互に振れ続ける
  (frame は 1pt も動かない)。ラベルを含めていた頃は `settledSignature` が毎回ポーリング上限を
  使い切り、「2回連続で変化なし」も永久に成立せず、**`scrollToTop` が毎回 `maxSwipes` 上限まで
  回っていた**(E2E-iOS/ios-xcuitest で 44〜56s。同じ画面が in-app では 1.5s)。
  判定したいのは「動いているか」なので frame だけで足りる(`settleAfterScroll` も同じ)。
  **ランナー側の `captureSettled` は逆にラベルを外さない** — あちらは tap 直後の「内容が
  更新されたか」を待つので、レイアウト不変でテキストだけ変わる更新を取りこぼすと stale を返す
- **用途でジェスチャを変える**(`FTSwipeIntent`。2026-08-02)。同じ「上へ払う」でも要求が違うので、
  ホストが用途を `/swipe` へ伝えてブリッジがジェスチャを選ぶ。**ブリッジに用途の知識を集約する**形
  (`SwipeRequest.scroll` と同じ方針):
  - `gesture`(DSL の `swipe`)= 何も送らない。ジェスチャ自体が目的(向きの検出をアプリに見せたい)
  - `search`(`scrollTo` / `scrollDown` 等)= 何も送らない。**1回の飛距離がビューポート高を
    超えると要素を飛び越す**ので欲張らない
  - `edge`(`scrollToEdge`)= Android は `durationMs`/`fling`、iOS は `velocity` を送る。
    行き過ぎても無害なので最速で端まで送ってよい
  - **Android は距離を送らない・広げてはいけない**(速くするのはストロークだけ。距離はブリッジの
    軸別既定 縦 0.4・横 0.6 のまま)。スワイプは画面中央基準の全画面固定なので `distance` を
    0.8 にすると始点が画面の 10% になり、**スクロール領域の外から始まって1ミリも動かない**。
    iOS は速度のノブなので同じ事故は起きない(XCTest が要素の中で始点を決める)
  - **ラッパードライバは用途を必ず素通しする**(既定実装は用途を捨てる。`SwipeForScrollForwardingTests`
    がソース走査で検出)。数値の根拠と計測手順は performance-tuning.md §3.16 / §3.17
- **`maxSwipes` は暴走を止める上限で終了条件ではない**(端用の既定は `defaultMaxEdgeSwipes` = 50)。
  上限で抜けたときは**ステップに注記を出す**(黙って成功にすると「scrollToBottom したのに
  末尾が無い」の原因が読めない)
- `scrollDown(repeat: N)` は**各スワイプの間で静止を待つ**(待たないと同じ理由で空振りし、
  N 画面ぶん進まない)
- **ブロック**: `withScrollDown { }` 系は `FTDriveCore.scrollContextStack` に積み、
  ブロック内の `tap`/`type`/`clearInput`/`select`/`exist`/`notExist` が `scroll:` 未指定なら
  **その向きで探索**する(`notExist` だけは意味が裏返る。上記「否定・状態・個数のアサーション」)。
  `withoutScroll { }` と `tapWithoutScroll` / `existWithoutScroll` は積んだ文脈を1段打ち消す。
  明示の `scroll:` 引数が常に最優先(`FTDriveCore.effectiveScroll`)
- **`textIs` 等の検証コマンドに `scroll:` は持たせない**(ユーザー決定 2026-07-27)。
  静止した画面を詳細に検証するためのもので、条件が揃うまで自動でスクロールする挙動は望まれていない。
  **再提案しない**
- **`scrollFrame` でスクロール領域を指定できる**(2026-08-02。Shirates と同じくセレクタ式で受ける)。
  `scroll*` / `scrollTo` / `withScroll*` の引数で、`withScroll*` に渡すとブロック内の `scroll:` 探索が継承する。
  **指定時だけ**ホストが領域の矩形から座標を計算してブリッジへ渡す(`FTCore/ScrollGeometry` =
  shirates-core `ScrollingInfo` の移植。容器 ∩ 画面 → `startMarginRatio` / `endMarginRatio` で削る)。
  **マージン比の既定値の一次記載はここ**(`FTScrollDefaults`。Shirates の既定は踏襲せず fleetest の
  実測で決めた = 承認済み差分)。**直後の「縦 0.4 / 横 0.6」はスワイプ距離の既定であってマージン比
  ではない** —— 混同しないこと:

  | 用途(`FTSwipeIntent`) | 縦のマージン比(始点・終点とも) | 横 |
  |---|---|---|
  | `search`(`scrollTo` / `scrollDown` 等) | 0.25(スパン 0.5・重なり 50%) | 0.2 |
  | `gesture`(DSL の `swipe`)/ `edge`(`scrollToEdge`) | 0.2(スパン 0.6) | 0.2 |

  探索だけ保守側に取るのは、**慣性を消せないので刻み = 実移動量にはならず**、行き過ぎが探索の失敗に
  直結するため(速度を落として慣性を消す案は Android に同じノブが無く、2026-08-02 の実測で収束しなかった)。
  片側の上限は `FTScrollDefaults.maxMarginRatio` = 0.45(= スパンの最小 0.1)。
  **未指定は従来どおりブリッジ側の軸別既定**(縦 0.4 / 横 0.6 の全画面固定)—— 全画面固定のまま
  スパンを変えると始点がスクロール領域の外に出て 1 ミリも動かない(performance-tuning §3.16 の実害)。
  **画面に1件も無い scrollFrame は従来経路へ落とさず失敗させる**(2026-08-08。
  `StepExecutor.scrollFrameUnresolved` の fail-fast。1本も振らないので `scrollFrameFailFastMessage`
  は「送られなかった」と言い、送信中に容器が消えた場合だけ文言を差し替える。黙って全画面スワイプへ
  退化させていた頃はカード上のボタンを発火させる実害があった。`select` 系だけは空要素を返す契約が
  優先し skipped)。**容器は解決したが margin で動かせる幅が潰れたときだけ従来経路へ落ちる** ——
  こちらは容器自体が見つかっているので fail-fast を通らず、`resolved but leaves nothing to move`
  の注記を残して全画面スワイプになる(Shirates も明示 scrollFrame は**矩形の供給元**であって、
  スクロール可能かの判定はしない)。
  **in-app は座標を「対象 + 移動量」として読む**(始点で UIScrollView を特定し、始点と終点の差を
  contentOffset へ)ので**マージンも効く**。**端送り(`SwipeRequest.edge` = scrollToEdge)だけは
  移動量を無視して端まで一度に寄せる**(2026-08-19): この経路にジェスチャは無く慣性も無いので
  「1回 = ビューポートの 85%」は実機の体感に寄せた刻みでしかなく、端が目的なら刻む理由が無い。
  長文(利用規約等)ではホストの往復がページ数に比例していた。**`edge` を探索(`intent: .search`)
  へ広げてはいけない** —— 1回で端まで飛んで途中の要素を全部飛び越す。ただし **Compose/Flutter は 501 で XCUITest へ回す** ——
  自前描画では hitTest も AX も領域を絞れず、指定領域の外を指しても画面本体が動いてしまう
  (2026-08-02 に E2E-Flutter で実測)。時間指定は持たない(上記の承認済み差分)。
  **未指定のときに容器を特定して座標化する案は撤回済み**(2026-08-02 実装 → 撤回 →
  08-03 に条件を変えて再投入 → 再び撤回。**3度目は無い**)。2度目の撤回理由は2つ:
  狙いだった Compose の飛び越しに**効かない**(Compose の容器は xcuitest で `other` として出て
  `scrollable` を申告できず、そもそも対象に選べない)/ in-app では**到達距離が縮んで既定
  `maxSwipes` に届かなくなる**(E2E-iOS/ios-inapp の `tap("#row_40")` が失敗)。
  判定コードは `StepExecutor.scrollContainer` に残り、**`scrollFrame` 未指定なら必ず nil を返す**。
  暗黙対象を選ぶ `implicitScrollTarget` は **2026-08-05 に関数ごと削除した**(production から
  呼ばれておらず、生きているように見えるだけだったため。規則と再検討条件は
  docs/performance-tuning.md §3.19 に残っているので、必要になったら書き直す)。
  **未指定でも見切れ判定は容器基準で行う**: Compose は**容器の外に子(ghost)を報告する**ので、
  viewport を画面全体にすると容器の外の要素を「見えている」と誤判定して探索がそこで止まり、
  タップが飲まれる。`scrollable` の申告が無くても、スナップショットの `depth` から
  **clip 元の祖先を復元**して viewport に使う(`StepExecutor.clippingContainer`。
  **これは見切れ判定専用で、スワイプ座標には使わない**)。2026-08-03 修正・
  詳細は docs/verification.md「Compose の探索直後タップ」。
  **スクロールできない領域を指定したときは注記で申告する**(座標は正しく作られ 200 が返るが
  何も動かない = 端に達したのと区別できず署名では検出できないため)。判定は
  `ElementInfo.scrollable`(Android=`isScrollable` / xcuitest=型 / in-app=版57から
  `isScrollableContainer` = UIScrollView(content 0x0 は除外)or `UIFocusItemScrollableContainer`
  への**インスタンス毎の準拠**。Compose の AccessibilityElement は `conformsToProtocol:` を
  自前実装しスクロール可能なノードでだけ準拠を名乗る —— 公開プロトコルなので私有 API ではない。
  2026-08-08 PoC: sut-ec-mobile 3画面 + E2E-Flutter で誤検知0・見逃し0。id 無しの容器も
  snapshot に出すようにした)。**申告できないエンジン(Compose/Flutter の xcuitest)では
  黙る** —— 使ってよいのは true を見つけたときだけで、
  「false = スクロールできない」と読むと誤報になる

### 失敗時に返す情報(2026-07-26)

- **解決失敗のメッセージに「近い候補」を最大3件**添える(`StepExecutor.candidateHint`。
  id の部分一致 → ラベルの部分一致 → 同型の順)。直すための snapshot 取り直しを1往復減らす
- **レポートに失敗時点の要素一覧**を折りたたみで載せる(`SceneRecordData.failureElements`)。
  スクリーンショットからは `#id` を読めないため、機械が直すための一次情報はこちら
- **「`checkIsOFF` で通ったが checked を一度も観測できなかったセレクタ」を run 終了時に警告**する
  (2026-07-27)。ブリッジは checked を**true のときだけ送る**ので、状態を持たない要素
  (ただのボタン等)や状態を報告しない実装(**iOS の SwiftUI / Flutter の checkbox**)を指すと
  `checkIsOFF` は**何を書いても成功する**。notExist の id typo と同じ構造の穴なので同じ扱いにする
  (一度でも checked を観測できたセレクタは警告しない = 正しい使い方を潰さない)
- **`scene` 番号の重複を警告**する(2026-07-27)。番号は利用者が手で振るのでコピペで重複しやすく、
  レポートに同じ番号が並ぶとどちらの結果か読み手が判別できない。
  **失敗にはしない**(番号は実行順にも結果にも影響しないため、既存シナリオを止めない)
- **「否定側でしか使われず一度も解決できなかった `#id`」を run 終了時に警告**する
  (`FTDriveCore.warnAboutNeverResolvedIDs`)。`notExist` / `countIs(x, 0)` は id の綴り誤りでも
  成功するため、構文検証では捕まらないこの穴の最後の砦
- **`ifCanSelect` の不成立は `.skipped` で記録**し、最後まで不成立だった分岐は同じく警告に出す
  (`.passed` にすると「セレクタが腐って毎回飛んでいる」状態が緑のまま見えなくなる)
- **台帳に無い `#id` を dry-run で警告**する(2026-08-03。`SelectorInventory`)。セレクタの綴り誤り・
  でっち上げは構文検証を通り、従来は**実機で初めて**「見つからない」になった。MCP の `ft_snapshot` が
  撮った id を `<プロジェクト>/.fleetest/selector-inventory.json` に**和集合で**貯め、dry-run が突き合わせる。
  誤検知を出さない側に倒す設計: **台帳が無い/そのプラットフォームの記録が無いなら黙る**(「知らない」を
  「間違い」と言わない)・**台帳が薄いうちも黙る**(そのシナリオが触る id の **2/3 以上が台帳に在るとき
  だけ**警告する。有無だけで判定すると、1画面撮った状態で既存シナリオを回して **44/47 が誤警告**した
  —— 2026-08-03 のドッグフーディングで判明。**単体テストと『台帳が空なら黙る』の検証は両方緑だった**)・
  **完全一致の id だけ**(ワイルドカードとラベルは対象外。ラベルは文言変更で
  普通に変わるので警告にすると必ずオオカミ少年になる)・**古い id を消さない**(消すと警告が増える方向)。
  **書き手は `ft_snapshot` だけ**で、実行(run)の hot path では書かない(スナップショット毎の
  ファイル I/O を実行時間に載せない)。**照合も dry-run 専用**(実行では解決の成否そのものが答え)
- **アサーションが0個の `expectation` を警告**する(2026-08-03。`FTDriveCore.runSection` /
  `warnAboutMissingAssertions`)。「`action` に全部書いて `expectation` は `tap` だけ」
  「`exist` のつもりで `select`」はコンパイルも実行も通り、**アプリがどう壊れても緑**になる
  (`verify` の inconclusive と同じ穴を CAE 側にも塞ぐ)。シナリオ全体で0本ならさらに強い提案を出す。
  **数える定義は `FTDriveCore.noteAssertion` 1箇所**(`verify` と共有。定義が割れると片方だけ誤検知する)。
  `appIs` は `FlowStep` を持たない唯一の検証コマンドなので `performCustom(isAssertion:)` で合流させる。
  **`ios`/`android`/`ifCanSelect`/`repeatWhileCanSelect` の本体を実行しなかったときは黙る**
  (`noteUnexecutedBlock`。中身は実行しないと分からないので誤検知を出さない側に倒す ——
  `expectation { android { notExist(…) } }` を iOS で回す形が実際にある)。
  **デバイス不要**(`api run --dry-run` / `ft_dry_run` で判定できる = デバイス実行の前に落とせる)
- **アプリより手前にある別プロセスの window を失敗時に添える**(Android のみ。2026-07-27)。
  `AndroidForegroundWindows` が `dumpsys window windows` を z 順に読み、アプリの window より
  手前で `isVisible=true` かつ別パッケージのものを返す。**アプリの a11y ツリーには他プロセスの
  window が出ない**ため、覆われていても要素一覧は正常に見え、`tap` は成功扱いで返る
  (この穴に実際に2度落ちた。docs/verification.md「操作は ✅ なのに画面が変わらないとき」)。
  常時可視の装飾(StatusBar / Taskbar / NavigationBar / 画面装飾)とアプリ自身の別 window は
  除外し、アプリの window を特定できないときは黙る(誤った断定をしない)。
  配線は `FTScenarioRunner` からの closure 注入(FTDSL は FTAndroid に依存しないため)
- **割り込み(`irregularHandler`)は1ステップで最大10回まで閉じる**(2026-08-20 に「1回だけ」から緩めた。
  既定値で、`irregularHandler(…, maxDismissals:)` で宣言ごとに変えられる)。
  長いステップの最中に**2度目の配信**が湧くと、1回きりでは閉じ切れず待ち続けたまま失敗する
  (受け手要望。配信基盤が出す側なのでアプリでは止められない)。上限を残すのは**閉じても
  消えない相手に無限に付き合わない**ため。加えて**同じ検出が2回閉じても残っていたら打ち切る**
  (1回目で切らないのは、閉じるアニメーションの最中に撮った木で早合点しないため)。
  打ち切ったときは注記に `the interruption is still on screen after being dismissed` を出す ——
  黙って諦めると「割り込みのせいで落ちた」ことが読めない
- **対象を覆っているアプリ内要素を失敗メッセージに添える**(2026-07-27。`StepExecutor.coveringHint`)。
  アプリ内メッセージ・モーダルは**同一プロセスなので上の別 window 検出では捕まらない**。
  判定は `OcclusionSuspicion.covering`(ツリーのみの幾何。FM もスクショも不要 = FM が落ちていても効く)。
  **過検出寄りなので判定は変えず文言を足すだけ**にする(ステップの成否には触らない)
- **「手前かどうか」は `PaintOrder` の1箇所で決める**(2026-08-07。MCP の `RefGuard` と共有)。
  ツリーの並び順は描画順ではない —— Google マップは地図の chrome をシートより**後**に出すのに
  描画はシートが手前で、ツリー順の近似では**シートの裏に潜った chrome を1件も拾えなかった**。
  ブリッジが `ElementInfo.z` を申告する木(Android)では本物の塗り順、持たない木(iOS)では
  従来どおりツリー順へ落ちる。実測(固定コーパスの Android 5画面): 疑いの総数 153→108(−29%)・
  塗り順に起因する見逃し 8→0。**疑いが減ることには実利がある** —— `geometric` は FM を呼ぶかの
  前段で、FM は許可枠で制限される共有資源だから(performance-tuning.md §3.5)
- **撃つ前に言える「たぶん何も起きない」は注記にする**(2026-08-07。`TapTargetGeometry`。
  MCP と共有)。3形とも実測由来: **無効な要素**(木には `disabled` と印字しているのに操作経路が
  `enabled` を見ていなかった)/ **中心が中身のどこにも乗らない容器**(`#layers_fab_button` を
  叩くと中心が地図の上なので海上にピンが落ちた)/ **中心が画面の外**(2026-08-08 追加。
  Compose iOS はスクロールで縁の外へ出た行を frame ごと木に残し、`#slot_07`(中心 y=-18)への
  ref タップが無警告の "done" で 1px も動かなかった。ウィンドウ外のタッチは hitTest に乗らず
  黙って落ちる。縁の丸め誤差(実測 0.3pt)を拾わないよう猶予 2pt を置く)。
  **失敗にはしない** —— 無効な要素をわざと叩いて反応しないことを確かめる書き方は正当で
  `enabledIsFalse` もある。注記なら後段の失敗から原因へ辿れる。
  座標に依る警告は MCP(`RefGuard.overlapWarning`)と同じ優先順の1チェーン
  `TapTargetGeometry.occlusionAdvisory` に集約し、強い事実から**最初の1件だけ**言う:
  zero-frame → 画面外 → 申告 scroller 外の残像 → 中心を覆う最前面
  (`OcclusionGeometry.overlayCovering`)→ 中身外し → 内側の別アクション → クランプ残骸
  (`stackedRefs`)→ 細帯(sliver)。
  **関数は分けてある**(2026-08-08): `keyboardCoveredAdvisory`/`disabledAdvisory` は
  **撃つ座標に依らない**のでどの経路でも言えるが、チェーンの残りは
  **frame の中心を撃つときにしか言えない** ——
  `visibleTapRect` が見えている部分へ寄せる経路では「背後へ抜けた」が嘘になる。
  載せる経路は tap(寄せない側)・長押し(`press(ref:)` は frame 中心)・doubleTap の3つで、
  **pinch / swipeBy は対象外**(掴んで動かす形なので無効でも意味がある)
- **縁の帯に潜っているだけなら、撃つ前に容器を1回送って外す**(2026-08-27。
  `TapTargetGeometry.uncoverScrollJump` が唯一の判定元。利用者向けの説明は
  docs/commands.md §縁の帯に潜った対象)。実アプリで頻出する形で、受け手の SUT では
  4.7 インチ実機でログアウトがタブバーに潜り、タップがタブに当たって7本が巻き添えで
  落ちた(D-02)。**外せないと分かる3形では送らない**(操作可能でない覆い・容器の半分以上を
  占める覆い・容器の中心線を跨ぐ覆い)。**拒否はしない** —— 覆われた要素をわざと叩く
  書き方を壊さない。実装で得た知見が2つ:
  **①「覆いが対象の上か下か」では向きが決まらない**(中心を覆っている以上、覆いの矩形は
  必ず対象の中心を含む)。**②「容器の縁に接しているか」でも決まらない** —— タブバーの下端は
  セーフエリアぶん内側で、内容を潜らせた容器の下端と揃わない(実測: 帯 778..840 / 容器 200..873)。
  採ったのは**容器の中心線のどちら側にあるか**。
  witness は `E2E-iOS/scenarios/17_縁の帯に潜る.swift`(`#btn_under_footer`)で、
  **効くのは xcuitest だけ** —— in-app エンジンは要素を直接活性化するので座標のヒットテストを
  通らず、機能を殺しても緑のままになる
- **「この木は画面を代表しているか」も MCP と共有する**(2026-08-15。`TreeCoverage`)。
  形は2つで、どちらも**幾何からしか疑えない**(打ち切りと違いブリッジの申告が無い):
  **①webView の内側に大きな空白帯が残る**(Android の Chrome は web コンテンツの a11y ノードを
  部分的にしか公開しない。同じ URL を iOS Safari で読むと全部出るのに、画面に描かれている表が
  フルツリーにも1つも無い)/ **②アドレス欄はあるのに webView 容器すら無い**(Chromium は
  a11y を要求するサービスが繋がってから木を作るので、その窓で撮ると chrome だけが返る。
  実測でブリッジ起動直後 19 要素 → 5 秒後 135 要素)。
  閾値は固定コーパスの実測から置いた(①容器比 8% + 画面比 5%。取りこぼしのある Chrome の1枚が
  容器の 13.6%、健全な iOS Safari の3枚が 0〜3.3% / ②空白率 0.5。witness が 0.886、
  健全なブラウザ画面が 0.059)。
  **DSL 側は注記だけで判定を変えない**(`StepNote.treeUnderreported`)—— 幾何からの疑いで
  断定すると、空のページに対する正当な `notExist` が書けなくなる。
  **同型が `DuplicateRegion`**(横スクロールで前後のコピーが両方 木に残る形。片方は描かれて
  いないので撃つと別物に当たる)。`hasClampedCoordinates` は**同一 frame**を要求するので、
  x だけずれるこの形では発火し得ず、流用できない。DSL の tap は `StepNote.staleDuplicateRegion`。
  毎ステップ O(n²) を払わないよう `riskFor` に**掴んだ要素の相方を探す O(n) の門**を先に置く
  (門は必要条件でしかないので、通ったら必ず `find` で確かめる)
- **「誰が覆っているか」は最前面を名指しする**(2026-08-08。`OcclusionGeometry.occluder`
  [実体。`RefGuard` は転送]と DSL `OcclusionSuspicion.covering` の両方)。配列順で最初を返すと
  中間層(包んでいるシート)を名指しし、**実際にタップを受け取る最前面**を素通しする。実データでは
  `#place_page_tabs_container` ではなく**タップを受け取った広告行**が答えになった。
  **掃討ゲートは件数しか見ない**ので、この種の変更は明細(`FT_SWEEP_BASELINE=1`)で1件ずつ確かめる
- **occlusion-guard は絵の鮮度を確かめてから FM を呼ぶ**(`StaleFrameDetector`。MCP の
  ft_screenshot と同じ判定を共有)。「木は変わったのに絵が前回とバイト同一 = 凍結した古いフレーム」
  なら1回だけ撮り直し、なお stale なら**誤った緑への反転を宣言せず素通り**する(`StepNote.staleScreenshot`)。
  **判定は新規撮影のときだけ**(`guardScreenshot` の 200ms キャッシュ供給は同一 Data を返すため、
  比較すると木の揺れで必ず偽 stale になる)。`FrozenVerdict` には接続しない(凍結判定の定義元は
  あちらのまま。これはスクショ経路のローカルな鮮度確認)
- **pressEnter は焦点の合図を待ってから撃つ**(`FocusWait` を MCP `awaitFocus` と共有)。
  木のどこかの `focused` 申告か `keyboardShown` を合図に最大 1.5s。合図が無ければ警告注記+実行
  (拒否しない)。keyboardShown を第二の合図に持つのは Compose iOS(in-app は UIResponder でない
  要素の focused を申告しない)対策
- **type は「200 = 入った」を信じない**(`AppDriver.verifiesTypedText`)。xcuitest ランナーと
  Android 注入器は内部で読み返すので true、in-app は false で `StepExecutor.verifyTypedText` が
  ホスト側で読み返す(期待値 = 撃つ前の値 + 入力・前方一致は追送・超過は clearInput + 全文打ち直し・
  マスク欄は検証不能として受理・停滞は**失敗**)。値そのものは失敗文言に出さない。
  ラッパードライバは実行側の値へ転送する(既定 false は安全側だが二重読み返しの固定費が乗る)
- **run の開始前に「画面だけ死んだ」仮想デバイスを弾く**(2026-08-05。`BlankWorkerTriage`)。
  Android は `ProfileWorkerFactory.excludeOrRepairBlankScreenWorkers` が同じ位置で**修復まで**行うが、
  **iOS には軽い修復手段が無い**(確認できているのは `simctl shutdown`→`boot` だけ)ので
  除外して復旧コマンドをログに出す。**iOS(BlankWorkerTriage)**の判定は恒常 blank
  (2.5s 間隔で5連続。約10秒の観測窓)に加え、一様が続いた機だけ画面を必ず変える入力を送る
  能動プローブ(`nudge`)で仕分ける ——「描画要求が無いだけの黒画面」(入力で戻る)と
  「本物の wedge」(戻らない)は受動観測では原理的に区別できない(2026-08-11。拍動では
  分けられなかった)。**Android 側は 1.5s×2 の恒常 blank のみで nudge を持たない**
  (`AndroidHealthProbe.isPersistentlyBlank`。修復手段が sleep/wake で軽いぶん短い窓のまま。
  iOS と同じ窓+nudge へ揃えるかは未判断)。
  健全機は1サンプルで返る = 正常時の固定費はスクショ1枚。**実機は対象外**(消灯を凍結と誤断する)
- **容器の推測に依存する補正は3層で止められる**(上位から `FT_CONTAINER_INFERENCE=off` の殺しスイッチ /
  実行プロファイルの `containerInference` / DSL の `tap(containerInference:)`・`withoutContainerInference { }`。
  実装は `StepExecutor.execute` 冒頭の `Self.containerInferenceEnabled && (step.containerInference ?? 既定)` 1式)。
  容器は木からの**推測**なので想定外のツリーでは外れ得る。外れたときに起きるのは
  「別の場所を叩く」「明後日の方向へ送る」「正当な要素が候補から消える」= **より悪い事態**なので、
  推測の入口(`clippingContainer`)と `hasClampedCoordinates` の2箇所だけでフラグを見て
  まとめて無効化できるようにしてある。**見えている部分を撃つ補正には床(8pt/dp)**もあり、
  わずかな重なりへは突っ込まない。**床は木の単位へ換算してから比べる**(2026-08-15):
  iOS の木は pt・Android の木は px なので、そのまま当てると3倍密度で床が約3倍緩み、
  この床が防ぐはずの誤タップ(沈黙する)が素通りする。倍率は `AppDriver.pointScale`
  (iOS=1 / Android=`wm density`。**ラッパーは透過必須** ——
  `SnapshotCacheBypassForwardingTests` が全ラッパーで見張る)。
  pt(1/163 inch)と dp(1/160 inch)は物理的にほぼ同じなので、pt で測った床は dp として通用する
- **座標が壊れている要素は解決候補にしない**(2026-08-05。`StepExecutor.hasClampedCoordinates`)。
  フレームワークは**容器の可視域を外れた子孫の frame の原点を容器の原点へクランプする**ため、
  掴むと `tap` が別の要素へ落ち(可視性ガードを通らないので沈黙)、`exist` は画面外なのに真を返す
  (「exist は非スクロール」の契約に反する)。判定は**症状ではなく機構**で書く
  (同一 frame・同 depth が3つ以上 かつ 原点を貸す上位要素が居て 群がそれより小さい)。
  消したときは `clampedStackHint` が理由と回避策(先にスクロール)を失敗文言へ添える。
  規則の根拠と実採取は docs/verification.md「画面外要素の frame は信用できない」
- **飲まれたタップを失敗メッセージで名指しする**(2026-08-05。`StepExecutor.tapDiagnosisHint`)。
  タップには事後検証が無く(何が起きるべきかをホストは知らない)、飲まれると落ちるのは
  2ステップ先の検証なので原因が遠い。**タップ直前に解決で使った木**を覚えておき、
  失敗した検証が既に持っている木と突き合わせて、1ピクセルも変わっていなければ注記を足す。
  **追加のスナップショットを撮らないことが設計要件**(実行中に I/O を足すと事象が消える。
  docs/verification.md の heisenbug)。判定は変えず注記のみ。
  記録は `select` では消さない(`tap → select → textIs` が失敗の定型)。
  機構・署名の作り方・誤検知の向きは docs/verification.md「操作は ✅ なのに画面が変わらないとき」

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
  1 点でだけ行い、**修正提案の description は素のまま**(ソース行との照合に使うため)
- **`setUp()` / `tearDown()`**: 同じクラスに引数なし・非async・非throws で書くと `@TestClass` マクロが
  各 `@Test` の run クロージャに織り込む(基底クラスからの継承は見ない)。ライフサイクル無しの
  クラスの生成コードは従来どおり(`X().method()` の 1 式のまま)
  - **setUp の失敗はシナリオごと中断**する。`scene(n)` の入口は `sceneAborted` を毎回 false に戻すため、
    scene をまたいで効く `scenarioAborted` へ昇格させている(ここを外すと setUp 失敗が無視される)
  - **tearDown は失敗後でも実行**する(中断フラグを一時解除 → 実行後に「元の中断」と「片付け中の失敗」の
    OR で復元)。片付けが飛ぶと後続シナリオを汚すため。ただし**画面凍結・ユーザー中断(debug stop)では
    実行しない**(前者は別デバイスで振り直すので無駄、後者は「止めた」のに片付けで再び止まるのが不合理)

### 実行アーキテクチャ

- `scenarios/` を SPM の実行ターゲット(fleetest-scenarios)としてコンパイル。
  マクロが生成する登録クラス(NSObject 派生)を objc ランタイム走査
  (メッセージ送信なしの class_getSuperclass のみ)で自動発見する
- **1 プロセス = 1 シナリオ実行**のサブプロセス方式。ホスト(CLI/GUI/MCP)は ScenarioHost 経由で
  起動し、NDJSON イベント(FTCore/ScenarioEvent)を受信。ビルドはホスト側で1回だけ
- シナリオ本体は**専用スレッドで同期実行**し、async の StepExecutor/AppDriver へは
  セマフォで橋渡し(FTSync)。ブロックするのは専用スレッドのみで協調プールは塞がない。
  **上限(既定120秒)で諦めたら op を必ず cancel する**(2026-07-30)。放置すると諦めたはずの
  tap/snapshot が**後続ステップの最中にブリッジへ着弾**し、記録に残らないまま画面を動かす
  = 原因不明の一発ずれになる。cancel は届く(通信は `URLSession.data(for:)`、待ちは
  `Task.sleep`。どちらも cancel 対応)。cancel を見ない処理(Process 実行等)は走り切るだけで悪化しない。
  **副作用: op は任意の await 点で巻き戻り得る**ので、掴んだ資源の解放は `defer` に置くこと
  (契約は `FMGate.enter()` のコメント。ここを崩すとホスト全体の FM ロックが漏れる)。
  この上限は `procedure` / `doUntilTrue` にも効き、`doUntilTrue(waitSeconds:)` に 120 秒より
  長い値を書いても待てない(利用者向けの記述は docs/commands.md)
- 失敗セマンティクス: コマンド NG → **シナリオ全体を中断**(以降のステップは scene を跨いで
  すべて skipped。throw を使わない Shirates 的中断)。tearDown だけは失敗後でも実行される。
  2026-07-27 変更(ユーザー決定): 以前は scene 単位のスキップで次の scene へ進んでいたが、
  失敗後の画面状態は不定で、続けても壊れた前提の擬陽性/擬陰性を生むだけのため廃止
  (`abortScenarioOnFailure()` も既定化に伴い撤去)
- **登録不要の単発実行**: `fleetest run-file <path.swift>`(Sources/fleetest/RunFileCommand.swift)。
  `fleetest project create/sync` で Package.swift へ登録していない .swift をそのまま実行する。
  実装は「対象プロジェクトの `scenarios/_runfile/` へコピー → 通常どおり `RunScenarios` へ委譲 →
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
**プライマリ → フォールバック → キャッシュ(.fleetest/heal-cache.json)→ 指紋照合 → FM ヒール**
とした。キー = シナリオID + file:line + 旧セレクタ文字列。2回目以降は FM なしで決定的に通過し、
ソース位置付きの修正提案をレポートに出し続ける(ソース自動書換はしない。
人がソースを直すとキー不一致でキャッシュは自然に無効化)。

### ロケータの指紋(2026-09-02)

**FM を採否の判断から外す層**(`FTCore.LocatorFingerprint` / `FTDSL.LocatorFingerprintCache`)。
「id が変わってラベルは不変」という典型的なドリフトを、推測なしで解決する。
下の知見にあるとおり **confidence は信号を持たない**ので、FM に採否を委ねると
正しい提案まで却下される —— その判断を決定的な照合へ移す。

- **効くのは失敗経路だけ**(プライマリ・フォールバック・キャッシュがすべて外れたとき)。
  **今緑のステップの挙動は変えられない**ので、リスクがこの1箇所に閉じる
- **控えるのは `type` + `label`**(+ 非 nil のときだけ `placeholder`)。**`id` は控えない**
  —— ドリフトで変わるのがまさに id。**`value` も控えない** —— 実行ごとに変わる
- **ちょうど1件一致のときだけ採用**。0件・複数件は従来どおり FM へ落ちる。
  **スコアも距離も重み付けも作らない**(根拠のない定数を置かない)——
  複数件を「もっとも近い」で選ぶと別要素へ静かに解決し、誤った緑を作る
- **記録するのはプライマリ/フォールバックで素直に解決できた回だけ**。指紋・ヒール・FM で
  解決した回を記録すると、誤った解決が指紋として固定化され再生産される
- **ヒールキャッシュへは書かない**。指紋は決定的で毎回再導出できるので、キャッシュしても
  得られるのは速度だけ。一方、一意に一致したが実は別要素だった場合に誤りが永続化し、
  以後 `healedByCache` として解決されて注記が消える。**FM ヒールは confidence の門を
  通ってからキャッシュに入るが、指紋にその門は無い**。修正提案は出す(提案と固定化は別)
- 注記 `heal-fingerprint-match` を必ず立てる(結果 JSON に出て run 横断で数えられる)
- 書き出しはメモリに溜めて `defer` で1回だけ(`HealCache.store` の毎ステップ I/O を払わない)
- **失効はシナリオ単位の置き換え**(時間の定数は使わない)。鍵が `file:line` とセレクタを含む
  以上、利用者が**行を足す/消す・セレクタを直す**たびに古い鍵が生まれ、二度と lookup されない
  まま永久に残る(実測: 1 run で 90 エントリ / 19.6KB)。シナリオが**通った**とき、その
  `scenarioID` の鍵のうち今回触れなかったものを刈る。守る条件3つ ——
  **①通ったときだけ**(失敗・中断した run は後続ステップに到達していないので、刈ると
  生きている指紋を落とす)/ **②そのシナリオで1件以上記録していたときだけ**(全ステップが
  キャッシュ・指紋・FM で解決した run は記録0件になり、刈るとそのシナリオの鍵を根こそぎ失う。
  **消してはいけないガード**)/ **③接頭辞 `"<scenarioID>|"` で自分のぶんだけ**
  (`--scenario` の部分実行で他シナリオの指紋を巻き込まない)

**witness は `TestProjects/E2E-CMP/scenarios/_disabled/94_指紋照合.swift`**。
`90_自己修復` は scene 1 で必ず v2 へ切り替えてから撃つので**対象行が一度も成功せず**、
指紋の witness にならない(あちらは cold state からの FM 修復を見るもの)。94 は
「同じ行が一度成功し、次にドリフトする」状況を作る。**状態(schema)の制御はシナリオの外**に
置く —— 中に入れると失敗中断時に後始末の scene へ到達できず回復しない。
**schema は台ごとのアプリデータ**なので両周を同じ `--device` に固定すること
(指紋はホスト側のファイルなので、台を跨ぐと指紋だけが引き継がれて噛み合わない)。

実測(2026-09-02): ドリフトした `#btn_heal_v1` が `#btn_heal_v2` へ **FM 呼び出し無し**で解決し、
アプリ側の記録が `tapped=v2`(正しい要素を叩いた証拠)、`heal-cache.json` は生成されない。
フル E2E 231 シナリオで採取 304 件・`workerAnomalies` 0 件。

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
- **confidence は採否の根拠に使えない**(2026-09-02・`Scripts/fm-verify.sh` を5周。
  `sampling: .greedy` なので全周で完全に同一の出力)。上の「誤要素を高確信で」と合わせると、
  **信号が両方向に外れる = 情報を持たない**:

  | シナリオ | 提案 | 正誤 | 自己申告(案1 前 → 後) |
  |---|---|---|---|
  | `90_自己修復` | `#btn_heal_v2` | **正解** | low → **low**(各 5/5) |
  | `93_triage` | `#nav_selector` → `#nav_input` | **誤り** | medium → **low**(各 5/5) |

  「案1 後」= `elementText` を省略可能にして「代わりが無ければ挙げるな」と `@Guide` に
  書いた後。**逆相関(誤答に高い確信)は消えたが、今度は正解も誤答も low で区別が付かない**。
  なお**モデルは省略の逃げ道を一度も使わなかった**(`heal-no-replacement` の発火 0/5)——
  何かを名指しする傾向はスキーマの制約ではなく**モデルの性質**。
  ただし誤答の確信が下がったこと自体は誤検知を減らす方向なので変更は残す。

  **閾値の調整では解けない** —— `medium` へ下げると誤答が通り、`low` へ下げると何でも通る。
  自己較正は小さいモデルが最も苦手とする能力で、**現行設計はそこを採否の唯一の門にしている**。
  一方で「一覧から役割の同じ要素を選ぶ」ほうは実測で足りている(正解を 5/5 で指した)。
  採否を confidence 以外の決定的な根拠へ移す案は **2026-09-02 に実装した**
  (このすぐ上の「ロケータの指紋」)。懸念していた「古い指紋で静かに誤った要素へ解決する」は、
  **一意一致のときだけ採用**・**失敗経路でしか動かない**・**注記を必ず立てる**の3つで抑えている
- **ヒールが黙って諦める経路は3つあり、全部に注記を置いてある**(2026-09-02。それ以前は
  どれも `cannot resolve the locator` としか出ず、`fm.byKind.heal` に呼び出しが記録されている
  のに何が起きたのか一切分からなかった): 一意に指せるセレクタが無い(`heal-unwritable`)/
  confidence が `high` に届かない(`heal-proposal-rejected`)/ 答えを木へ引き戻せない
  (`heal-answer-unresolved`)。**FM の応答後の写像は `FMReplayDelegate.healAttempt` に
  切り出してあり(FM もデバイスも要らない純粋関数)、戻り値は非オプショナル** ——
  `nil` は「FM を呼べなかった」だけを意味する。ここを `HealAttempt?` に戻すと
  「黙って nil」が再び書けるようになる(実際に変異テストがその退行を1件も落とせなかった)
- **プロンプトには壊れたロケータを名指しし「それを答えにするな」と書く**(2026-09-02)。
  書く前は**モデルが壊れたロケータをそのままオウム返し**していた(`btn_heal_v1` を提案 →
  木に無いので不一致)。同じ木から triage は正解を出せていたので木の問題ではない。
  名指ししてからは 5/5 で正解の要素を選ぶ。組み立ては `FMReplayDelegate.healPrompt`(純粋関数)
- **xcuitest の `launchApp` も既定で simctl 化**(FastLaunchDriver・2026-07-21)。
  XCUIApplication.launch()(約4.6s)の代わりに simctl terminate+launch+activate 接続(約2.4s)で
  再起動する(シナリオ wall −14〜19%)。`FT_NO_FAST_LAUNCH=1` で従来動作へ戻せる。
  attachOnly(整定なし接続)を launch に使わない理由は performance-tuning §6
- **inapp の `launchApp` は毎回 `simctl launch --terminate-running-process` で terminate+relaunch する
  が、アプリのデータは消さないためアプリがディスクへ永続化した直前ルートを復元し得る**(プロセス
  再利用ではない)。決定的なナビ状態リセットはアプリ側の責務で、ツールは状態リセットの注入
  (`SIMCTL_CHILD_FT_RESET` 等)を意図的に提供しない(ユーザー決定・2026-07-20)。
  シナリオ側は scene1 で対象タブをルートへ正規化して吸収する
- **`launchApp` は全エンジンで常にプロセスを再起動する**(前面化ではない。Android は
  ブリッジの force-stop+起動、xcuitest は FastLaunchDriver の terminate 込み launch)。
  「起動済みならプロセス温存でエントリー画面へ」の warm 化は 2026-08-08 に実装・検証まで
  行ったうえで**中止・破棄**した: Android は `am start --activity-clear-task` で成立するが、
  **iOS には起動済みプロセスをエントリー画面へ戻す OS 機構が無く**、前面化(activate)だけでは
  「起動直後の最初の画面」という契約を満たせない(片 OS のみの機能では意味が無いという判断)
- **in-app の木は可視な窓を全部歩く**(2026-08-20。それまではキーウィンドウ1枚だけ)。
  **別 UIWindow に載るモーダル**(アプリ内メッセージ SDK 等)が木から見えないと、
  画面を覆っているのにテストは何も失敗しない —— タップは `activate`、スクロールは
  `contentOffset` の直接書き込みで**どちらも hitTest を経由しない**ので**覆いが障害物にならず**、
  `irregularHandler` も照合対象が無いので発動しない = **誤った緑になる**
  (受け手報告。自前 SUT の `OverlayWindow` で再現 → `bridgeProtocolVersion` 75 で修正)。
  **`UIAlertController` は自分の窓を key にする**ので以前から載っていた。載らなかったのは
  **key にしない**窓で、そこが SDK 系オーバーレイの形。
  並びは **windowLevel の昇順**(手前を後ろに置く。ホストの遮蔽判定が「後に出るものが上」を
  前提にしているため)。**キーボードの窓だけは除く**(キーが大量に写り込むうえ、表示判定と
  実矩形は `keyboardIsVisible` / `keyboardFrameIfVisible` が別に申告する既存の設計)。
  **覆われた要素は落とす**(`InAppSnapshot.isCovered`): 前後の窓を両方載せると
  「覆われているのに `exist` が通る」が残る。判定は**その位置で手前の窓がタッチを受けるか**
  (`hitTest`)。**「手前の窓だけ見せる」にはしない** —— 画面の一部だけを覆う形(上部バナー・
  ハーフシート)で**触れる背面まで消える**か、逆にバナー自体が見えず `irregularHandler` で
  閉じられなくなる(2026-08-20 に両形の witness で確認)。
  限界: 判定は**タッチが届くか**であって**目に見えるか**ではない —— `isUserInteractionEnabled = false`
  の不透明な飾り窓は背面を残す(触れる以上、操作の前提としては正しい側)。
  witness は `E2EAppIOS` の `OverlayWindow`(全画面モーダル / 上部バナーの2形)と
  `TestProjects/E2E-iOS/scenarios/15_別ウィンドウのモーダル.swift`
- **操作の宛先も窓で決める**(2026-08-20 の追加報告。版 76)。木だけ複数窓にすると
  **見えているのに閉じられない**が残る —— `activate` が不発で合成タッチへ落ちた瞬間に
  **キーウィンドウ(= 背面のアプリ)へ撃つ**ため。ref を持つ操作は
  **その要素が載っている窓**(`InAppBridge.window(of:)`。`accessibilityContainer` を辿る。
  **`value(forKey:)` は使わない** —— 未定義キーの例外は Swift で捕まえられず対象アプリを落とす)、
  座標だけの操作とスクロールは**いま指が当たる窓**(`frontmostTouchableWindow`)へ送る。
  **スクリーンショットも可視な窓を重ねて描く** —— キーウィンドウ1枚だけだと
  「モーダルが写っていない証跡」を残すことになる
- **inapp は Compose Multiplatform(iOS)の swipe/scrollTo/press を駆動できない**
  (2026-07-22・`TestProjects/E2E-CMP` で切り分け確定)。同一アプリ・同一シナリオの両エンジン差分:
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
  1. **ブリッジ**: Compose/Flutter 検出時、**ジェスチャ目的**の `/swipe` と `/press` は **501**
     (`InAppBridge.handleSwipe`/`handlePress`。判定は `/status` と同じ `compose-resources` /
     `Flutter.framework` マーカー)。黙って空振りするより「12回スクロールしても見つかりません」の
     ような誤診断を防ぐ方が価値が高い。
     **409 ではなく 501 なのは意図的**: 409 はキーウィンドウ不在等の一時的競合にも使われるため、
     フォールバック判定に使うと「アプリが前面に無い」状況を隠して別画面を操作しかねない
     (`/terminate` が既に 501=このエンジンでは未対応 を返している慣習に合わせた)。
     **スクロール目的(`SwipeRequest.scroll`)だけは 2026-07-31 から in-app で通る** ——
     UIAccessibility の scroll アクション経由(上の「Compose/Flutter のスクロールは
     UIAccessibility の scroll アクションで駆動する」の節)。この段の記述は**ジェスチャ目的に限る**
  2. **事前ルーティング**(2026-07-23 導入 / 2026-07-31 に swipe を除外): hybrid は in-app と
     XCUITest の両ブリッジを張るので、起動時プローブの **`/status.unsupportedActions`**
     (ブリッジが「この対象アプリでは実行できない」アクション名を申告する)に該当し typeDriver
     ありなら**最初から** typeDriver(`AppAttachDriver`)へ回す
     (`StepExecutor.typeDriverGestures`)。409 の往復はゼロ。
     **申告は現在 `["press"]` だけ**(以前は Compose/Flutter で `["swipe","press"]`)。
     swipe を外したのは、可否が**目的と画面で割れる**ようになり「一律不可」では表現できない
     ため。swipe の可否判定は `handleSwipe` に一本化してある
  3. **事後 501 キャッチ**: プローブ不達で 2 が立たなかった場合の安全網。1回 501 を受けたら
     ラッチして以降は直接 typeDriver へ(`scrollTo` は maxSwipes 回まわるので毎回往復させない)。
     `type` の 409 安全網と同じ形。**press は ref がブリッジごとに別名前空間**なので
     typeDriver 側で snapshot し直して再解決する(`pressViaTypeDriver`)

  これにより **hybrid では Compose でもジェスチャが通る**(`TestProjects/E2E-CMP` の `ios-inapp` が
  18/18・37.3s。導入前は3シナリオ失敗・93.9s)。tap/type/スナップショットは高速な in-app のまま。
  409 が表面化するのは **typeDriver が無い構成**(engine=inapp 単独・xcuiPort 無し)だけで、
  そのときはメッセージが xcuitest プロファイルへ誘導する。
  なお `type` の事前ルーティング(`preferTypeDriver`)は別物で廃止済み — Compose でも inapp の
  type が可能かつ高速(266ms vs attach 1.0〜1.3s)なため。ジェスチャは inapp が**不可能**なので
  トレードオフの向きが逆になり、事前ルーティングが常に得になる
- **「in-app で不可・XCUITest で可」は常に XCUITest へ回す**(2026-07-28 にユーザー決定で一般化)。
  判定は `DriverError.isEngineIncapable` の1箇所: **501 と「ルート不明の 404」(本文 `not found:` 前置)
  だけ**。**409 は含めない**(上記の理由。in-app の 404 には ref 不明もあるため本文で見分ける)。
  対象は3つ:
  - `home` / `appSwitcher`: in-app は自プロセス外を触れないので**原理的に不可**。hybrid では
    501 の往復を作らず最初から XCUITest へ直行する(`FTDriveCore.systemDriver`)。XCUITest 側の
    `/home`・`/appswitcher` は**セッション不要**なので attach も activate も挟まない
  - `drag`(スクロール探索直後の**空打ち極小ドラッグ**): in-app は drag を実装しない。回さないと
    Compose の容器がタッチを1回吸ったままになり直後の tap が空振りする。**ラッチは swipe と共有
    しない**(`dragFallbackLatched`。共有すると drag の 501 だけで全 swipe が XCUITest 実スワイプ化し、
    バウンス由来の flake を持ち込む)。空打ちは補助なので両経路の失敗はステップの失敗にしない
  - `swipe` / `press`: 既存の申告+事後キャッチ(上記 2〜3)。判定だけ共通化した
- **MCP(`ft_*`)は実行プロファイルのエンジンに追従する**(2026-08-04 ユーザー決定。
  それ以前は「live / MCP は in-app を使わない」= 常に XCUITest だった)。
  **揃える理由は探索と実行で見えるものを一致させること**: snapshot の内容もジェスチャの成否も
  エンジンで変わるため、揃えないと「MCP では動いたのにシナリオでは落ちる」(およびその逆)が起きる。
  - 旧決定の根拠だった「`StepExecutor` を通らないので `home`/`drag`/座標 `press` が素の 501 になる」は
    **`HybridFallbackDriver` が埋めた**: in-app が原理的に不可な操作(501 / ルート不明 404)だけを
    attach 済み XCUITest へ回す。**ref を使う操作は回さない**(ref はブリッジごとに別名前空間で、
    渡すと無関係な要素を操作する)。唯一 `press(ref:)` だけは primary の snapshot で
    **座標へ畳んでから**回す
  - 合成は実行側(`ScenarioRunnerMain`)と同じ形:
    in-app(注入)→ WebView 画面だけ XCUITest へ委譲 → 不可な操作だけ XCUITest へ回す
  - **`profile` を渡さない直接指定(`port`/`platform`)は稼働中ブリッジに追従する**
    (`ExploreDriverResolver`。2026-08-05)。接続先が in-app なら同じデバイスの XCUITest ブリッジを
    フォールバックに合成して hybrid を組み、合成できないとき(実機・同名デバイス複数・
    XCUITest ブリッジを用意できない)だけ振り替え/素通しへ落とす
  - **宛先そのものも探す**(`BridgeDiscovery`。2026-08-06)。`port` 未指定で既定 8123 が無応答なら
    範囲(8123〜8154)を走査し、**生きているブリッジが1本だけなら自動採用**(採用理由を stderr へ)・
    **複数ならデバイス名付きで列挙してエラー**(別デバイスを黙って操作させない)・0本なら
    `fleetest bridge up` を案内する。既定固定だと `bridge up` が別ポートを選んだ瞬間
    (稼働中ブリッジの再利用・pid ファイルの残り)に全ツールがタイムアウトする。
    **`port` を明示したときは探索しない**(宛先を利用者が決めている)。
    Android の `serial` 未指定も同じ規律(`AndroidSerialResolver`。1台なら自動採用・
    複数なら AVD 名付きで列挙。`-s` 無しの adb は複数台で "more than one device/emulator" になる)。
    `ft_run_scenario` の `profile` 無し経路も同じ解決を通す(片方だけ賢いと食い違う)
  - **タイムアウトは確かめてから断定する**(`MCPServer.connectionLostHint`。2026-08-12)。
    接続拒否(`bridgeConnectionRefused`)は「誰も待受していない」が確定なので従来どおり即断するが、
    タイムアウト(`bridgeUnreachable`)の素の文言は「未起動 / 遅い / suspend」の**3択を並べるだけ**
    だった —— 実アプリ監査で ft_type がこれで落ち、直後の ft_status は「そのポートにブリッジが無い」と
    一意に答えられた(判定材料はあるのに操作系が使っていなかった)。判定の順序が要:
    **先に当のポートを `BridgeDiscovery.isBound` で見る**。bound のときの言い分は**エンジンで分ける**
    (`bridgeBusyHint(connection:engine:)`)—— xcuitest は busy(整定待ちは実測 33.7s /status 無応答 >
    interaction timeout 20s)なので「まだ繋がっている・リトライせよ」だが、**in-app は suspend でも
    kernel が handshake を返すので bound のまま** = リトライは永遠に当たらない助言になる。
    こちらは「ft_launch で前面へ戻すか、その機の xcuitest ポートを使え」。どちらも
    **forgetConnection はしない**。bound でないときだけ全ポートを走査し、消えていれば死亡と言い切って
    忘れる —— 走査を先にすると busy なブリッジは /status に出ないため「exited」と誤診し、
    健全なブリッジの再構築へ誘導してしまう(`bridgeUnreachableVerdict` = 唯一の判定点・純粋関数・
    テストで固定)。
    掴んでいるポートは `connectedPorts` に持つ —— **表示用の `connections` の文字列から読み解かない**
    (表記を整えるたびに判定が壊れる)
  - **宛先は port だけでなく udid まで書く**(`MCPServer.connectionLabel`。2026-08-12)。
    ブリッジは落ちても monitor が別ポートで建て直すので**同じセッション中にポートが動く**
    (実測: -03 が 8128→8126、-07 が 8136→8147)。port だけを覚えて使い回す読み手には、
    その port が今どの機かを確かめる手段が無かった。udid を申告しない旧ブリッジでは port だけ
    (「不明」と書くより短く、嘘も混ざらない)。**先頭は必ず `port `** ——
    `connectionLostHint` が `hasPrefix("port")` で iOS 経路を判別する
  - **「応答しない」を「死んだ」と読まない**(`BridgeDiscovery.isBound`。2026-08-06)。XCUITest は
    整定待ちでブリッジのスレッドを数十秒ブロックする(外部ログで実測 33.7s)。/status が返らなくても
    **カーネルは accept する**ので、待受があるうちは乗り換えず「今は忙しい・少し待て」を返す。
    ここを緩めると、自動採用が防ぐはずの**別デバイスへの取り違えを自分で作る**
  - **未インストールのアプリを launch させない**(`MCPServer.installedState`。2026-08-06)。
    `XCUIApplication.launch()` が未インストールで失敗すると、その issue は main queue 上
    (テストのスタック外)で記録されるため**ランナーごと落ちる** —— `requireLiveApp` が防いでいるのと
    同じ経路で、対処も同じ「XCUI に触れる前に弾く」。実測: 遊休ブリッジへ直接
    `POST /session {"bundleID":"<未インストール>"}` を投げると、無応答(待受のみ)を約5秒挟んで
    10秒以内にランナーが消える。**判定できないときは素通し**(実機・同名デバイス複数・simctl/adb 不調)。
    システムアプリ(springboard/Safari)は `get_app_container` が runtime のパスを返すので弾かれない
  - **hybrid でも別 bundle(springboard・他アプリ)を開いたら読み書きごと XCUITest へ寄せる**
    (2026-08-06)。`HybridFallbackDriver.launch` は従来**必ず primary(in-app)** へ投げていたが、
    **in-app ブリッジは自分のプロセスの中しか見えない** —— `ft_launch com.apple.springboard` は
    「Launched」と成功を返したうえで、続く snapshot が**アプリ自身の古い木**を返していた
    (実測: ホーム画面を読もうとして 30 要素のアプリ画面)。
    寄せ先は `AppAttachDriver`(fallback)では駄目 —— あれは固定 bundle への attach 専用で
    `launch` が意図的に no-op。**セッションを張れる素の BridgeClient** を別に持たせる
    (`foreignApp`)。自分のアプリへ launch し直すと in-app 主へ戻る。
    engine を hybrid に固定しても直らない問題なので、**エンジンの選択では解けない**
  - **ホーム画面・システム UI は `ft_launch com.apple.springboard` で読む**(XCUITest 経路のみ)。
    セッションはアプリに閉じているので、未起動での `ft_snapshot` は 409、`ft_navigate home` 後は
    背面アプリ照会の 500(kAXErrorServerNotFound)になる。`BridgeRouter.handleLaunch` は
    springboard を**起動せず参照だけ張る**特別扱いを持つので、これで木が読める
    (`MCPServer.springboardHint` / `backgroundingNavigationNote` が両方の行き止まりで案内する)
  - **MCP の snapshot は必ずキャッシュを捨てて撮る**(`MCPServer.freshSnapshot`。2026-08-06)。
    Android の a11y ノードはキャッシュ供給で、**Compose のスクロール後は木が古いまま固まる** ——
    実測(E2E-CMP / Pixel 9・Android 15)では `ft_swipe` 後の画面が行08〜16 なのに木は行01〜10 のままで、
    撮り直しても数分待っても直らず、`ft_tap(#row_03)` が **`selected=row_10`** を返した。
    ブリッジ側の既定(WebView 内だけ `refresh()`)は**シナリオ実行**の実測
    (全ノードで snapshot +65ms・E2E-Android の sum +43%)に基づくもので、MCP は1手ずつ撃つ経路なので
    往復のほうが桁で大きく、この上乗せは見えない。**「ジェスチャの後だけ」のフラグ運用にしない**
    (立て忘れたツールが1つでもあると黙って古い木に戻る)。
    出るのは **Android の Compose だけ**(RecyclerView と Flutter は同じ手順で再現しない)
  - **ref は撃つ直前に撮り直して照合する**(`RefGuard` / `MCPServer.verifiedRef`。2026-08-06)。
    **ref はスナップショットごとに振り直される**ので、覚えた番号のまま撃つと別の要素に当たる。
    覚えた要素の同一性(identifier → ラベル+型 → 型+frame)で引き直し、
    **動いていれば新しい ref へ撃ち直す/消えていれば撃たずに理由を返す**。
    identifier を持つ要素がその identifier で引けないときは**ラベルへ落ちない**(別要素を掴む)。
    ghost 判定は `StepExecutor.isOutsideContainer` を共有する(MCP 側に別の閾値を置くと
    DSL と「ghost の定義」が割れる)。**ghost は撃つが黙っては撃たない**(下記)。
    **identifier で引き直したらラベルの変化も見る**(`RefGuard.labelChangeNote`。2026-08-10)。
    identifier だけで引き直すと、検索候補が更新された画面では**同じ id・別の行**を掴むことがある
    (実測: 「立川駅、最近表示した項目」を狙ったタップが「立川駅 南口、立川市」に化けた)。
    動いた距離とは無関係に出す(位置が同じでもラベルだけ変わった形は同じ危険)。
    再ターゲット後に実際に操作を撃つ経路(`verifiedRef` / double_tap・pinch・drag(fromRef) が
    通る `verifiedElement`)には同じ警告を入れ、存在確認だけの経路(スクロール探索の着地表示・
    フォーカス待ち)には入れない
  - **`ft_scroll_to` は DSL と同じ `StepExecutor` に委ねる**(2026-08-06)。整定待ち・キャッシュ回避・
    容器基準の刻み・ghost の掴み直し・飛び越しの拾い直し・打ち切りは全部あちらに入っており、
    **同じ知見の2つ目の実装を作ると必ず割れる**。MCP は FlowStep を1つ組んで投げるだけ =
    MCP で届く要素はシナリオでも届く
  - **実機ブリッジは `/status` で udid を申告しない**(2026-08-13。iOS 実機の初監査)。
    iOS 16 以降 `UIDevice.name` は伏せられ機種名("iPhone")しか返らず、`SIMULATOR_UDID` も
    存在しないため、`status.device` を鍵にした一致(`liveIOSBridges`)も `Found.udid` も
    原理的に実らない(`ft_list_devices` が実機を必ず「no bridge」と報告し、`udid:` で実機を
    指せない)。ホスト側へ `.fleetest/bridge-<port>.device` = port→実機 udid の記録を新設した。
    **書くのは `IOSDeviceTransport.establish` の1箇所**(lan/usb 両方が通る実機専用経路)、
    **消すのは `teardown` の1箇所**(`bridge down` から無条件に呼ばれる。仮想デバイスでは
    no-op)。`BridgeDiscovery.scan` は**`status.udid` の申告を必ず優先**し、nil のときだけ
    記録で補う(仮想デバイスは自分で正しい udid を出すので古い記録に引きずられない)。
    記録の無い旧ブリッジは従来挙動へ静かに落ちる。あわせて `scan(repoRoot: nil)` を修正した
    —— 記録を読めず 127.0.0.1 へ落ちていたため、lan トランスポート(LAN IP 直叩き)の
    実機ブリッジは一度も疎通されていなかった。
    **この記録は `ft_list_apps` の宛先解決にも使う**: 実機を **`port:` だけで指した**呼び出しは
    `udids[key]` が nil のまま(`ExploreDriverResolver` は `SimulatorCatalog` しか引かない)なので、
    `connectedPorts[key]` からこの記録を引いて実機 udid を得る。**実機かどうかの判定は
    `bootedSimulatorUDID` より必ず前**に置くこと —— あちらは実機で throw するので、
    後ろに置くと実機判定へ到達しない(`udid:` 経路で実際に踏んだ)
  - **`ft_list_apps` の実機経路は `devicectl`**(`IOSPhysicalAppCatalog`。2026-08-13)。
    `simctl` は実機 udid を渡すと `Invalid device` で落ちるので
    `xcrun devicectl device info apps --include-all-apps --json-output` を使う。
    **user/system は `bundleIdentifier` の `com.apple.` 接頭辞で分類する** ——
    devicectl の既定一覧(`--include-all-apps` 無し)は `builtByDeveloper` だけで
    App Store アプリが漏れ、`url` の `/System` でも分類できない(Safari も Apple マップも
    `/private/var/containers/...` に居る。実測: 全287件・非Apple 206件)
  - **接続断からの回復は表示ラベルでなく記録で振り分ける**(`connectedPorts` /
    `connectedAndroidSerials`。2026-08-14)。`connectionLostHint` は `connections[key]`
    (表示用ラベル)の接頭辞 "port"/"serial " で iOS/Android を判別していたが、`profile:`
    経由のラベル(例 `"iPhone wave(実機) port 8144"`)は**どちらの接頭辞にも一致せず**、
    profile: のセッションは iOS も Android も回復機構(`forgetConnection`)に一度も
    入っていなかった。同じ根が3箇所 —— `connectionLostHint` の iOS/Android・
    `forgetConnection` の Android(serial をラベルから `dropFirst` で切り出していた)。
    **表示文字列で制御を分岐しない**のが教訓(表記を整えるたびに判定が壊れる。上の
    `connectionLabel` の注意と同型)。あわせて `connectedPorts[key] = probePort` を
    `probePort ?? provisioned.port` に修正(`probePort` は実機で常に nil。同じ根の消費側が
    2つあり片方だけ直っていた掃討漏れ)。**純粋関数・単体テストが正しく緑でも、この配線の
    手前で弾かれていれば何も改善しない**(教訓の詳細は docs/verification.md 参照)
  - **ブラウザの取りこぼしは「空白の幾何」で言う**(`MCPServer.webViewGapNote` /
    `gridWithoutHeaderNote`)。ブラウザは画面に描いているものを a11y へ出さないことがあり
    (Android の Chrome が顕著)、**木に無い要素は待つことも探すことも指すこともできない**のに
    応答からは気付けなかった。判定は幾何だけ = webView の中で**どの葉とも交わらない連続帯**。
    2つの規律がある:
    - **閾値を超えた帯は全部数える**(2026-08-13)。最大の1本だけを返していた頃、Yahoo!天気の
      週間画面では 345px の帯だけが報告され、**黙って落ちた 268px のほうに週間表の日付・
      気温・アイコンが丸ごと入っていた**。読み手は「警告された1箇所以外は揃っている」と読むので、
      1本だけ言うのは黙るより悪い。名指しは3本まで(`webViewGapBandsReported`)・残りは件数で言う
    - **格子の見出し欠落は「見出し行が入る余地」まで見る**(2026-08-13)。値のセルが揃っている
      のに列見出しだけ無い形は `gridWithoutHeaderNote` が名指しするが、**見出しが値と centerX で
      揃っていると見出し自身が格子の最上行として鎖に取り込まれる** —— 「直上が空か」だけでは
      見出しの在る格子と区別が付かず、実アプリで誤検知2件(同じページの2つの表)を出した。
      直上の空き ÷ **行間の中央値**が `gridHeaderRoomRatio`(2.0)以上のときだけ言う
      (実測比: 誤検知 1.16 / 0.54 に対し真陽性 4.4)。中央値なのは、実測の格子が途中に
      別セクションを挟んで間隔を飛ばすため(平均だと1本の飛びで閾値が跳ね上がる)
    - **webView ノードごと無い形は別の注記が要る**(2026-08-13。`missingPageContentNote`)。
      `webViewGapNote` は `type == "webView"` の**中**しか測れず、`emptyTreeNote` は
      `elements.isEmpty` **ちょうど**が条件なので、**Chrome が自分の chrome しか公開しない**
      画面では両方が黙る —— **状況が悪化したほうが黙る**逆転になっていた(直前の読みでは
      webView ノードがあり `webViewGapNote` が出ていた。実測 = 画面は表で埋まっているのに
      木は19要素、のち1要素)。判定は幾何のまま**画面全体**へ広げ、
      `unrepresentedScreenFraction`(どの要素とも交わらない最大の帯 ÷ 画面高)が 0.5 以上・
      URL バー在り・webView 無しの3条件。**URL バーを条件に入れるのは必須** ——
      オーバーレイが背景を落とす形(`and-overflow` 56.4%)は正常なので、これが無いと誤検知する
      (コーパス実測: witness 88.6% / URL バー有り webView 無しの次点 `and-browser_urlmenu` 5.9%)
  - **注記が載る応答は目録の `contexts` で決める**(`NoteCatalog.Context`)。**`ft_scroll_to` には
    「この一覧をそのまま報告してよいか / この行を指せるか」を言う注記を載せる**
    (`urlishLabelsNote` / `ambiguousLabelsNote` / `duplicateIDsNote` / `emptyTreeNote` ほか。
    2026-08-13)。`ft_scroll_to` は「swipe + snapshot の繰り返しの代わりに使え」と自ら勧める
    経路なので、**警告が落ちる側が常用経路になる** —— 実測では `link "13101"`(実際の描画は
    「千代田区」)を無警告で返し、同じ画面を `ft_snapshot` で撮り直して初めて出た。
    手数が増えるだけの注記(`unlabeledClickablesNote`)やスクロールで変わらないもの
    (`addressBarNote`)は載せない。**増やすときは Scripts/mcp-bench.sh の手数で決める**
  - **横スクロールの残骸は「同じ y・違う x で繰り返す区間」で言う**(2026-08-13。
    `duplicateRegionNote`)。WebView の表を横へ送ると、**スクロール前の行が古い x のまま木に残り、
    新しい行が並んで入る** —— 実測(気象庁)は同じ y の行が 200pt ずれて二重に並び、左端は
    x=0 へクランプされ、**約55行のうち印が付いたのは4行**だけだった。既存の3経路はどれも
    構造上当たらない: `outsideDeclaredScroller` / `isUntappableGhost` は「容器と**交差ゼロ**」が
    条件で x=0 は容器の**内側**、`stackedRefs` は「**同一矩形が3個以上**」が条件で複製は2個。
    しかも **WebKit の横スクロール div は `scrollable` を申告しない**(iOS の `scrollableTypes` は
    scrollView/table/collectionView のみ)ので、内側の容器そのものが木から見えない。
    **幾何条件を落とさないこと** —— 素の「最長反復区間」にすると、**1ページ内の2つの表が
    同じ見出し行を共有しているだけ**の形を掴む(実測で11行。設計中に気付いて足した)。
    実測は witness 10 に対し他フィクスチャ最大3。
    `StepExecutor.hasClampedCoordinates` は流用できない(あちらは**同一矩形・同深さ3個以上**が
    条件で、ここは矩形が違い x だけ揃う形)
  - **「変わっていない」の判定は木の**外**の数字も見る**(2026-08-13。`looksUnchanged`)。
    `SnapshotResponse.elements` は**ブリッジが上限で切った後**の列で、落とした数は
    `truncatedCount` に別で載る。要素だけを比べていたため、**上限より下だけが変わった操作**を
    「変化なし」と報告していた(実測: 表を横送りするタップで113要素増えたのに、上限120の内側が
    バイト一致で `waitForChange` が空振り)。**呼び手は回避できない** ——
    `maxElements` は `ft_snapshot` にしか無く、待ちの中の `freshSnapshot` は常に既定値で走る。
    併せて、**木が空同然の画面では「変化なし」が常に真になる**(空の木は空の木と一致する)ので、
    `unrepresentedScreenFraction` が 0.5 以上のときは判定に
    「『動かなかった』と『公開されていない』を区別できない」但し書きを付ける
    (実測: `scrollDown ×4` が実際に数画面送ったのに `ft_batch` が「どのステップも画面を
    変えていないかもしれない」と言った)。**判定はこの1本のまま**(2つ目を書かない)
  - **スクロール残像(ghost)は拒否せず、警告して撃つ**(`RefGuard.ghostWarning`)。
    Compose iOS は容器の外へ出た行をフルフレームで木に残し、`ios-xcuitest` はそれを座標で叩く
    (実測では下部タブへ遷移して "tap done" を返した。`ios-inapp` は要素起動なので当たる =
    エンジンで割れる)。**応答に「何に当たったかもしれないか」を添え**、一覧の行にも
    `⚠️scroll-leftover` を出す(`MCPServer.ghostNote` / `ghostFlags`。先頭の注記だけでは、
    行から ref をコピーする動作に届かない)。

    **印は2種類に割る**(2026-08-09)。`⚠️scroll-leftover` は「撃つと別の物に当たる」
    (沈黙した誤操作)、`⚠️offscreen` は「今そこに無い」だけ。**割る基準は打ち手ではなく危険度**
    —— どちらも対処は `ft_scroll_to` で出し直すことだが、同じ重さで並べると本物の残骸が
    埋もれる(実測: Apple マップの経路詳細で、シートを広げた後の `y=-59` の行まで
    「別の物に当たるかも」と警告されていた)。判定は `TapTargetGeometry.offscreenAdvisory`
    (中心が画面の外)で、**画面外を先に見る** = `RefGuard.preTapWarnings` の優先順位と同じ。
    揃えるのは、同じ要素について**ツールごとに言うことが変わらない**ようにするため。
    **`⚠️offscreen` の一覧注記は方向まで言う**(2026-08-10。`MCPServer.offscreenDirection`):
    中心のはみ出し量が大きい軸(below/above/right/left)で方向グループに分け、
    `ft_scroll_to` の `direction:` へそのまま渡せる語(down/up/right/left)を添える。
    旧文言「scrolled past」は削除した —— 実測(Apple マップの経路候補・横ページャ)で、
    一度も表示していない右隣ページの要素に「スクロールで通り過ぎた」は不正確だった。
    **左右方向の `⚠️offscreen` があり、かつ画面に `pageIndicator` が居るときだけ**、
    横ページャが1ページずつしか描画しないこと・`ft_scroll_to` で届くことを1文添える
    (`MCPServer.ghostNote` の `pageIndicatorHint`)。縦方向だけの offscreen やページャの無い画面では
    何も足さない

    当てる相手は `OcclusionGeometry.occluder`(中心を覆う別要素。実体は FTCore で DSL の
    タップ前警告と共有・`RefGuard` は転送)。**遮蔽と数えないものが7つ**ある:

    | 除外 | 理由 | 外すと起きること(すべて実報告) |
    |---|---|---|
    | ① 相手自身が ghost | **描かれていないものは何も覆えない** | 設定アプリの「閉じる」が、画面外へ出たリスト行 `clickable (16,484 370x52)` に弾かれる |
    | ② 何も描いていない葉コンテナ | label も value も子も無い `other` は画面に何も描いていない | 起動直後の「スキップ」と検索サジェスト先頭が `#compass_container`(全幅・非 clickable・葉)に弾かれる |
    | ③ 自分を丸ごと包む、**画面規模の**相手 | 全画面の暗幕・toolbar は遮蔽ではなく容器 | 同じ「閉じる」が全画面の `#AdditionalDimmingOverlay` / `Toolbar` に弾かれる |
    | ④ 自分の祖先と子孫 | 自分を含む容器を数えない | 「自分より深いものだけ」に絞ると、残像に重なる下部タブ(**浅い**)を見落とす |
    | ⑤ **奥に描かれている相手**(`drawnAbove`) | 奥にある物は覆えない | Apple マップの `#MapsSearchBar` が中の `#userProfileButton` を覆う扱いになる(2026-08-07) |
    | ⑥ **矩形がぴったり同じ相手** | 同寸同位置は「上に載った物」ではなくラッパーか入れ替わり。本物の積み重なりは `stackedRefs` が別に見る | 出ていない `#SearchAutocompleteView` が出ている `#ResultsViewTable` を覆う扱いになる(同 (0,62 402x812)) |
    | ⑦ **いちばん内側の入れ物より外の枠**(`enclosesAnInnerWrapper`。**z が無いエンジンだけ**) | 「自分を包むもっと小さい何か」ごと包む相手は外枠 | `#HomeView` が `#MapsSearchTextField` を覆う扱いになり、素の `ft_type` が毎回警告付きになる |

    **⑤の「奥/手前」はブリッジの申告(`ElementInfo.z`)が最優先で、無ければツリー順へ落ちる**。
    ツリー順は描画順の代理として使ってきたが production では裏返る —— Google マップは
    地図の chrome(ref 81〜86)をシート(ref 17〜61)より**後**に出すのに描画はシートが手前で、
    シートの裏の `#mylocation_button` を無警告でタップして裏の広告を踏み、**Chrome が起動**した
    (2026-08-07 実測)。Android は `getDrawingOrder()` を根から積んで
    `SnapshotBuilder.assignPaintOrder` が通し番号にして送る(**段ごとの値ではホストで合成できない**
    —— 出力ツリーは中間ノードを間引くので2要素の共通祖先が残っていない)。
    iOS(XCUITest / in-app)は描画順を読む API が無いので**ツリー順のまま**で、⑦の推測が要る。
    **z があるときは⑥⑦を使わない** —— 真値がある場に当て推量を混ぜると真値を打ち消す
    (実測: 地図側の容器が「内側の入れ物」に当たってシートの遮蔽が消えた)。

    **①を③より先に見る** —— ③の包含判定は 1pt の差で外れるほど際どい
    (実測: 閉じる `y483..521` 対 残像 `y484..536`)。閾値では守り切れない。
    本物の遮蔽は**一部しか重ならない**ことが多い(残像 `#row_11` (16,790 370x56) に対し
    下部タブ `#tab_controls` (134,792 134x48))。

    **③に「画面規模」の条件が付いているのは、包含を無条件に容器と読むと逆側へ倒れるから**
    (2026-08-07)。app bar の下へスクロールで潜り込んだ行はまさに「丸ごと包まれる」形で、
    無条件に除外すると**タップしても何も起きないのに警告も出ない**
    (実測: `#transit_station_title_name` (285,0 510x85) が `#header_container` (0,0 1080x290) の下)。
    包含する相手のうち**面積が画面の `fullScreenContainerAreaRatio`(0.5)以上**のものだけを
    容器とみなす —— 暗幕・全画面 toolbar は 100%、app bar は 12% で分かれる。
    **②と③は表と裏**(②を足すと鳴りすぎが止まり、③を緩めると黙りすぎが止まる)なので、
    片方だけ動かすと残る側が悪化する。

    **これでも誤検知は残る**。木の幾何だけでは「実際に描かれているか」を決められない ——
    最後に出たのは**キーボードの下**にある普通の行で、キーボードはスナップショットから
    丸ごと除外している(キー1つ1つが Button として写り込むため)ので frame すら取れない。
    だから**拒否ではなく警告**にしてある。ここを再びブロックへ戻さないこと。

    **教訓(この検知で誤検知を5形出した)**: `isOutsideContainer` は DSL では
    「掴み直して送り直す」= やり直しの合図で、外れても次の周回で回復する。
    **同じ判定を拒否へ格上げすると、外れがそのまま機能の喪失になる**。
    強度を変えて再利用するときは、外れたときの損害が同じかを確かめる。
    なお5形とも**利用者の実アプリで出た** —— 4 SUT 全画面(84画面)の掃討では1件も出ていない。
    **2026-08-07 に同じことが繰り返された**: 実アプリ(Google マップ)の1セッションで誤検知が
    3種類(上の②、③の緩和で塞いだ見逃し、積み重なりの件数判定)出たが、同じ日の
    自前 SUT 掃討では**3 SUT とも 0 件**だった。この検知系で「自前 SUT の誤検知 0」は
    production を代表しない。掃討は `Tests/Fixtures/RealAppSnapshots/` の固定コーパス
    (`SweepHarnessTests`)で実アプリにも当てる。
  - **容器の中に居ても別の物に当たる2形**(2026-08-06。`RefGuard.overlapWarning`)。
    上の ghost 判定は `isOutsideContainer` を**入口条件**にしているため、この2形を1つも捕まえない:

    | 形 | 実測 | 判定 |
    |---|---|---|
    | 上に描かれた overlay に覆われている | E2E-iOS のホームで `#nav_heal` (16,788 370x62) が下部タブ `#tab_controls` (134,778 134x62) の下。ref タップが**コントロールタブへ遷移**して "tap done" | `overlayCovering`: `occluder` のうち**木の順序で後ろ**にあるものだけ(先に並ぶ大きな背景パネルを遮蔽と読むと、拒否をやめる原因になった誤検知に逆戻りする) |
    | 同一矩形に積まれている | E2E-iOS のスクロール画面で `行 09`〜`行 40` の staticText **29 個が全部 (16,270 330x56)**(= `行 01` の位置)。ref タップが `selected=row_01` | `stackedRefs`: 同じ矩形を共有するもののうち、**label か value を持つものが3つ以上**。**入れ子の一本鎖は数えない**(Android のダイアログは `action_bar_root`→`content`→`parentPanel`→`customPanel`→`custom` が全部同じ矩形) |

    **数えるのを「中身を持つもの」に限るのは、件数だけだと普通の木が鳴るから**(2026-08-07)。
    同一 bounds のラッパー連鎖は Android ではありふれていて、実測では
    `#expandingscrollview_container`/`#cardui_cardlist`/`#recycler_view`/`#home_bottom_sheet_container`
    の4件(中身は普通の可視ボトムシート)が積み重なり扱いされた。元の実測ケース(行01へ畳まれた
    staticText 29 個)はどれもテキストを持つので、この制限でも引き続き捕まる。

    どちらも**拒否せず警告**(ghost と同じ理由)。積み重なりは一覧にも `⚠️scroll-leftover` を出す ——
    利用者から見ると原因も打ち手も ghost と同じなので**印を2種類に割らない**。
    誤検知ゲートの回し方は docs/verification.md(**自前 SUT だけでは足りない** ——
    `Tests/Fixtures/RealAppSnapshots/` の固定コーパスで実アプリにも当てる)。
  - **自分の子孫が中心を横取りする形**(2026-08-09。`TapTargetGeometry.nestedActionCoveringCentre`)。
    上の `occluder` は**祖先と子孫を除外する**(親子の重なりは正常な入れ子で、数えると何でも
    遮蔽になる)ので、この形を1つも捕まえていなかった。実測(Apple マップの検索候補):
    `#Maps.PlaceTableViewCell` (20,138 362x155) の中心 (201,215) が、同じセルの中の
    `#FeaturedInMultipleGuidesContextLineItem` (80,202 205x18) の内側にあり、ref タップは
    **場所カードではなくガイド一覧を開いて**無警告で "done" を返した。兄弟の重なり
    (`#FavoriteButton` × `#TransitDepartureRow`)では警告が出ていたので、**差は「子孫かどうか」だけ**。
    条件は「親が対話的」「子孫も対話的」「面積比 < `nestedActionAreaRatio`(=0.25)」の3つ:
    比の上限は**行を包み直すだけのラッパー**(同セル内の無名 button は 0.99)と**行の主ラベル**
    (`#MultiTextView` は 0.31〜0.49 で、押しても行と同じ場所が開く)を外し、
    **行の中に別の遷移先を持つ小さな帯**だけを残す値。コーパス全数(18枚)で発火は
    `#PinnedItemSection` ← `#PinnedTile`(帯を撃つとタイルが開く = 真陽性)の1件だけ。
    非対話の容器は `missesItsOwnContent` の担当なので**排他**(二重に言わない)。警告のみ
  - **申告されたスクロール容器の外へ送り出された行**(2026-08-09。
    `TapTargetGeometry.outsideDeclaredScroller`)。ghost 判定(`StepExecutor.isOutsideContainer`)は
    容器を**木の並びから推測する**ので、申告のある UIKit/SwiftUI では推測が中間ノードに当たって
    nil に落ち、1件も付いていなかった。実測(Apple マップの場所カード): カードを送ると
    `#MUScrollableStackView` (0,72 402x802) の上へ抜けた行が frame ごと木に残り、
    `link "ウィキペディア"` (16,-2 85x18) への ref タップが "done" を返して、実際には
    中心 (58,7) = ステータスバーに当たり**カードが先頭へ飛んだ**。
    こちらは推測せず **`scrollable` を申告している祖先だけ**を見る。
    **ただし depth からの祖先復元はブリッジの間引きで嘘になる** —— Google マップの検索結果では
    カード容器が落ちた結果、本文(depth 20〜22)が直前の写真カルーセル `#recycler_view`(depth 19)の
    子孫に見え、素の判定では**10件まとめて誤検知**した。そこで `clippingContainer` と同じ
    「その depth の兄弟が2つ以上、容器の中に居る」を条件に足す(間引きで繋がっただけの相手は
    仲間が容器の中に1つも居ない)。一覧の印は ghost と同じ `⚠️scroll-leftover`
    (原因も打ち手も同じなので**印を割らない**)
  - **`ft_pinch` は座標(`x`/`y`[+`radius`])でも対象を指せる**(2026-08-09)。地図やキャンバスは
    要素として木に無いので `ref` を渡せず、対象を省くと指が画面全体に開く —— 実測(Apple マップ):
    場所カードを半分出したまま `scale 0.4` を撃つと**地図は 1px も動かず、シートが全画面に展開した**。
    既定の半径は**画面の短辺の 22%**(座標系が iOS=pt / Android=px で桁が違うので固定値にしない)、
    画面の内側へクランプする(外へ出た指は届かず、要求より小さいズームになる)。
    **エンジンで honour できるかが割れる**: `PinchRequest.frame` を読むのは **Android と
    iOS in-app だけ**で、**XCUITest は読めない**(XCTest のピンチは `XCUIElement` にしか生えておらず
    座標版が無い)。だから xcuitest エンジンでは**全画面へ退化したことを戻り値で必ず言う**
    (黙って退化させると「狙った場所を撃ったつもりで手前のシートを掴む」= この修正の動機そのもの)。
    逃げ道は他のジェスチャと同じ `profile:` で in-app/hybrid を選ぶこと
  - **ソフトキーボードの遮蔽は木からは原理的に判定できない**(2026-08-08)。iOS xcuitest は
    `.keyboard`/`.key` サブツリーを木から除外しており、残る外側コンテナ(`inputView`)は
    子孫ゼロの空葉になって**空葉除外(誤検知対策)に正しく弾かれる**。Android は IME が
    別プロセスの別ウィンドウで木に出ない。実害は両 OS で実測済み: iOS はキーボード下の
    候補行への ref タップが顔文字キーに化けて検索欄を汚し、Android は Gboard の
    レイアウト選択シート下の候補タップが IME の「QWERTY」選択に化けた —— どちらも無警告。
    だから**ブリッジが `SnapshotResponse.keyboardFrame` で実矩形を申告する**:
    | エンジン | 取得元 | 罠 |
    |---|---|---|
    | iOS xcuitest | 走査中に見た `.keyboard` ノードの frame | — |
    | iOS in-app | `keyboardWillChangeFrame` 通知の最新値 | **TextEffects window の frame を使ってはいけない**(開いていても全画面 (0,0 402x874) が返り、画面上部の要素まで誤警告する。`UIInputSetHostView` のクラス名走査も iOS 27 で不発 — どちらも実測)。通知値が無ければ frame は申告しない(誤検知側に倒さない) |
    | Android | `UiAutomation.getWindows()` の TYPE_INPUT_METHOD の bounds(要 `FLAG_RETRIEVE_INTERACTIVE_WINDOWS`) | — |
    判定は `TapTargetGeometry.keyboardCoveredAdvisory`(中心が keyboardFrame 内)1箇所で、
    DSL はステップ注記・MCP はタップ警告 + `ft_snapshot` / `ft_scroll_to` の note に使う
    (note は覆う矩形を常に申告し、その下に操作対象が居るときだけ ref を列挙する)。
    **警告のみで拒否しない**(新しい検知は警告から)。旧ブリッジは申告しない = 黙って従来どおり。
    Android は `getWindows()` を毎 snapshot 叩く(dumpsys と違い a11y 内 API で安い。ただし
    `FLAG_RETRIEVE_INTERACTIVE_WINDOWS` をブリッジ起動時に恒久で立てる副作用がある)。
  - **iOS の `keyboardFrame` はキー面だけで、実際に覆う面積より狭い**(2026-08-13)。
    `.keyboard` ノードの frame をそのまま申告しているが、上のサジェストバー
    (`SystemInputAssistantView`)と地球儀/Dictate 行を含む `inputView` の下端を含まない
    (実測: 仮想デバイス iPhone 17 Pro / 402x874 で申告 y=583..816 に対し木の chrome は y=538..874。
    実機 iPhone 15 Pro でも上45pt・下58pt が同様に欠ける)。中心点判定
    (`keyboardCoveredAdvisory`)は正しいのに、**渡す矩形が狭いせいで隠れた要素を見落とす**
    ——「キーボードは何も覆っていない」という偽の全クリアが出た(witness: `#tab_home` が
    キーボードに完全に隠れているのに note は無警告で、直後の `ft_tap` 自身が別要素への
    誤爆を警告するという2機構の矛盾)。**中心点判定は変えない**(矩形1pt重なっただけの入力欄まで
    警告すると誤検知になる) —— `FTCore.KeyboardOcclusion` が申告と木の chrome
    (`inputView`/`SystemInputAssistantView`。**申告と交差するものだけ**)を足し込んで実効矩形を作り、
    MCP/DSL の呼び出し側全員(MCPServer+Snapshot.swift / MCPServer+Hints.swift /
    MCPServer+Dispatch.swift の ft_double_tap / StepExecutor+Actions.swift)がこの型を通す。
    chrome が木に無ければ申告どおり(Android は既に画面下端まで届いており対象外。ブラウザの
    WebView 内キーボードは chrome がツリーに出ないため同様に対象外)。
    **広げるだけでは雑音になる**: キーボード自身の部品(地球儀キー・変換候補バー)まで
    「キーボードの下に隠れている」に該当し、**注記は先頭8件しか名指ししない**ので本命が枠から
    押し出される。chrome 自身とその部分木(木は親→子順+`depth`)は除外する ——
    覆っている側を「覆われている」とは言えない。実測(`ios-maps_suggest_keyboard`):
    16件(修正前・見落とし)→ 30件(広げただけ・雑音)→ **20件**(除外後)で、増分4は
    **本当にキーボードに隠れた5件目の検索結果** `#Maps.PlaceTableViewCell`(y=836..906)。
    **拾い直しが要る**: `SystemInputAssistantView` は申告矩形と縁が接するだけで交差しないので
    最初の走査に入らない —— 実効矩形で chrome を引き直さないと、その部分木が除外から漏れる
  - **「セレクタを書けない」と言う前にスコープ記法を試す**(2026-08-09)。ラベルも id も無い
    clickable の注記は「ref か座標でしか指せない」と言い切っていたが、**id を持つ祖先があれば
    `#container >> .clickable[n]` で書ける**(スコープ記法。docs/commands.md)。実測(Google マップ
    の経路画面): 移動手段タブは id もラベルも無い clickable だが `#directions_mode_tabs` の中に
    居り、この形で一意に指せる —— タブのラベルは「58 分」のように**検索ごとに変わる**ので、
    ラベルで書くこと自体が誤り。`MCPServer.scopedSelector` が組み立て、**祖先の id が画面で
    一意でなければ nil**(`#recycler_view` が4つある画面で別の容器を掴むため)。
    祖先も名無しなら従来どおり「ref か座標」と言う
  - **半開きシートを広げる操作を座標の手計算にしない**(2026-08-09)。`ft_drag` が
    `fromRef`(要素の中心から。撃つ直前に撮り直して照合する)と `dx`/`dy`(移動量)を受ける。
    実測では `#Card grabber` の frame を人が読んで `ft_drag (200,664) → (200,120)` を組んでいた。
    **シートが折りたたまれていること自体は注記にしない** —— 状態を持つのは
    `#Card grabber` の value のような**アプリ・ロケール固有の文字列**で、それを条件にすると
    Apple マップの日本語表示にだけ効く判定になる。気付ける場所は探索が止まった瞬間なので、
    そちらは scrollTo のヒント(下記)で塞ぐ
  - **scrollTo の「シートを広げろ」ヒントは scrollFrame 未指定でも出す**(2026-08-09)。
    以前は `step.scrollFrame != nil` を入口にしていたため、同じ画面でも**指定した2回目にしか
    出なかった**(実測: Apple マップの経路手順で、未指定の1回目は「content no longer moved」
    としか言わず、scrollFrame を渡した2回目のヒントで初めて解けた)。未指定のときは
    `StepExecutor.partialHeightSheetExists` が**申告のあるスクロール容器の高さ**で判定する ——
    帯は画面の 15〜80%(下端はチップ行・横カルーセル ≒5% を落とし、上端は全画面リストを落とす)。
    実測でヒントが要った容器は 22%(`#TransitDirectionsListView`)と 37%(`#directions_group_list`)
  - **細帯(sliver)の注記**(2026-08-08): 幅・高さのどちらかが 10 以下の、極端に細いラベル付き要素
    (実測: 右端で 9x137 に切れたタブ「サンライズ瀬戸」)は掴めないことが多いので
    `ft_snapshot` が note で名指しする。判定は `TapTargetGeometry.isClippedSliver`
    (ラベル2文字以上 + 細い辺 ≤10 かつ対辺 ≥30。アイコン 9x13 等は対辺条件で除外)。
    **判定は要素自身の細さだけ**(縁で切れた結果か、元々細いだけかは幾何を見ないので判定しない)。
  - **明示した scrollFrame が解決できないときは、スワイプを1本も送らずに失敗する**
    (`ScrollSearchResult.scrollFrameMissing`。2026-08-08)。以前は「matched nothing →
    全画面スワイプ」へ黙って退化しており、Apple マップで snapshot が scroll と申告した
    `#MUScrollableStackView` が直後に 120 件 cap で木から落ち、退化したスワイプが
    カードの「計画」ボタンを発火して画面遷移した。cap 側の対策(scrollable の cap 免除)と両輪。
    範囲と細部:
    - **scrollTo 探索だけでなく `scrollDown` 等の単発スクロール・`scrollToBottom` 等の
      端送り・flick 系・`withScroll*` 配下の探索も同じ**(全画面退化はどれでもボタン誤発火に
      なり得る)。**`select` 系だけは例外** — 「掴めなければ空要素を返す」契約が優先し、
      fail-fast も skipped になる(失敗はしないが探索もしない)
    - **探索中に容器が消えた場合も失敗**にするが、文言は分ける(スワイプ済みなら
      「disappeared after N swipe(s)」— 0本のときだけ「実行していない」と言う。
      動詞は呼び手ごと: search was not run / swipe was not sent / flick was not sent)
    - **判定はセレクタ照合そのもの**(`Self.match`)で行う。`scrollContainer` の nil を
      流用してはいけない — あちらは `FT_SCROLL_TARGET=legacy`(座標スクロールの殺しスイッチ)
      でも nil を返すため、殺しスイッチが「全 scrollFrame シナリオ即死」に化ける。
      **legacy 時は fail-fast ごとスキップ**して従来挙動へ落とす
    - **容器は解決したが動かせる幅が無い**(margin で潰れた等)場合は従来どおり全画面へ
      落ちるが、注記(`resolved but leaves nothing to move`)で申告する
    - scrollFrame 未指定の全画面スワイプは従来どおり(正当な既定)。
  - **`ft_swipe` にも `scrollFrame` を置き、実装は `StepExecutor` へ委ねる**(2026-08-12)。
    動機は実機観測: web ページの中の**横スクロールする表**を動かす手段が無く、`ft_scroll_to` も
    使えなかった(狙う見出しがそもそも木に無い)。**FlowStep(action: "scroll") を組んで投げるだけ**に
    する —— DSL の `scrollDown/scrollUp/scrollLeft/scrollRight(scrollFrame:)` と同じ形で、
    `ScrollGeometry` の呼び出し・マージン定数・容器解決・fail-fast は全部あちらに1本化されている。
    **直に `driver.swipe(_:intent:path:)` を叩いてはいけない**: in-app ブリッジは Compose/Flutter で
    領域指定つきスクロールを 501 で拒否する設計で、その 501→XCUITest フォールバックは
    `StepExecutor.swipeWithFallback` にしか無い(直叩きだと in-app 単独エンジンで 501 のまま終わる)。
    **`direction` は指の向きのまま渡す**(action `"scroll"` は指の向きとして読む。逆写像は不要)。
    - **`scroll` アクションは `scrollFrameRect` を見ていなかった**(2026-08-12 に発見・修正)。
      `flick`/`scrollTo` は rect を先に見るのに `scroll` だけが locator しか見ず、木を撮る条件も
      locator の有無で決めていたため、**ref 形の scrollFrame が黙って全画面スワイプへ退化**していた
      (`scrollContainer` は rect を先に返すが、木が無いと viewport が無く path ごと nil になる)。
    - **効くのは「木に出ている容器」だけ**。web ページの入れ子 `overflow-x` のように容器が
      木に現れない相手には効かない(実測: ページ全体を渡すと中心線が表の外を通り、`ok` を返して
      1px も動かない)。**その場合の逃げ道は `ft_drag` の座標指定**で、これは実測で動いた。
      ツール定義にもこの2点を書いてある
  - **`ft_scroll_to` は「返す木にそれが居るか」を確かめてから成功と言う**(2026-08-06)。
    探索のスワイプは**タップ可能な行を発火させることがある**(SwiftUI の SUT で実測)。
    そのとき executor は途中の観測で passed のまま、撮り直した木は別画面になり、
    「scrolled to "#nav_diagnostics"」+ **その id が居ない診断画面の木**が返っていた
    (E2E-iOS のホームで決定的に再現)。照合は `matches`(waitFor と同じ = DSL と同じ)で行う ——
    `scrollTo` は `StepOutcome.resolvedElement` を載せないので、そちらを当てにすると一度も走らない。
    - **この撮り直しは節約の対象ではない**(2026-08-12 に最適化を実装して**撤回**)。
      iOS の `ft_scroll_to` は対象が既に画面内(0スワイプ)でも 5.35s かかり、内訳は
      **探索 2.0s + この撮り直し 2.0s**(注記の生成は主因ではない —— `FT_MCP_NOTES_OFF=all`
      でも差が出ない)。executor が解決に使った木を持ち帰って撮り直しを省く実装を入れたところ、
      **既存の回帰テスト2本が落ちて構造的な穴が見えた**: 撮り直しを省くと、この照合と
      「中心が画面外へ動いた」ゲート(`MCPScrollToOffscreenGateTests`)が**どちらも定義上通る**
      ようになる(返す木 = 照合した木なので必ず一致する)。後者は **0スワイプの witness を持つ**
      (Apple マップの経路ページャは読み取りの合間に自分で動く)ので、スワイプ数では守れない。
      **2枚目を読むこと自体が砦**なので、速さと引き換えにしない。
  - **木が「起動したアプリのもの」かを突き合わせる**(`MCPServer.switchedAppNote`。2026-08-06)。
    Android のブリッジは session を**前面ウィンドウ**から採る(`root.getPackageName()`)ので、
    back でアプリを出ると session ごと別アプリへ移り、`backgroundedSessionNote` は
    **構造上まったく発火しない**。4 SUT は id・ラベルが共通契約なので木を見ても気付けない。
    ホスト側で最後の `ft_launch` を覚えるのが唯一の検知経路(詳細は docs/verification.md)。
  - **繋いだブリッジの版を照合し、ズレは既定で拒否する**(`MCPServer+Driver.swift` の
    `enforceVersion` / `bridgeVersionSkew`。2026-08-06 導入・2026-08-09 に警告から拒否へ反転)。
    profile 無しの iOS 経路は `ExploreDriverResolver` が**生きているポートへ素で繋ぐ**だけで
    provision を通らないため、`bridgeProtocolVersion` を上げても旧ランナーが使われ続ける
    (実害: ランナー側の修正2件が `bridge down && bridge up` まで反映されなかった)。
    MCP の出力はシナリオへ書く文字列の供給源なので、古いブリッジの注記から誤ったセレクタが
    書き込まれるほうが「セッションが止まる」より高くつく("Refusing to operate…" を throw)。
    押し通すには `allowVersionSkew: true` で、その場合は**毎回の応答に警告が付き続ける**
    (1度言って黙らない)。版を返さない旧ブリッジ(nil)は判定できないので黙る。
  - **`ft_navigate back` は「画面が変わった」と断言しない**(2026-08-06)。iOS の back は端の swipe で、
    自前ナビの画面(`#btn_back` を持つ SwiftUI 等)では**1px も動かない**(E2E-iOS で2回とも不変)。
    アプリの外へ出ることもあるので、両方を注記に書く。
  - **エンジン切替の案内には「アプリが起動し直る」まで書く**(`iosEngineHint` 末尾。2026-08-06。
    2026-08-08 に苦情を受けて1文へ圧縮したが、この事実は残した)。
    dylib は起動時にしか差し込めないので、in-app ブリッジの初回起動はアプリを再起動する。
    書かないと、案内に従った瞬間に探索中の画面が消え、**ホーム画面へ同じ座標のジェスチャが撃たれる**
    (実測: マップ画面での double tap がホームから `#nav_scroll` を開き `行 05` を選んだ)。
  - **スクロール容器は行に `scroll` を出し、2つ以上あるときだけ先頭で名指しする**
    (`ScrollFrameCandidates`。2026-08-06)。**id を持たない ScrollView/Table/CollectionView も
    版58から木に出る**(xcuitest の `isEligible` が容器型を id 必須から免除。in-app は
    版57で対応済み。id が無い容器は矩形で名指しされる)。当初 `ft_scroll_to` の `scrollFrame:` は
    セレクタ文字列しか取らないのに、一覧はどれが容器かを言っていなかった —— 引数説明が
    「複数あるときに渡せ」と言うだけで、**渡す値の探し方が無かった**。専用ツールを足さないのは、
    欲しくなるのが常に snapshot の直後(データは既に届いている)で、ツールは説明文が毎リクエストに乗るため。
    **`scrollFrame:` は ref(整数)も受ける**(2026-08-10。MCP 専用 — DSL の `scrollFrame:` は
    従来どおり文字列のみで、この決定に触れない): id が重複・欠落した容器はセレクタで一意に
    指せないため、`ft_snapshot`/`ft_scroll_to` が返した ref をそのまま渡せば `MCPServer.scrollTo`
    が既存の stale-ref 再照合(`resolveSessionRef` → `RefGuard.relocate`)を通したうえで frame を
    `FlowStep.scrollFrameRect` に入れる(`StepExecutor.scrollContainer` が locator より rect を
    優先し、rect は常に解決済み扱いなので scrollFrame の fail-fast には掛からない)。
    `ScrollFrameCandidates.note` は id が重複・欠落した候補を含む画面でだけこの逃げ道を一言添える。
    規律は `scrollFrameNote` と同じ **true を見つけたときだけ喋る** —— Compose/Flutter の in-app は
    申告できないので、そこで「容器なし」と言うと嘘になる。名指しは **id → ラベル(40字以内)**の順で、
    どちらも無ければ矩形を出して「書けない」ことを明示する(存在しないセレクタを勧めない)。
    1つだけの画面で黙るのは、iOS in-app では `scrollFrame` を渡すと XCUITest フォールバックを
    払うため(選択の余地が無い画面で勧める価値がない)。
    飛び越しの拾い直しの注記も**総称でなく実物の名前**を出す(`suggestedScrollFrame`。
    推測した容器に申告済みの容器が IoU 0.5 以上で重なるときだけ)。
    実画面での確認: 3 SUT(E2E-Android / E2E-CMP on Android / E2E-iOS)の 35 画面で
    印が出たのはスクロール画面3枚だけ・いずれも設計どおりの2容器(縦リスト+横カルーセル)で誤検知0。

    **印が出ない理由は2つあり、混同しない**(2026-08-06 に iOS 設定アプリで実地確認):
    ①**エンジンが申告できない**(Compose/Flutter の自前描画容器)/
    ②**容器がスナップショットに載っていない**。②は iOS で普通に起きる ——
    `scrollView`/`table`/`collectionView` は `BridgeRouter.isEligible` の `default` 分岐、
    in-app は `UIScrollView` が `.other` へ写るので、**どちらも identifier が空なら除外**される
    (Android も resource-id が無い容器は同じ)。**`scrollFrame:` は名前を要求するので、
    ②の容器はそもそも指定できない** = 印が無いことと書けないことが一致していて矛盾は無い。
    容器を型で指定できるようにする(`.scrollView` を書けるようにする)には**ブリッジのフィルタを
    緩める**しかなく、版上げ + `clippingContainer` の推測結果が変わるため 4 SUT の E2E が要る。
    価値は中程度(容器推測が既に大半を吸収している)なので**保留**
  - **`ft_status` は session と「いま前面か」を分けて出す**。session はブリッジが掴んでいるアプリで、
    `ft_navigate home` の後も変わらない。前面判定は XCUITest の `/appstate`(1往復)。
    iOS は**任意の前面 bundle ID を取れない**(`foregroundAppID` は nil を返す)ので、
    「session のアプリが前面か」だけを言う
  - **棚卸し・診断・スクリーンショットの3点**(2026-08-09。他ツールの MCP との比較で出た穴):
    `ft_list_devices` は**マシンプロファイルを前提にしない**(`/fleetest-mcp` の受け手は machines/ を
    一つも持たない)。解決できなければ素のカタログ(`SimulatorCatalog` / `AndroidSerialResolver`)へ
    落ちるが、**落ちた理由を必ず本文に書く** —— 黙って代替すると、登録マシン名とプロファイル名の
    不一致(実在した)を受け手が永久に発見できない /
    `ft_logs` は**ブリッジを一切通らない**(要る場面はアプリが落ちてブリッジごと消えた直後)。
    iOS はホストの DiagnosticReports、Android は adb だけを見る。ここで踏んだ罠が2つ:
    **①クラッシュ直後はまだ .ips が無い**(ReportCrash の書き込みは非同期。見つからないときだけ
    数秒待って引き直す)/ **②既定の窓 300s には前の run のレポートが残っている**(実測で 11 分前の
    ものを掴んだ)ので**経過時間を必ず出す**。Android 側は `pidof` が空のときテキスト一致へ
    落とすと**クラッシュの原因行を捨てる**(`FATAL EXCEPTION` とスタックはパッケージ名を含まず、
    名指しで残るのは `Process:` の1行だけ)ため、crash バッファでは絞らず「絞れなかった」と明示する /
    `ft_screenshot` は既定で縮小 JPEG(`maxWidth` 600)。**費用は画素数で決まる**ので
    バイト数で形式を選ばない —— 平坦な UI では原寸 PNG のほうが JPEG より小さいことすらあり、
    バイト比較で選ぶと大きな画像を返してしまう。600 は実測(1179px の iPhone で CJK 本文も
    ステータスバーも読め、画素は 1/2.4)。密な画面は `maxWidth` / `fullSize` で逃がす
  - **`ft_batch` は StepExecutor に委ねる**(2026-08-10)。MCP の dispatch を順に回す案は採らない ——
    複数手の実行は探索ロジックなので、2つ目の実装を作らず StepExecutor へ渡す規律(`ft_scroll_to` と同じ)。
    委譲の主目的は**「バッチで通った = そのまま書けばシナリオでも通る」を成立させる**こと
    (下書きの検証に、ファイル作成と swift build を払って `ft_run_scenario` する以外の道が無かった)。
    **steps は DSL の手を並べた文字列1本・表記は最小記述の1つだけ**(2026-08-10 ユーザー決定):
    `"steps": "type '#f' 'abc'; scrollTo '#item' direction: .down"` —— 引数は引用符+
    空白区切り・手は `;`(改行も同義。どちらも引用符の中では区切らない。`BatchLineParser.splitSteps`)。
    MCP の arguments はオブジェクト必須なのでキー自体は消せない(`ft_batch { tap … }` のような
    素のブロックはプロトコル上表現できない)。ここへ至る経緯: 14キーのオブジェクト形 →「行そのもの」
    (`tap("#a")` の正形)→ 正形+緩い綴りの併存 → **併存をやめ最小形のみ**。廃止した表記
    (括弧・引数カンマ・配列 steps)は**書き換え方を添えて拒否**する —— 黙って受けると表記が
    再び分裂し、黙って落とすと1往復増える。**文字列の引用符だけは `'…'` と `"…"` の両方を等価に
    受ける**(同日の追決定 —— JSON の `\"` 経由で `"…"` が届くのは自然な書き方なので拒まない。
    案内する推奨は JSON エスケープの要らない `'…'`)。**限定文法のパーサ**(`BatchLineParser`。
    純粋関数・デバイスにも MCPServer の状態にも依存しない)が `name arg*` / `arg := [label ":"] value`
    / `value := string | number | bool | .ident` だけを解釈する —— 入れ子呼び出し・配列・演算子・
    クロージャは構文的に受け付けず明確なエラーにする。
    シナリオへの変換は draft が担う —— 記録は FlowStep からの再生成なので、正形
    (括弧+`"`)の DSL が出て「バッチで通った=シナリオでも通る」の契約は崩れない。
    バッチ文法が executor/codegen の全ステップを表せることは `testRoundTripThroughScenarioCodeGen`
    が守る(正形→最小形の機械変換を挟んで往復)。位置引数の名前は**シグネチャ文字列
    (`DSLCommandIndex.signature`)から導出する**(`BatchArgSpecTable`。名前の一覧をハードコード
    しない)。シグネチャが引数リストの形をしていない `swipe(.up / .down / .left / .right)` だけは
    小さな明示表(`positionalOverrides`)に載せ、辞書キー語彙が DSL 自身のパラメータ名と食い違う
    唯一の箇所(`swipeElementToElement(from, ...)` → バッチの辞書キーは他コマンドと同じ "selector")
    も同様に1件だけの表(`dictKeyAliases`)で吸収する。**未対応ラベルは黙って捨てない**——
    各ビルダに「実際に読むキー」を宣言させ(`BatchStepBuilder.keys`)、シグネチャには載っているのに
    ビルダが対応していないラベル(例: `tap` の `containerInference:`)は名指しで拒否し、シグネチャに
    すら無いラベルは別の文言(`ft_dsl_commands` へ誘導)で拒否する。
    **ref は1手目でだけ書ける**(2026-08-12。それ以前は全面禁止だった) —— 禁止の理由
    「ref はそれを撮ったスナップショットに対してだけ有効で、各手が木を変えるので後続の手の ref は
    黙って別の要素に当たる」は2手目以降にしか当てはまらない。**1手目はまだどの手も画面を
    変えていない**ので、ft_tap と同じ経路(`verifiedRef` = RefGuard の再照合。gone は拒否・
    ghost/移動は警告付きで続行)で解決してよい。実アプリでは重複 id・曖昧ラベルだらけで
    一意に書けるセレクタが存在しない要素が多く、全面禁止だと ft_batch がほとんど使えなかった
    (2026-08-12 の Apple マップ監査)。解決した ref は**そのまま書けるセレクタへ変換してから**
    実行する(`SelectorNaming.graded` = ft_tap の推奨セレクタと同じ実装)——
    変換できない要素は拒否する。「バッチで通った=そのまま書けばシナリオでも通る」は
    セレクタで表せることが前提で、ref はシナリオに書けないため。**何に解決したかは応答に出す**
    (出さないと読み手はシナリオ行を書けない)。記録(`InteractionLog`)も解決後のセレクタで残す。
    **2手目以降の ref は採用しない**(2026-08-16 ユーザー決定。**再提案しない**)——
    一意なセレクタが無い要素をバッチで叩く手段としては**座標タップのほうが筋が良い**。
    ref はシナリオに書けないので「バッチで通った=そのまま書けばシナリオでも通る」の契約から
    外れるが、`tap x: y:` は `ScenarioCodeGen` が 1:1 で書き出せる(2026-08-16 に解禁)。
    拒否文言も `tap` のときだけ座標形を逃げ道として案内する。
    2手目以降の ref は従来どおり拒否し、**文言で理由と書き換え方まで返す** ——
    「そんな引数は無い」で終えると渡し方を探してもう1往復する(2026-08-10 のデバイス確認)。
    通すのは operation/scroll カテゴリだけで、判定は `DSLCommandIndex` から導出する(名前を
    ハードコードしない)。ライフサイクル・破壊的なコマンドは弾く = 1回の承認でデータ消去へ届かせない。
    **検証は実行より前に全手へ通す**(途中で弾くと前半の手だけがデバイスに残る)。
    最初の失敗で止め、**木は最後に1回だけ**返す(毎手の木を積むとバッチにした意味が消える)。
    その最後の木だけは MCP の描画経路を通すので、遮蔽・ghost 等の MCP 固有の注記は付く
    - **「全部通ったのに画面が1ピクセルも変わっていない」を言う**(2026-08-12)。最後の木を
      `snapshotBody` へ直接渡していたため、操作系ツールの settle-lite(`snapshotAfterBody`)を
      通らず、**空振りしたバッチが無条件に成功と表示されていた**(実測: iOS Safari の横スクロール表で
      `swipeBy` が `ok` を返し、木は操作前とバイト一致。同じジェスチャを `ft_swipe` で撃つと
      ちゃんと警告が出る = ツールによって同じ空振りが見えたり見えなかったりしていた)。
      判定は `MCPServer.looksUnchanged` を再利用し(2つ目を書かない)、起点はループより前で
      捕まえる(`recordSnapshot` が上書きするため)。**断定はしない** —— 縁に着いていて
      正当に動かない回がある
    - **`scroll` は codegen が書き戻せなかった**(2026-08-12 に発見・修正)。`ft_batch` は
      `scrollDown/Up/Left/Right` を実行できる(カテゴリ `scroll` は許可済み)のに
      `ScenarioCodeGen` に `case "scroll"` が無く、`// (unsupported step: …)` に落ちていた ——
      **「通ったバッチは 1:1 でシナリオ行になる」という契約が破れていた**
  - **引数語彙は操作系の全ツールで揃える**(2026-08-10 の見直し): 長押しは `holdSeconds`
    (DSL の `tap(holdSeconds:)` と同語彙。旧 `duration` は黙って既定値へ落とさず改名を案内して拒否)、
    `snapshotAfter`/`waitFor`/`timeout`/`expandBulk`/`interactiveOnly` は操作系ツール
    (tap/type/drag/swipe/double_tap/press/pinch/navigate/**open_url**)全部に載せる(無いツールだけ
    毎回 ft_snapshot の1往復=承認1回を余計に払っていた。`ft_open_url` は 2026-08-12 に追加 ——
    URL を開くのは開いた先を見るためなので、往復が必ず1回増えていた。**1行目の文面は
    `snapshotAfter` の有無で出し分ける**: 木を返すのに「後で撮り直せ」と言うのは矛盾する)。
    集合は `MCPServerToolDefinitionsTests` が守る。
    **繰り返し載るプロパティ説明は短文に留め、ニュアンスは initialize の instructions へ1本化**
    (`MCPServer.serverInstructions`。プロパティ側に書くと全ツールへ複製され毎セッションの
    コンテキスト費用になる —— udid/allowVersionSkew の長文複製だけで約9k文字あった)
  - **ref の再ターゲットは「なぜ動いたか」の手掛かりまで返す**。原因は断定できないが、
    **同じ深さの兄弟が同じ分だけ動いたか**は手元の2枚から言える(揃っていれば容器のスクロール、
    その要素だけならレイアウト変化)。**画面全体で数えてはいけない** —— 固定ヘッダやタブが
    多数派になり、実測でスクロールを「動いていない」と誤答した(動かない 13 対 動いた 7)
  - **失敗と曖昧さの返し方**(2026-08-06 の外部フィードバック):
    `ft_status` は **Android で複数台のとき失敗させず全台を並べて返す**(読み取り専用なので
    「曖昧なまま操作させない」規律に触れない。操作系は従来どおりエラー)/
    `ft_scroll_to` の空振りは**止まった画面で引けるものの一覧**と「素のラベルは完全一致・
    部分一致は `*…*`」を添える(往復を省き、記法の誤りに気づかせる)/
    残像は**一覧の行そのもの**にも `⚠️scroll-leftover` を出す(先頭の注記だけでは、
    行から ref をコピーする動作に届かない)/ プロファイル解決の警告は
    **stderr に捨てず次の応答へ載せる**(MCP クライアントは stderr を見ないので、
    デバイス名の不一致が実行するまで表に出なかった)/ `ft_doctor` は FM 不可のとき
    **止まる機能と代わりの書き方**まで返す(`FMDoctor.unavailableImpact`)
  - **既にある逃げ道は、払った場所で名指しする**(2026-08-16 の外部評価。指摘4件のうち3件が
    「機能はあるのに応答が名乗っていない」形だった。実バグ0):
    **⑴ 待ちの上限**(`MCPServer.waitTimeoutRemedy`)—— `timeout` は全ての待ちに 2026-08-10 から
    あるのに、**外れた回の文がどこにもそれを名指していなかった**ため「5秒固定」と読まれ、
    外れると分かっている待ちにも毎回満額を払わせていた(評価の1セッションで 10 秒)。
    3経路(ft_snapshot の waitFor / snapshotAfter の waitFor / waitForChange)に同じ1文を出す。
    **当たった回には出さない** —— 逃げ道は払った場所だけで言う。
    **⑵ 木の畳み方の継承**(`MCPServer.inheritingSnapshotFilters`)—— `snapshotAfter` は継承して
    名乗っていたが、**`ft_scroll_to` は継承そのものをしていなかった**(黙って全行を返す)。
    interactiveOnly を渡した後、**どのツールで読むかで出力量が変わる**のは、指定が効いていない
    ように見える。**木を返す口はすべてこの1関数を通す**(2つ目の継承規則を書かない)。
    **⑶ シート展開救済の名乗り**(`MCPServer.sheetRescueMarker`)—— 散文は出ていたが、所要時間の
    内訳(`sheet-expand rescue +1.4s`)と語が違い、**1つの文字列では拾えなかった**。
    構造化フラグの要望だったが、**この応答の宛先はエージェントの本文1本**なので機械可読チャネルは
    増やさず、4形(記憶で省いた/伸びなかった/展開だけで出た/再試行した)の先頭の語を固定する。
    **⑷ `ft_type` の `replace: true` は仕様どおり素の type の約2倍**(実測 6.1s 対 2.3s)。
    内訳は clear の1往復と**打った結果の読み返し**(in-app iOS は clear/type の成否を検証せず
    YES を返すので、読み返さないと「replaced」が嘘になる)。`snapshotAfter`(かつ `pressEnter`
    無し)ならその1枚と共有するので、値段と避け方をスキーマに書いた
  - **「書けるセレクタが無い」を黙らない**(2026-08-07。実アプリの探索で出た4形):
    同じ id を複数の要素が持つとき行内に `×N`(`SnapshotRenderer`。生成側は一覧を読んで
    コードを書くのに、そのセレクタが曖昧だという信号がどこにも無かった)/
    **ラベルも id も無い clickable** の件数と ref(座標でしか指せないことを伝える。
    実測: 経路の移動手段タブがアイコンのみで、書ける手段が何も無かった)/
    3件以上が共有するラベル(素のラベルでは一意に指せない)/
    `ft_scroll_to` にも複数スクロール領域の注記(`scrollFrame:` を渡すべき当人に出ていなかった)
  - **`checked` は行に出す**(2026-08-07)。`disabled` は出すのに `checked` は一度も
    描画しておらず非対称だった。これが無いと、タブの選択状態は `checkIsON` では表明できるのに
    **MCP からは観測できない**。`true` のときだけ出す(印が無い = オフと状態を持たないの両方)
  - **別パッケージの木は、相手がシステム UI なら案内を変える**(2026-08-07)。
    許可ダイアログ(`permissioncontroller` 等)で従来の「`ft_launch` してから ref を信用しろ」を
    そのまま実行すると、**ダイアログを放置したままアプリを再起動してループする**。
    既知のシステム UI では「これを操作すれば元へ戻る」と言う(`MCPServer.systemDialogPackages`)
  - **`ft_type(ref:, pressEnter:)` はフォーカスが立つのを待ってから Enter を撃つ**
    (`MCPServer.awaitFocus`。2026-08-06)。直前に別の欄へ入力していると移動が間に合わず、
    Enter が**前の欄**へ飛んで黙って何も起きない(Android で観測)。
    **報告しないフレームワークで待ち続けない**のが要点 —— Compose iOS の a11y 要素は UIResponder では
    ないので in-app は `focused` を一度も返さない。「木の中に誰も `focused` を名乗らない」を
    報告しない経路と読んで即座に諦める。DSL の pressEnter も同じ待ちを持つ(定数は
    `FTCore.FocusWait` で共有。あちらはロケータが無いので「どこかの focused / keyboardShown」を合図にする)
  - この追従によって、**マップ系ジェスチャの MCP と実行の食い違いが消えた**(2026-08-04)。
    `profile` 付きなら iOS の Compose でもダブルタップが、Flutter でもピンチが効く。
    `profile` 無しは XCUITest 経路のままなのでこの2つが効かず、応答テキストに切り分けを添える
    (`MCPServer.iosEngineHint`)。表と実測は docs/commands.md
- **XCUITest ランナーは「操作の失敗」でプロセスごと落ちる**(Xcode 27 beta のツールチェーン不具合。
  2026-07-28 にクラッシュレポートで確定)。XCUI の失敗は `_XCUIFailWithError` が issue を記録するが、
  ブリッジのハンドラは **main queue 上 = テストメソッドのスタックの外**で動く
  (`BridgeHTTPServer.dispatchToMain`)ため XCUITest が「現在のテスト」を特定できず
  `XCTFallbackIssueHandler` へ回り、そこから XCTest↔swift-testing 相互運用が**無限再帰**して
  スタックオーバーフロー(実測 950 段超)で SIGSEGV する。**`continueAfterFailure` も
  `FTCatchObjCException` も効かない**(issue がテストケースに届かない / ObjC 例外ではない)。
  ランナーが死ぬとブリッジが消え、**その run のワーカーが離脱**して振り直しになる。対処は2層:
  1. **ランナー**: 操作系(tap/type/pressEnter/swipe/drag/press)は `requireLiveApp()` で
     `app.state` を確認し、起動していなければ XCUI に触れず **503** を返す
     (409 はセッション消失専用・501/404 はフォールバック判定に使用済みのため空いている 503)。
     snapshot/screenshot には入れない(`state` は IPC で毎回コスト・取得系は issue を出さない)
  2. **ホスト**: `AppAttachDriver` が ref 無し操作の前に `ensureAttached()` で
     **セッションを自分の bundleID へ揃える**(1インスタンス=1シナリオにつき1回)。
     XCUITest ブリッジは run 内で使い回されるため、セッションが**前のプロジェクトのアプリ**を
     指したまま来ることがある(実測: E2E-iOS の次に回った E2E-Flutter の `scrollTo` が
     `com.ftester.e2e.ios` を掴み、それが未起動で上記クラッシュに至った)。
     409/503 は「attach し直せば通る」として activate+1回再試行

  効果(`--ios --ios-inapp` フル構成): 離脱がベースライン 2回中2件 → **2回中0件**。
  追加の activate は1シナリオ1回・ジェスチャを XCUITest へ回すときだけなので、
  **run 時間に有意差なし**(3 SUT の合計で ±1s 以内・2026-07-28 実測)。
  なお**トリガは他にもあり得る**(要素が hittable でない等の XCUI 失敗)。恒久対策は
  ランナーから swift-testing を外せるかの調査が要る(未着手)
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
- **偽陽性検証の run(実行プロファイル `falsePositiveCheck`。**既定 true**。2026-09-03 にオプトインをやめた)では、
  `exist`/`textIs` は既定 `requireVisible: true` のため、ソフトキーボードに覆われた要素は
  「`false positive (occlusion)`」で失敗する**。入力を伴う画面では検証対象・操作対象を入力欄より**上**に置く
  (TestProjects/E2E-CMP のテキスト入力画面がこの配置。2026-07-22 実測)
- **inapp ブリッジは注入先アプリのプロセス内常駐**なので、アプリがクラッシュ/終了すると HTTP が
  `DriverError.bridgeConnectionRefused`(「Could not connect」)になる。xcuitest/Android はブリッジが
  別プロセスのためこの切断は起きない(inapp 固有)。切断時は `InAppDriver` がホストの
  `~/Library/Logs/DiagnosticReports` から対象 bundleID の直近 `.ips` を探し、レポートのエラー行に
  クラッシュレポートのパスと終了理由を1行で添付する(`SimulatorCrashReport`。JSON 形式優先・旧テキスト
  形式もフォールバック解析)。`.ips` が**見つからない**ときは「OS 終了/メモリ圧/自発終了・混在実行の
  suspend の可能性」を切り分け文言として添える(クラッシュ以外の切断と区別する)

---

## 11. テストプロジェクトと実行プロファイル(2026-07-08)

シナリオのフラット配置(リポジトリ直下 scenarios/)と UserDefaults 頼みの実行設定を廃止し、
**テストプロジェクト**(TestProjects/<name>/)と**組み合わせ型の実行プロファイル**(JSON)に移行した。

### 11.1 テストプロジェクト

`TestProjects/<name>/` = シナリオ+プロファイル+レポートを持つ器。プロジェクト毎に SPM の
executableTarget `fleetest-scenarios-<name>`(path: `TestProjects/<name>/scenarios`)が対応する。

- **Package.swift のマーカー区間自動生成**: `// === fleetest projects begin/end ===` の区間を
  `fleetest project create/sync` が全置換で再生成する(手編集禁止)。書換後に
  `swift package dump-package` で検証し、失敗時は元内容へロールバック(PackageManifestEditor)。
  マニフェスト内容自体が変わるため SwiftPM のマニフェストキャッシュ stale が構造的に起きない
  (Package.swift 内で FileManager 走査して動的生成する案はキャッシュ stale リスクで却下)
- プロジェクト間はビルド隔離される(1 プロジェクトのコンパイルエラーが他を止めない)。
  バイナリ毎に objc 走査が分かれるため、シナリオ一覧のプロジェクト別化は発見ロジック無変更で成立
- プロジェクト名は SPM ターゲット名になるため `^[A-Za-z0-9_][A-Za-z0-9_-]*$`(日本語はクラス名側で使う)
- `--project` 省略時の解決: TestProjects/ が 1 つならそれ → LocalConfig.defaultProject → 候補一覧付きエラー
- CLI: `fleetest project create <name> [--app <bundleID>]` / `project list` / `project sync`
  (手動コピーや git pull 後の TestProjects/ ↔ マーカー区間の再整合)

### 11.2 プロファイルは 3 種の組み合わせ

`TestProjects/<name>/profiles/` 配下。共通設定の継承ではなく**部品の参照合成**で表現する。

**アプリケーションプロファイル** `apps/<name>.json` — common(共通)→ ios/android の後勝ちマージ。
`autoInstall` は **common のみ**採用(未指定時の既定は
`appPath` の有無 — パスを書いたのに入らない事故を避ける。止めたいときだけ `false` を明示する)、
`appName`(表示名)・bundle ID(`app`)・`appPath`・`appPathPhysical` は
**ios/android セクションのみ**採用(common に書くと merging で無視され validate が警告する。
表示名を OS ごとに書き分けられるようにするため、common の `appName` は継承しない):

```json
{ "common":  { "autoInstall": true },
  "ios":     { "appName": "サンプルアプリ", "app": "com.example.sampleapp",
               "appPath": "~/builds/SampleApp.app",
               "appPathPhysical": "~/builds/device/SampleApp.app" },
  "android": { "appName": "サンプルアプリ", "app": "com.example.sampleapp", "appPath": "builds/app-debug.apk" } }
```

**`appPathPhysical` は実機に配るパッケージ**(省略時は `appPath`)。iOS はシミュレータ用ビルド
(iphonesimulator SDK・未署名)を実機へ入れられず、`0xe8008014 The executable contains an
invalid signature.` で失敗するため、同じアプリでも成果物が2つ要る。**端末ごとにアプリ
プロファイルを分けないための欄**(2026-08-26 ユーザー決定。分けると実行プロファイルまで
二重管理になり、`all` のような混在プロファイルに実機を入れられない)。Android は同じ APK が
両方で動くので普通は書かない。選び分けの規則は `ResolvedAppTarget.packagePath(physical:)` の1箇所。
**ステージング先は `apps/physical/<ファイル名>`**(仮想デバイス用は `apps/<ファイル名>`)——
2つのビルドは同名(`dist/ios-simulator/X.app` と `dist/ios-device/X.app`)なのが普通で、
同じディレクトリへ置くと後からステージングした方が相手を上書きし、**片方の端末に必ず誤った
ビルドが入る**。実機用の転送は**その platform に実機が居る run でだけ**行う(100MB 級を
毎回リモートへ rsync しない)。**実機が居るのに `appPathPhysical` が無い iOS の run は
resolve の時点で警告する**(インストール失敗はブリッジ供給の後に出るので遅い)。

`appPath` の相対パスは**リポジトリルート**基準(上例の `builds/app-debug.apk` は `<repoRoot>/builds/...`)。
`~` 展開・絶対パスも可。ビルド成果物は TestProjects/ 外に置くのが普通なためプロジェクト基準にしていない。

**Android は `.apk` のほかに `.apks`(App Bundle 由来のスプリット束)も書ける**(2026-08-19)。
`.apks` は単一 APK ではないので `adb install` に渡せず、**インストールは bundletool へ委譲する**
(`ApksBundle`。無ければ「`brew install bundletool` するか `FT_BUNDLETOOL` を指す」で落ちる)。
選別を自前でやらない理由は実測 —— 実物の `.apks` には variant 違いの master が2つ
(`base-master.apk` / `base-master_2.apk`)あり、正しい方は名前ではなく `toc.pb` の targeting で決まる。
差分判定(下の 4.)は bundletool 抜きで効く: 端末に入っている base/split の**各ファイルの md5 が
この `.apks` のエントリのどれかと一致するか**を見る(大きさで候補を絞ってから展開するので、
79MB を毎回ほどかない)。限界は**足りない split を見つけられない**こと(何が入るべきかは
targeting = bundletool にしか決められない。feature module を足した回だけ入れ直しを取りこぼす)。

`healthCheckURL`(common のみ・任意)— アプリが依存するバックエンドの死活確認 URL。実行開始前に
3秒タイムアウトで到達確認し、不達なら警告する(実行はブロックしない)。バックエンド停止中は
アプリが非同期処理でクラッシュし「Application is not running」で全滅して原因が見えにくいため
(2026-07-21 実害)、入口で気づけるようにする。

**マシンプロファイル** `machines/<マシン名>.json` — ファイル名がマシン名(`M2 Ultra(192GB).json` 等)。
1 ファイルに ios / android セクションを書き、そのマシンで使えるデバイスを `name` 付きで列挙。
マシン別ファイルなので UDID / AVD などマシン固有の実体をそのまま書ける:

```json
{ "ios":     { "devices": [ { "name": "simulator1", "simulator": "iPhone 17 Pro", "os": "27.0" } ] },
  "android": { "devices": [ { "name": "emulator1", "avd": "Pixel_9" },
                            { "name": "emulator2", "avd": "Pixel 8(Android 14)" } ] } }
```

- デバイス名は 1 ファイル内(ios+android 横断)で一意(重複はロード時エラー)
- iOS: `simulator` 名+`os`(または `udid` 直指定。`port` で固定も可)
- Android: `avd`(AVD の ID と表示名(config.ini の avd.ini.displayname)のどちらでも可。
  起動中エミュレータの AVD 名と照合して adb serial に解決。未起動はヒント付きエラー。
  **エミュレータの** serial 直指定は廃止 — serial は起動順で変わるためプロファイルに書かない)
- `fleetest profile setup --auto-device` の選定規則(`DevicePicker`)— iOS は**最新 OS の
  既存シミュレータ**(名前に "Pro" を含むものを優先)、Android は config.ini の **API レベルが
  最大の既存 AVD**。**iOS は iPad を候補から除外する**(除外しないと "Pro" 優先が iPad Pro を
  掴む)。除外が効くのは自動選定だけで、`--simulator`/`--udid` や `api create-device` で
  iPad を明示指定する経路は従来どおり通る

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
- **実機は一括操作(`devices up/down` / `api devices-up/devices-down/devices-restart` /
  モニターの「全て起動」「全て終了」)の対象外**(ユーザー決定 2026-08-30。再提案しない)——
  実機は端末そのものを起動・停止できないため、混ざっていると一括起動が数分のブリッジ供給
  (build-for-testing)を始めて同時起動枠(2台)の半分を専有し、他機のブートを遅らせていた。
  一括操作は実機をキューに積まず1行ログするだけで、`deviceStopping`/`deviceStarting`/
  `deviceFinished` も出さない(拡張のタイルを一括操作の「待機中/シャットダウン中」に倒さない)。
  **ブリッジの起動・停止は `fleetest run` とモニタータイルの右クリックメニューだけ**が担う
  (ラベルは「ブリッジを起動/停止」)。`bridge down --all` は例外(明示的な全停止コマンドなので
  実機のブリッジも含めて止める)
- **iOS 実機の `state: "booted"` は「端末は接続済みだがブリッジが1本も無い」**の意味
  (`ApiMonitorCommand.iosState`。シミュレータの booted=起動済みとは意味が違う)。実機のブリッジは
  自動供給されないのでこの状態は待っても変わらない ⇒ モニタータイルは**未起動として表示**し、
  右クリックも「ブリッジを起動」を出す(`deviceTiles.js` の `bridgeNotRunning`)。
  Android 実機の booted は「adb は見えるがブート未完了」= 本当に遷移途中なので対象外
- ライブ映像は実機だけ **`fleetest-devicepoll`**(スクショのポーリング → MJPEG)を使う。
  `fleetest-simstream` は CoreSimulator 私有 API で iOS 実機に使えず、`fleetest-androidstream`
  (screenrecord)は Android 実機だと静止画面でフレームが流れないため(詳細 docs/verification.md)
- 実機で成立しない機能は静かに無効化される: iOS の録画(`simctl io recordVideo`)、
  Reduce Motion 自動設定、autoInstall の差分スキップ(コンテナを読めないため毎回インストール)。
  Android 実機は録画(`adb screenrecord`)も従来どおり動く
- `model` / `os` は実機では**表示専用**(登録時に控えるだけで同定には使わない。端末を挿し替えても
  追随しない)。iOS シミュレータの `simulator`/`os` だけは実体解決に使う値なので意味が違う
- 実機の要件と罠(iOS の署名・LAN/USB 経路、Android の画面ロック)は docs/verification.md

**実行プロファイル** `runs/<name>.json` — アプリ+デバイス名リスト+実行時設定。
platform フィールドは持たず、**iOS/Android のデバイス名を混在させれば両OS同時実行**になる。
`machine` は使うマシンプロファイル名の明示指定(未指定なら FT_MACHINE、それも無ければ
machines/ が1つのときだけ自動採用)。
**`fleetest profile setup` は書いたときのマシン名を必ず残す** — 拡張の実行プロファイル編集は
`machine` が無いと「(未指定)」になりデバイスを選べないため。別マシンへ持ち出すときは
同名の `machines/<名>.json` を用意するか、この行を消して登録名解決に戻す:

```json
{ "app": "sampleapp",
  "devices": [ { "name": "simulator1" }, { "name": "simulator2" }, { "name": "emulator1" } ],
  "fm": true, "heal": true, "reportDir": "reports", "defaultTimeout": 5,
  "wipeDataOnBloat": true, "wipeDataThresholdGB": 8 }
```

`fm`(既定 true)は FM(Foundation Models)機能の親スイッチ。false にすると自己修復(heal)・
偽陽性検証(exist 等の FM 視覚照合)・`screenLooksLike`・失敗時トリアージを含む FM 呼び出しを一切行わない
(子ランナーへは `--no-fm` 等で伝搬し、delegate 自体を作らない)。個別トグルは
**`heal` / `falsePositiveCheck` / `screenLooksLike` / `triage` の4つで、いずれも既定 true**
(`falsePositiveCheck` は 2026-09-03 にオプトインをやめた。`triage` は同日に追加)。
親が false なら個別指定に関わらず全て無効。screenLooksLike を無効にした run では該当ステップは
skip(素通り)になり、FM 利用不可時と同じ扱い。**`triage` は合否を変えない助言**なので、
切っても検証の強度は落ちない(失敗のたびに平均6秒の FM 呼び出しが走るのを避けたいときに切る)。
子への伝搬は `ScenarioHost` が `--no-triage` 等を渡す形で、3段(プロファイル → 子 → 実行時)が
つながっていることは `FMToggleWiringTests` が固定する。UI はデバイスタブの実行プロファイル設定
「FM(Foundation Model)」セクション(親チェックボックス ON のときだけ個別トグルを表示)。

`wipeDataOnBloat`(既定 true)は実行開始時に Android AVD の wipe 対象
(userdata/cache/snapshots)合計が `wipeDataThresholdGB`(既定 8。**Play イメージは wipe 直後の
再構築だけで 2〜4GB になるため 4GB 以下はスラッシング**、実測 2026-07-17)超過なら Wipe Data してから
実行する(AndroidDataWiper.swift。ゲストは初期化されるが、アプリは appPath があれば強制
再インストール、ロケールは下記 `locale` が再ブート後に自動適用される)。

手動の Wipe Data はプロファイルタブの**デバイス行の右クリック**から撃つ(Android =
`fleetest api device-wipe --platform android --avd <ID>` = 上と同じファイル集合の削除、
iOS = `--platform ios --udid <UDID>` = `simctl erase`。リモートは `remote exec <機械> --` で回す)。
**識別子だけで撃ち、プロジェクトもマシンプロファイルも参照しない**(`api delete-device` と同じ契約)
—— 名前で引くと、リモートではランナー側の複製が古いときに `device not found` で必ず失敗し
(複製の更新はモニターの fan-out 開始時だけ)、操作のたびにプロジェクトを送り直す羽目になる。
**実機には項目を出さない**(識別子から作る spec は必ず仮想デバイスなので原理的に来ないが、
`DeviceWiper.target` が別の呼び手のために拒否を持ち続ける)。**識別子を持たない行にも出さない**
(avd 未設定の Android エントリはそもそも wipe できない)。

**停止を確認できなければ1バイトも消さず、失敗として返す**(2026-08-29 に「中止したのに
ok:true」を踏んだ。台が止まっただけで中身は残り、利用者には成功と見えた)。確認は2つの
どちらかで取れればよい: ①adb の serial が消えた ②**その AVD の qemu プロセスが消えた**
(`AndroidDataWiper.avdProcessPresent`。前方一致では見ない —— 片方がもう片方の接頭辞になる
AVD 名は普通にある)。②を併せて見るのは、まさに kill が遅い状況では adb 側も詰まっており、
①だけだと「本当は止まっているのに確認が取れない」で中止してしまうため。締切は 60 秒
(フリート実行中は 30 秒で取り切れなかった実例がある)。
**しきい値は見ない**(人が選んで撃つので、消すか消さないかの判断はもう済んでいる)。
本体は自動チェックと同じ `AndroidDataWiper.performWipe` / 起動・停止は `DeviceBooter` を通す ——
「停止を確認できたときだけ消す」「稼働中だった台だけ起こし直す」を2箇所に持たない。
拡張はこれを **device ジョブ(op: `wipe`)としてライフサイクルの直列キューへ載せる**
(中で停止と再起動をするので、一括起動や個別の起動/停止と重なると simctl/adb・ブリッジ供給が
競合する)。進行は CLI の NDJSON `wipeStatus`(phase: stopping/rebooting/done/failed)を
run 開始時の自動 Wipe と**同じタイル表示**へ流す。

`recoverCpuFallbackToGpu`(既定 false)を true にすると、実行開始時に**画面凍結で CPU 描画
(swiftshader)へ落ちた Android エミュレータを GPU(`-gpu host`)で起動し直す**
(AndroidGpuRecovery.swift。`dumpsys SurfaceFlinger` で現に CPU の個体だけが対象、1台ずつ直列)。
GPU モードは emulator の**起動引数で固定**されるためプロセス再起動が必須で、該当機1台につき
run 開始が約1分延びる(ゲスト再起動では戻らない)。戻した先で再び凍結すればモニターの watchdog が
また CPU に落とす(§12.4 の既知トレードオフ)。UI はデバイスタブの実行プロファイル設定
「CPUフォールバックをGPUに回復する」。拡張側の記憶(`MonitorDeviceOps.cpuRenderNames`)は
モニターが再検出した renderMode を見て `syncCpuRenderNames` が落とす(run 側の復帰は拡張の外で
起きるため、これが無いと次の個別 device-up が再び swiftshader で起こしてしまう)。

`enableAnimations`(既定 false)を true にすると、**テスト対象アプリのアニメーションを残す**。
既定(false)では run 開始時に Android の `window/transition/animator_*_scale` を 0 にし、iOS
シミュレータの Reduce Motion を ON にする(アニメーションは a11y イベントを出さないため、静穏判定を
通過した後も絵が動き続けてスクリーンショットが遷移途中を掴む。§7 の実害)。判定元は
`FTCore/AnimationPolicy`(実行プロファイル → `FT_ANIMATIONS` → 各ドライバ。CLI は
`fleetest run --enable-animations`、環境変数直指定でも ON にできる)。

適用は2箇所ある。**ブリッジのコールド起動時**(`AndroidBridge` / `BridgeLauncher`)だけでは
ブリッジが run をまたいで再利用されたときに前の run の状態が残るため、**run 開始時にも毎回同期**する
(Android: `ProfileWorkerFactory.syncAnimationSettings`、iOS: `buildIOSWorkers` の供給直後)。
Android 実機はグローバル設定が**永続的に**書き換わるので、現在値を読んで差分があるときだけ書き、
そのときだけ1行知らせる(エミュレータ/シミュレータは無条件・無言)。iOS 実機はホストから
アクセシビリティ設定を変更できないため対象外(端末側で手動設定する)。

`homeOnStart`(**既定 true**)は run 開始時に各デバイスへ `home()` を1回撃つ
(`ProfileWorkerFactory.pressHomeOnStart`)。一斉に launch した直後の端末は「描画要求が無いだけ」で
画面が黒いまま止まることがあり、そのままだと凍結と見分けが付かない(2026-08-11 実測: 黒かった5台の
うち4台は入力で戻った)。予防として1回だけ入力を入れる。**デバイスあたり1回**なので実行時間への
影響はほぼゼロ。UI はデバイスタブの実行プロファイル設定。

`iosFastInput`(既定 false)を true にすると **iOS xcuitest ブリッジの入力で quiescence 待ちを
飛ばす**(`FT_FAST_INPUT=1` を実行環境へ注入し、`BridgeClient.fastInput` が受ける。CLI は
`fleetest run --fast-input`)。動きの激しい画面では整定前タップのフレークリスクを伴うので
オプトイン。計測値は docs/performance-tuning.md。**効くのは XCUITest ランナーだけ**
(`Runner/FleetestRunnerUITests/FastInput.swift`。`fast` は in-app ブリッジにも送られるが
あちらは解釈しない = quiescence の概念が無いため)。

`iosPreActionWarmup`(**既定 true**)は **interop WebView 画面(domInterop モード)の委譲イベント
直前に、ランナーへ木を1回読ませてから撃つ**(`WebViewDelegatingDriver.warmDelegatedForEvent`)。
attach したままの XCUITest セッションは、ランナーに問い合わせないまま数秒置いた直後の
座標イベントを **200 を返しつつ届け損なう**(実測 約13%。ページは pointerdown すら見ない。
機構は非公開で特定できておらず、観測に立脚した防御。A/B と経緯は docs/verification.md
§interop WebView)。時間閾値にしないのは、短いギャップでも確率的に落ちる実測があり安全な
境界を引けないため。false は `FT_PRE_ACTION_WARMUP=0` として注入される(ProfileRunner /
ApiRunCommand の2箇所)。**効くのは hybrid の domInterop 経路だけ**(委譲モード・xcuitest
エンジンは毎ステップ ランナーが働くので元から出ない)。コストは該当画面のイベント1回につき
約 +0.4 秒で、スイート全体では並列に隠れて差が出ない(25周比較 88.9s vs 90.0s)。
UI は実行プロファイル設定の iOS セクション(inapp エンジン ON のときだけ表示)。

`record`(既定 false)を true にすると、各ワーカー(デバイス)で run 全体を録画し続けつつ
(iOS: `simctl io recordVideo` の .mov / Android: `screenrecord` の 180 秒セグメント群)、
ファイナライズ時に**テスト関数(シナリオ)ごとに1本の mp4**へ壁時計区間で切り出して
`<runDir>/recordings/` に保存する(AVAssetReader/Writer で該当区間だけ半分解像度+低 bitrate の
H.264 に再エンコード。VFR ソースの区間頭フレーム欠落は直前サンプルの retime で補う)。拡張側との
契約は `recordings/index.json`(schemaVersion 2。VideoRecordingCoordinator.swift・
RecordingIndex.swift・RecordingWallClock.swift)。録画自体の失敗は run を失敗させない。

**録画できることを実物で1本確かめてから本番を始める**(2026-08-26)。`simctl io recordVideo` は
**端末側に録画セッションが刺さっていても "Recording started" を出し、0 バイトの .mov を作り続ける**。
気付けるのは run の終わり(切り出し)で、その run の録画は全部失われる。そこで
`IOSSimulatorVideoRecorder.start()` は ①同じ udid の stale な client を pkill(従来)
②**1 秒だけ録って閉じ、ファイルが空でないかを見る**(新規)—— 空なら「この端末は録画できない」と
理由と復旧手順(デバイスの停止→起動)を出して**その台の録画だけ諦める**(run は続ける)。
**「ファイルが育たない」は検知に使えない** —— 正常な録画でも閉じるまで 0 バイトのまま
(実測: 8 秒間ずっと 0、停止した瞬間に 21KB)。だから*閉じてから*大きさを見る。

**失敗しても index は残す**(2026-08-26)。集計欄は2つあり**別のことを言う**:
`clipsAttempted`/`clipsFailed` は「録れた動画から切り出せなかった」、
**`sourcesFailed` は「そもそも録れていない」**(録画プロセスは起動したのに、読めるファイルが
1本も残らなかったワーカー数)。以前は後者のとき index を書かずに `recordings/` ごと消していたため、
**録画が全滅した run は拡張の録画タブから黙って消え、「録画していない run」と区別が付かなかった**
(実害: `simctl io recordVideo` が 0 バイトの .mov を作る Mac で、その機械のセッションだけ
一覧から消えた。fleetest ではなく環境側の不調だったが、画面からは追えなかった)。
拡張は行に「録画失敗 N 台」を出し、再生ビューでは**「録れていない」を「切り出せなかった」より
優先して**理由に出す(直す場所が simctl / screenrecord 側なのか、エンコーダ側なのかが変わるため)。

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

1. **マシン決定**: 実行プロファイルの `machine` > `FT_MACHINE` 環境変数 > (旧: 登録名。廃止済み、
   `~/.config/fleetest/config.json`)> machines/ が 1 ファイルならそれを自動採用 > エラー。
   設定を UserDefaults にしないのは CLI/MCP/VSCode 拡張(内部で `fleetest api` を呼ぶ)の
   複数プロセスでドメインを揃えて共有するため
2. **デバイス解決**: 実行プロファイルの各 name を現在マシンのマシンプロファイル(ios→android の順)
   から引く。このマシンに無い name は**スキップ+警告**(実行プロファイルをマシン非依存で使い回すため)。
   1 台も解決できなければエラー。Android は `AndroidDeviceCatalog.resolveSerial` が
   **AVD ID 完全一致**でのみ serial を引き、不一致は throw(代役フォールバック無し)。
   → **profile 外のはぐれエミュレータは profile 実行には一切混入しない**(ワーカー0件)。
   ただし serial 未指定の対話コマンド(`ft_status`/`ft_snapshot` 等)は接続中デバイスが
   **1台のときだけ**それを自動採用する(2026-08-06。複数なら AVD 名付きで列挙してエラー)。
   はぐれ Android 機が1台混ざっていると、それが唯一の候補になって診断画面がそれになりうるので、
   規模ランの調査前に `adb -s <serial> emu kill` で掃除する(2026-07-16)
3. **アプリ解決**: common → デバイスの platform セクションの後勝ちマージ。`app`(bundle ID)必須
4. **並列数 = 解決後のデバイス数**(maxParallel は存在しない)。プラットフォーム毎にワーカーを立て、
   RunOrchestrator の platform 別キューで両OS同時並列実行
5. platform 未指定(@TestClass / @Test 両対応)のシナリオは iOS ワーカーがいれば ios キューへ。
   **platform を宣言していて、この run がその OS を回さないシナリオはキューに入れず skipped**
   (`PlatformApplicability`。ProfileRunner / `api run` の profile 経路だけ。
   `--ports` / `--serial` 直指定は回す OS の集合を宣言しないので対象外)
6. 未知キーは警告(タイポ検出)。相対パスのチルダ展開あり。基準は用途で異なる:
   `appPath` はリポジトリルート基準、`reportDir` はプロジェクトルート基準(RunProfile.resolve)
7. 合成後は必須検証済みの `ResolvedProfile` になり、実行コードはこれだけを見る

### 11.4 実行フロー(fleetest run --project P --profile ios)

1. ProfileResolver で合成 → CLI 明示引数(--heal/--report-dir 等)が最終上書き
2. `ScenarioHost.build(project:)`(ホスト 1 回。入力の BuildFingerprint が前回ビルドと一致すれば
   スキップ=無変更の再実行で no-op build ~2.6s を払わない。performance-tuning §3.2)。
   `fleetest api run` の並列実行経路ではワーカー供給(3〜4)をビルドと並行に開始する
3. **デバイス供給**: iOS は BridgeProvisioner がポート範囲(8123〜)を短タイムアウトで並行スキャンし、
   /status のデバイス名 × simctl の UDID 照合で**稼働中ブリッジを再利用**、不足分は空きポートを採番して
   BridgeLauncher(xctestrun FT_PORT 注入)で起動・waitUntilReady。シミュレータの新規作成はしない
   (同名複数の曖昧時は UDID 明記を推奨)。Android は AndroidDeviceCatalog で avd 照合。
   コールド起動は「プランニング(ポート採番、直列)→ 共有ビルド(dylib/xctestrun、直列)→
   起動(デバイス単位で並列。hybrid の 2 ブリッジはデバイス内直列)」(performance-tuning §3.2)。
   **run は終了時にブリッジを停止しない**(常駐を残すのが仕様。次の run が再利用する)
4. **自動インストール**: `appPath` あり+`autoInstall`(**未指定の既定は appPath の有無**。
   `false` 明示で opt-out)→ オーケストレータ投入前に各ワーカーへ並行 install
   (差分判定=installedIsCurrent も並列。失敗ワーカーは離脱、残ワーカーがキューを引き継ぐ)。
   **ライブ操作(記録開始)の install も同じ差分判定**を通す(`ApiLiveServe`。無条件に入れ直すと
   記録のたびにアプリが終了し、状態が消える)
5. RunOrchestrator で並列実行。ワーカーラベル=デバイスの論理名。レポートは
   `TestProjects/<P>/reports/`、ヒールキャッシュは `--project-dir` 経由で `TestProjects/<P>/.fleetest/` に分離
   - **シナリオの振り分けは platform 別の静的分配**(ワークスティールではない)。
     `ProfileRunner` は iOS デバイスが1台でもあれば既定 platform を `ios` にし、
     `RunOrchestrator` は `@TestClass` の `platform:` **未指定**シナリオをその既定 platform の
     キューにだけ入れる。自分の platform のキューが無いワーカーは1本も受け取らずに終わる。
     → **両OSのデバイスを供給する実行プロファイル(`all` 等)を使っても、platform 未指定の
     シナリオは片方の OS でしか走らない**(供給された他方のデバイスは空回り)。
     platform 非依存に書いたシナリオを両OSで回すなら `--profile ios` と `--profile android` を
     別々に実行する。シナリオ数や負荷には依存しない決定的な挙動(2026-07-22 実測)
6. `defaultTimeout` はランナーの `--default-timeout` → FTDriveCore に渡り、
   exist/textIs/valueIs の `timeout: Double? = nil` の既定値になる
7. ワーカー構築(供給+インストール)は ProfileWorkerFactory(FTAndroid)に共通化され、
   CLI(ProfileRunner)と `fleetest api run`(VSCode 拡張など UI 入口向けの共通経路)が共用する

### 11.5 インターフェース

- CLI: `fleetest run [--project P] [--profile 名] [--scenario ...]`(profile 未指定時は従来どおり
  手動 --ports/--serial)、`fleetest profile list`(解決結果と整合チェック)
- **GUI(SwiftUI 版 `fleetest-gui`)は 2026-07-10 に削除**。対話的 UI は VSCode 拡張
  (`vscode-fleetest/`)に一本化した。プロジェクト/実行プロファイルの選択はコマンドパレット
  (「fleetest: プロジェクトを選択」「fleetest: 実行プロファイルを選択」、`fleetest.project` /
  `fleetest.profile` 設定)、プロファイル JSON の編集・保存時検証は問題パネル(Diagnostics)で行う。
  **実行/デバッグ実行は `fleetest.profile` 未指定なら実行せず、デバイスタブでの指定を促す通知
  (「デバイスタブを開く」= `fleetest.showDeviceMonitor`)を出す**(未指定だとブリッジ自動供給の無い
  直接ポート接続に落ち、全シナリオが接続拒否で即失敗するため。ユーザー決定 2026-07-26。
  dry-run とライブ操作パネル連動は実デバイスを要さない/解決済みのため除外)
  内部的には CLI と同じ `fleetest api ...` サブコマンドを呼ぶため、解決ロジック(ProfileResolver 等)
  は CLI と共通(詳細は [vscode-fleetest/README.md](../vscode-fleetest/README.md))
- MCP: `ft_list_scenarios` / `ft_run_scenario` に `project` / `profile` 引数、`ft_list_projects` 追加。
  ft_run_scenario は 1 シナリオ実行なので profile からはシナリオの platform に合う先頭デバイス・
  heal・reportDir のみ利用

### 11.6 移行と後方互換

- 旧 `scenarios/` は `TestProjects/SampleApp/scenarios/` へ git mv(同一コミットでアトミック移行。
  レガシーレイアウトのランタイムサポートは持たない)
- ルート `reports/` の既存成果物は履歴として残置。旧 `.fleetest/heal-cache.json` も放置で無害
  (キー不一致なら FM が再ヒールするだけ)

---

## 12. デバイスモニターの画面配信と自己修復(2026-07-14)

### 12.1 画面配信は3段フォールバック

**H.264+WebCodecs(既定)→ MJPEG ストリーミング → スクリーンショットポーリング**の順に落ちる。

- **H.264 経路**: helper(`fleetest-simstream`=IOSurface→VTCompressionSession HWエンコード /
  `fleetest-androidstream`=screenrecord の H.264 をトランスコード無しでパススルー)が
  10バイトヘッダの v2 レコードを stdout へ → 拡張が Uint8Array のまま webview へ転送 →
  `VideoDecoder`(HWデコード)→ canvas。デコードは全チャンク(P フレーム連鎖のため)、
  canvas 描画のみ約 15fps に間引く。ワイヤ形式・ping の契約は
  `Sources/fleetest-simstream/main.m`・`fleetest-androidstream/main.m`・
  `vscode-fleetest/src/deviceStream.ts` の3ファイル同期(詳細はそのコメント)
- **フォールバック**: webview の `codecError`(WebCodecs 非対応/デコード失敗)でデバイス単位に
  MJPEG へ自動復帰(設定 `fleetest.streamCodec` で恒久切替も可)。ストリーミング自体の連続失敗は
  従来どおりポーリングへ(`onFailure`)。フォールバック状態はパネル単位のメモリ(開き直しでリセット)
- **monitor のスクショポーリング抑制**: タイルがストリーミング表示中のデバイスは、拡張が
  `suppressFrames`(stdin 制御)で monitor 側の生成ごと止める(受信後の間引きは競合吸収の
  安全弁として残置)。契約は `Sources/fleetest/ApiMonitorCommand.swift` 冒頭
- **壊れたレコードを webview へ流さない**: 長さ前置きのバイナリ列は helper が書き込み途中で死ぬと
  境界がズレ、以降**自力復帰せず**ゴミの寸法+非 JPEG を吐き続ける。v1 パーサは寸法・長さの足切りと
  JPEG SOI 照合で desync を検出し、未知 KIND と同じく helper を kill して張り直す
  (`deviceStream.ts` の `handleProtocolDesync`)。タイル側もヘッダ由来の寸法を信用せず
  **デコードできた画像の実寸だけ**でアスペクト比を決める(壊れたフレーム1枚でタイル幅が
  異常に広がったまま戻らない実害。2026-07-26)
- **実寸は `VideoFrame.close()` の前に控える**: close 後の VideoFrame は `displayWidth/Height` が
  0 を返す(WebCodecs 仕様の detach)。0 を弾く実装だったため H.264 タイルはアスペクト比を
  一度も採れず既定値(0.4615)のままだった(実害。2026-07-29)。以後は寸法が変わるたび
  `onDimensions` で枠へ反映する(初回だけだと解像度変更で古い比率が残る)
- **screenrecord のレターボックス補正(Android)**: screenrecord は**エンコーダ上限を超える画面を
  縮めた動画へレターボックス投影する**(黒帯が映像に焼き込まれるため、タイルは帯ごと表示する。
  実害: 1280x2856 の Pixel 10 Pro で左右に黒帯。1080x2424 では起きない)。`fleetest-androidstream` は
  起動時に 1 秒の `screenrecord --verbose` プローブ(出力先 `/dev/null`)で
  `Content area is <w>x<h> at offset x=<x> y=<y>` を読み、offset が 0 でないときだけ実内容の領域を
  `--size` に渡す。**プローブが返す領域はエンコーダが受け付けたサイズ以下**なので `--size` 明示で
  configure が落ちない(自前でサイズを推定すると拒否され得る。しかも `--size` 指定時の
  screenrecord は 1280x720 への自動フォールバックをせず即エラー終了する)。費用は約 1.2 秒/helper 起動

### 12.2 ブリッジ死の検知と自己修復

XCUITest ランナーは HTTP サーバだけ死んで xcodebuild 親が残ることがある(2026-07-14 実例)。

- **watchdog**(`vscode-fleetest/src/monitorBridgeWatchdog.ts`): 一度 connected になったデバイスが
  booted(実体は起動中・ブリッジ無応答)へ降格して連続5観測(約10秒)続いたら `device-up` を
  自動投入。実行レーン稼働中は保留・クールダウン3分・2回失敗で諦めて表示(`fleetest.autoRepairBridge`
  既定 ON)。タイルに出すのは諦めた後(failed)だけで、文言は実機「デバイス未接続」/仮想機
  「接続できません」(内部語ではなくユーザーの取れる行動が分かる語にする。fleetest 出力への
  誘導はホバーのツールチップへ退避。`deviceTiles.js` の `bridgeWatchLabel`)
- **残骸掃除**: `BridgeLauncher.startDetached` は起動前に同一ポートの xctestrun
  (`FleetestRunner-<port>.xctestrun`)を掴む旧 xcodebuild を kill する(他ポートはパス不一致で不干渉)

### 12.3 実測(M1 Max、詳細は performance-tuning.md §4.1)

- Android エミュレータは headless(-no-window)だと hw.gpu.mode=auto が SwiftShader(CPU描画)へ
  落ちるため **DeviceBooter は `-gpu host` で起動**(モーション時 qemu 約3コア→約1/3)。
  gfxstream+host Vulkan(MoltenVK)は `-gpu host` の時点で既定有効で、HWUI の Vulkan 化は
  効果なし(§6 不採用表)
- **ただし `-gpu host` が画面凍結(白フレーム固着)の根本原因**(headless + macOS 27 / emulator
  36.5.10。切り分け実測 2026-07-17。performance-tuning.md §7 参照)。swiftshader_indirect は免疫だが
  CPU 約3倍。そこで **基本 host・凍結が軽量修復で治らない個体だけ per-device で swiftshader_indirect
  再起動**にフォールバックする(§12.4 の watchdog ラダー)。`bootOne(gpuMode:)`→`startEmulator`、
  CLI は `fleetest api device-up --gpu swiftshader_indirect`。swangle_indirect は screencap 0B で不採用
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
  (契約は `vscode-fleetest/src/monitorDeviceModel.ts` 冒頭。拡張は未知の種別も再起動修復に倒す)。
  **`metal-errors` だけは拡張側で落とす**(表示も修復もしない。`monitorHealthWatchdog` の
  actionable フィルタ。ホスト GPU ドライバ由来で全機に同時に出る背景現象で個体の異常を表さない=
  タイルに出すのが不適切。フリート全数検証の実データは performance-tuning.md §7。
  Swift 側は記録・分析のため載せ続ける契約のまま)
- **watchdog**(`vscode-fleetest/src/monitorHealthWatchdog.ts`): 異常種別ごとに修復ラダーが分かれる。
  ライフサイクルキュー busy 中は保留(起動/停止処理との競合回避)。テスト実行中は保留しない
  (ユーザー決定 2026-07-17: 凍結は実行完了を待たず即修復。実行中の該当デバイスは再起動で落ちるが
  凍結済みで証跡が撮れないため許容)。設定 `fleetest.autoRepairDeviceHealth` は
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
- **ブロードキャスト実行**(`fleetest run --broadcast`。2026-08-22): 選んだシナリオを実行プロファイルの
  **各デバイスで1回ずつ**回す(warmup 向け。受け手が `--device` を台数ぶん外部ループで撃っていたのを
  run 基盤に載せた)。**差し替えるのは分配だけ** —— `ScenarioDispatch.broadcast` で `RunOrchestrator.run`
  が platform 別の共有キューの代わりに**レーン(デバイス論理名)別のキュー**を作り(`BroadcastPlan` =
  純粋関数。platform 未指定のシナリオは全レーンへ・明示は同 platform のレーンだけ)、ワーカーは
  `BroadcastPlan.laneKey(of:)`(= `logicalName`。復帰でポートが変わっても同じ台は同じキューに戻る)で
  自分のキューを取る。供給・インストール・フック(run で1回)・スタッガ・CPU 門・復帰・lease・録画・
  レポートは同じ経路。`ProfileRunner` は **`limitingDevices` を通さない**(各台で回すのが目的)。
  `ScenarioRunItem` は `lane` を持ち **URL に `?lane=` を付けて (シナリオ × デバイス) を別キー**にする
  (表示バッファ・稼働集計・requeue 回数は URL で持つ。`lastPathComponent` は ID のまま)。
  結果は台ごとに `worker` で区別(同じ ID が `~N` 連番で並ぶ)。**`RunRecorder.discardLast` は worker を
  名指しする**(同じ ID を別の台が同時に書いているので、「この ID の最新」では別の台の記録を消す。
  欠番は詰めない)。参加しなかった台のぶんは「device … never joined the run」、離脱して復帰できなかった
  台のぶんは「… dropped out and could not be revived」で失敗として残す(準備できなかった台が緑に紛れない)。
  ホスト混在プロファイルは `DeviceMachineRunner` が**分割せず全ホストへ全件**を渡し、`--host` は
  `RemoteRunArgs.build` が中継する。`--fleet` とは併用不可(中継していないので黙って分配になる)。
  `api run`(拡張)には載せていない(Test Explorer は flowURL = シナリオ1項目の前提)
- **実行中の凍結による結果取り消し+別デバイス再実行**(`RunOrchestrator.runWorker`。2026-07-17):
  シナリオが失敗した直後にそのワーカーの Android デバイスを `isDeviceFrozen`(注入プローブ=
  `AndroidHealthProbe.isPersistentlyBlank`。FTCore→FTAndroid は循環のため呼び出し側=fleetest ターゲットが注入。
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
    カウンタリセット)。凍結/消失判定はこのブレーカの前段(既知の即離脱)、ブレーカは後段の保険。
    **離脱には証拠が要る**(2026-08-24。`FTCore.WorkerCircuitBreaker`): 離脱するのは**この streak の間に
    別のレーンが1本でも通ったとき**だけ。誰も通っていない = 全レーンが同時に落ちている = 台ではなく run の
    問題なので、レーンを残して走り続ける(`workerAnomalies` に `circuitHeld` を streak ごとに1件・
    ログに1行)。受け手報告(2026-08-23): 外部サイト停止の時間帯に condition の not-found で全レーンが
    連続失敗 → 全部離脱 → 再投入 → revive 上限 → 39 本中 34 本失敗・多数が `no usable workers` で未実行。
    **condition 段階の失敗を数えない案は却下**(不良な台は launch / 最初のステップ = condition で落ちる
    ので、守るべき形を見なくなる)。**閾値のプロファイル化だけも却下**(障害の時間帯は予測できないので
    常時高く = 保護を捨てる)。単レーンの run は連続失敗だけでは離脱しなくなる(プローブは別に効く)。
    陽性対照: 全部落ちる6本を2レーンで回し、両レーンとも held・離脱なし・6本すべて実行を確認(2026-08-24)
  - **凍結だけでなく「実行中のデバイス消失」も振り分け対象**(2026-07-18): watchdog の実行中再起動や
    エミュレータのクラッシュで adb からデバイスが消える(`device offline`→`not found`)と、runner の
    固定ワーカーは以降のシナリオを全部即失敗させる(実測: 1台消失で11件連鎖失敗)。これを拾うため
    `.failed` 時に `isDeviceUnreachable`(注入=`AndroidDeviceCatalog.connectedSerials` に serial が居ないか。
    取得失敗時は誤振り分け回避で false)を **凍結プローブより先に**確認し、消失していれば同じ
    discard+requeue+離脱へ流す(理由表示「デバイス消失(offline/未検出)」)。`isDeviceFrozen`/`isDeviceUnreachable`
    の注入は `ProfileRunner`・`ApiRunCommand` の両並列経路で行う
- **劣化ワーカーの可視化**(`RunSummary.degradedWorkers`。2026-07-18): 連鎖失敗が結果 JSON を掘るまで見えなかった
  問題への観測性。RunOrchestrator が離脱(凍結/消失/連続失敗/接続不能)を `NoteCollector`(`degraded`)で集約し
  `RunSummary.degradedWorkers`(「label: 理由」)に載せる。`RunRecorder.finish` 経由で run.json の `degradedWorkers`
  に永続化(空は nil 省略)し、CLI(ProfileRunner の print / ApiRunCommand の logStderr)にも末尾サマリを出す
- **動的ワーカープール(復帰デバイスの再参加)**(`RunOrchestrator.superviseWorker`。2026-07-18): 従来ワーカー集合は
  実行開始時固定で、離脱したデバイスは監視側が再起動しても同一実行に戻れなかった(構造的限界)。`runWorker` の戻り値を
  `WorkerExit{completed/retired}` にし、離脱時は `superviseWorker` が同じタスクスロット内で `reviveWorker`(注入クロージャ=
  fleetest 側が `ProfileWorkerFactory.buildWorker(forLogicalName:)` を `REVIVE_TIMEOUT`=90s・5s 間隔でポーリング+アプリ再導入)を
  呼び、復帰できたら新ワーカーでキュー消化を再開。`MAX_WORKER_REVIVES`=2・`ScenarioQueue.hasItems()` ガードで暴走と
  無駄な再供給を防ぐ。動的タスク追加はせず withTaskGroup 構造は不変(=安全)。FTCore→FTAndroid 循環回避のため
  再供給は注入(既存 isDeviceFrozen 等と同じ)。**注**: 実行開始時の接続失敗も retired 扱いのため、開始時から不在の
  デバイスは最大 MAX_WORKER_REVIVES×REVIVE_TIMEOUT 分ポーリングする(他ワーカーと並行なので run はブロックしない)
- **個別デバイス操作の2台並行**(`monitorDeviceLifecycle.ts` のスケジューラ。2026-07-18): 右クリック起動/停止の
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
  `fleetest api devices-up --restart A --restart B` とし、**DeviceBooter.bootAll の単一キュー**に
  再起動アイテム(先頭。起動済みでもスキップせず shutdownOne→bootOne[host GPU])と通常ブート
  アイテム(restart 対象は除外=同一機の二重処理防止)を混載、既存の2ワーカーが消化する。
  NDJSON に `deviceStopping`(--restart 機の down 開始)を追加(検証: monitorModel.ts
  `isDevicesUpEvent`。受信時にそのデバイスだけ stopDeviceStreams)。cpuRenderNames の解除は
  `MonitorDeviceOps.bulkUpWithRestarts`。右クリック単発「GPUで再起動」は従来どおり
  `restartBatch` ジョブ(`fleetest api devices-restart`、`isDevicesRestartEvent`)を使う
- **一括 down の per-device 反映(`api devices-down`)**(2026-07-19): monitor は down 中 pause で
  状態スキャンごと止まる(→タイルが全台落ちてからまとめて「未起動」化していた)。対策として **profile 指定の
  bulk down を NDJSON 化**(`deviceStopping`/`deviceFinished`。停止ロジックは `shutdownProfile` と同一で回帰なし)、
  拡張は `deviceFinished` ごとにそのタイルだけ offline を先行反映(`deviceDownFinished` → resume 後に本物の
  state で上書き)。profile 無しの down は従来の全掃討 `devices down` のまま。詳細は performance-tuning.md §3.4
- **「プロセス」タブ(常駐プロセス一覧・停止)**(2026-07-19): `ps` の fleetest 関連常駐を分類表示
  (`residentProcesses.ts`)。Android ブリッジは**エミュレータ内 `am instrument`= ホスト `ps` に出ない**ため
  `adb forward --list` から情報行を合成(ホスト PID 無し→PID 列は `(遅延起動)`/デバイス内 PID `(12345)`)。
  停止ボタンは「プロセスを終了してタブを閉じる」の1つ(2026-08-19 に「すべて強制終了」を廃止して
  置き換え)。掃討スコープは**ユーザー決定**で: ① iOS ブリッジ/ランナー・in-app・モニター/
  host-metrics/stream を停止し **iOS シミュレータと Android エミュ本体(qemu)は残す**(デバイスタブの領域。
  `bridge down --all`=sim を残す/`bridge down --platform android`=qemu を残す/残余 SIGKILL は
  **この workspace 由来のみ**=workspaceRoot/binaryDir を含むコマンド。machine-wide 巻き込み回避)、
  ② **MCP サーバ(mcp)は表示・掃討とも対象外**(セッション保護)、③ 掃討後は**再起動せず
  モニターパネルを閉じる**(モニターを止めたままタブを開いておくとデバイスタブが状態更新を失い
  凍結するため、「止める=閉じる」を1操作にする。再開はパネルを開き直すだけ)

- **監視と実行の協調(run-lease)**(2026-07-18): monitor(watchdog)と run は別プロセスで無協調のため、
  watchdog が実行中デバイスに破壊的再起動をかけて run のワーカーを壊していた。対策として run→monitor 方向の
  lease を追加(`Sources/FTBridgeClient/RunLease.swift`。`run-<key>.lease`)。`fleetest api run`
  (RunOrchestrator)がワーカー担当デバイス(serial/udid)へ 5s ハートビートで write、離脱・完了時に remove
  (FTCore→FTBridgeClient は循環のため `writeRunLease`/`removeRunLease` クロージャ注入。`RunLeaseKeys` actor で
  管理)。`fleetest api monitor` が `RunLease.isFresh` を読んでデバイスイベントに `inRun` を載せ、拡張の
  `monitorHealthWatchdog` が **clock-skew 等の host 再起動分岐のみ inRun 中は保留**(restartAttempts/cooldown を
  動かさず見送る)。**blank-screen(CPU フォールバック再起動)と wifi 修復は inRun でも実行**(凍結はデータ汚染で
  即対応が要件、wifi は非破壊)。凍結で run のワーカーが壊れる分は §12.4 の requeue が回復する

### 12.5 タイルペインの auto-fit と「非表示中は実測しない」規律(2026-07-30/31)

タイルが1行(`.grid` は `flex-wrap:nowrap`)で横スクロールせずちょうど収まる高さへ、
セパレーターを自動で置く(ツールバー右端のトグル・既定 ON。手動ドラッグは OFF ではなく
**一時停止**で、台数が変わると自動で再開する)。

- **量の連鎖**: ペイン高さ → タイル高さ → `--tile-image-h`(= タイル実測高 − 固定 chrome 66px。
  `deviceTiles.js` の `relayoutTiles`)→ タイル幅(`--tile-image-h × --tile-aspect`)。
  幅は画像高さに比例するので、**収まる高さは1回の差分計算で出せる**
  (`paneHeight + (収まる画像高 − 現在の画像高)`。`tileFitModel.js`)。padding/border/gap の定数は
  持たず全て実測して渡す(style.css を変えたとき片方だけ古くなるのを防ぐ)
- **前提**: 差分計算は「**今のペイン高さ ↔ 今の `--tile-image-h` が対応している**」ことに依存する。
  この対応が崩れると、崩れた差のぶんだけ高さが増減して二度と収まらない
- **罠(実害 2026-07-31)**: `devices` のポーリングは「デバイス」タブが**非表示の間も届き続ける**
  (タブ非表示で止まるのはフレーム配信だけ。`devicesTabVisible`)。`applyDevices` は毎回
  `relayoutTiles` を呼ぶため、`display:none` 中は `clientHeight=0` → `--tile-image-h` が下限 60px に
  潰れて書き込まれ、上の対応が壊れていた。**タブへ戻ると実際の画像高さぶん過大**になりタイルが
  はみ出す(初回表示だけ正しく、他タブを経由すると必ず崩れる)。対策は
  **レイアウトが無いとき(`clientHeight===0`)は書かずに抜ける** — 非表示中は直前の正しい値が保たれる。
  同じ理由で `splitter.js` の高さ反映も `splitAreaHidden()` で抜け、タブ復帰時に
  `switchTab` → `reapplyTilePaneHeight` が測り直す
- **一般化**: **webview は非表示中もメッセージを受け続ける**。ハンドラからレイアウト実測値
  (`clientHeight`/`getBoundingClientRect`)を**書き込む**処理は、表示中でないことを確認してから行う
  (読むだけなら 0 が返って無害だが、書くと次に表示されたときまで嘘が残る)

## 13. 実行の相乗りガードと launch 事前検査(2026-07-16)

デモ凍結事故(ライブモニター稼働中のシムへ外部 run が相乗り→ launch ハング→ 60s watchdog で
ランナー死→ストリーム凍結)の再発防止として2つのガードを入れた。**うち占有ガードは後に撤去した**(13.1)。

### 13.1 MonitorLease(占有ガード、B1)は撤去済み(2026-07-24)

「モニターが見ているデバイスへの外部 run を lease で拒否する」占有ガードを一度入れたが、
**テスト実行をモニターより優先する**方針(ユーザー決定)により全廃した。
`MonitorLease` の実装も `.fleetest/monitor-*.lease` も現在は**存在しない**。
モニターは受動ビューアで、run に割り込まれても respawn で復帰する。**再提案しない**。

run → monitor 方向の `RunLease`(§12 の「監視と実行の協調」)は別物で**現役**
(watchdog が実行中デバイスを破壊的に再起動するのを抑える)。混同しないこと。

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

シナリオ実行結果を git 管理下の `TestProjects/<name>/results/` に蓄積し、分散チーム(複数マシン・
複数ブランチ)の結果をコミット・マージで合流させる。サーバ DB は使わない。

### 14.1 マージ安全性(設計の核)

**1 run = 1 ディレクトリ、1 シナリオ実行 = 1 ファイルの追加専用レイアウト**。
runID = `<yyyyMMdd-HHmmss(UTC)>Z-<マシン名>-<乱数4hex>` をディレクトリ名にするため、
異なるマシン・異なる実行は必ず別パスに書き、git 上は常に純粋な追加になる
(同一秒・同一マシンの二重起動は乱数 4hex で分離)。JSONL 追記型は同一ファイルへの
複数ブランチ追記で必ず衝突するため不採用。

検証済み(2026-07-17): 2 ブランチで同一シナリオ集合を同時刻に実行→マージで、
コンフリクトゼロ・全 run が合流・`fleetest results list` が統合結果を返すことを確認。

- レイアウト: `results/runs/<YYYY-MM>/<runID>/run.json + scenarios/<シナリオID>.json`
  (月別シャーディングで走査範囲を限定。間引きは月ディレクトリごと git rm)
- run.json のみ実行完了時に同一プロセスが 1 回上書き(finishedAt・集計)。finishedAt 欠落=
  未完了 run(クラッシュ検出に利用)。scenarios/ は追加専用(同一 run 内の再実行は `~2` 連番)
- スキーマ詳細・フィールド一覧は **docs/results-json.md**(唯一の定義元。DTO は `RunRecord.swift`)。
  **`results/` は .gitignore なので、その中に置いた README は受け手に届かない**
  (2026-08-20 まで design.md はそこを指していた)。ドキュメントは docs/ に置く
- **自動クローズの抑止は `StepExecutor.handlersSuppressed` の1箇所で判定する**(2026-08-21)。
  ブロック形(`handlerSuppressionDepth`)と命令形(`handlersDisabled`)を**別に持つ**のは、
  ブロック形が**1つの CAE ブロックの内側にしか置けない**ため —— 「`condition` で止めて
  `expectation` で戻す」は命令形でしか書けない。`enableHandler()` はブロック形を解除しない
  (ブロックは出口で必ず戻るので、内側から外すと入れ子の意味が壊れる)
- **宣言された割り込みを閉じるのは `StepExecutor.dismissInterruption` の1箇所**(2026-08-20)。
  `perform` を通らない条件判定(`ifCanSelect` / `repeatWhileCanSelect` = `FTDriveCore.canSelect`)は
  `dismissDeclaredInterruption(in:)` から**同じ実装**を呼ぶ。**2つ目の実装を書かない** ——
  判定が割れると「操作は閉じるのに条件判定は閉じない」という、失敗ではなく**誤った経路**として
  現れる形になる(受け手が実際に踏んだ)。条件判定は**1回を1ステップとして数え直す**
  (`beginInterruptionScope`)—— 直前のステップが上限まで閉じていると1回も閉じられない
- **失敗の素性は事実だけ**(2026-08-20): `failedSteps` に `section`(フェーズ)・`command`・
  `failureKind`(`StepFailureKind`)・`notes` を載せ、run.json に `workerAnomalies` を載せる。
  **「環境要因の失敗」の分類は置かない** —— アプリが重いのかマシンが混んでいるのかツールには
  区別できず、推測を混ぜると誤った緑・誤った赤を作る(受け手の方針。仕分けは読み手が行う)。
  `command` は**説明文から切り出さない**(group の前置・注記の括弧書きが付くので、書式を
  変えた瞬間に静かに壊れる)。渡し忘れはコンパイルも実行も通るので
  `CommandNamePlumbingTests` がソース走査で落とす

### 14.2 記録パス

全実行経路(api run 直列/プロファイル/並列、fleetest run 直列/並列/ProfileRunner)は
`ScenarioHost.run` に合流するため、レコード生成フックはそこ 1 点
(`ScenarioEvent` 列を `ScenarioRecordBuilder` で畳み込み)。run 単位のメタ(runID・プロファイル・
trigger)は CLI エントリでしか分からないため、`RunRecorder` を CLI エントリで生成して注入する。

- 実装: `Sources/FTCore/RunRecord.swift`(DTO+Builder)/ `RunResultsStore.swift`(I/O・月別走査)/
  `RunRecorder.swift`(発番・NSLock 直列化)。書き込みは全て best-effort(実行を止めない)
- dry-run・debug 実行は記録しない(last-results と同判断)。fleetest-scenarios 直叩き・MCP 経路は対象外
- レコード粒度: 成否・所要時間・worker・scene 別合否は常時、ステップ詳細・fixSuggestions・
  errorLogs(インフラ失敗の切り分け用)は失敗時のみ。スクリーンショットは含めない
  (reports/ への相対パス参照のみ。reports/ は gitignore のまま)

### 14.3 分析

- 集計は `Sources/FTCore/RunResultsQuery.swift` の純関数に集約(閾値定数も同ファイル冒頭)。
  CLI(`fleetest results list/summary/flaky/trend/devices/slow/insights`)と
  拡張向け `fleetest api results`(1 行 JSON)の両方がこれを使う
- ダッシュボード: `vscode-fleetest/src/dashboardPanel.ts` + `src/webview/dashboard/`。
  ペイロード契約は `ApiResultsCommand.swift` ⇔ `dashboardModel.ts` で同期
- スキーマ進化: 全ファイルに schemaVersion。フィールド追加は Optional でバージョン据え置き、
  読み側は自分より新しい version をスキップ。既存ファイルの書き換えマイグレーションは
  しない(git 履歴とマージ安全性を壊すため)
- インデックス/キャッシュは未導入(月別プルーニング+全走査で当面十分。遅くなったら
  `.fleetest/` 配下に再構築可能キャッシュを足す)

## 15. 外部パッケージ配布と mint 配布の履歴(2026-07-19・07-20 外部構成を既定化)

**現状(正典)**: onboarding の既定は**外部パッケージ構成**(受け手ディレクトリを `fleetest init` で
テストパッケージ化し、Projects は受け手側に住む。foundation-tester は横に clone した「ツール」=
TOOL_ROOT)。clone 構成(クローンの中で直接シナリオを管理)は保守者/PoC 向け。入口は **Claude Code
プラグイン**(ターミナルで `claude plugin marketplace add wave1008/foundation-tester` →
`claude plugin install fleetest@foundation-tester --scope user`。受け手は VSCode の Claude Code 拡張前提で、
拡張パネルでは /plugin スラッシュコマンドが使えないため CLI 形式が正。
スキルはマーケットプレイス経由で自動更新)。フォールバックは curl ワンライナー
(`Scripts/install-skill.sh` がスキルを .claude/skills/ へコピー。自動更新なし。
`--dir` で他のエージェントのスキル置き場へも入る)→ いずれも
`/fleetest-setup`(プラグインでは `/fleetest:fleetest-setup`)が構成を自動判定し、受け手ディレクトリは
外部構成へ分岐、クローン内は clone 構成。CLI・VSCode 拡張とも TOOL_ROOT の clone から `swift build` /
`npm run install-local` でビルドする(バイナリ配布はしない)。mint は廃止(VSIX はバイナリ配布しないため
clone がどのみち必須で、CLI だけ mint 経由にすると二重取得になるだけだったため)。

**配布アダプタの方針(2026-08-27。インストーラが面倒を見るのは Claude Code だけ)**: 導入
runbook の正典は `.claude/skills/<name>/SKILL.md`(ツール中立の markdown 手順書。特定エージェント
専用機能に依存させない)。Claude Code へは**規約位置から正典を参照するだけの薄いアダプタ**を置き、
**runbook 本体は複製しない**:

| | Claude Code |
|---|---|
| プラグイン manifest | `.claude-plugin/plugin.json` |
| マーケットプレイス manifest | `.claude-plugin/marketplace.json` |
| リポジトリ内のスキル発見 | `.claude/skills/`(正典の実体) |
| スキルの呼び出し | `/fleetest-setup` |
| 入口ファイル | `CLAUDE.md` |
| MCP 登録 | `.mcp.json`(プロジェクト) |
| プラグイン導入 | `claude plugin marketplace add` → `plugin install --scope user` |
| プラグイン更新 | `marketplace update` → `plugin update` |
| プラグインの版照合 | `claude plugin list` の `Version:`(= git sha) |
| コマンド単位の承認 allowlist | `.claude/settings.json` |

**他のエージェント(Codex・Cline・Cursor 等)には配布アダプタを置かない**(2026-08-27 に Codex の
アダプタ一式を撤去)。中核はどれもエージェント固有ではない —— 機械作業はインストーラ、`ft_*` は
標準の stdio MCP サーバ、runbook はツール中立の markdown。**エージェントごとに面倒を見ると、
規約位置・プラグインのサブコマンド名・版照合の方法・設定ファイルの書式が全部そのエージェント
固有の分岐になり、増やすたびに4箇所(Swift・install.sh・install-skill.sh・update.sh)へ手で
写す**ことになる。案内は docs/user-docs/tools/other_agents.md に集約し、コードは
Claude Code の1系統だけを持つ。**受け手のグローバル設定(`~/.codex/config.toml` 等)には
1バイトも書かない** —— セキュリティ境界であり、TOML は同じテーブルの重複でファイル全体が
無効になるので、素朴な追記は受け手の設定を壊す。

**repo ルートに `skills` を置いてはいけない**(2026-08-27 実測で撤去)。プラグイン root =
repo ルートのとき、**Claude Code は `.claude-plugin/plugin.json` の明示パスと既定の `skills/` の
両方を読む**(置換ではなく加算。以前は「source が `./` なら明示パスが既定を置換する」という
前提で書いていたが誤り)。`skills → .claude/skills` を置いていた間、
**6本のスキルが12本として登録され常時コストが倍**になっていた(~1,270 → ~2,537 tok)。
数え方は `claude plugin details fleetest@foundation-tester` の Component inventory。
`agentAdapters.test.mjs` がルートの `skills` の不在を固定する。

規約位置の唯一の定義元は `Sources/FTCore/AgentIntegration.swift`。**シェル(install.sh /
install-skill.sh)は clone 前・ビルド前に走るので Swift を呼べず、同じ規則を手で持つ** ——
`vscode-fleetest/test/agentIntegration.test.mjs` が両者のドリフトを落とし、
「インストーラが他エージェントの規約位置・設定へ書かない」ことも同じテストが固定する。
`agentAdapters.test.mjs` は「アダプタが正典に届くこと」を落とす。
**正典を移してシンボリックリンクにしない** —— raw.githubusercontent はリンクを**本文でなく
リンク先の文字列**として返すので、`install-skill.sh` の curl が SKILL.md ではなく1行のパスを掴む。

**Codex を使う受け手への案内(コードは持たない)**: サンドボックスに**縛られるのはシェル
コマンドだけで、MCP サーバはその外で動く**(2026-08-27 実測: `--sandbox read-only` でも MCP
プロセスはワークスペース外書込と loopback が通る)。したがって **`ft_*` 経由の作成・実行・
デバイス駆動は既定設定のまま動き**、通らないのは**シェル経由の導入・更新**だけ。原因は権限では
ない2つ: **①SwiftPM が自前の `sandbox-exec` を入れ子に使うため `swift build` / `swift package` が
`sandbox_apply: Operation not permitted` で起動できない ②`xcrun simctl` が CoreSimulatorService への
mach 接続を塞がれる**(`adb` は TCP 5037 なので network_access で通る)。
**`network_access` / `writable_roots` を積んでも直らない**ので、それらを根拠に「OK」と言うと
false green になる(以前 install.sh のステップ7.7 が実際に出していた)。

**ローカル検証の罠**: `/plugin` は VSCode 拡張パネルでは使えない(ターミナル CLI かデスクトップアプリ)。
`claude plugin marketplace add <ローカルパス>` は git clone ではなく**作業ツリーを丸ごとコピー**する
(gitignore を無視するため `.build/` 約8GB も入りキャッシュが約13GBに膨れる)。検証後は
`claude plugin uninstall fleetest@foundation-tester` + `claude plugin marketplace remove foundation-tester`
で登録を外し、**キャッシュ実体は remove 後も残る**(実測)ので
`~/.claude/plugins/cache/foundation-tester` を手動削除する。GitHub 経由の本番導入は git clone なので
生成物は含まれない。
以下は外部パッケージ構成(`fleetest init`)の実装詳細。

受け手が foundation-tester を clone せず、**自分の Swift パッケージが fleetest を SPM 依存として引いて**
自分のアプリのシナリオを書ける構成(以下「外部パッケージ構成」)。clone してその中でシナリオを管理する構成を「clone 構成」と呼ぶ。

- **公開 products**: `Package.swift` の `products:` に `.library`(FTScenarioRunner / FTDSL / FTCore)と
  `.executable`(fleetest)。受け手のシナリオターゲットはこれを `.product(package: "foundation-tester")` で引く。
- **`fleetest init`**: 受け手の Package.swift(空マーカー区間 + swift5Mode + fleetest 依存)を書き、
  `ProjectScaffold.createAndRegister` が最初のプロジェクトを登録。内外は `isExternalPackage`
  (`Sources/FTScenarioRunner` の有無)で自動判定し、`PackageManifestEditor` が内部=target 参照 /
  外部=`.product` 参照のスタンザを生成する(`project sync` も同じ判定)。
- **repoRoot の二役分離**: シナリオビルドは `ScenarioHost.packageRoot()`(= 受け手パッケージ。Package.swift
  のみ上方探索。`FT_PACKAGE_ROOT` で明示指定可)。ブリッジ資産(`Runner/`・`InAppBridge/`)は
  `RepoRoot.find()`。後者の解決順は ⓪ `FT_TOOL_ROOT`(明示指定。無効なら探索へ落とさず失敗)
  ① 実行ディレクトリ上方の Package.swift+Runner/(clone 構成)② 受け手パッケージの `.build/checkouts/*/Runner/`
  (外部パッケージ構成の git 依存。swift build が展開・CLI の導入方法に依らず永続)③ 実行中バイナリの位置
  (`<TOOL_ROOT>/.build/debug/fleetest-mcp` 等。cwd が受け手パッケージに固定される MCP・path 依存で
  checkouts が無い構成はここ)④ `#filePath` からのツールソース(自前ビルド)。
  **受け手パッケージのルートを渡してはいけない**(実害: MCP の profile 経路が `packageRoot()` を
  BridgeProvisioner へ渡しており、外部パッケージ構成で `InAppBridge/build.sh` が無く全 `ft_*` が
  失敗した)。両ルートの解決結果は `fleetest doctor --roots-only`(FM 判定に依存しない独立ゲート・
  ツール本体を解決できなければ exit 1)と `fleetest doctor` が表示する。
- **mint 配布(採用していたが廃止)**: `mint install wave1008/foundation-tester@<ver>`。**罠(記録)**: mint は
  temp でビルドしてバイナリのみ残しソースを消すため CLI の `#filePath` は死ぬ → ブリッジは上記②(受け手の
  checkout)で解決する必要があった。よって外部パッケージ構成は **git 依存必須**(ブリッジ用に Runner/ を含む
  checkout が要る)。ソース無し mint バイナリで bridge up→/status ready を実機実証済みだったが、CLI/VSIX の
  二重取得の無駄から mint 自体を廃止(現状は上記「正典」参照)。**制約(継続)**: XCUITest ブリッジは SPM
  ライブラリ化できないため「ソースビルド配布」前提(prebuilt をソースの無い別マシンへ運ぶと Runner/ 解決不能)。
- **拡張**: `binaryPath` は実在しなければ PATH フォールバック(`binaryPathResolve.ts`)で外部パッケージ構成の
  CLI(自前ビルドの PATH 登録先)を発見する。
- **版**: git タグ(履歴の目印)/ 拡張 package.json / プロトコル版(compatCheck)は独立。リリースは
  `Scripts/release.sh`(docs/releasing.md)。**受け手の配布口は `main` の1本**で、版を固定する導線は
  案内しない —— `#<tag>` でプラグインを固定してもスキルが引く install.sh と初回 clone は `main` のままで、
  ピンとして機能していなかった。`FLEETEST_REF` は保守者のブランチ検証口として残す(位置づけの
  書き換えだけで、install.sh の detached ガードと `update-check.sh` の `pinned` verdict は残してある ——
  受け手が自分で `git checkout <tag>` した clone を勝手に動かさないため)。

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
`fleetest api repair-display`(`ApiRepairDisplayCommand`)へ委譲する(以前は `emulatorGrpc.ts` +
`emulatorEndpoints.ts` に proto コピー・ディスカバリ・blank 判定の第二実装があり、閾値と手順を
言語間で同期する必要があった)。proto は `third_party/emulator-proto/`(vendored・再生成手順は
同 README。Swift スタブは生成物をコミット)。

### 16.2 置き換え済みの操作と残存 adb

- gRPC 化済み: blank プローブ/sleep-wake 修復(AndroidHealthProbe)・停止=setVmState SHUTDOWN
  (DeviceBooter/DataWiper/DevicesCommand)・serial→AVD 名=ディスカバリ読み・bootCompleted
  (booted=true のみ確定、他は getprop 再確認)・難治型 reboot の adb 不達時 RESET・
  drag・press のタッチ合成(AndroidDriver)
- adb 残存(原理的に置き換え不可): ブリッジ到達の `adb forward`+localhost HTTP・shell 系
  (am/pm/settings/getprop/cmd wifi/dumpsys)・install・pull・実機の全操作
- **キー系は adb keyevent 固定**(home/back/appSwitcher/pressEnter)。gRPC のキー注入は
  §16.3 のとおり届かない(2026-07-25 の PoC が測ったのは送出 1.2ms vs 215ms = 往復の速さで、
  効いたかではない)

### 16.3 罠(実測で確定・変更時に踏み直さないこと)

- **キー注入(sendKey)は guest に入力デバイスがあるキーしか届かない。無いキーは RPC だけ成功して
  黙って捨てられる**(2026-08-19。emulator 36.5.10 / API 36 arm64 の 2 AVD で確認: 名前付きキー
  "GoHome"/"AppSwitch" は成功を返すのに前面が変わらず、`adb shell input keyevent` なら戻る。
  送出中の `getevent` は1イベントも受けず、guest の入力デバイスは **gpio-keys と
  virtio_input_multi_touch だけ**でキーボードが無い)。**キー系は adb keyevent 固定**にしてある
  (`AndroidDriver` の home/back/appSwitcher/pressEnter。名前付きキーの API は両層とも置いていない)。
  gpio-keys に載る **KEY_POWER(116)/KEY_SLEEP(142)** だけは届くので sleep-wake 修復は gRPC のまま。
  KEY_WAKEUP(143) の不発(2026-07-25 実測)も同じ機序。sleep は KEY_SLEEP(非トグル)→直後の
  POWER トグルは安全
- **blank 判定に gRPC PNG のサイズ閾値を使わない**(emulator エンコーダは一様黒でも 51KB。
  30KB 閾値は adb 較正)。gRPC 経路は ImageIO デコード+`uniformFrame` の画素一様判定
- **grpc-swift は約10MB の単一メッセージ受信で接続切断される**(RGBA 直取り不可。PNG で受けて
  ホスト側デコードにしている理由)
- grpc-swift v2 の正リポジトリは **grpc/grpc-swift-2.git**(grpc-swift.git の 2.x タグは旧系)

### 16.4 iOS 側の相当実装: simctl→CoreSimulator 直叩き(2026-07-25)

iOS には emulator gRPC に相当する公開 RPC が無いため、同型の勝ち筋は **simctl のプロセス起動固定費の
排除**。`FTCoreSimShim`(ObjC・dlopen+objc_msgSend、fleetest-simstream と同作法)が
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

**適用範囲は列挙だけではない**(2026-08-02 拡張)。シナリオ毎に1回走る simctl 往復2つも
同じ作法で置き換えた(`CoreSimAppControl` が振り分け。殺しスイッチは同じ `FT_SIMULATOR_CONTROL=simctl`):

| 置き換え | 旧 | 新(CoreSimulator) |
|---|---|---|
| アプリ起動 | `simctl launch --terminate-running-process` | `launchApplicationWithID:options:error:` |
| 未インストール検査 | `simctl get_app_container` | `applicationIsInstalled:type:error:` |

- **launch の環境変数は接頭辞が違う**。simctl は `SIMCTL_CHILD_` を剥がして子へ渡すが、
  CoreSimulator の `options["environment"]` は**接頭辞なし**で渡す。剥がし忘れると
  in-app の dylib が注入されずブリッジが上がらない(`InAppLauncher` は接頭辞なしで持ち、
  simctl フォールバック側だけ前置する)
- **未インストールの断定は `NSPOSIXErrorDomain` code 3 のときだけ**。この API は
  「入っていない」も「判定できない」も `NO` を返すので、他のエラーは nil = 判定不能にして
  simctl の判定へ委ねる(誤って `appNotInstalled` で run を止めない側へ倒す)
- **律速は初期化に移った**。CoreSimulator の初期化は**プロセスごとに約 384ms**で、以降は 0〜1ms。
  **シナリオ1本=1プロセス**なので、最初に触った呼び出しが必ずこれを被る(性能の内訳と
  暖機を不採用にした理由は performance-tuning.md §3.12)

## 木はどこから来るか(WebView / ブラウザの一覧)

**軸は2つ**(対象 × エンジン)。ここが唯一の一覧で、以下の節はその詳細。

| 対象 | エンジン | 木の出どころ | 殺しスイッチ |
|---|---|---|---|
| 自作アプリの WebView | Android の a11y ブリッジ | **DOM**(CDP。`webView` ノードがある画面だけ) | `FT_WEBVIEW_DOM=off` |
| 自作アプリの WebView | iOS **in-app** | **DOM**(`InAppWebViewDOM`) | `FT_WEBVIEW_DOM=off` |
| 自作アプリの WebView | iOS **xcuitest** | **a11y** | — |
| **ブラウザ**(Safari / Chrome) | ホスト側 | **a11y。足りないときだけ DOM** | `FT_BROWSER_DOM=off` |

**スイッチは2つで意味が割れている**: `FT_WEBVIEW_DOM` = 自作アプリの WebView(OS 共通)/
`FT_BROWSER_DOM` = ブラウザ本体(OS 共通)。**1つに束ねない** —— 束ねると
「ブラウザだけ止めて A/B」が取れない。

**iOS in-app が DOM なのは別の事情**: あちらは in-app エンジンから WKWebView の a11y ツリーが
そもそも見えない(別プロセス提供)。

**Android の自作アプリが DOM なのは版差**(2026-08-15。詳細は次節「Android の自作アプリも
DOM から読む」)。一度は「a11y で読めるなら +147ms を払う理由が無い」として撤回したが、
**読めることと、どの端末でも同じ属性で読めることは別**だった。

**どちらの木を見ているかの判別**: 要素の `web: true` が DOM 由来の印。ブラウザなのに
DOM 由来が1件も無ければ `browserA11yFallbackNote` が「a11y から来ている」と言う
(2026-08-14 の監査 ⒝。**粒度と命名を揃えたので中身では見分けられない**)。

**Android の自作アプリで DOM が読めなかったときは黙らない**(2026-09-03): `route` が `.appWebView`
なのに `AndroidWebViewDOM.read` が nil のとき、`WebViewDOMFallback` が stderr へ理由を言う
(`warnBlankCaptureOnce` と同じく判定・文言は純粋関数、メモは static)。
実測の起点: E2E-RN の `placeholder=` 検査が **local(`android-35/google_apis` = userdebug・
`ro.debuggable=1`)では緑・ランナー(`google_apis_playstore` = user・`ro.debuggable=0`)では決定的に
赤**で、APK も WebView 版も同一だった。SUT は release ビルド(非 debuggable)なので Chromium は
`webview_devtools_remote_<pid>` を開かず、DOM 読みが黙って a11y へ落ちていた。
**言うのは端末の事実で決まる2つだけ**: ①ソケットが無く、かつシステムもアプリも非 debuggable と
確認できた(構造的に開かない)/ ②同名プロセスが複数でソケットを1つに選べない。
**nil の大半は正常な過渡**(WebView 未生成・タブ未選択・遷移直後)なので、ソケットがある回・
debuggable なのにソケットがまだ無い回・事実が読めなかった回は**黙る**(鳴らすと健全な構成でも
毎回鳴る)。**回数は (serial, package) ごとに診断1回**: ソケット解決が結論(有り / 無し / 曖昧)を
返した時点でメモし、以後は問い合わせも警告もしない。未起動・adb 不能は結論ではないので次の
miss で引き直す。追加コストは miss 経路の adb 1往復(構造的の回だけ debuggable の問い合わせが
もう1往復)で、結論後は 0。文言では**アプリ自身の `setWebContentsDebuggingEnabled(true)` という
3つ目の口**に必ず触れる —— 「2つのフラグだけで決まる」と断定すると、その呼び出しを持つ受け手に
誤った直し方を指す(`WebViewDOMFallbackTests` が断定文言を否定で固定)。**挙動は変えない**
(警告だけ)。子の stderr を中継する `ScenarioHost` は、ドライバが自分で `⚠️` を付けた行に
重ねない(`fleetest run` で `⚠️ ⚠️` になっていた)。受け手向けの説明は
docs/user-docs/selector/webview(.md/_ja.md)。

## ブラウザの中身は DOM から読む(2026-08-13)

殺しスイッチは `FT_BROWSER_DOM=off`(自作アプリ側の `FT_WEBVIEW_DOM=off` とは別の口)。
**自作アプリの WebView は別の理由で別の門**(次節)。

### なぜ(当初の根拠は誤診だったので、置き換わっている)

最初は「`android.webkit.WebView` は `<table>` のセルを a11y へ1つも公開しない」を根拠に
アプリ内 WebView 向けに作った。**これは誤診**で、実際はセルは a11y に在り
`SnapshotBuilder.mappedType` の葉テキスト救済が取りこぼしていた(ブリッジ版 61 で修正)。
**4 SUT で揃って再現したのは WebView の性質ではなく共通のフィルタだった**
(教訓は docs/verification.md)。

残った本物の根拠は**ブラウザ本体**。あちらは実際にページを部分的にしか a11y へ出さない
(監査22/23/25 の実 web ページ。Android Chrome が本文を1要素も公開しない形が2サイトで再現)。
a11y からは埋めようがないので DOM を直接読む。

### 既定は a11y。足りないときだけ DOM(2026-08-14 に反転)

**当初は「ブラウザでは常に DOM」だった。** 根拠は「ページごとに a11y の充実度が変わるので、
条件で切り替えると**このページでは通るが別のページでは落ちる**」。**この前提が実測で崩れた**:

- 充実度が変わって見えた正体は **a11y サービス接続から木が出来るまでの数秒の窓**で、
  ページの性質ではなかった(§実機だけの罠 の ⑵ と同じ現象)
- 窓を過ぎた実ページでは **a11y と DOM のラベル集合が完全に一致**した
  (Wikipedia 34 / 気象庁 61 / tenki.jp 75、いずれも差 0)
- **a11y は 6〜20 倍速い**(126ms 対 1430ms)

判定は `WebViewDOM.browserA11yLooksSufficient` の1箇所。足りないと見なすのは
**`webView` ノードが無い / その内側にラベルが1つも無い**の2つだけ。
DOM を入れるときは `webView` ノードの内側の a11y 要素を落としてから足す
(素朴に append すると本文が二重に並ぶ)。ノード自身とブラウザ chrome は a11y のまま残す。

判定は `FTCore.WebViewDOM` の1箇所(`WebViewDOMTree.swift`)。**`WebViewDOMSnapshot.swift` へ
置かない** —— あちらは `BridgeSourceSet` の inApp ブリッジ入力なので、ホスト専用の関数を足すと
dylib に無駄なコードが入り `BridgeContractTests` の指紋が鳴る。

### 口は3つ、その上の層は1つ

プロトコル層(JS・座標写し・差し込み)は共通で、**開け方だけが違う**。

| 相手 | 口 | 備考 |
|---|---|---|
| iOS 自作アプリの WKWebView | in-app ブリッジから直に JS | 既存(`InAppWebViewDOM`) |
| Android Chrome | CDP。`adb forward localabstract:chrome_devtools_remote` | **pid が付かない**ので WebView の pid 一致規則とは別規則 |
| iOS Safari(シミュレータ) | `webinspectord_sim` の unix ソケット | 根が `/private/var/tmp` と `/private/tmp` の**2つ**ある |

**Chrome は debuggable でなくても `@chrome_devtools_remote` を公開する**(`chrome://inspect` が
成り立つ理由)。a11y が6要素しか返さなかった Wikipedia のページから、同じ JS で 64 ノードを
9ms で取得できた。

### 能動タブの選択は「順序」では決まらない

**`/json` は MRU 順ではない**(7タブの Chrome で先頭は前面ではない別サイトだった)。しかも
同じページを2タブ開くと**題名が一致する**。順序や題名で1つに決めると背面タブを掴み、
**Chrome は背面タブの JS を止めるので評価が返らない**(実測 183 秒待っても返らなかった)。

確からしい順に並べ(`rankedTabs`)、**上から試して応答したものを能動タブとみなす**。
根拠は強い順に ①アドレス欄と URL が一致 → ②フラグメントを落とせば一致 → ③部分一致 →
④題名一致 → ⑤残り。**フラグメントを最初から落とさない** —— 同じページの2タブを分ける
唯一の材料がそれのことがある。

**`URLSessionWebSocketTask.receive()` には締切が無い**ので必ず番犬を付ける。snapshot は
最頻の操作で、ここが無期限だと run ごと固まる。

### DOM は a11y の粒度・命名へ揃える

同じ画面を a11y と DOM で読んで**セレクタの書き方が変わらない**ようにする(ブリッジ版 66)。

- **子孫が全部インラインのテキストなら1ノードへ畳む**。Chromium の accname は
  `<td><span>19</span> / <span>24</span></td>` を「19 / 24」1件で出すが、素の DOM 走査は
  葉ごとに3件出す。役割を持つ子孫(link/button/input/img)が1つでもあれば畳まない
- **`alt` の無い画像は `src` のファイル名を名前にする**(`logo_small.svg` → `logo_small`)。
  Chromium がそうしており、揃えないと置き換えた瞬間に名前が消える

**揃えた副作用**: ラベルだけでは a11y と DOM を見分けられなくなる。**検証は木の構造で行う**
(ブラウザ chrome の後に id 無しノードが続くか)。ここを怠って一度、a11y の木を
「DOM が効いている」と誤読した。

### 実機(iOS)は口が違う

シミュレータの unix ソケットは実機に無い。実機は **usbmuxd → lockdownd → TLS → webinspectord**:

    /var/run/usbmuxd に ReadPairRecord / ListDevices / Connect(62078)
      → lockdown: QueryType → StartSession(EnableSessionSSL)→ **クライアント証明書付き TLS**
      → StartService "com.apple.webinspector" → Port と EnableServiceSSL
      → その Port へもう1本 Connect し、**同じ証明書で TLS**
      → 以後はシミュレータと同じ WIR プロトコル

**root は要らない**(ペアリング記録は `/var/db/lockdown/` を読めなくても usbmuxd が渡す)。
**外部ツールも要らない**(`ios-webkit-debug-proxy` は不要)。
iOS 17 以降 RemoteXPC/RSD へ移ったサービスもあるが、`com.apple.webinspector` は
**iOS 26.6 でも従来の lockdown から起こせた**(実測)。移された合図は `InvalidService` で、
そのときだけ stderr に出す。

`SecIdentity` は PKCS#12 を `kSecImportToMemoryOnly` で読む(**キーチェーンに触れない**)。

**Android の実機は特別扱い不要**(Pixel 4a で確認。Chrome は同じく `@chrome_devtools_remote`)。

### 実機だけの罠(3つとも実測で踏んだ)

**⑴ 1通が大きいと黙って捨てられる。** エラーも応答も返らず、60 秒待っても来ない。
しかも**上限は固定ではない** —— 同じ端末・同じページで2回測って境界がフレーム
7917/7981 と 8493/8557 に割れた(約 600 バイトの揺れ)。`Runtime.compileScript` でも同じで、
**コマンドの種類ではなく1通の大きさ**が効く。共有 JS(約 9.7KB)は1通で送れない。

対処は**分割して積む**(`assemblyExpressions`)。`globalThis.__ftSrc` へ `=`/`+=` で積み、
最後に eval して削除する。**共有 JS は1文字も変えない**(変えると他の3経路と別物になる)。
予算は **7000 → 駄目なら 4000**(境界のギリギリは狙わない。壊れ方が沈黙なので気付けない)。
**退避は繋ぎ直す**(同じ接続で RPC をやり直すと2周目のアプリ一覧が返らない)。
**閉じた直後の再接続も失敗する**ので 1.5 秒置く —— どちらも実機で陽性対照を通して確かめた
(予算を 200 に落として退避を強制的に走らせる)。**全体の締切は 30 秒**で、退避も内側。
**切るのはソース長ではなくフレーム長** —— JSON のリテラル化で 1.2 倍に膨らみ、
膨張率は場所によって違う(ソース 3000 → フレーム 5546 / 4000 → 8630)。
**文字単位で切る**(JS に日本語コメントがあり、バイトで切ると UTF-8 が割れる)。

**⑵ Web インスペクタが無効だと、TLS までは通って直後に切られる。**
`_rpc_reportIdentifier:` すら送れない。設定 → Safari → 詳細 → Web インスペクタ。

**⑶ 有効にする前から動いていた Safari は webinspectord に登録されない。**
アプリ一覧にデーモンだけが並び Safari が居ない。起動し直せば載る。

⑵⑶ は**人の操作でしか直せない**ので、黙って a11y へ落ちるだけにせず
**stderr で原因を名指しする**(`inspectorHint`)。**一覧が空のときは何も言わない** ——
単に Safari 未起動の可能性があり、そこで「起動し直せ」は的外れ(誤った助言は無いより悪い)。

## Android の自作アプリの WebView も DOM から読む(2026-08-15)

**ブラウザとは理由も門も違う。** ブラウザは「a11y に本文が出ない」だが、こちらは
**同じ HTML・同じアプリでも WebView の版で属性が入れ替わる**(実測。記録は
`Sources/FTAndroid/AndroidWebViewVersions.swift` 冒頭):

    WebView 124 : textField ph="WebView 入力"   (placeholder あり / id なし)
    WebView 150 : textField id=wv_input          (id あり / placeholder なし)

トレードではなく**入れ替え**なので、`#id` も `placeholder=` も混在フリートでは移植できない。
**DOM から読めば木が両方を持つ**ので、版差が供給源で消える。

**だから門も違う**: ブラウザは a11y が足りていれば読まないが、**自作アプリは足りて見えても読む**
(問うているのは「読めているか」ではなく「**どの端末でも同じ属性が出るか**」)。
自作アプリ側の門は **`webView` ノードの有無だけ** —— 無い画面で pid 引きと forward を払わない。
判定は `AndroidWebViewDOM.route`(純粋)の1箇所。

**ソケット規則が2つある**:

| 相手 | ソケット | 解決 |
|---|---|---|
| Chrome | `@chrome_devtools_remote`(**pid なし**) | パッケージ名 → 固定名 |
| 自作アプリの WebView | `@webview_devtools_remote_<pid>` | `pidof <package>` の**アプリ自身の pid** |

**成立条件は debuggable だけ**(2026-08-15 に emulator-5554 / `com.ftester.e2e` で実測)。
**アプリが `setWebContentsDebuggingEnabled(true)` を呼ぶ必要は無い** —— debuggable なら
WebView が1つでも生成された時点でソケットが開く(確認した版は Chrome/150.0.7871.181)。
**アプリの協力を要る退化は足さない**(release ビルドは id を難読化するので、id で指すテスト自体が
debug ビルドの活動)。取れないときは例外にせず黙って従来の a11y。

**注入は ref の名前空間が違う**(踏みやすい罠)。ブリッジの `/type` `/clear` は
**自分の snapshot の ref しか受け付けない**(`BridgeRouter.centerOf` は未知の ref を 404)。
DOM ノードにはホストが新しい ref を振るので、そのままでは**入力だけが 404 で落ちる**
(タップは座標をホストが持っているので通る = 落ち方が入力に偏る)。
`AndroidWebViewDOM.bridgeRefMap`(中心点を含む最小の a11y 入力欄)で写してから送り、
注入は従来どおり SET_TEXT + resource-id 追跡 + 読み返しの経路に乗せる。
**木の ref そのものは書き換えない** —— `z` を持たない要素の塗り順は ref 順に落ちるので、
入力欄だけ小さい ref にすると**その欄が兄弟の裏にあると判定される**。
**ブラウザ経路には対応表を作らない**(今日の挙動のまま)。

**推測で1つ選ばない**: 一覧(`/proc/net/unix`)には他アプリの `webview_devtools_remote_<別 pid>`
も Chrome の口も並ぶ。採るのは**自分の pid と厳密一致する名前だけ**で、複数当たれば
`ambiguous` = a11y のまま(外すと**別プロセスの DOM を本物の画面として木へ差し込む**)。
pid 引きとソケット一覧は**1往復に畳む**(adb は1回ごとに数十 ms かかり、ここは毎 snapshot の経路)。

## 17. テストベースからのシナリオ下書き生成(2026-07-26)

`TestProjects/<name>/docs/testbases/*.md`(テスト設計の元資料)を Swift DSL シナリオの**下書き**に
落とす。`fleetest draft-scenario`。ライブ操作の記録生成(§10 の gen-scenario)は実セレクタを持つが、
こちらは設計資料しか無いのでセレクタは全て TODO プレースホルダになる。

### 17.1 二段構え(FM → 決定的パーサ)

| 層 | 実装 | 役割 |
|---|---|---|
| 構造化(FM) | `FTFoundationModels/TestbaseDrafter` | 資料 → `ScenarioDraft`(scene の並び + CAE ごとの自然言語手順)。1呼び出し1セッション |
| 構造化(決定的) | `FTCore/TestbaseOutline.parse` | 見出し(`#`=説明 / `##`=scene)・`### 前提`・行頭ラベル(`前提:`/`Given:`)・「〜こと」で CAE に振り分け |
| レンダリング | `FTDSL/ScenarioDraftCodeGen` | 手順文 → コマンド候補(語彙の包含判定のみ・**FM 不使用=決定的**)+ Swift ソース |

**FM が不可用・失敗・出し損ないのときは決定的パーサへ落ちる**(`--no-fm` で常に決定的)。
4K 制約のため FM へ渡すのは先頭 2400 文字だけで、超過時は警告する(全文要約より「頭から確実に」)。

### 17.2 生成物の性質(壊さないこと)

- 生成クラスには **`@Draft` を付ける** → 一括実行から外れる(一覧には残る)。人が TODO を実セレクタへ
  置き換えてから `@Draft` を外す運用。出力先は `scenarios/Drafts/`(SPM ターゲットに含まれるので
  **下書きもコンパイル対象**。`ScenarioCodeGen.writeValidated` でビルド検証し、失敗時は `_disabled/` へ隔離)
- プレースホルダは `#TODO` = **決して解決できない id**。埋め忘れたまま `@Draft` を外すと
  「ロケータを解決できません」で確実に落ちる(空実装で緑になる方が危険なので意図的)
- 手順文は必ずコマンド行の末尾コメントに残す(写像が外れても元の意図が読める)
- `--name` 明示時は重複回避の連番が付かないため、同名ファイルがあれば上書きせずエラーにする
