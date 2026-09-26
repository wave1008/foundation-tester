// ライブ操作の要求上限に足す猶予(launch/install)が、Swift 側の内側の上限と一致することを確認する。
// Swift の真実は Sources/FTBridgeClient/BridgeClient.swift の `Timeout.session` / `Timeout.physicalInstall`
// (serve 側の command watchdog も `ApiLiveServeCommand.watchdogAllowanceSeconds` で同じ値を使う)。
// 片方だけ変えると、拡張が serve を張り直す時刻と serve 自身の猶予がずれる。
// process.cwd() は npm test 実行時に vscode-fleetest ルート(protocolVersion.test.mjs と同じ前提)。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

import { serveCommandAllowanceMs } from "../src/liveModel";

const swiftSource = readFileSync(
  path.join(process.cwd(), "..", "Sources", "FTBridgeClient", "BridgeClient.swift"), "utf8");

function swiftSeconds(name) {
  const match = swiftSource.match(new RegExp(`static let ${name}: TimeInterval = (\\d+)`));
  assert.ok(match, `BridgeClient.swift から Timeout.${name} を抽出できませんでした`);
  return Number(match[1]);
}

test("launch の猶予は BridgeClient.Timeout.session と一致する", () => {
  assert.equal(serveCommandAllowanceMs({ cmd: "launch", bundle: "com.example" }), swiftSeconds("session") * 1000);
});

test("install の猶予は BridgeClient.Timeout.physicalInstall と一致する", () => {
  assert.equal(serveCommandAllowanceMs({ cmd: "install", path: "/tmp/x.app" }), swiftSeconds("physicalInstall") * 1000);
});
