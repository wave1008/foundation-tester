// 一括操作(bulkOpActive)の実機ポリシー(ユーザー決定 2026-09-08)。
//
// 一括起動(bulkOp:'up')は実機も対象にする —— CLI 側は `api start-all-devices` が実機の
// ブリッジも別レーンで起動し deviceStarting/deviceFinished を流す(このテストの対象外)。
// webview は CLI が個々の実機へ到達するまでの間、「未起動」の実機タイルを仮想デバイスと同じ
// 「待機中」プレースホルダ+「ブリッジ起動待機」チップで見せる(deviceTiles.js の renderFrame の
// waitingUp と renderMeta の起動待機チップ)。CLI が到達すると deviceOpBusy(op:'up') が飛び、
// 「ブリッジを起動中」表示に切り替わる(physicalBridgeStarting が waitingUp より優先)。
//
// 一括終了(bulkOp:'down')は従来どおり実機タイルに触らない(端末の電源が触れないため。
// ここは変更していないので旧テストをそのまま残す)。
//
// タイル単体操作(entry.opBusy。右クリックの「ブリッジを起動/停止」)は一括操作と無関係に
// 従来どおり効く必要があるので、そちらも別途確認する。
//
// 実 HTML+実バンドルを jsdom で動かす方式は webviewWipeTile.test.mjs と同じ。

import assert from "node:assert/strict";
import { createRequire } from "node:module";
import path from "node:path";
import { before, test } from "node:test";
import * as esbuild from "esbuild";
import { JSDOM } from "jsdom";

const require2 = createRequire(import.meta.url);

let panelHtml;
let webviewBundle;

before(async () => {
  const htmlBuild = await esbuild.build({
    entryPoints: [path.resolve("src/monitorHtml.ts")],
    bundle: true,
    platform: "node",
    format: "cjs",
    target: "node18",
    write: false,
    external: ["vscode"],
    logLevel: "silent",
  });
  const vscodeStub = { Uri: { joinPath: (_base, ...segs) => ({ path: `/${segs.join("/")}` }) } };
  const patchedRequire = (id) => (id === "vscode" ? vscodeStub : require2(id));
  const mod = { exports: {} };
  new Function("module", "exports", "require", htmlBuild.outputFiles[0].text)(mod, mod.exports, patchedRequire);
  const webviewStub = { asWebviewUri: (uri) => `https://localhost${uri.path}`, cspSource: "https://localhost" };
  panelHtml = mod.exports.renderHtml(webviewStub, { path: "" });

  const mainBuild = await esbuild.build({
    entryPoints: [path.resolve("src/webview/monitor/main.js")],
    bundle: true,
    platform: "browser",
    format: "iife",
    target: "es2022",
    write: false,
    logLevel: "silent",
  });
  webviewBundle = mainBuild.outputFiles[0].text;
});

function createWebview() {
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({ postMessage: () => {}, setState: () => {}, getState: () => undefined });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document };
}

function post(window, data) {
  window.dispatchEvent(new window.MessageEvent("message", { data }));
}

function tiles(document) {
  return [...document.querySelectorAll("#grid .tile")];
}

/** そのタイルが画像を出しているか(出していなければプレースホルダ) */
function showsImage(tile) {
  return tile.querySelector(".frame-wrap img") !== null;
}

function placeholderText(tile) {
  return tile.querySelector(".frame-placeholder")?.textContent ?? "";
}

/** ヘッダー(実際は tile-footer 先頭)の「起動待機」チップが見えているか。className は
 * deviceTiles.js createTile の queuedBadge('badge badge-queued')と一致させること。 */
function queuedChipVisible(tile) {
  const el = tile.querySelector(".badge-queued");
  return !!el && el.style.display !== "none";
}

function queuedChipText(tile) {
  return tile.querySelector(".badge-queued")?.textContent ?? "";
}

test("一括起動(bulkOp:up)はオフラインの実機タイルも待機中にする", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, {
    type: "devices",
    devices: [
      {
        id: "android:Emu 2", name: "Emu 2", platform: "android", state: "offline", kind: "virtual",
        serial: "emulator-5556", recording: false,
      },
      {
        id: "ios:iPhone 実機", name: "iPhone 実機", platform: "ios", state: "offline", kind: "physical",
        udid: "00008130-AAAA", recording: false,
      },
    ],
  });

  const [virtualTile, physicalTile] = tiles(document);

  post(window, { type: "bootBusy", busy: true, bulkOp: "up" });

  // 仮想デバイスは従来どおり「待機中」(wvMonitor.tile.waiting)+「起動待機」チップ
  assert.match(placeholderText(virtualTile), /待機中/);
  assert.equal(queuedChipVisible(virtualTile), true);
  assert.match(queuedChipText(virtualTile), /起動待機/);

  // 実機も一括起動の対象 —— offline の実機は仮想デバイスと同じ「待機中」プレースホルダ+
  // 「ブリッジ起動待機」チップ(実機専用文言)を出す
  assert.match(placeholderText(physicalTile), /待機中/);
  assert.equal(queuedChipVisible(physicalTile), true);
  assert.match(queuedChipText(physicalTile), /ブリッジ起動待機/);
});

