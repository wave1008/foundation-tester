# foundation-tester — iOS テストツール設計書

macOS 27 の Foundation Models framework(オンデバイス 3B モデル)を最大限活用する
アプリテストツール。iOS を先行実装し、Android は同じ抽象の上に後続実装する。

- 作成日: 2026-07-07
- ステータス: 設計確定(iOS フェーズ)
- 決定事項: ハイブリッド型 / 自作 XCUITest ランナー / シミュレータ優先 / Swift + FoundationModels

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

1. **探索・生成モード**: FM エージェントがアプリを探索し、決定的なテストフロー
   (YAML)を生成して保存する。LLM を使うのはここ。
2. **実行モード**: 保存済みフローを FM なしで決定的に再生。高速・安定で CI 向き。
3. **失敗時のみ FM が介入**: ロケータ自己修復、スクリーンショット+ツリー差分の
   トリアージ、自然言語バグレポート生成。

コンテキスト対策の原則:
- アクセシビリティツリーは **圧縮テキスト(set-of-mark 形式)** にして 1 画面ずつ渡す
- セッションは **1 ステップ = 1 セッション**(履歴は要約した「旅程ログ」だけ持ち回る)
- 出力は全て `@Generable` で構造化(自由文を返させない)

---

## 2. 全体アーキテクチャ

```
┌─ macOS ホスト ─────────────────────────────────────────────┐
│  ftester CLI (swift-argument-parser)                        │
│  ├─ FTAgent      : FoundationModels エージェント層          │
│  │   ├─ ExplorerProfile   (探索・フロー生成)                │
│  │   ├─ VerifierProfile   (マルチモーダル画面検証)          │
│  │   └─ TriagerProfile    (失敗トリアージ・自己修復)        │
│  ├─ FTCore       : Flow DSL / Driver プロトコル / 再生器    │
│  └─ FTBridgeClient : ランナーへの HTTP クライアント         │
└──────────────┬─────────────────────────────────────────────┘
               │ HTTP (localhost:8123 — シミュレータはホストと
               │        ネットワークスタック共有なので直接届く)
┌──────────────▼─────────────────────────────────────────────┐
│  iOS シミュレータ                                           │
│  FTesterRunnerUITests (XCUITest 内 HTTP サーバ, WDA 方式)   │
│  └─ XCUIApplication で対象アプリを起動・操作・snapshot      │
└────────────────────────────────────────────────────────────┘
```

**Driver プロトコル**が唯一のプラットフォーム境界。Android フェーズでは
`AndroidDriver`(adb + UIAutomator2 系サーバ)を同プロトコルで実装し、
FTAgent / FTCore はそのまま再利用する。

```swift
protocol AppDriver {
    func launch(bundleID: String) async throws
    func snapshot() async throws -> ScreenSnapshot      // 圧縮済みツリー
    func tap(elementRef: Int) async throws
    func type(elementRef: Int, text: String) async throws
    func swipe(_ direction: SwipeDirection) async throws
    func screenshot() async throws -> Data              // PNG
    func terminate() async throws
}
```

---

## 3. リポジトリ構成

```
foundation-tester/
├── Package.swift                  # CLI とライブラリ (macOS 27+)
├── Sources/
│   ├── ftester/                   # CLI エントリポイント
│   ├── FTCore/                    # Flow DSL, AppDriver, Replayer, ロケータ解決
│   ├── FTAgent/                   # FoundationModels: プロファイル, @Generable 型, Tools
│   └── FTBridgeClient/            # ランナー HTTP クライアント (URLSession)
├── Runner/
│   └── FTesterRunner/             # Xcode プロジェクト
│       ├── FTesterRunnerApp/      # 空のホストアプリ(UIテストの器)
│       └── FTesterRunnerUITests/  # HTTP サーバ内蔵の常駐 UI テスト
├── SampleApp/                     # 検証用の小さな SwiftUI デモアプリ(テスト対象)
├── flows/                         # 生成されたテストフロー (YAML)
├── reports/                       # 実行レポート・バグレポート出力先
└── docs/ios-test-tool-design.md   # 本書
```

---

## 4. XCUITest ブリッジ(自作ランナー)設計

WebDriverAgent と同じ原理を最小構成で自作する。

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

## 6. Flow DSL と決定的再生

### 6.1 フローファイル(YAML)

