# TestProjects/E2EX-CMP

Compose Multiplatform の**固有部品**(共通契約の SUT に載らない Material3 の定番部品)を確かめる E2E。
対象アプリは `E2EXAppCMP/`(bundle id / package = `com.ftester.e2ex`)。testTag・echo の唯一の正は
`E2EXAppCMP/docs/ui-contract.md`。利用者向けの書き方の正典は `docs/user-docs/in_action/ui_component_patterns_ja.md`。

- `01`〜`15`: 部品ごとの推奨の書き方(利用者のシナリオの実例を兼ねる)
- `90_不具合の回帰.swift`: ここで見つけて直したツールの不具合の回帰テスト(S0020 の iOS XCUITest だけ未修正で赤)

```sh
E2EXAppCMP/scripts/build-ios.sh       # → dist/ios-simulator/FTE2EX.app
E2EXAppCMP/scripts/build-android.sh   # → dist/android/ft-e2ex-debug.apk
fleetest run --project E2EX-CMP --profile ios-inapp --runner local      # iOS 既定エンジン(hybrid)
fleetest run --project E2EX-CMP --profile ios-xcuitest --runner local   # iOS XCUITest
fleetest run --project E2EX-CMP --profile android --runner local
```

プロファイルは手元の3台だけ(`Scripts/e2e.sh` の対象外)。
