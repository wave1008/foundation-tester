// monitorProcessManager.ts
// デバイスモニターパネル(monitorPanel.ts)の常駐子プロセス管理部分。
// MonitorProcessManager クラスは、monitor プロセス(`ftester api monitor`)・host-metrics
// プロセス(`ftester api host-metrics`)の起動・停止・再起動・pause/resume 制御を担う。
// monitorPanel.ts の MonitorPanelController はこのクラスのインスタンスを1つ保持し、
// show()/dispose()/restartMonitorIfScopeChanged() 等から公開メソッドを呼び出す
// (webview へのメッセージ送信・設定取得・出力チャネルは MonitorPanelDeps 経由)。

import { type ChildProcessByStdio, spawn } from "node:child_process";
import type { Readable, Writable } from "node:stream";
import { resolveProjectName } from "./config";
import {
  type MonitorControlCommand,
  type MonitorDevice,
  isMonitorEvent,
  monitorControlLine,
  toWebviewMessage,
} from "./monitorModel";
import { NdjsonParser } from "./ndjson";
import type { MonitorPanelDeps } from "./monitorPanel";

/**
 * monitor プロセス用: stdin もパイプで保持する。
 * `ftester api monitor` は stdin の EOF を終了指示として扱うため、stdio を "ignore"(=/dev/null)
 * にすると起動直後に EOF を検知して即終了してしまう(タイルが一切表示されない症状の原因)。
 */
type MonitorProcess = ChildProcessByStdio<Writable, Readable, Readable>;

/**
 * host-metrics プロセス(`ftester api host-metrics --interval 1`)が stdout に流す1行の形。
 * monitor とは別プロセス・別スキーマなので monitorModel.ts の MonitorEvent 側には混ぜず、ここで
 * 直接定義・検証する(isMonitorEvent と同じ「壊れた行は安全側で無視する」方針)。
 */
type HostMetricsRawEvent = {
  readonly kind: "hostMetrics";
  readonly ts: number;
  readonly cpu: number | null;
  readonly gpu: number | null;
  readonly ane: number | null;
  readonly aneWatts: number | null;
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
    numberOrNull(record.ane) &&
    numberOrNull(record.aneWatts) &&
    numberOrNull(record.memUsedBytes) &&
    numberOrNull(record.memTotalBytes)
  );
}

/** host-metrics プロセスの1サンプルを webview へ送るメッセージの形(post() 経由)。 */
export type HostMetricsToWebviewMessage = {
  readonly type: "hostMetrics";
  readonly cpu: number | null;
  readonly gpu: number | null;
  readonly ane: number | null;
  readonly aneWatts: number | null;
  readonly memUsedBytes: number | null;
  readonly memTotalBytes: number | null;
};

/**
 * monitor / host-metrics の2つの常駐子プロセスの起動・停止・再起動・pause/resume 制御を担う。
 * MonitorPanelController が1つ保持し、show()/dispose()/restartMonitorIfScopeChanged()・
 * handleWebviewMessage の "restartMonitor" ケースから呼ばれる。デバイスライフサイクルキュー
 * (monitorDeviceOps.ts の MonitorDeviceOps)からは直接参照せず、MonitorPanelDeps の
 * writeMonitorControl コールバック経由で pause/resume を依頼する(サブコントローラ間の直接参照禁止)。
 */
