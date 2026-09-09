// stepsViewCache.test.mjs
// stepsView.ts の StepsTreeDataProvider のキャッシュが project + シナリオ id で引かれることの回帰テスト。
// 5 SUT(E2E-CMP / E2E-iOS / …)はクラス名・メソッド名を共有するので、id だけを鍵にすると
// プロジェクト切替後に別プロジェクトの行(ファイルパス)を出す。
// cli は `api steps` の応答を project ごとに返す偽物。vscode API は esbuild の vscodeStubPlugin
// (空 Proxy)で、EventEmitter の fire は何もしない。

import assert from "node:assert/strict";
import { test } from "node:test";
import { StepsTreeDataProvider } from "../src/stepsView";

function stepRow(project) {
  return {
    index: 1, scene: 1, sceneTitle: "scene", section: "action", command: "tap(\"#a\")",
    comment: null, generatedComment: null, file: `TestProjects/${project}/scenarios/S.swift`, line: 10,
  };
}

/** invoke の呼び出しを記録し、--project に応じた行を返す偽 cli。 */
function fakeCli() {
  const calls = [];
  return {
    calls,
    async invoke(_binary, _cwd, invocation) {
      const args = invocation.args;
      const project = args[args.indexOf("--project") + 1];
      calls.push({ project, scenario: args[args.indexOf("--scenario") + 1] });
      return { exitCode: 0, cancelled: false, json: { steps: [stepRow(project)] } };
    },
  };
}

const flush = () => new Promise((resolve) => setImmediate(resolve));
const fakeEmitter = () => ({ event: () => ({ dispose() {} }), fire() {}, dispose() {} });

function loadedFile(provider) {
  const scenes = provider.getChildren();
  assert.equal(scenes[0].type, "scene", `loaded でない: ${JSON.stringify(scenes[0])}`);
  const steps = provider.getChildren(scenes[0]);
  return steps[0].step.file;
}

test("同じ id でもプロジェクトが違えば取り直す(別プロジェクトのキャッシュを返さない)", async () => {
  const cli = fakeCli();
  const provider = new StepsTreeDataProvider(
    cli, "/repo", () => ({ binaryPath: "fleetest", buildBeforeRun: false }), { appendLine: () => {} }, fakeEmitter(),
  );
  provider.setScenario("Login.S0010", "E2E-CMP");
  await flush();
  assert.equal(loadedFile(provider), "TestProjects/E2E-CMP/scenarios/S.swift");

  provider.setScenario("Login.S0010", "E2E-iOS");
  await flush();
  assert.deepEqual(cli.calls, [
    { project: "E2E-CMP", scenario: "Login.S0010" },
    { project: "E2E-iOS", scenario: "Login.S0010" },
  ]);
  assert.equal(loadedFile(provider), "TestProjects/E2E-iOS/scenarios/S.swift");
});

test("同じ project + id へ戻るとキャッシュから出す(取り直さない)", async () => {
  const cli = fakeCli();
  const provider = new StepsTreeDataProvider(
    cli, "/repo", () => ({ binaryPath: "fleetest", buildBeforeRun: false }), { appendLine: () => {} }, fakeEmitter(),
  );
  provider.setScenario("Login.S0010", "E2E-CMP");
  await flush();
  provider.setScenario("Login.S0010", "E2E-iOS");
  await flush();
  provider.setScenario("Login.S0010", "E2E-CMP");
  await flush();
  assert.equal(cli.calls.length, 2);
  assert.equal(loadedFile(provider), "TestProjects/E2E-CMP/scenarios/S.swift");
});

test("warnings は scene より先の子ノードとして出る", async () => {
  const warning = "⚠️ the expectation block of scene 1 contains no assertions.";
  const cli = {
    calls: [],
    async invoke() {
      return { exitCode: 0, cancelled: false, json: { steps: [stepRow("E2E-CMP")], warnings: [warning] } };
    },
  };
  const provider = new StepsTreeDataProvider(
    cli, "/repo", () => ({ binaryPath: "fleetest", buildBeforeRun: false }), { appendLine: () => {} }, fakeEmitter(),
  );
  provider.setScenario("Login.S0010", "E2E-CMP");
  await flush();

  const children = provider.getChildren();
  assert.equal(children[0].type, "warning");
  assert.equal(children[0].warning.message, warning);
  assert.equal(children[1].type, "scene");
});

test("warnings が無ければ(未指定の旧 CLI 応答含め)先頭は scene のまま", async () => {
  const cli = fakeCli(); // json に warnings キーが無い旧 CLI 応答を模す
  const provider = new StepsTreeDataProvider(
    cli, "/repo", () => ({ binaryPath: "fleetest", buildBeforeRun: false }), { appendLine: () => {} }, fakeEmitter(),
  );
  provider.setScenario("Login.S0010", "E2E-CMP");
  await flush();

  const children = provider.getChildren();
  assert.equal(children[0].type, "scene");
});
