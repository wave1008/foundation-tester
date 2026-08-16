// monitorDeviceStream.test.mjs
// MonitorDeviceStreamController(src/monitorDeviceStreamController.ts)の回帰テスト。node:test。
// esbuild が "../src/monitorDeviceStreamController" を .ts に解決してバンドルする。
//
// 守る不変条件(コミット eaf2316 の回帰): restartAllStreams() は disposeAll()+reapply() で
// streamingDeviceIds を空にし、suppressFrames を空集合で同期する。これが崩れると「モニター
// 再起動」時に旧 streamingIds を根拠に stale な suppressFrames が再送され、走行中 h264 が
// 新キーフレームを出さずタイルが「起動中」で餓死する。
//
// パイプライン生成には実 helper の spawn が要る(resolveSimStream が dirname(binaryPath) の
// ftester-simstream を探すため)。テストでは常駐するだけの mock を temp dir に置いて代用する
// (フレームは出さない=onChunk 不要。start() で spawn され pipelines に載れば noteStreamRendered
// が成立する)。

import assert from "node:assert/strict";
import { test } from "node:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { MonitorDeviceStreamController } from "../src/monitorDeviceStreamController";

/** dirname(binaryPath) に常駐するだけの mock helper 群を置き、binaryPath を返す。
 * names で置く helper を選べる(実機は ftester-devicepoll に振り分けられるため)。 */
function makeMockBinaryDir(names = ["ftester-simstream"]) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ftester-stream-test-"));
  for (const name of names) {
    const helper = path.join(dir, name);
    // 引数は無視し、SIGTERM されるまで生存するだけ(dispose まで pipeline を running に保つ)
    // 起動引数は argv ファイルへ落として検証できるようにする
    fs.writeFileSync(helper, `#!/bin/sh\necho "$@" > "${path.join(dir, name)}.argv"\nexec sleep 120\n`);
    fs.chmodSync(helper, 0o755);
  }
  return { dir, binaryPath: path.join(dir, "ftester") };
}

/** helper の spawn は非同期なので argv ファイルの生成を待つ(現れなければ undefined)。 */
async function waitForArgv(dir, name, timeoutMs = 3000) {
  const file = path.join(dir, `${name}.argv`);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (fs.existsSync(file)) {
      return fs.readFileSync(file, "utf8");
    }
    await new Promise((r) => setTimeout(r, 25));
  }
  return undefined;
}

/** MonitorDeviceStreamController に渡す最小 fake deps。writeMonitorControl を記録する。 */
function makeDeps(binaryPath) {
  const controls = [];
  const deps = {
    workspaceRoot: "/tmp",
    outputChannel: { appendLine() {} },
    getConfig: () => ({
      binaryPath,
      iosStreamEnabled: true,
      androidStreamEnabled: false,
      streamCodec: "h264",
      liveFps: 12,
      monitorMaxWidth: 960,
    }),
    isPollingMode: () => false,
    post: () => {},
    writeMonitorControl: (cmd) => controls.push(cmd),
    isDeviceStreaming: () => false,
    getStreamingDeviceIds: () => [],
    notifyMonitorDevices: () => {},
    isPanelActive: () => true,
    notifyMachineProfilesChanged: () => {},
    openGeneratedDocument: () => {},
  };
  return { deps, controls };
}

const iosDevice = {
  id: "sim-udid-1",
  name: "iPhone 17 Pro",
  platform: "ios",
  state: "connected",
  udid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
  detail: "",
};

