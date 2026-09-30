// monitorBridgeLogRotation.ts
// XCUITest ランナー(iOS のブリッジ)は起動中ずっと結果の束へセッションログを書き、実機の画面配信を
// 続けると1台1日約2.6GB 増える。生きているブリッジの分は既存の掃除では消せないため、ブリッジ診断
// ログの合計が上限を超えた候補を `fleetest api restart-bridge` で起動し直し、古い束を孤児化させて
// 既存の掃除に任せる(束自体は消さない)。
// vscode を import しない(test/monitorBridgeLogRotation.test.mjs から node:test で検証するため。
// monitorBridgeWatchdog.ts と同じ方針)。

import { t } from "./i18n";
import { formatBytesAuto } from "./retentionModel";
import type { DeviceLifecycleJob, MonitorBridgeLogRotationCandidate } from "./monitorModel";

/** monitorPanel.ts が唯一の窓口経由で与える依存(サブコントローラ間の直接参照禁止と同じ方針)。
 * webview への post は無い(この自動修復はタイル表示を持たない。バッジが要るなら bridgeWatch と
 * 同様に足す)。 */
export interface MonitorBridgeLogRotationDeps {
  /** outputChannel.appendLine への委譲(このモジュールを vscode 非依存に保つため関数で受ける)。 */
  log(message: string): void;
  /** MonitorDeviceOps.enqueueLifecycleJob への委譲。同一デバイスの重複排除は呼び出し先に任せる。 */
  enqueueLifecycleJob(job: DeviceLifecycleJob): void;
  /** 実行中のレーンが1つでもあるか(runLaneModel.isAnyLaneRunning への委譲)。 */
  isAnyRunActive(): boolean;
  /** デバイスライフサイクルキューが busy か(MonitorDeviceOps.isQueueBusy への委譲)。他の操作と
   * 重ねると simctl/adb・ブリッジ供給が競合するため、空くまで待つ(bridgeWatchdog と同じ理由)。 */
  isDeviceLifecycleQueueBusy(): boolean;
  /** テスト用の時刻注入。省略時 Date.now(拡張ホスト側の実運用ではこちらを使う)。 */
  now?: () => number;
}

/** 起動し直し後、同じデバイスへ再投入しないクールダウン(ミリ秒)。Swift 側の計測間隔が10分なので、
 * 起動し直し後に古い束が掃除されたことが次の計測に映るまで最大2周期(20分)ぶん同じ候補が届きうる。
 * 起動し直しが断られた(使用中)場合も、このクールダウン後に再挑戦する。 */
const COOLDOWN_MS = 20 * 60 * 1000;

/**
 * `monitorBridgeLogRotation` イベント(候補は変わったときだけ届く)を受けて、busy でなければ
 * `restart-bridge` ジョブを積む。撃てなかった直近の候補は保持し、reevaluate() から
 * (busy が解けた後・クールダウンが明けた後に)拾い直せるようにする。
 */
export class MonitorBridgeLogRotation {
  private readonly now: () => number;
  /** 直近に届いた候補(変わったときだけ届くイベントを、次に呼べる状態になるまで覚えておく控え)。 */
  private lastCandidate: MonitorBridgeLogRotationCandidate | null = null;
  /** deviceId ごとの「この時刻まで再投入しない」。 */
  private readonly cooldownUntil = new Map<string, number>();

  constructor(private readonly deps: MonitorBridgeLogRotationDeps) {
    this.now = deps.now ?? Date.now;
  }

  /** `monitorBridgeLogRotation` イベント受信時に呼ぶ。 */
  observe(candidate: MonitorBridgeLogRotationCandidate | null): void {
    if (candidate !== null && candidate.machine !== undefined) {
      // 契約上ここには乗らない(このマシンのデバイスだけ)。万一乗っていたら手元へ撃たず、
      // 直近の候補も更新しない(二重の備えの一方。もう一方は monitorDeviceModel.ts の isMonitorEvent)。
      return;
    }
    this.lastCandidate = candidate;
    this.tryFire(candidate);
  }

  /** monitorDevices サイクル毎(bridgeWatchdog.observe と同じ呼ばれ方)に呼ぶ再評価口。候補自体は
   * 変わったときしか届かないため、busy/クールダウンで見送った直近の候補を、状況が変わった後に
   * 拾い直すのはここの役目。 */
  reevaluate(): void {
    this.tryFire(this.lastCandidate);
  }

  private tryFire(candidate: MonitorBridgeLogRotationCandidate | null): void {
    if (candidate === null) {
      return;
    }
    if (this.deps.isAnyRunActive() || this.deps.isDeviceLifecycleQueueBusy()) {
      return;
    }
    const cooldown = this.cooldownUntil.get(candidate.deviceId) ?? 0;
    if (this.now() < cooldown) {
      return;
    }
    this.cooldownUntil.set(candidate.deviceId, this.now() + COOLDOWN_MS);
    this.deps.enqueueLifecycleJob({ kind: "device", name: candidate.name, op: "restartBridge" });
    this.deps.log(
      `[bridge-log-rotation] ${t("monitor.bridgeLogRotation.restarting", {
        name: candidate.name,
        limit: formatBytesAuto(candidate.limitBytes),
        bundle: formatBytesAuto(candidate.bundleBytes),
      })}`,
    );
  }
}
