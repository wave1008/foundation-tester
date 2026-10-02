# TestProjects/E2EX-iOS

各フレームワークの**定番部品**を確かめる E2E(E2EX)の iOS 版。対象アプリは `E2EXAppIOS/`。画面・`#id`・echo の契約は
`E2EXAppCMP/docs/ui-contract.md` と `ui-contract-wave2.md`、この SUT の差分は `E2EXAppIOS/docs/ui-contract.md`。
利用者向けの書き方の正典は `docs/user-docs/reference/writing/ui_component_patterns_ja.md`。

- `@Draft("既知の制約: …" / "調査中: …")` のシナリオはツールの制約に当たるもの(既定の実行から外れる。名指しで回すと再現する)
- 回すのは `Scripts/e2ex.sh`(プロファイルは -01〜-08 の8台。同名のデバイスが各機にあるので `--on M1Ultra` でも同じプロファイルで回る)
