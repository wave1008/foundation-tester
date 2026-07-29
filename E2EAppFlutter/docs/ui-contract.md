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
→ Slider だけは `Semantics(identifier: ...)` 単体で包む(型は `other` になる)。

### B. 型語彙が OS で非対称

| 要素 | iOS | Android |
|---|---|---|
| ボタン(`button: true` を持つノード) | `button` | `button` |
| **テキスト** | `staticText` | `staticText`(2026-07-26 の正規化以降。葉+contentDesc を写像。それ以前は `other`) |
| `Switch` | `switch` | `switch` |
| `Checkbox` | `switch` | (同左) |
| `Radio` | `button` | (同左) |
| `Slider`(A の理由で素の Semantics) | `other` | `other` |
| `TextField`(`obscureText` 含む) | `textField` | `textField` |

Flutter は canvas 描画で Android 側の className が `android.view.View` のままになるため、
ブリッジが **葉 + contentDesc → `staticText`** の規則で写像している(docs/design.md §10)。
→ 型セレクタは `button` / `switch` / `staticText` / `textField` が使える。
→ **id の無いテキストもスナップショットに出る**(2026-07-26 以降)。ラベルをアンカーにした
  方向セレクタが Android でも使える(`Projects/E2E-Flutter/Scenarios/13_ID無し画面.swift`)。
→ `obscureText: true` は **`secureTextField` にならない**(ネイティブ SUT と違い型で区別できない)。
→ **iOS の in-app エンジンではテキスト欄は `other`**(Flutter のフィールドは UITextField ではないため。
  `#id` 指定なら両エンジン同一に動く)。

### C. リストの行はデフォルトで `staticText`

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

### H2. iOS の IME アクション(`#txt_ime_action`)は engine の私有 API へ配送している

**`insertText:@"\n"` は使えない**(2026-07-28 実測): Flutter engine は改行を握り潰し、
**文字として挿入もされず**(`len` が増えない)**アクションも出ない**。
`FlutterTextInputView` は `UITextField` 派生ではないので `FTPressEnterOnComposeFirstResponder` の
UIKit 除外にも当たらず、そのままでは 200 が返って**成功に見えるのに何も起きない**という最悪の形になる。

そこで in-app は engine の配送口を直接呼ぶ(`InAppInput.m` の `ftFlutterPerformInputAction`):

- `[view textInputDelegate]` → `flutterTextInputView:performAction:withClient:` に
  `[view textInputClient]` を添えて送る(いずれも `FlutterTextInputView` の getter が実在)
- アクション値は `view.returnKeyType`(UIKit の**公開** enum)から逆写像する。engine 側が Dart の
  `textInputAction` から `returnKeyType` を作っているため復元になる。**未知の値は写像せず失敗扱い**
- **私有 API なので各段で存在確認し、1つでも欠けたら 409 に縮退する**(推測で続行しない)。
  Flutter 更新で壊れたらシナリオ 18 が赤くなる ―― それが唯一の検知手段

**xcuitest フォールバックは hybrid では効かない**: in-app の合成タッチが立てたフォーカスに
XCUITest から到達できない(`hasKeyboardFocus` の要素が見つからず `typeText("\n")` が無言 no-op)。
だから in-app 側で完結させる必要がある。engine=xcuitest 単独なら最初から XCUITest が
タップ・入力するので従来どおり発火する。

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
→ 3番目の『項目』= `.button[6]`。**iOS/Android 両方で同じ並び**であることを実測で確認済み。

### WebView 画面(SUT 固有の実測)

- `webview_flutter` を platform view として合成する。**iOS/Android とも中身は見える**が、
  初回表示が 4 SUT で最も遅い(**Android 実測 約8秒**)。シナリオは `timeout:` を長めに取る。
- iOS のコンテナ identifier は Flutter が付ける `platform_view[0]`(SUT 固有なので当てにしない。
  `.webView` 型で指す)。
- **iOS in-app では DOM 経路を使わない**。platform view が合成タッチと `insertText` を横取りし、
  読めても操作が届かないため(2026-07-29 実測: 入力が Web の input に入らない)。
  in-app/hybrid では WebView 画面だけ XCUITest へ委譲される。

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
