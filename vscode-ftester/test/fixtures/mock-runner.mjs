#!/usr/bin/env node
// mock-runner.mjs
// `ftester api run` を模したダミー実行スクリプト。テストから spawn して
// NdjsonParser → runReducer / debugAdapter の配線を検証するためのフィクスチャ(実バイナリは使わない)。
//
// 使い方: node mock-runner.mjs --pattern <name> [--scenario <id> ...] [--debug] [--pause-on-start]
//                              [--breakpoint <file:line> ...]
//   pattern:
//     success  : 全シナリオが成功する(既定)
//     failure  : 各シナリオで1ステップが失敗する(file/line/detail 付き)
//     skip     : スキップされたステップを含むが、シナリオ自体は成功する
//     log      : kind=log 行を挟む
//     nonjson  : 有効な NDJSON 行の間に非JSON行(壊れた print 混入など)を挟む
//     crash    : runFinished(・scenarioFinished)を出さないまま異常終了する(exit code 1)。
//                --debug 併用時は scenarioStarted 直後に突然死する(paused は一切出さない)。
//     parallel : 並列実行(`--profile` 指定時)の契約を模す。runStarted 直後に
//                workersReady(2ワーカー: "ios:シミュ1"/"ios:シミュ2")を出し、以降の全イベントに
//                "worker" フィールドを付ける。--scenario を2件指定すると、それぞれ別ワーカーに
//                割り当てられたシナリオのイベントが1件ずつ交互に(ラウンドロビンで)混在して
//                出力される(2件目のシナリオは失敗させる)。
//
//   --debug 指定時、シナリオ ID が「クラッシュ.T1」のときも --pattern crash と同じ扱いにする
//   (debugAdapter.ts 経由では launch 引数に任意の CLI フラグを追加できないため、
//   突然死のテストは特別なシナリオ ID 名で起動する。test/dap.test.mjs 参照)。
//
//   --debug 指定時は Sources/FTCore/ScenarioDebug.swift のプロトコルに従い、
//   stdin から NDJSON の制御コマンド({"cmd":"continue"|"step"|"pause"|"stop"} /
//   {"cmd":"breakpoints","locations":[...]})を受け付け、paused イベントで一時停止する
//   (2ステップの固定シナリオ: index1=line10, index2=line14)。--pattern はデフォルト(success 相当)
//   と crash のみを解釈する。
//
// 他の引数(--project/--platform/--port/--serial/--skip-build/--dry-run 等)は
// 実際の CLI 同様に受け付けるが無視する。
//
// 標準出力への書き込みは fs.writeSync(1, ...) で行う(process.stdout.write はパイプ相手だと
// 非同期にバッファされることがあり、crash パターンで process.exit する直前の行が
// 書き出される前に失われる可能性があるため)。

import { writeSync } from "node:fs";
import process from "node:process";
import { createInterface } from "node:readline";

const args = process.argv.slice(2);

function optionValues(name) {
  const values = [];
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === name && i + 1 < args.length) {
      values.push(args[i + 1]);
    }
  }
  return values;
}

function optionValue(name, fallback) {
  const values = optionValues(name);
  return values.length > 0 ? values[values.length - 1] : fallback;
}

const pattern = optionValue("--pattern", "success");
const requestedScenarios = optionValues("--scenario");
const scenarios = requestedScenarios.length > 0 ? requestedScenarios : ["モックテスト.T0001"];
const debugMode = args.includes("--debug");
const pauseOnStart = args.includes("--pause-on-start");

function emit(obj) {
  writeSync(1, `${JSON.stringify(obj)}\n`);
}

function emitRawLine(text) {
  writeSync(1, `${text}\n`);
}

/** 1シナリオ分の NDJSON を出力する。戻り値: 失敗したら true。 */
function runScenario(id, { fail = false, skip = false, withLog = false } = {}) {
  const file = "Projects/Mock/Scenarios/Mock.swift";
  emit({ kind: "scenarioStarted", scenario: id, title: `${id} のタイトル` });
  emit({ kind: "sceneStarted", scenario: id, scene: 1, sceneTitle: "シーン1" });
  emit({
    kind: "step",
    scenario: id,
    scene: 1,
    section: "condition",
    index: 1,
    description: "launch com.example.mock",
    status: "passed",
    file,
    line: 10,
  });
  if (withLog) {
    emit({ kind: "log", scenario: id, message: "print() で出力されたデバッグメッセージ" });
  }
  let index = 2;
  if (skip) {
    emit({
      kind: "step",
      scenario: id,
      scene: 1,
      section: "action",
      index,
      description: 'tap "#optional_btn" (optional)',
      status: "skipped",
      detail: "要素が見つからないため任意ステップをスキップ",
      file,
      line: 12,
    });
    index += 1;
  }
  emit({
    kind: "step",
    scenario: id,
    scene: 1,
    section: "expectation",
    index,
    description: 'exist "#welcome_text"',
    status: fail ? "failed" : "passed",
    detail: fail ? "要素が見つかりません: #welcome_text" : undefined,
    file,
    line: 14,
  });
  emit({ kind: "sceneFinished", scenario: id, scene: 1, sceneTitle: "シーン1", passed: !fail });
  emit({
    kind: "scenarioFinished",
    scenario: id,
    passed: !fail,
    reportPath: `/tmp/mock-reports/${encodeURIComponent(id)}.md`,
  });
  return fail;
}

