// monitorProcessManager.ts
// デバイスモニターパネル(monitorPanel.ts)の常駐子プロセス管理部分。
// monitor プロセス(`fleetest api monitor`)・host-metrics プロセス(`fleetest api host-metrics`)の
// 起動・停止・再起動・pause/resume/suppressFrames 制御を担う。

import { type ChildProcessByStdio, spawn } from "node:child_process";
import type { Readable, Writable } from "node:stream";
import { resolveProjectName } from "./config";
import { deviceCommandArgs } from "./remoteRunArgs";
import { t } from "./i18n";
import {
  type MonitorControlCommand,
  type MonitorDevice,
  filterMonitorDevices,
  isMonitorEvent,
  monitorControlLine,
  sortMonitorDevices,
  toWebviewMessage,
} from "./monitorModel";
import { type MachineLock, applyMachineLockEvent, isConfirmedHeld } from "./machineLockModel";
import { NdjsonParser } from "./ndjson";
import type { MonitorPanelDeps } from "./monitorPanel";

/**
 * `fleetest api monitor` は stdin の EOF を終了指示として扱うため、stdio を "ignore"(=/dev/null)
 * にすると起動直後に EOF を検知して即終了する(タイルが一切表示されない症状の原因)。stdin もパイプで保持する。
 */
type MonitorProcess = ChildProcessByStdio<Writable, Readable, Readable>;

/**
 * host-metrics 子1本ぶんの寿命管理の状態(機械ごと。手元も同じ形で持つ)。
 * failureStreak/gaveUp は「起動後10秒未満での異常終了」が3回続いたら自動再起動を諦めるための
 * 安全弁(旧バイナリに host-metrics サブコマンドが無い機械で無限に ssh を張らない)。
 * 10秒以上動いてからの終了は正常運転とみなして 0 に戻す。gaveUp は「モニター再起動」ボタンと
 * show() の両方でリセットして再挑戦できる(バイナリ更新後の復帰経路)。
 */
interface HostMetricsChild {
  proc: MonitorProcess | undefined;
  /** stopHostMetricsProcess() 経由による意図した終了かどうか(stoppingMonitor と同じ役割)。 */
  stopping: boolean;
  /** 再起動の多重起動ガード(restartPending と同じ役割)。 */
  restartPending: boolean;
  /** 予期しない終了後の自動再起動タイマー(5秒後)。dispose/stop 時に必ずクリアする。 */
  restartTimer: ReturnType<typeof setTimeout> | undefined;
  /** 直近の起動時刻(ms)。close イベントでの経過時間から「起動後10秒未満での異常終了」を判定する。 */
  startedAt: number | undefined;
  failureStreak: number;
  gaveUp: boolean;
}

/**
 * host-metrics プロセス(`fleetest api host-metrics --interval 1`)が stdout に流す1行の形。
 * monitor とは別スキーマなので monitorModel.ts の MonitorEvent には混ぜず、ここで直接定義・検証する。
 */
type HostMetricsRawEvent = {
  readonly kind: "hostMetrics";
  readonly ts: number;
  readonly cpu: number | null;
  readonly gpu: number | null;
  readonly memUsedBytes: number | null;
  readonly memTotalBytes: number | null;
};

/** value が HostMetricsRawEvent として扱ってよいか判定する(isMonitorEvent と同じ方針)。 */
function isHostMetricsEvent(value: unknown): value is HostMetricsRawEvent {
  if (typeof value !== "object" || value === null) {
    return false;
  }
  const record = value as Record<string, unknown>;
  const numberOrNull = (field: unknown): boolean => field === null || typeof field === "number";
  return (
    record.kind === "hostMetrics" &&
    typeof record.ts === "number" &&
    numberOrNull(record.cpu) &&
    numberOrNull(record.gpu) &&
    numberOrNull(record.memUsedBytes) &&
    numberOrNull(record.memTotalBytes)
  );
}

/** host-metrics プロセスの1サンプル、および行の集合を webview へ送るメッセージの形(post() 経由)。
 *  対向: src/webview/monitor/hostCharts.js(applyHostMetrics / setHostMetricMachines)。 */
export type HostMetricsToWebviewMessage =
  | {
      readonly type: "hostMetrics";
      /** どの機械のサンプルか(手元は undefined)。**サンプル自身には入っていない** ——
       *  リモートの子は向こうで自分の値を出すだけなので、spawn した側でここに入れる。 */
      readonly machine?: string;
      readonly cpu: number | null;
      readonly gpu: number | null;
      readonly memUsedBytes: number | null;
      readonly memTotalBytes: number | null;
    }
  /** 行の集合(手元 + このリモート機。値より先に配る)。消えた機械の行は webview 側で捨てる。 */
  | { readonly type: "hostMetricsMachines"; readonly machines: readonly string[] }
  /** その機械で誰かの run(dispatch)が走っているか(docs/remote-runner.md §18.2 M2)。
   *  ツールバーの機械の行に錠前を出す。**held:false は「空き」**で、控えを消す(不明へ戻す)
   *  ときは送らない —— 表示は「錠前が出るか出ないか」の2値で足りる。 */
  | {
      readonly type: "machineLock";
      readonly machine: string;
      readonly held: boolean;
      readonly issuer?: string;
      readonly mine: boolean;
    };

