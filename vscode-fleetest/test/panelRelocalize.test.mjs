// panelRelocalize.test.mjs
// 各 webview パネルの relocalize()(fleetest.language 変更時に extension.ts が呼ぶ)の実行時検証。
// コントローラクラス自体はこのテストのためだけに export されている(生成経路は register*Panel の
// み。各 *Panel.ts 冒頭コメント参照)。
//
// Monitor/Live/Dashboard の relocalize() は内部で vscode.Uri.joinPath(...)(renderHtml/
// renderLiveHtml)や vscode.workspace.createFileSystemWatcher(...)(Monitor の
// サブコントローラ MonitorProfilesController がコンストラクタで呼ぶ)を実行する。esbuild の
// vscodeStubPlugin(monitorUpdate.test.mjs 冒頭コメント参照)は `import * as vscode from "vscode"`
// を CJS→ESM 変換する際に __toESM の __copyProps が Proxy の実プロパティ(length/name/prototype
// のみ)しか写さないため、`vscode.Uri`/`vscode.workspace` 等はどのファイルでも undefined になり、
// 触れた時点で必ず例外になる(実測: TypeError: Cannot read properties of undefined)。
// そのため実行時テストで検証できるのは「vscode に触れない経路」だけ:
// - パネル未生成(this.panel === undefined)の relocalize() は vscode に一切触れないので実行できる
//   (Monitor はコンストラクタ自体が vscode.workspace.createFileSystemWatcher を呼ぶため、
//   コンストラクタすら実行できない。Monitor は対象外)。
// - HealReviewController.renderHtml(items) は webview/extensionUri を取らず vscode に触れないため、
//   パネルが開いている場合も実行できる。
// Monitor/Live/Dashboard の「開いていれば html を再構築し(ライブ配信を張り直)す」契約は
// test/panelRelocalizeSourceContract.test.mjs がソース走査で検証する(同ファイル冒頭コメント参照)。

import assert from "node:assert/strict";
import { test } from "node:test";

import { DashboardPanelController } from "../src/dashboardPanel";
import { FleetestCli } from "../src/cli";
import { HealReviewController } from "../src/healReviewPanel";
import { LivePanelController } from "../src/livePanel";
import { RunEventBus } from "../src/runEventBus";

const outputChannel = { appendLine() {} };
const getConfig = () => ({ binaryPath: "/usr/local/bin/fleetest", project: "P", profile: "" });

function newLiveController() {
  const cli = new FleetestCli(outputChannel);
  // FleetestTestTree(../src/testTree)はモジュール読み込み時に vscode.TestTag(...) を呼ぶため、
  // esbuild の vscodeStubPlugin 下では import した時点で落ちる。LivePanelController は
  // testTree.refresh() しか呼ばないので、その形だけを備えた fake で足りる。
  const testTree = { refresh: async () => {} };
  const context = { workspaceState: { get: () => false }, extensionUri: {} };
  return new LivePanelController(context, "/tmp/proj", getConfig, outputChannel, cli, testTree, new RunEventBus());
}

function newDashboardController() {
  return new DashboardPanelController("/tmp/proj", getConfig, outputChannel, new RunEventBus(), {});
}

function newHealReviewController() {
  return new HealReviewController("/tmp/proj", getConfig, outputChannel, {}, new RunEventBus());
}

test("LivePanelController.relocalize(): パネル未生成なら何もしない(例外なし・ストリーム再起動なし)", () => {
  const controller = newLiveController();
  let restarted = 0;
  controller.live.restartStream = () => {
    restarted += 1;
  };
  assert.doesNotThrow(() => controller.relocalize());
  assert.equal(restarted, 0);
});

test("DashboardPanelController.relocalize(): パネル未生成なら何もしない", () => {
  const controller = newDashboardController();
  assert.doesNotThrow(() => controller.relocalize());
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
