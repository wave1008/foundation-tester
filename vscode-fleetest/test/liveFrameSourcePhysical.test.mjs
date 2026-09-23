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
  assert.match(region, /device\?\.platform === "ios"[\s\S]*&& !physical[ )]/,
    "iOS の simstream 分岐の条件に「実機でない」を含めること");
});

// ブリッジの無い台(booted)へ切り替えたら観測を1回撃つ。serve の自動起動の引き金は観測・操作の
// 接続拒否だけで、自動のフレーム取得は起動を撃たない(ApiLiveCommand.emitFrame)。撃たないと
// 「接続できません」のまま何も始まらない(実地 2026-09-24: iPhone wave)。
function methodBody(source, marker) {
  const start = source.indexOf(marker);
  assert.notEqual(start, -1, `${marker} が見つからない`);
  return source.slice(start, source.indexOf("\n  }", start));
}

test("booted の台へ切り替えたら観測を撃つ(切り替えの全経路が通る ensureServeProcess から)", () => {
  const source = codeOnly(fs.readFileSync(path.join(root, "src/monitorLiveController.ts"), "utf8"));
  assert.match(methodBody(source, "private ensureServeProcess(device: LiveDeviceRef): void {"),
    /if \(switched\) \{\s*this\.requestOpenObservation\(\);/, "台が変わったら観測を予約すること");
  const request = methodBody(source, "private requestOpenObservation(): void {");
  assert.match(request, /state !== "booted"\) \{\s*return;/, "撃つのは booted のときだけ");
  assert.match(request, /if \(this\.busy\) \{\s*this\.openObservationPending = true;/,
    "busy の間は控える(refreshSnapshot は busy なら何もしない)");
});

// busy の間に届いた「ライブ操作」(openDevice)と観測の控えは、busy が解けた時点で消化する。
// busy の原因が画面取得・操作だと applyDevices が来ず、選択が黙って捨てられていた。
test("busy が解けたら保留中の選択と観測を消化する", () => {
  const source = codeOnly(fs.readFileSync(path.join(root, "src/monitorLiveController.ts"), "utf8"));
  const setBusy = methodBody(source, "private setBusy(busy: boolean): void {");
  assert.match(setBusy, /this\.pendingSelectId = undefined;\s*void this\.openDevice\(pendingId\);/,
    "保留中の選択を開くこと");
  assert.match(setBusy, /this\.openObservationPending = false;\s*void this\.refreshSnapshot\(\);/,
    "控えた観測を撃つこと");
});

// 一覧に無い台(他の機械のタイル = `ios:<machine>/<name>`)を指定されたら、黙って前の台を続けず理由を言う。
// 黙ると前の台の画面が出続け、開いたつもりの台と違う画面になる(実地 2026-09-24: M1Ultra の iPhone wave)。
test("一覧に無い台を開こうとしたらバナーで言う", () => {
  const source = codeOnly(fs.readFileSync(path.join(root, "src/monitorLiveController.ts"), "utf8"));
  const open = methodBody(source, "private async openDevice(id: string): Promise<void> {");
  assert.match(open,
    /if \(this\.selectedDeviceId !== id\) \{[\s\S]*this\.devices\.every\(\(device\) => device\.id !== id\)[\s\S]*t\("live\.deviceNotOpenable", \{ id \}\)/,
    "選べなかったときに live.deviceNotOpenable を出すこと");
});

// 他の機械の台は serve を向こうで起こし(remote exec)、配信(この Mac の台しか映せない)は張らない。
// 一覧を取り直しても消えないよう applyDevices が足し戻す(消えると選択が先頭の台へ戻る)。
test("他の機械の台: serve は remote exec で起こし・配信は張らず・一覧の取り直しで消さない", () => {
  const source = codeOnly(fs.readFileSync(path.join(root, "src/monitorLiveController.ts"), "utf8"));
  assert.match(methodBody(source, "private startServeProcess(device: LiveDeviceRef): void {"),
    /const args = device\.machine \? \["remote", "exec", device\.machine, "--", \.\.\.serveArgs\] : serveArgs;/,
    "machine があれば remote exec で包むこと");
  const frame = methodBody(source, "private updateLiveFrameSource(): void {");
  assert.match(frame, /const remote = device\?\.machine !== undefined;/, "他の機械の台かを見ること");
  assert.match(frame, /&& !physical && !remote\) \{/, "iOS の配信分岐から他の機械の台を除くこと");
  assert.match(frame, /device\.serial &&\s*!remote\s*\) \{/, "Android の配信分岐から他の機械の台を除くこと");
  assert.match(methodBody(source, "private applyDevices(listed: LiveDeviceOption[], bannerMessage: string | undefined): void {"),
    /const options = \[\.\.\.listed\.filter\(\(o\) => !this\.remoteOptions\.has\(o\.id\)\), \.\.\.this\.remoteOptions\.values\(\)\];/,
    "一覧の取り直しで他の機械の台を足し戻すこと");
});
