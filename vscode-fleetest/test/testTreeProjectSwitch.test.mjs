// testTreeProjectSwitch.test.mjs
// プロジェクト切替時の Test Explorer の追従(testTree.ts)。
//
// 一覧は `fleetest api list-scenarios --project <新>`(そのプロジェクトが未ビルドなら
// swift build を含む)が返るまで来ない。その間ずっと前のプロジェクトのシナリオが並ぶと、
// 押した先は新しいプロジェクトの設定で走って噛み合わないので、切替の時点で捨てる。
// run 中は TestRun がアイテムを参照しているので再構築できず、旗で run 終了まで持ち越す。
//
// コンストラクタは通さない(vscode.tests.createTestController は esbuild の vscodeStubPlugin 下では
// 作れない。monitorProfilesDeviceMachineScope.test.mjs と同じ fake-deps パターン)。

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import { test } from "node:test";
import { FleetestTestTree } from "../src/testTree";

const SCENARIOS = [{ id: "A.test1", title: "t", app: "a", platform: "ios", file: "/x.swift" }];

/** TestProjects/ を持たない一時ワークスペース(= プロジェクト未解決)で組み立てる。
 * 未解決なら refreshForProjectSwitch は withProgress を通らず refresh() が即戻るので、
 * 「捨てる」ところだけを見られる。 */
function makeTree() {
  const workspaceRoot = fs.mkdtempSync(`${os.tmpdir()}/fleetest-tree-test-`);
  const replaced = [];
  const tree = Object.create(FleetestTestTree.prototype);
  tree.controller = { items: { replace: (items) => replaced.push(items) } };
  tree.cli = { invoke: async () => ({ exitCode: 0, json: { scenarios: [] }, cancelled: false }) };
  tree.getWorkspaceRoot = () => workspaceRoot;
  tree.getConfig = () => ({ binaryPath: "fleetest", project: "", profile: "", buildBeforeRun: true });
  tree.outputChannel = { appendLine() {} };
  tree.generation = 0;
  tree.lastScenarios = [...SCENARIOS];
  tree.lastData = { scenarios: SCENARIOS };
  tree.projectSwitchPending = false;
  return { tree, replaced };
}

test("プロジェクト切替は待つ前にツリーを空にする(前のプロジェクトのシナリオを押せる状態で残さない)", async () => {
  const { tree, replaced } = makeTree();

  await tree.refreshForProjectSwitch();

  assert.deepEqual(replaced[0], [], "最初にツリーを空にすること");
  assert.deepEqual(tree.scenarios, [], "逆引き用の保持データも捨てること");
});

test("切替は保持データも捨てる(待っている間のフィルター切替で前の一覧が戻らない)", async () => {
  const { tree } = makeTree();
  let refreshed = 0;
  await tree.refreshForProjectSwitch();
  // lastData が残っていると、rebuildFromLastData は CLI を叩かず前の一覧を並べ直してしまう。
  tree.refresh = async () => { refreshed += 1; };
  tree.rebuildFromLastData();

  assert.equal(refreshed, 1, "捨ててあれば refresh() に委ねる");
});

test("run 中の切替は旗にして run 終了で拾う", () => {
  const { tree } = makeTree();
  let switched = 0;
  tree.refreshForProjectSwitch = async () => { switched += 1; };

  tree.notePendingProjectSwitch();
  assert.equal(switched, 0, "run 中は再構築しない");

  tree.flushPendingProjectSwitch();
  assert.equal(switched, 1);
});

test("持ち越しが無ければ run 終了で再構築しない", () => {
  const { tree } = makeTree();
  let switched = 0;
  tree.refreshForProjectSwitch = async () => { switched += 1; };

  tree.flushPendingProjectSwitch();

  assert.equal(switched, 0);
});

test("拾うのは1回だけ(次の run の終了で撃ち直さない)", () => {
  const { tree } = makeTree();
  let switched = 0;
  tree.refreshForProjectSwitch = async () => { switched += 1; };

  tree.notePendingProjectSwitch();
  tree.flushPendingProjectSwitch();
  tree.flushPendingProjectSwitch();

  assert.equal(switched, 1);
});

// ---- 配線(extension.ts)------------------------------------------------------------------
// 上のテストは testTree の側しか見ない。**この機能の値打ちは配線に在る** —— 呼ばれなければ
// 静かに旧挙動(`testTree.refresh()` 直呼び)へ戻り、run 中の切替は永久に拾われないまま緑になる。
// 型では止まらない(どちらのメソッドも存在するので消しても通る)ので、ソース走査で固定する。

import { readFileSync } from "node:fs";
import path from "node:path";

/** コメントを落とす(コメント中の名前を配線と数えない。jsdomTeardown.test.mjs と同じ理由)。 */
function stripComments(source) {
  return source
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .split("\n")
    .map((line) => line.replace(/\/\/.*$/, ""))
    .join("\n");
}

const extensionSource = stripComments(
  readFileSync(path.join(process.cwd(), "src", "extension.ts"), "utf8"),
);

test("配線: fleetest.project の変更は refreshForProjectSwitch / notePendingProjectSwitch を通る", () => {
  assert.match(extensionSource, /testTree\.refreshForProjectSwitch\(\)/,
    "切替時はツリーを捨ててから再構築する経路を通すこと(素の refresh() ではツリーが残る)");
  assert.match(extensionSource, /testTree\.notePendingProjectSwitch\(\)/,
    "run 中の切替を旗にすること");
});

test("配線: run 終了で flushPendingProjectSwitch を呼ぶ", () => {
  assert.match(extensionSource, /testTree\.flushPendingProjectSwitch\(\)/,
    "拾わないと run 中に来た切替は手で更新するまで反映されない");
});
