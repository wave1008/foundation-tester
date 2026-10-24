// 辞書(webview 側)。namespace: runBoard.
// 対象ソース: webview/monitor/runBoard.js(デバイスモニターの「run ボード」。docs/design.md §18)。
// webview バンドル(src/webview/i18n.js)から import される。**vscode 非依存**を保つこと。
// キーは "runBoard." 始まり。
import type { MessageDict } from "../core";

export const runBoardStrings = {
  "runBoard.title": { ja: "実行中 {count}", en: "Running {count}" },
  // ツールチップと aria-label が共有。**ON/OFF で入れ替えない**(ユーザー決定)——
  // このボタンは「いま開く」ではなく「開いた状態を保つ」モードのスイッチ
  "runBoard.expandAll": { ja: "全て展開を維持", en: "Keep all expanded" },
  "runBoard.collapse": { ja: "run ボードを閉じる", en: "Collapse run board" },
  "runBoard.expand": { ja: "run ボードを開く", en: "Expand run board" },
  "runBoard.expandLanes": { ja: "デバイスごとの内訳を開く", en: "Show per-device lanes" },
  "runBoard.collapseLanes": { ja: "デバイスごとの内訳を閉じる", en: "Hide per-device lanes" },
  "runBoard.machineIdle": { ja: "空き", en: "Free" },
  "runBoard.machineUnknown": { ja: "実行状況を観測できていません", en: "Run status not observed" },
  "runBoard.issuerRun": { ja: "{issuer} の run", en: "{issuer}'s run" },
  "runBoard.building": { ja: "シナリオをビルド中", en: "Building scenarios…" },
  "runBoard.requeued": { ja: "⟳{count}", en: "⟳{count}" },
  "runBoard.laneDropouts": { ja: "レーン離脱 {count}", en: "{count} lane(s) dropped" },
  "runBoard.preparing": { ja: "デバイスの準備を開始します", en: "Starting device preparation…" },
  // 準備中の端末ごとの供給の段階(台帳の supply)。1つだけ出す(選び方は runBoardModel.currentSupplyStep・台数は出さない)
  "runBoard.supplyRunnerBuild": { ja: "ランナーをビルド中", en: "Building the runner…" },
  "runBoard.supplyBooting": { ja: "デバイスを起動中", en: "Booting devices…" },
  "runBoard.supplyBridge": { ja: "ブリッジを起動中", en: "Starting the bridge…" },
  "runBoard.supplyInstalling": { ja: "アプリをインストール中", en: "Installing the app…" },
  "runBoard.supplyConfiguring": { ja: "デバイスを設定しています", en: "Configuring devices…" },
  // 全台の準備が終わり、実行が始まる直前(準備中のときだけ。実行中には添えない)
  "runBoard.supplyStarting": { ja: "テストを開始しています", en: "Starting tests…" },
  "runBoard.compiling": { ja: "Vision コンパイル中", en: "Compiling Vision…" },
  "runBoard.laneIdle": { ja: "⏹ 待機", en: "⏹ Waiting" },
  "runBoard.remainingUnknown": { ja: "—", en: "—" },
  "runBoard.remainingTime": { ja: "残 ~{time}", en: "~{time} left" },
  "runBoard.remainingOverage": {
    ja: "残 ~0:00(+{time} 超過)",
    en: "~0:00 left (+{time} over)",
  },
  "runBoard.encodingVideo": { ja: "動画を編集中 {done}/{total}", en: "Encoding videos {done}/{total}" },
} satisfies MessageDict;
