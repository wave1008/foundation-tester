#!/usr/bin/env node
// mock-monitor.mjs
// `ftester api monitor` を模したダミー実行スクリプト。テストから spawn して
// NdjsonParser → monitorModel の配線を検証するためのフィクスチャ(実バイナリは使わない)。
//
// 使い方: node mock-monitor.mjs [--project <P>] [--interval <秒>] [--max-width <px>] [--pattern <name>]
//   pattern:
//     success (既定): monitorDevices(2台: connected 1 / booted 1) →
//                      connected デバイスの monitorFrame を3枚 →
//                      booted デバイスの monitorError の順に1回だけ出力する。
//
//   --project/--interval/--max-width は実際の CLI 同様に受け付けるが無視する。
//
// 契約どおり、一連のイベントを出力した後もプロセスは終了せず、stdin の EOF('end')または
// SIGTERM を受けて初めて exit(0) する(テスト側は期待件数を受信した時点で child.stdin.end() を
// 呼んで EOF を送る。dryRun 相当のタイムアウトフォールバックとして SIGTERM にも対応する)。
//
// 標準出力への書き込みは fs.writeSync(1, ...) で行う(mock-runner.mjs と同じ理由:
// process.stdout.write は非同期にバッファされることがあり、パイプ相手だと書き出しのタイミングが
// 読み取り側のイベントループと絡んで不安定になりうるため)。

import { writeSync } from "node:fs";
import process from "node:process";

const args = process.argv.slice(2);

function optionValue(name, fallback) {
  const i = args.indexOf(name);
  return i !== -1 && i + 1 < args.length ? args[i + 1] : fallback;
}

const pattern = optionValue("--pattern", "success");

function emit(obj) {
  writeSync(1, `${JSON.stringify(obj)}\n`);
}

function runSuccess() {
  emit({
    kind: "monitorDevices",
    devices: [
      { id: "ios:シミュ1", name: "シミュ1", platform: "ios", state: "connected", detail: "接続済み" },
      {
        id: "ios:シミュ2",
        name: "シミュ2",
        platform: "ios",
        state: "booted",
        detail: "ブリッジ未接続",
      },
    ],
  });
  for (let i = 0; i < 3; i += 1) {
    emit({
      kind: "monitorFrame",
      device: "ios:シミュ1",
      jpegBase64: `frame-${i}`,
      width: 480,
      height: 1040,
    });
  }
  emit({ kind: "monitorError", device: "ios:シミュ2", message: "ブリッジに接続できません" });
}

switch (pattern) {
  case "success":
  default:
    runSuccess();
    break;
}

// 実際の `ftester api monitor` と同じく stdin EOF / SIGTERM で終了する。
process.stdin.resume();
process.stdin.on("end", () => process.exit(0));
process.on("SIGTERM", () => process.exit(0));
