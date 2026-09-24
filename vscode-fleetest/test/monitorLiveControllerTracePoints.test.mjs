// monitorLiveController.ts の tracePoints ハンドラ(軌跡モード)のソース走査。
// MonitorLiveController は vscode.ExtensionContext 等が要りスタブでは作れないため、host 側の
// 配線は liveSnapshotCacheRebind.test.mjs と同じ方針で走査して守る。webview 側の挙動
// (トグル/Shift でどちらの型のメッセージを送るか)は webviewLiveDrag.test.mjs が実 DOM で見る。
//
// 守っているのは3つ:
//   ①snapshot 未取得(lastScreen 無し)なら送らないこと(他のポインタ操作ハンドラと同じ規律)
//   ②点の座標は pointFromClick で device 座標へ、時刻は /1000 で秒へ変換すること
//     (GestureRequest.t は秒。webview は ms で送る)
//   ③時間を縮めないこと(利用者の決定: なぞった時間どおりに再生する)。上限の判定は
//     liveModel.gestureCapFor(値は liveModel.test.mjs が見る)を通し、応答待ちは再生時間ぶん延ばす

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

function tracePointsCaseBody() {
  const source = controllerSource();
  const start = source.indexOf('case "tracePoints": {');
  assert.notEqual(start, -1, 'case "tracePoints": が見つからない');
  const end = source.indexOf('case "pressPoint": {', start);
  assert.notEqual(end, -1, "tracePoints ケースの終端(次の case)が見つからない");
  return source.slice(start, end);
}

test("tracePoints: snapshot 未取得(lastScreen 無し)なら送らない", () => {
  const body = tracePointsCaseBody();
  assert.match(body, /if \(!this\.lastScreen\)/, "他のポインタ操作ハンドラと同じ規律で断ること");
});

test("tracePoints: 座標は pointFromClick で device 座標へ、時刻は /1000 で秒へ変換する", () => {
  const body = tracePointsCaseBody();
  assert.match(body, /pointFromClick\(/, "座標変換は既存のドラッグと同じ経路を通ること");
  assert.match(body, /p\.t \/ 1000/, "ms → 秒の変換を行うこと(GestureRequest.t は秒)");
});

test("tracePoints: 時間を縮めず、上限は gestureCapFor で決めて長すぎるものは断る", () => {
  const body = tracePointsCaseBody();
  assert.doesNotMatch(body, /\/ totalSeconds/, "点の時刻を比率で縮めないこと");
  assert.match(body, /gestureCapFor\(totalSeconds\)/, "上限の判定は gestureCapFor を通すこと");
  assert.match(body, /"tooLong"[\s\S]*postActionError\(t\("live\.traceTooLong"/, "絶対上限を超えたら送らずに断ること");
  assert.match(body, /maxGestureSeconds: cap/, "既定上限を超えたらこの1回だけ上限を上げること");
});

test("serve への応答待ちは軌跡の再生時間ぶん延ばす", () => {
  const source = controllerSource();
  assert.match(source, /SERVE_REQUEST_TIMEOUT_MS \+ serveCommandPlaybackMs\(command\)/);
});

test("tracePoints: gesture コマンドを組み立て、RecordedStep(gesture)も同じ点列から作る", () => {
  const body = tracePointsCaseBody();
  assert.match(body, /cmd: "gesture", fingers/, "serve へ gesture コマンドを送ること");
  assert.match(body, /recordedGestureFingers\(fingers, screen\)/,
    "レコーディング用の RecordedStep も同じ(変換・縮小済みの)fingers から作ること"
    + "(mcp 表示と記録で別のロジックを持たない)");
});
