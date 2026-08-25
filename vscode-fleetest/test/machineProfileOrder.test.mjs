// マシンプロファイルのデバイス一覧の並び順(2026-08-17 指示)。**機械ごとにまとめる**:
// 手元が先 → ホスト名順、その中で名前順。同名が別ホストに並ぶのが通常なので、名前を第1キーに
// すると1台ずつ機械が入れ替わり「この機械には何が居るか」が読めない。
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { test } from "node:test";
import { listMachineProfiles } from "../src/config.ts";

/** machines/<name>.json を1つ持つワークスペースを作る。 */
function workspaceWith(profile) {
  const ws = fs.mkdtempSync(path.join(os.tmpdir(), "ftmpo-"));
  const dir = path.join(ws, "TestProjects", "P", "profiles", "machines");
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "M.json"), JSON.stringify(profile));
  return ws;
}

test("機械ごとにまとまる(手元 → ホスト名順、その中で名前順)", () => {
  const ws = workspaceWith({
    android: { devices: [
      { machine: "M1Ultra", name: "Pixel-02" },
      { machine: "M1Max", name: "Pixel-01" },
      { machine: "local", name: "Pixel-01" },
      { machine: "M1Ultra", name: "Pixel-01" },
      { machine: "M1Max", name: "Pixel-02" },
    ] },
  });
  const devices = listMachineProfiles(ws, "P")[0].devices;
  assert.deepEqual(
    devices.map((d) => `${d.name}/${d.machine ?? "local"}`),
    ["Pixel-01/local", "Pixel-01/M1Max", "Pixel-02/M1Max", "Pixel-01/M1Ultra", "Pixel-02/M1Ultra"],
  );
});

// machine を書いていないデバイスは直下の既定に居る。**"local" と同一視すると順序が狂う**
test("machine 省略は直下の既定として並べる(手元扱いにしない)", () => {
  const ws = workspaceWith({
    machine: "M1Ultra",
    ios: { devices: [
      { name: "iPhone-01" },                    // 既定 = M1Ultra
      { machine: "local", name: "iPhone-01" },
    ] },
  });
  const devices = listMachineProfiles(ws, "P")[0].devices;
  assert.deepEqual(devices.map((d) => d.machine ?? "(none)"), ["local", "(none)"]);
});
