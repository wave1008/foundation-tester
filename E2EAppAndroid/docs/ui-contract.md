# FT E2E Android ネイティブアプリ UI 契約

**画面構成・`#id`・表示ラベルは `E2EApp/docs/ui-contract.md`(Compose Multiplatform 版)と共通**。
同じシナリオを各 SUT に当てて比較できるよう、値は byte 一致させてある。
このファイルは **Android ネイティブ実装(View/XML + 一部 Compose)固有の差分だけ**を定義する。

- applicationId: `com.ftester.e2e.android`(Compose 版 `com.ftester.e2e` と共存できる)
- `#txt_about_app` は `app=com.ftester.e2e.android`
- シナリオ: `Projects/E2E-Android/Scenarios/`

## 実装方式(どこが View で、どこが Compose か)

**同じアプリの中で View と Compose を同居させる**のがこの SUT の核。型語彙が画面ごとに変わる。

| 画面 | 実装 | ツリー上の型 |
|---|---|---|
| コントロール | `ComposeView`(material3) | Switch/Button → `Cell`、Checkbox/RadioButton → `CheckBox`、Slider → `Slider` |
| スクロール | `RecyclerView` + clickable な行 ViewGroup | `CollectionView` + `Cell` |
| テキスト入力 | `EditText` | `TextField` / `SecureTextField`(password のみ) |
| それ以外 | View/XML | `Button` / `StaticText` / `Switch` / `ScrollView` |

## 実スナップショットで採取した型(2026-07-23・Pixel 9/Android 15)

| 要素 | 型 | 備考 |
|---|---|---|
| `android.widget.Button` | `Button` | View 側のボタん全部 |
| `TextView` | `StaticText` | |
| `EditText`(通常) | `TextField` | `textMultiLine` も `TextField`(iOS ネイティブは `TextView` になる) |
| `EditText`(textPassword) | `SecureTextField` | |
| `SwitchCompat` | `Switch` | ダイアログ画面・自己修復画面 |
| Compose `Switch` / `Button` | **`Cell`** | className が android.widget.* にならず既定 clickable 側に落ちる |
| Compose `Checkbox` / `RadioButton` | `CheckBox` | ラジオも `CheckBox` に丸められる |
| Compose `Slider` | `Slider` | |
| `RecyclerView` | `CollectionView` | |
| 行(clickable ViewGroup) | `Cell` | |

### セレクタ画面の序数(シナリオ 04 が依存)

見えている Button のツリー順は Compose 版・iOS ネイティブ版と**同じ**:
戻る(1) 許可(2) 通知を許可(3) 項目(4,5,6) 共通ラベル(7) 別名(8) 結果クリア(9) タブ(10-12)。
→ 3番目の『項目』= `.Button[6]`。

## Android 固有の罠(すべて実測で踏んだもの)

### 1. View は resource-id を実行時生成できない

Compose の `testTag` に相当する仕組みが View 系には無い。動的リスト(`#row_01`..`#row_40`)は
**`res/values/ids.xml` に静的宣言**し、`onBindViewHolder` で `view.id = R.id.row_NN` を割り当てる。
これを忘れると行は `#id` を一切持たない。

### 2. ComposeView の中だけ `testTagsAsResourceId` が要る

View 側は `android:id` が自動的に resource-id として出るが、ComposeView の中は
`Modifier.semantics { testTagsAsResourceId = true }` を立てないと `#id` が全滅する
(ラベルは引ける)。ルートで1回立てれば子孫全体に効く。

### 3. `importantForAccessibility="no"` では消えない

ブリッジの UiAutomation は not-important view も含めて走査するため、行内の TextView は
`importantForAccessibility="no"` を付けても `StaticText` としてツリーに残る。
結果として行ラベル「行 03」は **Cell と StaticText の2要素**に出る。
→ ラベル指定は**型限定**(`.Cell=行 03`)で一意化する契約にしてある。

### 4. 縦 LinearLayout の `layout_weight` は幅に効かない

ジェスチャ画面で「幅 45%」を作ろうとして縦 LinearLayout に `layout_width="0dp"` +
`layout_weight` を書くと、幅が 0 のままになり **要素がスナップショットから丸ごと消える**
(幅 2px 未満はフィルタで除外)。幅の比率は**横**の LinearLayout + `weightSum` で作る。

### 5. AlertDialog の既定ボタンは id を持てない

`setPositiveButton` のボタンは resource-id が `android:id/button1` / `button2` になり
`#btn_dialog_ok` を引けない。**`setView` に自前の id 付きレイアウトを載せる**
(`res/layout/dialog_confirm.xml`)。別ウィンドウでも View の resource-id はそのまま出るため、
`#txt_dialog_title` も引ける(iOS ネイティブは UIAlertController が id を捨てるのでここが OS 差)。

### 6. savedInstanceState は捨てる

`MainActivity.onCreate` は `super.onCreate(null)` を呼ぶ。渡すと Android が View 階層の状態
(EditText の文字列など)まで復元し、`relaunchApp` 後の初期状態が前回実行に汚染される。
EditText 側にも `android:saveEnabled="false"` を付けてある。

### 7. ダイアログ表示中は `screen` が別ウィンドウのサイズになる

ダイアログを開いた状態のスナップショットは `screen: 1024x427` のようにダイアログ側の
ウィンドウ寸法を返す。座標系は絶対座標のままなので tap には影響しないが、
画面比率で撃つ `swipe` をダイアログ表示中に使ってはいけない。

## ビルド

```sh
cd E2EAppAndroid
./scripts/build-android.sh    # → dist/android/ft-e2e-android-debug.apk
```
