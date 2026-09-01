// monitorDashboardController.ts
// デバイスモニターパネルの「ダッシュボード」タブ(旧 dashboardPanel.ts)向けサブコントローラ。
// `fleetest api results` / `results-run` をワンショット spawn して webview へ配る。
// monitorPanel.ts から MonitorDashboardControllerDeps 経由でのみ連携する(他のサブコントローラを
// 直接参照しない。monitorPanel.ts 冒頭コメントの分割方針と同じ)。
//
// - データは `fleetest api results --project <名> --since 90d --min-runs 3` を1発叩いて得る
//   1行 JSON(dashboardModel.ts の ApiResultsPayload / Sources/fleetest/ApiResultsCommand.swift と同期)。
//   ビルドを伴わない読み取り専用コマンドなので cli.ts の FleetestCli(直列キュー)には乗せず
//   oneShotCli.ts の runOneShot() で単発 spawn する。
// - 更新タイミング: モニターパネルを開いた時・webview の「更新」ボタン(refresh)・
//   RunEventBus の runEnded(GUI 実行完了。dry-run は結果 DB に記録されないため対象外)・
//   fleetest.project 設定変更(Select Project)。いずれも monitorPanel.ts から呼ばれる
//   (このファイルは RunEventBus/vscode.workspace.onDidChangeConfiguration を直接購読しない)。

import * as path from "node:path";
import * as vscode from "vscode";
import { type FleetestConfig, listProjectCandidates, resolveProjectName } from "./config";
import { t } from "./i18n";
import {
  type ApiResultsRunPayload,
  type DashboardFromWebviewMessage,
  type DashboardToWebviewMessage,
  isApiResultsPayload,
  isApiResultsRunPayload,
} from "./dashboardModel";
import { type OneShotResult, type PipeProcess, runOneShot } from "./oneShotCli";

const RESULTS_SINCE = "90d";
const RESULTS_MIN_RUNS = 3;

