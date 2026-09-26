// monitorDashboardController.ts
// デバイスモニターパネルの「ダッシュボード」タブ向けサブコントローラ。
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
import { type FleetestConfig, listProjectCandidates, listProjectDeviceCatalog, resolveProjectName } from "./config";
import { t } from "./i18n";
import {
  type ApiResultsPayload,
  type ApiResultsRunPayload,
  type DashboardFromWebviewMessage,
  type DashboardToWebviewMessage,
  type SinceOption,
  isApiResultsPayload,
  isApiResultsRunPayload,
} from "./dashboardModel";
import { type OneShotResult, type PipeProcess, runOneShot } from "./oneShotCli";
import { selectWorkspaceProject } from "./projectSelection";

const RESULTS_MIN_RUNS = 3;

/** webview 由来の相対パスを workspaceRoot に対して解決し、配下かつ拡張子が一致するか検証する
 * (webview のクリックはユーザー由来だが値そのものは信頼しない)。合格なら絶対パス、
 * 不合格なら null。handleOpenReport(.md)/handleOpenSource(.swift)で共有する純粋関数
 * (vscode 非依存なので単体テストで直接呼べる)。 */
export function resolveWorkspaceRelativeFile(workspaceRoot: string, rawPath: string, requiredExt: string): string | null {
  const resolved = path.resolve(path.isAbsolute(rawPath) ? rawPath : path.join(workspaceRoot, rawPath));
  const root = path.resolve(workspaceRoot);
  const withinRoot = resolved === root || resolved.startsWith(root + path.sep);
  if (!withinRoot || path.extname(resolved) !== requiredExt) {
    return null;
  }
  return resolved;
}

