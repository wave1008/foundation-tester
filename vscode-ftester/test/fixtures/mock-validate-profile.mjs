#!/usr/bin/env node
// mock-validate-profile.mjs
// `ftester api validate-profile` を模したダミー実行スクリプト。cli.ts(FtesterCli)経由で
// profileModel.ts / profileDiagnostics.ts の配線を検証するためのフィクスチャ(実バイナリは使わない)。
//
// 使い方: node mock-validate-profile.mjs [--project <P>] [--kind apps|machines|runs] [--name <n>]
//   [--pattern <name>]
//   pattern:
//     mixed(既定): apps 1件(問題なし) / machines 1件(重複デバイス名でエラー) /
//                  runs 2件(1件は未知キー警告のみ、1件は app 参照欠落でエラー) の
//                  計4件を返す(--kind/--name が指定されていればそれで絞り込む)。
//
// 契約(Sources/ftester/ApiValidateProfileCommand.swift と同じ):
//   stdout(1行JSON): {"machine":"M1 Max"|null,"project":"<P>","results":[
//     {"kind":"apps"|"machines"|"runs","name":"..","path":"..","errors":[..],"warnings":[..]}, ...
//   ]}
// 検証エラーがあっても exit 0(実物と同じ)。診断は stderr のみ。
//
// 標準出力への書き込みは fs.writeSync(1, ...) で行う(mock-monitor.mjs と同じ理由:
// process.stdout.write は非同期にバッファされることがあり、パイプ相手だと書き出しのタイミングが
// 読み取り側のイベントループと絡んで不安定になりうるため)。

import { writeSync } from "node:fs";
import process from "node:process";

const args = process.argv.slice(2);

function optionValue(name, fallback) {
  const i = args.indexOf(name);
  return i !== -1 && i + 1 < args.length ? args[i + 1] : fallback;
}

const project = optionValue("--project", "SampleApp");
const kind = optionValue("--kind", undefined);
const name = optionValue("--name", undefined);
const pattern = optionValue("--pattern", "mixed");

function emit(obj) {
  writeSync(1, `${JSON.stringify(obj)}\n`);
}

const ALL_RESULTS = [
  {
    kind: "apps",
    name: "sampleapp",
    path: "/repo/Projects/SampleApp/profiles/apps/sampleapp.json",
    errors: [],
    warnings: [],
  },
  {
    kind: "machines",
    name: "M1 Max",
    path: "/repo/Projects/SampleApp/profiles/machines/M1 Max.json",
    errors: ["デバイス名が重複しています: エミュ1(name は ios/android 横断で一意にしてください)"],
    warnings: [],
  },
  {
    kind: "runs",
    name: "sampleapp_all",
    path: "/repo/Projects/SampleApp/profiles/runs/sampleapp_all.json",
    errors: [],
    warnings: ["runs/sampleapp_all.json: 未知のキー \"foo\" は無視されます"],
  },
  {
    kind: "runs",
    name: "broken",
    path: "/repo/Projects/SampleApp/profiles/runs/broken.json",
    errors: ["\"app\"(apps/ への参照)がありません"],
    warnings: [],
  },
];

function runMixed() {
  let results = ALL_RESULTS;
  if (kind !== undefined) {
    results = results.filter((result) => result.kind === kind);
  }
  if (name !== undefined) {
    results = results.filter((result) => result.name === name);
  }
  emit({ machine: "M1 Max", project, results });
}

switch (pattern) {
  case "mixed":
  default:
    runMixed();
    break;
}

process.exit(0);
