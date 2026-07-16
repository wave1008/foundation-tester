// monitorHealthWatchdog.ts
// Android エミュレータのゲストOS健全性プローブ異常(wifi-disabled/clock-skew 等。Swift 側で
// 30秒間隔×2回連続確認済みのもののみ届く)を自動検出し、adb 経由の軽量修復(Wi-Fi 再有効化)または
// device-up/down 再起動で自動修復するウォッチドッグ。vscode を import しない(test/monitorHealthWatchdog.test.mjs
// から node:test で検証するため。monitorBridgeWatchdog.ts と同じ方針)。
//
// 契約: webview へは { type: "healthWatch", name, phase } を post する(name は deviceOpBusy と
// 同じ名前空間=デバイス論理名。monitorModel.ts の MonitorToWebviewMessage 参照)。

import type { MonitorDevice, MonitorDeviceState, MonitorToWebviewMessage } from "./monitorModel";

export type HealthWatchMessage = Extract<MonitorToWebviewMessage, { readonly type: "healthWatch" }>;

/** monitorPanel.ts が唯一の窓口経由で与える依存(サブコントローラ間の直接参照禁止と同じ方針)。 */
export interface MonitorHealthWatchdogDeps {
  post(message: HealthWatchMessage): void;
  /** outputChannel.appendLine への委譲(このモジュールを vscode 非依存に保つため関数で受ける)。 */
  log(message: string): void;
  /** MonitorDeviceOps.enqueueRestart への委譲(down→up をペアで積む。重複排除は呼び出し先)。 */
  enqueueRestart(name: string): void;
  /** MonitorDeviceOps.markCpuRender への委譲。以後この名前の device-up は swiftshader で起動する
   * (セッション中維持)。 */
  forceCpuRender(name: string): void;
  /** adb で Wi-Fi を再有効化する軽量修復。解決失敗・実行失敗は false(例外は投げない)。 */
  runWifiRepair(serial: string): Promise<boolean>;
  /** MonitorDeviceStreamController.restartForDeviceName への委譲。稼働中パイプラインが無ければ
   * false(ポーリングモード・諦め済み等)。 */
  restartStream(name: string): boolean;
  /** 設定 ftester.autoRepairDeviceHealth の現在値。 */
  isAutoRepairEnabled(): boolean;
  /** 実行中のレーンが1つでもあるか(runLaneModel.isAnyLaneRunning への委譲)。 */
  isAnyRunActive(): boolean;
  /** デバイスライフサイクルキューが busy か(MonitorDeviceOps.isQueueBusy への委譲)。 */
  isDeviceLifecycleQueueBusy(): boolean;
  /** テスト用の時刻注入。省略時 Date.now(拡張ホスト側の実運用ではこちらを使う)。 */
  now?: () => number;
}

/** Wi-Fi 再有効化後、再判定を待つクールダウン(ミリ秒)。Swift 側プローブが30秒間隔×2回連続確認の
 * ため、修復効果の反映を待つのに60秒+マージンが要る。 */
const WIFI_REPAIR_COOLDOWN_MS = 120_000;
/** 再起動投入後、再判定を待つクールダウン(ミリ秒)。down→up 一巡+ブート完了+プローブ再確定を待つ。 */
const RESTART_COOLDOWN_MS = 5 * 60_000;
/** クールダウンを挟んで最大何回まで自動再起動を試みるか。超えたら failed で以後停止(異常なし観測まで)。 */
const MAX_RESTART_ATTEMPTS = 2;
/** 異常なし観測がこの時間(ミリ秒)連続して初めてエピソード(試行回数の記憶)を破棄する。ブート直後は
 * 一時的に健全になるため、即時リセットだと restartAttempts が毎回0に戻り MAX_RESTART_ATTEMPTS が
 * 永遠に発動せず無限再起動ループになった実害への対策(2026-07-17)。 */
const EPISODE_RESET_AFTER_HEALTHY_MS = 10 * 60_000;
/** ストリーム修復後、再判定を待つクールダウン(ミリ秒)。Wi-Fi 修復と同じ根拠(プローブ30秒×2回+マージン)。 */
const STREAM_REPAIR_COOLDOWN_MS = 120_000;

