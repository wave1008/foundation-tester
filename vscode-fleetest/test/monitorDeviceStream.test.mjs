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
// fleetest-simstream を探すため)。テストでは常駐するだけの mock を temp dir に置いて代用する
// (フレームは出さない=onChunk 不要。start() で spawn され pipelines に載れば noteStreamRendered
// が成立する)。

import assert from "node:assert/strict";
import { test } from "node:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { MonitorDeviceStreamController } from "../src/monitorDeviceStreamController";

/** dirname(binaryPath) に常駐するだけの mock helper 群を置き、binaryPath を返す。
 * names で置く helper を選べる(実機は fleetest-devicepoll に振り分けられるため)。 */
function makeMockBinaryDir(names = ["fleetest-simstream"]) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fleetest-stream-test-"));
  for (const name of names) {
    const helper = path.join(dir, name);
    // 引数は無視し、SIGTERM されるまで生存するだけ(dispose まで pipeline を running に保つ)
    // 起動引数は argv ファイルへ落として検証できるようにする
    fs.writeFileSync(helper, `#!/bin/sh\necho "$@" > "${path.join(dir, name)}.argv"\nexec sleep 120\n`);
    fs.chmodSync(helper, 0o755);
  }
  return { dir, binaryPath: path.join(dir, "fleetest") };
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
      monitorInterval: 0.05, // まとめ窓(秒)。テストでは短く
    }),
    isPollingMode: () => false,
    post: () => {},
    writeMonitorControl: (cmd) => controls.push(cmd),
    isDeviceStreaming: () => false,
    getStreamingDeviceIds: () => [],
    notifyMonitorDevices: () => {},
    notifyMachineLocks: () => {},
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

/** suppressFrames は monitorInterval(fake では 0.05s)だけ溜めて送る(syncSuppressFrames 参照) */
const waitSuppressWindow = () => new Promise((resolve) => setTimeout(resolve, 120));

