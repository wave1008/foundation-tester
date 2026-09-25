// liveAppActions.ts
// ライブ操作タブ(monitorLiveController.ts の MonitorLiveController)からアプリ操作(インストール・
// 起動)とレコーディング(操作→FlowStep記録→gen-scenario)を切り出したサブコントローラ。必要な
// コールバックだけを束ねた狭い deps を経由してコントローラ本体を呼ぶ(monitorPanel.ts の
// MonitorPanelDeps と同じ分割規約)。

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type * as vscode from "vscode";
import type { FleetestCli } from "./cli";
import {
  type FleetestConfig,
  listAppProfileNames,
  readAppProfileDetail,
  readAppProfileTarget,
  resolveProjectName,
} from "./config";
import { t } from "./i18n";
import {
  type LiveDeviceRef,
  type LiveServeCommand,
  type LiveToWebviewMessage,
  operationBelongsToApp,
  parseGenScenarioEvent,
  type RecordedStep,
} from "./liveModel";

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** MonitorLiveController からの窓口(必要なものだけを束ねた狭い形)。 */
export interface LiveAppActionsDeps {
  readonly workspaceRoot: string;
  getConfig(): FleetestConfig;
  readonly outputChannel: vscode.OutputChannel;
  post(message: LiveToWebviewMessage): void;
  currentDeviceRef(): LiveDeviceRef | undefined;
  postActionError(message: string): void;
  runAction(
    command: LiveServeCommand,
    recordStep?: RecordedStep,
    options?: { readonly silentObservation?: boolean; readonly logLabel?: string },
  ): Promise<boolean>;
  openGeneratedDocument(filePath: string): void;
}

export class LiveAppActions {
  // ---- レコーディング(操作→FlowStep記録→gen-scenario) -----------------------------------
  private recording = false;
  /** startRecord の install→launch 実行中(recording=true になる前)の再入ガード。無いと開始待ち中の
   * 二度押しで2本目が走り、その finally が1本目の「処理中」recordStatus を消してしまう。 */
  private startingRecord = false;
  private recordedSteps: RecordedStep[] = [];
  private recordApp: { bundle: string; platform: string } | null = null;
  /** refreshAppProfiles の選択維持用(applyDevices の selectedDeviceId と同じ役割)。 */
  private selectedAppProfileId: string | undefined;
  /** generateScenario 実行中かどうか。コントローラの dispose 時に cli.ts の直列キューから
   * 自分のタスクを止めるか判定するのに使う(isGenerating 経由)。 */
  private generating = false;

  constructor(
    private readonly deps: LiveAppActionsDeps,
    private readonly cli: FleetestCli,
    private readonly refreshTestTree: () => void,
  ) {}

  private post(message: LiveToWebviewMessage): void {
    this.deps.post(message);
  }

  private postActionError(message: string): void {
    this.deps.postActionError(message);
  }

  private currentDeviceRef(): LiveDeviceRef | undefined {
    return this.deps.currentDeviceRef();
  }

  private runAction(
    command: LiveServeCommand,
    recordStep?: RecordedStep,
    options?: { readonly silentObservation?: boolean; readonly logLabel?: string },
  ): Promise<boolean> {
    return this.deps.runAction(command, recordStep, options);
  }

  /** コントローラの dispose() から、生成中の gen-scenario を時限 SIGKILL してよいか判定するのに使う。 */
  isGenerating(): boolean {
    return this.generating;
  }

  /** コントローラ本体の runAction(操作成功後)から呼ばれる。対象アプリの上での操作だけを記録する
   * (operationBelongsToApp の doc)。 */
  recordStep(step: RecordedStep | undefined, appName: string | undefined): void {
    if (this.recording && step && operationBelongsToApp(appName, this.recordApp?.bundle)) {
      this.recordedSteps.push(step);
    }
  }

  /** webview の selectAppProfile ハンドラから。 */
  selectAppProfile(appProfile: string): void {
    this.selectedAppProfileId = appProfile;
    this.postAppProfileDetail();
  }

  // ---- レコーディング ---------------------------------------------------------------

  /** 直前の選択が新しい一覧にも存在すれば維持し、無ければ先頭を選択する(applyDevices と同じ方針)。 */
  refreshAppProfiles(): void {
    const config = this.deps.getConfig();
    const resolution = resolveProjectName(this.deps.workspaceRoot, config);
    if (resolution.kind !== "resolved") {
      this.selectedAppProfileId = undefined;
      this.post({ type: "appProfiles", profiles: [], selectedId: undefined });
      return;
    }
    const profiles = listAppProfileNames(this.deps.workspaceRoot, resolution.project);
    const stillExists = this.selectedAppProfileId !== undefined && profiles.includes(this.selectedAppProfileId);
    this.selectedAppProfileId = stillExists ? this.selectedAppProfileId : profiles[0];
    this.post({ type: "appProfiles", profiles, selectedId: this.selectedAppProfileId });
    this.postAppProfileDetail();
  }

