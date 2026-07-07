# foundation-tester

macOS の Foundation Models framework(オンデバイス 3B モデル)を頭脳にした、
iOS / Android アプリの E2E テストツール。

**設計思想: 「AI がテストを作り、コードが決定的に再生する」**

- **生成**: 自然言語のゴールを渡すと、FM エージェントがアプリを実際に操作しながら探索し、
  テストフロー(YAML)を自動生成する。すべてオンデバイス — アプリの画面情報が Mac の外に出ない
- **再生**: 生成済みフローは LLM なしで決定的に再生する。高速・安定で CI 向き
- **失敗時のみ FM が介入**: ロケータ自己修復 / スクリーンショットの視覚検証(マルチモーダル)/
  失敗原因のトリアージとレポート生成

## 4つのインターフェース

同じコア(Flow DSL + AppDriver + Replayer + FM エージェント)の上に、用途別の入口が4つある。

| 入口 | 起動 | 向いている用途 |
|---|---|---|
| **CLI** `ftester` | `swift run ftester ...` | CI・回帰テストの定期実行(決定的・無料・exit code) |
| **GUI** ftester Studio | `swift run ftester-gui` | 人間の対話操作: フロー実行・ライブ操作・FM探索 |
| **MCP** サーバ | Claude Code が自動起動([.mcp.json](.mcp.json)) | エージェント連携: AIによるテスト作成・デバッグ・探索的テスト |
| **Flow DSL** (YAML) | `flows/*.yaml` | テスト資産。どの入口で作っても同じ形式で保存・再生される |

役割分担の原則: **探索・判断(知能)はエージェント、操作・再生・検証(決定性)は ftester**。
テスト作成は GUI の FM 探索(オンデバイス・無料)か、複雑なものは Claude Code(MCP 経由)で行い、
できた YAML を CLI/CI で決定的に回す。

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

# 3. FM エージェントにテストを作らせる → flows/*.yaml が生成される
swift run ftester explore com.example.sampleapp \
  --goal "メールアドレス test@example.com、パスワード password123 でログインし、ホーム画面に「ようこそ」が表示されることを確認する"

# 4. 決定的再生(LLM なし。失敗があれば exit code 1)
swift run ftester run flows/
```

ゴール文のコツ: 入力値は具体的に書く。**確認したい文言は「」で囲む**
(「」内はエージェントが停滞した場合のコード側検証にも使われる)。

## コマンド一覧

| コマンド | 説明 |
|---|---|
| `doctor` | FM・Xcode・シミュレータ・adb の事前診断 |
| `bridge up / down / status` | iOS ブリッジ(常駐 XCUITest ランナー)の管理 |
| `explore <bundle-id> --goal "..."` | FM 探索によるフロー生成(`--max-steps` `--out`) |
| `run <path>` | フローの決定的再生(`--heal` で自己修復許可、`--report-dir`、`--ports` で並列) |
| `launch / terminate <bundle-id>` | アプリの起動・終了 |
| `snapshot [--json]` | 画面の要素一覧(圧縮形式)を表示 |
| `tap --ref N` / `tap --x --y` | タップ |
| `type --ref N "text"` | テキスト入力 |
| `swipe up\|down\|left\|right` / `press --ref N` | スワイプ・長押し |
| `screenshot -o file.png` | スクリーンショット保存 |

共通オプション: `--platform ios|android`(既定 ios)、`--serial <adb serial>`(Android 複数台時)、
`--port <n>`(iOS ブリッジ)。

### 並列実行

シミュレータ1台につきブリッジ1本(別ポート)を立て、`run --ports` でフローを分配する。
Android フローがあれば専用ワーカーも同時に走る。

```bash
# デバイス毎にブリッジを起動(ビルドは1回で共有される)
swift run ftester bridge up --device "iPhone 17 Pro"                          # port 8123
swift run ftester bridge up --device "iPhone 17 Pro Max" --port 8124 --skip-build
xcrun simctl install "iPhone 17 Pro Max" <対象アプリ.app>   # 各デバイスにアプリを入れる

