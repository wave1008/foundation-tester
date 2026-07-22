# Projects/E2E

ftester 自身の機能を検証する E2E テストプロジェクト。対象アプリはリポジトリ同梱の
Compose Multiplatform アプリ `E2EApp/`(iOS/Android 両対応、bundle id / package =
`com.ftester.e2e`)。testTag(`#id`)と表示ラベルの唯一の正は `E2EApp/docs/ui-contract.md`。

**同じ画面契約を別の UI フレームワークで実装した SUT が他に3つある**(`#id`・ラベルは同一、
型語彙と id 露出の作法だけが違う。フレームワーク差の退行はこれを跨がないと出ない):
[E2E-iOS](../E2E-iOS/README.md)(SwiftUI+UIKit)/ [E2E-Android](../E2E-Android/README.md)
(View/XML+Compose)/ [E2E-Flutter](../E2E-Flutter/README.md)(Flutter)。
全 SUT をまとめて回すのは `Scripts/e2e.sh`。

## 対象アプリのビルド

```sh
cd E2EApp
./scripts/build-ios.sh       # → dist/ios-simulator/FTE2E.app
./scripts/build-android.sh   # → dist/android/ft-e2e-debug.apk
```

## 実行

```sh
ftester run --project E2E --profile ios        # iPhone 17 Pro(iOS 27.0)・xcuitest エンジン(全件グリーンの基準)
ftester run --project E2E --profile ios-inapp  # 同じ端末を inapp エンジンで(エンジン差分の観測用)
ftester run --project E2E --profile android    # Pixel 9(Android 15)-01
ftester run --project E2E --profile heal       # --heal(_disabled/90 を有効化して回すとき)
```

### iOS のエンジン選択

**in-app エンジンは「時間・移動を伴うジェスチャ」を駆動できない**(tap/type は通るが swipe/press は無反応)。
**これは Compose 固有ではない** — SwiftUI ネイティブでも同じことを 2026-07-23 に `Projects/E2E-iOS` で
実測した(それまで Compose 固有だと誤って記述していた)。両エンジンで同一シナリオを回した実測:

| コマンド | inapp 単体 | xcuitest |
|---|---|---|
| `tap` / `type` | ✅ | ✅ |
| `press`(長押し) | ❌ 無反応(現在は常に 501) | ✅ |
| `swipe` 4方向 | ❌ 無反応(スクロールビューが無い画面は 501) | ✅ |
| `scrollTo`(LazyColumn) | ❌ 何回スワイプしても動かない | ✅ |

原因は合成タッチの品質ではなく2段構え: (1) `/swipe` の主経路は `UIScrollView.contentOffset` の
直接操作で、Compose 画面にある**無関係な UIScrollView** を動かして黙って空振りしていた
(現在はその向きにスクロール余地があるビューだけを対象にし、無ければ 501)。
(2) 合成タッチへ迂回してもジェスチャ認識器は drag/長押しを受理しない(Compose も SwiftUI も)。

**ただし hybrid(`iosInappEngine: true`)では自動でフォールバックする**(2026-07-23)。
hybrid は in-app と XCUITest の両ブリッジを張るので、ジェスチャだけ XCUITest 側へ回せばよい:

- `/status` の `unsupportedActions` 申告(compose は `["swipe","press"]`、uikit は `["press"]`)を
  起動時プローブで見て、該当する操作は**最初から** XCUITest へ回す
- 検出漏れ時は **501**(このエンジンでは未対応)を捕まえて切り替え、以降はラッチして往復を繰り返さない。
  409(キーウィンドウ不在等の一時的競合)では**切り替えない** — 切り替えると「アプリが前面に無い」
  状況を隠して別画面を操作しかねないため
- どちらも効かない構成(engine=inapp 単独・XCUITest ブリッジ無し)でのみ 501 が表面化する
- フォールバックしたステップはレポートに `(XCUITest へフォールバック)` と注記が付く
  (ロケータのフォールバックとは別扱いで、セレクタ更新の提案は出さない)

この結果 **`ios-inapp` も 18/18 で通る**(37.3s。フォールバック導入前は3シナリオが落ちて 93.9s)。
`tap`/`type`/スナップショットは高速な in-app のまま、ジェスチャだけが XCUITest 経由になる。
詳細は docs/design.md §10 の知見。

### 両OSで回すときは `ios` と `android` を別々に実行する

**両OSのデバイスを1つの実行プロファイルに並べても、片方の OS でしか走らない。**
シナリオの振り分けは **platform 別の静的分配**で、空いたレーンが取りに行く仕組みではない:

- `ProfileRunner` は「iOS デバイスが1台でもあれば」既定 platform を `ios` にする
- `RunOrchestrator` は `@TestClass` の `platform:` 未指定シナリオを**その既定 platform のキューにだけ**入れる
- 自分の platform のキューが無いワーカーは**1本も受け取らずに終わる**

E2E のシナリオは全て `@TestClass(app: "com.ftester.e2e")` で `platform:` を持たない(=両OS共通で
書いてある)ため、両OS混在のプロファイルでは全 18 本が iOS キューに入り、Android エミュレータは
起動されるだけで空回りする。実測でもレポート 18 件すべて `platform: ios` だった。
シナリオ数や負荷には依存しない決定的な挙動(規則は docs/design.md §11.4)。

