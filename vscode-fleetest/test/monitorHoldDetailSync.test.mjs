// hold 中のタイル表示は言語境界を跨ぐ文字列契約で繋がっている:
// Swift 側(ApiMonitorCommand.swift)が detail に "held (fleetest monitor resume)" を載せ、
// webview 側(deviceTiles.js)が接頭辞 'held' で「モニタ停止中」表示へ切り替える。
// 型検査が効かないので、両側の文字列の同時存在をソース走査で縛る(片方だけ変えると落ちる)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");

test("monitor hold: the Swift detail literal and the webview prefix key stay in sync", () => {
  const swift = readFileSync(
    path.join(root, "..", "Sources", "fleetest", "ApiMonitorCommand.swift"), "utf8");
  assert.match(swift, /detail: "held \(fleetest monitor resume\)"/,
    "ApiMonitorCommand.swift no longer emits the 'held (fleetest monitor resume)' detail" +
    " — update deviceTiles.js (monitorPaused) together");
  const tiles = readFileSync(
    path.join(root, "src", "webview", "monitor", "deviceTiles.js"), "utf8");
  assert.match(tiles, /\.startsWith\('held'\)/,
    "deviceTiles.js no longer keys on the 'held' prefix — update ApiMonitorCommand.swift together");
});
