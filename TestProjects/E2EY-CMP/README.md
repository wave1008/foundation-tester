# TestProjects/E2EY-CMP

Compose Multiplatform で作った E2EY(実アプリで頻出し、ツールの判定 —— 容器の推定・端の判定・待ち・遮蔽・入力の読み返し ——
を直撃する画面の作り)の E2E。対象アプリは `E2EYAppCMP/`(bundle id / package = `com.ftester.e2ey`)。
画面・`#id`・echo の唯一の正は `E2EYAppCMP/docs/ui-contract.md`(CMP の部品と逸脱は末尾「CMP の実装」)。
書き方の正典は `docs/user-docs/reference/writing/ui_component_patterns_ja.md`。

- `01_ナビゲーション.swift`: ホームの 12 行から各画面へ入って戻る
- `51`〜`62`: 画面ごとに 1 本(入れ子スクロール・反転チャット・読み込みの状態・スワイプの操作・選択モード・文中リンク・
  PIN と OTP・戻るの横取り・引き伸ばせるシート・スクロールで隠れるバー・折りたたみヘッダとタブ・高さの揃わないグリッド)。
  各画面の「罠」を実際に踏む手順で、成否は echo の文字列で確かめる

```sh
Scripts/e2ey.sh                 # iOS(in-app = 既定エンジン)と Android。SUT はソースが新しければ再ビルド
Scripts/e2ey.sh --ios-xcuitest  # iOS だけを XCUITest エンジンで
Scripts/e2ey.sh --rebuild       # SUT を必ず再ビルド
```

プロファイルは -01〜-08 の8台(同名のデバイスが各機にあるので `--on M1Ultra` でも同じプロファイルで回る。`Scripts/e2e.sh` の対象外)。