test("窓の中に届いた描画 ack はまとめて1回の suppressFrames になる", async () => {
  const { dir, binaryPath } = makeMockBinaryDir();
  const { deps, controls } = makeDeps(binaryPath);
  const controller = new MonitorDeviceStreamController(deps);
  try {
    const second = { ...iosDevice, id: "ios:second", name: "second" };
    controller.applyDevices([iosDevice, second]);
    controller.noteStreamRendered(iosDevice.id);
    await new Promise((resolve) => setTimeout(resolve, 10)); // 別メッセージとして届く形
    controller.noteStreamRendered(second.id);
    assert.equal(controls.filter((c) => c.cmd === "suppressFrames").length, 0, "窓の中では送らない");
    await waitSuppressWindow();
    const sent = controls.filter((c) => c.cmd === "suppressFrames");
    assert.equal(sent.length, 1, "2本の ack で1回");
    assert.deepEqual([...sent[0].devices].sort(), [iosDevice.id, second.id].sort());
  } finally {
    controller.setVisible(false);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("restartAllStreams は streamingIds を空にし suppressFrames を空集合で再同期する", async () => {
  const { dir, binaryPath } = makeMockBinaryDir();
  const { deps, controls } = makeDeps(binaryPath);
  const controller = new MonitorDeviceStreamController(deps);
  try {
    // connected デバイスでパイプライン生成 → 描画 ack で streamingIds に載せる
    controller.applyDevices([iosDevice]);
    controller.noteStreamRendered(iosDevice.id);
    assert.equal(controller.isStreaming(iosDevice.id), true, "前提: ack 後は streaming 中");
    assert.deepEqual(controller.streamingIds(), [iosDevice.id]);

    await waitSuppressWindow();
    controls.length = 0; // ここから先の suppressFrames を観測する
    controller.restartAllStreams();
    // 溜めずに即時 = 同期で観測できる(空集合の再同期が遅れると餓死の回帰)

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
  const { dir, binaryPath } = makeMockBinaryDir(["fleetest-simstream", "fleetest-devicepoll"]);
  const { deps } = makeDeps(binaryPath);
  const controller = new MonitorDeviceStreamController(deps);
  try {
    controller.applyDevices([{
      id: "phys-ios", name: "iPhone 実機", platform: "ios", state: "connected",
      detail: "", kind: "physical", host: "127.0.0.1", port: 8134,
      udid: "00008130-001819863E60001C",
    }]);
    const argv = await waitForArgv(dir, "fleetest-devicepoll");
    assert.ok(argv, "devicepoll が起動すること");
    assert.match(argv, /--platform ios/);
    assert.match(argv, /--host 127\.0\.0\.1/);
    assert.match(argv, /--port 8134/);
    assert.equal(fs.existsSync(path.join(dir, "fleetest-simstream.argv")), false,
      "実機に simstream を起動しないこと");
  } finally {
    controller.setVisible(false);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("Android 実機も devicepoll に振り分けられる(--serial 付き)", async () => {
  const { dir, binaryPath } = makeMockBinaryDir(["fleetest-androidstream", "fleetest-devicepoll"]);
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
    const argv = await waitForArgv(dir, "fleetest-devicepoll");
    assert.ok(argv, "devicepoll が起動すること");
    assert.match(argv, /--platform android/);
    assert.match(argv, /--serial 14141JEC204922/);
    assert.equal(fs.existsSync(path.join(dir, "fleetest-androidstream.argv")), false,
      "実機に androidstream を起動しないこと(静止画面でフレームが流れない)");
  } finally {
    controller.setVisible(false);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// Android 実機のブリッジが未起動(bridgeRunning===false)と確定している台は devicepoll を
// 起こさない(絵を捨てるだけのプロセスを走らせない。タイル側は deviceTiles.js の
// bridgeNotRunning がフレームを畳む)。上のテストは bridgeRunning 省略(=不明)で devicepoll が
// 起動することを確認済みなので、ここでは false のときだけを見る(往復の反対側)。
test("Android 実機はブリッジ未起動(bridgeRunning===false)と確定していれば devicepoll を起こさない", async () => {
  const { dir, binaryPath } = makeMockBinaryDir(["fleetest-androidstream", "fleetest-devicepoll"]);
  const { deps } = makeDeps(binaryPath);
  deps.getConfig = () => ({
    binaryPath, iosStreamEnabled: true, androidStreamEnabled: true,
    streamCodec: "h264", liveFps: 12, monitorMaxWidth: 960,
  });
  const controller = new MonitorDeviceStreamController(deps);
  try {
    controller.applyDevices([{
      id: "phys-and", name: "Pixel 実機", platform: "android", state: "connected",
      detail: "", kind: "physical", serial: "14141JEC204922", bridgeRunning: false,
    }]);
    assert.equal(fs.existsSync(path.join(dir, "fleetest-devicepoll.argv")), false,
      "ブリッジ未起動が確定している台に devicepoll を起こさないこと");
  } finally {
    controller.setVisible(false);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("シミュレータは従来どおり simstream(実機振り分けの巻き添えにしない)", async () => {
  const { dir, binaryPath } = makeMockBinaryDir(["fleetest-simstream", "fleetest-devicepoll"]);
  const { deps } = makeDeps(binaryPath);
  const controller = new MonitorDeviceStreamController(deps);
  try {
    controller.applyDevices([{ ...iosDevice, kind: "virtual" }]);
    assert.ok(await waitForArgv(dir, "fleetest-simstream"), "simstream が起動すること");
    assert.equal(fs.existsSync(path.join(dir, "fleetest-devicepoll.argv")), false);
  } finally {
    controller.setVisible(false);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// --- リモートのデバイス ---------------------------------------------------------------
// 手元のヘルパーは udid/adb serial で当てるが、**それは向こうの機械の識別子**なので、
// 同名の台が手元にあると**別の機械の画面が映る**((host, name) が一意なら同名は正常な構成)。
// 代わりにその機械で `api device-stream` を起こし、向こうがヘルパーへ exec で化ける
// (契約: Sources/fleetest/ApiDeviceStreamCommand.swift)。stdout の形は同じなので
// StreamPipeline も codec も失敗時のポーリング復帰もそのまま使える。

const remoteDevice = {
  id: "ios:M1Max/iPhone 17 Pro",
  name: "iPhone 17 Pro",
  platform: "ios",
  state: "connected",
  udid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", // 向こうの機械の udid。手元では当たらない
  machine: "M1Max",
  detail: "",
};

// 共有ランナーの配信の退避(docs/remote-runner.md §18.2 M2)。**保持者が自分か他人かは問わない** ——
// 配信を張ったままの run は実際に赤くなる(docs/verification.md の実測)。
test("占有中の機械の配信は起こさず、張っていれば畳む", async () => {
  const { dir, binaryPath } = makeMockBinaryDir(["fleetest-simstream", "fleetest"]);
  const { deps } = makeDeps(binaryPath);
  deps.getConfig = () => ({
    binaryPath, iosStreamEnabled: true, androidStreamEnabled: false,
    streamCodec: "h264", liveFps: 12, monitorMaxWidth: 960, project: "demo",
  });
  const controller = new MonitorDeviceStreamController(deps);
  try {
    controller.applyDevices([remoteDevice]);
    assert.ok(await waitForArgv(dir, "fleetest"), "前提: 空いていれば配信が張られる");
    fs.rmSync(path.join(dir, "fleetest.argv"));

    // run が始まった = その機械が占有された。**次の monitorDevices を待たずに畳む**
    controller.setOccupiedMachines(new Set(["M1Max"]));
    assert.equal(controller.isStreaming(remoteDevice.id), false, "配信は畳まれる");
    controller.applyDevices([remoteDevice]);
    assert.equal(await waitForArgv(dir, "fleetest", 300), undefined,
      "占有中は起こし直さない(タイルはポーリングのフレームで更新され続ける)");

    // run が終われば戻る
    controller.setOccupiedMachines(new Set());
    assert.ok(await waitForArgv(dir, "fleetest"), "解放されたら張り直す");
  } finally {
    controller.setVisible(false);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// 同じ台を2人が眺めると端末側の捕捉コストが人数ぶん重なる(FTCore.StreamLease)。
// **起こしてから断られる形にしない** = 監視が配る事実を見て起こさないだけ(ssh を張らない)
test("他の発行者が配信中の台は起こさない", async () => {
  const { dir, binaryPath } = makeMockBinaryDir(["fleetest-simstream", "fleetest"]);
  const { deps } = makeDeps(binaryPath);
  deps.getConfig = () => ({
    binaryPath, iosStreamEnabled: true, androidStreamEnabled: false,
    streamCodec: "h264", liveFps: 12, monitorMaxWidth: 960, project: "demo",
  });
  const controller = new MonitorDeviceStreamController(deps);
  try {
    controller.applyDevices([{ ...remoteDevice, streamedByOther: true }]);
    assert.equal(await waitForArgv(dir, "fleetest", 300), undefined, "二重に張らない");
    controller.applyDevices([{ ...remoteDevice, streamedByOther: false }]);
    assert.ok(await waitForArgv(dir, "fleetest"), "相手がやめたら張る");
  } finally {
    controller.setVisible(false);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// 手元でも同じ: 同じ Mac の別ウィンドウ(別の拡張ホスト)が同じ台のヘルパーを持っていれば、監視が
// FTCore.LocalStreamHolder(`ps -E` のプロセスの実体)で streamedByOther を配り、こちらは起こさない
test("同じ Mac の別ウィンドウが配信中の手元の台は起こさない", async () => {
  const { dir, binaryPath } = makeMockBinaryDir(["fleetest-simstream"]);
  const { deps } = makeDeps(binaryPath);
  const controller = new MonitorDeviceStreamController(deps);
  try {
    controller.applyDevices([{ ...iosDevice, streamedByOther: true }]);
    assert.equal(await waitForArgv(dir, "fleetest-simstream", 300), undefined, "二重に張らない");
    controller.applyDevices([{ ...iosDevice, streamedByOther: false }]);
    assert.ok(await waitForArgv(dir, "fleetest-simstream"), "相手のウィンドウが畳んだら張る");
  } finally {
    controller.setVisible(false);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("リモートのデバイスは remote exec 経由の device-stream で配信する", async () => {
  // fleetest 本体を mock にする(リモート経路はこれを spawn する)
  const { dir, binaryPath } = makeMockBinaryDir(["fleetest-simstream", "fleetest"]);
  const { deps } = makeDeps(binaryPath);
  deps.getConfig = () => ({
    binaryPath, iosStreamEnabled: true, androidStreamEnabled: false,
    streamCodec: "h264", liveFps: 12, monitorMaxWidth: 960, project: "demo",
  });
  const controller = new MonitorDeviceStreamController(deps);
  try {
    controller.applyDevices([remoteDevice]);
    const argv = await waitForArgv(dir, "fleetest");
    assert.ok(argv, "fleetest(remote exec)が起動されること");
    assert.match(argv, /remote exec M1Max -- api device-stream/, "その機械の上で解決させる");
    // **エイリアスではなく "local"** —— 転送したプロファイルは畳んであり(RunnerProfileView)、
    // 向こうでは自分の台が machine:"local"。M1Max で絞ると1台も残らず配信が張れない
    // (fan-out の子が `--device-machine local` を渡すのと同じ理由)
    assert.match(argv, /--device-machine local/, "畳んだプロファイルは local で引く");
    assert.doesNotMatch(argv, /--device-machine M1Max/, "エイリアスで絞ると向こうで1台も残らない");
    assert.match(argv, /--platform ios --name iPhone 17 Pro/, "宛先は (platform, 名前) で指す");
    assert.match(argv, /--codec h264/, "codec 設定はリモートにもそのまま効く");
    assert.match(argv, /--project demo/, "向こうもマシンプロファイルを引くのでプロジェクトが要る");

    const localArgv = await waitForArgv(dir, "fleetest-simstream", 300);
    assert.equal(localArgv, undefined,
      "手元のヘルパーを起こしてはいけない(udid は向こうのもの。同名の手元の台に当たる)");
  } finally {
    controller.setVisible(false);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("プラットフォームの配信を切っていればリモートも起こさない(ポーリングに委ねる)", async () => {
  const { dir, binaryPath } = makeMockBinaryDir(["fleetest"]);
  const { deps } = makeDeps(binaryPath);
  deps.getConfig = () => ({
    binaryPath, iosStreamEnabled: false, androidStreamEnabled: true,
    streamCodec: "h264", liveFps: 12, monitorMaxWidth: 960,
  });
  const controller = new MonitorDeviceStreamController(deps);
  try {
    controller.applyDevices([remoteDevice]);
    assert.equal(await waitForArgv(dir, "fleetest", 300), undefined);
  } finally {
    controller.setVisible(false);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("未登録のリモートデバイスは張らない(向こうの device-stream が名前を解決できない)", async () => {
  // 典型: WiFi ペアリングだけで別の機械から見えている実機。向こうの monitor は
  // 「未登録だが connected」で報告するが、device-stream は登録簿の名前でしか宛先を
  // 解決できず(ApiDeviceStreamCommand.swift)、必ず exit 64 → 約30秒周期の再試行ループになる
  const { dir, binaryPath } = makeMockBinaryDir(["fleetest"]);
  const { deps } = makeDeps(binaryPath);
  deps.getConfig = () => ({
    binaryPath, iosStreamEnabled: true, androidStreamEnabled: false,
    streamCodec: "h264", liveFps: 12, monitorMaxWidth: 960, project: "demo",
  });
  const controller = new MonitorDeviceStreamController(deps);
  try {
    controller.applyDevices([{ ...remoteDevice, kind: "physical", registered: false }]);
    assert.equal(await waitForArgv(dir, "fleetest", 300), undefined,
      "登録簿に無い名前で device-stream を張りに行ってはいけない");
  } finally {
    controller.setVisible(false);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("リモートの実機は設定に関わらず MJPEG で張る — h264 を要求すると desync する", async () => {
  // 向こう(ApiDeviceStreamCommand)は実機を devicepoll = MJPEG(v1)固定に落とす。
  // こちらが h264(v2)のつもりで読むと、v1 レコードを v2 のレイアウトで解釈して
  // 未知 KIND → kill → 再起動のループになる。
  // **観測点は argv ではなくパイプラインの codec**: argv には元々 --codec を載せないので、
  // argv だけ見るテストは「codec を h264 のままにする」変異を1つも殺せない。
  // codec 設定を切り替えても張り替えが起きない = 実機は最初から mjpeg で固定されている。
  const { dir, binaryPath } = makeMockBinaryDir(["fleetest"]);
  const { deps } = makeDeps(binaryPath);
  let streamCodec = "h264";
  deps.getConfig = () => ({
    binaryPath, iosStreamEnabled: true, androidStreamEnabled: false,
    streamCodec, liveFps: 12, monitorMaxWidth: 960, project: "demo",
  });
  const controller = new MonitorDeviceStreamController(deps);
  const physicalRemote = { ...remoteDevice, kind: "physical", port: 8123 };
  try {
    controller.applyDevices([physicalRemote]);
    controller.noteStreamRendered(physicalRemote.id);
    assert.equal(controller.isStreaming(physicalRemote.id), true, "前提: 張れている");

    streamCodec = "mjpeg";
    controller.applyDevices([physicalRemote]);
    assert.equal(controller.isStreaming(physicalRemote.id), true,
      "実機が設定どおり h264 で張られていると、ここで mjpeg へ張り替わってしまう");
  } finally {
    controller.setVisible(false);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// --- run 中の台の配信退避(手元・リモート共通の inRun 信号) -----------------------------
// occupiedMachines(機械単位。共有ランナーの dispatch.lock)と inRun(台単位。RunLease)は
// 粒度が違う信号で、どちらか一方が立てば畳む。手元の台は machine が無く occupiedMachines では
// 判定できないため、この信号が無いと「手元だけ run 中も配信が張りっぱなし」になる
// (実測: 手元 8 台の stale-screenshot 注記がリモートの 5〜14 倍)。

test("inRun:true の手元の台は配信を起こさない", async () => {
  const { dir, binaryPath } = makeMockBinaryDir();
  const { deps } = makeDeps(binaryPath);
  const controller = new MonitorDeviceStreamController(deps);
  try {
    controller.applyDevices([{ ...iosDevice, inRun: true }]);
    assert.equal(await waitForArgv(dir, "fleetest-simstream", 300), undefined,
      "run 中の台にヘルパーを起こしてはいけない");
  } finally {
    controller.setVisible(false);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("配信中の台が inRun:true になったら既存の配信を畳む", async () => {
  const { dir, binaryPath } = makeMockBinaryDir();
  const { deps } = makeDeps(binaryPath);
  const controller = new MonitorDeviceStreamController(deps);
  try {
    controller.applyDevices([iosDevice]);
    // **ヘルパーが実際に起きるまで待つ**(spawn は非同期。待たずに下で argv を消すと
    // まだ書かれていないファイルを消して落ちる)
    assert.ok(await waitForArgv(dir, "fleetest-simstream"), "前提: run 開始前は配信が起きる");
    controller.noteStreamRendered(iosDevice.id);
    assert.equal(controller.isStreaming(iosDevice.id), true, "前提: run 開始前は配信中");

    controller.applyDevices([{ ...iosDevice, inRun: true }]);
    assert.equal(controller.isStreaming(iosDevice.id), false, "run 開始で配信が畳まれる");

    // RunLease は pid 生存 + mtime 15 秒で自ら失効するので、run が終わって inRun が
    // 外れれば次の applyDevices で自動的に配信へ戻る(解除に専用の手当ては要らない)
    fs.rmSync(path.join(dir, "fleetest-simstream.argv"));
    controller.applyDevices([iosDevice]);
    assert.ok(await waitForArgv(dir, "fleetest-simstream"), "run 終了で配信が自動的に戻る");
  } finally {
    controller.setVisible(false);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// 陰性対照: inRun が false・欠落の台は従来どおり配信する(この変更が「常に畳む」側へ
// 倒れていないことの確認)
test("inRun:false・欠落の台は従来どおり配信する(陰性対照)", async () => {
  const { dir, binaryPath } = makeMockBinaryDir();
  const { deps } = makeDeps(binaryPath);
  const controller = new MonitorDeviceStreamController(deps);
  try {
    controller.applyDevices([{ ...iosDevice, inRun: false }]);
    assert.ok(await waitForArgv(dir, "fleetest-simstream"), "inRun:false は配信する");
    fs.rmSync(path.join(dir, "fleetest-simstream.argv"));

    controller.setVisible(false);
    controller.setVisible(true);
    controller.applyDevices([{ id: "ios:no-inrun-field", name: "no-field", platform: "ios",
      state: "connected", udid: iosDevice.udid, detail: "" }]);
    assert.ok(await waitForArgv(dir, "fleetest-simstream"), "inRun 欠落は配信する");
  } finally {
    controller.setVisible(false);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// machine 単位の occupiedMachines と台単位の inRun は独立に効く(片方だけでも畳む)
test("機械の占有(occupiedMachines)と台の inRun は独立に配信を畳む", async () => {
  const { dir, binaryPath } = makeMockBinaryDir(["fleetest-simstream", "fleetest"]);
  const { deps } = makeDeps(binaryPath);
  deps.getConfig = () => ({
    binaryPath, iosStreamEnabled: true, androidStreamEnabled: false,
    streamCodec: "h264", liveFps: 12, monitorMaxWidth: 960, project: "demo",
  });
  const controller = new MonitorDeviceStreamController(deps);
  try {
    // occupiedMachines だけが立っている(inRun は無し) — 従来どおり畳む
    controller.applyDevices([remoteDevice]);
    assert.ok(await waitForArgv(dir, "fleetest"), "前提: 空いていれば配信する");
    fs.rmSync(path.join(dir, "fleetest.argv"));
    controller.setOccupiedMachines(new Set(["M1Max"]));
    controller.applyDevices([remoteDevice]);
    assert.equal(await waitForArgv(dir, "fleetest", 300), undefined,
      "機械の占有だけでも畳む(この台の inRun は立っていない)");
    controller.setOccupiedMachines(new Set());

    // inRun だけが立っている(machine の占有は無し) — こちらも畳む
    controller.applyDevices([remoteDevice]);
    assert.ok(await waitForArgv(dir, "fleetest"), "前提: 解放されていれば配信する");
    fs.rmSync(path.join(dir, "fleetest.argv"));
    controller.applyDevices([{ ...remoteDevice, inRun: true }]);
    assert.equal(await waitForArgv(dir, "fleetest", 300), undefined,
      "台の inRun だけでも畳む(機械は占有されていない)");
  } finally {
    controller.setVisible(false);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("手元に配信ヘルパーが1つも無くてもリモートは配信できる", async () => {
  // fleetest だけ置く(simstream/androidstream/devicepoll は無い)
  const { dir, binaryPath } = makeMockBinaryDir(["fleetest"]);
  const { deps } = makeDeps(binaryPath);
  deps.getConfig = () => ({
    binaryPath, iosStreamEnabled: true, androidStreamEnabled: false,
    streamCodec: "h264", liveFps: 12, monitorMaxWidth: 960, project: "demo",
  });
  const controller = new MonitorDeviceStreamController(deps);
  try {
    controller.applyDevices([remoteDevice]);
    assert.ok(await waitForArgv(dir, "fleetest"),
      "リモートは向こうの fleetest が起こすので、手元のビルドの有無に依存しない");
  } finally {
    controller.setVisible(false);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