swift run ftester run flows/ --ports 8123,8124   # フローをワーカーに自動分配
swift run ftester bridge down --all              # 全ブリッジ停止
```

- 実測(M4 Mac): 3フロー逐次 55.2秒 → 2+1並列 31.2秒(壁時間 ≒ 最長フロー)
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
付けるだけ。ブリッジは不要。

```bash
swift run ftester explore com.android.settings --platform android \
  --goal "「Network & internet」を開いて、「Internet」が表示されることを確認する"
```

## フロー YAML

生成されるフローは人間がレビュー・編集できる YAML。`platform` を持つため、
`run flows/` は **iOS/Android 混在ディレクトリをフロー毎にドライバ自動選択で一括実行**できる。

```yaml
name: ログインフロー
app: com.example.sampleapp
platform: ios            # ios / android(省略時は --platform に従う)
dirty: true              # 自己修復や探索中断で書き換えられた印(要レビュー)
steps:
- action: scrollTo       # 要素が見つかるまでスクロール(direction / maxSwipes 指定可)
  locator: { id: login_btn }
  direction: up
  maxSwipes: 8
- action: type           # tap / type / swipe / press / scrollTo
  locator: { id: email } # 優先度: id > label > type+index。type は id/label と併用可
  fallbacks: [ { type: TextField, index: 0 } ]
  text: test@example.com
- assert: exists         # アクセシビリティツリーで決定的に検証
  locator: { id: welcome_text }
  timeout: 5
- action: tap            # optional: true = 要素が見つからなくても失敗せずスキップ
  locator: { label: 今はしない }  # (パスワード保存シート等、出るかどうか不定なダイアログの処理用)
  optional: true
- assert: valueEquals    # スイッチやテキスト欄の値を検証(Switch は "1"=ON / "0"=OFF)
  locator: { id: notif_toggle, type: Switch }
  expected: "1"
- assert: screenMatches  # FM がスクリーンショットを見て判定(マルチモーダル)
  expected: 商品リストがあるホーム画面が表示されている
