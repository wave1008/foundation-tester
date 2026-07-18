// residentProcesses.test.mjs
// residentProcesses.ts(classifyResident / parseResidentProcesses)のユニットテスト。
// esbuild が "../src/residentProcesses"(拡張子なし)を .ts に解決してバンドルする。
// ps 行は実機(M2 Ultra)の `ps -axo pid=,ppid=,command=` から採取した実例に基づく。

import assert from "node:assert/strict";
import { test } from "node:test";
import { classifyResident, parseAndroidBridges, parseResidentProcesses } from "../src/residentProcesses";

test("classifyResident: 各種別を正しく判定する", () => {
  const cases = [
    [
      "/Applications/Xcode_27_beta_3.app/Contents/Developer/usr/bin/xcodebuild test-without-building -xctestrun /Users/w/foundation-tester/.ftester/DerivedData/Build/Products/FTesterRunner_iphonesimulator27.0.xctestrun -destination id=2C4FBE2E-5358-48CD-B32A-964B8EB817B4",
      "bridge",
    ],
    [
      "/Users/w/Library/Developer/CoreSimulator/Devices/E38DCA93-95F2-4DDF-B1FE-29527205D3EE/data/Containers/Bundle/Application/99534FFE/FTesterRunnerUITests-Runner.app/FTesterRunnerUITests-Runner",
      "sim-runner",
    ],
    [
      "/Users/w/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless -avd Pixel_9_Android_15_-07",
      "emulator",
    ],
    [".build/debug/ftester api monitor --project SampleApp --interval 1 --max-width 800", "monitor"],
    [".build/debug/ftester api host-metrics --interval 1", "host-metrics"],
    [".build/debug/ftester api live serve --platform ios --device iPhone17Pro --port 8127", "live-serve"],
    [".build/debug/ftester-androidstream --serial emulator-5554", "stream"],
    [".build/debug/ftester-simstream --udid E38DCA93-95F2-4DDF-B1FE-29527205D3EE", "stream"],
    [".build/debug/ftester api run --project SampleApp --scenario Foo", "run"],
    [".build/debug/ftester-mcp", "mcp"],
    [".build/debug/ftester bridge status --port 8123", "ftester"],
  ];
  for (const [cmd, type] of cases) {
    const r = classifyResident(cmd);
    assert.ok(r, `分類されるべき: ${cmd}`);
    assert.equal(r.type, type, `種別 ${type} を期待: ${cmd}`);
  }
});

test("classifyResident: ftester 無関係のプロセスは null", () => {
  const excluded = [
    "/usr/libexec/CoreSimulatorBridge",
    "/System/Applications/Utilities/Activity Monitor.app/Contents/MacOS/Activity Monitor",
    // -avd を持たない qemu(ftester フリート外の可能性)は対象にしない
    "/opt/homebrew/bin/qemu-system-x86_64 -m 2048 -hda disk.img",
    // FTesterRunner を含まない別プロジェクトの xcodebuild
    "/usr/bin/xcodebuild test-without-building -xctestrun /tmp/OtherApp.xctestrun",
    // 引数に monitor の語が偶然出るだけの無関係コマンド
    "/usr/bin/node scripts/monitor.js",
  ];
  for (const cmd of excluded) {
    assert.equal(classifyResident(cmd), null, `null であるべき: ${cmd}`);
  }
});

test("classifyResident: detail(識別子)を抽出する", () => {
  assert.equal(classifyResident("x/qemu-system-aarch64 -avd Pixel_9_Android_15_-07")?.detail, "Pixel_9_Android_15_-07");
  assert.equal(classifyResident(".build/debug/ftester-androidstream --serial emulator-5554")?.detail, "emulator-5554");
  assert.equal(
    classifyResident("a/CoreSimulator/Devices/E38DCA93-95F2-4DDF-B1FE-29527205D3EE/x/FTesterRunnerUITests-Runner")?.detail,
    "E38DCA93-95F2-4DDF-B1FE-29527205D3EE",
  );
});

test("parseResidentProcesses: ps 出力(pid ppid state command)を分類・整列して抽出する", () => {
  const psOutput = [
    "  222     1 S   .build/debug/ftester-mcp",
    "  111  4321 S+  .build/debug/ftester api monitor --project SampleApp --interval 1",
    "  333     1 S   /usr/libexec/CoreSimulatorBridge", // 除外
    "  444  4321 R   /Users/w/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless -avd Pixel_9_Android_15_-01",
    "", // 空行スキップ
    "not-a-process-line", // pid で始まらない行はスキップ
  ].join("\n");
  const got = parseResidentProcesses(psOutput);
  // 期待: emulator → monitor → mcp の順(KIND_ORDER)。CoreSimulatorBridge は除外。
  assert.deepEqual(
    got.map((p) => [p.pid, p.type, p.detail]),
    [
      [444, "emulator", "Pixel_9_Android_15_-01"],
      [111, "monitor", "SampleApp"],
      [222, "mcp", ""],
    ],
  );
  assert.equal(got[0].label, "Androidエミュ");
  assert.equal(got[0].ppid, 4321);
  assert.equal(got.every((p) => p.zombie === false), true);
});