interface DeviceHealthEntry {
  /** 現在のエピソードで一度でも unhealthy を post したか。post の重複防止、および異常なし復帰時に
   * "ok" を post すべきかの判定を兼ねる。 */
  degraded: boolean;
  /** このエピソードで Wi-Fi 修復を試みたか(wifi-disabled 単独時のみ1回だけ試す)。 */
  wifiAttempted: boolean;
  /** このエピソードでストリーム修復を試みたか(blank-screen 検出時のみ1回だけ試す)。 */
  streamAttempted: boolean;
  /** このエピソードで CPU 描画(swiftshader)への切替・再起動を試みたか(blank-screen 検出時のみ
   * 1回だけ試す)。 */
  cpuFallbackAttempted: boolean;
  /** このエピソードで実際に投入した再起動の回数。 */
  restartAttempts: number;
  /** この時刻(ms)まで新規の修復・再起動を投入しない(0 = クールダウン無し)。 */
  cooldownUntil: number;
  /** MAX_RESTART_ATTEMPTS 到達済み。異常なし観測まで一切の判定をスキップする。 */
  failed: boolean;
  /** 連続して異常なしを観測し始めた時刻(ms)。undefined = 直近観測が異常または未観測
   * (0 センチネルはテストの注入時計が 0 始まりのため使えない)。
   * EPISODE_RESET_AFTER_HEALTHY_MS 継続して初めてエントリを削除する。 */
  healthySince: number | undefined;
}

function freshEntry(): DeviceHealthEntry {
  return {
    degraded: false,
    wifiAttempted: false,
    streamAttempted: false,
    cpuFallbackAttempted: false,
    restartAttempts: 0,
    cooldownUntil: 0,
    failed: false,
    healthySince: undefined,
  };
}

/**
 * デバイス単位で health 異常を検出し、設定・実行中レーンの状態を見た上で adb Wi-Fi 修復または
 * device-up/down 再起動による自動修復を試みる。observe() は monitorDevices イベント毎(約2秒毎)に
 * 呼ばれる想定で、タイマーは持たない(monitor プロセスが止まれば判定も止まる)。
 *
 * Swift 側で確定済み(2回連続観測)の異常だけが届くため、拡張側に連続回数のデバウンスは不要。
 * observe は毎サイクル同じ health 付きで呼ばれるので、エピソード状態とクールダウンで冪等にする。
 */
export class MonitorHealthWatchdog {
  private readonly entries = new Map<string, DeviceHealthEntry>();
  private readonly now: () => number;

  constructor(private readonly deps: MonitorHealthWatchdogDeps) {
    this.now = deps.now ?? Date.now;
  }

  observe(devices: readonly MonitorDevice[]): void {
    for (const device of devices) {
      this.observeOne(device.name, device.state, device.health, device.serial);
    }
  }