```

実例: [flows/resource-upload-test-mode.yaml](flows/resource-upload-test-mode.yaml)
(設定 > デベロッパ > Resource Upload Test Mode が ON であることの検証。
スクロール探索・型指定ロケータ・値検証・日英ロケール両対応フォールバックを使用)

- 失敗時は `reports/` に Markdown レポート(ステップ結果、トリアージ分類
  appBug / locatorDrift / flakiness / envIssue、修正案、スクリーンショット)を出力
- `--heal` 時、壊れたロケータは FM が修復して続行し、フローは `dirty: true` 付きで上書きされる

## GUI(ftester Studio)

```bash
swift run ftester-gui                       # リポジトリルートから起動(flows/ を相対参照)
FT_PORTS=8123-8130 swift run ftester-gui    # ポート範囲を指定して起動(設定より優先)
FT_AUTORUN=1 swift run ftester-gui          # 起動と同時に全実行(スモークテスト・デモ用)
FT_TAB=3 swift run ftester-gui              # 初期タブ指定(0:実行 1:ライブ 2:探索 3:設定)
```

SwiftUI 製の macOS アプリ。**iOS と Android は切替なしで同時に扱う** — 起動時に設定の
ポート範囲をスキャンして稼働中の iOS ブリッジを、`adb devices` から Android デバイスを
自動発見し、ツールバーの「対象デバイス」ピッカーに並ぶ。4タブ構成:

- **フロー実行** — flows/ の一覧(platform・dirty・実行状態バッジ)、ステップ表、
  実行+自己修復トグル、ライブ実行ログ、失敗時トリアージ表示。
  **「全実行」は稼働中の全デバイスへフローを動的に分配して並列実行**
  (iOS ブリッジ毎のワーカー + Android も adb デバイス毎のワーカー、CLI の `run --ports`
  と同じオーケストレータ)。ログはワーカー毎のレーンに分かれて流れる。
  Android は複数エミュレータを起動しておくだけで並列対象になる(ブリッジ不要)
- **ライブ操作** — 対象デバイスのスクリーンショットを**クリックした位置をそのままタップ**
  (デバイス座標へ自動変換)、要素一覧(行クリックで tap)、スワイプ・起動・終了
- **FM探索** — ゴールを書いて探索開始 → ExplorerAgent の進捗をライブ表示 →
  生成フローが一覧に自動追加され、そのまま実行できる(対象デバイスの platform が
  フローに記録される)
- **設定** — 下記

CLI・MCP と同じモジュールを使うため挙動は完全に同一。

### 設定ペイン(ポート範囲とブリッジ管理)

設定は今後の拡張を見込んで独立タブに集約している。

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
| `ft_list_flows` / `ft_run_flow` | フロー一覧 / 決定的再生(`heal` オプション付き) |

全ツールに `platform: ios|android` を指定可能。探索(explore 相当)はツール化していない —
スナップショットと操作プリミティブがあれば、クライアント側のエージェント自身が探索できるため。
役割分担は「エージェント=知能(探索・判断)、ftester=決定性(操作・再生・検証)」。

## アーキテクチャ

```
ftester CLI (macOS) ── FTAgent   (FoundationModels: 探索 / 視覚検証 / 修復 / トリアージ)
      │                FTCore    (Flow DSL / AppDriver 抽象 / 決定的再生器 / レポート)
      │
      ├─ HTTP (localhost:8123) ──▶ iOS シミュレータ内の常駐 XCUITest
      │                            (WebDriverAgent 方式・依存ゼロの自作ブリッジ)
      └─ adb ─────────────────────▶ Android エミュレータ / 実機
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
Sources/
  ftester/         CLI(swift-argument-parser)
  ftester-gui/     GUI「ftester Studio」(SwiftUI macOS アプリ)
  ftester-mcp/     MCP サーバ(stdio / JSON-RPC、自前実装)
  FTCore/          Flow DSL / AppDriver / 再生器 / レポート(FM 非依存)
  FTAgent/         FM エージェント(Explorer / Healer / Verifier / Triager)
  FTBridgeClient/  iOS ブリッジの HTTP クライアントと起動管理
  FTAndroid/       Android ドライバ(adb 直叩き)
Runner/            xcodegen 定義 + ブリッジ本体(HTTP サーバ内蔵 UI テスト)
SampleApp/         検証用 SwiftUI デモアプリ(test@example.com / password123)
flows/             生成されたテストフロー(コミットして資産化する)
docs/              設計書・実装知見
```

## パフォーマンス(実測値)

| 操作 | 実測 | 補足 |
|---|---|---|
| ブリッジ `/status` | 13ms | HTTP サーバ自体のオーバーヘッドはほぼゼロ |
| スナップショット(iOS) | 約 250ms | XCUITest のツリー取得コストが本体 |
| スナップショット(Android) | 約 2.0秒 | `uiautomator dump` の既知の特性 |
| MCP ツール呼び出し | +0ms 相当 | ブリッジ直叩きと差なし(常駐プロセス) |
| フロー実行(4ステップ+スクロール6回) | 約 30秒 | 大半はステップ間の安定待ち(0.6〜0.8秒×N)と起動待ち |

- `swift run ftester ...` は毎回 SwiftPM のチェックで **約1.6秒** 上乗せされる。
  連続実行するときは `.build/debug/ftester ...` を直接叩くと速い(GUI/MCP は常駐なので無関係)
- FM の応答時間: 探索1ステップ数秒、screenMatches 数秒(すべてオンデバイス・無料)

## トラブルシューティング

- **オンデバイスモデル: 利用不可** → システム設定で Apple Intelligence を有効化(`doctor` が理由を表示)
- **ドライバに接続できません** → iOS: `bridge up` を先に実行(ログは `.ftester/bridge-<ポート>.log`)。
  Android: `adb devices` で接続確認
- **explore が中断した** → 到達分のフローは `dirty: true` 付きで保存されるので、YAML を直接編集して
  仕上げられる(id ロケータ推奨)
- **Android の日本語入力が入らない** → `adb input text` の既知の制限(ASCII 推奨)
