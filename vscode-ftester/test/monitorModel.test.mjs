// monitorModel.test.mjs
// monitorModel.ts(isMonitorEvent/toWebviewMessage/isMonitorFromWebviewMessage)のユニットテスト。
// node:test で実行する。esbuild が "../src/monitorModel"(拡張子なし)を monitorModel.ts に
// 解決してバンドルする。
//
// 末尾に、mock-monitor.mjs を実際に spawn して NdjsonParser → monitorModel に通す
// 統合テストを1本含む(monitorPanel.ts の配線を再現する。runReducer.test.mjs の
// mock-runner.mjs 統合テストと同じ方針)。

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import path from "node:path";
import { test } from "node:test";
import { NdjsonParser } from "../src/ndjson";
import {
  isMonitorEvent,
  isMonitorFromWebviewMessage,
  toWebviewMessage,
} from "../src/monitorModel";

// esbuild がこのテストを out-test/ にバンドルするため、import.meta.url はバンドル後の
// 場所を指す。npm test は常に vscode-ftester/ を cwd として実行されるので、
// process.cwd() を基準に test/fixtures/ を解決する(runReducer.test.mjs と同じ理由)。
const MOCK_MONITOR = path.resolve(process.cwd(), "test", "fixtures", "mock-monitor.mjs");

// ---- isMonitorEvent: 正常3種 ----

test("isMonitorEvent: monitorDevices の正常な値を true と判定する", () => {
  const value = {
    kind: "monitorDevices",
    devices: [
      { id: "ios:シミュ1", name: "シミュ1", platform: "ios", state: "connected", detail: "接続済み" },
      { id: "android:エミュ1", name: "エミュ1", platform: "android", state: "offline", detail: "" },
    ],
  };
  assert.equal(isMonitorEvent(value), true);
});

test("isMonitorEvent: monitorFrame の正常な値を true と判定する", () => {
  const value = {
    kind: "monitorFrame",
    device: "ios:シミュ1",
    jpegBase64: "AAAA",
    width: 480,
    height: 1040,
  };
  assert.equal(isMonitorEvent(value), true);
});

test("isMonitorEvent: monitorError の正常な値(device あり)を true と判定する", () => {
  const value = { kind: "monitorError", device: "ios:シミュ1", message: "接続できません" };
  assert.equal(isMonitorEvent(value), true);
});

test("isMonitorEvent: monitorError は device 省略でも true(契約上 device は省略されうる)", () => {
  const value = { kind: "monitorError", message: "マシンプロファイルが未設定です" };
  assert.equal(isMonitorEvent(value), true);
});

// ---- isMonitorEvent: 不正kind ----

test("isMonitorEvent: 未知の kind は false", () => {
  assert.equal(isMonitorEvent({ kind: "monitorSomethingUnknown" }), false);
  assert.equal(isMonitorEvent({ kind: 123 }), false);
  assert.equal(isMonitorEvent({}), false);
  assert.equal(isMonitorEvent(null), false);
  assert.equal(isMonitorEvent("not an object"), false);
  assert.equal(isMonitorEvent(undefined), false);
});

// ---- isMonitorEvent: フィールド欠落 ----

test("isMonitorEvent: monitorDevices は devices 配列が無ければ false", () => {
  assert.equal(isMonitorEvent({ kind: "monitorDevices" }), false);
  assert.equal(isMonitorEvent({ kind: "monitorDevices", devices: "not-an-array" }), false);
});

test("isMonitorEvent: monitorDevices は要素の state が欠落/不正なら false", () => {
  const missingState = {
    kind: "monitorDevices",
    devices: [{ id: "ios:シミュ1", name: "シミュ1", platform: "ios", detail: "" }],
  };
  assert.equal(isMonitorEvent(missingState), false);

  const invalidState = {
    kind: "monitorDevices",
    devices: [
      { id: "ios:シミュ1", name: "シミュ1", platform: "ios", state: "unknown", detail: "" },
    ],
  };
  assert.equal(isMonitorEvent(invalidState), false);
});

test("isMonitorEvent: monitorDevices は要素の platform が ios/android 以外なら false", () => {
  const value = {
    kind: "monitorDevices",
    devices: [
      { id: "x", name: "x", platform: "windows", state: "connected", detail: "" },
    ],
  };
  assert.equal(isMonitorEvent(value), false);
});

test("isMonitorEvent: monitorFrame は width/height が欠落/非数値なら false", () => {
  assert.equal(
    isMonitorEvent({ kind: "monitorFrame", device: "d", jpegBase64: "A", height: 100 }),
    false,
  );
  assert.equal(
    isMonitorEvent({
      kind: "monitorFrame",
      device: "d",
      jpegBase64: "A",
      width: "480",
      height: 100,
    }),
    false,
  );
});

