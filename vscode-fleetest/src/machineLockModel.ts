// machineLockModel.ts
// **どの機械で誰の run が走っているか**の控え(vscode 非依存の純粋関数。
// docs/remote-runner.md §18.7 M2)。供給元は `api monitor` の monitorLock イベント
// (その機械で走っている監視プロセスが dispatch.lock をローカルで読む。リモートぶんは
// fan-out の子が読んで親が machine を埋め、**手元ぶんは machine 欠落のまま届く**)。
// **手元も対象**: dispatch.lock は機械に1本で、リモートへのディスパッチもローカル run も
// 同じ1本を取る(CLAUDE.md「1マシンで同時に走る run は1本」)。
//
// 使い道は3つ。**どれも「新しい ssh を張らない」ことが前提**(この控えは既に流れている
// モニターの副産物):
//   1. 配信の自動退避 —— 占有中の機械のライブ配信を畳んでポーリングへ落とす
//      (配信を張ったままの run は実際に赤くなる。docs/verification.md)
//   2. 占有の表示 —— ツールバーの機械の行に「誰の run が実行中か」を出す
//   3. 破壊的操作の確認 —— リモートの devices down / デバイス削除の modal に添える
//
// **「不明」と「空き」を混ぜない**。控えが無い機械は不明(観測していない・旧ランナー)で、
// 空きだと言い切らない —— 破壊的操作の確認が「走っている run は無い」と誤って請け合わないため。

import type { MonitorDevice } from "./monitorModel";
import { LOCAL_MACHINE_KEY } from "./runBoardModel";

/** 1機械ぶんの占有。**保持者が誰かは表示専用**(自己申告。Sources/FTRemote/HostOccupancy.swift)。 */
export interface MachineLock {
  /** **その機械をまだ観測できているか**。false = 供給元(リモートの監視の子)が落ちた ——
   * ロックの状態は分からない。**「空き」ではない**(ApiMonitorLockEvent.observed の契約)。 */
  readonly observed: boolean;
  readonly held: boolean;
  readonly issuer?: string;
  readonly issuerHost?: string;
  readonly acquiredAt?: string;
  /** 保持者がこの利用者か。false は「他人」と「不明」の両方を含む。 */
  readonly mine: boolean;
}

/** monitorLock イベント1件を控えへ畳む(不変。新しい Map を返す)。
 * **machine 欠落 = 手元**(`LOCAL_MACHINE_KEY`)—— monitorRuns / monitorDevices と同じ綴り。 */
export function applyMachineLockEvent(
  current: ReadonlyMap<string, MachineLock>,
  event: {
    readonly machine?: string;
    readonly observed: boolean;
    readonly held: boolean;
    readonly issuer?: string;
    readonly issuerHost?: string;
    readonly acquiredAt?: string;
    readonly mine: boolean;
  },
): Map<string, MachineLock> {
  const next = new Map(current);
  // **machine 欠落は捨てない** —— 手元の綴りなので `LOCAL_MACHINE_KEY` へ写す。捨てていた頃は
  // 手元の run 中に錠前が出ず、他人がこの Mac へディスパッチしていても配信が畳まれなかった
  const machine = event.machine ?? LOCAL_MACHINE_KEY;
  if (!event.observed) {
    // **控えを消さない** —— 消すと「一度も聞いていない機械」(= 配信してよい)と同じになり、
    // run の最中に子が落ちただけで**配信が再開する**(2026-08-31 のレビュー指摘)。
    // **直前に分かっていた値は残す**(捨てると「不明」と「空きだと分かっている」が同じ形になる)。
    // 残した値を**事実として出してはいけない** —— 表示と確認は isConfirmedHeld を通す
    const previous = current.get(machine);
    next.set(machine, { ...(previous ?? { held: false, mine: false }), observed: false });
    return next;
  }
  next.set(machine, {
    observed: true,
    held: event.held,
    issuer: event.issuer,
    issuerHost: event.issuerHost,
    acquiredAt: event.acquiredAt,
    mine: event.mine,
  });
  return next;
}

// **デバイス一覧で控えを間引かない**(2026-08-31 のレビュー指摘)。供給元の子は「変化したとき
// だけ」出すので、一覧から一時的に消えた機械の控えを捨てると run が終わるまで二度と届かず、
// 破壊的操作の警告と錠前が黙って消える。寿命は monitor プロセスと共にする
// (monitorProcessManager.ts が起動時に空へ戻す)。

