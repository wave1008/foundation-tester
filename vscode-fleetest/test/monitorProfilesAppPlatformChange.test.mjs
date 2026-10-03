// monitorProfilesAppPlatformChange.test.mjs
// アプリプロファイルのファイル変化(watcher onDidChange)でホストが何を送り、いつモニターを再起動するかを
// 縛る(monitorProfilesRunScopeRestart.test.mjs と同じ fake-deps パターン)。
// - profileInfo を送らない: 送るとアプリプロファイルの編集欄が自動保存のたびに読み込み中へ差し替わり、
//   入力中のフォーカスが外れる。対象 OS の最新値は appProfileFileChanged.appPlatforms に載せる
// - 対象 OS が変わり、それが監視中の実行プロファイルのアプリならモニターを再起動する
//   (`api monitor --profile` は起動時に1回だけ、アプリの platform で devices を絞って読む)

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { MonitorProfilesController } from "../src/monitorProfilesController";

function makeController({ selectedProfile = "ios", runApp = "sampleapp" } = {}) {
  const workspaceRoot = fs.mkdtempSync(path.join(os.tmpdir(), "fleetest-app-platform-test-"));
  const profilesDir = path.join(workspaceRoot, "TestProjects", "P", "profiles");
  fs.mkdirSync(path.join(profilesDir, "runs"), { recursive: true });
  fs.mkdirSync(path.join(profilesDir, "apps"), { recursive: true });
  fs.writeFileSync(path.join(profilesDir, "runs", "ios.json"), JSON.stringify({ app: runApp, devices: [] }), "utf8");
  const appPath = (name) => path.join(profilesDir, "apps", `${name}.json`);
  const writeApp = (name, object) => fs.writeFileSync(appPath(name), JSON.stringify(object), "utf8");
  writeApp("sampleapp", { ios: { app: "com.example" } });
  writeApp("other", { platform: "android" });
  const posts = [];
  let restarts = 0;
  // コンストラクタ(FileSystemWatcher)は通さない。class field の初期化もされないので自前で置く
  const controller = Object.create(MonitorProfilesController.prototype);
  controller.runScopeKeys = new Map();
  controller.runFormWrites = new Map();
  controller.runEditedOutside = new Set();
  controller.appPlatformSeen = new Map();
  controller.restartMonitorDebounced = () => { restarts += 1; };
  controller.deps = {
    workspaceRoot,
    getConfig: () => ({ binaryPath: "fleetest", project: "P", profile: selectedProfile }),
    outputChannel: { appendLine() {} },
    post: (message) => posts.push(message),
  };
  return { controller, posts, appPath, writeApp, restarts: () => restarts };
}

test("アプリプロファイルの変化は profileInfo を送らず、appProfileFileChanged に最新の appPlatforms を載せる", () => {
  const { controller, posts, appPath, writeApp } = makeController();
  controller.postProfileInfo();
  posts.length = 0;

  writeApp("sampleapp", { platform: "ios", ios: { app: "com.example" } });
  controller.handleAppProfileFileChanged(appPath("sampleapp"));

  assert.deepEqual(posts.map((m) => m.type), ["appProfileFileChanged"]);
  assert.equal(posts[0].name, "sampleapp");
  assert.deepEqual(JSON.parse(JSON.stringify(posts[0].appPlatforms)), { other: "android", sampleapp: "ios" });
});

test("profileInfo の appPlatforms は欠落・読めないファイルを hybrid にする", () => {
  const { controller, posts, appPath } = makeController();
  fs.writeFileSync(appPath("broken"), "{not json", "utf8");
  controller.postProfileInfo();
  const info = posts.find((m) => m.type === "profileInfo");
  assert.deepEqual(JSON.parse(JSON.stringify(info.appPlatforms)), { broken: "hybrid", other: "android", sampleapp: "hybrid" });
});

test("監視中の実行プロファイルのアプリの対象 OS が変わったらモニターを再起動する", () => {
  const { controller, appPath, writeApp, restarts } = makeController();
  controller.postProfileInfo();

  writeApp("sampleapp", { ios: { app: "com.example", appName: "renamed" } });
  controller.handleAppProfileFileChanged(appPath("sampleapp"));
  assert.equal(restarts(), 0, "対象 OS が変わらない保存(表示名の編集等)では再起動しない");

  writeApp("sampleapp", { platform: "ios", ios: { app: "com.example" } });
  controller.handleAppProfileFileChanged(appPath("sampleapp"));
  assert.equal(restarts(), 1);
});

test("監視中の実行プロファイルが参照しないアプリの変化では再起動しない", () => {
  const { controller, appPath, writeApp, restarts } = makeController();
  controller.postProfileInfo();
  writeApp("other", { platform: "ios" });
  controller.handleAppProfileFileChanged(appPath("other"));
  assert.equal(restarts(), 0);
});
