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

/** dirname(binaryPath) に常駐するだけの mock ftester-simstream を置き、binaryPath を返す。 */
function makeMockBinaryDir() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ftester-stream-test-"));
  const helper = path.join(dir, "ftester-simstream");
  // 引数は無視し、SIGTERM されるまで生存するだけ(dispose まで pipeline を running に保つ)
  fs.writeFileSync(helper, "#!/bin/sh\nexec sleep 120\n");
  fs.chmodSync(helper, 0o755);
  return { dir, binaryPath: path.join(dir, "ftester") };
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
