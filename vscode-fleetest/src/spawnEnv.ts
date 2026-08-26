// 拡張が起動する fleetest プロセスへ渡す環境変数。**spawn する場所ごとに書かない**
// (書き分けると設定が一部の経路にしか効かず「切ったのに切れていない」になる。
// spawnEnvCoverage.test.mjs が fleetest を spawn する箇所の取りこぼしを検出する)。
//
// 今のところ渡すのは実機の自動ロック抑止の殺しスイッチだけ。**既定(抑制する)のときは
// 何も足さない** —— 環境を汚さず、CLI 側の既定値を唯一の正にしておく。
// 同期相手: Sources/FTCore/KeepAwakePolicy.swift(鍵と "0" の意味の定義元)。

import * as vscode from "vscode";

/** spawn オプションの `env` に渡す値。追加が無ければ undefined(= 親の環境をそのまま継承)。 */
export function fleetestSpawnEnv(): NodeJS.ProcessEnv | undefined {
  // **テスト実行時の vscode はスタブ**(workspace を持たない)。読めなければ既定=抑制する
  // として扱う —— CLI 側の既定と同じなので、環境には何も足さない
  const suppress =
    vscode.workspace?.getConfiguration("fleetest").get<boolean>("suppressPhysicalDeviceAutoLock", true) ??
    true;
  return buildSpawnEnv(suppress, process.env);
}

/** 設定と環境を切り離した本体(テスト用)。 */
export function buildSpawnEnv(
  suppressPhysicalDeviceAutoLock: boolean,
  base: NodeJS.ProcessEnv,
): NodeJS.ProcessEnv | undefined {
  if (suppressPhysicalDeviceAutoLock) return undefined;
  return { ...base, FT_KEEP_AWAKE: "0" };
}
