#!/usr/bin/env node
// mock-live.mjs
// `ftester api list-devices` / `ftester api live <sub>` を模したダミー実行スクリプト。
// livePanel.ts が実際に spawn する形(binaryPath 相当 = このスクリプト、args = "api" の次から)を
// 再現するため、第一引数に "list-devices" または "live" を取る。
//
// 使い方:
//   node mock-live.mjs list-devices --project <p>
//     --project が "NoMachine" の場合はマシンプロファイル未設定を模して stdout に何も出さず、
//     stderr にメッセージを書いて exit 1(実物の ApiListDevicesCommand と同じ:失敗時は
//     {"ok":false} のような JSON を出さず、ArgumentParser 経由のエラーのみ)。
//     それ以外は ios 1台(connected)・android 1台(offline)の2台を返して exit 0。
//
//   node mock-live.mjs live <snapshot|tap|type|swipe|press|launch|terminate|install> [options...] [--fail]
//     --fail が付いている、または snapshot で --port 9999 が指定された場合は
//     {"ok":false,"error":"..."} を stdout に出して exit 1(実物の ApiLiveCommand の
//     ok:false 方針と同じ)。それ以外は成功として扱う
//     (snapshot は {"ok":true,...} のフルペイロード、それ以外は {"ok":true} だけ)。
//
// 契約(Sources/ftester/ApiListDevicesCommand.swift・ApiLiveCommand.swift)通り、stdout には
// 結果1行のJSONだけを出す(診断は stderr のみ)。標準出力への書き込みは fs.writeSync(1, ...) で行う
// (mock-monitor.mjs 等と同じ理由: process.stdout.write は非同期にバッファされることがあり、
// パイプ相手だと書き出しのタイミングが読み取り側のイベントループと絡んで不安定になりうるため)。

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
} else if (command === "live") {
  const sub = args[1];
  const fail = args.includes("--fail") || (sub === "snapshot" && optionValue("--port", undefined) === "9999");

  if (fail) {
    emitStdout({ ok: false, error: `mock-live: ${sub} に失敗しました(--fail 指定)` });
    process.exit(1);
  }

  if (sub === "snapshot") {
    emitStdout({
      ok: true,
      platform: optionValue("--platform", "ios"),
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
  } else {
    emitStdout({ ok: true });
  }
  process.exit(0);
} else {
  emitStderr(`mock-live: 未知のコマンドです: ${String(command)}`);
  process.exit(1);
}
