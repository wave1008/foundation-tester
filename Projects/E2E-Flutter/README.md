# Projects/E2E-Flutter

ftester を **Flutter アプリ**に対して検証する E2E テストプロジェクト。
対象アプリはリポジトリ同梱の `E2EAppFlutter/`(bundle id / applicationId = `com.ftester.e2e.flutter`)。

- 画面構成・`#id`・ラベルの正: `E2EApp/docs/ui-contract.md`(Compose 版と共通)
- Flutter 固有の差分(必須設定2つ・罠8つ): `E2EAppFlutter/docs/ui-contract.md`

## 対象アプリのビルド

```sh
cd E2EAppFlutter
./scripts/build-ios.sh        # → dist/ios-simulator/FTE2EFlutter.app
./scripts/build-android.sh    # → dist/android/ft-e2e-flutter-debug.apk
```

Flutter SDK が必要(`brew install --cask flutter`)。

## 実行

**iOS と Android を別々に実行する。** シナリオは `platform:` 未指定(両OS共通で書いてある)ため、
両OSのデバイスを1プロファイルに並べても片方のキューにしか入らない(docs/design.md §11.4)。

```sh
ftester run --project E2E-Flutter --profile ios-xcuitest
ftester run --project E2E-Flutter --profile android
```

## 実測(2026-07-23・M2 Ultra)

| プロファイル | 結果 | 壁時計 |
|---|---|---|
| `ios-xcuitest`(iPhone 17 Pro/iOS 27.0 × 6) | ✅ 20/20 | 43.3s |
| `ios-inapp`(同上・hybrid) | ✅ 20/20 | — |
| `android`(Pixel 9/Android 15 × 8) | ✅ 20/20 | 30.9s |

## シナリオ一覧

| ファイル | 検証する ftester 機能 |
|---|---|
| `01_起動と画面遷移.swift` | `launchApp` / タブ切替 / 下位画面遷移+`戻る` / タブ切替でスタックを持ち越さないこと |
| `02_セレクタ_id指定.swift` | `#id` セレクタと結果 echo の完全一致検証 |
| `03_セレクタ_ラベルと部分一致.swift` | ラベルセレクタの完全一致優先→部分一致フォールバック契約 |
| `04_セレクタ_型と序数.swift` | `.Type[n]` / `.Type#id` / `.Type=ラベル` / `\|\|` フォールバック連鎖 |
| `05_テキスト入力.swift` | `type` と入力値 echo |
| `06_ジェスチャ.swift` | `tap` 連打 / `press`(長押し)と通常タップの区別 / `swipe` 4方向 |
| `07_スクロール.swift` | `scrollTo` と「`exist`/`textIs` は非スクロール」の契約 |
| `08_待機とタイムアウト.swift` | 暗黙待ち(既定タイムアウト再試行)と `timeout:` 引数 |
| `09_条件分岐とダイアログ.swift` | `ifCanSelect` と `optional:` |
| `10_ライフサイクルとプラットフォーム分岐.swift` | `relaunchApp`、`ios {}` / `android {}`、コントロールの状態遷移 |

## `_disabled/`(通常実行に含めない)

**`_disabled/` は SPM のビルド対象外**(`Package.swift` の `exclude`)。回すときは
`Scenarios/` 直下へ移動 → `swift build --product ftester-scenarios-E2E-Flutter` → 実行 → 元に戻す。

- `90_自己修復.swift` — FM 必須。`--heal` を付けて実行。
  **2026-07-23 検証済み**(iOS): FM 経路で `#btn_heal_v1` → `#btn_heal_v2||修復対象` に修復できることを確認。
  この検証で SUT のバグを1件発見・修正した(下記「key 無しの identifier 切替」)
- `91_クラッシュ検知.swift` — アプリを実際にクラッシュさせる破壊的シナリオ。**`ios-xcuitest` で回す**。
  **2026-07-23 検証済み**: `dart:ffi` の NULL 参照(SIGSEGV)でプロセスが落ち、
  「Application ... is not running」(XCUITest 500)として現れる。
  **Dart の `throw` では落ちない**(フレームワークに捕捉される)ため意図的に不正メモリアクセスにしている

## 既知の未解決事象: occlusion-guard の偽陽性(2026-07-23)

FM が生きている状態でこの SUT を回すと、`launchApp()` 直後の `exist("#txt_home_marker")` が
「偽陽性(occlusion): [covered]」で落ちることが**ある時間窓で3回**あった。**原因は未特定**。

### 確定していること(コード精査 + 実測)

- レポート添付の失敗時スクリーンショットは **FM の入力ではない**(FM が見るのは poll 周回内の
  `guardScreenshot()`。添付は poll が尽きた後の別撮り)。当初これを取り違えて「FM の誤判定」と
  断定したのは誤り
- その別撮り画像を同一クロップ・同一 instructions/prompt で 15 回再判定 → **15/15 fullyVisible**
  (`sampling: .greedy`)。「その画像を見て誤判定した」のではない
- poll はスクショを**周回ごとに取り直す**(TTL 200ms + 周回末尾で無効化)。腐ったキャッシュ説はコードで否定
- `lastOcclusion` は要素未発見の周回でクリアされるため、失敗が返った以上
  **最終周回(起動の約5秒後)でも要素は解決でき、その時点の新鮮なスクショを FM が covered と判定した**
- 3件とも `#txt_home_marker`(淡色背景に淡色テキスト)。この SUT で低インク事前フィルタを抜けて
  FM に回るのは実質この領域だけで、高コントラストの echo 検証は FM を呼ばない
  (同じ実行窓で CMP/ネイティブ SUT が無傷だったのはこのため。除外の根拠にならない)

