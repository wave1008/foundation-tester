// リモート配信の一斉起動を絞る入場制限(src/remoteStreamAdmission.ts)。
//
// 実測(2026-08-30): 1機械あたり ssh は device-stream N + monitor 1 + host-metrics 1 = N+2 本。
// M1Max(8台)がちょうど 10 本で、sshd の MaxStartups 既定 10:30:100 の第1閾値に当たり
// `Connection timed out during banner exchange` で配信が張れなかった。ここが緩むと
// 台数の多い機械ほど確実に再発する。

import assert from "node:assert/strict";
import { test } from "node:test";
import { admitStreamStarts, MAX_LOCAL_HW_STREAM_STARTS_PER_PASS, MAX_REMOTE_STREAM_STARTS_PER_PASS } from "../src/remoteStreamAdmission";

const remote = (n, machine) =>
  Array.from({ length: n }, (_, i) => ({ deviceId: `${machine}:d${i}`, machine }));

test("1機械あたり1パスで起こす本数を上限で止める", () => {
  const admitted = admitStreamStarts(remote(8, "M1Max"), 4);
  assert.equal(admitted.length, 4);
  assert.deepEqual(admitted, ["M1Max:d0", "M1Max:d1", "M1Max:d2", "M1Max:d3"],
    "入力の順序を保つ(タイルの並び順で先頭から起こす)");
});

test("上限は機械ごとに独立(別の機械は互いに枠を食わない)", () => {
  const admitted = admitStreamStarts([...remote(8, "M1Max"), ...remote(8, "M1Ultra")], 4);
  assert.equal(admitted.filter((id) => id.startsWith("M1Max:")).length, 4);
  assert.equal(admitted.filter((id) => id.startsWith("M1Ultra:")).length, 4);
});

test("手元のデバイス(machine 無し)は制限しない —— ssh を張らないので枠と無関係", () => {
  const local = Array.from({ length: 12 }, (_, i) => ({ deviceId: `local:d${i}` }));
  assert.equal(admitStreamStarts(local, 4).length, 12);
});

test("手元とリモートが混ざっても、絞られるのはリモートだけ", () => {
  const mixed = [
    { deviceId: "local:a" }, ...remote(6, "M1Max"), { deviceId: "local:b" },
  ];
  const admitted = admitStreamStarts(mixed, 2);
  assert.deepEqual(admitted, ["local:a", "M1Max:d0", "M1Max:d1", "local:b"]);
});

test("上限に満たなければ全部通す(常に絞る実装を通さない)", () => {
  assert.equal(admitStreamStarts(remote(3, "M1Max"), 4).length, 3);
});

test("既定値は monitor + host-metrics の 2 本を引いてなお余裕がある", () => {
  // MaxStartups の第1閾値 10 に対し、常駐2本 + 既定の同時起動数 <= 10 に収まること
  assert.ok(MAX_REMOTE_STREAM_STARTS_PER_PASS + 2 <= 10,
    `既定 ${MAX_REMOTE_STREAM_STARTS_PER_PASS} + 常駐2本が MaxStartups の第1閾値 10 を超えている`);
  assert.ok(MAX_REMOTE_STREAM_STARTS_PER_PASS >= 1, "1本も起こせないと配信が永久に張られない");
});

// ---- 手元のハードウェアエンコーダの枠(iOS Simulator の h264) ----
// 実測(2026-10-21 23:51): パネルを隠して戻した瞬間に手元の simstream 10 本が同時にエンコードのセッションを開き、
// AppleAVE がマシン全体で -17691 を返し始めた(約5分で自然回復)。緩むと一斉起動のたびに同じ形を踏む。

const localHw = (n) => Array.from({ length: n }, (_, i) => ({ deviceId: `local:hw${i}`, hardwareEncoded: true }));

test("手元のハードウェアエンコードの配信は1パスで上限まで", () => {
  assert.deepEqual(admitStreamStarts(localHw(10), 4, 3), ["local:hw0", "local:hw1", "local:hw2"]);
});

test("手元のエンコーダの枠はリモートの枠と独立(互いに食わない)", () => {
  const admitted = admitStreamStarts([...localHw(5), ...remote(5, "M1Max")], 2, 3);
  assert.equal(admitted.filter((id) => id.startsWith("local:hw")).length, 3);
  assert.equal(admitted.filter((id) => id.startsWith("M1Max:")).length, 2);
});

test("ハードウェアエンコードでない手元の配信(mjpeg・Android)は絞らない", () => {
  const plain = Array.from({ length: 12 }, (_, i) => ({ deviceId: `local:p${i}`, hardwareEncoded: false }));
  assert.equal(admitStreamStarts([...plain, ...localHw(6)], 4, 3).length, 12 + 3);
});

test("手元のエンコーダの枠の既定値は 3", () => {
  assert.equal(MAX_LOCAL_HW_STREAM_STARTS_PER_PASS, 3);
  assert.equal(admitStreamStarts(localHw(10)).length, 3, "既定引数でもこの値で絞る");
});
