// monitorExploreController.ts
// デバイスモニターパネル(monitorPanel.ts)の「FM探索」タブ担当サブコントローラ。
//
// - デバイス一覧取得(`ftester api list-devices`)は monitorLiveController.ts と同じ理由で
//   oneShotCli.ts の runOneShot() で専用 spawn する(ビルドを伴わないため cli.ts のキューと競合しない)。
// - `ftester api explore` は内部で swift build(生成コードのビルド検証)を行うため、cli.ts の
//   FtesterCli(直列実行キュー)経由で実行する(oneShotCli.ts の専用 spawn ではなく)。SPM の
//   ビルドロックが `ftester api run` 等の他の CLI 呼び出しと衝突しないようにするため。
//   このキューは live 系(list-devices)とは別ルートだが、run/heal 系の実行とは共有するため
//   FM探索の実行中は他のテスト実行が待たされる(意図した挙動)。

import * as vscode from "vscode";
import { type FtesterCli } from "./cli";
import { resolveProjectName } from "./config";
import { t } from "./i18n";
import {
  buildFinishedNotification,
  formatExploreLogLine,
  isExploreEvent,
  parseMaxSteps,
  validateBundleIdInput,
  validateGoalInput,
  validateMaxStepsInput,
  type ExploreErrorEvent,
  type ExploreFinishedEvent,
  type ExploreFromWebviewMessage,
  type ExploreResultView,
  type ExploreToWebviewMessage,
} from "./exploreModel";
import { buildDeviceArgs, devicesToOptions, type LiveDeviceOption, parseListDevicesResult } from "./liveModel";
import type { MonitorPanelDeps } from "./monitorPanel";
import { type OneShotResult, type PipeProcess, runOneShot } from "./oneShotCli";

