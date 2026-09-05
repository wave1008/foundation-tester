// childEnv.ts
// 拡張が起こす子プロセスの環境。FT_PARENT_PID を渡すと fleetest 側(FTCore.ParentDeathWatch)が
// この拡張ホストの死で自ら終わる —— stdin を ignore で起こす api run 等は EOF を終了契機に
// できないため、これが無いと拡張の突然死で孤児になる(Codex 指摘 2026-09-05)。
// vscode 非依存(orphanSweep.ts/adbWifiRepair.ts 等 vscode を import しないファイルからも使う)。

/** fleetest 側 FTCore.ParentDeathWatch が読む環境変数名。 */
export const PARENT_PID_ENV = "FT_PARENT_PID";

/** 拡張が spawn/exec/execFile する全プロセスに渡す env を組み立てる。既存の追加分(extra)は
 * 保ちつつ FT_PARENT_PID で上書きする(呼び手が誤って渡していても親 pid を優先)。 */
export function childEnv(extra?: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  return { ...process.env, ...extra, [PARENT_PID_ENV]: String(process.pid) };
}
