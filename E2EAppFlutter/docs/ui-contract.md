# FT E2E Flutter アプリ UI 契約

**画面構成・`#id`・表示ラベルは `E2EApp/docs/ui-contract.md`(Compose Multiplatform 版)と共通**。
同じシナリオを各 SUT に当てて比較できるよう、値は byte 一致させてある。
このファイルは **Flutter 実装固有の差分だけ**を定義する。
tag 定数は `lib/tags.dart` に集約する(値は共通契約の表と byte 一致)。

- bundle id / applicationId: `com.ftester.e2e.flutter`(他の SUT と共存できる)
- `#txt_about_app` は `app=com.ftester.e2e.flutter`
- シナリオ: `Projects/E2E-Flutter/Scenarios/`(**platform 未指定 = ios/android 両方で回す**)

## Flutter で `#id` を出すための必須設定(2つ)

### 1. `SemanticsBinding.instance.ensureSemantics()`

Flutter の semantics ツリーは**支援技術が要求したときだけ**構築される。`main()` で
`ensureSemantics()` を呼んで常時 ON にしないと、ブリッジから要素が1つも見えない
(= どのセレクタも解決できない)。E2E 用アプリなので恒久的に有効化している(`lib/main.dart`)。

### 2. `Semantics(identifier: ...)` を `MergeSemantics` で畳む

`identifier` は iOS = `accessibilityIdentifier` / Android = `resource-id` にマップされる。
ただし `Semantics` ウィジェットは**それ自体が1ノードを作る**ため、素で包むと
「identifier だけのノード」と「label だけのノード」に割れる。`MergeSemantics` で
1ノードに畳む(`lib/widgets.dart` の `tagged()`)。

## Flutter 固有の罠(すべて実測で踏んだもの)

### A. `Slider` に `MergeSemantics` を被せると **iOS の a11y ツリーが丸ごと空になる**

スナップショットが 0 要素になり、アプリ全体でどのセレクタも解決できなくなる
(画面自体は正常に描画されるので気付きにくい)。Slider は increase/decrease の子ノードを
持つため、畳むとブリッジが読める形にならない。
→ Slider だけは `Semantics(identifier: ...)` 単体で包む(型は `Other` になる)。

### B. 型語彙が OS で非対称

| 要素 | iOS | Android |
|---|---|---|
| ボタン(`button: true` を持つノード) | `Button` | `Button` |
| **テキスト** | `StaticText` | **`Other`** |
| `Switch` | `Switch` | `Switch` |
| `Checkbox` | `Switch` | (同左) |
| `Radio` | `Button` | (同左) |
| `Slider`(A の理由で素の Semantics) | `Other` | `Other` |
| `TextField`(`obscureText` 含む) | `TextField` | `TextField` |

Flutter は canvas 描画で、Android 側の className が `android.view.View` のままになるため
テキストが `StaticText` に写像されない。
→ **型セレクタを使ってよいのは `Button` だけ**。テキストの検証は必ず `#id` + `textIs` で書く。
→ `obscureText: true` は **`SecureTextField` にならない**(ネイティブ SUT と違い型で区別できない)。

### C. リストの行はデフォルトで `StaticText`

`InkWell` は `onTap` アクションを持つだけで button フラグは立たない。
`Semantics(button: true)` を明示しないと行が型で区別できない(`tagged(..., button: true)`)。

### D. `ListView` の `cacheExtent` は 0 にする

既定(250px)だと画面外の先読み行まで semantics に出るうえ、iOS ではその frame が
ビューポート内にクランプされて報告される(design.md §4.6)。すると `scrollTo` が
「まだ画面外の `#row_40` を見つけた」と判断して停止し、続くタップがクランプ座標
(実際には何も無い場所)を叩いて空振りする。

### E. 起動直後の数百 ms はポインタ入力を取りこぼす

a11y ツリーは完成しているのに、最初の tap が**成功扱いのまま黙って無反応**になることがある
(Android で実測)。シナリオ側は `launchApp()` の直後に `exist("#txt_home_marker")` を挟んで
1往復させ、着地を確認してから操作する。

### F. Android の input connection は tap 応答より遅れて張られる

tap 直後に `type` すると 500「ACTION_SET_TEXT を受け付けないフィールドです」で落ちる。
tap と type の間に1往復(`exist`)挟む。

### G. ダイアログはネイティブウィンドウではない

Flutter の `AlertDialog` は Navigator のオーバーレイなので、見出しもボタンも通常の
Semantics として出る → **`#txt_dialog_title` が両 OS で引ける**
(iOS ネイティブ SUT は UIAlertController が id を捨てるため引けない。ここが SUT 間の差)。

### H. `resizeToAvoidBottomInset: false`

キーボードで列が動くと入力欄がキーボード下へ回り込み、ロケータが解決できなくなる
(Compose 版で実測した罠と同じ)。Scaffold で無効化している。

### I. rebuild だけでは `Semantics(identifier:)` の変更が反映されない

状態で identifier を切り替えるウィジェット(自己修復画面の `_schemaV1 ? btnHealV1 : btnHealV2`)は、
**key を付けないと rebuild しても a11y ツリー上の identifier が古いまま**になる
(タップの closure は新しい状態で動くのに、`#btn_heal_v1` が schema=v2 でも解決できてしまう。
2026-07-23 実測)。`key: ValueKey(状態)` でウィジェットごと再生成させて切替を強制する。

## セレクタ画面の序数(シナリオ 04 が依存)

見えている Button のツリー順は他の SUT と**同じ**:
戻る(1) 許可(2) 通知を許可(3) 項目(4,5,6) 共通ラベル(7) 別名(8) 結果クリア(9) タブ(10-12)。
→ 3番目の『項目』= `.Button[6]`。**iOS/Android 両方で同じ並び**であることを実測で確認済み。

## ビルド

```sh
cd E2EAppFlutter
./scripts/build-ios.sh        # → dist/ios-simulator/FTE2EFlutter.app
./scripts/build-android.sh    # → dist/android/ft-e2e-flutter-debug.apk
```

**`flutter build ios --simulator` は使えない**(Flutter 3.44.7 / Xcode 27):
universal(x86_64+arm64)を要求する内部チェックが `lipo` の出力と食い違い、
`Binary .../Flutter.framework/Flutter does not contain architectures "arm64 x86_64"` で必ず落ちる
(lipo では両方入っている)。`scripts/build-ios.sh` は arm64 固定で `xcodebuild` を直接叩いて回避する。
`ios/Runner.xcodeproj` の `IPHONEOS_DEPLOYMENT_TARGET` も 13.0 → 15.0 に上げてある
(Xcode 27 は 15.0 未満をエラーにする)。
