# TestProjects/E2EY-RN

実アプリで頻出する画面の作り(入れ子スクロール・反転チャット・読み込みの状態・スワイプの操作 等 12 画面)を
React Native で確かめる E2E(E2EY)の RN 版。対象アプリは `E2EYAppRN/`。画面・`#id`・echo の契約は
`E2EYAppCMP/docs/ui-contract.md`、この SUT の差分は `E2EYAppRN/docs/ui-contract.md`。
利用者向けの書き方の正典は `docs/user-docs/reference/writing/ui_component_patterns_ja.md`。

- シナリオ: `01_ナビゲーション`(ホームから 12 画面へ行って戻る)+ 画面ごとに 1 ファイル(`51`〜`62`)。
  各ファイルの冒頭コメントが「確かめる癖」(その画面の罠)
- `@Draft("既知の制約: …" / "調査中: …")` のシナリオはツールの制約に当たるもの(既定の実行から外れる。名指しで回すと再現する)
- 回すのは `Scripts/e2ey.sh`(プロファイルは -01〜-08 の8台。同名のデバイスが各機にあるので `--on M1Ultra` でも同じプロファイルで回る)