test("classifyResident: 新規 ftester-<name> helper を汎用に ftester 種別で拾う", () => {
  const r = classifyResident(".build/debug/ftester-newhelper --serve");
  assert.ok(r);
  assert.equal(r.type, "ftester");
  assert.equal(r.detail, "ftester-newhelper"); // helper 名を識別子に出す
  // 専用 helper は従来どおり個別種別が勝つ
  assert.equal(classifyResident(".build/debug/ftester-mcp").type, "mcp");
  assert.equal(classifyResident(".build/debug/ftester-androidstream --serial x").type, "stream");
});

test("classifyResident: binaryDir 配下の実行ファイルは名前を問わず拾う(もれ防止)", () => {
  const binaryDir = "/Users/w/foundation-tester/.build/debug";
  const cmd = `${binaryDir}/ftbridge-daemon --port 9000`;
  assert.equal(classifyResident(cmd), null); // binaryDir 無しなら未分類
  const r = classifyResident(cmd, { binaryDir });
  assert.ok(r);
  assert.equal(r.type, "ftester");
  assert.equal(r.detail, "ftbridge-daemon");
  // ディレクトリ外の同名は拾わない
  assert.equal(classifyResident("/opt/other/ftbridge-daemon --port 9000", { binaryDir }), null);
});

test("classifyResident: in-app ブリッジ(注入アプリ)を .inapp の UDID で拾う", () => {
  const udid = "26FB5C4F-28B3-42D0-BB3A-A7B4D63917FF";
  const cmd = `/Users/w/Library/Developer/CoreSimulator/Devices/${udid}/data/Containers/Bundle/Application/GUID/SampleApp.app/SampleApp`;
  assert.equal(classifyResident(cmd), null); // inappBridges 無しなら未分類
  const r = classifyResident(cmd, { inappBridges: new Map([[udid, "8140"]]) });
  assert.ok(r);
  assert.equal(r.type, "inapp-bridge");
  assert.equal(r.detail, "SampleApp"); // detail はアプリ名
  // 同じ UDID でも XCUITest ランナーは sim-runner が勝つ
  const runnerCmd = `/x/CoreSimulator/Devices/${udid}/data/Containers/Bundle/Application/G/FTesterRunnerUITests-Runner.app/FTesterRunnerUITests-Runner`;
  assert.equal(classifyResident(runnerCmd, { inappBridges: new Map([[udid, "8140"]]) }).type, "sim-runner");
  // UDID がマップに無ければ拾わない(別シミュの通常アプリを誤検出しない)
  assert.equal(classifyResident(cmd, { inappBridges: new Map([["OTHER-UDID", "8140"]]) }), null);
});

test("parseResidentProcesses: ポートを bridge=xctestrun名 / sim-runner=同一UDIDのbridge / inapp=.inapp から解決する", () => {
  const udid = "26FB5C4F-28B3-42D0-BB3A-A7B4D63917FF";
  const inappUdid = "E38DCA93-95F2-4DDF-B1FE-29527205D3EE";
  const psOutput = [
    // 実機採取形式: -xctestrun .../FTesterRunner-<port>.xctestrun -destination platform=iOS Simulator,id=<UDID>
    `  36328     1 S /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test-without-building -xctestrun /Users/w/foundation-tester/.ftester/DerivedData/Build/Products/FTesterRunner-8128.xctestrun -destination platform=iOS Simulator,id=${udid}`,
    `  36795 35891 S /Users/w/Library/Developer/CoreSimulator/Devices/${udid}/data/Containers/Bundle/Application/AA/FTesterRunnerUITests-Runner.app/FTesterRunnerUITests-Runner`,
    `  40000 39000 S /Users/w/Library/Developer/CoreSimulator/Devices/${inappUdid}/data/Containers/Bundle/Application/BB/SampleApp.app/SampleApp`,
    "  50000     1 S .build/debug/ftester-mcp",
  ].join("\n");
  const got = parseResidentProcesses(psOutput, {
    inappBridges: new Map([[inappUdid, "8155"]]),
  });
  const byPid = Object.fromEntries(got.map((p) => [p.pid, p]));
  assert.equal(byPid[36328].type, "bridge");
  assert.equal(byPid[36328].port, "8128"); // xctestrun 名から
  assert.equal(byPid[36795].type, "sim-runner");
  assert.equal(byPid[36795].port, "8128"); // 同一 UDID の bridge から
  assert.equal(byPid[40000].type, "inapp-bridge");
  assert.equal(byPid[40000].port, "8155"); // .inapp(inappBridges)から
  assert.equal(byPid[50000].port, ""); // ポート概念の無い種別は空
});