/** MonitorDashboardController が使う狭い窓口。 */
export interface MonitorDashboardControllerDeps {
  readonly workspaceRoot: string;
  getConfig(): FleetestConfig;
  readonly outputChannel: vscode.OutputChannel;
  post(message: DashboardToWebviewMessage): void;
  /** モニターパネルが開いているか。閉じている間は CLI を叩かない(旧 dashboardPanel.ts の
   * this.panel チェックと同じ役割)。 */
  isPanelActive(): boolean;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export class MonitorDashboardController {
  /** results/results-run のワンショット spawn(runOneShot 経由。同時に複数走りうる ——
   * refresh と runDetail/trend が重なるケース ——ので Set で持つ)。 */
  private readonly activeChildren = new Set<PipeProcess>();
  /** runStarted の isDryRun を runEnded まで持ち越す(healReviewPanel.ts の HealFixCollector と同じ理由:
   * dry-run 実行は結果 DB に記録されないため runEnded 時点で除外判定するのにここで覚えておく必要がある)。 */
  private lastRunWasDryRun = false;
  /** 同時に複数 refresh() が走らないようにする簡易ガード(更新ボタン連打・runEnded と手動更新の重なり対策)。 */
  private refreshing = false;
  /** 実行中に来た refresh 要求を1回ぶんだけ持ち越す。捨てると「読み込み中にプロジェクトを
   * 切り替えたのに、終わってみると旧プロジェクトの表示のまま」になる(2026-09-01 実害)。 */
  private refreshQueued = false;
  /** runDetail 版の同型ガード(行クリック連打対策)。 */
  private detailFetching = false;
  /** trend 版の同型ガード(scenarioID クリック連打対策)。 */
  private trendFetching = false;

  constructor(private readonly deps: MonitorDashboardControllerDeps) {}

  /** パネル dispose 時に results 系の実行中プロセス全部を止める(oneShotCli.ts 呼び出し側
   * 共通の SIGTERM→2秒後 SIGKILL。1本運用時と同じ挙動を各プロセスへ適用する)。 */
  dispose(): void {
    for (const proc of this.activeChildren) {
      if (proc.exitCode !== null || proc.signalCode !== null) {
        continue;
      }
      proc.kill("SIGTERM");
      setTimeout(() => {
        if (proc.exitCode === null && proc.signalCode === null) {
          proc.kill("SIGKILL");
        }
      }, 2000);
    }
  }

  /** RunEventBus の runStarted。monitorPanel.ts の handleBusMessage から呼ぶ。 */
  noteRunStarted(isDryRun: boolean): void {
    this.lastRunWasDryRun = isDryRun;
  }

  /** RunEventBus の runEnded。monitorPanel.ts の handleBusMessage から呼ぶ。 */
  noteRunEnded(): void {
    if (!this.lastRunWasDryRun && this.deps.isPanelActive()) {
      void this.refresh();
    }
  }

  /** fleetest.project の設定変更(Select Project)への追従。monitorPanel.ts の
   * onDidChangeConfiguration 購読から呼ぶ。 */
  onProjectSettingChanged(): void {
    if (this.deps.isPanelActive()) {
      void this.refresh();
    }
  }

  /** webview からの "dashboard" 封筒の中身(検証済み)。monitorPanel.ts の handleWebviewMessage から呼ぶ。 */
  handleWebviewMessage(message: DashboardFromWebviewMessage): void {
    switch (message.type) {
      case "ready":
      case "refresh":
        void this.refresh();
        break;
      case "runDetail":
        void this.handleRunDetail(message.runID, message.runIDs);
        break;
      case "trend":
        void this.handleTrend(message.scenarioID);
        break;
      case "openReport":
        void this.handleOpenReport(message.path);
        break;
      case "selectProject":
        void this.handleSelectProject(message.project);
        break;
    }
  }

  /** webview のドロップダウンからのプロジェクト切替。fleetest.selectProject コマンドと同じく
   * 設定 fleetest.project を書き換えるだけ —— refresh は monitorPanel.ts の
   * onDidChangeConfiguration 購読(onProjectSettingChanged 経由)が行う(2経路から refresh すると
   * 二重 spawn になる)。 */
  private async handleSelectProject(project: string): Promise<void> {
    if (!listProjectCandidates(this.deps.workspaceRoot).includes(project)) {
      return;
    }
    const resolution = resolveProjectName(this.deps.workspaceRoot, this.deps.getConfig());
    if (resolution.kind === "resolved" && resolution.project === project) {
      return;
    }
    await vscode.workspace
      .getConfiguration("fleetest")
      .update("project", project, vscode.ConfigurationTarget.Workspace);
  }

  /** runOneShot の子プロセスを activeChildren へ登録し、完了後に取り除く共通ラッパ。 */
  private async runOneShotTracked(args: string[]): Promise<OneShotResult> {
    const config = this.deps.getConfig();
    let proc: PipeProcess | undefined;
    try {
      return await runOneShot(config.binaryPath, this.deps.workspaceRoot, args, this.deps.outputChannel, (p) => {
        proc = p;
        this.activeChildren.add(p);
      });
    } finally {
      if (proc) {
        this.activeChildren.delete(proc);
      }
    }
  }

  private async refresh(): Promise<void> {
    if (this.refreshing) {
      this.refreshQueued = true;
      return;
    }
    this.refreshing = true;
    this.deps.post({ type: "loading" });
    try {
      const config = this.deps.getConfig();
      const resolution = resolveProjectName(this.deps.workspaceRoot, config);
      // 候補は毎回送る(未解決でもドロップダウンからの選択で復帰できるように)
      this.deps.post({
        type: "projects",
        projects: listProjectCandidates(this.deps.workspaceRoot),
        current: resolution.kind === "resolved" ? resolution.project : "",
      });
      if (resolution.kind !== "resolved") {
        this.deps.post({
          type: "error",
          message: t("exploreHeal.common.projectUnresolved"),
        });
        return;
      }
      const args = [
        "api",
        "results",
        "--project",
        resolution.project,
        "--since",
        RESULTS_SINCE,
        "--min-runs",
        String(RESULTS_MIN_RUNS),
      ];
      const result = await this.runOneShotTracked(args);
      if (!isApiResultsPayload(result.json)) {
        const detail = result.stderrTail.length > 0 ? result.stderrTail : `exit code: ${String(result.exitCode)}`;
        this.deps.post({
          type: "error",
          message: t("exploreHeal.dashboard.fetchFailedDetail", { detail }),
        });
        return;
      }
      this.deps.post({ type: "data", payload: result.json });
    } catch (error) {
      this.deps.post({
        type: "error",
        message: t("exploreHeal.dashboard.fetchFailedError", { error: errorMessage(error) }),
      });
    } finally {
      this.refreshing = false;
      if (this.refreshQueued) {
        this.refreshQueued = false;
        void this.refresh();
      }
    }
  }

  /** runIDs = 同じ実行(runGroup)の構成 run 全部。フリート実行は全構成 run の詳細を集めて返す。 */
  private async handleRunDetail(runID: string, runIDs?: readonly string[]): Promise<void> {
    if (this.detailFetching) {
      return;
    }
    this.detailFetching = true;
    try {
      const config = this.deps.getConfig();
      const resolution = resolveProjectName(this.deps.workspaceRoot, config);
      if (resolution.kind !== "resolved") {
        this.deps.post({ type: "runDetailError", runID, message: t("exploreHeal.common.projectUnresolved") });
        return;
      }
      const ids = runIDs && runIDs.length > 0 ? runIDs : [runID];
      const payloads: ApiResultsRunPayload[] = [];
      for (const id of ids) {
        const args = ["api", "results-run", "--project", resolution.project, "--run-id", id];
        const result = await this.runOneShotTracked(args);
        if (!isApiResultsRunPayload(result.json)) {
          const detail = result.stderrTail.length > 0 ? result.stderrTail : `exit code: ${String(result.exitCode)}`;
          this.deps.post({
            type: "runDetailError",
            runID,
            message: t("exploreHeal.dashboard.runDetailFetchFailed", { detail }),
          });
          return;
        }
        payloads.push(result.json);
      }
      this.deps.post({ type: "runDetail", payloads });
    } catch (error) {
      this.deps.post({
        type: "runDetailError",
        runID,
        message: t("exploreHeal.dashboard.fetchFailedError", { error: errorMessage(error) }),
      });
    } finally {
      this.detailFetching = false;
    }
  }

  private async handleTrend(scenarioID: string): Promise<void> {
    if (this.trendFetching) {
      return;
    }
    this.trendFetching = true;
    try {
      const config = this.deps.getConfig();
      const resolution = resolveProjectName(this.deps.workspaceRoot, config);
      if (resolution.kind !== "resolved") {
        this.deps.post({ type: "trendError", scenarioID, message: t("exploreHeal.common.projectUnresolved") });
        return;
      }
      const args = [
        "api",
        "results",
        "--project",
        resolution.project,
        "--since",
        RESULTS_SINCE,
        "--min-runs",
        String(RESULTS_MIN_RUNS),
        "--scenario",
        scenarioID,
      ];
      const result = await this.runOneShotTracked(args);
      if (!isApiResultsPayload(result.json)) {
        const detail = result.stderrTail.length > 0 ? result.stderrTail : `exit code: ${String(result.exitCode)}`;
        this.deps.post({
          type: "trendError",
          scenarioID,
          message: t("exploreHeal.dashboard.trendFetchFailed", { detail }),
        });
        return;
      }
      this.deps.post({ type: "trend", scenarioID, records: result.json.trend ?? [] });
    } catch (error) {
      this.deps.post({
        type: "trendError",
        scenarioID,
        message: t("exploreHeal.dashboard.fetchFailedError", { error: errorMessage(error) }),
      });
    } finally {
      this.trendFetching = false;
    }
  }

  /** webview 由来の相対パスを workspaceRoot に対して解決し、配下かつ .md であることを検証してから
   * 開く(webview のクリックはユーザー由来だが値そのものは信頼しない)。 */
  private async handleOpenReport(rawPath: string): Promise<void> {
    const resolved = path.resolve(
      path.isAbsolute(rawPath) ? rawPath : path.join(this.deps.workspaceRoot, rawPath),
    );
    const root = path.resolve(this.deps.workspaceRoot);
    const withinRoot = resolved === root || resolved.startsWith(root + path.sep);
    if (!withinRoot || path.extname(resolved) !== ".md") {
      return;
    }
    const uri = vscode.Uri.file(resolved);
    try {
      await vscode.workspace.fs.stat(uri);
    } catch {
      void vscode.window.showWarningMessage(t("exploreHeal.dashboard.reportNotFound"));
      return;
    }
    const doc = await vscode.workspace.openTextDocument(uri);
    await vscode.window.showTextDocument(doc);
  }
}