/** 配信を畳むべき機械。**保持者が誰かによらない** —— 自分の run でも配信との干渉は同じ
 * (docs/verification.md の実測: 配信ありのフル E2E で Android が実際に赤になった)。
 *
 * **観測できなくなった機械(observed:false)も畳んだままにする** —— 走っているかどうかが
 * 分からない以上、配信を再開する側に倒さない(その機械のタイルはどのみち state:"unknown" で
 * ポーリング表示になる)。**一度も聞いていない機械は入らない** = 旧ランナーの配信は従来どおり。 */
export function occupiedMachines(locks: ReadonlyMap<string, MachineLock>): Set<string> {
  const occupied = new Set<string>();
  for (const [machine, lock] of locks) {
    if (lock.held || !lock.observed) {
      occupied.add(machine);
    }
  }
  return occupied;
}

/** 配信を畳む機械(「ライブ更新」チェックボックスの反映)。OFF = occupiedMachines と同じ
 * (保持者を問わない)。ON = **他人の run の機械だけ**畳む —— 他人の run を配信で赤くしない
 * (共有ランナーの規律。docs/remote-runner.md §18.7)。観測できない機械は保持者も分からないので
 * ON でも畳む(`mine` は「他人」と「不明」を区別しない)。
 *
 * **手元(`LOCAL_MACHINE_KEY`)も同じ規則で通る** —— 自分の run は `mine:true` なので ON では
 * 畳まれず(ユーザー決定 2026-09-17「自分の run のぶんは利用者が選ぶ」)、他人がこの Mac へ
 * ディスパッチして保持しているときだけ畳む。この3ケースは machineLockModel.test.mjs が等号固定。 */
export function streamFoldMachines(
  locks: ReadonlyMap<string, MachineLock>,
  showStreamDuringRun: boolean,
): Set<string> {
  if (!showStreamDuringRun) {
    return occupiedMachines(locks);
  }
  const folded = new Set<string>();
  for (const [machine, lock] of locks) {
    if (!lock.observed || (lock.held && !lock.mine)) {
      folded.add(machine);
    }
  }
  return folded;
}

/** 破壊的操作の確認・錠前の表示に使ってよい占有か。**観測できているときだけ**
 * (不明を「〜の run が実行中」と言わない・「走っていない」とも請け合わない)。 */
// **型述語(`lock is MachineLock`)にしない** —— 偽の枝で「保持していない MachineLock」まで
// 除外され(never へ潰れる)、解放の遷移が書けなくなる
export function isConfirmedHeld(lock: MachineLock | undefined): boolean {
  return lock?.observed === true && lock.held;
}

/** **手元で run が使っている台**の名前(`inRun` = RunLease 由来なので CLI から起こした run も写る)。
 * リモートの台は含めない(あちらは dispatch.lock = occupiedMachines で見る)。
 * 一覧を未観測(undefined)なら空 = 黙る(CLI 側の門が最後に断る)。 */
export function localDevicesInRun(devices: readonly MonitorDevice[] | undefined): readonly string[] {
  return (devices ?? []).filter((d) => d.machine === undefined && d.inRun === true).map((d) => d.name);
}

export type BulkDownGate =
  /** 全掃討は CLI が丸ごと断る(Sources/FTAndroid/DeviceBooter.swift の sweepRefusal)ので撃たない。
   * **押し切るボタンは出さない**(GUI に --force を出さない規律) */
  | { readonly kind: "blockedByLocalRun"; readonly names: readonly string[] }
  | { readonly kind: "confirmOccupied"; readonly holders: readonly { readonly machine: string; readonly issuer?: string }[] }
  | { readonly kind: "proceed" };

/** 「全て終了」を押したときの門。**手元の run は全掃討(プロファイル未選択)のときだけ止める** ——
 * プロファイル選択時の一括停止は CLI が使用中の台だけ飛ばして残りを止める(stopRefusal)ので、
 * 押すこと自体は妨げない。 */
export function bulkDownGate(input: {
  readonly profileSelected: boolean;
  readonly localInRun: readonly string[];
  readonly occupied: readonly { readonly machine: string; readonly issuer?: string }[];
}): BulkDownGate {
  if (!input.profileSelected && input.localInRun.length > 0) {
    return { kind: "blockedByLocalRun", names: input.localInRun };
  }
  if (input.occupied.length > 0) {
    return { kind: "confirmOccupied", holders: input.occupied };
  }
  return { kind: "proceed" };
}

/** 全掃討の CLI が断ったときの1行(`❌ ` を外した本文)。それ以外は undefined。
 * 文言の対: Sources/FTAndroid/DeviceBooter.swift の sweepRefusal */
export function sweepRefusalDetail(line: string): string | undefined {
  const match = /^❌ (refusing to shut everything down: .*)$/.exec(line.trim());
  return match?.[1];
}
