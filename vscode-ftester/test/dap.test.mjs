// dap.test.mjs
// FtesterDebugSession(src/debugAdapter.ts)のプロトコルテスト。node:test で実行する。
//
// debugAdapter.ts は @vscode/debugadapter 以外(特に "vscode" モジュール)に依存しないため、
// 実エディタ無しでインスタンスを直接 new し、handleMessage()/onDidSendMessage() だけで
// DAP を駆動できる(vscode.debug.* は debugConfig.ts 側にしか登場しない)。
// child_process は本物を spawn するが、相手は本物の ftester CLI ではなく
// test/fixtures/mock-runner.mjs(--debug モード)にする(駆動ロジックは test/fixtures/dapDriver.mjs)。

import assert from "node:assert/strict";
import path from "node:path";
import { test } from "node:test";
import { createDapDriver } from "./fixtures/dapDriver.mjs";

// esbuild が out-test/ にバンドルするため import.meta.url はバンドル後の場所を指す。
// npm test は常に vscode-ftester/ を cwd として実行される(package.json の "test" スクリプト)ので
// process.cwd() を基準に fixtures を解決する(runReducer.test.mjs と同じ流儀)。
const MOCK_RUNNER = path.resolve(process.cwd(), "test", "fixtures", "mock-runner.mjs");
// spawn の cwd はリポジトリルート相当として扱う(存在するディレクトリが必要なので
// vscode-ftester/ 自身を使う。Projects/Mock/... は実在しなくてよい: パス文字列の
// 相対化/spawn の cwd としてのみ使う)。
const REPO_ROOT = process.cwd();

function createMockDriver(overrides = {}) {
  return createDapDriver({ binaryPath: MOCK_RUNNER, cwd: REPO_ROOT, ...overrides });
}

/**
 * テスト終了時に一時停止中/実行中のプロセスが残っていれば必ず後始末する。
 * (アサーション失敗などで途中終了すると、mock-runner が stdin 待ちのまま残り、
 * node --test 自体がプロセス終了を待ち続けて固まってしまうため。)
 */
async function withDriver(overrides, fn) {
  const driver = createMockDriver(overrides);
  try {
    await fn(driver);
  } finally {
    if (!driver.messages.some((m) => m.type === "event" && m.event === "terminated")) {
      driver.send("terminate", {});
      await driver.waitForEvent("terminated", 3000).catch(() => undefined);
    }
  }
}

test("setBreakpoints: 絶対パス→リポジトリ相対化し、起動後の追加分も全ファイル分を全置換で stdin へ送る", async () => {
  await withDriver({}, async (driver) => {
    const fileA = path.join(REPO_ROOT, "Projects", "Mock", "Scenarios", "Mock.swift");

    await driver.initialize();

    // プロセス起動前: setBreakpoints は蓄積のみ(verified な応答は返す)
    driver.send("setBreakpoints", { source: { path: fileA }, breakpoints: [{ line: 14 }] });
    const resp1 = await driver.waitForResponse("setBreakpoints");
    assert.equal(resp1.body.breakpoints.length, 1);
    assert.equal(resp1.body.breakpoints[0].verified, true);
    assert.equal(resp1.body.breakpoints[0].line, 14);
    assert.equal(resp1.body.breakpoints[0].source.path, fileA);

    await driver.launch({ project: "Mock", scenario: "テスト.T1", skipBuild: true });
    await driver.configurationDone();

    // 起動時に渡した --breakpoint(Mock.swift:14)に命中して一時停止する
    const stopped1 = await driver.waitForEvent("stopped");
    assert.equal(stopped1.body.reason, "breakpoint");

    // 起動後に別ファイルの breakpoints を追加設定する → 全置換で stdin へ送られ、
    // mock-runner が ack を stderr に出す(1件目の Mock.swift:14 も含めて全部届いているはず)
    const fileB = path.join(REPO_ROOT, "Projects", "Other", "Scenarios", "Other.swift");
    driver.send("setBreakpoints", { source: { path: fileB }, breakpoints: [{ line: 5 }] });
    const resp2 = await driver.waitForResponse("setBreakpoints");
    assert.equal(resp2.body.breakpoints.length, 1);
    assert.equal(resp2.body.breakpoints[0].line, 5);

    await driver.waitUntil(() =>
      driver.logs.some((l) => l.stream === "stderr" && l.line.includes("breakpoints ack")),
    );
    const ackLine = driver.logs.find((l) => l.line.includes("breakpoints ack")).line;
    assert.match(ackLine, /Projects\/Mock\/Scenarios\/Mock\.swift:14/);
    assert.match(ackLine, /Projects\/Other\/Scenarios\/Other\.swift:5/);
  });
});

test("paused → stopped の reason は直前のコマンドで決まる(entry → next(step) → continue(breakpoint))", async () => {
  await withDriver({}, async (driver) => {
    await driver.initialize();
    await driver.launch({ project: "Mock", scenario: "テスト.T2", skipBuild: true, stopOnEntry: true });
    await driver.configurationDone();

    // --pause-on-start により最初のステップ(index1, line10)の手前で一時停止する
    const stopped1 = await driver.waitForEvent("stopped");
    assert.equal(stopped1.body.reason, "entry");

    // next(ステップ実行) → stdin へ {"cmd":"step"} → 1歩進んで再度一時停止(index2, line14)
    driver.send("next", { threadId: 1 });
    await driver.waitForResponse("next");
    const stopped2 = await driver.waitForEvent("stopped");
    assert.equal(stopped2.body.reason, "step");

    // stackTrace は直近の paused から1フレームを組み立てる
    driver.send("stackTrace", { threadId: 1 });
    const stackResp = await driver.waitForResponse("stackTrace");
    assert.equal(stackResp.body.stackFrames.length, 1);
    assert.equal(stackResp.body.stackFrames[0].line, 14);
    assert.match(stackResp.body.stackFrames[0].source.path, /Mock\.swift$/);

    // continue → stdin へ {"cmd":"continue"} → 最後まで進んで scenarioFinished → runFinished → 終了
    driver.send("continue", { threadId: 1 });
    await driver.waitForResponse("continue");

    const finishedEvent = await driver.waitForEvent("ftester.scenarioFinished");
    assert.equal(finishedEvent.body.passed, true);

    await driver.waitForEvent("terminated");
    await driver.waitForEvent("exited");
  });
});

