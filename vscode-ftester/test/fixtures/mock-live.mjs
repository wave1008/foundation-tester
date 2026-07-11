#!/usr/bin/env node
// mock-live.mjs
// `ftester api list-devices`(ワンショット)/ `ftester api live serve`(常駐)を模したダミー
// 実行スクリプト。livePanel.ts が実際に spawn する形(binaryPath 相当 = このスクリプト、
// args = "api" の次から)を再現するため、第一引数に "list-devices" または "live" を取る。
//
// 使い方:
//   node mock-live.mjs list-devices --project <p>
//     --project が "NoMachine" の場合はマシンプロファイル未設定を模して stdout に何も出さず、
//     stderr にメッセージを書いて exit 1(実物の ApiListDevicesCommand と同じ:失敗時は
//     {"ok":false} のような JSON を出さず、ArgumentParser 経由のエラーのみ)。
//     それ以外は ios 1台(connected)・android 1台(offline)の2台を返して exit 0。
//
//   node mock-live.mjs live serve [--platform ..] [--port ..] [--serial ..] [--fail-all]
//     常駐する。stdin から NDJSON でコマンドを1行ずつ受け、実物の ApiLiveServe と同じプロトコルで
//     応答する(Sources/ftester/ApiLiveCommand.swift 冒頭のプロトコル参照):
//       refresh 以外は {"kind":"actionResult","ok":..,"error":..} → 続けて
//       {"kind":"snapshot","ok":..,...} の2行、refresh は snapshot の1行だけ。
//     コマンドに --fail(真偽ではなくコマンド自体のフィールドとして扱う)を模すため、
//     このモックでは特別な入力値で失敗を再現する: tap の ref が 999 なら actionResult を
//     ok:false にする。--fail-all を付けて起動すると、以降の全操作(refresh 含む)の
//     snapshot をずっと ok:false にする(常駐プロセスが壊れているケースの再現用)。
//     stdin の EOF で exit 0 になる(実物と同じ)。
//
// 契約(Sources/ftester/ApiListDevicesCommand.swift・ApiLiveCommand.swift)通り、stdout には
// 1行1JSONだけを出す(診断は stderr のみ)。標準出力への書き込みは fs.writeSync(1, ...) で行う
// (mock-monitor.mjs 等と同じ理由: process.stdout.write は非同期にバッファされることがあり、
// パイプ相手だと書き出しのタイミングが読み取り側のイベントループと絡んで不安定になりうるため)。

import { createInterface } from "node:readline";
import { writeSync } from "node:fs";
import process from "node:process";

const args = process.argv.slice(2);

function optionValue(name, fallback) {
  const i = args.indexOf(name);
  return i !== -1 && i + 1 < args.length ? args[i + 1] : fallback;
}

function emitStdout(obj) {
  writeSync(1, `${JSON.stringify(obj)}\n`);
}

function emitStderr(message) {
  writeSync(2, `${message}\n`);
}

const command = args[0];

if (command === "list-devices") {
  const project = optionValue("--project", "SampleApp");
  if (project === "NoMachine") {
    emitStderr("エラー: マシンプロファイルが見つかりません: 未登録");
    process.exit(1);
  }
  emitStdout({
    project,
    machine: "M1 Max",
    devices: [
      { name: "シミュ1", platform: "ios", state: "connected", detail: "port 8127", port: 8127, serial: null },
      { name: "エミュ1", platform: "android", state: "offline", detail: "", port: null, serial: null },
    ],
  });
  process.exit(0);
} else if (command === "live" && args[1] === "serve") {
  const platform = optionValue("--platform", "ios");
  const failAll = args.includes("--fail-all");

  function emitSnapshot() {
    if (failAll) {
      emitStdout({
        kind: "snapshot",
        ok: false,
        error: "mock-live: --fail-all 指定によりスナップショット取得に失敗しました",
      });
      return;
    }
    emitStdout({
      kind: "snapshot",
      ok: true,
      error: null,
      platform,
      screen: { width: 402, height: 874 },
      image: "//4=", // 有効な base64 文字列であればよい(内容は検証対象外)
      elements: [
        {
          ref: 1,
          type: "Button",
          label: "ログイン",
          identifier: "login_button",
          value: null,
          frame: { x: 20, y: 780, width: 362, height: 48 },
        },
        {
          ref: 2,
          type: "TextField",
          label: null,
          identifier: "username_field",
          value: "",
          frame: { x: 20, y: 200, width: 362, height: 44 },
        },
      ],
    });
  }

  const rl = createInterface({ input: process.stdin, terminal: false });
  rl.on("line", (line) => {
    let value;
    try {
      value = JSON.parse(line);
    } catch {
      emitStderr(`mock-live: 未知の形式の行を無視しました: ${line}`);
      return;
    }
    const cmd = value && typeof value === "object" ? value.cmd : undefined;
    if (cmd === "refresh") {
      emitSnapshot();
      return;
    }
    // tap --ref 999 を「実行時の失敗」の再現用に予約する(実物の ok:false ケースの模擬)。
    const failed = failAll || (cmd === "tap" && value.ref === 999);
    emitStdout({
      kind: "actionResult",
      ok: !failed,
      error: failed ? `mock-live: ${String(cmd)} に失敗しました` : null,
    });
    emitSnapshot();
  });
  rl.on("close", () => process.exit(0));
} else {
  emitStderr(`mock-live: 未知のコマンドです: ${JSON.stringify(args)}`);
  process.exit(1);
}
