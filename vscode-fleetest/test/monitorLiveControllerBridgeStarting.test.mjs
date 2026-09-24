// monitorLiveController.ts の bridgeStarting(LiveBridgeAutoStarter が自動起動を進行中かどうか。
// 契約: Sources/fleetest/ApiLiveCommand.swift 冒頭)配線のソース走査。
// MonitorLiveController は vscode.ExtensionContext 等が要りスタブでは作れないため、
// monitorLiveControllerTracePoints.test.mjs と同じ方針で走査して守る:
//   ①frameTick は bridgeStarting 中の失敗を handleFrameFailure(接続断のエラー表示)へ回さないこと
//   ②applySnapshotResult は bridgeStarting 中の失敗を postActionError(エラー表示)へ回さないこと
//   ③runAction の action 失敗は bridgeStarting 中だけ中立の案内(live.bridgeStartingActionNotice)を
//     neutral:true で出し、撃ち直さないこと
//   ④postActionError(neutral) が neutral のときも connectionBannerShown を立てること
//     (serve 復帰[handleConnectionOk]で自動的に消えるようにするため)

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

function controllerSource() {
  return codeOnly(fs.readFileSync(path.join(root, "src/monitorLiveController.ts"), "utf8"));
}

function methodBody(source, methodStartNeedle, nextMethodNeedle) {
  const start = source.indexOf(methodStartNeedle);
  assert.notEqual(start, -1, `${methodStartNeedle} が見つからない`);
  const end = source.indexOf(nextMethodNeedle, start);
  assert.notEqual(end, -1, `${nextMethodNeedle} が見つからない(終端の切り出しに失敗)`);
  return source.slice(start, end);
}

test("frameTick: bridgeStarting 中の失敗は handleFrameFailure へ回さない", () => {
  const body = methodBody(
    controllerSource(),
    "private async frameTick(): Promise<void> {",
    "private async runAction(",
  );
  assert.match(body, /this\.applyBridgeStarting\(frame\.bridgeStarting\)/,
    "frameTick が frame.bridgeStarting を applyBridgeStarting へ渡していない");
  assert.match(body, /else if \(!frame\.bridgeStarting\) \{\s*\n\s*this\.handleFrameFailure\(frame\.error\)/,
    "handleFrameFailure は !frame.bridgeStarting のときだけ呼ぶこと"
    + "(起動中の失敗をエラー扱いしない)");
});

test("applySnapshotResult: bridgeStarting 中の失敗は postActionError へ回さない", () => {
  const body = methodBody(
    controllerSource(),
    "private applySnapshotResult(result: LiveSnapshot | LiveErrorResult): void {",
    "private async fetchSnapshot(): Promise<void> {",
  );
  assert.match(body, /this\.applyBridgeStarting\(result\.bridgeStarting\)/,
    "applySnapshotResult が result.bridgeStarting を applyBridgeStarting へ渡していない");
  const notOkRange = body.indexOf("if (!result.ok) {");
  assert.notEqual(notOkRange, -1, "!result.ok の分岐が見当たらない");
  const notOkBody = body.slice(notOkRange, body.indexOf("this.handleConnectionOk();"));
  assert.match(notOkBody, /if \(result\.bridgeStarting\) \{\s*\n\s*return;/,
    "起動中の失敗はここで return し、postActionError を撃たないこと");
});

test("runAction: action の失敗は bridgeStarting のときだけ中立の案内(neutral:true)を出す", () => {
  const body = methodBody(
    controllerSource(),
    "private async runAction(",
    "private async runTapAtPoint(",
  );
  assert.match(body, /if \(action\) \{\s*\n\s*this\.applyBridgeStarting\(action\.bridgeStarting\)/,
    "runAction が action.bridgeStarting を applyBridgeStarting へ渡していない");
  assert.match(
    body,
    /if \(action\.bridgeStarting\) \{\s*\n\s*this\.postActionError\(t\("live\.bridgeStartingActionNotice"\), true\)/,
    "action.bridgeStarting のときは live.bridgeStartingActionNotice を neutral:true で出すこと",
  );
  assert.match(body, /\} else \{\s*\n\s*this\.postActionError\(action\.error\);/,
    "bridgeStarting でない通常の失敗は従来どおり action.error を出すこと");
});

test("postActionError: neutral のときも connectionBannerShown を立てる(serve 復帰で自動的に消えるように)", () => {
  const body = methodBody(
    controllerSource(),
    "private postActionError(message: string, neutral = false): void {",
    "private applyBridgeStarting(",
  );
  assert.match(body, /this\.connectionBannerShown = neutral \|\| isConnectionClassMessage\(message\)/,
    "neutral のときも connectionBannerShown を立てること");
  assert.match(body, /neutral \? \{ neutral: true \} : \{\}/,
    "neutral:true は webview へ送る actionError メッセージにも載せること");
});

// 配信中は frameTick が止まるので、serve に聞き直さないと起動が済んでも「接続中」が消えない
// (実地 2026-09-24: 17:44:24 に serve が起動成功を記録した後も表示が残り続けた)
test("接続中の間は観測を撃ち直し、観測の後で自分から予約を掛け直す", () => {
  const src = controllerSource();
  const apply = methodBody(src, "private applyBridgeStarting(starting: boolean): void {",
    "private scheduleBridgeStartingProbe(");
  assert.match(apply, /if \(starting\) \{\s*\n\s*this\.scheduleBridgeStartingProbe\(\);/,
    "表示を出したら撃ち直しを予約すること");
  assert.match(apply, /this\.clearBridgeStartingProbe\(\);/, "表示を畳んだら予約を消すこと");
  const probe = methodBody(src, "private scheduleBridgeStartingProbe(): void {",
    "private clearBridgeStartingProbe(");
  assert.match(probe, /await this\.refreshSnapshot\(\);/, "観測を撃つこと");
  assert.match(probe, /if \(this\.bridgeStartingShown[^)]*\) \{\s*\n\s*this\.scheduleBridgeStartingProbe\(\);/,
    "起動中のままなら観測の後で自分から掛け直すこと(applyBridgeStarting は値が同じだと何もしない)");
});

test("serve を止めるときは接続中の表示ごと解く(予約だけ消すと次の serve で掛からない)", () => {
  const body = methodBody(controllerSource(), "private stopServeProcess(): void {", "private killServeProcess(");
  assert.match(body, /this\.applyBridgeStarting\(false\);/);
});