  /** 選択中アプリプロファイルの詳細(表示名/アプリID/パッケージパス)を現在のデバイス platform で
   * 解決して webview へ送る。詳細は platform 依存(bundle/appPath が OS 別)のため、デバイス変更・
   * プロファイル選択変更・一覧更新のたびに送り直す。未選択・プロジェクト未解決・デバイス未選択では
   * 空値を送る(webview 側で「—」表示・インストール不可になる)。 */
  postAppProfileDetail(): void {
    const id = this.selectedAppProfileId;
    if (!id) {
      return;
    }
    const resolution = resolveProjectName(this.deps.workspaceRoot, this.deps.getConfig());
    const device = this.currentDeviceRef();
    const detail =
      resolution.kind === "resolved" && device
        ? readAppProfileDetail(this.deps.workspaceRoot, resolution.project, id, device.platform)
        : null;
    this.post({
      type: "appProfileDetail",
      appProfile: id,
      appName: detail?.appName ?? null,
      bundle: detail?.bundle ?? null,
      appPath: detail?.appPath ?? null,
    });
  }

  /** 選択中プロファイルの appPath を現在のデバイス platform で解決してインストールする。
   * appPath 未設定(システムアプリ・ビルド無し等)や未解決はエラー表示して何もしない。 */
  async installApp(appProfile: string): Promise<void> {
    const device = this.currentDeviceRef();
    if (!device) {
      this.postActionError(t("live.noDeviceSelected"));
      return;
    }
    const resolution = resolveProjectName(this.deps.workspaceRoot, this.deps.getConfig());
    if (resolution.kind !== "resolved") {
      this.postActionError(t("live.projectUnresolved"));
      return;
    }
    const detail = readAppProfileDetail(this.deps.workspaceRoot, resolution.project, appProfile, device.platform);
    if (!detail?.appPath) {
      this.postActionError(t("live.installNoPath"));
      return;
    }
    this.post({ type: "busyOverlay", message: t("live.installing") });
    try {
      await this.runAction(
        { cmd: "install", path: detail.appPath },
        undefined,
        { silentObservation: true, logLabel: t("live.opLabel.install", { name: appProfile }) },
      );
    } finally {
      this.post({ type: "busyOverlay", message: null });
    }
  }

  /** 選択中プロファイルのアプリ(bundle)を現在のデバイス platform で解決して起動する
   * (記録は開始しない。startRecord と違い install はしない)。bundle 未解決はエラー表示のみ。 */
  async launchApp(appProfile: string): Promise<void> {
    const device = this.currentDeviceRef();
    if (!device) {
      this.postActionError(t("live.noDeviceSelected"));
      return;
    }
    const resolution = resolveProjectName(this.deps.workspaceRoot, this.deps.getConfig());
    if (resolution.kind !== "resolved") {
      this.postActionError(t("live.projectUnresolved"));
      return;
    }
    const detail = readAppProfileDetail(this.deps.workspaceRoot, resolution.project, appProfile, device.platform);
    if (!detail?.bundle) {
      this.postActionError(t("live.launchNoBundle"));
      return;
    }
    await this.runAction(
      { cmd: "launch", bundle: detail.bundle },
      undefined,
      { logLabel: t("live.opLabel.launch", { bundle: detail.bundle }) },
    );
  }

