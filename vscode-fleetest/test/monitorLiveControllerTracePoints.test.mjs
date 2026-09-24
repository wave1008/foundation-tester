// monitorLiveController.ts の tracePoints ハンドラ(軌跡モード)のソース走査。
// MonitorLiveController は vscode.ExtensionContext 等が要りスタブでは作れないため、host 側の
// 配線は liveSnapshotCacheRebind.test.mjs と同じ方針で走査して守る。webview 側の挙動
// (トグル/Shift でどちらの型のメッセージを送るか)は webviewLiveDrag.test.mjs が実 DOM で見る。
//
// 守っているのは3つ:
//   ①snapshot 未取得(lastScreen 無し)なら送らないこと(他のポインタ操作ハンドラと同じ規律)
//   ②点の座標は pointFromClick で device 座標へ、時刻は /1000 で秒へ変換すること
//     (GestureRequest.t は秒。webview は ms で送る)
//   ③合計が 8 秒を超えたら全点を比例縮小すること(dragPoints と同じ 8 秒クランプ。
//     serve のリクエストタイムアウト 20 秒に近づけない)

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

test("tracePoints: 合計8秒を超えたら全点を比例縮小する(dragPoints と同じ8秒クランプ)", () => {
  const body = tracePointsCaseBody();
  assert.match(body, /totalSeconds > 8/, "8秒を超えたときだけ縮小すること");
  assert.match(body, /8 \/ totalSeconds/, "縮小は比率(全点を同じ比率で縮める)で行うこと");
});

test("tracePoints: gesture コマンドを組み立て、RecordedStep(gesture)も同じ点列から作る", () => {
  const body = tracePointsCaseBody();
  assert.match(body, /cmd: "gesture", fingers/, "serve へ gesture コマンドを送ること");
  assert.match(body, /recordedGestureFingers\(fingers, screen\)/,
    "レコーディング用の RecordedStep も同じ(変換・縮小済みの)fingers から作ること"
    + "(mcp 表示と記録で別のロジックを持たない)");
});
