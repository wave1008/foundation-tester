// adbWifiRepair.ts
// MonitorHealthWatchdog の Android 修復コマンド実行(Wi-Fi 再有効化・画面凍結修復)。vscode を import しない
// (orphanSweep.ts/monitorBridgeWatchdog.ts と同じ方針)。画面凍結の修復は CLI(`ftester api repair-display`)へ
// 委譲する — gRPC 優先/adb フォールバック・blank 判定はすべて Swift 側 FTAndroid.AndroidHealthProbe に閉じており、
// 拡張はここで判定ロジックを持たない(対向: Sources/ftester/ApiRepairDisplayCommand.swift)。

import { execFile } from "node:child_process";

/** adb がデバイス無応答時にハングしうるための上限(ミリ秒)。 */
const TIMEOUT_MS = 10 * 1000;

/** repair-display の上限(ミリ秒)。CLI 側は最大2サイクル(dwell 1.5s→3.0s)で抵抗変種 ~11s
 * かかるため、adb 単発より十分長く取る。 */
const REPAIR_TIMEOUT_MS = 60 * 1000;

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

/** 画面凍結(blank-screen)の軽量修復を CLI に委譲する。手順・判定閾値・gRPC/adb の振り分けは
 * Swift 側 AndroidHealthProbe.repairBlankDisplay が唯一の正(docs/performance-tuning.md §7)。
 * 戻り値: 再プローブで非 blank になったら true。spawn 失敗・タイムアウト・JSON 不正は false
 * (例外は投げない。呼び出し側 monitorHealthWatchdog は false を「修復できず」として扱う)。 */
export function repairDisplay(
  binaryPath: string,
  cwd: string,
  serial: string,
): Promise<boolean> {
  return new Promise((resolve) => {
    execFile(
      binaryPath,
      ["api", "repair-display", "--serial", serial],
      { cwd, timeout: REPAIR_TIMEOUT_MS },
      (error, stdout) => {
        if (error) {
          resolve(false);
          return;
        }
        try {
          resolve((JSON.parse(stdout.trim()) as { repaired?: unknown }).repaired === true);
        } catch {
          resolve(false);
        }
      },
    );
  });
}
