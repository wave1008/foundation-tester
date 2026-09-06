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
import fs from "node:fs";
import os from "node:os";
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
  const handle = cli.enqueue(process.execPath, CWD, {
    args: [MOCK_SLOW_CLEANUP],
    onNdjsonValue: () => {},
    onLog: (line) => {
      if (line === "ready") {
        ready();
      }
    },
  });
  return { readyPromise, resultPromise: handle.result, handle };
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

// ---- enqueue() のハンドル: 自分の呼び出しだけを止める(2026-09-07)----
// cancelCurrent() は「今走っている何か」を殺す。run の前に list-scenarios / ビルドが積まれていると
// そちらを殺し、続く api run が止められないまま走り出す。ハンドルは自分の1回だけを狙う。

test("enqueue().cancel(): 未着手の呼び出しはキューから外して spawn せず、前の呼び出しには触らない", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"], now: 0 });
  const cli = new FleetestCli(makeOutputChannel());

  const first = invokeSlowCleanup(cli);
  await first.readyPromise;

  // 2本目が spawn されたら印を書く(spawn の有無を結果の形ではなくファイルの実体で見る)
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fleetest-cli-cancel-"));
  const marker = path.join(dir, "spawned");
  const second = cli.enqueue(process.execPath, CWD, {
    args: ["-e", "require('node:fs').writeFileSync(process.argv[1], 'spawned')", marker],
  });
  second.cancel();

  const secondResult = await second.result;
  assert.deepEqual(secondResult, { json: undefined, exitCode: null, cancelled: true },
    "未着手のキャンセルは spawn せず cancelled:true で即解決する");
  assert.equal(await stillPending(first.resultPromise), true, "前の呼び出しは生きたまま");

  // 前の呼び出しを終わらせ、キューが空になった後も2本目が走り出していないことを確かめる
  first.handle.cancel({ escalateAfterMs: 1 });
  t.mock.timers.tick(1);
  const firstResult = await first.resultPromise;
  assert.equal(firstResult.cancelled, true);
  // キューは直列なので、後から積んだ3本目が完了した時点で「2本目が走ったなら終わっている」
  await cli.invoke(process.execPath, CWD, { args: ["-e", "0"] });
  assert.equal(fs.existsSync(marker), false, "取り消した呼び出しは後からも spawn されない");
  fs.rmSync(dir, { recursive: true, force: true });
});

test("enqueue().cancel(): 実行中の自分の呼び出しだけを止め、後ろに積まれた呼び出しは通常どおり走る", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"], now: 0 });
  const cli = new FleetestCli(makeOutputChannel());

  const first = invokeSlowCleanup(cli);
  await first.readyPromise;
  const second = cli.enqueue(process.execPath, CWD, {
    args: [MOCK_APPLY_HEAL],
    stdin: JSON.stringify({ fixes: [] }),
  });

  first.handle.cancel({ escalateAfterMs: 1 });
  t.mock.timers.tick(1);
  const firstResult = await first.resultPromise;
  assert.equal(firstResult.cancelled, true, "自分の呼び出しは止まる");

  const secondResult = await second.result;
  assert.equal(secondResult.cancelled, false, "後ろの呼び出しは巻き込まれない");
  assert.equal(secondResult.exitCode, 0);
  assert.deepEqual(secondResult.json, { applied: [], failures: [] });
});

test("enqueue().cancel(): 終了済みの呼び出しに対しては何もしない(二重解決・例外なし)", async () => {
  const cli = new FleetestCli(makeOutputChannel());
  const handle = cli.enqueue(process.execPath, CWD, { args: [MOCK_APPLY_HEAL], stdin: "{\"fixes\":[]}" });
  const result = await handle.result;
  assert.equal(result.exitCode, 0);
  handle.cancel();
  handle.cancel({ escalateAfterMs: 1 });
  assert.equal(result.cancelled, false);
});

// ---- stdin の EPIPE(2026-09-07)----
// 子が stdin を読む前に終わる(または 64KB 超で pipe が詰まったまま終わる)と、書き込みの EPIPE が
// 非同期の 'error' で来る。リスナーが無いと未処理エラーで拡張ホストごと落ちる。

test("stdin 対応 spawn: 子が読む前に終わっても(EPIPE)未処理の 'error' にならず結果が返る", async () => {
  const cli = new FleetestCli(makeOutputChannel());
  // 1MB は pipe のバッファ(64KB)を確実に超え、子は読まずに即終了する
  const result = await cli.invoke(process.execPath, CWD, {
    args: ["-e", "process.exit(0)"],
    stdin: "x".repeat(1 << 20),
  });
  assert.equal(result.exitCode, 0);
  assert.equal(result.cancelled, false);
});
