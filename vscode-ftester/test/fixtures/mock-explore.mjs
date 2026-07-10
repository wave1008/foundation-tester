#!/usr/bin/env node
// mock-explore.mjs
// `ftester api explore` を模したダミー実行スクリプト。テストから spawn して
// NdjsonParser → exploreModel の配線(ftester.explore コマンドが FtesterCli の直列キュー経由で
// 実行する探索プロセス)を検証するためのフィクスチャ(実バイナリは使わない)。
//
// 使い方: node mock-explore.mjs --bundle <id> --goal <text> [--max-steps <n>] [--project <p>]
//                                [--platform <p>] [--port <n>] [--serial <s>]
//                                [--outcome completed|gaveUp|stepLimitReached] [--quarantined]
//                                [--fail] [--delay-ms <n>]
//
//   既定(--fail 無し): exploreStarted → exploreStep×min(3,maxSteps)(各 --delay-ms(既定20ms)の
//   遅延を挟む。1ステップ数十秒かかりうる実物の非同期進行を模す)→ exploreValidating →
//   exploreFinished(outcome=--outcome(既定 completed)、quarantined=--quarantined 指定時 true)
//   の順に出力して exit 0。
//
//   --fail: 実物の「FM利用不可・ドライバ接続不可」ケースを模し、exploreStarted を出さずに
//   error イベントだけ出して exit 1(ApiExploreCommand.swift の早期リターンと同じ)。
//
// SIGTERM(cancellation)には特別なハンドラを登録しない(Node のデフォルト動作でそのまま
// 終了する。cli.ts の cancelCurrent() が SIGTERM/SIGKILL で止められることの確認に使える)。
//
// 標準出力への書き込みは fs.writeSync(1, ...) で行う(他のフィクスチャと同じ理由: パイプ相手だと
// process.stdout.write の書き出しタイミングが不安定になりうるため)。

import { writeSync } from "node:fs";
import process from "node:process";

const args = process.argv.slice(2);

function optionValue(name, fallback) {
  const i = args.indexOf(name);
  return i !== -1 && i + 1 < args.length ? args[i + 1] : fallback;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function emit(obj) {
  writeSync(1, `${JSON.stringify(obj)}\n`);
}

const bundle = optionValue("--bundle", "com.example.app");
const goal = optionValue("--goal", "ログインしてホーム画面を確認する");
const maxSteps = Number(optionValue("--max-steps", "25"));
const project = optionValue("--project", "SampleApp");
const platform = optionValue("--platform", "ios");
const outcome = optionValue("--outcome", "completed");
const quarantined = args.includes("--quarantined");
const fail = args.includes("--fail");
const delayMs = Number(optionValue("--delay-ms", "20"));

async function main() {
  if (fail) {
    emit({ kind: "error", message: "mock-explore: FM が利用できません(--fail 指定)" });
    process.exitCode = 1;
    return;
  }

  emit({ kind: "exploreStarted", project, bundleID: bundle, goal, maxSteps, platform });

  const stepCount = Math.max(1, Math.min(3, maxSteps));
  for (let step = 1; step <= stepCount; step += 1) {
    await sleep(delayMs);
    emit({ kind: "exploreStep", step, maxSteps, description: `模擬ステップ${step}を実行` });
  }

  await sleep(delayMs);
  emit({ kind: "exploreValidating", message: "生成コードをビルド検証中" });

  await sleep(delayMs);
  emit({
    kind: "exploreFinished",
    outcome,
    detail: outcome === "gaveUp" ? "対象要素が見つかりませんでした" : null,
    stepsTaken: stepCount,
    file: "/tmp/mock-explore/Generated/MockScenario.swift",
    scenarioID: "MockScenario.T0001",
    quarantined,
  });
  process.exitCode = 0;
}

await main();
