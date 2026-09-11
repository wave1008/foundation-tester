// lastResultsSync.test.mjs
// diffLastResults / absorbIntoSnapshot(vscode 非依存の純粋関数)と、registerLastResultsSync の
// 監視先の張り替え(reconfigure)の回帰テスト。後者は controller を最小 duck type(items.forEach)で
// 渡し、合成 run を作らない経路(ツリーに leaf が無い = onResultsApplied だけ呼ばれる)で観測する。

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { absorbIntoSnapshot, diffLastResults, registerLastResultsSync } from "../src/lastResultsSync";

test("diffLastResults: previous が空なら current の全件を報告する", () => {
  const current = new Map([
    ["A.s1", "passed"],
    ["A.s2", "failed"],
  ]);
  const changed = diffLastResults(current, new Map());
  assert.deepEqual(
    changed.sort((a, b) => a.id.localeCompare(b.id)),
    [
      { id: "A.s1", state: "passed" },
      { id: "A.s2", state: "failed" },
    ],
  );
});

test("diffLastResults: current と previous が同一なら空", () => {
  const snapshot = new Map([["A.s1", "passed"]]);
  assert.deepEqual(diffLastResults(snapshot, new Map(snapshot)), []);
});

test("diffLastResults: 状態が変わった id のみ報告する", () => {
  const previous = new Map([
    ["A.s1", "passed"],
    ["A.s2", "failed"],
  ]);
  const current = new Map([
    ["A.s1", "passed"],
    ["A.s2", "passed"],
  ]);
  assert.deepEqual(diffLastResults(current, previous), [{ id: "A.s2", state: "passed" }]);
});

test("diffLastResults: previous にあり current に無い id は報告しない", () => {
  const previous = new Map([
    ["A.s1", "passed"],
    ["A.s2", "failed"],
  ]);
  const current = new Map([["A.s1", "passed"]]);
  assert.deepEqual(diffLastResults(current, previous), []);
});

test("absorb: GUI 実行分だけ進め、次 diff の合成 run 対象から外す", () => {
  const snapshot = new Map([["A.s1", "failed"]]);
  const current = new Map([
    ["A.s1", "passed"], // GUI 実行で failed → passed
    ["B.s1", "failed"], // ターミナル実行分(absorb 対象外)
  ]);
  absorbIntoSnapshot(snapshot, current, ["A.s1"]);
  assert.deepEqual(diffLastResults(current, snapshot), [{ id: "B.s1", state: "failed" }]);
});

test("absorb: NFD の id でも NFC のストアキーへ揃う(lookupKey 正規化)", () => {
  const nfc = "デ".normalize("NFC");
  const nfd = nfc.normalize("NFD");
  const snapshot = new Map();
  const current = new Map([[nfc, "passed"]]);
  absorbIntoSnapshot(snapshot, current, [nfd]);
  assert.deepEqual(diffLastResults(current, snapshot), []);
});

test("absorb: current に無い id(dry-run 等の未記録)は snapshot から消す", () => {
  const snapshot = new Map([["A.s1", "failed"]]);
  const current = new Map();
  absorbIntoSnapshot(snapshot, current, ["A.s1"]);
  assert.equal(snapshot.size, 0);
});

// ---- reconfigure ----
// fs.watch は登録時に解決した project のディレクトリで固定なので、fleetest.project を切り替えても
// 新プロジェクトでの CLI 実行がツリーへ届かなかった。DEBOUNCE_MS(1 秒)の後に反映されるので、
// 各段は 1.5 秒待つ。

const DEBOUNCE_WAIT_MS = 1500;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function makeWorkspace(projects) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "fleetest-lrs-reconf-"));
  for (const project of projects) {
    fs.mkdirSync(path.join(root, ".fleetest", "last-results", project), { recursive: true });
    // resolveProjectName は候補(TestProjects/ 配下の実ディレクトリ)に無い設定値を採用しない。
    fs.mkdirSync(path.join(root, "TestProjects", project), { recursive: true });
  }
  return root;
}

// last-results/<project>/ の直下はプロファイルごとのサブディレクトリ(lastResults.ts の
// readAllResults 参照)。この統合テストは実ファイルシステム + fs.watch を使うので、新レイアウトの
// パスへ書く
function writeResult(root, project, profile, scenarioId, state) {
  const dir = path.join(root, ".fleetest", "last-results", project, profile);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, scenarioId), state);
}

test("reconfigure: プロジェクト切替後は新プロジェクトの last-results への書き込みが反映される", async () => {
  const root = makeWorkspace(["ProjA", "ProjB"]);
  const config = { project: "ProjA" };
  let applied = 0;
  const sync = registerLastResultsSync({
    controller: { items: { forEach: () => {}, size: 0 } },
    workspaceRoot: root,
    getConfig: () => config,
    isGuiRunActive: () => false,
    outputChannel: { appendLine: () => {} },
    onResultsApplied: () => { applied += 1; },
  });
  try {
    // last-results/<project>/ の直下はプロファイルごとのサブディレクトリ
    writeResult(root, "ProjA", "ios-inapp", "Login.S0010", "passed");
    await sleep(DEBOUNCE_WAIT_MS);
    assert.equal(applied, 1, "切替前: ProjA への書き込みが反映される(実験系の陽性対照)");

    config.project = "ProjB";
    sync.reconfigure();
    writeResult(root, "ProjB", "ios-inapp", "Login.S0010", "failed");
    await sleep(DEBOUNCE_WAIT_MS);
    assert.equal(applied, 2, "切替後: ProjB への書き込みが反映されない(監視先が旧プロジェクトのまま)");
  } finally {
    sync.dispose();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("reconfigure: スナップショットを捨てるので、同じ id・同じ状態でも新プロジェクトの値として反映される", async () => {
  // 5 SUT はシナリオ ID を共有する。旧プロジェクトのスナップショットと差分を取ると、新プロジェクトで
  // 同じ状態の id が「変化なし」として落ちる。
  const root = makeWorkspace(["ProjA", "ProjB"]);
  const config = { project: "ProjA" };
  let applied = 0;
  const sync = registerLastResultsSync({
    controller: { items: { forEach: () => {}, size: 0 } },
    workspaceRoot: root,
    getConfig: () => config,
    isGuiRunActive: () => false,
    outputChannel: { appendLine: () => {} },
    onResultsApplied: () => { applied += 1; },
  });
  try {
    writeResult(root, "ProjA", "ios-inapp", "Login.S0010", "passed");
    await sleep(DEBOUNCE_WAIT_MS);
    assert.equal(applied, 1);

    config.project = "ProjB";
    sync.reconfigure();
    writeResult(root, "ProjB", "ios-inapp", "Login.S0010", "passed");
    await sleep(DEBOUNCE_WAIT_MS);
    assert.equal(applied, 2);
  } finally {
    sync.dispose();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("dispose 後は書き込みが反映されない(watch と timer が閉じている)", async () => {
  const root = makeWorkspace(["ProjA"]);
  let applied = 0;
  const sync = registerLastResultsSync({
    controller: { items: { forEach: () => {}, size: 0 } },
    workspaceRoot: root,
    getConfig: () => ({ project: "ProjA" }),
    isGuiRunActive: () => false,
    outputChannel: { appendLine: () => {} },
    onResultsApplied: () => { applied += 1; },
  });
  sync.dispose();
  try {
    writeResult(root, "ProjA", "ios-inapp", "Login.S0010", "passed");
    await sleep(DEBOUNCE_WAIT_MS);
    assert.equal(applied, 0);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
