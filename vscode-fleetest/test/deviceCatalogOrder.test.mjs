// プロジェクトのデバイスカタログ(config.ts の listProjectDeviceCatalog)の並び順・重複排除。
// カタログは全実行プロファイル(profiles/runs/*.json)の devices[] の和集合で、
// **ファイル名順に読み、鍵 (platform, machine, name) の先着(最初に見つかった方)を採用する**
// (どちらの本体で表現しても同じ実体を指すため。表示順の並べ替えは webview 側の責務で、
// ここでは持たない)。
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { test } from "node:test";
import { listProjectDeviceCatalog } from "../src/config.ts";

/** profiles/runs/<name>.json を複数持つワークスペースを作る。files は { "<name>.json": <object> }。 */
function workspaceWith(files) {
  const ws = fs.mkdtempSync(path.join(os.tmpdir(), "ftdc-"));
  const dir = path.join(ws, "TestProjects", "P", "profiles", "runs");
  fs.mkdirSync(dir, { recursive: true });
  for (const [name, profile] of Object.entries(files)) {
    fs.writeFileSync(path.join(dir, name), JSON.stringify(profile));
  }
  return ws;
}

test("ファイル名順に読み、devices[] を連結する(1ファイルの中では記載順)", () => {
  const ws = workspaceWith({
    "a-ios.json": { app: "x", devices: [{ platform: "ios", name: "iPhone-01" }] },
    "b-android.json": { app: "x", devices: [{ platform: "android", name: "Pixel-01" }] },
  });
  const catalog = listProjectDeviceCatalog(ws, "P");
  assert.deepEqual(catalog.map((d) => d.name), ["iPhone-01", "Pixel-01"]);
});

test("同じ (platform, machine, name) は先に見つかった方(ファイル名順で先)を採用する", () => {
  const ws = workspaceWith({
    "a.json": { app: "x", devices: [{ platform: "ios", machine: "local", name: "iPhone-01", port: 8100 }] },
    "b.json": { app: "y", devices: [{ platform: "ios", machine: "local", name: "iPhone-01", port: 9999 }] },
  });
  const catalog = listProjectDeviceCatalog(ws, "P");
  assert.equal(catalog.length, 1);
  assert.equal(catalog[0].port, 8100, "先着(a.json)の本体が残る");
});

test("machine が違えば同名でも別エントリ(一意なのは (platform, machine, name))", () => {
  const ws = workspaceWith({
    "a.json": {
      app: "x",
      devices: [
        { platform: "android", machine: "local", name: "Pixel-01" },
        { platform: "android", machine: "M1Max", name: "Pixel-01" },
      ],
    },
  });
  const catalog = listProjectDeviceCatalog(ws, "P");
  assert.equal(catalog.length, 2);
  assert.deepEqual(catalog.map((d) => d.machine), [undefined, "M1Max"]);
});

test("platform が違えば同名でも別エントリ", () => {
  const ws = workspaceWith({
    "a.json": {
      app: "x",
      devices: [
        { platform: "ios", name: "同名" },
        { platform: "android", name: "同名" },
      ],
    },
  });
  const catalog = listProjectDeviceCatalog(ws, "P");
  assert.equal(catalog.length, 2);
});

test("machine の 'local'/''/省略は手元(undefined)へ正規化する", () => {
  const ws = workspaceWith({
    "a.json": {
      app: "x",
      devices: [
        { platform: "ios", machine: "local", name: "A" },
        { platform: "ios", machine: "", name: "B" },
        { platform: "ios", name: "C" },
      ],
    },
  });
  const catalog = listProjectDeviceCatalog(ws, "P");
  assert.deepEqual(catalog.map((d) => d.machine), [undefined, undefined, undefined]);
});

test("enabled:false のデバイスもカタログに含める(プロファイルごとの採否とは別)", () => {
  const ws = workspaceWith({
    "a.json": { app: "x", devices: [{ platform: "ios", name: "OFF", enabled: false }] },
  });
  const catalog = listProjectDeviceCatalog(ws, "P");
  assert.equal(catalog.length, 1);
  assert.equal(catalog[0].name, "OFF");
});

test("platform/name 欠落・型不正のエントリはスキップする", () => {
  const ws = workspaceWith({
    "a.json": {
      app: "x",
      devices: [
        { platform: "ios" }, // name 欠落
        { name: "no-platform" }, // platform 欠落
        { platform: "windows", name: "不正platform" },
        "文字列",
        { platform: "ios", name: "OK" },
      ],
    },
  });
  const catalog = listProjectDeviceCatalog(ws, "P");
  assert.deepEqual(catalog.map((d) => d.name), ["OK"]);
});

test("1ファイルの読み取り/解析失敗はそのファイル分だけ空として扱う(他ファイルは生きる)", () => {
  const ws = workspaceWith({ "b.json": { app: "x", devices: [{ platform: "ios", name: "OK" }] } });
  fs.writeFileSync(path.join(ws, "TestProjects", "P", "profiles", "runs", "a.json"), "{not json");
  const catalog = listProjectDeviceCatalog(ws, "P");
  assert.deepEqual(catalog.map((d) => d.name), ["OK"]);
});

test("profiles/runs/ が無い・空のプロジェクトは空配列", () => {
  const ws = fs.mkdtempSync(path.join(os.tmpdir(), "ftdc-empty-"));
  assert.deepEqual(listProjectDeviceCatalog(ws, "P"), []);
});