  private observeOne(
    name: string,
    state: MonitorDeviceState,
    health: readonly string[] | undefined,
    serial: string | undefined,
  ): void {
    if (state !== "connected") {
      // 自動再起動中は offline/booted を経由するので、エントリを消してはいけない(failed 等の
      // 記憶を保持したまま connected 復帰を待つ)。
      return;
    }

    const hasIssue = health !== undefined && health.length > 0;

    if (!hasIssue) {
      const entry = this.entries.get(name);
      if (!entry) {
        return;
      }
      if (entry.degraded) {
        entry.degraded = false;
        this.deps.post({ type: "healthWatch", name, phase: "ok" });
      }
      const now = this.now();
      if (entry.healthySince === undefined) {
        entry.healthySince = now;
      } else if (now - entry.healthySince >= EPISODE_RESET_AFTER_HEALTHY_MS) {
        this.entries.delete(name);
      }
      return;
    }

    let entry = this.entries.get(name);
    if (!entry) {
      entry = freshEntry();
      this.entries.set(name, entry);
    }
    entry.healthySince = undefined;

    if (!entry.degraded) {
      entry.degraded = true;
      this.deps.log(`[health-watch] ${name}: ゲストOS健全性異常を検出しました(${health.join(", ")})。`);
      // failed 後に白⇔正常をフラッピングする個体向け: 異常中はタイルに修復失敗を出し続ける。
      this.deps.post({ type: "healthWatch", name, phase: entry.failed ? "failed" : "unhealthy" });
    }

    if (entry.failed) {
      return;
    }

    if (this.now() < entry.cooldownUntil) {
      return;
    }
    if (!this.deps.isAutoRepairEnabled() || this.deps.isAnyRunActive() || this.deps.isDeviceLifecycleQueueBusy()) {
      return;
    }

    const isWifiOnly =
      health.includes("wifi-disabled") && !health.includes("clock-skew") && !health.includes("blank-screen");
    if (isWifiOnly && !entry.wifiAttempted && serial !== undefined) {
      entry.wifiAttempted = true;
      entry.cooldownUntil = this.now() + WIFI_REPAIR_COOLDOWN_MS;
      this.deps.log(`[health-watch] ${name}: Wi-Fi 再有効化による修復を試みます。`);
      this.deps.post({ type: "healthWatch", name, phase: "repairing" });
      void this.deps.runWifiRepair(serial).then((ok) => {
        this.deps.log(
          ok
            ? `[health-watch] ${name}: Wi-Fi 再有効化コマンドを実行しました。`
            : `[health-watch] ${name}: Wi-Fi 再有効化コマンドの実行に失敗しました。`,
        );
      });
      return;
    }

    const hasBlank = health.includes("blank-screen");
    if (hasBlank) {
      // blank-screen 専用ラダー: streamRepair 1回 → swiftshader 再起動 1回 → failed。
      // host 再起動は実験で「治らず再凍結」が確定したため一切挟まない(2026-07-17)。
      if (!entry.streamAttempted) {
        entry.streamAttempted = true;
        if (this.deps.restartStream(name)) {
          entry.cooldownUntil = this.now() + STREAM_REPAIR_COOLDOWN_MS;
          this.deps.log(`[health-watch] ${name}: 画面ストリームヘルパーの再起動による修復を試みます。`);
          this.deps.post({ type: "healthWatch", name, phase: "streamRepairing" });
          return;
        }
        this.deps.log(`[health-watch] ${name}: ストリーム未稼働のためヘルパー再起動をスキップし、CPU 描画切替へ進みます。`);
        // fall through(同サイクルで CPU 描画切替へ)
      }

      if (!entry.cpuFallbackAttempted) {
        entry.cpuFallbackAttempted = true;
        entry.cooldownUntil = this.now() + RESTART_COOLDOWN_MS;
        this.deps.forceCpuRender(name);
        this.deps.log(`[health-watch] ${name}: 画面凍結が解消しないため CPU 描画(swiftshader)へ切り替えて再起動します。`);
        this.deps.post({ type: "healthWatch", name, phase: "cpuFallback" });
        this.deps.enqueueRestart(name);
        return;
      }

      // swiftshader 再起動でも解消しない(想定外)。
      entry.failed = true;
      this.deps.log(`[health-watch] ${name}: CPU 描画への切替後も画面凍結が解消しませんでした。`);
      this.deps.post({ type: "healthWatch", name, phase: "failed" });
      return;
    }

    if (entry.restartAttempts >= MAX_RESTART_ATTEMPTS) {
      entry.failed = true;
      this.deps.log(
        `[health-watch] ${name}: 自動修復を${String(MAX_RESTART_ATTEMPTS)}回試みましたが復旧しませんでした。`,
      );
      this.deps.post({ type: "healthWatch", name, phase: "failed" });
      return;
    }
    entry.restartAttempts += 1;
    entry.cooldownUntil = this.now() + RESTART_COOLDOWN_MS;
    this.deps.log(`[health-watch] ${name}: デバイス再起動による修復を試みます。`);
    this.deps.post({ type: "healthWatch", name, phase: "restarting" });
    this.deps.enqueueRestart(name);
  }
}
