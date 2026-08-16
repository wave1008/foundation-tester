# TestProjects/E2E-iOS

ftester を **iOS ネイティブアプリ(SwiftUI + UIKit)** に対して検証する E2E テストプロジェクト。
対象アプリはリポジトリ同梱の `E2EAppIOS/`(bundle id = `com.ftester.e2e.ios`)。

- 画面構成・`#id`・ラベルの正: `E2EAppCMP/docs/ui-contract.md`(Compose 版と共通)
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

**launchApp を減らすため、同じ launch 文脈を共有できる軽量シナリオは1 @Test 内の連続 scene に
統合してある**(2026-08-08。旧シナリオ境界は `tap("#tab_home")`+再遷移。scene タイトルの
`S00x0:` 接頭辞が旧シナリオ ID)。重量級と検出器(01 の起動着地・05_スクロール の S0060/S0080/S0090/S0100・
06_待機とタイムアウト の S0020・08_ライフサイクルとコントロール の S0010/S0030・
10_イレギュラーハンドラ・11_WebView)は独立のまま。

| ファイル | 検証する ftester 機能 |
|---|---|
| `01_起動と画面遷移.swift` | `launchApp` / タブ切替 / 下位画面遷移+`戻る` / タブ切替でスタックを持ち越さないこと |
| `02_セレクタ画面.swift` | `#id`・ラベル一致規則・`.Type[n]` 系・`\|\|` フォールバック・フィルタ OR・対称アサーション(旧 02/03/04/16 を統合) |
| `03_テキスト入力.swift` | `type` と入力値 echo・`.SecureTextField`・`clearInput`・キーボード表示検証・pressEnter/IME(旧 18 を統合) |
| `04_ジェスチャ.swift` | `tap` 連打 / `press` / `swipe` 4方向 / `swipePointToPoint` / ピンチ・ダブルタップ・斜めドラッグ(旧 22 を統合) |
| `05_スクロール.swift` | `scrollTo`・`swipeElementToElement`・`notExist(scroll:)`・scrollFrame・Shirates 準拠スクロール(旧 14.S0010/16.S0020/S0030 を統合)。S0060/S0080/S0090/S0100 は独立 |
| `06_待機とタイムアウト.swift` | 暗黙待ちと `timeout:`・セレクタ拡張・appIs/screenshot/waitForDisplay/verify(旧 12/21.S0010 を統合) |
| `07_条件分岐とダイアログ.swift` | ダイアログ操作・`ifCanSelect`・`repeatWhileCanSelect`・`waitForClose`(旧 14.S0020/21.S0060 を統合) |
| `08_ライフサイクルとコントロール.swift` | `restartApp` のプロセス内/永続分離・コントロール状態・操作可否アサーション(旧 11 を統合)・`clearAppData` |
| `09_ID無し画面.swift` / `10_イレギュラーハンドラ.swift` / `11_WebView.swift` / `12_フリック.swift` | 単独維持(リセット手段が無い画面・setUp ハンドラ・重量級) |

## `_disabled/`(通常実行に含めない)

**`_disabled/` は SPM のビルド対象外**(`Package.swift` の `exclude`)。回すときは
`scenarios/` 直下へ移動 → `swift build --product ftester-scenarios-E2E-iOS` → 実行 → 元に戻す。

- `90_自己修復.swift` — FM 必須。`ios-heal` プロファイルで実行。
  **2026-07-23 検証済み**: FM 経路で `#btn_heal_v1` → `#btn_heal_v2||修復対象` に修復、
  2回目はヒールキャッシュ経路(FM 不使用)で通ることを確認
- `91_クラッシュ検知.swift` — アプリを実際にクラッシュさせる破壊的シナリオ。**`ios-inapp` で回すこと**。
  **2026-07-23 検証済み**: `fatalError` でプロセスが落ち、エラー行に `.ips` のパスと終了理由
  (`EXC_BREAKPOINT SIGTRAP`)が付く。この検証で ftester 側のバグを2件発見・修正した
  (`.ips` の探索が早すぎて取りこぼす / 前の実行の古い `.ips` を拾う)

## 注意

- **ダイアログ見出しに id は付かない**。`exist("確認")` とラベルで引く。
  `.accessibilityIdentifier` を title にも message にも付けたが両方とも捨てられた(実測)
- `02_セレクタ画面` の `.Button[6]` は実スナップショットで採取した値。序数は「見えている同型要素のツリー順」で
  スクロール位置と画面クロム(戻る・下部タブ)に依存する。レイアウトを変えたら採取し直す
- テキスト入力画面はスクロールさせない。ソフトキーボードに覆われると `exist`/`textIs` の
  可視性判定が偽陽性(occlusion)で落ちる(Compose 版と同じ制約)
