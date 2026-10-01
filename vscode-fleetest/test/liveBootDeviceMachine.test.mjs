// 拡張が `api start-device --name` を組むときは機械を絞ること(`--device-machine`)。
// Swift の findDevice は --device-machine 省略時に同名のデバイスが複数の機械に居ると ambiguous で断る
// (Sources/fleetest/ApiDeviceCommands.swift。.claude/rules/remote.md「タイル1枚の起動・停止もその機械へ回す」)。
// ライブ操作の bootDevice(monitorLiveController.ts)がこれを付けず、手元とリモートに同名のデバイスが並ぶ
// プロファイルではライブ操作からの起動が毎回断られていた。
// MonitorLiveController は vscode を要しスタブで作れないので、monitorLiveControllerBridgeStarting.test.mjs と
// 同じくソース走査で守る。
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const SRC = path.join(process.cwd(), "src");

test("api start-device を組む配列リテラルは --device-machine を含む", () => {
  const hits = [];
  for (const name of readdirSync(SRC).filter((f) => f.endsWith(".ts"))) {
    const text = readFileSync(path.join(SRC, name), "utf8");
    for (const m of text.matchAll(/\[\s*"api",\s*"start-device"[^\]]*\]/g)) {
      hits.push({ name, literal: m[0] });
    }
  }
  assert.ok(hits.some((h) => h.name === "monitorLiveController.ts"), "走査がライブ操作の起動に届いていない");
  const missing = hits.filter((h) => !h.literal.includes('"--device-machine"')).map((h) => `${h.name}: ${h.literal}`);
  assert.deepEqual(missing, []);
});

test("ライブ操作の bootDevice はリモートのデバイスを手元から起こさない(machine ありは起動せずに false)", () => {
  const text = readFileSync(path.join(SRC, "monitorLiveController.ts"), "utf8");
  const start = text.indexOf("private async bootDevice(");
  assert.notEqual(start, -1, "bootDevice が見つからない");
  const body = text.slice(start, text.indexOf("\n  }\n", start));
  const guardAt = body.indexOf("if (machine !== undefined) {");
  const spawnAt = body.indexOf("this.runCli(");
  assert.ok(guardAt !== -1 && spawnAt !== -1 && guardAt < spawnAt, "machine の判定が起動より前に無い");
  assert.match(text, /this\.bootDevice\(option\.name, option\.machine\)/, "呼び手が machine を渡していない");
});