```yaml
# flows/login_success.yaml
name: ログイン成功フロー
app: com.example.sampleapp
generatedBy: ftester explore v0.1 (afm3-on-device)
steps:
  - action: tap
    locator: { id: email }            # 優先度: id > label > type+index
    fallbacks: [ { label: "メールアドレス" }, { type: TextField, index: 0 } ]
  - action: type
    locator: { id: email }
    text: "test@example.com"
  - action: tap
    locator: { id: login_btn }
  - assert: exists
    locator: { label: "ようこそ" }
    timeout: 5
  - assert: screenMatches            # Verifier(マルチモーダル)による視覚検証
    expected: "ホーム画面が表示され、タブバーに4つのタブがある"
```

### 6.2 再生器(Replayer)

- FTCore 内の純 Swift 実装。**FM は関与しない**(`screenMatches` を除く)。
- ロケータ解決: id → label → type+index のフォールバック連鎖。
- 失敗時の処理:
  1. ロケータ不一致 → **Triager に自己修復を依頼**。`confidence == high` なら
     その場で続行し、フローファイルに修復案を書き込み `dirty: true` を付ける
     (人間のレビュー対象であることを明示)。
  2. アサーション失敗 → Triager が `TriageReport` を生成し、スクリーンショット・
     ツリー差分と共に `reports/` へ Markdown 出力。

---

## 7. CLI UX

```
ftester doctor                      # FM 可用性・Xcode・シミュレータの事前チェック
ftester bridge up [--device "iPhone 17"]   # ランナーのビルド・常駐起動
ftester explore <bundle-id> --goal "ログインして商品を購入できることを確認"
                                    # 探索 → flows/*.yaml を生成
ftester run flows/ [--heal]         # 決定的再生(--heal で自己修復を許可)
ftester report                      # 直近実行のレポート表示
```

---

## 8. マイルストーン

| M | 内容 | 完了条件 |
|---|---|---|
| **M1** | ブリッジ + 手動駆動 | CLI から SampleApp を起動し、curl 相当で tap/type/snapshot/screenshot が通る |
| **M2** | FM 探索 → フロー生成 | `ftester explore` が SampleApp のログインフロー YAML を自動生成する |
| **M3** | 決定的再生 + 自己修復 + トリアージ | id 変更を仕込んだ SampleApp でフローが自己修復され、意図的バグで TriageReport が出る |
| **M4** | Android ドライバ | `AndroidDriver`(adb + UIAutomator2 系)で FTAgent/FTCore を無変更のまま Android アプリを探索・再生 |

M4 に向けて今やるのは `AppDriver` プロトコルの維持だけ。Android 側の作り込みは行わない。

---

## 9. リスクと対策

| リスク | 対策 |
|---|---|
| Apple Intelligence 未有効 / FM 利用不可 | `ftester doctor` で `availability` を事前診断。`LanguageModel` 差替(PCC/Claude)を用意 |
| 4K コンテキスト超過 | スナップショット圧縮 + 1 ステップ 1 セッション + 応答の構造化。`contextSizeExceeded` 捕捉時は要素数を半減させて再試行 |
| 巨大な画面ツリーで snapshot が遅い | ランナー側でフィルタしてから返す(ホストに生ツリーを送らない) |
| xcodebuild ランナーの不安定さ | `bridge up` にヘルスチェック+自動再起動。`/status` ポーリング |
| Vision 入力の HW 要件(AFM 3 Core Advanced) | ホストは Apple Silicon Mac 前提なので通常問題なし。`doctor` で検査 |
| 3B の判断ミス(探索の迷走) | ステップ上限・同一画面ループ検出をコード側で強制。`giveUp` アクションを用意 |

---

## 9.5 M2実装で得た知見(3Bモデルの実測特性)

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

## 9.6 M3実装で得た知見

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

## 9.7 M4実装で得た知見(Android)

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

## 9.8 並列実行の実装知見

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
- 実測: 3フロー(iOS×2 + Android×1)逐次 55.2秒 → iOS 2ワーカー+Android 1ワーカー並列で
  31.2秒。壁時間は最長フローに漸近する(理想スケーリング)

## 10. 検証方法(E2E)

1. `SampleApp`(ログイン画面 + ホーム画面 + 設定画面の 3 画面 SwiftUI アプリ、
   accessibility identifier 付き)をリポジトリに同梱
2. M1: `ftester bridge up` → `curl localhost:8123/snapshot` で圧縮ツリーが返る
3. M2: `ftester explore com.example.sampleapp --goal "ログインする"` →
   `flows/*.yaml` が生成され、人間が読んで妥当
4. M3: SampleApp の identifier を 1 つ改名 → `ftester run --heal` で修復・成功。
   意図的にログインを失敗させるビルド → TriageReport が `appBug` と分類する
```
