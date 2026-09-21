// hostMetricsRetry.ts
// host-metrics 子プロセス(機械ごとに1本)の「次にいつ試すか」の判定だけを持つ純粋関数と、
// その定数。消費側は monitorProcessManager.ts の1箇所。
//
// 対向: Sources/fleetest/RemoteMonitorFanout.swift の `retryPlan`(同じ形の純粋関数。
// あちらは fanout の子、こちらは host-metrics の子)。**名前と形を寄せてある**ので、
// 片方を読めばもう片方の判断も追える。値そのものは別(停滞の実害が桁違い —— あちらが
// 止まると台が不明・配信が畳まれたままになるので 60 秒、こちらは行が空になるだけ)。

import type { MonitorDeviceState } from "./monitorDeviceModel";

/** 起動から何 ms 未満での終了を「すぐ死んだ」とみなすか。ssh の接続確立 + fleetest の起動で
 *  数秒はかかるので、それを超えて生きていたなら設定は通っていたと判断する。 */
export const HOST_METRICS_QUICK_FAILURE_MS = 10000;
/** すぐ死ぬのが何回続いたら短間隔の再起動をやめるか(旧バイナリに `api host-metrics` が無い
 *  機械へ 5 秒ごとに ssh を張り続けない)。 */
export const HOST_METRICS_QUICK_FAILURE_LIMIT = 3;
/** 通常の再起動の待ち(ms)。 */
export const HOST_METRICS_RETRY_DELAY_MS = 5000;
/** 諦めたあとに試し直す間隔(ms)。単位は分オーダーで選ぶ:
 *  ①非対応バイナリの機械に払う無駄は「10分に ssh 1本」= 実質ゼロ
 *  ②飽和は run が終われば解けるので、フル E2E(実測 18 分)の途中と直後に必ず1回は当たる。
 *  尽きない(回数上限を置かない) —— 上限を置くと2回目の長い run でまた恒久停止に戻る。
 *  **短くしてはいけない** —— 短くすると上の2つ(①の churn・②の空振り)を両方壊す。
 *  ランナーの再起動(2分前後)の取りこぼしは、時間ではなく observationRevivalPlan の
 *  「その機械が再び観測できるようになった」合図で拾う。 */
export const HOST_METRICS_GIVE_UP_RETRY_MS = 10 * 60 * 1000;

/** 子が死んだあとの次の一手。 */
export interface HostMetricsRetryPlan {
  /** 更新後の連続クイック失敗回数。 */
  readonly failureStreak: number;
  readonly delayMs: number;
  /** true なら短間隔をやめた(ログは「諦める」形にする)。 */
  readonly gaveUp: boolean;
}

/** `elapsedMs` = 子が生きていた時間。HOST_METRICS_QUICK_FAILURE_MS 未満なら連続回数を増やし、
 *  HOST_METRICS_QUICK_FAILURE_LIMIT に達したら長い間隔へ落とす。 */
export function retryPlan(args: {
  readonly failureStreak: number;
  readonly elapsedMs: number;
}): HostMetricsRetryPlan {
  const failureStreak = args.elapsedMs < HOST_METRICS_QUICK_FAILURE_MS ? args.failureStreak + 1 : 0;
  const gaveUp = failureStreak >= HOST_METRICS_QUICK_FAILURE_LIMIT;
  return {
    failureStreak,
    delayMs: gaveUp ? HOST_METRICS_GIVE_UP_RETRY_MS : HOST_METRICS_RETRY_DELAY_MS,
    gaveUp,
  };
}

/**
 * その機械を**いま観測できているか**。供給元は monitorDevices の state だけで、新しい判定は
 * 作らない —— 「観測していない台は unknown」の既存の規律(monitorDeviceModel.ts の
 * MonitorDeviceState)にそのまま乗る。**offline は観測できている**(止まっていると分かる)
 * ので unknown と混ぜない。
 */
export type MachineObservation = "observed" | "unobserved";

/** 機械名 → 観測できているか。machine を持たない台(手元)は含めない —— 合図で拾いたいのは
 *  リモートランナーの再起動だけで、手元の host-metrics はランナーの生死と無関係。 */
export function machineObservations(
  devices: readonly { readonly machine?: string; readonly state: MonitorDeviceState }[],
): ReadonlyMap<string, MachineObservation> {
  const observations = new Map<string, MachineObservation>();
  for (const device of devices) {
    const machine = device.machine;
    if (typeof machine !== "string" || machine === "") {
      continue;
    }
    // 1台でも観測できていればその機械は観測できている(子は全台まとめて落ちるので、
    // 混ざるのは張り直しの途中だけ)
    if (device.state !== "unknown") {
      observations.set(machine, "observed");
    } else if (!observations.has(machine)) {
      observations.set(machine, "unobserved");
    }
  }
  return observations;
}

/** 諦めを畳んで即座に張り直すか。 */
export interface HostMetricsRevivalPlan {
  readonly foldGiveUp: boolean;
}

/**
 * **「その機械が再び観測できるようになった」を再挑戦の合図にする**(タイマーは1msも縮めない)。
 *
 * ランナーを再起動すると、2分前後のあいだ LAN 上では TCP が即座に拒否されるので、host-metrics の
 * 子は「起動直後の異常終了」の枠をミリ秒で使い切って HOST_METRICS_GIVE_UP_RETRY_MS(10分)の
 * 窓に入る。exit code では「一時的(再起動)」と「恒久的(旧バイナリ・飽和)」を区別できない
 * (`remote exec` は到達確認で失敗すると ExitCode を持たないので ssh の 255 は 1 に畳まれる。
 * stderr の文言での判定は書式が変われば静かに壊れるので採らない)。
 *
 * 一方で**再起動だけは別のデータに現れる**: ランナーが落ちると monitor の fanout の子も死に、
 * その機械の台は state:"unknown" になる。戻ると fanout が 60 秒以内に張り直して観測が戻る。
 * この遷移(unobserved → observed)を合図にすれば、区別できない2つは合図を出さない:
 *   - 旧バイナリ: fanout の子も上がらない = 台は unknown のまま = 合図が出ない
 *   - 飽和: fanout の子は生きたまま host-metrics だけ落ちる = ずっと observed = 合図が出ない
 * 飽和で fanout まで落ちた場合だけは合図が出て1回余分に撃つが、失敗すればまた10分の経路へ
 * 戻るので許容する(ssh 1本ぶん)。
 */
export function observationRevivalPlan(args: {
  /** 前回のその機械の観測状態(初見は undefined)。 */
  readonly before: MachineObservation | undefined;
  readonly now: MachineObservation;
  /** その機械の子が諦めているか。諦めていなければ畳むものが無い(生きている子を張り直さない)。 */
  readonly gaveUp: boolean;
}): HostMetricsRevivalPlan {
  return { foldGiveUp: args.gaveUp && args.before === "unobserved" && args.now === "observed" };
}