/** 1シナリオ分の NDJSON イベント配列を組み立てる(runScenario と違い、即emitせず配列で返す)。 */
function buildScenarioEvents(id, workerId, { fail = false } = {}) {
  const file = "Projects/Mock/Scenarios/Mock.swift";
  return [
    { kind: "scenarioStarted", scenario: id, title: `${id} のタイトル`, worker: workerId },
    { kind: "sceneStarted", scenario: id, scene: 1, sceneTitle: "シーン1", worker: workerId },
    {
      kind: "step",
      scenario: id,
      scene: 1,
      section: "condition",
      index: 1,
      description: "launch com.example.mock",
      status: "passed",
      file,
      line: 10,
      worker: workerId,
    },
    {
      kind: "step",
      scenario: id,
      scene: 1,
      section: "expectation",
      index: 2,
      description: 'exist "#welcome_text"',
      status: fail ? "failed" : "passed",
      detail: fail ? "要素が見つかりません: #welcome_text" : undefined,
      file,
      line: 14,
      worker: workerId,
    },
    { kind: "sceneFinished", scenario: id, scene: 1, sceneTitle: "シーン1", passed: !fail, worker: workerId },
    {
      kind: "scenarioFinished",
      scenario: id,
      passed: !fail,
      reportPath: `/tmp/mock-reports/${encodeURIComponent(id)}.md`,
      worker: workerId,
    },
  ];
}

/**
 * 並列実行(--profile 指定時)の契約を模す: runStarted → workersReady → 複数シナリオの
 * イベントをラウンドロビンで1件ずつ交互に出力 → runFinished。2件目以降のシナリオは失敗させる
 * (worker プレフィックス・複数シナリオ独立集計の両方をテストで検証できるようにするため)。
 */
function runParallel() {
  const workers = [
    { id: "ios:シミュ1", name: "シミュ1", platform: "ios", detail: "port 8127" },
    { id: "ios:シミュ2", name: "シミュ2", platform: "ios", detail: "port 8128" },
  ];
  emit({ kind: "runStarted", total: scenarios.length });
  emit({ kind: "workersReady", workers });

  const queues = scenarios.map((id, i) =>
    buildScenarioEvents(id, workers[i % workers.length].id, { fail: i === 1 }),
  );

  let failedCount = 0;
  // 各シナリオのキューから1件ずつ交互に取り出して出力する(実行が interleave する状況を模す)。
  while (queues.some((queue) => queue.length > 0)) {
    for (const queue of queues) {
      if (queue.length === 0) {
        continue;
      }
      const event = queue.shift();
      emit(event);
      if (event.kind === "scenarioFinished" && !event.passed) {
        failedCount += 1;
      }
    }
  }

  emit({ kind: "runFinished", passed: scenarios.length - failedCount, failed: failedCount });
  process.exitCode = failedCount > 0 ? 1 : 0;
}

function runAllAndFinish(options) {
  emit({ kind: "runStarted", total: scenarios.length });
  let failedCount = 0;
  for (const id of scenarios) {
    if (runScenario(id, options)) {
      failedCount += 1;
    }
  }
  emit({ kind: "runFinished", passed: scenarios.length - failedCount, failed: failedCount });
  process.exitCode = failedCount > 0 ? 1 : 0;
}

/**
 * ホストからの stdin 制御コマンドを受け付けるチャネル。
 * {"cmd":"breakpoints","locations":[...]} は即座に全置換で反映する(resume 扱いにはしない。
 * 実際の ScenarioDebugControl.apply と同じく、一時停止中でも breakpoints 自体は再開の合図にならない)。
 * その他の {"cmd":...} は next() を待っている側へ1件ずつ渡す(先着順のキュー)。
 */
class ControlChannel {
  constructor(initialBreakpoints) {
    this.breakpoints = new Set(initialBreakpoints);
    this.queue = [];
    this.waiters = [];
    this.rl = createInterface({ input: process.stdin, terminal: false });
    this.rl.on("line", (line) => {
      let obj;
      try {
        obj = JSON.parse(line);
      } catch {
        return;
      }
      if (!obj || typeof obj.cmd !== "string") {
        return;
      }
      if (obj.cmd === "breakpoints") {
        this.breakpoints = new Set(Array.isArray(obj.locations) ? obj.locations : []);
        writeSync(2, `mock-runner: breakpoints ack ${JSON.stringify([...this.breakpoints])}\n`);
        return;
      }
      this.push(obj.cmd);
    });
  }

