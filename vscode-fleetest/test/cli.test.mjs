// cli.test.mjs
// FleetestCli(src/cli.ts)の stdin 対応 spawn(CliInvocation.stdin)と cancelCurrent() の
// キャンセル方針のユニット/統合テスト。node:test で実行する。esbuild が "../src/cli"
// (拡張子なし)を cli.ts に解決してバンドルする。
//
// 相手は本物の fleetest CLI ではなく test/fixtures/mock-apply-heal.mjs
// (stdin の JSON をそのまま読んで応答を返すダミー)にする。binaryPath には process.execPath
// (node)を渡し、args の先頭にフィクスチャのパスを置くことで「node <fixture> ...」として
// spawn させる(dap.test.mjs や runReducer.test.mjs の mock-runner 統合テストと同じ方針)。
//
// FleetestCli は vscode.OutputChannel を1引数で受け取るが、このテストでは
// appendLine だけ実装したダミーで足りる(cli.ts は他のメソッドを呼ばない)。
//
// cancelCurrent() のテストは実子プロセス(test/fixtures/mock-slow-cleanup.mjs。SIGTERM を無視して
// 生き続ける)を本物の spawn で起動し、node:test の mock timers で setTimeout だけを差し替える。
// 差し替えるのは cli.ts 内部の setTimeout であって子プロセス自体の生死判定(exitCode/signalCode)や
// OS のシグナル配送ではないので、tick() で仮想時間を進めるだけで実際に SIGKILL が飛ぶ様子を
// (実時間をほぼ待たずに)確認できる。

import assert from "node:assert/strict";
import path from "node:path";
import { test } from "node:test";
import { FleetestCli } from "../src/cli";

const MOCK_APPLY_HEAL = path.resolve(process.cwd(), "test", "fixtures", "mock-apply-heal.mjs");
const MOCK_SLOW_CLEANUP = path.resolve(process.cwd(), "test", "fixtures", "mock-slow-cleanup.mjs");
const CWD = process.cwd();

function makeOutputChannel() {
  const lines = [];
  return { lines, appendLine: (line) => lines.push(line) };
}

/** MOCK_SLOW_CLEANUP を起動し、"ready" 行(SIGTERM ハンドラ登録済みの合図)を待ってから
 * invoke() の Promise を返す。cancelCurrent() を呼ぶ前に必ずこれを await すること
 * (登録前に SIGTERM が届くと素通りして即終了し、キャンセル方針を検証できなくなるため)。 */
function invokeSlowCleanup(cli) {
  let ready;
  const readyPromise = new Promise((resolve) => {
    ready = resolve;
  });
  const resultPromise = cli.invoke(process.execPath, CWD, {
    args: [MOCK_SLOW_CLEANUP],
    onNdjsonValue: () => {},
    onLog: (line) => {
      if (line === "ready") {
        ready();
      }
    },
  });
  return { readyPromise, resultPromise };
}

/** resultPromise がまだ解決していないことを、実時間をほぼ使わずに確かめる
 * (setImmediate は mock timers[apis:["setTimeout"]] の対象外なので実際に効く)。 */
function stillPending(resultPromise) {
  return Promise.race([
    resultPromise.then(() => false),
    new Promise((resolve) => setImmediate(() => resolve(true))),
  ]);
}