そのため**このプロジェクトに `all` プロファイルは置かない**(かつて置いていたが、`ios` と同じ結果に
なるうえ Android を無駄に起動するだけだったので削除した)。両OSのカバレッジは
`--profile ios` と `--profile android` の2回実行で担保する。

## 実測(2026-07-22・M2 Ultra)

| プロファイル | 結果 | 壁時計 |
|---|---|---|
| `ios`(xcuitest・iPhone 17 Pro/iOS 27.0) | ✅ 18/18 | 176s |
| `android`(Pixel 9/Android 15) | ✅ 18/18 | 82s |
| `ios-inapp` | ❌ 3件失敗(既知。上表のエンジン差分) | — |

## シナリオ一覧

| ファイル | 検証する ftester 機能 |
|---|---|
| `01_起動と画面遷移.swift` | `launchApp` / タブ切替 / 下位画面遷移+`戻る` / タブ切替時にスタックが持ち越されないこと |
| `02_セレクタ_id指定.swift` | `#id` セレクタと結果 echo の完全一致検証 |
| `03_セレクタ_ラベルと部分一致.swift` | ラベルセレクタの完全一致優先→部分一致フォールバック契約 |
| `04_セレクタ_型と序数.swift` | `.Type[n]` / `.Type#id` / `.Type=ラベル` / `\|\|` フォールバック連鎖(序数は下記の注意を参照) |
| `05_テキスト入力.swift` | `type` と入力値 echo(単一行/パスワード/送信/クリア) |
| `06_ジェスチャ.swift` | `tap` 連打 / `press`(長押し)と通常タップの区別 / `swipe` 4方向 |
| `07_スクロール.swift` | `scrollTo` と「`exist`/`textIs` は非スクロール」の契約 |
| `08_待機とタイムアウト.swift` | 暗黙待ち(既定タイムアウト再試行)と `timeout:` 引数 |
| `09_条件分岐とダイアログ.swift` | `ifCanSelect` と `optional:` |
| `10_ライフサイクルとプラットフォーム分岐.swift` | `relaunchApp` によるプロセス内/永続状態の分離、`ios {}` / `android {}` |

## `_disabled/`(通常実行に含めない)

**`_disabled/` は SPM のビルド対象外**(`Package.swift` の `exclude`)。回すときは
`Scenarios/` 直下へ移動 → `swift build --product ftester-scenarios-E2E` → 実行 → 元に戻す。

- `90_自己修復.swift` — FM 呼び出しを要するため通常実行には載せない。`heal` プロファイルで実行。
  **2026-07-22 検証済み**: FM 経路(14.5s)で `#btn_heal_v1` → `#btn_heal_v2||修復対象` に修復し、
  2回目はヒールキャッシュ経路(7.9s・FM 不使用)で通ることを確認。
- `91_クラッシュ検知.swift` — アプリを実際にクラッシュさせる破壊的シナリオ。**`ios-inapp` で回すこと**
  (クラッシュレポート添付は inapp 固有。xcuitest はブリッジが別プロセスなので切断しない)。
  **2026-07-22 検証済み**: エラー行に `.ips` のパスと終了理由が付くことを確認。

この2本の検証で ftester 側のバグを2件発見・修正した(FM rationale へのトランスクリプト混入、
操作起因クラッシュでレポートが添付されない件)。

## 注意

- `04_セレクタ_型と序数.swift` の `.Button[6]` / `.Cell[6]` は **両 OS の実スナップショットで採取した値**。
  `.Type[n]` は「見えている同型要素のツリー順」で、圧縮スナップショットが画面外を含まないため
  **スクロール位置と画面クロム(戻る・下部タブ)に依存する**。レイアウトを変えたら採取し直す
  (序数の並び自体は iOS/Android で一致した)。
- テキスト入力画面は、検証対象(echo)と操作対象(送信/クリア)を**すべて入力欄より上**に置き、
  さらに**スクロールさせない**。下に置くとソフトキーボードに覆われて `exist`/`textIs` の可視性判定
  (requireVisible 既定 true)が「偽陽性(occlusion)」で落ち、スクロール可だとフォーカス時の
  bringIntoView で次の入力欄がキーボード下へ回り込み「ロケータを解決できません」になる(両方実測)。
- **Android で発覚した罠2つ**(いずれもアプリ側で吸収済み):
  1. 要素の**型名が OS で異なる**。Compose の Button は iOS = `Button` / Android = `Cell`。
     型を使うセレクタは `ios {}` / `android {}` で分ける(`#id` とラベルは共通)。
  2. **ダイアログは別ウィンドウ**に描画されるため、App ルートの `exposeTestTagsAsResourceId()` が
     届かず Android だけダイアログ内の `#id` が全滅する。`AlertDialog(modifier = ...)` に再適用が必須。
- ジェスチャ画面は `#pad_swipe` を画面いっぱいに敷き、その上に要素を重ねている。`swipe` は要素を狙わず
  画面全体を払う形で撃たれるため(iOS=XCUITest の swipeUp() 等 / Android=縦 0.3h↔0.7h の固定座標)、
  パッドが小さいと始点が外れる。
  詳細は `E2EApp/docs/ui-contract.md` §ジェスチャ画面。
