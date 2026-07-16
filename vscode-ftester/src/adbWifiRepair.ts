// adbWifiRepair.ts
// MonitorHealthWatchdog の Wi-Fi 修復コマンド実行。vscode を import しない
// (orphanSweep.ts/monitorBridgeWatchdog.ts と同じ方針)。

import { execFile } from "node:child_process";

/** adb がデバイス無応答時にハングしうるための上限(ミリ秒)。 */
const TIMEOUT_MS = 10 * 1000;

/** `adb -s <serial> shell cmd wifi set-wifi-enabled enabled` を実行し、exit 0 なら true。
 * タイムアウト・実行エラーは例外を投げず false を返す。 */
export function repairWifi(adbPath: string, serial: string): Promise<boolean> {
  return new Promise((resolve) => {
    execFile(
      adbPath,
      ["-s", serial, "shell", "cmd", "wifi", "set-wifi-enabled", "enabled"],
      { timeout: TIMEOUT_MS },
      (error) => {
        resolve(!error);
      },
    );
  });
}
