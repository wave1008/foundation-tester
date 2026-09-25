---
paths:
  - "AndroidRunner/**"
  - "AndroidRunner/src/com/example/ftbridge/InputInjector.java"
  - "Sources/FTAndroid/**"
  - "Sources/FTAndroid/AdbInstallVerifier.swift"
  - "Sources/FTAndroid/AndroidBridge.swift"
  - "Sources/FTAndroid/AndroidDriver.swift"
  - "Sources/FTAndroid/AndroidWebViewUpdate.swift"
  - "Sources/FTCore/Shell.swift"
  - "Tests/FTAndroidTests/**"
  - "Tests/FTAndroidTests/AdbInstallVerifierTests.swift"
  - "Tests/FTAndroidTests/AndroidDriverCheckedInt32Tests.swift"
  - "Tests/FTAndroidTests/AndroidDriverTypeSplitTests.swift"
  - "Tests/FTAndroidTests/AndroidWebViewUpdateTests.swift"
  - "Tests/FTAndroidTests/InputInjectorEditableIdUniquenessTests.swift"
  - "Tests/FTCoreTests/ShellSourceScanTests.swift"
  - "Tests/FTCoreTests/ShellTimeoutTests.swift"
---

# Android(Play Protect・テキスト注入) の規律

CLAUDE.md から移した規則(本文は移設前と同一)。この領域のファイルを Read したときに自動で読み込まれる。

- **テストツールはアプリを Google へ送らない・確認も取らない**(ユーザー決定 2026-09-05)。
  Android の `adb install` は Play Protect の照会(「Send app for a security check?」)で無期限に
  止まるので、`AdbInstallVerifier` が install の間だけ `verifier_verify_adb_installs` を 0 にして
  必ず戻す(実機・エミュレータとも)。**門は `AndroidDriver.adb` が引数で掛ける**ので、
  アプリを入れる新しい経路は何もしなくても通る。例外は adb を自分で spawn する bundletool と
  adb 閉包を外から受ける `AndroidWebViewUpdate` だけで、そこは `withVerificationOff` を明示。
  **素の `Shell.run` で adb install を打つコードは `AdbInstallVerifierTests` が落とす**。
  **ダイアログを押す方式にしない**(id 無し・ロケール依存・送信の選択肢が画面に出る)。
  キルスイッチは実行プロファイルの `playProtectBypass: false`(ユーザー決定: 設定タブではなく
  プロファイル)—— OFF でもツールは端末のダイアログに答えない(止まるだけ)
- **Android のテキスト注入(`InputInjector`)を触ったら負荷10周で判定する**
  (`for i in $(seq 10); do Scripts/e2e.sh --cmp --android; done`)。**単独実行では出ない** flake が
  ある(高負荷でだけ約40%)。守る規律 —「`ACTION_SET_TEXT` の `true` は受理であって反映ではない
  (必ず読み返す)」「`combined` は最初の読みから1回だけ作る(パスワード欄の読みはマスクされて
  おり、作り直すと伏せ字を書き込む・二重追記する)」「フォーカスが立つまで撃たない」
  「追跡は座標でなく resource-id」「**読む前に `refresh()` し、その戻り値を見る**(a11y ノードはキャッシュ供給で、
  とくに WebView は DOM 変更を数秒遅れて出す。取り直さないと**入っているのに古い値を
  読み続けて**期限切れで 500 になる。**false は取り直せておらず中身が古いまま**なので、
  その周回は読まず撃たず次周回で引き直す)」「**`findFocus(FOCUS_INPUT)` を信じない**(Flutter では
  半分の確率で欄でなく FlutterView の入れ物を返す。ref なしの clear / IME Enter は
  `focusedEditable` = 編集可能でなければ木から `isFocused && isEditable` を探す。実機 10 周中 5 周)」
  — と不採用案(`ACTION_FOCUS`・ホスト側のキーボード回避)は
  docs/design.md §Android のテキスト注入の規律
