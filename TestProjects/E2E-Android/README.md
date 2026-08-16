# TestProjects/E2E-Android

ftester を **Android ネイティブアプリ(View/XML + 一部 Compose)** に対して検証する E2E テスト
プロジェクト。対象アプリはリポジトリ同梱の `E2EAppAndroid/`(package = `com.ftester.e2e.android`)。

- 画面構成・`#id`・ラベルの正: `E2EAppCMP/docs/ui-contract.md`(Compose 版と共通)
- Android ネイティブ固有の差分(型語彙・7つの罠): `E2EAppAndroid/docs/ui-contract.md`

## 対象アプリのビルド

```sh
cd E2EAppAndroid
./scripts/build-android.sh    # → dist/android/ft-e2e-android-debug.apk
```

## 実行

```sh
ftester run --project E2E-Android --profile android
```

全シナリオが `platform: "android"` 固定(SUT が Android 専用のため)。

## 実測(2026-07-23・M2 Ultra・Pixel 9/Android 15 × 8)

| プロファイル | 結果 | 壁時計 |
|---|---|---|
| `android` | ✅ 21/21 | 38.8s |

## シナリオ一覧

**同じ画面・同じ導入(`launchApp`+ナビ)から始まる軽量シナリオは1 @Test の連続 scene へ
統合してある**(2026-08-08。旧シナリオ境界は `tap("#tab_home")`(入力系は `hideKeyboard()` を
前置)+再遷移。scene タイトルの `S00x0:` 接頭辞が旧シナリオ ID)。重量級(05_スクロール の
S0060/S0080/S0090/S0100)と独立維持のもの(06_待機とタイムアウト の S0020・
08_ライフサイクルとコントロール の S0010/S0030・09_ID無し画面・10_イレギュラーハンドラ・
11_WebView・12_フリック)は独立のまま。

| ファイル | 検証する ftester 機能 |
|---|---|
| `01_起動と画面遷移.swift` | `launchApp` / タブ切替 / 下位画面遷移+`戻る` / タブ切替でスタックを持ち越さないこと |
| `02_セレクタ画面.swift` | `#id`・ラベル一致規則・`.Type[n]` 系・`\|\|` フォールバック・フィルタ OR・対称アサーション・View/Compose の型差(旧 02/03/04/16 を統合) |
| `03_テキスト入力.swift` | `type` と入力値 echo・`value*`・`.SecureTextField`・`clearInput`・キーボード表示検証・pressEnter/IME(旧 18 を統合) |
| `04_ジェスチャ.swift` | `tap` 連打 / `press`(長押し)と通常タップの区別 / `swipe` 4方向 / `swipePointToPoint` / ピンチ・ダブルタップ・斜めドラッグ(旧 22 を統合) |
| `05_スクロール.swift` | `scrollTo`(RecyclerView)・「`scroll:` を付けない探索・検証は現在画面のみ」の契約・swipeElementToElement・scrollFrame・Shirates 準拠スクロール(旧 14.S0010/16.S0020/S0030 を統合)。S0060/S0080/S0090/S0100 は独立 |
| `06_待機とタイムアウト.swift` | 暗黙待ち(既定タイムアウト再試行)と `timeout:` 引数・セレクタ拡張(notExist/countIs/相対/スコープ/状態フィルタ)・appIs/screenshot/waitForDisplay/verify(旧 12/21.S0010 を統合)。S0020 は独立 |
| `07_条件分岐とダイアログ.swift` | ダイアログ操作・`ifCanSelect`・back クローズ・`repeatWhileCanSelect`・`waitForClose`(旧 14.S0020/21.S0060 を統合) |
| `08_ライフサイクルとコントロール.swift` | `restartApp` によるプロセス内/永続状態の分離、Compose コントロールの状態遷移・`enabledIsFalse`/`enabledIsTrue`・`checkIsON`/`checkIsOFF`・ブリッジの value 供給(旧 11/24 を統合)。S0010/S0030 は無変更 |
| `09_ID無し画面.swift` / `10_イレギュラーハンドラ.swift` / `11_WebView.swift` / `12_フリック.swift` | 単独維持(リセット手段が無い画面・setUp ハンドラ・重量級) |

## `_disabled/`(通常実行に含めない)

**`_disabled/` は SPM のビルド対象外**(`Package.swift` の `exclude`)。回すときは
`scenarios/` 直下へ移動 → `swift build --product ftester-scenarios-E2E-Android` → 実行 → 元に戻す。

- `90_自己修復.swift` — FM 必須。`--heal` を付けて実行。
  **2026-07-23 検証済み**: FM 経路で `#btn_heal_v1` → `#btn_heal_v2||修復対象` に修復できることを確認
- `91_クラッシュ検知.swift` — アプリを実際にクラッシュさせる破壊的シナリオ。
  **2026-07-23 検証済み**: メインスレッドの未捕捉 RuntimeException でプロセスが落ちる。
  **Android のブリッジは別プロセス(instrumentation)なので切断せず**、iOS inapp のような
  `.ips` 添付も無い。「要素が見つかりません」という形でクラッシュが現れる

## 注意

- **同じアプリの中で型語彙が変わる**。View の Button は `Button`、Compose の Button は `Cell`。
  型セレクタは「どの画面か」まで意識して書く
- 行ラベル「行 03」は Cell と StaticText の2要素に出る(`importantForAccessibility="no"` では
  消えない)。ラベル指定は型限定 `.Cell=行 03` で一意化する
- `#row_NN` は `res/values/ids.xml` の静的 id。行を増減したら ids.xml と `RowAdapter.ROW_IDS` を同時に直す