test("一括起動(bulkOp:up)は state:booted でブリッジ不在の実機も待機中にし、CLI 到達後は起動中表示へ切り替わる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  // iOS 実機の state:'booted' は「端末は接続済みだがブリッジが無い」の意味(deviceBridgeNotRunning
  // のコメント参照)。offline とは別の未起動の形として実機だけが取りうる
  post(window, {
    type: "devices",
    devices: [
      {
        id: "ios:iPhone 実機", name: "iPhone 実機", platform: "ios", state: "booted", kind: "physical",
        udid: "00008130-DDDD", recording: false,
      },
    ],
  });

  const [physicalTile] = tiles(document);

  post(window, { type: "bootBusy", busy: true, bulkOp: "up" });

  assert.match(placeholderText(physicalTile), /待機中/);
  assert.equal(queuedChipVisible(physicalTile), true);
  assert.match(queuedChipText(physicalTile), /ブリッジ起動待機/);

  // CLI がこの実機に到達(deviceStarting 相当)
  post(window, { type: "deviceOpBusy", name: "iPhone 実機", op: "up", status: "running" });

  assert.match(placeholderText(physicalTile), /ブリッジを起動中/);
  assert.equal(queuedChipVisible(physicalTile), false, "起動中に切り替わったらチップは隠れる");

  // 操作完了(deviceFinished 相当)。次の devices サイクルが観測に追いつくまでは
  // awaitingStateAfterUp が「起動中」表示を保つ(applyDeviceOpBusy のコメント参照) ——
  // 「ブリッジ起動待機」の古いチップに戻って固まらないことを確かめる
  assert.doesNotThrow(() => post(window, { type: "deviceOpBusy", name: "iPhone 実機", op: null, status: null }));

  assert.match(placeholderText(physicalTile), /ブリッジを起動中/);
  assert.equal(queuedChipVisible(physicalTile), false, "完了直後もチップが古い文言で出っぱなしにならない");
});

test("一括終了(bulkOp:down)は接続中の実機タイルをシャットダウン中にしない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, {
    type: "devices",
    devices: [
      {
        id: "android:Emu 3", name: "Emu 3", platform: "android", state: "connected", kind: "virtual",
        serial: "emulator-5557", recording: false,
      },
      {
        id: "ios:iPhone Live", name: "iPhone Live", platform: "ios", state: "connected", kind: "physical",
        udid: "00008130-BBBB", recording: false,
      },
    ],
  });
  for (const device of ["android:Emu 3", "ios:iPhone Live"]) {
    post(window, { type: "frame", device, jpegBase64: "AAAA", width: 100, height: 200 });
  }

  const [virtualTile, physicalTile] = tiles(document);
  assert.equal(showsImage(virtualTile), true, "前提: 開始前はライブ映像が出ている");
  assert.equal(showsImage(physicalTile), true, "前提: 開始前はライブ映像が出ている");

  post(window, { type: "bootBusy", busy: true, bulkOp: "down" });

  // 仮想デバイスは従来どおり最終フレームを止めてシャットダウン中表示(wvMonitor.tile.shuttingDown)
  assert.equal(showsImage(virtualTile), false);
  assert.match(placeholderText(virtualTile), /シャットダウン中/);

  // 実機は一括終了の対象外(変更していない) —— 一括操作では触られていないのでライブ映像を出したまま
  assert.equal(showsImage(physicalTile), true, "実機は bulkOpActive==='down' の対象外なのでライブ映像を残す");
});

test("実機タイル単体のブリッジ停止(opBusy)は一括操作と無関係に従来どおり効く", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, {
    type: "devices",
    devices: [
      {
        id: "ios:iPhone Live", name: "iPhone Live", platform: "ios", state: "connected", kind: "physical",
        udid: "00008130-CCCC", recording: false,
      },
    ],
  });
  post(window, { type: "frame", device: "ios:iPhone Live", jpegBase64: "AAAA", width: 100, height: 200 });

  const [physicalTile] = tiles(document);
  assert.equal(showsImage(physicalTile), true, "前提: ライブ映像が出ている");

  // 一括終了が別途進行中でも(=bulkOpActive==='down')実機タイルはそれだけでは変化しない
  post(window, { type: "bootBusy", busy: true, bulkOp: "down" });
  assert.equal(showsImage(physicalTile), true, "一括操作それ自体では実機タイルは変化しない");

  // 右クリック「ブリッジを停止」= タイル単体の deviceOpBusy(op:'down', status:'running')
  post(window, { type: "deviceOpBusy", name: "iPhone Live", op: "down", status: "running" });

  assert.equal(showsImage(physicalTile), false, "単体のブリッジ停止操作は無効化していない");
  // 実機は端末そのものを止めないので「シャットダウン中」ではない(止まるのはブリッジだけ)
  assert.match(placeholderText(physicalTile), /ブリッジを停止中/);
  assert.doesNotMatch(placeholderText(physicalTile), /シャットダウン中/);
});
