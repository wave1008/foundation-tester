// DeviceActionNotices(src/monitorDeviceActionNotice.ts): 実機の起動で人の操作(ロック解除・
// UI 自動化の承認)を促す通知。要点は「待ちに入ったら出す・待ちが終わったら消える」(ユーザー指示)と、
// 出したことを OUTPUT にも残すこと。消えたかは表示の Promise が解決したかで見る。
import assert from "node:assert/strict";
import { test } from "node:test";
import { DeviceActionNotices } from "../src/monitorDeviceActionNotice";

function make() {
  const shown = [];
  const logged = [];
  const ui = {
    show(message, until) {
      const entry = { message, closed: false };
      until.then(() => { entry.closed = true; });
      shown.push(entry);
    },
  };
  return { notices: new DeviceActionNotices((line) => logged.push(line), ui), shown, logged };
}

const tick = () => new Promise((r) => setImmediate(r));

test("待ちに入ったら出し、終わったら(action:null)消える", async () => {
  const { notices, shown, logged } = make();
  notices.update("iPhone SE3", undefined, "unlock");
  assert.equal(shown.length, 1);
  assert.match(shown[0].message, /iPhone SE3/);
  assert.equal(logged.length, 1);
  assert.ok(logged[0].includes(shown[0].message), logged[0]);
  await tick();
  assert.equal(shown[0].closed, false);
  notices.update("iPhone SE3", undefined, null);
  await tick();
  assert.equal(shown[0].closed, true);
  assert.equal(notices.openAction("iPhone SE3", undefined), undefined);
});

test("同じ台・同じ action が重なっても通知は1枚", () => {
  const { notices, shown } = make();
  notices.update("iPhone SE3", undefined, "approveAutomation");
  notices.update("iPhone SE3", undefined, "approveAutomation");
  assert.equal(shown.length, 1);
});

test("action が変われば前の通知を消して張り替える(ロック解除 → 承認プロンプト)", async () => {
  const { notices, shown } = make();
  notices.update("iPhone SE3", undefined, "unlock");
  notices.update("iPhone SE3", undefined, "approveAutomation");
  await tick();
  assert.equal(shown.length, 2);
  assert.equal(shown[0].closed, true);
  assert.equal(shown[1].closed, false);
  assert.notEqual(shown[0].message, shown[1].message);
});

test("待ちが終われば次の待ちでまた出す(再試行のたびに促す)", () => {
  const { notices, shown } = make();
  notices.update("iPhone SE3", undefined, "approveAutomation");
  notices.update("iPhone SE3", undefined, null);
  notices.update("iPhone SE3", undefined, "approveAutomation");
  assert.equal(shown.length, 2);
});

test("機械が違えば別の台 = 別の通知・片方の終了でもう片方は消えない", async () => {
  const { notices, shown } = make();
  notices.update("iPhone SE3", undefined, "unlock");
  notices.update("iPhone SE3", "M1Max", "unlock");
  assert.match(shown[1].message, /M1Max/);
  notices.update("iPhone SE3", "M1Max", null);
  await tick();
  assert.equal(shown[0].closed, false);
  assert.equal(shown[1].closed, true);
});

test("release(CLI が action:null を出さずに終わった)でも消える", async () => {
  const { notices, shown } = make();
  notices.update("iPhone SE3", undefined, "approveAutomation");
  notices.release("iPhone SE3", undefined);
  await tick();
  assert.equal(shown[0].closed, true);
  // 開いていない台の release は何もしない
  notices.release("iPhone 13", undefined);
});