test("isMonitorEvent: monitorError は message が欠落/非文字列なら false", () => {
  assert.equal(isMonitorEvent({ kind: "monitorError", device: "d" }), false);
  assert.equal(isMonitorEvent({ kind: "monitorError", message: 123 }), false);
});

// ---- toWebviewMessage: 変換 ----

test("toWebviewMessage: monitorDevices → { type: 'devices', devices }", () => {
  const devices = [
    { id: "ios:シミュ1", name: "シミュ1", platform: "ios", state: "connected", detail: "接続済み" },
  ];
  assert.deepEqual(toWebviewMessage({ kind: "monitorDevices", devices }), {
    type: "devices",
    devices,
  });
});

test("toWebviewMessage: monitorFrame → { type: 'frame', ... }", () => {
  const event = {
    kind: "monitorFrame",
    device: "ios:シミュ1",
    jpegBase64: "AAAA",
    width: 480,
    height: 1040,
  };
  assert.deepEqual(toWebviewMessage(event), {
    type: "frame",
    device: "ios:シミュ1",
    jpegBase64: "AAAA",
    width: 480,
    height: 1040,
  });
});

test("toWebviewMessage: monitorError → { type: 'deviceError', device, message }", () => {
  const event = { kind: "monitorError", device: "ios:シミュ2", message: "接続できません" };
  assert.deepEqual(toWebviewMessage(event), {
    type: "deviceError",
    device: "ios:シミュ2",
    message: "接続できません",
  });
});

// ---- isMonitorFromWebviewMessage ----

test("isMonitorFromWebviewMessage: devicesUp/devicesDown/restartMonitor を true と判定する", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesUp" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesDown" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "restartMonitor" }), true);
});

test("isMonitorFromWebviewMessage: 未知の type や不正値は false", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "unknown" }), false);
  assert.equal(isMonitorFromWebviewMessage({}), false);
  assert.equal(isMonitorFromWebviewMessage(null), false);
  assert.equal(isMonitorFromWebviewMessage("devicesUp"), false);
});

// ---- 統合: mock-monitor.mjs → NdjsonParser → monitorModel ----

test("統合: mock-monitor.mjs(success パターン)の出力を NdjsonParser → monitorModel に通すと devices→frame×3→deviceError の順のメッセージ列になる", async () => {
  const messages = await runMockMonitorThroughPipeline(["--pattern", "success"], 5);

  assert.equal(messages.length, 5);
  assert.deepEqual(
    messages.map((m) => m.type),
    ["devices", "frame", "frame", "frame", "deviceError"],
  );

  assert.equal(messages[0].devices.length, 2);
  assert.equal(messages[0].devices[0].id, "ios:シミュ1");
  assert.equal(messages[0].devices[0].state, "connected");
  assert.equal(messages[0].devices[1].state, "booted");

  for (let i = 0; i < 3; i += 1) {
    assert.equal(messages[1 + i].device, "ios:シミュ1");
    assert.equal(messages[1 + i].jpegBase64, `frame-${i}`);
    assert.equal(messages[1 + i].width, 480);
    assert.equal(messages[1 + i].height, 1040);
  }

  assert.equal(messages[4].device, "ios:シミュ2");
  assert.equal(messages[4].message, "ブリッジに接続できません");
});

/**
 * mock-monitor.mjs を spawn し、stdout を NdjsonParser → isMonitorEvent/toWebviewMessage に
 * 通して発生した webview メッセージを配列で返す(monitorPanel.ts が組む配線の縮小版)。
 * expectedCount 件受信した時点で stdin を EOF にして終了させる(mock-monitor.mjs は契約どおり
 * stdin EOF まで生存し続けるため)。想定件数に届かない不具合時に無限に待たないよう、
 * タイムアウトで強制終了するフォールバックも備える。
 */
function runMockMonitorThroughPipeline(mockArgs, expectedCount) {
  return new Promise((resolve, reject) => {
    const proc = spawn(process.execPath, [MOCK_MONITOR, ...mockArgs], {
      cwd: path.dirname(MOCK_MONITOR),
      stdio: ["pipe", "pipe", "pipe"],
    });

    const messages = [];
    const parser = new NdjsonParser(
      (value) => {
        if (!isMonitorEvent(value)) {
          return;
        }
        messages.push(toWebviewMessage(value));
        if (messages.length >= expectedCount) {
          proc.stdin.end();
        }
      },
      () => {
        // 非JSON行は無視する(このテストでは検証対象外)
      },
    );

    const timer = setTimeout(() => {
      proc.kill("SIGKILL");
      reject(new Error("mock-monitor.mjs からの応答がタイムアウトしました"));
    }, 5000);

    proc.stdout.on("data", (chunk) => parser.push(chunk));
    proc.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    proc.on("close", () => {
      clearTimeout(timer);
      parser.end();
      resolve(messages);
    });
  });
}