test("stdin 対応 spawn: invocation.stdin を書き込んで EOF を送り、mock-apply-heal.mjs が読んだ内容をそのまま応答に反映する", async () => {
  const outputChannel = makeOutputChannel();
  const cli = new FleetestCli(outputChannel);

  const request = {
    fixes: [
      {
        scenarioID: "S.T1",
        file: "TestProjects/P/scenarios/S.swift",
        line: 12,
        oldSelector: "#old_id",
        newSelector: "#new_id",
        newComment: null,
      },
      {
        scenarioID: "S.T2",
        file: "TestProjects/P/scenarios/S.swift",
        line: 20,
        oldSelector: "#old2",
        newSelector: "#FAIL_new2",
        newComment: "説明",
      },
    ],
  };

  const result = await cli.invoke(process.execPath, CWD, {
    args: [MOCK_APPLY_HEAL],
    stdin: JSON.stringify(request),
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.cancelled, false);
  assert.deepEqual(result.json, {
    applied: ["S.T1|TestProjects/P/scenarios/S.swift:12|#old_id"],
    failures: [
      {
        id: "S.T2|TestProjects/P/scenarios/S.swift:20|#old2",
        message: "模擬エラー: #FAIL_new2",
      },
    ],
  });
});

test("stdin 対応 spawn: fixes が空でも往復できる(applied/failures とも空配列)", async () => {
  const outputChannel = makeOutputChannel();
  const cli = new FleetestCli(outputChannel);

  const result = await cli.invoke(process.execPath, CWD, {
    args: [MOCK_APPLY_HEAL],
    stdin: JSON.stringify({ fixes: [] }),
  });

  assert.equal(result.exitCode, 0);
  assert.deepEqual(result.json, { applied: [], failures: [] });
});

test("stdin 未指定の呼び出し(既存の挙動)は引き続き動作する(stdin を使わない CLI 呼び出しの回帰確認)", async () => {
  const outputChannel = makeOutputChannel();
  const cli = new FleetestCli(outputChannel);

  // mock-apply-heal.mjs は stdin が空でも({fixes:[]} 相当として)正常応答するため、
  // stdin を渡さない(stdio: "ignore")呼び出しでも同じフィクスチャで検証できる。
  const result = await cli.invoke(process.execPath, CWD, { args: [MOCK_APPLY_HEAL] });

  assert.equal(result.exitCode, 1);
  // stdin が閉じている(EOF 即時)ため mock-apply-heal.mjs 側は空文字列 → JSON パース失敗
  // → exitCode 1 で {applied:[],failures:[]} を返す実装になっている。stdio:"ignore" でも
  // プロセスが正しく起動・完走し、cli.ts が結果を受け取れることの確認が目的。
  assert.deepEqual(result.json, { applied: [], failures: [] });
});

// ---- cancelCurrent() のキャンセル方針(2026-09-06 Codex 指摘)----
// 後始末を持つ fleetest の子(`api run` 等)には時限 SIGKILL を送らない。既定(escalateAfterMs
// 省略)は SIGTERM のみで、onStillRunning が要求したときだけ forceKill() 経由で SIGKILL する。
// 時限 SIGKILL が要るのは escalateAfterMs を明示するヘルパー呼び出しだけ(従来挙動)。

test("既定の cancelCurrent(): SIGTERM のみを送り、時間が経っても自動では SIGKILL しない", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"], now: 0 });
  const outputChannel = makeOutputChannel();
  const cli = new FleetestCli(outputChannel);

  const { readyPromise, resultPromise } = invokeSlowCleanup(cli);
  await readyPromise;

  cli.cancelCurrent();
  t.mock.timers.tick(60000);

  assert.equal(
    await stillPending(resultPromise),
    true,
    "SIGTERM を無視する子は、既定の cancelCurrent() だけでは終了しない(SIGKILL していない証拠)",
  );

  // 後始末: 実際に SIGKILL して終了させる(次のテストへ孤児プロセスを持ち越さない)。
  cli.cancelCurrent({ escalateAfterMs: 1 });
  t.mock.timers.tick(1);
  const result = await resultPromise;
  assert.equal(result.cancelled, true);
});

test("onStillRunning は SIGTERM から2秒後に1回だけ呼ばれ、forceKill() で SIGKILL する", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"], now: 0 });
  const outputChannel = makeOutputChannel();
  const cli = new FleetestCli(outputChannel);

  const { readyPromise, resultPromise } = invokeSlowCleanup(cli);
  await readyPromise;

  let stillRunningCalls = 0;
  let forceKill;
  cli.cancelCurrent({
    onStillRunning: (kill) => {
      stillRunningCalls += 1;
      forceKill = kill;
    },
  });

  t.mock.timers.tick(1999);
  assert.equal(stillRunningCalls, 0, "2秒未満ではまだ呼ばれない");

  t.mock.timers.tick(1);
  assert.equal(stillRunningCalls, 1, "2秒後に1回呼ばれる");
  assert.equal(typeof forceKill, "function");

  assert.equal(await stillPending(resultPromise), true, "通知だけでは殺していない");

  forceKill();
  const result = await resultPromise;
  assert.equal(result.cancelled, true, "forceKill() が実際に SIGKILL する");

  t.mock.timers.tick(10000);
  assert.equal(stillRunningCalls, 1, "forceKill 後もタイマーを再スケジュールして呼び直さない");
});

test("escalateAfterMs を渡すと従来どおり指定時間後に自動で SIGKILL する(後始末を持たない外部ヘルパー用)", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"], now: 0 });
  const outputChannel = makeOutputChannel();
  const cli = new FleetestCli(outputChannel);

  const { readyPromise, resultPromise } = invokeSlowCleanup(cli);
  await readyPromise;

  cli.cancelCurrent({ escalateAfterMs: 2000 });

  t.mock.timers.tick(1999);
  assert.equal(await stillPending(resultPromise), true, "escalateAfterMs 未満ではまだ SIGKILL しない");

  t.mock.timers.tick(1);
  const result = await resultPromise;
  assert.equal(result.cancelled, true, "escalateAfterMs 経過で自動 SIGKILL され終了する");
});
