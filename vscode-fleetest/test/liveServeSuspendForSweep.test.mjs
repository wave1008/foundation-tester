// 「全て終了」の前に拡張が自分のライブ操作の serve を畳み、終わったら立て直すことのソース走査。
//
// serve は台の印(`.fleetest/mcp-<鍵>.lease`)を書くので、畳まずに全掃討(`devices down`)を撃つと
// CLI の sweepRefusal がその印で丸ごと断り、「MCP session が駆動中(fleetest-mcp pid …)」という
// 事実と違う名指しのトーストだけが出て1台も止まらない(実地 2026-09-24: ライブ操作タブで実機
// iPhone を開いたまま「全て終了」)。
//
// MonitorLiveController は vscode 依存でスタブでは作れないため、liveServeRebindWait.test.mjs と
// 同じく host 側の配線を走査で守る。

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

/** コメント行を落とす(理由書きに関数名が出るので、素で走査すると実装を消しても緑になる) */
function codeOnly(source) {
  return source
    .split("\n")
    .filter((line) => !line.trim().startsWith("//") && !line.trim().startsWith("*") && !line.trim().startsWith("/*"))
    .join("\n");
}

function read(rel) {
  return codeOnly(fs.readFileSync(path.join(root, rel), "utf8"));
}

function body(source, marker) {
  const start = source.indexOf(marker);
  assert.notEqual(start, -1, `${marker} が見つからない`);
  const end = source.indexOf("\n  }", start);
  assert.notEqual(end, -1, `${marker} の本体末尾が見つからない`);
  return source.slice(start, end);
}

test("「全て終了」は serve を畳んで(close を待って)から enqueue し、キューが空いたら立て直す", () => {
  const panel = read("src/monitorPanel.ts");
  const fn = body(panel, "private async confirmThenBulkDown(): Promise<void> {");
  const suspend = fn.indexOf("await this.live.suspendServeForSweep()");
  const enqueue = fn.indexOf('enqueueLifecycleJob({ kind: "bulk", op: "down" })');
  const idle = fn.indexOf("await this.deviceOps.whenLifecycleQueueIdle()");
  const resume = fn.indexOf("this.live.resumeServeAfterSweep()");
  assert.ok(suspend >= 0 && enqueue > suspend, "畳む(await)のが enqueue より前");
  assert.ok(idle > enqueue && resume > idle, "立て直すのはキューが空いた後");
});

test("畳んでいる間は serve を起動しない(掃討の途中で印を書き戻さない)", () => {
  const controller = read("src/monitorLiveController.ts");
  const start = body(controller, "private startServeProcess(device: LiveDeviceRef): void {");
  assert.match(start, /^\s*if \(this\.serveSuspendedForSweep\) \{\s*return;/m,
    "startServeProcess の先頭で抑止する(再バインド・5秒後の自動再起動のどちらもここを通る)");
  const suspend = body(controller, "async suspendServeForSweep(): Promise<void> {");
  assert.match(suspend, /this\.serveSuspendedForSweep = true;[\s\S]*this\.serveProcess = undefined;/,
    "抑止フラグを立ててから参照を手放す");
  assert.match(suspend, /proc\.once\("close", done\);\s*this\.killServeProcess\(proc\);/,
    "close の待ち手を登録してから止める(先に止めると close を取り逃がす)");
  assert.match(suspend, /setTimeout\(done, SERVE_SWEEP_STOP_WAIT_MS\)/, "待ちに上限を置く");
  const resume = body(controller, "resumeServeAfterSweep(): void {");
  assert.match(resume, /this\.serveSuspendedForSweep = false;[\s\S]*this\.refreshDevices\(\)/,
    "抑止を解いてから refreshDevices の既存経路で立て直す");
});
