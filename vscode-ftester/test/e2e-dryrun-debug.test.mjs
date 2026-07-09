// e2e-dryrun-debug.test.mjs
// FtesterDebugSession(src/debugAdapter.ts)を実バイナリ(.build/debug/ftester)相手に駆動する
// エンドツーエンドテスト。node:test で実行するが、実バイナリ・実リポジトリ(SampleApp)に
// 依存するため、FTESTER_E2E=1 が設定されているときだけ実行する(それ以外は skip され、
// 通常の `npm test` の合否には影響しない)。
//
// 実行方法:
//   FTESTER_E2E=1 node --test out-test/e2e-dryrun-debug.test.mjs
// (out-test/ へのバンドルは npm test と同じ `node esbuild.mjs --tests` で行われる)
//
// シナリオは Projects/SampleApp/Scenarios/ログインテスト.swift の S0010。19行目
// (tap "#login_btn||ログイン", index=4)にブレークポイントを張り、--dry-run + stopOnEntry で
// initialize → setBreakpoints → configurationDone → stopped(entry, index1/line15)
// → next → stopped(step, index2/line17) → continue → stopped(breakpoint, line19)
// → continue → scenarioFinished(passed:true) → terminated の系列を確認する。
// dry-run なのでデバイス/シミュレータは不要(全コマンドを記録のみで通過させる)。

import assert from "node:assert/strict";
import path from "node:path";
import { test } from "node:test";
import { createDapDriver } from "./fixtures/dapDriver.mjs";

const RUN_E2E = process.env.FTESTER_E2E === "1";

// npm test は vscode-ftester/ を cwd として実行される(package.json の "test" スクリプト)ので、
// リポジトリルート(Package.swift のあるフォルダ)はその1つ上。
const REPO_ROOT = path.resolve(process.cwd(), "..");
const BINARY_PATH = path.join(REPO_ROOT, ".build", "debug", "ftester");
const SCENARIO_FILE = path.join(
  REPO_ROOT,
  "Projects",
  "SampleApp",
  "Scenarios",
  "ログインテスト.swift",
);

test(
  "E2E: 実バイナリ --debug --dry-run で initialize→setBreakpoints→configurationDone→" +
    "stopped(entry)→next→stopped(step)→continue→stopped(breakpoint)→continue→terminated",
  { skip: !RUN_E2E && "FTESTER_E2E=1 のときだけ実行します" },
  async () => {
    const driver = createDapDriver({ binaryPath: BINARY_PATH, cwd: REPO_ROOT });
    try {
      await driver.initialize();

      // 19行目(tap "#login_btn||ログイン", index=4)にブレークポイントを張る
      driver.send("setBreakpoints", { source: { path: SCENARIO_FILE }, breakpoints: [{ line: 19 }] });
      const bpResp = await driver.waitForResponse("setBreakpoints", 15000);
      assert.equal(bpResp.body.breakpoints[0].verified, true);
      assert.equal(bpResp.body.breakpoints[0].line, 19);

      await driver.launch({
        project: "SampleApp",
        scenario: "ログインテスト.S0010",
        dryRun: true,
        stopOnEntry: true,
        skipBuild: true,
      });
      await driver.configurationDone();

      // stopOnEntry により最初のステップ(index1, line15: launchApp())の手前で一時停止する
      const stoppedEntry = await driver.waitForEvent("stopped", 30000);
      assert.equal(stoppedEntry.body.reason, "entry");

      driver.send("stackTrace", { threadId: 1 });
      const entryStack = await driver.waitForResponse("stackTrace", 15000);
      assert.equal(entryStack.body.stackFrames[0].line, 15);
      assert.match(entryStack.body.stackFrames[0].source.path, /ログインテスト\.swift$/);

      // next → 1歩進んで(index2, line17)再度一時停止
      driver.send("next", { threadId: 1 });
      await driver.waitForResponse("next", 15000);
      const stoppedStep = await driver.waitForEvent("stopped", 15000);
      assert.equal(stoppedStep.body.reason, "step");

      driver.send("stackTrace", { threadId: 1 });
      const stepStack = await driver.waitForResponse("stackTrace", 15000);
      assert.equal(stepStack.body.stackFrames[0].line, 17);

      // continue → ブレークポイント(index4, line19)まで進んで一時停止
      driver.send("continue", { threadId: 1 });
      await driver.waitForResponse("continue", 15000);
      const stoppedBreakpoint = await driver.waitForEvent("stopped", 15000);
      assert.equal(stoppedBreakpoint.body.reason, "breakpoint");

      driver.send("stackTrace", { threadId: 1 });
      const breakpointStack = await driver.waitForResponse("stackTrace", 15000);
      assert.equal(breakpointStack.body.stackFrames[0].line, 19);

      // continue → 残りを最後まで進めてシナリオ成功、プロセス終了
      driver.send("continue", { threadId: 1 });
      await driver.waitForResponse("continue", 15000);

      const finishedEvent = await driver.waitForEvent("ftester.scenarioFinished", 30000);
      assert.equal(finishedEvent.body.passed, true);

      await driver.waitForEvent("terminated", 15000);
      const exitedEvent = await driver.waitForEvent("exited", 5000);
      assert.equal(exitedEvent.body.exitCode, 0);
    } finally {
      if (!driver.messages.some((m) => m.type === "event" && m.event === "terminated")) {
        driver.send("terminate", {});
        await driver.waitForEvent("terminated", 5000).catch(() => undefined);
      }
    }
  },
);
