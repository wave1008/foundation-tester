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

## 既知の未解決事象: occlusion-guard の偽陽性(2026-07-23)

FM が生きている状態でこの SUT を回すと、`launchApp()` 直後の `exist("#txt_home_marker")` が
「偽陽性(occlusion): 領域が不透明な要素に覆われている」で落ちることが**ある実行の窓で3回**あった。

**原因は未特定。** 当初「FM の誤判定」と結論したが、それは誤りだった:

- レポートに添付される失敗時スクリーンショットは **FM の入力ではない**。
  FM が見るのは poll ループ内で撮る `guardScreenshot()`(判定時点)で、
  レポートのスクショは poll が尽きた後の別撮り
- その別撮り画像を同じクロップ・同じ instructions/prompt で FM に 15 回食わせたところ
  **15/15 とも fullyVisible**(`sampling: .greedy` = 決定的デコード)。
  つまり「その画像を FM が誤判定した」わけではない
- 残る仮説は「FM に渡った crop が別物だった」(起動直後の未確定 frame で
  空白領域を切り出した等)。これは ftester 側の入力の問題であり Apple の不具合ではない

切り分けのため、**guard が反転したときに FM へ渡した crop 自体を保存する**ようにした:

```
~/Library/Logs/ftester/occlusion/occlusion-<時刻>.png   ← FM が実際に見た画像
~/Library/Logs/ftester/occlusion/occlusion-<時刻>.txt   ← 期待テキスト
```

保存先は `FT_OCCLUSION_DUMP_DIR` で変更可(`off` で無効)。失敗理由の末尾に `[crop: <path>]` が付く。
再判定は `Scripts/occlusion-repro.swift`(ftester 非依存。Apple へ出す最小再現にもなる):

```sh
xcrun swiftc -O Scripts/occlusion-repro.swift -o /tmp/occlusion-repro
/tmp/occlusion-repro ~/Library/Logs/ftester/occlusion/occlusion-<時刻>.png 15
```

配色について: この SUT は **Material 3 の既定配色(淡い着色)をそのまま使う**。
白背景・黒文字に変えれば低インク判定を避けられるが、M3 既定はごく普通の実アプリの見た目であり、
そこで落ちるなら ftester 側の問題。SUT の見た目を変えて避けるのは**検出器を潰す**行為なので採らない。

- **検出点は `01_起動と画面遷移`**。ここは `exist` を既定(`requireVisible: true`)のまま置いてある
- 他シナリオの `launchApp()` 直後の着地確認だけは `requireVisible: false`。あれは可視性の
  **検証**ではなく「Flutter が起動直後にポインタ入力を取りこぼす」ための同期の1往復であり、
  かつ FM はホスト全体で直列化(約1回/秒)されるため 19 箇所で呼ぶとコストだけが乗る
- **現状**: M3 既定のまま 01 単体 10 回 + フルスイート 3 回で再現せず。
  「潰れた」のか「踏まなくなっただけ」なのかは区別できていない

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