test("restartAllStreams は streamingIds を空にし suppressFrames を空集合で再同期する", () => {
  const { dir, binaryPath } = makeMockBinaryDir();
  const { deps, controls } = makeDeps(binaryPath);
  const controller = new MonitorDeviceStreamController(deps);
  try {
    // connected デバイスでパイプライン生成 → 描画 ack で streamingIds に載せる
    controller.applyDevices([iosDevice]);
    controller.noteStreamRendered(iosDevice.id);
    assert.equal(controller.isStreaming(iosDevice.id), true, "前提: ack 後は streaming 中");
    assert.deepEqual(controller.streamingIds(), [iosDevice.id]);

    controls.length = 0; // ここから先の suppressFrames を観測する
    controller.restartAllStreams();

    assert.deepEqual(controller.streamingIds(), [], "restartAllStreams 後は streamingIds が空");
    const lastSuppress = controls.filter((c) => c.cmd === "suppressFrames").at(-1);
    assert.ok(lastSuppress, "suppressFrames が送られる");
    assert.deepEqual(lastSuppress.devices, [], "stale な id を再送せず空集合で同期する");
  } finally {
    controller.setVisible(false); // 全パイプライン(mock 子プロセス)を破棄
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("codec 設定変更で稼働中パイプラインが張り替えられる(同 codec は継続)", () => {
  const { dir, binaryPath } = makeMockBinaryDir();
  let codec = "h264";
  const { deps } = makeDeps(binaryPath);
  deps.getConfig = () => ({
    binaryPath, iosStreamEnabled: true, androidStreamEnabled: false,
    streamCodec: codec, liveFps: 12, monitorMaxWidth: 960,
  });
  const controller = new MonitorDeviceStreamController(deps);
  try {
    controller.applyDevices([iosDevice]);
    controller.noteStreamRendered(iosDevice.id);
    assert.equal(controller.isStreaming(iosDevice.id), true);

    // 同 codec で再適用しても張り替えない(streaming 継続)
    controller.applyDevices([iosDevice]);
    assert.equal(controller.isStreaming(iosDevice.id), true, "同 codec なら継続");

    // codec を変えて再適用 → 張り替え(ack 前なので streaming は一旦 false になる)
    codec = "mjpeg";
    controller.applyDevices([iosDevice]);
    assert.equal(controller.isStreaming(iosDevice.id), false,
      "codec 変更で張り替えられ描画 ack がリセットされる");
  } finally {
    controller.setVisible(false);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// ---- 実機(kind: physical)の振り分け ----

test("iOS 実機は simstream ではなく devicepoll に振り分けられる(--host/--port 付き)", async () => {
  // simstream は CoreSimulator 私有 API で実機に使えない。両方置いても devicepoll が選ばれること
  const { dir, binaryPath } = makeMockBinaryDir(["ftester-simstream", "ftester-devicepoll"]);
  const { deps } = makeDeps(binaryPath);
  const controller = new MonitorDeviceStreamController(deps);
  try {
    controller.applyDevices([{
      id: "phys-ios", name: "iPhone 実機", platform: "ios", state: "connected",
      detail: "", kind: "physical", host: "127.0.0.1", port: 8134,
      udid: "00008130-001819863E60001C",
    }]);
    const argv = await waitForArgv(dir, "ftester-devicepoll");
    assert.ok(argv, "devicepoll が起動すること");
    assert.match(argv, /--platform ios/);
    assert.match(argv, /--host 127\.0\.0\.1/);
    assert.match(argv, /--port 8134/);
    assert.equal(fs.existsSync(path.join(dir, "ftester-simstream.argv")), false,
      "実機に simstream を起動しないこと");
  } finally {
    controller.setVisible(false);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("Android 実機も devicepoll に振り分けられる(--serial 付き)", async () => {
  const { dir, binaryPath } = makeMockBinaryDir(["ftester-androidstream", "ftester-devicepoll"]);
  const { deps } = makeDeps(binaryPath);
  deps.getConfig = () => ({
    binaryPath, iosStreamEnabled: true, androidStreamEnabled: true,
    streamCodec: "h264", liveFps: 12, monitorMaxWidth: 960,
  });
  const controller = new MonitorDeviceStreamController(deps);
  try {
    controller.applyDevices([{
      id: "phys-and", name: "Pixel 実機", platform: "android", state: "connected",
      detail: "", kind: "physical", serial: "14141JEC204922",
    }]);
    const argv = await waitForArgv(dir, "ftester-devicepoll");
    assert.ok(argv, "devicepoll が起動すること");
    assert.match(argv, /--platform android/);
    assert.match(argv, /--serial 14141JEC204922/);
    assert.equal(fs.existsSync(path.join(dir, "ftester-androidstream.argv")), false,
      "実機に androidstream を起動しないこと(静止画面でフレームが流れない)");
  } finally {
    controller.setVisible(false);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("シミュレータは従来どおり simstream(実機振り分けの巻き添えにしない)", async () => {
  const { dir, binaryPath } = makeMockBinaryDir(["ftester-simstream", "ftester-devicepoll"]);
  const { deps } = makeDeps(binaryPath);
  const controller = new MonitorDeviceStreamController(deps);
  try {
    controller.applyDevices([{ ...iosDevice, kind: "virtual" }]);
    assert.ok(await waitForArgv(dir, "ftester-simstream"), "simstream が起動すること");
    assert.equal(fs.existsSync(path.join(dir, "ftester-devicepoll.argv")), false);
  } finally {
    controller.setVisible(false);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// --- リモートのデバイス ---------------------------------------------------------------
// 手元のヘルパーは udid/adb serial で当てるが、**それは向こうの機械の識別子**なので、
// 同名の台が手元にあると**別の機械の画面が映る**((host, name) が一意なら同名は正常な構成)。
// 代わりにその機械で `api device-stream` を起こし、向こうがヘルパーへ exec で化ける
// (契約: Sources/ftester/ApiDeviceStreamCommand.swift)。stdout の形は同じなので
// StreamPipeline も codec も失敗時のポーリング復帰もそのまま使える。

const remoteDevice = {
  id: "ios:M1Max/iPhone 17 Pro",
  name: "iPhone 17 Pro",
  platform: "ios",
  state: "connected",
  udid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", // 向こうの機械の udid。手元では当たらない
  machineHost: "M1Max",
  detail: "",
};

test("リモートのデバイスは remote exec 経由の device-stream で配信する", async () => {
  // ftester 本体を mock にする(リモート経路はこれを spawn する)
  const { dir, binaryPath } = makeMockBinaryDir(["ftester-simstream", "ftester"]);
  const { deps } = makeDeps(binaryPath);
  deps.getConfig = () => ({
    binaryPath, iosStreamEnabled: true, androidStreamEnabled: false,
    streamCodec: "h264", liveFps: 12, monitorMaxWidth: 960, project: "demo",
  });
  const controller = new MonitorDeviceStreamController(deps);
  try {
    controller.applyDevices([remoteDevice]);
    const argv = await waitForArgv(dir, "ftester");
    assert.ok(argv, "ftester(remote exec)が起動されること");
    assert.match(argv, /remote exec M1Max -- api device-stream/, "その機械の上で解決させる");
    assert.match(argv, /--device-host M1Max/, "向こうは自分が誰かを知らないので親が明示する");
    assert.match(argv, /--platform ios --name iPhone 17 Pro/, "宛先は (platform, 名前) で指す");
    assert.match(argv, /--codec h264/, "codec 設定はリモートにもそのまま効く");
    assert.match(argv, /--project demo/, "向こうもマシンプロファイルを引くのでプロジェクトが要る");

    const localArgv = await waitForArgv(dir, "ftester-simstream", 300);
    assert.equal(localArgv, undefined,
      "手元のヘルパーを起こしてはいけない(udid は向こうのもの。同名の手元の台に当たる)");
  } finally {
    controller.setVisible(false);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("プラットフォームの配信を切っていればリモートも起こさない(ポーリングに委ねる)", async () => {
  const { dir, binaryPath } = makeMockBinaryDir(["ftester"]);
  const { deps } = makeDeps(binaryPath);
  deps.getConfig = () => ({
    binaryPath, iosStreamEnabled: false, androidStreamEnabled: true,
    streamCodec: "h264", liveFps: 12, monitorMaxWidth: 960,
  });
  const controller = new MonitorDeviceStreamController(deps);
  try {
    controller.applyDevices([remoteDevice]);
    assert.equal(await waitForArgv(dir, "ftester", 300), undefined);
  } finally {
    controller.setVisible(false);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