  /** アプリ起動(必要なら事前インストール)まで完了させてから記録状態に入る。起動失敗時は
   * 記録を開始しない(runAction が既に actionError を post 済み)。 */
  async startRecord(appProfile: string, autoInstall: boolean): Promise<void> {
    if (this.recording || this.startingRecord) {
      return;
    }
    const device = this.currentDeviceRef();
    if (!device) {
      this.postActionError(t("live.noDeviceSelected"));
      return;
    }
    const config = this.deps.getConfig();
    const resolution = resolveProjectName(this.deps.workspaceRoot, config);
    if (resolution.kind !== "resolved") {
      this.postActionError(t("live.projectUnresolved"));
      return;
    }
    const target = readAppProfileTarget(this.deps.workspaceRoot, resolution.project, appProfile, device.platform);
    if (!target) {
      this.postActionError(t("live.appProfileUnresolved"));
      return;
    }
    this.selectedAppProfileId = appProfile;
    // タップ直後〜アプリ起動完了(install→launch は数秒かかり得る)まで画面を薄暗くして「処理中」を出す。
    // finally で必ず消す(成功時はレコーディングUI、失敗時は runAction が post 済みの actionError が状態を示す)。
    this.startingRecord = true;
    this.post({ type: "busyOverlay", message: t("live.recordStarting") });
    try {
      if (autoInstall && target.appPath) {
        // 再インストールはアプリを終了させ、install 直後の観測は必ず「not running」で失敗する。
        // それを表示・中断に使わないよう silentObservation。画面はこの後の launch が出す。
        const installed = await this.runAction(
          { cmd: "install", path: target.appPath }, undefined, { silentObservation: true });
        if (!installed) {
          return;
        }
      }
      const launched = await this.runAction({ cmd: "launch", bundle: target.bundle });
      if (!launched) {
        return;
      }
      this.recording = true;
      this.recordedSteps = [];
      this.recordApp = { bundle: target.bundle, platform: device.platform };
      this.post({ type: "recording", active: true });
    } finally {
      this.startingRecord = false;
      this.post({ type: "busyOverlay", message: null });
    }
  }

  stopRecord(): void {
    this.recording = false;
    if (this.recordedSteps.length === 0) {
      this.post({ type: "recording", active: false });
      this.post({ type: "recordStatus", message: t("live.recordNoSteps"), file: null });
      return;
    }
    // 生成が終わるまでは「レコーディング終了」を非活性で見せる(active:false のまま generating:true)。
    // active:false→開始ボタンへの切り替えは generateScenario の完了時(generating:false)に行う。
    this.post({ type: "recording", active: false, generating: true });
    void this.generateScenario();
  }

  /** 記録済みステップを一時JSONに書き出し `fleetest api gen-scenario` を(cli.ts の直列キュー経由で)
   * 実行する。成功時は生成ファイルを開いてテストツリーを更新する。一時ファイルはベストエフォートで削除する。 */
  private async generateScenario(): Promise<void> {
    // stopRecord が generating:true を post 済み。成否・経路によらずここを抜けるときに
    // 「レコーディング終了(非活性)」→「レコーディング開始」へ戻す(外側 finally で一元化)。
    try {
      const app = this.recordApp;
      const config = this.deps.getConfig();
      const resolution = resolveProjectName(this.deps.workspaceRoot, config);
      if (!app || resolution.kind !== "resolved") {
        this.post({ type: "recordStatus", message: t("live.projectUnresolvedShort"), file: null });
        return;
      }

      const payload = { app: app.bundle, platform: app.platform, steps: this.recordedSteps };
      const tmpPath = path.join(os.tmpdir(), `fleetest-record-${Date.now()}-${process.pid}.json`);
      try {
        fs.writeFileSync(tmpPath, JSON.stringify(payload), "utf8");
      } catch (error) {
        this.post({
          type: "recordStatus",
          message: t("live.tempFileWriteFailed", { error: errorMessage(error) }),
          file: null,
        });
        return;
      }
      this.post({ type: "recordStatus", message: t("live.generatingCode"), file: null });

      let generatedFile: string | undefined;
      let errorMsg: string | undefined;
      this.generating = true;
      try {
        await this.cli.invoke(config.binaryPath, this.deps.workspaceRoot, {
          args: ["api", "gen-scenario", "--project", resolution.project, "--steps", tmpPath],
          onNdjsonValue: (value) => {
            const event = parseGenScenarioEvent(value);
            if (!event) {
              return;
            }
            if (event.event === "scenarioGenerated") {
              generatedFile = event.file;
            } else {
              errorMsg = event.message;
            }
          },
          onLog: (line, stream) => this.deps.outputChannel.appendLine(`[gen-scenario ${stream}] ${line}`),
        });
      } catch (error) {
        errorMsg = errorMessage(error);
      } finally {
        this.generating = false;
        try {
          fs.unlinkSync(tmpPath);
        } catch {
          // 生成完了後の一時ファイルなので削除失敗は無視してよい(ベストエフォート)。
        }
      }

      if (generatedFile) {
        // 生成成功は自動で開くファイルが示すので「生成しました」の文言は出さず、生成中表示だけ消す。
        this.post({ type: "recordStatus", message: "", file: generatedFile });
        this.deps.openGeneratedDocument(generatedFile);
        this.refreshTestTree();
      } else {
        this.post({ type: "recordStatus", message: errorMsg ?? t("live.codeGenFailed"), file: null });
      }
    } finally {
      this.post({ type: "recording", active: false, generating: false });
    }
  }
}