/**
 * monitor / host-metrics の2つの常駐子プロセスの起動・停止・再起動・pause/resume 制御を担う。
 * デバイスライフサイクルキュー(monitorDeviceOps.ts)からは直接参照せず、MonitorPanelDeps の
 * writeMonitorControl コールバック経由で pause/resume を依頼する(サブコントローラ間の直接参照禁止)。
 */
export class MonitorProcessManager {
  private monitorProcess: MonitorProcess | undefined;
  /** stopMonitorProcess() 経由(dispose/再起動)による意図した終了かどうか。 */
  private stoppingMonitor = false;
  /**
   * 現在の monitor プロセスが実際に使っている監視スコープ("<project> <profile>" 形式。profile が
   * 空なら "<project> ")。fleetest.profile/project の変更で再起動が必要かどうかの判定に使う。
   * restartMonitorIfScopeChanged() が変化検知のために読むので公開する。
   */
  monitorScope: string | undefined;
  /**
   * restartMonitorProcess() の多重起動ガード。連続したプロファイル変更やボタン連打で
   * stopMonitorProcess()→startMonitorProcess() が重なり二重起動するのを防ぐ。
   */
  /** scheduleRestartAfterClose の安全弁: close をこの秒数待って来なければ強制的に再起動を進める。
   * stopXProcess は SIGTERM 後 2s で SIGKILL するため close は通常 ~2-3s で来る。8s は余裕を持たせた上限。 */
  private static readonly RESTART_CLOSE_TIMEOUT_MS = 8000;
  private restartPending = false;
  /** monitor の予期しない終了後の自動再起動タイマー(5秒後)。dispose/stop 時に必ずクリアする。 */
  private monitorRestartTimer: ReturnType<typeof setTimeout> | undefined;
  /** monitor の直近の起動時刻(ms)。「起動後10秒未満での異常終了」判定用(host-metrics と同型)。 */
  private monitorStartedAt: number | undefined;
  /** monitor の「起動後10秒未満での異常終了」の連続回数(host-metrics と同型の give-up 用)。 */
  private monitorFailureStreak = 0;
  /** monitor の自動再起動を諦めた状態か。リセット条件も host-metrics と同じ(show()/再起動ボタン)。 */
  private monitorGaveUp = false;
  /**
   * host-metrics 子プロセス(常駐。monitor プロセスとは独立に管理する)。**機械ごとに1本**で、
   * キーは機械名(手元は "")。リモートは `remote exec <machine> -- api host-metrics` ——
   * 専用の ssh 経路は書かない(docs/remote-runner.md §14。配信 = device-stream と同じ規律)。
   */
  private readonly hostMetricsChildren = new Map<string, HostMetricsChild>();
  /**
   * いま行を出しているリモート機(機械名順)。直近の monitorDevices に居る機械の集合で、
   * **表示フィルタは通さない** —— フィルタの出入りで ssh を張り直すと、行が付いたり消えたりする
   * だけのために接続が churn する。
   */
  private hostMetricsMachines: readonly string[] = [];
  /** リモート機ごとの占有(dispatch.lock)。供給元は monitorLock イベント(docs/remote-runner.md
   * §18.2 M2)。**控えが無い機械は「不明」**で、空きとは区別する(machineLockModel.ts)。 */
  private machineLocks: ReadonlyMap<string, MachineLock> = new Map();
  /**
   * 直近の monitorDevices で観測したデバイス一覧(整列済み・表示フィルタ適用前)。
   * fleetest.monitorDeviceFilter が変わったときに次の監視サイクル(最大 interval 秒)を待たず
   * 絞り込み直して再送するためだけに保持する。monitor プロセス起動時にクリアし、旧スコープの
   * 観測が新スコープの表示として再送されないようにする。
   */
  private latestDevices: readonly MonitorDevice[] | undefined;

  /** テスト用の spawn 差し替え口(既定は実 spawn)。monitorProcessManager.test.mjs 参照。 */
  constructor(
    private readonly deps: MonitorPanelDeps,
    private readonly spawnFn: typeof spawn = spawn,
  ) {}

