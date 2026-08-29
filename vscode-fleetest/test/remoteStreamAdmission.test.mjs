// リモート配信の一斉起動を絞る入場制限(src/remoteStreamAdmission.ts)。
//
// 実測(2026-08-30): 1機械あたり ssh は device-stream N + monitor 1 + host-metrics 1 = N+2 本。
// M1Max(8台)がちょうど 10 本で、sshd の MaxStartups 既定 10:30:100 の第1閾値に当たり
// `Connection timed out during banner exchange` で配信が張れなかった。ここが緩むと
// 台数の多い機械ほど確実に再発する。

import assert from "node:assert/strict";
import { test } from "node:test";
import { admitStreamStarts, MAX_REMOTE_STREAM_STARTS_PER_PASS } from "../src/remoteStreamAdmission";

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
