// adbWifiRepair.ts
// MonitorHealthWatchdog の adb 修復コマンド実行(Wi-Fi 再有効化・画面リセット)。vscode を import しない
// (orphanSweep.ts/monitorBridgeWatchdog.ts と同じ方針)。

import { execFile } from "node:child_process";

/** adb がデバイス無応答時にハングしうるための上限(ミリ秒)。 */
const TIMEOUT_MS = 10 * 1000;

function adb(adbPath: string, args: string[]): Promise<boolean> {
  return new Promise((resolve) => {
    execFile(adbPath, args, { timeout: TIMEOUT_MS }, (error) => {
      resolve(!error);
    });
  });
}

/** `adb -s <serial> shell cmd wifi set-wifi-enabled enabled` を実行し、exit 0 なら true。
 * タイムアウト・実行エラーは例外を投げず false を返す。 */
export function repairWifi(adbPath: string, serial: string): Promise<boolean> {
  return adb(adbPath, ["-s", serial, "shell", "cmd", "wifi", "set-wifi-enabled", "enabled"]);
}

/** 画面凍結(blank-screen)の軽量修復: KEYCODE_SLEEP → 1.5s → KEYCODE_WAKEUP。
 * 凍結は -gpu host の並行合成競合による表示バッファ固着で、表示パイプラインの無効化→再合成が
 * 唯一の軽量修復(実測 ~4s。readback では回復しない。Swift 側の
 * AndroidHealthProbe.repairBlankDisplay と同一手順・docs/performance-tuning.md §7)。
 * 修復の成否確認は Swift 側プローブの次サイクル(health クリア)に委ねるため戻り値はコマンド成否のみ。 */
export async function repairDisplay(adbPath: string, serial: string): Promise<boolean> {
  const slept = await adb(adbPath, ["-s", serial, "shell", "input", "keyevent", "KEYCODE_SLEEP"]);
  await new Promise((resolve) => setTimeout(resolve, 1_500));
  const woke = await adb(adbPath, ["-s", serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP"]);
  return slept && woke;
}
