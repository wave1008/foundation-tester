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

/** blank 判定の PNG サイズ閾値。Swift 側 AndroidHealthProbe.blankScreenMaxPNGBytes(30_000)との
 * 言語間契約 — 変更する場合は両方を同期させること。 */
const BLANK_SCREEN_MAX_PNG_BYTES = 30_000;

/** `adb exec-out screencap -p` の PNG サイズで blank(一様フレーム)を判定する。
 * 取得失敗・0 バイトは「blank ではない」扱い(誤修復継続しない安全側。Swift 側 probeBlank と同方針)。 */
function probeBlank(adbPath: string, serial: string): Promise<boolean> {
  return new Promise((resolve) => {
    execFile(
      adbPath,
      ["-s", serial, "exec-out", "screencap", "-p"],
      { timeout: TIMEOUT_MS, encoding: "buffer", maxBuffer: 16 * 1024 * 1024 },
      (error, stdout) => {
        resolve(!error && stdout.length > 0 && stdout.length < BLANK_SCREEN_MAX_PNG_BYTES);
      },
    );
  });
}

/** 画面凍結(blank-screen)の軽量修復: KEYCODE_SLEEP → dwell → KEYCODE_WAKEUP → dwell → 再プローブ。
 * 凍結は -gpu host の並行合成競合による表示バッファ固着で、表示パイプラインの無効化→再合成が
 * 唯一の軽量修復(readback では回復しない)。1サイクル(dwell 1.5s)で直らない抵抗性の変種が実在し、
 * dwell 3s の2サイクル目で回復する(実測 2026-07-25。Swift 側の AndroidHealthProbe.repairBlankDisplay と
 * 同一手順・docs/performance-tuning.md §7)。戻り値: 再プローブで非 blank になったら true。 */
export async function repairDisplay(adbPath: string, serial: string): Promise<boolean> {
  for (const dwellMs of [1_500, 3_000]) {
    await adb(adbPath, ["-s", serial, "shell", "input", "keyevent", "KEYCODE_SLEEP"]);
    await new Promise((resolve) => setTimeout(resolve, dwellMs));
    await adb(adbPath, ["-s", serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP"]);
    await new Promise((resolve) => setTimeout(resolve, dwellMs));
    if (!(await probeBlank(adbPath, serial))) {
      return true;
    }
  }
  return false;
}
