// e2e-monitor.test.mjs
// `ftester api monitor`(src/monitorModel.ts が変換する NDJSON の生成元)を実バイナリ
// (.build/debug/ftester)相手に spawn するエンドツーエンドテスト。node:test で実行するが、
// 実バイナリ・実リポジトリ(SampleApp のマシンプロファイル)に依存するため、FTESTER_E2E=1 が
// 設定されているときだけ実行する(それ以外は skip され、通常の `npm test` の合否には影響しない)。
// e2e-dryrun-debug.test.mjs と同じ方針(REPO_ROOT/.build/debug/ftester を spawn)。
//
// デバイス(シミュレータ/エミュレータ)自体が起動している必要はない。マシンプロファイル
// (Projects/SampleApp/profiles/machines/)にデバイスが定義されてさえいれば、各デバイスは
// state: "offline"(未起動)のままでもこのテストは成功する(ApiMonitorCommand.swift 参照。
// デバイスの起動・終了はこのコマンドの責務外)。
//
// 実行方法:
//   FTESTER_E2E=1 node --test out-test/e2e-monitor.test.mjs
// (out-test/ へのバンドルは npm test と同じ `node esbuild.mjs --tests` で行われる)

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import path from "node:path";
import { test } from "node:test";
import { isMonitorEvent } from "../src/monitorModel";
import { NdjsonParser } from "../src/ndjson";

const RUN_E2E = process.env.FTESTER_E2E === "1";

// npm test は vscode-ftester/ を cwd として実行される(package.json の "test" スクリプト)ので、
// リポジトリルート(Package.swift のあるフォルダ)はその1つ上(e2e-dryrun-debug.test.mjs と同じ)。
const REPO_ROOT = path.resolve(process.cwd(), "..");
const BINARY_PATH = path.join(REPO_ROOT, ".build", "debug", "ftester");

/** monitorModel.ts の isMonitorEvent が monitorDevices の要素として受理する state の語彙。 */
const VALID_DEVICE_STATES = ["connected", "booted", "offline"];

test(
  "E2E: 実バイナリ ftester api monitor が monitorDevices を配信し、SIGTERM で数秒以内に終了する",
  { skip: !RUN_E2E && "FTESTER_E2E=1 のときだけ実行します" },
  async () => {
    const proc = spawn(
      BINARY_PATH,
      ["api", "monitor", "--project", "SampleApp", "--interval", "0.5", "--max-width", "240"],
      { cwd: REPO_ROOT, stdio: ["pipe", "pipe", "pipe"] },
    );

    // NDJSON としてパース不能な行、および monitorDevices/monitorFrame/monitorError 以外の
    // 行種(kind)が混ざっていないかを、テスト終了まで継続して記録する。
    const nonJsonLines = [];
    const nonConformingValues = [];
    const stderrChunks = [];
    proc.stderr.on("data", (chunk) => stderrChunks.push(chunk.toString("utf8")));

    let firstDevicesSeen = false;
    let resolveFirstDevices;
    let rejectFirstDevices;
    const firstDevicesPromise = new Promise((resolve, reject) => {
      resolveFirstDevices = resolve;
      rejectFirstDevices = reject;
    });

    const stdoutParser = new NdjsonParser(
      (value) => {
        if (!isMonitorEvent(value)) {
          nonConformingValues.push(value);
          return;
        }
        if (value.kind === "monitorDevices" && !firstDevicesSeen) {
          firstDevicesSeen = true;
          resolveFirstDevices(value);
        }
      },
      (line) => {
        nonJsonLines.push(line);
      },
    );
    proc.stdout.on("data", (chunk) => stdoutParser.push(chunk));
    proc.on("error", (error) => rejectFirstDevices(error));

    try {
      const timeoutId = setTimeout(() => {
        rejectFirstDevices(
          new Error(
            "monitorDevices イベントが30秒以内に届きませんでした" +
              (stderrChunks.length > 0 ? `(stderr: ${stderrChunks.join("")})` : ""),
          ),
        );
      }, 30000);
      let devicesEvent;
      try {
        devicesEvent = await firstDevicesPromise;
      } finally {
        clearTimeout(timeoutId);
      }

      assert.ok(Array.isArray(devicesEvent.devices));
      assert.ok(devicesEvent.devices.length >= 1, "少なくとも1台のデバイスが報告されること");
      for (const device of devicesEvent.devices) {
        assert.equal(typeof device.name, "string");
        assert.ok(
          device.platform === "ios" || device.platform === "android",
          `platform は ios/android のいずれか(実際: ${String(device.platform)})`,
        );
        // デバイスが起動している必要はない(state: "offline"(未起動)のままでもよい)。
        assert.ok(
          VALID_DEVICE_STATES.includes(device.state),
          `state は monitorModel.ts が受理する語彙のいずれか(実際: ${String(device.state)})`,
        );
      }

      // SIGTERM を送り、数秒以内にプロセスが終了することを検証する。
      const closed = new Promise((resolve) => proc.once("close", resolve));
      const start = Date.now();
      proc.kill("SIGTERM");
      await Promise.race([
        closed,
        new Promise((_, reject) =>
          setTimeout(
            () => reject(new Error("SIGTERM 送信から5秒以内にプロセスが終了しませんでした")),
            5000,
          ),
        ),
      ]);
      const elapsedMs = Date.now() - start;
      assert.ok(
        elapsedMs < 5000,
        `SIGTERM 送信から終了までが5秒未満であること(実際: ${elapsedMs}ms)`,
      );

      stdoutParser.end();
      assert.deepEqual(nonJsonLines, [], "NDJSON としてパース不能な行が混ざっていないこと");
      assert.deepEqual(
        nonConformingValues,
        [],
        "monitorDevices/monitorFrame/monitorError 以外の行種が混ざっていないこと",
      );
    } finally {
      if (proc.exitCode === null && proc.signalCode === null) {
        proc.kill("SIGKILL");
      }
    }
  },
);
