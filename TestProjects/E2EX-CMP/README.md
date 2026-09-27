# TestProjects/E2EX-CMP

Compose Multiplatform の**固有部品**(共通契約の SUT に載らない Material3 の定番部品)を確かめる E2E。
対象アプリは `E2EXAppCMP/`(bundle id / package = `com.ftester.e2ex`)。testTag・echo の唯一の正は
`E2EXAppCMP/docs/ui-contract.md`。利用者向けの書き方の正典は `docs/user-docs/in_action/ui_component_patterns_ja.md`。

- `01`〜`15`: 部品ごとの推奨の書き方(利用者のシナリオの実例を兼ねる)
- `90_不具合の回帰.swift`: ここで見つけて直したツールの不具合の回帰テスト(S0020 の iOS XCUITest だけ未修正で赤)

```sh
Scripts/e2ex.sh                 # iOS(in-app = 既定エンジン)と Android。SUT はソースが新しければ再ビルド
Scripts/e2ex.sh --ios-xcuitest  # iOS だけを XCUITest エンジンで
Scripts/e2ex.sh --rebuild       # SUT を必ず再ビルド
```

プロファイルは手元の3台だけ(スクリプトは常に `--runner local`。`Scripts/e2e.sh` の対象外)。