export class MonitorProcessManager {
  private monitorProcess: MonitorProcess | undefined;
  /** stopMonitorProcess() 経由(dispose/再起動)による意図した終了かどうか。 */
  private stoppingMonitor = false;
  /**
   * 現在の monitor プロセスが実際に使っている監視スコープ("<project> <profile>" 形式。
   * profile が空なら "<project> ")。ftester.profile / ftester.project の変更を検知したときに、
   * 監視対象を変えるべきかどうか(=再起動が必要かどうか)を判定するために保持する。
   * MonitorPanelController.restartMonitorIfScopeChanged() が変化検知のために読むので公開する。
   */
  monitorScope: string | undefined;
  /**
   * restartMonitorProcess() の多重起動ガード。true の間は追加の再起動要求を無視する。
   * 連続したプロファイル変更や「モニター再起動」ボタン連打で stopMonitorProcess() →
   * startMonitorProcess() が重なり、monitor プロセスが二重起動するのを防ぐ。
   */
  private restartPending = false;
  /** host-metrics プロセス(常駐。monitor プロセスとは独立に管理する)。 */
  private hostMetricsProcess: MonitorProcess | undefined;
  /** stopHostMetricsProcess() 経由による意図した終了かどうか(stoppingMonitor と同じ役割)。 */
  private stoppingHostMetrics = false;
  /** restartHostMetricsProcess() の多重起動ガード(restartPending と同じ役割)。 */
  private hostMetricsRestartPending = false;
  /** 予期しない終了後の自動再起動タイマー(5秒後)。dispose/stop 時に必ずクリアする。 */
  private hostMetricsRestartTimer: ReturnType<typeof setTimeout> | undefined;
  /** 直近の起動時刻(ms)。close イベントでの経過時間から「起動後10秒未満での異常終了」を判定する。 */
  private hostMetricsStartedAt: number | undefined;
  /**
   * 「起動後10秒未満での異常終了」が連続した回数。3回連続したら諦めて自動再起動を止める
   * (旧バイナリに host-metrics サブコマンドが無い環境で無限に再起動ループしないための安全弁)。
   * 10秒以上動いてからの終了は正常運転とみなして 0 にリセットする。
   */
  private hostMetricsFailureStreak = 0;
  /**
   * 自動再起動を諦めた状態かどうか。true の間は close イベントで再起動をスケジュールしない。
   * 「モニター再起動」ボタン(handleWebviewMessage の "restartMonitor")でリセットして再挑戦できる
   * (バイナリ更新後の復帰経路)。パネルを開き直したとき(show())も同様にリセットする。
   */
  private hostMetricsGaveUp = false;
  /**
   * 直近の monitorDevices イベントで観測したデバイス一覧(state 込み)。モニタープロセスの再起動
   * (プロファイル切り替え含む)を跨いで保持し、リセットしない — restartMonitorIfScopeChanged() が
   * 「切り替え直前(旧スコープ)の最終観測」を元に、新スコープ外の稼働中デバイスを判定する
   * (devicesToShutdownOnScopeChange)ために必要なため。新しい monitor プロセスが起動して
   * 最初の monitorDevices を出すまでの間も、直前の観測を保持し続ける。
   * MonitorPanelController.enqueueShutdownOutsideNewScope() が読むので公開する。
   */
  lastKnownDevices: readonly MonitorDevice[] = [];

  constructor(private readonly deps: MonitorPanelDeps) {}

  /**
   * パネルを新規に開いたとき(show())の起動一式: monitor プロセスを起動し、host-metrics の
   * 失敗カウンタをリセットしてから host-metrics プロセスを起動する(前回セッションで諦めていても、
   * 開き直したときは素直に起動を試みる。hostMetricsGaveUp 宣言部参照)。
   */
  startAll(): void {
    this.startMonitorProcess();
    this.hostMetricsFailureStreak = 0;
    this.hostMetricsGaveUp = false;
    this.startHostMetricsProcess();
  }

  /**
   * 「モニター再起動」ボタン(handleWebviewMessage の "restartMonitor")の処理一式: monitor
   * プロセスを再起動し、host-metrics の失敗カウンタもリセットして再起動を試みる(バイナリ更新後は
   * ボタン一つで復帰できるようにするため)。
   */
  restartAll(): void {
    this.restartMonitorProcess();
    this.hostMetricsFailureStreak = 0;
    this.hostMetricsGaveUp = false;
    this.restartHostMetricsProcess();
  }