### 競合する仮説(次回発生時に下記の計装で判別する)

1. **FM/SCA の劣化窓**(有力): flip は 04:08 の FM 全滅(ModelManagerError 1001)と
   05:34 の全滅(SensitiveContentAnalysisML error 15)の**間**の 05:22-05:25 に起きた。
   SCA が劣化する過程で画像添付が白紙化/破棄され、モデルは「何も見えない画像」に正しく
   covered と答えていた可能性(応答自体は成功するので FM 全滅の警告は出ない)。
   これなら **Apple 報告案件**(availability は正常のまま vision 経路だけ黙って劣化する)
2. **起動遷移画面**: Flutter debug ビルド(JIT)の first frame が並列負荷で遅れ、
   launch screen(白)が覆っている間に判定された = **guard は正しかった**可能性。
   ただし落ちた実行の launch 時間(5.6s)は通った実行の範囲(4.2〜7.5s)に収まっており、相関は弱い

### 次回発生時の切り分け手順

flip 時に **FM が実際に見た crop** と読み取り結果が自動で残る(この事象のために追加した計装):

- 失敗メッセージ末尾の `observed="..."` — **空なら仮説1**(画像が渡っていない)、
  **期待どおりの文字列なら純粋な判定誤り**(読めたのに covered と答えた = Apple 報告の最有力材料)
- 失敗メッセージ末尾の `[crop: <path>]` — FM が見た画像そのもの
  (`~/Library/Logs/ftester/occlusion/`。`FT_OCCLUSION_DUMP_DIR` で変更可・`off` で無効)。
  **白紙なら仮説1か2**、レンダリング済みなら判定誤り
- 再判定・Apple 提出用の最小再現: `Scripts/occlusion-repro.swift`(ftester 非依存)

```sh
xcrun swiftc -O Scripts/occlusion-repro.swift -o /tmp/occlusion-repro
/tmp/occlusion-repro ~/Library/Logs/ftester/occlusion/occlusion-<時刻>.png 15
```

### 配色と検出器の方針

この SUT は **Material 3 の既定配色(淡い着色)をそのまま使う**。白背景に変えれば低インク判定を
避けられるが、M3 既定はごく普通の実アプリの見た目であり、そこで落ちるなら ftester 側の問題。
SUT の見た目を変えて避けるのは**検出器を潰す**行為なので採らない。

- **検出点は `01_起動と画面遷移`**(既定 `requireVisible: true` のまま。timeout も既定 5s のまま —
  広げると仮説2を吸収してしまい、判別材料が消える)
- 他シナリオの `launchApp()` 直後の着地確認だけは `requireVisible: false`。あれは可視性の検証ではなく
  「Flutter が起動直後にポインタ入力を取りこぼす」ための同期の1往復で、FM 直列化(約1回/秒)の
  コストだけが乗るため

## in-app エンジン対応(2026-07-23 に2つの修正で解決)

かつては `iosInappEngine: true` で回すと **a11y ツリーが取れず要素が1つも見えなかった**。
原因は2つあり、どちらも ftester 側で解決済み(`ios-inapp` プロファイルで 20/20 グリーン):

1. **Flutter engine は `_AXSSetAutomationEnabled` を見ない**。platform 側の a11y ブリッジ
   (SemanticsObject 群)が生成されず `FlutterView.accessibilityElements` が空のままだった。
   → in-app ブリッジが snapshot ごとに `FlutterEngine.ensureSemanticsEnabled`(公開 API)を
   動的に呼ぶ(`FTEnsureFlutterSemantics`。非 Flutter アプリでは no-op)
2. **Flutter の SemanticsObjectContainer は旧式の indexed UIAccessibilityContainer API しか
   実装しない**(`accessibilityElements` プロパティは空)。走査がコンテナで止まっていた。
   → 非 UIView ノード限定で `accessibilityElementCount`/`accessibilityElement(at:)` を辿る
   (UIView に適用すると UITableView の走査を乗っ取り `.Cell` が消える退行になる。実測済み)

in-app での注意: テキスト欄の型は `Other` になる(XCUITest の `TextField` と食い違う。
Flutter のフィールドは UITextField ではないため)。`#id` 指定なら両エンジンで同一に動く。
ジェスチャ(swipe/press)は申告により XCUITest へ自動フォールバックする(hybrid)。

## 注意(Flutter 特有。シナリオの書き方に直接効く)

- **`launchApp()` の直後に `exist("#txt_home_marker")` を必ず挟む**。Flutter は起動直後の数百 ms、
  a11y ツリーは完成しているのにポインタ入力を取りこぼす(初回タップが成功扱いのまま無反応)
- **tap と type の間に1往復挟む**。Android は input connection が tap 応答より遅れて張られ、
  直後の `type` が 500「ACTION_SET_TEXT を受け付けないフィールドです」で落ちる
- **`scrollTo` の直後にもう一度 `swipe(.up)` して端まで送る**。`scrollTo` は行が下端に数 px
  覗いた時点で解決を返すため、その中心をタップすると行の外に落ちて空振りする
- **型セレクタは `Button` だけ**。テキストは iOS=`StaticText` / Android=`Other` と非対称なので
  `#id` + `textIs` で書く。`obscureText` の欄も `SecureTextField` にはならない
- `#txt_dialog_title` は**両OSで引ける**(Flutter のダイアログはネイティブウィンドウではないため)。
  iOS ネイティブ SUT では引けないので、SUT 間でシナリオを流用するときはここが差になる
