// childEnv.ts
// 拡張が起こす子プロセスの環境。FT_PARENT_PID を渡すと fleetest 側(FTCore.ParentDeathWatch)が
// この拡張ホストの死で自ら終わる —— stdin を ignore で起こす api run 等は EOF を終了契機に
// できないため、これが無いと拡張の突然死で孤児になる(Codex 指摘 2026-09-05)。
// vscode 非依存(orphanSweep.ts/adbWifiRepair.ts 等 vscode を import しないファイルからも使う)。

import { hostname } from "node:os";

/** fleetest 側 FTCore.ParentDeathWatch が読む環境変数名。 */
export const PARENT_PID_ENV = "FT_PARENT_PID";

/** 画面配信の所有者の印(FTCore.StreamOwner)。この拡張ホストが起こした配信ヘルパーと監視が
 * 同じ値を持ち、監視は「同じ台のヘルパーを別の印が持っていれば起こさない」と判定する。
 * FT_PARENT_PID は子が自分の pid で上書きして継ぐ(fan-out の子)し ssh 越しにも運べないので、
 * 同一性は別の変数で運ぶ。値は `<hostname>:<pid>`(同じランナーを別の Mac から眺めても衝突しない)。 */
export const STREAM_OWNER_ENV = "FT_STREAM_OWNER";

/** 拡張が spawn/exec/execFile する全プロセスに渡す env を組み立てる。既存の追加分(extra)は
 * 保ちつつ FT_PARENT_PID / FT_STREAM_OWNER で上書きする(呼び手が誤って渡していても拡張ホストを優先)。 */
export function childEnv(extra?: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  return {
    ...process.env,
    ...extra,
    [PARENT_PID_ENV]: String(process.pid),
    [STREAM_OWNER_ENV]: `${hostname()}:${process.pid}`,
  };
}
