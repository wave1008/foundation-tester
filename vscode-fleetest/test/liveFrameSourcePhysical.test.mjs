// ライブ操作の映像の供給元が **iOS 実機に simstream を使わない**ことのソース走査。
//
// simstream は CoreSimulator の私有 API = シミュレータ専用で、実機の UDID は「invalid UDID」で即終了する。
// それでも起こすと StreamPipeline が再起動を繰り返し、その間は frameTick が「配信中」と見て
// ポーリングもしない = 新しい台の絵が来ず、前の台の画面が出たままになった(2026-09-24 の実害:
// Android 実機 → iOS 実機)。モニターのタイル(monitorDeviceStreamController.ts)は以前から
// 実機を devicepoll へ分けている。
//
// MonitorLiveController は vscode.ExtensionContext 等が要りスタブでは作れないため、
// liveServeRebindWait.test.mjs と同じく配線を走査で守る。

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

function codeOnly(source) {
  return source
    .split("\n")
    .filter((line) => !line.trim().startsWith("//") && !line.trim().startsWith("*") && !line.trim().startsWith("/*"))
    .join("\n");
}

test("iOS の simstream 分岐は実機を除く", () => {
  const source = codeOnly(fs.readFileSync(path.join(root, "src/monitorLiveController.ts"), "utf8"));
  const start = source.indexOf("private updateLiveFrameSource(): void {");
  assert.notEqual(start, -1, "updateLiveFrameSource が見つからない");
  const simStream = source.indexOf("resolveSimStream(config)", start);
  assert.notEqual(simStream, -1, "simstream の分岐が見つからない");
  const region = source.slice(start, simStream);
  assert.match(region, /const physical = this\.selectedOption\(\)\?\.kind === "physical";/,
    "選択中の台が実機かを見ること");
  assert.match(region, /device\?\.platform === "ios"[\s\S]*&& !physical\)/,
    "iOS の simstream 分岐の条件に「実機でない」を含めること");
});