const WORKSPACE_STATE_BUNDLE_ID_KEY = "ftester.explore.lastBundleId";
/** ログ行の上限(超えたら先頭から捨てる。無制限に溜めるとメモリ・postMessage量が肥大化するため)。 */
const MAX_LOG_LINES = 500;

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export class MonitorExploreController implements vscode.Disposable {
  private devices: LiveDeviceOption[] = [];
  private selectedDeviceId: string | undefined;
  private running = false;
  private logLines: string[] = [];
  private lastResult: ExploreResultView | null = null;
  private lastGeneratedFile: string | undefined;
  /** list-devices のワンショット spawn(専用。runOneShot 経由)。 */
  private activeChild: PipeProcess | undefined;

  constructor(
    private readonly deps: MonitorPanelDeps,
    private readonly cli: FtesterCli,
    private readonly workspaceState: vscode.Memento,
    private readonly onScenarioGenerated: () => void,
  ) {}

  dispose(): void {
    if (this.running) {
      this.cli.cancelCurrent();
    }
    this.killActiveChild();
  }

  private post(message: ExploreToWebviewMessage): void {
    this.deps.post({ type: "explore", message });
  }

  /** パネル close 時・dispose 時に list-devices の実行中プロセスを止める(cli.ts と同じ SIGTERM→2秒後 SIGKILL)。 */
  private killActiveChild(): void {
    const proc = this.activeChild;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      return;
    }
    proc.kill("SIGTERM");
    setTimeout(() => {
      if (proc.exitCode === null && proc.signalCode === null) {
        proc.kill("SIGKILL");
      }
    }, 2000);
  }

  private async runOneShotList(args: string[]): Promise<OneShotResult> {
    const config = this.deps.getConfig();
    try {
      return await runOneShot(config.binaryPath, this.deps.workspaceRoot, args, this.deps.outputChannel, (proc) => {
        this.activeChild = proc;
      });
    } finally {
      this.activeChild = undefined;
    }
  }

  /** webview の"ready"再送時に呼ばれる。冪等(全状態を上書き描画するだけ)。 */
  sendInitialState(): void {
    const lastBundleId = this.workspaceState.get<string>(WORKSPACE_STATE_BUNDLE_ID_KEY, "");
    this.post({
      type: "hydrate",
      running: this.running,
      logLines: this.logLines,
      lastBundleId,
      result: this.lastResult,
      devices: this.devices,
      selectedId: this.selectedDeviceId,
    });
  }

  // ---- デバイス一覧 ---------------------------------------------------------------

  private async refreshDevices(): Promise<void> {
    const config = this.deps.getConfig();
    const resolution = resolveProjectName(this.deps.workspaceRoot, config);
    if (resolution.kind !== "resolved") {
      this.applyDevices([], t("exploreHeal.common.projectUnresolved"));
      return;
    }
    try {
      // --profile が無いと machines/ が複数のとき「マシン名が未登録」で落ちる(monitorDeviceOps.ts と同経路)
      const listArgs = ["api", "list-devices", "--project", resolution.project];
      if (config.profile) {
        listArgs.push("--profile", config.profile);
      }
      const result = await this.runOneShotList(listArgs);
      const parsed = parseListDevicesResult(result.json);
      if (!parsed) {
        const detail = result.stderrTail.length > 0 ? result.stderrTail : `exit code: ${String(result.exitCode)}`;
        this.applyDevices(
          [],
          t("exploreHeal.explore.deviceListFailedProfile", { detail }),
        );
        return;
      }
      this.applyDevices(devicesToOptions(parsed.devices), undefined);
    } catch (error) {
      this.applyDevices([], t("exploreHeal.explore.deviceListFailed", { error: errorMessage(error) }));
    }
  }

  /** 直前の選択が新しい一覧にも存在すれば維持し、無ければ先頭を選択する(接続済みデバイスが
   * 無ければ空配列のまま = 探索は実行不可。live のようなフォールバックデバイスは使わない)。 */
  private applyDevices(options: LiveDeviceOption[], bannerMessage: string | undefined): void {
    this.devices = options;
    const stillExists = this.selectedDeviceId !== undefined && options.some((o) => o.id === this.selectedDeviceId);
    this.selectedDeviceId = stillExists ? this.selectedDeviceId : options[0]?.id;
    this.post({ type: "devices", devices: options, selectedId: this.selectedDeviceId });
    this.post({ type: "banner", message: bannerMessage ?? null });
  }

  // ---- 探索の開始・キャンセル・ファイルを開く ----------------------------------------------

  private appendLog(line: string): void {
    this.logLines.push(line);
    if (this.logLines.length > MAX_LOG_LINES) {
      this.logLines.splice(0, this.logLines.length - MAX_LOG_LINES);
    }
    this.post({ type: "log", line });
  }

  private async start(bundleIdRaw: string, goalRaw: string, maxStepsRaw: string): Promise<void> {
    if (this.running) {
      return;
    }
    const bundleId = bundleIdRaw.trim();
    const goal = goalRaw.trim();
    const formErrorMessage =
      validateBundleIdInput(bundleId) ?? validateGoalInput(goal) ?? validateMaxStepsInput(maxStepsRaw);
    if (formErrorMessage) {
      this.post({ type: "formError", message: formErrorMessage });
      return;
    }
    const device = this.devices.find((d) => d.id === this.selectedDeviceId);
    if (!device) {
      this.post({ type: "formError", message: t("exploreHeal.explore.selectDevicePrompt") });
      return;
    }
    const config = this.deps.getConfig();
    const resolution = resolveProjectName(this.deps.workspaceRoot, config);
    if (resolution.kind !== "resolved") {
      this.post({
        type: "formError",
        message: t("exploreHeal.common.projectUnresolved"),
      });
      return;
    }

    this.post({ type: "formError", message: null });
    void this.workspaceState.update(WORKSPACE_STATE_BUNDLE_ID_KEY, bundleId);
    this.logLines = [];
    this.lastResult = null;
    this.running = true;
    this.post({ type: "running", running: true });

    const args = [
      "api",
      "explore",
      "--project",
      resolution.project,
      "--bundle",
      bundleId,
      "--goal",
      goal,
      "--max-steps",
      String(parseMaxSteps(maxStepsRaw)),
      ...buildDeviceArgs({ platform: device.platform, port: device.port, serial: device.serial, udid: device.udid }),
    ];

    let finishedEvent: ExploreFinishedEvent | undefined;
    let errorEvent: ExploreErrorEvent | undefined;
    try {
      const result = await this.cli.invoke(config.binaryPath, this.deps.workspaceRoot, {
        args,
        onNdjsonValue: (value) => {
          if (!isExploreEvent(value)) {
            return;
          }
          this.appendLog(formatExploreLogLine(value));
          if (value.kind === "exploreFinished") {
            finishedEvent = value;
          } else if (value.kind === "error") {
            errorEvent = value;
          }
        },
        onLog: (line, stream) => this.deps.outputChannel.appendLine(`[explore ${stream}] ${line}`),
      });
      if (finishedEvent) {
        const notification = buildFinishedNotification(finishedEvent);
        this.lastGeneratedFile = finishedEvent.file ?? undefined;
        this.lastResult = {
          message: notification.message,
          severity: notification.severity,
          hasFile: finishedEvent.file !== null,
        };
        this.onScenarioGenerated();
      } else if (errorEvent) {
        this.lastResult = { message: errorEvent.message, severity: "error", hasFile: false };
      } else if (!result.cancelled) {
        this.lastResult = {
          message: t("exploreHeal.explore.processCrashed", { exitCode: String(result.exitCode) }),
          severity: "error",
          hasFile: false,
        };
      } else {
        this.appendLog(t("exploreHeal.explore.log.cancelled"));
      }
    } catch (error) {
      const message = errorMessage(error);
      this.deps.outputChannel.appendLine(`[explore] ${message}`);
      this.lastResult = { message, severity: "error", hasFile: false };
    } finally {
      this.running = false;
      this.post({ type: "running", running: false });
      if (this.lastResult) {
        this.post({ type: "result", ...this.lastResult });
      }
    }
  }

  private openFile(): void {
    if (!this.lastGeneratedFile) {
      return;
    }
    this.deps.openGeneratedDocument(this.lastGeneratedFile);
  }

  // ---- webview からのメッセージ -----------------------------------------------------
  // isExploreFromWebviewMessage による型ガードは呼び出し元(monitorPanel.ts の isExploreWebviewEnvelope)
  // 側で済んでいるためここでは行わない。

  handleWebviewMessage(message: ExploreFromWebviewMessage): void {
    switch (message.type) {
      case "refreshDevices":
        void this.refreshDevices();
        break;
      case "selectDevice":
        if (this.devices.some((device) => device.id === message.id)) {
          this.selectedDeviceId = message.id;
        }
        break;
      case "start":
        void this.start(message.bundleId, message.goal, message.maxSteps);
        break;
      case "cancel":
        if (this.running) {
          this.cli.cancelCurrent();
        }
        break;
      case "openFile":
        void this.openFile();
        break;
    }
  }
}