  startMonitorProcess(): void {
    const config = this.deps.getConfig();
    const resolution = resolveProjectName(this.deps.workspaceRoot, config);
    if (resolution.kind !== "resolved") {
      this.monitorScope = undefined;
      this.deps.post({
        type: "processDown",
        message:
          "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
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
    // 実際に使った監視スコープを記録する(restartMonitorIfScopeChanged() が変化検知に使う)。
    this.monitorScope = `${resolution.project} ${config.profile}`;

    let proc: MonitorProcess;
    try {
      proc = spawn(config.binaryPath, args, {
        cwd: this.deps.workspaceRoot,
        shell: false,
        stdio: ["pipe", "pipe", "pipe"],
      });
    } catch (error) {
      this.deps.outputChannel.appendLine(`[ftester] monitor プロセスの起動に失敗しました: ${String(error)}`);
      this.deps.post({
        type: "processDown",
        message: `モニタープロセスの起動に失敗しました: ${String(error)}`,
      });
      return;
    }

    // stdin は EOF が終了指示なので、こちらからは何も書かず開いたまま保持する。
    // 相手が先に死んだ後の書き込み(end等)で EPIPE が飛んでも拡張を落とさない。
    proc.stdin.on("error", () => undefined);

    this.stoppingMonitor = false;
    this.monitorProcess = proc;

    const stdoutParser = new NdjsonParser(
      (value) => {
        if (!isMonitorEvent(value)) {
          this.deps.outputChannel.appendLine(
            `[monitor] 未知の形式の行を無視しました: ${JSON.stringify(value)}`,
          );
          return;
        }
        if (value.kind === "monitorDevices") {
          // モニター再起動(プロファイル切り替え含む)を跨いで保持する(lastKnownDevices 宣言部参照)。
          this.lastKnownDevices = value.devices;
        }
        this.deps.post(toWebviewMessage(value));
      },
      (line) => this.deps.outputChannel.appendLine(`[monitor stdout] ${line}`),
    );
    const stderrParser = new NdjsonParser(
      (value) => this.deps.outputChannel.appendLine(`[monitor stderr] ${JSON.stringify(value)}`),
      (line) => this.deps.outputChannel.appendLine(`[monitor stderr] ${line}`),
    );

    proc.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => stderrParser.push(chunk));

    proc.on("error", (error) => {
      this.deps.outputChannel.appendLine(`[ftester] monitor プロセスでエラーが発生しました: ${error.message}`);
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
      if (!selfInitiated) {
        // exit 0 の予期しない終了(過去例: stdin の扱いの不備)も無言にせず必ず通知する。
        const hint =
          exitCode === 0
            ? "予期せず終了しました。「モニター再起動」で再開できます。"
            : "マシンプロファイル未設定の可能性があります。" +
              "「ftester machine set」の実行、または Projects/<project>/profiles/machines/ の内容を確認してください。";
        this.deps.post({
          type: "processDown",
          message: `モニタープロセスが終了しました(exit code: ${String(exitCode)}, signal: ${String(signal)})。${hint}`,
        });
      }
    });
  }

  /** 実行中の monitor プロセスがあれば SIGTERM(2秒後 SIGKILL)で止める。無ければ何もしない。 */
  stopMonitorProcess(): void {
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
   * monitor プロセスを止めてから起動し直す(「モニター再起動」ボタン、および
   * restartMonitorIfScopeChanged() による監視対象追随の両方から呼ばれる)。
   * 多重起動ガード: restartPending が true の間は追加の呼び出しを無視する(連続したプロファイル
   * 変更やボタン連打で stopMonitorProcess()/startMonitorProcess() が重なり、monitor プロセスが
   * 二重起動するのを防ぐ)。ガードで潰された再起動要求があっても実害はない — 実際に走る
   * startMonitorProcess() は呼び出し時点の getConfig() を読むので、最終的に反映されるのは
   * 常に最新の設定であるため。
   */
  restartMonitorProcess(): void {
    if (this.restartPending) {
      return;
    }
    this.restartPending = true;
    const proc = this.monitorProcess;
    this.stopMonitorProcess();
    if (!proc) {
      this.restartPending = false;
      this.startMonitorProcess();
      return;
    }
    proc.once("close", () => {
      this.restartPending = false;
      this.startMonitorProcess();
    });
  }

  /**
   * host-metrics プロセス(`ftester api host-metrics --interval 1`)を spawn する。monitor プロセスと
   * 同じく stdin をパイプで保持したまま何も書かない(EOF が終了指示)。--project/--profile は
   * 付けない — ホストMac自体の値であり監視対象デバイスに依存しないため(プロファイル/プロジェクト
   * 切り替えでの再起動は不要。restartMonitorIfScopeChanged() からは呼ばない)。
   */
  startHostMetricsProcess(): void {
    // 予約済みの自動再起動があれば無効化する。「プロセス終了→close 未配送」の隙間で
    // restartHostMetricsProcess()(モニター再起動ボタン)が走ると、close ハンドラが積んだ
    // 5秒後の自動再起動と本起動の両方が生きて host-metrics が二重起動し得るため、
    // どの経路から起動する場合も先にタイマーを消す。
    if (this.hostMetricsRestartTimer) {
      clearTimeout(this.hostMetricsRestartTimer);
      this.hostMetricsRestartTimer = undefined;
    }
    const config = this.deps.getConfig();
    let proc: MonitorProcess;
    try {
      proc = spawn(config.binaryPath, ["api", "host-metrics", "--interval", "1"], {
        cwd: this.deps.workspaceRoot,
        shell: false,
        stdio: ["pipe", "pipe", "pipe"],
      });
    } catch (error) {
      this.deps.outputChannel.appendLine(`[host-metrics] プロセスの起動に失敗しました: ${String(error)}`);
      return;
    }

    // stdin は EOF が終了指示なので、こちらからは何も書かず開いたまま保持する(monitor と同じ)。
    proc.stdin.on("error", () => undefined);

    this.stoppingHostMetrics = false;
    this.hostMetricsProcess = proc;
    this.hostMetricsStartedAt = Date.now();

    const stdoutParser = new NdjsonParser(
      (value) => {
        if (!isHostMetricsEvent(value)) {
          this.deps.outputChannel.appendLine(`[host-metrics] 未知の形式の行を無視しました: ${JSON.stringify(value)}`);
          return;
        }
        this.deps.post({
          type: "hostMetrics",
          cpu: value.cpu,
          gpu: value.gpu,
          ane: value.ane,
          aneWatts: value.aneWatts,
          memUsedBytes: value.memUsedBytes,
          memTotalBytes: value.memTotalBytes,
        });
      },
      (line) => this.deps.outputChannel.appendLine(`[host-metrics stdout] ${line}`),
    );
    const stderrParser = new NdjsonParser(
      (value) => this.deps.outputChannel.appendLine(`[host-metrics stderr] ${JSON.stringify(value)}`),
      (line) => this.deps.outputChannel.appendLine(`[host-metrics stderr] ${line}`),
    );

    proc.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => stderrParser.push(chunk));

    proc.on("error", (error) => {
      this.deps.outputChannel.appendLine(`[host-metrics] プロセスでエラーが発生しました: ${error.message}`);
    });

    proc.on("close", () => {
      stdoutParser.end();
      stderrParser.end();
      if (this.hostMetricsProcess === proc) {
        this.hostMetricsProcess = undefined;
      }
      // 意図した停止(dispose/再起動)かどうかはフラグだけで判定する(monitor と同じ理由)。
      const selfInitiated = this.stoppingHostMetrics;
      this.stoppingHostMetrics = false;
      if (selfInitiated) {
        return;
      }
      this.scheduleHostMetricsRestart();
    });
  }

  /**
   * host-metrics プロセスの予期しない終了を受けて、再起動するか諦めるかを決める(startHostMetricsProcess
   * の close ハンドラから呼ばれる)。起動後10秒未満での異常終了が3回連続したら諦めて outputChannel に
   * 1回だけログし、以後 hostMetricsGaveUp が true の間は再起動をスケジュールしない(旧バイナリに
   * host-metrics サブコマンドが無い環境で無限に再起動ループしないための安全弁)。10秒以上動いてからの
   * 終了は正常運転とみなして連続回数をリセットする。
   */
  private scheduleHostMetricsRestart(): void {
    const elapsedMs = Date.now() - (this.hostMetricsStartedAt ?? Date.now());
    if (elapsedMs < 10000) {
      this.hostMetricsFailureStreak += 1;
    } else {
      this.hostMetricsFailureStreak = 0;
    }
    if (this.hostMetricsFailureStreak >= 3) {
      if (!this.hostMetricsGaveUp) {
        this.hostMetricsGaveUp = true;
        this.deps.outputChannel.appendLine(
          "[host-metrics] 起動直後の異常終了が続いたため自動再起動を停止しました。" +
            "バイナリが `api host-metrics` に対応しているか確認してください" +
            "(対応後は「モニター再起動」ボタンで復帰できます)。",
        );
      }
      return;
    }
    this.hostMetricsRestartTimer = setTimeout(() => {
      this.hostMetricsRestartTimer = undefined;
      // 5秒待つ間にパネルが閉じられていたら何もしない。
      if (this.deps.isPanelActive()) {
        this.startHostMetricsProcess();
      }
    }, 5000);
  }

  /** 実行中の host-metrics プロセスがあれば SIGTERM(2秒後 SIGKILL)で止める(stopMonitorProcess と同じ方針)。 */
  stopHostMetricsProcess(): void {
    if (this.hostMetricsRestartTimer) {
      clearTimeout(this.hostMetricsRestartTimer);
      this.hostMetricsRestartTimer = undefined;
    }
    const proc = this.hostMetricsProcess;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      return;
    }
    this.stoppingHostMetrics = true;
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
   */
  private restartHostMetricsProcess(): void {
    if (this.hostMetricsRestartPending) {
      return;
    }
    this.hostMetricsRestartPending = true;
    const proc = this.hostMetricsProcess;
    this.stopHostMetricsProcess();
    if (!proc) {
      this.hostMetricsRestartPending = false;
      this.startHostMetricsProcess();
      return;
    }
    proc.once("close", () => {
      this.hostMetricsRestartPending = false;
      this.startHostMetricsProcess();
    });
  }

  /**
   * モニタープロセスの stdin に pause/resume の制御コマンドを書き込む(NDJSON 1行)。
   * モニターが未起動・終了済みのときは黙ってスキップする(エラーにしない)。書き込み自体が
   * 失敗した場合も握りつぶし、呼び出し元のジョブ実行は継続させる(stdin の "error" ハンドラは
   * startMonitorProcess() 側で既に no-op 登録済み)。monitorDeviceOps.ts の MonitorDeviceOps
   * からは直接呼ばず、MonitorPanelDeps.writeMonitorControl 経由で呼ばれる
   * (サブコントローラ間の直接参照禁止のため monitorPanel.ts が仲介する)。
   */
  writeMonitorControl(cmd: MonitorControlCommand): void {
    const proc = this.monitorProcess;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      return;
    }
    try {
      proc.stdin.write(monitorControlLine(cmd));
    } catch {
      // 書き込み失敗は無視する(ジョブ自体は続行する)。
    }
  }
}