  push(cmd) {
    if (this.waiters.length > 0) {
      const resolve = this.waiters.shift();
      resolve(cmd);
    } else {
      this.queue.push(cmd);
    }
  }

  /** 次のコマンドが来るまで待つ(キュー済みがあれば即解決)。 */
  next() {
    if (this.queue.length > 0) {
      return Promise.resolve(this.queue.shift());
    }
    return new Promise((resolve) => this.waiters.push(resolve));
  }

  hitsBreakpoint(file, line) {
    return this.breakpoints.has(`${file}:${line}`);
  }

  close() {
    this.rl.close();
  }
}

/** --debug の固定2ステップシナリオを、一時停止・再開を挟みながら実行する。 */
async function runDebugScenario() {
  const id = scenarios[0];
  const file = "Projects/Mock/Scenarios/Mock.swift";

  emit({ kind: "runStarted", total: 1 });
  emit({ kind: "scenarioStarted", scenario: id, title: `${id} のタイトル` });
  emit({ kind: "sceneStarted", scenario: id, scene: 1, sceneTitle: "シーン1" });

  if (pattern === "crash" || id === "クラッシュ.T1") {
    // 突然死パターン: paused を一切出さないまま異常終了する
    writeSync(2, "mock-runner: simulated crash (debug)\n");
    process.exit(1);
  }

  const channel = new ControlChannel(optionValues("--breakpoint"));
  const steps = [
    { index: 1, line: 10, description: "launch com.example.mock" },
    { index: 2, line: 14, description: 'exist "#welcome_text"' },
  ];

  let pauseAtNext = pauseOnStart;
  let stopRequested = false;

  for (const step of steps) {
    if (stopRequested) {
      break;
    }
    if (pauseAtNext || channel.hitsBreakpoint(file, step.line)) {
      pauseAtNext = false;
      emit({
        kind: "paused",
        scenario: id,
        index: step.index,
        description: step.description,
        file,
        line: step.line,
        scene: 1,
        section: "action",
      });

      let resumed = false;
      while (!resumed) {
        // eslint-disable-next-line no-await-in-loop -- 一時停止中は次のコマンドを待つのが本義
        const cmd = await channel.next();
        switch (cmd) {
          case "continue":
            resumed = true;
            break;
          case "step":
            pauseAtNext = true;
            resumed = true;
            break;
          case "pause":
            // 一時停止中の pause は無視して待ち続ける(実装の ScenarioDebugControl と同じ)
            pauseAtNext = true;
            break;
          case "stop":
            stopRequested = true;
            resumed = true;
            break;
          default:
            break;
        }
      }
    }
    if (stopRequested) {
      break;
    }
    emit({
      kind: "step",
      scenario: id,
      scene: 1,
      section: "action",
      index: step.index,
      description: step.description,
      status: "passed",
      file,
      line: step.line,
    });
  }

  const passed = !stopRequested;
  emit({ kind: "sceneFinished", scenario: id, scene: 1, sceneTitle: "シーン1", passed });
  emit({
    kind: "scenarioFinished",
    scenario: id,
    passed,
    reportPath: `/tmp/mock-reports/${encodeURIComponent(id)}.md`,
  });
  emit({ kind: "runFinished", passed: passed ? 1 : 0, failed: passed ? 0 : 1 });
  channel.close();
  process.exitCode = passed ? 0 : 1;
  process.exit(process.exitCode);
}

if (debugMode) {
  await runDebugScenario();
} else {
  switch (pattern) {
    case "failure":
      runAllAndFinish({ fail: true });
      break;

    case "skip":
      runAllAndFinish({ skip: true });
      break;

    case "log":
      runAllAndFinish({ withLog: true });
      break;

    case "nonjson":
      emit({ kind: "runStarted", total: scenarios.length });
      emitRawLine("これはユーザーコードの print() が紛れ込んだ非JSON行です");
      {
        let failedCount = 0;
        for (const id of scenarios) {
          if (runScenario(id, {})) failedCount += 1;
        }
        emit({ kind: "runFinished", passed: scenarios.length - failedCount, failed: failedCount });
      }
      break;

    case "parallel":
      runParallel();
      break;

    case "crash": {
      emit({ kind: "runStarted", total: scenarios.length });
      const id = scenarios[0];
      emit({ kind: "scenarioStarted", scenario: id, title: `${id} のタイトル` });
      emit({ kind: "sceneStarted", scenario: id, scene: 1, sceneTitle: "シーン1" });
      emit({
        kind: "step",
        scenario: id,
        scene: 1,
        section: "condition",
        index: 1,
        description: "launch com.example.mock",
        status: "passed",
      });
      // ここでランナーが突然死したことを模す(scenarioFinished/runFinished を出さない)
      writeSync(2, "mock-runner: simulated crash\n");
      process.exit(1);
      break;
    }

    case "success":
    default:
      runAllAndFinish({});
      break;
  }
}
