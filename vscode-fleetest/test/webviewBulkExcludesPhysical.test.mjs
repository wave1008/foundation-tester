// 一括操作(bulkOpActive)は実機を対象にしない(2026-08-30 のユーザー決定)。
//
// 背景: 実機は端末そのものを起動・終了できず(端末が触れるのはブリッジだけ)、一括起動に
// 実機が混ざると XCUITest ランナーのビルド+インストールに数分かかるうえ、固定2台の同時起動枠
// の半分を占有して他の台の起動を遅らせていた。CLI 側は devices up/down 等から実機を除外する
// (このテストの対象外)。ここは webview 表示側 —— deviceTiles.js の renderFrame(shuttingDown/
// waitingUp)と renderMeta(起動待機チップ)が bulkOpActive を見て実機タイルまで
// 「待機中」「シャットダウン中」に染めてしまわないかを確かめる。
//
// タイル単体操作(entry.opBusy。右クリックの「ブリッジを起動/停止」)は実機でも従来どおり
// 効く必要がある(ブリッジ自体の起動/停止は個別に残る)ので、そちらも別途確認する。
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

test("一括起動(bulkOp:up)はオフラインの実機タイルを待機中にしない", (t) => {
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

  // 仮想デバイスは従来どおり「待機中」(wvMonitor.tile.waiting)
  assert.match(placeholderText(virtualTile), /待機中/);
  assert.equal(queuedChipVisible(virtualTile), true, "仮想デバイスの起動待機チップは出る(この確認が無いと Change 2 の欠落を見逃す)");
  assert.match(queuedChipText(virtualTile), /起動待機/);

  // 実機は一括操作の対象外 —— bulkOpActive だけでは「待機中」にならず、通常の
  // オフライン表示(wvMonitor.deviceState.offline)のまま
  assert.doesNotMatch(placeholderText(physicalTile), /待機中/);
  assert.match(placeholderText(physicalTile), /未起動/);
  assert.equal(queuedChipVisible(physicalTile), false, "実機の起動待機チップは出てはいけない(Change 2)");
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

  // 実機は一括終了の対象外 —— 一括操作では触られていないのでライブ映像を出したまま
  assert.equal(showsImage(physicalTile), true, "実機は bulkOpActive の対象外なのでライブ映像を残す");
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

  assert.equal(showsImage(physicalTile), false, "単体のブリッジ停止操作は Change 1 で無効化していない");
  assert.match(placeholderText(physicalTile), /シャットダウン中/);
});