  /**
   * パネルを新規に開いたとき(show())の起動一式: monitor プロセスを起動し、host-metrics の
   * 失敗カウンタをリセットしてから host-metrics プロセスを起動する(前回セッションで諦めていても、
   * 開き直したときは素直に起動を試みる。hostMetricsGaveUp 宣言部参照)。
   */
  startAll(): void {
    this.monitorFailureStreak = 0;
    this.monitorGaveUp = false;
    this.startMonitorProcess();
    // リモート機の子は最初の monitorDevices(syncHostMetricsMachines)で立つ
    const local = this.hostMetricsChild("");
    local.failureStreak = 0;
    local.gaveUp = false;
    this.startHostMetricsProcess();
  }

  /**
   * 「モニター再起動」ボタン(handleWebviewMessage の "restartMonitor")の処理一式: monitor
   * プロセスを再起動し、host-metrics の失敗カウンタもリセットして再起動を試みる(バイナリ更新後は
   * ボタン一つで復帰できるようにするため)。
   */
  restartAll(): void {
    this.monitorFailureStreak = 0;
    this.monitorGaveUp = false;
    this.restartMonitorProcess();
    this.hostMetricsChild(""); // 一度も起動していなくてもボタンで立ち上がるようにする
    for (const child of this.hostMetricsChildren.values()) {
      child.failureStreak = 0;
      child.gaveUp = false;
    }
    this.restartHostMetricsProcess();
  }

  startMonitorProcess(): void {
    // 予約済みの自動再起動があれば無効化する(startHostMetricsProcess と同じ理由 — どの経路から
    // 起動する場合も、close ハンドラが積んだ自動再起動と二重起動しないよう先にタイマーを消す)
    if (this.monitorRestartTimer) {
      clearTimeout(this.monitorRestartTimer);
      this.monitorRestartTimer = undefined;
    }
    this.latestDevices = undefined;
    const config = this.deps.getConfig();
    const resolution = resolveProjectName(this.deps.workspaceRoot, config);
    if (resolution.kind !== "resolved") {
      this.monitorScope = undefined;
      this.deps.post({
        type: "processDown",
        message: t("deviceOps.projectUnresolved"),
      });
      return;
    }

    const interval = Math.max(0.5, config.monitorInterval);
    const args = [
      "api",
      "monitor",
      "--project",
      resolution.project,
      "--interval",
      String(interval),
      "--max-width",
      String(config.monitorMaxWidth),
    ];
    if (config.profile) {
      // 実行プロファイルが参照するデバイスのみに監視対象を絞り込む(空なら全デバイス。CLI 側の既定)。
      args.push("--profile", config.profile);
    }
    this.monitorScope = `${resolution.project} ${config.profile}`;

    let proc: MonitorProcess;
    try {
      proc = this.spawnFn(config.binaryPath, args, {
        cwd: this.deps.workspaceRoot,
        shell: false,
        stdio: ["pipe", "pipe", "pipe"],
      });
    } catch (error) {
      this.deps.outputChannel.appendLine(t("deviceOps.log.monitorStartFailed", { error: String(error) }));
      this.deps.post({
        type: "processDown",
        message: t("deviceOps.monitorStartFailedMessage", { error: String(error) }),
      });
      return;
    }

    // stdin は EOF が終了指示なので、こちらからは何も書かず開いたまま保持する。
    // 相手が先に死んだ後の書き込み(end等)で EPIPE が飛んでも拡張を落とさない。
    proc.stdin.on("error", () => undefined);

    this.stoppingMonitor = false;
    this.monitorProcess = proc;
    // **占有の控えは monitor プロセスと寿命を共にする** —— 供給元はこのプロセスの子
    // (リモート機で走る `api monitor`)で、再起動すれば新しい子が最初のサイクルで出し直す。
    // 残したままだと、終わった run の錠前が出続け配信も畳まれたままになる。
    // **デバイス一覧で間引かない**(消えた機械の行を捨てる hostMetricsMachines とは別の寿命):
    // 子は変化したときだけ出すので、一度捨てると run が終わるまで二度と届かない
    this.machineLocks = new Map();
    this.deps.notifyMachineLocks(this.machineLocks);
    this.monitorStartedAt = Date.now();
    // 再起動(プロファイル切り替え含む)でプロセス側の抑制状態は失われるため、既にストリーミング中の
    // デバイスがあれば suppressFrames を再送する(MonitorDeviceStreamController.streamingIds 参照)。
    const streamingIds = this.deps.getStreamingDeviceIds();
    if (streamingIds.length > 0) {
      this.writeMonitorControl({ cmd: "suppressFrames", devices: streamingIds });
    }

    const stdoutParser = new NdjsonParser(
      (rawValue) => {
        if (!isMonitorEvent(rawValue)) {
          this.deps.outputChannel.appendLine(
            t("deviceOps.log.unknownLine", { label: "monitor", value: JSON.stringify(rawValue) }),
          );
          return;
        }
        let value = rawValue;
        if (value.kind === "monitorHold") {
          // webview へは送らない: 配信の停止は hold 中の全タイル state:"unknown" 化で
          // applyDevices の qualifying 判定(state !== "connected")が畳む。ここはログだけ
          this.deps.outputChannel.appendLine(
            t(value.active ? "deviceOps.log.monitorHoldActive" : "deviceOps.log.monitorHoldReleased"),
          );
          return;
        }
        if (value.kind === "monitorLock") {
          this.applyMachineLock(value);
          return;
        }
        if (value.kind === "monitorDevices") {
          // プロファイルタブの表示順に整列してから全消費側へ配る(sortMonitorDevices 参照)。
          this.latestDevices = sortMonitorDevices(value.devices);
          // MonitorDeviceStreamController のパイプライン張り替え判定に使う(monitorPanel.ts で配線)。
          // 表示フィルタ前を渡す: ウォッチドッグは offline の観測で連続回数をリセットするため、
          // 絞り込んだ一覧を渡すと古い booted 連続回数が次の起動へ持ち越されて誤検知に寄る。
          this.deps.notifyMonitorDevices(this.latestDevices);
          // リモート機の host-metrics(行が増える)。表示フィルタ前の一覧で判定する
          this.syncHostMetricsMachines(this.latestDevices);
          value = {
            kind: "monitorDevices",
            devices: filterMonitorDevices(this.latestDevices, this.deps.getConfig().monitorDeviceFilter),
          };
        }
        // monitorFrame は state==connected のデバイスにしか来ない(ApiMonitorCommand.swift)ため、
        // "running" フィルタで消える対象(offline / unknown)とは重ならない。フレーム側の絞り込みは不要。
        if (value.kind === "monitorFrame" && this.deps.isDeviceStreaming(value.device)) {
          // 生成側(suppressFrames)でも止めているが、送信中フレームとの競合・再起動直後の残りを
          // 吸収する安全弁としてここでも間引く(monitorDeviceStreamController.ts 冒頭コメント参照)。
          return;
        }
        this.deps.post(toWebviewMessage(value));
      },
      (line) => this.deps.outputChannel.appendLine(`[monitor stdout] ${line}`),
    );
    // **CLI が言っている理由を捨てない** —— 以前は exit code だけを見て「マシンプロファイル
    // 未設定かも」と決め打ちしていたため、実際は「その実行プロファイルはこのプロジェクトに
    // 無い」だったときに**見当違いの場所を調べさせた**(2026-08-17 の実害)。
    // stderr の直近の Error 行を控えてバナーに載せる(全文は OUTPUT に残る)
    let lastError: string | undefined;
    const noteStderr = (line: string): void => {
      this.deps.outputChannel.appendLine(`[monitor stderr] ${line}`);
      // ArgumentParser / ValidationError は "Error: …" で始まる。進行ログ(==>/→)は拾わない
      if (line.startsWith("Error:")) {
        lastError = line.slice("Error:".length).trim();
      }
    };
    const stderrParser = new NdjsonParser(
      (value) => this.deps.outputChannel.appendLine(`[monitor stderr] ${JSON.stringify(value)}`),
      noteStderr,
    );

    proc.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => stderrParser.push(chunk));

