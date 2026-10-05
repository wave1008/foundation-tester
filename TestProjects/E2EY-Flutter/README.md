# TestProjects/E2EY-Flutter

実アプリで頻出し、ツールの判定(容器の推定・端の判定・待ち・遮蔽・入力の読み返し)を直撃する画面の作りを
確かめる E2E(E2EY)の Flutter 版。対象アプリは `E2EYAppFlutter/`。画面・`#id`・echo の契約は
`E2EYAppCMP/docs/ui-contract.md`、この SUT の差分は `E2EYAppFlutter/docs/ui-contract.md`。
利用者向けの書き方の正典は `docs/user-docs/reference/writing/ui_component_patterns_ja.md`。

- シナリオは画面ごとに1ファイル(`51`〜`62`)+ `01_ナビゲーション.swift`。各ファイル冒頭に「確かめる癖」
- `@Draft("既知の制約: …" / "調査中: …")` のシナリオはツールの制約に当たるもの(既定の実行から外れる。名指しで回すと再現する)
- 回すのは `Scripts/e2ey.sh`(プロファイルは -01〜-08 の8台。同名のデバイスが各機にあるので `--on M1Ultra` でも同じプロファイルで回る)