test("parseResidentProcesses: 親PID を launchd_sim 経由でシミュレータ名に解決する", () => {
  const udid = "26FB5C4F-28B3-42D0-BB3A-A7B4D63917FF";
  const psOutput = [
    `  35891     1 S launchd_sim /Users/w/Library/Developer/CoreSimulator/Devices/${udid}/data/var/run/launchd_bootstrap.plist`,
    `  40000 35891 S /Users/w/Library/Developer/CoreSimulator/Devices/${udid}/data/Containers/Bundle/Application/AA/FTesterRunnerUITests-Runner.app/FTesterRunnerUITests-Runner`,
    "  50000     1 S .build/debug/ftester-mcp",
  ].join("\n");
  const got = parseResidentProcesses(psOutput, {
    simulatorNames: { [udid]: "iPhone 17 Pro(iOS 27.0)-06" },
  });
  const runner = got.find((p) => p.pid === 40000);
  assert.equal(runner.type, "sim-runner");
  assert.equal(runner.parentDescription, "iPhone 17 Pro(iOS 27.0)-06");
  // ppid<=1 は launchd
  assert.equal(got.find((p) => p.pid === 50000).parentDescription, "launchd(システム)");
});

test("parseResidentProcesses: シミュレータ名が未知なら UDID 短縮にフォールバック", () => {
  const udid = "ABCDEF01-2345-6789-ABCD-EF0123456789";
  const psOutput = [
    `  100     1 S launchd_sim /x/CoreSimulator/Devices/${udid}/data/var/run/launchd_bootstrap.plist`,
    `  200   100 S /x/CoreSimulator/Devices/${udid}/y/FTesterRunnerUITests-Runner.app/FTesterRunnerUITests-Runner`,
  ].join("\n");
  const got = parseResidentProcesses(psOutput); // simulatorNames 無し
  assert.equal(got.find((p) => p.pid === 200).parentDescription, `シミュレータ ${udid.slice(0, 8)}`);
});

test("parseAndroidBridges: adb forward --list から device:8123 転送だけを情報行に合成する", () => {
  const out = [
    "emulator-5554 tcp:52267 tcp:8123", // ブリッジ
    "emulator-5556 tcp:52859 tcp:8123", // ブリッジ
    "emulator-5554 tcp:40000 tcp:5555", // ブリッジ以外の forward → 除外
    "garbage line", // 形式外 → 無視
  ].join("\n");
  const pidBySerial = new Map([["emulator-5554", 12345]]);
  const got = parseAndroidBridges(out, pidBySerial);
  assert.equal(got.length, 2);
  assert.equal(got[0].type, "android-bridge");
  assert.equal(got[0].label, "Androidブリッジ");
  assert.equal(got[0].detail, "emulator-5554"); // 識別子=シリアル
  assert.equal(got[0].port, "52267"); // ホスト側転送ポート
  assert.equal(got[0].pid, 0); // ホスト PID 無し(kill 非対象)
  assert.equal(got[0].devicePid, 12345); // デバイス内 PID → "(12345)" 表示
  assert.equal(got[1].devicePid, undefined); // pidof 未取得なら undefined("—")
  assert.equal(got[0].zombie, false);
  assert.equal(got[0].note, "エミュレータ内プロセス");
  assert.equal(got[0].parentDescription, "Android(emulator-5554)");
});

test("parseResidentProcesses: state Z / <defunct> をゾンビとして立てる", () => {
  const psOutput = [
    "  555     1 Z   .build/debug/ftester-mcp",
    "  666  4321 S   .build/debug/ftester api host-metrics --interval 1 <defunct>",
    "  777  4321 S   .build/debug/ftester api monitor --project SampleApp",
  ].join("\n");
  const byPid = Object.fromEntries(parseResidentProcesses(psOutput).map((p) => [p.pid, p.zombie]));
  assert.equal(byPid[555], true); // state 先頭 Z
  assert.equal(byPid[666], true); // command に <defunct>
  assert.equal(byPid[777], false); // 通常
});
