// panelRelocalize.test.mjs
// 各 webview パネルの relocalize()(fleetest.language 変更時に extension.ts が呼ぶ)の実行時検証。
// コントローラクラス自体はこのテストのためだけに export されている(生成経路は register*Panel の
// み。各 *Panel.ts 冒頭コメント参照)。
//
// Monitor の relocalize() は内部で vscode.Uri.joinPath(...)(renderHtml)や
// vscode.workspace.createFileSystemWatcher(...)(Monitor のサブコントローラ
// MonitorProfilesController がコンストラクタで呼ぶ)を実行する。esbuild の vscodeStubPlugin
// (monitorUpdate.test.mjs 冒頭コメント参照)は `import * as vscode from "vscode"` を CJS→ESM
// 変換する際に __toESM の __copyProps が Proxy の実プロパティ(length/name/prototype のみ)しか
// 写さないため、`vscode.Uri`/`vscode.workspace` 等はどのファイルでも undefined になり、触れた
// 時点で必ず例外になる(実測: TypeError: Cannot read properties of undefined)。
// そのため実行時テストで検証できるのは「vscode に触れない経路」だけ:
// - LiveTabHost(「ライブ操作」タブのサブコントローラ)は自分の WebviewPanel を持たず、
//   MonitorPanelController から狭い deps(LiveTabHostDeps)だけを注入されるので、vscode に
//   触れずに単体で構成できる(Monitor 本体はコンストラクタ自体が
//   vscode.workspace.createFileSystemWatcher を呼ぶため、コンストラクタすら実行できない。
//   Monitor 本体は対象外)。
// - HealReviewController.renderHtml(items) は webview/extensionUri を取らず vscode に触れないため、
//   パネルが開いている場合も実行できる。
// Monitor の relocalize()(html 再構築 → deviceStream.restartAllStreams() → live.restartStream() の
// 順)は test/panelRelocalizeSourceContract.test.mjs がソース走査で検証する(同ファイル冒頭コメント参照)。
// 「結果ダッシュボード」は単独パネルを廃止しモニターパネルのタブへ統合済み(旧 dashboardPanel.ts)。
// relocalize は Monitor 側の1本にまとまったため、ここに Dashboard 専用のテストは無い。

import assert from "node:assert/strict";
import { test } from "node:test";

import { FleetestCli } from "../src/cli";
import { HealReviewController } from "../src/healReviewPanel";
import { LiveTabHost } from "../src/liveTabHost";
import { RunEventBus } from "../src/runEventBus";

const outputChannel = { appendLine() {} };
const getConfig = () => ({ binaryPath: "/usr/local/bin/fleetest", project: "P", profile: "" });

function newLiveTabHost() {
  const cli = new FleetestCli(outputChannel);
  // FleetestTestTree(../src/testTree)は生成時に vscode.tests.createTestController を呼ぶため、
  // esbuild の vscodeStubPlugin 下では作れない。LiveTabHost は testTree.refresh() しか呼ばないので、
  // その形だけを備えた fake で足りる。
  const testTree = { refresh: async () => {} };
  const deps = {
    post: () => {},
    isPanelOpen: () => false,
    showTab: () => {},
    isPollingMode: () => false,
    openGeneratedDocument: () => {},
  };
  return new LiveTabHost(deps, getConfig, cli, testTree, new RunEventBus(), "/tmp/proj", outputChannel);
}

function newHealReviewController() {
  return new HealReviewController("/tmp/proj", getConfig, outputChannel, {}, new RunEventBus());
}

test("LiveTabHost.restartStream(): MonitorLiveController.restartStream() へ委譲する(例外なし)", () => {
  const host = newLiveTabHost();
  let restarted = 0;
  host.live.restartStream = () => {
    restarted += 1;
  };
  assert.doesNotThrow(() => host.restartStream());
  assert.equal(restarted, 1);
});

test("HealReviewController.relocalize(): パネル未生成なら何もしない", () => {
  const controller = newHealReviewController();
  assert.doesNotThrow(() => controller.relocalize());
});

test("HealReviewController.relocalize(): パネルが開いていれば items を埋め込んだ html を組み直す", () => {
  const controller = newHealReviewController();
  // renderHtml(items) は webview に触れない(healReviewPanel.ts 冒頭コメント: 外部リソース無し)ため
  // vscode スタブの制約を受けない。
  const panel = { webview: { html: "old-html" } };
  controller.panel = panel;

  controller.relocalize();

  assert.notEqual(panel.webview.html, "old-html");
  assert.match(panel.webview.html, /<!doctype html>/);
});