test("scopes/variables: 停止中はスコープ「ステップ」とシナリオ/ステップ番号/コマンド/scene/区分/位置を返す", async () => {
  await withDriver({}, async (driver) => {
    await driver.initialize();
    await driver.launch({ project: "Mock", scenario: "テスト.T5", skipBuild: true, stopOnEntry: true });
    await driver.configurationDone();

    // --pause-on-start により最初のステップ(index1, line10)の手前で一時停止する
    const stopped = await driver.waitForEvent("stopped");
    assert.equal(stopped.body.reason, "entry");

    driver.send("scopes", { frameId: 1 });
    const scopesResp = await driver.waitForResponse("scopes");
    assert.equal(scopesResp.body.scopes.length, 1);
    const scope = scopesResp.body.scopes[0];
    assert.equal(scope.name, "ステップ");
    assert.equal(scope.expensive, false);

    driver.send("variables", { variablesReference: scope.variablesReference });
    const variablesResp = await driver.waitForResponse("variables");
    const byName = Object.fromEntries(variablesResp.body.variables.map((v) => [v.name, v.value]));

    // 値が undefined の項目(今回は無い)は出ない前提で、期待する6項目ちょうどが揃うことを確認する
    assert.deepEqual(
      Object.keys(byName),
      ["シナリオ", "ステップ番号", "コマンド", "scene", "区分", "位置"],
    );
    assert.equal(byName["シナリオ"], "テスト.T5");
    assert.equal(byName["ステップ番号"], "1");
    assert.equal(byName["コマンド"], "launch com.example.mock");
    assert.equal(byName["scene"], "1");
    assert.equal(byName["区分"], "action");
    assert.equal(byName["位置"], "Projects/Mock/Scenarios/Mock.swift:10");
  });
});

test("scopes/variables: 一時停止前(lastPaused 無し)はエラーにせず空配列を返す", async () => {
  await withDriver({}, async (driver) => {
    await driver.initialize();

    driver.send("scopes", { frameId: 1 });
    const scopesResp = await driver.waitForResponse("scopes");
    assert.equal(scopesResp.success, true);
    assert.deepEqual(scopesResp.body.scopes, []);

    driver.send("variables", { variablesReference: 1 });
    const variablesResp = await driver.waitForResponse("variables");
    assert.equal(variablesResp.success, true);
    assert.deepEqual(variablesResp.body.variables, []);
  });
});

test("terminate: stdin へ stop cmd を送り、プロセスが自発的に終了してから TerminatedEvent を出す", async () => {
  await withDriver({}, async (driver) => {
    await driver.initialize();
    await driver.launch({ project: "Mock", scenario: "テスト.T3", skipBuild: true, stopOnEntry: true });
    await driver.configurationDone();
    await driver.waitForEvent("stopped"); // entry で一時停止中

    driver.send("terminate", {});
    const terminateResp = await driver.waitForResponse("terminate");
    assert.equal(terminateResp.success, true);

    // stop cmd が正しく届いていれば、mock-runner は強制killされずに自発的に
    // scenarioFinished(passed:false)/runFinished を出してから終了する
    const finishedEvent = await driver.waitForEvent("ftester.scenarioFinished");
    assert.equal(finishedEvent.body.passed, false);

    const terminatedEvent = await driver.waitForEvent("terminated");
    const finishedIndex = driver.messages.indexOf(finishedEvent);
    const terminatedIndex = driver.messages.indexOf(terminatedEvent);
    assert.ok(
      finishedIndex < terminatedIndex,
      "scenarioFinished は terminated より先に届くはず(stop cmd による正常終了)",
    );

    await driver.waitForEvent("exited");
  });
});

test("突然死(NDJSON を出し切らないままプロセスが exit)しても TerminatedEvent を必ず出す", async () => {
  await withDriver({}, async (driver) => {
    await driver.initialize();
    await driver.launch({
      // mock-runner はこのシナリオ ID を --debug + crash 相当として扱う(test/fixtures/mock-runner.mjs 参照)
      project: "Mock",
      scenario: "クラッシュ.T1",
      skipBuild: true,
    });
    await driver.configurationDone();

    const terminatedEvent = await driver.waitForEvent("terminated");
    assert.ok(terminatedEvent);
    const exitedEvent = await driver.waitForEvent("exited");
    assert.equal(exitedEvent.body.exitCode, 1);

    // 突然死なので paused/scenarioFinished は一切発生しない
    assert.ok(!driver.messages.some((m) => m.type === "event" && m.event === "stopped"));
    assert.ok(!driver.messages.some((m) => m.type === "event" && m.event === "ftester.scenarioFinished"));
  });
});

test("spawn 失敗(バイナリ不在)でも TerminatedEvent を出す", async () => {
  await withDriver(
    { binaryPath: path.join(REPO_ROOT, "no-such-ftester-binary") },
    async (driver) => {
      await driver.initialize();
      await driver.launch({ project: "Mock", scenario: "テスト.T4", skipBuild: true });
      await driver.configurationDone();

      await driver.waitForEvent("terminated");
      await driver.waitForEvent("exited");
    },
  );
});
