# Projects/E2E-iOS

ftester を **iOS ネイティブアプリ(SwiftUI + UIKit)** に対して検証する E2E テストプロジェクト。
対象アプリはリポジトリ同梱の `E2EAppIOS/`(bundle id = `com.ftester.e2e.ios`)。

- 画面構成・`#id`・ラベルの正: `E2EApp/docs/ui-contract.md`(Compose 版と共通)
- iOS ネイティブ固有の差分(型語彙・UIAlertController の癖・UITableView の癖): `E2EAppIOS/docs/ui-contract.md`

## 対象アプリのビルド

```sh
cd E2EAppIOS
./scripts/build-ios.sh       # → dist/ios-simulator/FTE2EIOS.app
```

## 実行

```sh
ftester run --project E2E-iOS --profile ios-xcuitest   # 全件グリーンの基準
ftester run --project E2E-iOS --profile ios-inapp      # エンジン差分の観測用
ftester run --project E2E-iOS --profile ios-heal       # --heal
```

全シナリオが `platform: "ios"` 固定(SUT が iOS 専用のため)。

## 実測(2026-07-23・M2 Ultra・iPhone 17 Pro/iOS 27.0 × 6)

| プロファイル | 結果 | 壁時計 |
|---|---|---|
| `ios-xcuitest` | ✅ 20/20 | 91.3s |
| `ios-heal` | ✅ 20/20 | — |
| `ios-inapp` | ✅ 20/20 | 30.4s |

## `ios-inapp` で判明し、修正した ftester 側の穴2件(2026-07-23)

この SUT を作って初めて見えた2点。**どちらも Compose 固有ではなく SwiftUI ネイティブでも起きていた**。
いずれも修正済みで、現在 `ios-inapp` は 20/20 グリーン(30.4s。xcuitest の 42.6s より速い)。

### 1. in-app のジェスチャ空振りが hybrid でフォールバックされなかった

`press` / `swipe` が 200 を返して成功扱いになるのに `onLongPressGesture` / `DragGesture` が
発火しない、という「黙った空振り」。原因は `InAppBridge` が `unsupportedActions` の申告も 501 の
返却も **`uiFramework == "compose"` のときだけ**行っていたこと。SwiftUI ネイティブは判定から
外れるため申告も 501 も出ず、ホストはフォールバックしなかった。

修正:
- `press` は実装を持たず**常に 501**(合成タッチの押下保持はどのフレームワークでも受理されない)
- `swipe` は contentOffset を動かせるスクロールビューが**その向きに余地を持って**存在するときだけ実行し、
  無ければ 501(ジェスチャ検出用パッドのように合成タッチへ落ちるしかない画面を申告する)
- `/status` の `unsupportedActions` は uikit でも `["press"]` を申告する
- `AppAttachDriver.swipe` は 409(セッションなし)なら activate して1回だけ再試行する
  (フォールバック先の XCUITest ブリッジに attach していない状態で swipe が最初の操作になると落ちていた。
  Compose 版は press のフォールバックが先に snapshot=activate していて露呈していなかった)

### 2. `.Cell` 型が in-app エンジンでは出なかった

`InAppSnapshot.elementType` に `UITableViewCell` の分岐が無く(enum の `.cell` は定義だけで到達不能)、
セルが `Other` に落ちていた。XCUITest エンジンは同じ画面で `Cell` を返すため、エンジンを替えると
型セレクタが壊れる。`UITableViewCell` / `UICollectionViewCell` の判定を追加して解消。

### (解消済み 2026-07-23)SUT 跨ぎの inapp 連続実行ハザード

かつて `E2E`(com.ftester.e2e)と `E2E-iOS`(com.ftester.e2e.ios)の inapp を同じシミュレータ群で
連続実行すると、後から回した方が「ブリッジ接続不能(The request timed out)」で大量に落ちた
(実測 14/20 失敗)。根本原因は **provisioner の inapp 再利用判定が注入先アプリを見ていなかった**こと:

別アプリのブリッジを掴む → 最初のシナリオが対象アプリを前面化した時点で旧アプリが suspend →
probe 無応答 → フォールバックが「注入先 = 今回のアプリ」と誤認 → 旧アプリが握ったままのポートで
relaunch → bind 失敗 → 以降のリクエストは suspend した旧ブリッジへ(TCP 受理・HTTP 無応答)。

現在は再利用を「同じアプリに注入済み」のときだけに限定し、別アプリの旧ブリッジは provision 時に
simctl terminate する(ログに「別アプリに注入された in-app ブリッジ(port N)を終了して起動し直します」
と出る)。手動の terminate は不要になった。A→B / B→A の両方向で検証済み。

## シナリオ一覧

| ファイル | 検証する ftester 機能 |
|---|---|
| `01_起動と画面遷移.swift` | `launchApp` / タブ切替 / 下位画面遷移+`戻る` / タブ切替でスタックを持ち越さないこと |
| `02_セレクタ_id指定.swift` | `#id` セレクタと結果 echo の完全一致検証 |
| `03_セレクタ_ラベルと部分一致.swift` | ラベルセレクタの完全一致優先→部分一致フォールバック契約 |
| `04_セレクタ_型と序数.swift` | `.Type[n]` / `.Type#id` / `.Type=ラベル` / `\|\|` フォールバック連鎖 |
| `05_テキスト入力.swift` | `type` と入力値 echo。UIKit 入力欄の型分化(`.SecureTextField`)も引く |
| `06_ジェスチャ.swift` | `tap` 連打 / `press`(長押し)と通常タップの区別 / `swipe` 4方向 |
| `07_スクロール.swift` | `scrollTo` と「`exist`/`textIs` は非スクロール」の契約。`.Cell=行 03` のラベル解決 |
| `08_待機とタイムアウト.swift` | 暗黙待ち(既定タイムアウト再試行)と `timeout:` 引数 |
| `09_条件分岐とダイアログ.swift` | `ifCanSelect` と `optional:`。UIAlertController のボタン id 解決 |
| `10_ライフサイクルとコントロール.swift` | `relaunchApp` によるプロセス内/永続状態の分離、Switch/ラジオ/Slider の状態遷移 |

## `_disabled/`(通常実行に含めない)

**`_disabled/` は SPM のビルド対象外**(`Package.swift` の `exclude`)。回すときは
`Scenarios/` 直下へ移動 → `swift build --product ftester-scenarios-E2E-iOS` → 実行 → 元に戻す。

- `90_自己修復.swift` — FM 必須。`ios-heal` プロファイルで実行。**未検証**(検証時点で FM が
  `SensitiveContentAnalysisML error 15` で不通のため。シナリオ側の機構〈schema を v2 に切り替えて
  `#btn_heal_v1` が解決不能になる〉までは動作確認済み)
- `91_クラッシュ検知.swift` — アプリを実際にクラッシュさせる破壊的シナリオ。**`ios-inapp` で回すこと**。
  **2026-07-23 検証済み**: `fatalError` でプロセスが落ち、エラー行に `.ips` のパスと終了理由
  (`EXC_BREAKPOINT SIGTRAP`)が付く。この検証で ftester 側のバグを2件発見・修正した
  (`.ips` の探索が早すぎて取りこぼす / 前の実行の古い `.ips` を拾う)

## 注意

- **ダイアログ見出しに id は付かない**。`exist("確認")` とラベルで引く。
  `.accessibilityIdentifier` を title にも message にも付けたが両方とも捨てられた(実測)
- `04` の `.Button[6]` は実スナップショットで採取した値。序数は「見えている同型要素のツリー順」で
  スクロール位置と画面クロム(戻る・下部タブ)に依存する。レイアウトを変えたら採取し直す
- テキスト入力画面はスクロールさせない。ソフトキーボードに覆われると `exist`/`textIs` の
  可視性判定が偽陽性(occlusion)で落ちる(Compose 版と同じ制約)