/** MonitorDashboardController が使う狭い窓口。 */
export interface MonitorDashboardControllerDeps {
  readonly workspaceRoot: string;
  getConfig(): FleetestConfig;
  readonly outputChannel: vscode.OutputChannel;
  post(message: DashboardToWebviewMessage): void;
  /** モニターパネルが開いているか。閉じている間は CLI を叩かない。 */
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
   * 切り替えたのに、終わってみると旧プロジェクトの表示のまま」になる(実害)。 */
  private refreshQueued = false;
  /** runDetail 版の同型ガード(行クリック連打対策)。 */
  private detailFetching = false;
  /** trend 版の同型ガード(scenarioID クリック連打対策)。 */
  private trendFetching = false;
  private headlineDiffFetching = false;
  private headlineDiffQueued: { latestRunIDs: readonly string[]; previousRunIDs: readonly string[] } | null = null;
  /** (project, since) ごとの直近ペイロード(メモリのみ)。パネルを閉じて開き直すと
   * webview の DOM は失われるが、この Map は MonitorDashboardController の生存中は残るので、
   * refresh() の冒頭で即座に再送できる(再取得の 15〜20 秒を待たせない)。 */
  private readonly resultsCache = new Map<string, ApiResultsPayload>();
  /** 集計期間。webview 再読込(言語切替)で選択が既定へ戻るのを防ぐため、'projects' 送信時に
   * 毎回載せて webview に合わせさせる。既定は従来と同じ 90d。 */
  private since: SinceOption = "90d";

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
      case "openSource":
        void this.handleOpenSource(message.file, message.line);
        break;
      case "selectProject":
        void this.handleSelectProject(message.project);
        break;
      case "headlineDiff":
        void this.handleHeadlineDiff(message.latestRunIDs, message.previousRunIDs);
        break;
      case "setSince":
        this.since = message.since;
        void this.refresh();
        break;
    }
  }

  private cacheKey(project: string): string {
    return project + "\u0000" + this.since;
  }

  /** webview のドロップダウンからのプロジェクト切替(refresh は onProjectSettingChanged 経由)。 */
  private async handleSelectProject(project: string): Promise<void> {
    await selectWorkspaceProject(this.deps.workspaceRoot, this.deps.getConfig(), project);
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
      // 候補は毎回送る(未解決でもドロップダウンからの選択で復帰できるように)。since も毎回載せる
      // (webview 再読込で選択が既定へ戻るのを防ぐ)。
      this.deps.post({
        type: "projects",
        projects: listProjectCandidates(this.deps.workspaceRoot),
        current: resolution.kind === "resolved" ? resolution.project : "",
        since: this.since,
      });
      if (resolution.kind !== "resolved") {
        this.deps.post({
          type: "error",
          message: t("exploreHeal.common.projectUnresolved"),
        });
        return;
      }
      // デバイスの健全性が結合鍵(モニターの台 → 実行プロファイルの name)を揃えるための和集合。
      // 'data' より先に送る(結合し直しは deviceHealth.js 側で持ち越すが、揃った状態で最初の
      // 描画をさせたい)。
      this.deps.post({
        type: "deviceCatalog",
        devices: listProjectDeviceCatalog(this.deps.workspaceRoot, resolution.project).map((device) => ({
          platform: device.platform,
          machine: device.machine,
          name: device.name,
          avd: device.avd,
          udid: device.udid,
        })),
      });
      // 直近ペイロードがあれば取得完了を待たず即座に再送する(パネルを開き直した webview は
      // DOM を持たないので、この再送が無いと結果が出るまで毎回 15〜20 秒空白になる)。
      const cached = this.resultsCache.get(this.cacheKey(resolution.project));
      if (cached) {
        this.deps.post({ type: "data", payload: cached });
      }
      const args = [
        "api",
        "results",
        "--project",
        resolution.project,
        "--since",
        this.since,
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
      this.resultsCache.set(this.cacheKey(resolution.project), result.json);
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
        this.since,
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
    const resolved = resolveWorkspaceRelativeFile(this.deps.workspaceRoot, rawPath, ".md");
    if (!resolved) {
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

  /** 失敗ステップの file:line クリック。workspaceRoot 配下・.swift・実在を検証してから開き、
   * line(1始まり)へ移動する。handleOpenReport と同じ流儀(検証は resolveWorkspaceRelativeFile 共有)。 */
  private async handleOpenSource(rawFile: string, line: number): Promise<void> {
    const resolved = resolveWorkspaceRelativeFile(this.deps.workspaceRoot, rawFile, ".swift");
    if (!resolved) {
      return;
    }
    const uri = vscode.Uri.file(resolved);
    try {
      await vscode.workspace.fs.stat(uri);
    } catch {
      void vscode.window.showWarningMessage(t("exploreHeal.dashboard.sourceNotFound"));
      return;
    }
    const doc = await vscode.workspace.openTextDocument(uri);
    const editor = await vscode.window.showTextDocument(doc);
    const position = new vscode.Position(Math.max(0, line - 1), 0);
    editor.selection = new vscode.Selection(position, position);
    editor.revealRange(new vscode.Range(position, position), vscode.TextEditorRevealType.InCenter);
  }

  /** 前回比。latest/previous それぞれの構成 run 全部の results-run 応答を集めて生のまま返す
   * (突き合わせ判定は webview 側の純粋関数 headlineDiffLogic.js が持つ。判定を1箇所にする方針)。 */
  private async handleHeadlineDiff(latestRunIDs: readonly string[], previousRunIDs: readonly string[]): Promise<void> {
    if (this.headlineDiffFetching) {
      // 捨てない: 控えの即時再送 → 取り直し の2回の data で依頼が続けて来る。後の依頼を捨てると
      // 先の応答は webview に古いと捨てられ、前回比が出ないまま残る。最新の1件だけ持ち越す
      this.headlineDiffQueued = { latestRunIDs, previousRunIDs };
      return;
    }
    this.headlineDiffFetching = true;
    try {
      const config = this.deps.getConfig();
      const resolution = resolveProjectName(this.deps.workspaceRoot, config);
      if (resolution.kind !== "resolved") {
        this.deps.post({ type: "headlineDiffError" });
        return;
      }
      const fetchAll = async (ids: readonly string[]): Promise<ApiResultsRunPayload[] | null> => {
        const payloads: ApiResultsRunPayload[] = [];
        for (const id of ids) {
          const args = ["api", "results-run", "--project", resolution.project, "--run-id", id];
          const result = await this.runOneShotTracked(args);
          if (!isApiResultsRunPayload(result.json)) {
            return null;
          }
          payloads.push(result.json);
        }
        return payloads;
      };
      const latest = await fetchAll(latestRunIDs);
      const previous = latest ? await fetchAll(previousRunIDs) : null;
      if (!latest || !previous) {
        this.deps.post({ type: "headlineDiffError" });
        return;
      }
      this.deps.post({ type: "headlineDiff", latest, previous });
    } catch {
      this.deps.post({ type: "headlineDiffError" });
    } finally {
      this.headlineDiffFetching = false;
      const queued = this.headlineDiffQueued;
      this.headlineDiffQueued = null;
      if (queued) {
        void this.handleHeadlineDiff(queued.latestRunIDs, queued.previousRunIDs);
      }
    }
  }
}
