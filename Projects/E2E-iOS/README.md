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
| `ios-inapp` | ❌ 2件失敗(**既知・下記の ftester 側の穴**) | 55.1s |

## `ios-inapp` で判明した ftester 側の穴(2026-07-23)

この SUT を作って初めて見えた2点。**どちらも Compose 固有ではなく、SwiftUI ネイティブでも起きる**。

### 1. in-app のジェスチャ空振りが hybrid でフォールバックされない

`press` / `swipe` は 200 を返して成功扱いになるが、SwiftUI の `onLongPressGesture` /
`DragGesture` は発火しない(`tap` は合成タッチで通る)。CMP 版と同じ症状だが、
**hybrid の XCUITest フォールバックが働かない**:

- `InAppBridge.swift` は `unsupportedActions` の申告も 501 の返却も
  **`uiFramework == "compose"` のときだけ**行う(bundle 内の Kotlin フレームワーク有無で判定)
- SwiftUI ネイティブは `uiFramework != "compose"` なので申告も 501 も出ず、
  ホストは「成功した」と解釈してフォールバックしない → **黙って空振りする**

つまり `Projects/E2E/README.md` の「Compose Multiplatform の iOS では in-app が…」という
記述は範囲が狭すぎで、実際は **in-app の合成タッチが時間・移動を伴うジェスチャを
駆動できない**(フレームワーク非依存)のが根。修正するなら 501 の条件を
`uiFramework` ではなくアクション種別(swipe/press)そのものに広げる話になる。

### 2. `.Cell` 型が in-app エンジンでは出ない

`.Cell=行 03` が解決できず失敗する。`InAppSnapshot.elementType` には
`UITableViewCell` を判定する分岐が無く(enum の `.cell` は定義だけで到達不能)、
セルは `Other` に落ちる。XCUITest エンジンは同じ画面で `Cell` を返すため、
**エンジンを替えると型セレクタが壊れる**。

→ 当面 `ios-xcuitest` を基準とし、`ios-inapp` はこの2点の観測用に残す。

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

## 注意

- **ダイアログ見出しに id は付かない**。`exist("確認")` とラベルで引く。
  `.accessibilityIdentifier` を title にも message にも付けたが両方とも捨てられた(実測)
- `04` の `.Button[6]` は実スナップショットで採取した値。序数は「見えている同型要素のツリー順」で
  スクロール位置と画面クロム(戻る・下部タブ)に依存する。レイアウトを変えたら採取し直す
- テキスト入力画面はスクロールさせない。ソフトキーボードに覆われると `exist`/`textIs` の
  可視性判定が偽陽性(occlusion)で落ちる(Compose 版と同じ制約)
