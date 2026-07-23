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

- `90_自己修復.swift` — FM 必須。`--heal` を付けて実行。**未検証**(検証時点で FM が不通)
- `91_クラッシュ検知.swift` — アプリを実際にクラッシュさせる破壊的シナリオ。**`ios-xcuitest` で回す**。
  **2026-07-23 検証済み**: `dart:ffi` の NULL 参照(SIGSEGV)でプロセスが落ち、
  「Application ... is not running」(XCUITest 500)として現れる。
  **Dart の `throw` では落ちない**(フレームワークに捕捉される)ため意図的に不正メモリアクセスにしている

## 既知の ftester 欠陥: occlusion-guard が低コントラスト画面で誤判定する(2026-07-23 実測)

FM が生きている状態でこの SUT を回すと、`exist("#txt_home_marker")` が
「偽陽性(occlusion): 領域が不透明な要素に覆われている」で落ちることがある。
**失敗時スクリーンショットでは当該テキストは完全に見えており、FM の誤判定**
(memory の poc-fm-occlusion-guard: 素の FM は低インク領域で約 50% 誤反転する、と符合)。

この SUT は **Material 3 の既定配色(淡い着色)をそのまま使う**。白背景・黒文字の
高コントラストに変えれば落ちなくなるが、それは**検出器を潰す**行為である
(M3 既定はごく普通の実アプリの見た目であり、そこで落ちるなら ftester 側の問題)。
よって配色は変えず、欠陥が再現する状態を保つ。

- **検出点は `01_起動と画面遷移`**。ここは `exist` を既定(`requireVisible: true`)のまま置いてある
- 他シナリオの `launchApp()` 直後の着地確認だけは `requireVisible: false`。あれは可視性の
  **検証**ではなく「Flutter が起動直後にポインタ入力を取りこぼす」ための同期の1往復であり、
  かつ FM はホスト全体で直列化(約1回/秒)されるため、19 箇所すべてで FM を呼ぶと
  実行時間が跳ね上がる。検証としての価値は無く、コストだけがある
- **再現性(2026-07-23 実測)**: 誤判定は**ある実行の窓で3回**観測されたが、その後
  FM が生きている状態で 01 単体 10 回 + フルスイート 3 回を回して**再現しなかった**。
  安定化したのは配色ではなく、上記の同期バリアを `requireVisible: false` にしたこと
  (誤判定はすべて同期バリアのステップで起きていた)。
  よって現時点では「潰れた」のか「踏まなくなっただけ」なのか区別できていない。
  01 が guard を持ち続けているので、再発すればそこで捕まる

## Flutter は in-app エンジンでは動かない(2026-07-23 実測)

`iosInappEngine: true`(hybrid)で回すと **a11y ツリーが取れず要素が1つも見えない**
(`#txt_home_marker` すら解決できない)。原因は未特定。
そのため `ios-inapp` プロファイルは置かず、iOS は `ios-xcuitest` で回す。

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
