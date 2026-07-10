#!/usr/bin/env node
// mock-device-op.mjs
// `ftester api device-up` / `ftester api device-down` を模したダミー実行スクリプト。
// monitorPanel.ts のデバイスタイル個別起動/停止ボタンが実際に spawn する形(第一引数が
// "device-up"/"device-down"、以降 --name/--project)を再現する。テストから spawn して
// NdjsonParser → monitorModel.isDeviceOpEvent の配線を検証するためのフィクスチャ
// (実バイナリは使わない)。
//
// 使い方: node mock-device-op.mjs (device-up|device-down) --name <n> [--project <p>] [--fail]
//   --fail 無し(既定): log を2行出力してから {"kind":"finished","ok":true,"error":null} で exit 0。
//   --fail: log を1行出力してから {"kind":"finished","ok":false,"error":"..."} で exit 1
//   (ApiDeviceCommands.swift の ok:false 方針と同じ)。
//
// 標準出力への書き込みは fs.writeSync(1, ...) で行う(他のフィクスチャと同じ理由)。

import { writeSync } from "node:fs";
import process from "node:process";

const args = process.argv.slice(2);

function optionValue(name, fallback) {
  const i = args.indexOf(name);
  return i !== -1 && i + 1 < args.length ? args[i + 1] : fallback;
}

function emit(obj) {
  writeSync(1, `${JSON.stringify(obj)}\n`);
}

function emitStderr(message) {
  writeSync(2, `${message}\n`);
}

const sub = args[0];
if (sub !== "device-up" && sub !== "device-down") {
  emitStderr(`mock-device-op: 未知のサブコマンドです: ${String(sub)}`);
  process.exit(1);
}

const name = optionValue("--name", "シミュ1");
const fail = args.includes("--fail");
const verb = sub === "device-up" ? "起動" : "停止";

emit({ kind: "log", message: `${name} を${verb}しています...` });

if (fail) {
  emit({ kind: "finished", ok: false, error: `${name} の${verb}に失敗しました(--fail 指定)` });
  process.exit(1);
} else {
  emit({ kind: "log", message: `${name} の${verb}が完了しました` });
  emit({ kind: "finished", ok: true, error: null });
  process.exit(0);
}
