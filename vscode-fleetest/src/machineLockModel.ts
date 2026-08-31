// machineLockModel.ts
// **どのリモート機で誰の run が走っているか**の控え(vscode 非依存の純粋関数。
// docs/remote-runner.md §18.2 M2)。供給元は `api monitor` の monitorLock イベント
// (ランナー機で走っている fan-out の子が dispatch.lock をローカルで読み、親が machine を埋める)。
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
 * `observed:false`(子が落ちた)と machine 無しは**控えを消す** = 不明へ戻す。 */
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
  if (event.machine === undefined) {
    // 手元(machine 無し)には dispatch.lock という概念が無い。届いたら捨てる
    return next;
  }
  if (!event.observed) {
    // **控えを消さない** —— 消すと「一度も聞いていない機械」(= 配信してよい)と同じになり、
    // run の最中に子が落ちただけで**配信が再開する**(2026-08-31 のレビュー指摘)。
    // **直前に分かっていた値は残す**(捨てると「不明」と「空きだと分かっている」が同じ形になる)。
    // 残した値を**事実として出してはいけない** —— 表示と確認は isConfirmedHeld を通す
    const previous = current.get(event.machine);
    next.set(event.machine, { ...(previous ?? { held: false, mine: false }), observed: false });
    return next;
  }
  next.set(event.machine, {
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

/** 破壊的操作の確認・錠前の表示に使ってよい占有か。**観測できているときだけ**
 * (不明を「〜の run が実行中」と言わない・「走っていない」とも請け合わない)。 */
// **型述語(`lock is MachineLock`)にしない** —— 偽の枝で「保持していない MachineLock」まで
// 除外され(never へ潰れる)、解放の遷移が書けなくなる
export function isConfirmedHeld(lock: MachineLock | undefined): boolean {
  return lock?.observed === true && lock.held;
}
