// マシン名を省略したときの既定名(= host のホスト部)。**規則が JS と Swift で割れると、
// 入力欄のウォーターマークが予告した名前と実際に登録される名前が食い違う**
// (プロファイルの machine 欄は前者を見て書かれるので、run が「そんなマシンは無い」で落ちる)。
//
// process.cwd() は npm test 実行時に vscode-fleetest ルート。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { defaultMachineForHost, normalizeRemoteHosts } from "../src/remoteRunArgs";

const CASES = [
  ["user@m1max.local", "m1max.local"],
  ["m1max.local", "m1max.local"],
  ["192.168.1.20", "192.168.1.20"],
  ["  user@192.168.1.20  ", "192.168.1.20"],
  ["wave@host@weird", "weird"], // 最後の @ で切る(user 名に @ は入らない)
  ["", ""],
];

test("host からマシン名を採る(user@ を落とす)", () => {
  for (const [host, expected] of CASES) {
    assert.equal(defaultMachineForHost(host), expected, host);
  }
});

test("正規化でも machine 空欄は host のホスト部で埋まる(user@ が残らない)", () => {
  const [entry] = normalizeRemoteHosts([{ machine: "", host: "user@m1ultra.local", dir: "" }]);
  assert.equal(entry.machine, "m1ultra.local");
});

test("Swift 側(RemoteHostRegistry.defaultMachine)と同じ規則である", () => {
  const swift = readFileSync(
    path.join(process.cwd(), "..", "Sources/FTRemote/RemoteHostRegistry.swift"), "utf8");
  const body = swift.match(/func defaultMachine\(forHost[\s\S]*?\n    \}/);
  assert.ok(body, "defaultMachine(forHost:) が見つかりません");
  // 同じ2つの規則(最後の @ で切る / 前後の空白を落とす)が両実装にあること
  assert.match(body[0], /lastIndex\(of: "@"\)/,
    "Swift 側が最後の @ で切っていません(JS と規則が割れる)");
  assert.match(body[0], /trimmingCharacters/, "Swift 側が空白を落としていません");
  const ts = readFileSync(path.join(process.cwd(), "src/remoteRunArgs.ts"), "utf8");
  const jsBody = ts.match(/export function defaultMachineForHost[\s\S]*?\n\}/);
  assert.ok(jsBody, "defaultMachineForHost が見つかりません");
  assert.match(jsBody[0], /lastIndexOf\("@"\)/);
  assert.match(jsBody[0], /trim\(\)/);
});
