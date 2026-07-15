// monitorBridgeWatchdog.ts
// iOS/Android ブリッジ突然死(XCUITest ランナー等が無応答のまま固まり、connected だったデバイスが
// booted のまま復帰しない)を自動検出し、lifecycle ジョブ(device-up)で自動修復するウォッチドッグ。
// vscode を import しない(test/monitorBridgeWatchdog.test.mjs から node:test で検証するため。
// orphanSweep.ts と同じ方針)。
//
// 契約: webview へは { type: "bridgeWatch", name, phase } を post する(name は deviceOpBusy と
// 同じ名前空間=デバイス論理名。monitorModel.ts の MonitorToWebviewMessage 参照)。

import type {
  DeviceLifecycleJob,
  MonitorDevice,
  MonitorDeviceState,
  MonitorToWebviewMessage,
} from "./monitorModel";

export type BridgeWatchMessage = Extract<MonitorToWebviewMessage, { readonly type: "bridgeWatch" }>;

/** monitorPanel.ts が唯一の窓口経由で与える依存(サブコントローラ間の直接参照禁止と同じ方針)。 */
export interface MonitorBridgeWatchdogDeps {
  post(message: BridgeWatchMessage): void;
  /** outputChannel.appendLine への委譲(このモジュールを vscode 非依存に保つため関数で受ける)。 */
  log(message: string): void;
  /** MonitorDeviceOps.enqueueLifecycleJob への委譲。同一デバイスの重複排除は呼び出し先に任せる。 */
  enqueueLifecycleJob(job: DeviceLifecycleJob): void;
  /** 設定 ftester.autoRepairBridge の現在値。 */
  isAutoRepairEnabled(): boolean;
  /** 実行中のレーンが1つでもあるか(runLaneModel.isAnyLaneRunning への委譲)。 */
  isAnyRunActive(): boolean;
  /** デバイスライフサイクルキューが busy か(MonitorDeviceOps.isQueueBusy への委譲)。一括down 等の
   * 実行中は修復 up を積まない — さもないと停止処理中の booted を無応答と誤検知し、ユーザーが停止した
   * デバイスを勝手に再起動してしまう。 */
  isDeviceLifecycleQueueBusy(): boolean;
  /** テスト用の時刻注入。省略時 Date.now(拡張ホスト側の実運用ではこちらを使う)。 */
  now?: () => number;
}

/** booted が連続何回で無応答とみなすか(interval 2秒設定なら約10秒)。 */
const UNRESPONSIVE_THRESHOLD = 5;
/** 修復ジョブ投入後、再投入しないクールダウン時間(ミリ秒)。 */
const COOLDOWN_MS = 3 * 60 * 1000;
/** クールダウンを挟んで最大何回まで自動修復を試みるか。超えたら failed で以後停止(connected 復帰まで)。 */
const MAX_REPAIR_ATTEMPTS = 2;

interface DeviceWatchEntry {
  /** 直近の連続 booted 観測回数(UNRESPONSIVE_THRESHOLD で頭打ち)。connected/offline の観測でリセットする。 */
  bootedStreak: number;
  /** unresponsive 検出以降に実際に投入した修復ジョブの回数。 */
  attemptCount: number;
  /** この時刻(ms)まで新規の修復ジョブを投入しない(0 = クールダウン無し)。 */
  cooldownUntil: number;
  /** MAX_REPAIR_ATTEMPTS 到達済み。connected 観測まで一切の判定をスキップする。 */
  failed: boolean;
  /** unresponsive を一度でも post したか。post の重複防止、および connected 復帰時に
   * "ok" を post すべきか(=一度でも劣化したか)の判定を兼ねる。 */
  degraded: boolean;
}

function freshEntry(): DeviceWatchEntry {
  return { bootedStreak: 0, attemptCount: 0, cooldownUntil: 0, failed: false, degraded: false };
}

/**
 * デバイス単位で connected→booted への降格(ブリッジ無応答)を検出し、設定・実行中レーンの状態を
 * 見た上で device-up ジョブによる自動修復を試みる。observe() は monitorDevices イベント毎に
 * 呼ばれる想定で、タイマーは持たない(monitor プロセスが止まれば判定も止まる)。
 *
 * 対象は「このインスタンスの生存中に一度でも connected を観測したデバイス」のみ(最初から booted の
 * デバイスは対象外 — 意図的にブリッジ無しで起動している可能性があるため)。
 */
export class MonitorBridgeWatchdog {
  private readonly entries = new Map<string, DeviceWatchEntry>();
  private readonly now: () => number;

  constructor(private readonly deps: MonitorBridgeWatchdogDeps) {
    this.now = deps.now ?? Date.now;
  }

  observe(devices: readonly MonitorDevice[]): void {
    for (const device of devices) {
      this.observeOne(device.name, device.state);
    }
  }

  private observeOne(name: string, state: MonitorDeviceState): void {
    const entry = this.entries.get(name);

    if (state === "connected") {
      if (!entry) {
        this.entries.set(name, freshEntry());
        return;
      }
      if (entry.degraded) {
        this.entries.set(name, freshEntry());
        this.deps.post({ type: "bridgeWatch", name, phase: "ok" });
      } else {
        entry.bootedStreak = 0;
      }
      return;
    }

    if (!entry) {
      // 一度も connected を観測していないデバイスは対象外。
      return;
    }

    if (state === "offline") {
      // 連続性が途切れるだけで、failed/attemptCount/cooldown は connected 観測まで保持する。
      entry.bootedStreak = 0;
      return;
    }

    // state === "booted"
    if (entry.failed) {
      return;
    }
    entry.bootedStreak = Math.min(entry.bootedStreak + 1, UNRESPONSIVE_THRESHOLD);
    if (entry.bootedStreak < UNRESPONSIVE_THRESHOLD) {
      return;
    }
    if (!entry.degraded) {
      entry.degraded = true;
      this.deps.log(
        `[bridge-watch] ${name}: booted が${String(UNRESPONSIVE_THRESHOLD)}回連続したためブリッジ無応答とみなします。`,
      );
      this.deps.post({ type: "bridgeWatch", name, phase: "unresponsive" });
    }

    if (this.now() < entry.cooldownUntil) {
      return;
    }
    if (entry.attemptCount >= MAX_REPAIR_ATTEMPTS) {
      entry.failed = true;
      this.deps.log(
        `[bridge-watch] ${name}: 自動修復を${String(MAX_REPAIR_ATTEMPTS)}回試みましたが復旧しませんでした。`,
      );
      this.deps.post({ type: "bridgeWatch", name, phase: "failed" });
      return;
    }
    if (!this.deps.isAutoRepairEnabled() || this.deps.isAnyRunActive()
        || this.deps.isDeviceLifecycleQueueBusy()) {
      return;
    }
    entry.attemptCount += 1;
    entry.cooldownUntil = this.now() + COOLDOWN_MS;
    this.deps.enqueueLifecycleJob({ kind: "device", name, op: "up" });
    this.deps.post({ type: "bridgeWatch", name, phase: "repairing" });
  }
}