    proc.on("error", (error) => {
      this.deps.outputChannel.appendLine(t("deviceOps.log.monitorRuntimeError", { error: error.message }));
    });

    proc.on("close", (exitCode, signal) => {
      stdoutParser.end();
      stderrParser.end();
      if (this.monitorProcess === proc) {
        this.monitorProcess = undefined;
      }
      // 意図した停止(dispose/再起動)かどうかはフラグだけで判定する。
      // stdin EOF 経由で終了した場合は signal が null になるため、signal では判定できない。
      const selfInitiated = this.stoppingMonitor;
      this.stoppingMonitor = false;
      // **OUTPUT にも必ず1行残す**(webview バナーはパネルの開き直しで消えるため、これが無いと
      // monitor がいつ・どう死んだかが後から一切追えない。受け手報告 2026-08-24: silent 死に見えた。
      // signal=SIGKILL はバイナリ差し替え(update.sh の再ビルド)の署名)
      this.deps.outputChannel.appendLine(
        t("deviceOps.log.monitorClosed", {
          exitCode: String(exitCode),
          signal: String(signal),
          initiated: selfInitiated ? "self" : "unexpected",
        }),
      );
      if (!selfInitiated) {
        // **終了のたびにバナーは出さない** —— 自動再起動が自己回復させるので、外からの kill
        // (update.sh のバイナリ差し替え・新バイナリへの respawn)で毎回警告が鳴っていた
        // (2026-09-01 報告)。無言にはしない: OUTPUT には上で必ず1行残り、バナーは
        // **再起動を諦めたときだけ**(scheduleMonitorRestart の give-up)。
        // **CLI が理由を言っていればそれを出す**(推測より事実。決め打ちの案内は最後の手段)
        const hint = lastError
          ? lastError
          : exitCode === 0
            ? t("deviceOps.monitorExitedUnexpectedHint")
            : t("deviceOps.monitorExitedMachineHint");
        this.scheduleMonitorRestart(
          t("deviceOps.monitorClosedMessage", {
            exitCode: String(exitCode),
            signal: String(signal),
            hint,
          }),
        );
      }
    });
  }

  /**
   * monitor プロセスの予期しない終了を受けて、再起動するか諦めるかを決める(host-metrics と同型。
   * 2026-08-24 追加 — それまで monitor は死ぬとバナー通知のみで、パネルの開き直しまで戻らなかった。
   * 実害: update.sh の再ビルドが稼働中バイナリを差し替えて SIGKILL → 無人計測の監視が止まりっぱなし)。
   */
  private scheduleMonitorRestart(downMessage: string): void {
    const elapsedMs = Date.now() - (this.monitorStartedAt ?? Date.now());
    if (elapsedMs < 10000) {
      this.monitorFailureStreak += 1;
    } else {
      this.monitorFailureStreak = 0;
    }
    if (this.monitorFailureStreak >= 3) {
      if (!this.monitorGaveUp) {
        this.monitorGaveUp = true;
        this.deps.outputChannel.appendLine(t("deviceOps.log.monitorGaveUp"));
        // バナーはここでだけ出す(close 側のコメント参照)。downMessage は CLI の Error 行を
        // 最優先にした終了理由(monitorClosedMessage 済みの文)
        this.deps.post({
          type: "processDown",
          message: t("deviceOps.monitorGaveUpMessage", { detail: downMessage }),
        });
      }
      return;
    }
    this.deps.outputChannel.appendLine(t("deviceOps.log.monitorRestartScheduled"));
    this.monitorRestartTimer = setTimeout(() => {
      this.monitorRestartTimer = undefined;
      // 5秒待つ間にパネルが閉じられていたら何もしない(host-metrics と同じ)。
      if (this.deps.isPanelActive()) {
        this.startMonitorProcess();
      }
    }, 5000);
  }

  /** 実行中の monitor プロセスがあれば SIGTERM(2秒後 SIGKILL)で止める。無ければ何もしない。 */
  stopMonitorProcess(): void {
    if (this.monitorRestartTimer) {
      clearTimeout(this.monitorRestartTimer);
      this.monitorRestartTimer = undefined;
    }
    const proc = this.monitorProcess;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      return;
    }
    this.stoppingMonitor = true;
    // 行儀よく stdin EOF(=終了指示)を送ってから SIGTERM も送る(どちらでもクリーンに終了する)。
    proc.stdin.end();
    proc.kill("SIGTERM");
    setTimeout(() => {
      if (proc.exitCode === null && proc.signalCode === null) {
        proc.kill("SIGKILL");
      }
    }, 2000);
  }

  /**
   * fleetest.monitorDeviceFilter の変更を、次の監視サイクルを待たず直近の観測へ適用して再送する
   * (monitor プロセスの再起動は不要 — 監視スコープは変わらず拡張側の表示フィルタだけが変わるため)。
   * 観測がまだ無い(起動直後・スコープ変更直後)なら何もしない: 次サイクルでフィルタ込みで届く。
   */
  repostDevicesWithCurrentFilter(): void {
    if (!this.latestDevices) {
      return;
    }
    // webview への再送のみ(notifyMonitorDevices は呼ばない — ホスト側の状態は何も変わっていない)。
    const visible = filterMonitorDevices(this.latestDevices, this.deps.getConfig().monitorDeviceFilter);
    this.deps.post(toWebviewMessage({ kind: "monitorDevices", devices: visible }));
  }

  /**
   * monitor プロセスを止めてから起動し直す(「モニター再起動」ボタン、および
   * restartMonitorIfScopeChanged() の両方から呼ばれる)。多重起動ガードで潰された再起動要求が
   * あっても実害はない — 実際に走る startMonitorProcess() は呼び出し時点の getConfig() を読むため、
   * 最終的に反映されるのは常に最新の設定である。
   */
  restartMonitorProcess(): void {
    if (this.restartPending) {
      return;
    }
    this.restartPending = true;
    const proc = this.monitorProcess;
    this.stopMonitorProcess();
    this.scheduleRestartAfterClose(
      proc,
      () => { this.restartPending = false; },
      () => this.startMonitorProcess(),
    );
  }

  /** proc の close を待って start する共通ロジック。close が来ない(defunct/zombie 化等)と
   * pending が永久 true になり以後の再起動が全て握り潰されるため、RESTART_CLOSE_TIMEOUT_MS の
   * 安全弁でも1回だけ進める(close と二重起動しない)。 */
  private scheduleRestartAfterClose(
    proc: MonitorProcess | undefined,
    clearPending: () => void,
    start: () => void,
  ): void {
    if (!proc) {
      clearPending();
      start();
      return;
    }
    let proceeded = false;
    const proceed = () => {
      if (proceeded) {
        return;
      }
      proceeded = true;
      clearTimeout(timer);
      clearPending();
      start();
    };
    const timer = setTimeout(proceed, MonitorProcessManager.RESTART_CLOSE_TIMEOUT_MS);
    proc.once("close", proceed);
  }

  /** 機械1つぶんの寿命管理の状態(無ければ作る)。キーは機械名(手元は "")。 */
  private hostMetricsChild(machine: string): HostMetricsChild {
    const existing = this.hostMetricsChildren.get(machine);
    if (existing) {
      return existing;
    }
    const child: HostMetricsChild = {
      proc: undefined,
      stopping: false,
      restartPending: false,
      restartTimer: undefined,
      startedAt: undefined,
      failureStreak: 0,
      gaveUp: false,
    };
    this.hostMetricsChildren.set(machine, child);
    return child;
  }

  /** OUTPUT の1行。リモートの子はどの機械のものか分からないと読めないので機械名を前置する。 */
  private hostMetricsLog(machine: string, message: string): void {
    this.deps.outputChannel.appendLine(machine ? `[${machine}] ${message}` : message);
  }

  /**
   * 直近の monitorDevices に居るリモート機に合わせて、host-metrics の子と webview の行を揃える。
   * **表示フィルタ前の一覧で判定する**(hostMetricsMachines 参照)。集合が変わったときだけ動く。
   */
  private syncHostMetricsMachines(devices: readonly MonitorDevice[]): void {
    const wanted = [
      ...new Set(devices.map((device) => device.machine).filter((machine): machine is string =>
        typeof machine === "string" && machine !== "")),
    ].sort();
    const current = this.hostMetricsMachines;
    if (wanted.length === current.length && wanted.every((machine, i) => machine === current[i])) {
      return;
    }
    this.hostMetricsMachines = wanted;
    for (const machine of current) {
      if (!wanted.includes(machine)) {
        this.stopHostMetricsProcess(machine);
        this.hostMetricsChildren.delete(machine);
      }
    }
    // 値より先に行の集合を配る(観測が来る前から行が見えるようにする)
    this.deps.post({ type: "hostMetricsMachines", machines: wanted });
    for (const machine of wanted) {
      if (current.includes(machine)) {
        continue; // 既に子が居る(諦めた機械もそのまま — 再挑戦は「モニター再起動」から)
      }
      const child = this.hostMetricsChild(machine);
      child.failureStreak = 0;
      child.gaveUp = false;
      this.startHostMetricsProcess(machine);
    }
  }

  /** いまの行の集合(リモート機。手元は webview 側が常に持つ)を webview へ配り直す。
   *  webview の再読込(パネル生成・言語切替)で行が消えるので sendInitialState から呼ぶ。 */
  postHostMetricsMachines(): void {
    this.deps.post({ type: "hostMetricsMachines", machines: this.hostMetricsMachines });
    this.postMachineLocks();
  }

  /** いまの占有を webview へ配り直す(行の集合と同じく webview 再読込で失われる)。 */
  postMachineLocks(): void {
    for (const [machine, lock] of this.machineLocks) {
      this.deps.post({
        type: "machineLock", machine, held: isConfirmedHeld(lock), issuer: lock.issuer, mine: lock.mine,
      });
    }
  }

  /** リモート機で誰かが run を走らせているか。破壊的操作の確認が読む(占有が**不明**の機械は
   * undefined —— 「走っていない」と請け合わない)。 */
  machineLock(machine: string): MachineLock | undefined {
    return this.machineLocks.get(machine);
  }

  /** いま run が走っている機械の一覧(一括停止の確認が読む)。 */
  occupiedMachineList(): readonly { readonly machine: string; readonly issuer?: string }[] {
    // **観測できているものだけを名指しする**(不明を「実行中」と言わない。言えないことは黙る)
    return [...this.machineLocks]
      .filter(([, lock]) => isConfirmedHeld(lock))
      .map(([machine, lock]) => ({ machine, issuer: lock.issuer }));
  }

  /** monitorLock 1件を控えへ畳み、変化があれば配信の退避と表示へ配る。 */
  private applyMachineLock(event: {
    readonly machine?: string; readonly observed: boolean; readonly held: boolean;
    readonly issuer?: string; readonly issuerHost?: string; readonly acquiredAt?: string;
    readonly mine: boolean;
  }): void {
    const before = event.machine === undefined ? undefined : this.machineLocks.get(event.machine);
    this.machineLocks = applyMachineLockEvent(this.machineLocks, event);
    const after = event.machine === undefined ? undefined : this.machineLocks.get(event.machine);
    if (before?.held === after?.held && before?.issuer === after?.issuer
        && before?.observed === after?.observed) {
      return;
    }
    if (event.machine !== undefined) {
      // **「終わった」と言うのは、掴んでいたのが解放されたときだけ** —— 起動直後の
      // 「不明 → 空き」や、観測が途切れただけの遷移で「run が終わりました」と書かない
      // (毎回の monitor 起動で、走ってもいない run の完了行が機械ぶん並ぶ)
      if (isConfirmedHeld(after)) {
        this.deps.outputChannel.appendLine(t("deviceOps.log.machineLockHeld",
          { machine: event.machine, issuer: after?.issuer ?? "?" }));
      } else if (isConfirmedHeld(before) && after?.observed === true) {
        this.deps.outputChannel.appendLine(
          t("deviceOps.log.machineLockFree", { machine: event.machine }));
      }
      this.deps.post({
        type: "machineLock", machine: event.machine,
        held: isConfirmedHeld(after), issuer: after?.issuer, mine: after?.mine ?? false,
      });
    }
    this.deps.notifyMachineLocks(this.machineLocks);
  }

  /**
   * host-metrics プロセス(`fleetest api host-metrics --interval 1`)を spawn する。--project/--profile は
   * 付けない — ホストMac自体の値であり監視対象デバイスに依存しないため(restartMonitorIfScopeChanged()
   * からは呼ばない)。このプロセスはライブ表示専用でファイル永続化は行わない — 実行履歴は
   * run 単位(RunRecorder)で results/runs/<YYYY-MM>/<runID>/host-metrics.ndjson へ記録される。
   * machine を渡すと `remote exec <machine> -- …` でその機械の値を採る(既存の汎用転送を使うだけ)。
   */
  startHostMetricsProcess(machine = ""): void {
    const child = this.hostMetricsChild(machine);
    // 予約済みの自動再起動があれば無効化する。「プロセス終了→close未配送」の隙間で
    // restartHostMetricsProcess() が走ると、close ハンドラが積んだ自動再起動と本起動の両方が
    // 生きて二重起動し得るため、どの経路から起動する場合も先にタイマーを消す。
    if (child.restartTimer) {
      clearTimeout(child.restartTimer);
      child.restartTimer = undefined;
    }
    const config = this.deps.getConfig();
    let proc: MonitorProcess;
    try {
      proc = this.spawnFn(
        config.binaryPath,
        deviceCommandArgs(
          machine ? { kind: "remote", machine } : { kind: "local" },
          ["api", "host-metrics", "--interval", "1"],
        ),
        {
          cwd: this.deps.workspaceRoot,
          shell: false,
          stdio: ["pipe", "pipe", "pipe"],
        },
      );
    } catch (error) {
      this.hostMetricsLog(machine, t("deviceOps.log.hostMetricsStartFailed", { error: String(error) }));
      return;
    }

    // stdin は EOF が終了指示なので、こちらからは何も書かず開いたまま保持する(monitor と同じ)。
    // リモートの子でも同じ: `remote exec` は ssh に stdin を継承させるので、閉じれば向こうの
    // host-metrics まで EOF が届いて畳まれる。
    proc.stdin.on("error", () => undefined);

    child.stopping = false;
    child.proc = proc;
    child.startedAt = Date.now();

    const label = machine ? `host-metrics ${machine}` : "host-metrics";
    const stdoutParser = new NdjsonParser(
      (value) => {
        if (!isHostMetricsEvent(value)) {
          this.deps.outputChannel.appendLine(
            t("deviceOps.log.unknownLine", { label, value: JSON.stringify(value) }),
          );
          return;
        }
        this.deps.post({
          type: "hostMetrics",
          // 子は自分の値を出すだけで機械名を知らない(向こうから見れば自分が手元)。
          // どの行へ積むかはここでしか分からないので、spawn した側で付ける
          ...(machine ? { machine } : {}),
          cpu: value.cpu,
          gpu: value.gpu,
          memUsedBytes: value.memUsedBytes,
          memTotalBytes: value.memTotalBytes,
        });
      },
      (line) => this.deps.outputChannel.appendLine(`[${label} stdout] ${line}`),
    );
    const stderrParser = new NdjsonParser(
      (value) => this.deps.outputChannel.appendLine(`[${label} stderr] ${JSON.stringify(value)}`),
      (line) => this.deps.outputChannel.appendLine(`[${label} stderr] ${line}`),
    );

    proc.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => stderrParser.push(chunk));

    proc.on("error", (error) => {
      this.hostMetricsLog(machine, t("deviceOps.log.hostMetricsRuntimeError", { error: error.message }));
    });

    proc.on("close", () => {
      stdoutParser.end();
      stderrParser.end();
      if (child.proc === proc) {
        child.proc = undefined;
      }
      // 意図した停止(dispose/再起動)かどうかはフラグだけで判定する(monitor と同じ理由)。
      const selfInitiated = child.stopping;
      child.stopping = false;
      if (selfInitiated) {
        return;
      }
      this.scheduleHostMetricsRestart(machine);
    });
  }

  /**
   * host-metrics プロセスの予期しない終了を受けて、再起動するか諦めるかを決める。3回連続で
   * 諦めたら outputChannel に1回だけログする(カウンタの意味は HostMetricsChild 参照)。
   */
  private scheduleHostMetricsRestart(machine: string): void {
    const child = this.hostMetricsChild(machine);
    const elapsedMs = Date.now() - (child.startedAt ?? Date.now());
    if (elapsedMs < 10000) {
      child.failureStreak += 1;
    } else {
      child.failureStreak = 0;
    }
    if (child.failureStreak >= 3) {
      if (!child.gaveUp) {
        child.gaveUp = true;
        this.hostMetricsLog(machine, t("deviceOps.log.hostMetricsGaveUp"));
      }
      return;
    }
    child.restartTimer = setTimeout(() => {
      child.restartTimer = undefined;
      // 5秒待つ間にパネルが閉じられていたら何もしない。リモートは、その間にその機械の
      // デバイスが消えていたら張り直さない(行も既に消えている)
      if (!this.deps.isPanelActive()) {
        return;
      }
      if (machine !== "" && !this.hostMetricsMachines.includes(machine)) {
        return;
      }
      this.startHostMetricsProcess(machine);
    }, 5000);
  }

  /**
   * 実行中の host-metrics プロセスを SIGTERM(2秒後 SIGKILL)で止める(stopMonitorProcess と同じ方針)。
   * machine 省略時は**全機械ぶん**(パネルを閉じる・dispose・掃討の経路はこちら)。
   */
  stopHostMetricsProcess(machine?: string): void {
    if (machine === undefined) {
      for (const key of [...this.hostMetricsChildren.keys()]) {
        this.stopHostMetricsProcess(key);
        if (key !== "") {
          // **リモートの記録は捨てる** —— 残すと「モニター再起動」がもう誰も見ていない機械の
          // ssh を張り直す(行の集合は下で空にするので、webview にも行は無い)
          this.hostMetricsChildren.delete(key);
        }
      }
      // 次に monitorDevices が来たら行を配り直す(集合が同じでも再送させるため空にする)
      this.hostMetricsMachines = [];
      return;
    }
    const child = this.hostMetricsChildren.get(machine);
    if (!child) {
      return;
    }
    if (child.restartTimer) {
      clearTimeout(child.restartTimer);
      child.restartTimer = undefined;
    }
    const proc = child.proc;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      return;
    }
    child.stopping = true;
    proc.stdin.end();
    proc.kill("SIGTERM");
    setTimeout(() => {
      if (proc.exitCode === null && proc.signalCode === null) {
        proc.kill("SIGKILL");
      }
    }, 2000);
  }

  /**
   * host-metrics プロセスを止めてから起動し直す(「モニター再起動」ボタンから呼ばれる)。
   * 多重起動ガードは restartMonitorProcess と同じ理由(連打で二重起動しないようにする)。
   * リモートの子も同じ扱い(向こうのバイナリを更新したあとボタン一つで復帰できるようにする)。
   */
  private restartHostMetricsProcess(): void {
    for (const machine of [...this.hostMetricsChildren.keys()]) {
      const child = this.hostMetricsChild(machine);
      if (child.restartPending) {
        continue;
      }
      child.restartPending = true;
      const proc = child.proc;
      this.stopHostMetricsProcess(machine);
      this.scheduleRestartAfterClose(
        proc,
        () => { child.restartPending = false; },
        () => this.startHostMetricsProcess(machine),
      );
    }
  }

  /**
   * モニタープロセスの stdin に制御コマンドを書き込む(NDJSON 1行)。モニターが
   * 未起動・終了済みのとき、および書き込み失敗はいずれも黙ってスキップし、呼び出し元のジョブ実行は
   * 継続させる。MonitorPanelDeps.writeMonitorControl 経由で呼ばれる(サブコントローラ間の直接参照禁止)。
   */
  writeMonitorControl(cmd: MonitorControlCommand): void {
    const proc = this.monitorProcess;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      return;
    }
    try {
      proc.stdin.write(monitorControlLine(cmd));
    } catch {
      // 無視する(呼び出し元は継続させる)。
    }
  }
}
