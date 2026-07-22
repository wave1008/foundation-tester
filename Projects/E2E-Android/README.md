# Projects/E2E-Android

ftester を **Android ネイティブアプリ(View/XML + 一部 Compose)** に対して検証する E2E テスト
プロジェクト。対象アプリはリポジトリ同梱の `E2EAppAndroid/`(package = `com.ftester.e2e.android`)。

- 画面構成・`#id`・ラベルの正: `E2EApp/docs/ui-contract.md`(Compose 版と共通)
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

| ファイル | 検証する ftester 機能 |
|---|---|
| `01_起動と画面遷移.swift` | `launchApp` / タブ切替 / 下位画面遷移+`戻る` / タブ切替でスタックを持ち越さないこと |
| `02_セレクタ_id指定.swift` | `#id` セレクタと結果 echo の完全一致検証 |
| `03_セレクタ_ラベルと部分一致.swift` | ラベルセレクタの完全一致優先→部分一致フォールバック契約 |
| `04_セレクタ_型と序数.swift` | `.Type[n]` / `.Type#id` / `.Type=ラベル` / `\|\|`。**同一アプリ内で View=`Button` / Compose=`Cell`** の食い違い |
| `05_テキスト入力.swift` | `type` と入力値 echo。`SecureTextField` はパスワード欄だけ |
| `06_ジェスチャ.swift` | `tap` 連打 / `press`(長押し)と通常タップの区別 / `swipe` 4方向 |
| `07_スクロール.swift` | `scrollTo`(RecyclerView)と「`exist`/`textIs` は非スクロール」の契約 |
| `08_待機とタイムアウト.swift` | 暗黙待ち(既定タイムアウト再試行)と `timeout:` 引数 |
| `09_条件分岐とダイアログ.swift` | `ifCanSelect` と `optional:`。カスタムビュー AlertDialog の id 解決 |
| `10_ライフサイクルとコントロール.swift` | `relaunchApp` によるプロセス内/永続状態の分離、Compose コントロールの状態遷移 |

## 注意

- **同じアプリの中で型語彙が変わる**。View の Button は `Button`、Compose の Button は `Cell`。
  型セレクタは「どの画面か」まで意識して書く
- 行ラベル「行 03」は Cell と StaticText の2要素に出る(`importantForAccessibility="no"` では
  消えない)。ラベル指定は型限定 `.Cell=行 03` で一意化する
- `#row_NN` は `res/values/ids.xml` の静的 id。行を増減したら ids.xml と `RowAdapter.ROW_IDS` を同時に直す
