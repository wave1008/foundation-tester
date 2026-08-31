// dashboardPanel.ts
// テスト実行結果ダッシュボードの WebviewPanel(コマンド `fleetest.showResultsDashboard`)。
// monitorPanel.ts/healReviewPanel.ts と同じシングルトンパターン(1拡張につきパネル1枚)。
//
// - データは `fleetest api results --project <名> --since 90d --min-runs 3` を1発叩いて得る
//   1行 JSON(dashboardModel.ts の ApiResultsPayload / Sources/fleetest/ApiResultsCommand.swift と同期)。
//   ビルドを伴わない読み取り専用コマンドなので cli.ts の FleetestCli(直列キュー)には乗せず
//   oneShotCli.ts の runOneShot() で単発 spawn する。
// - 更新タイミング: パネルを開いた時(show())・webview の「更新」ボタン(refresh)・
//   RunEventBus の runEnded(GUI 実行完了。dry-run は結果 DB に記録されないため対象外)。
// - webview 資産は src/webview/dashboard/{main.js,style.css}(esbuild が media/dashboard/ へ
//   バンドル)。テンプレートリテラル内蔵は禁止(CLAUDE.md 方針)。

import { randomBytes } from "node:crypto";
import * as path from "node:path";
import * as vscode from "vscode";
import { type FleetestConfig, listProjectCandidates, resolveProjectName } from "./config";
import { currentLocale, t } from "./i18n";
import {
  isApiResultsPayload,
  isApiResultsRunPayload,
  isDashboardFromWebviewMessage,
  type DashboardToWebviewMessage,
} from "./dashboardModel";
import { type OneShotResult, type PipeProcess, runOneShot } from "./oneShotCli";
import type { RunBusMessage, RunEventBus } from "./runEventBus";

const VIEW_TYPE = "fleetestResultsDashboard";
const RESULTS_SINCE = "90d";
const RESULTS_MIN_RUNS = 3;

/** DashboardPanelController が使う狭い窓口(将来サブコントローラへ分割する際も同じ形で注入する)。 */
export interface DashboardPanelDeps {
  readonly workspaceRoot: string;
  getConfig(): FleetestConfig;
  readonly outputChannel: vscode.OutputChannel;
  post(message: DashboardToWebviewMessage): void;
}

export function registerDashboardPanel(
  context: vscode.ExtensionContext,
  workspaceRoot: string,
  getConfig: () => FleetestConfig,
  outputChannel: vscode.OutputChannel,
  eventBus: RunEventBus,
): { relocalize(): void } {
  const controller = new DashboardPanelController(
    workspaceRoot,
    getConfig,
    outputChannel,
    eventBus,
    context.extensionUri,
  );
  context.subscriptions.push(
    controller,
    vscode.commands.registerCommand("fleetest.showResultsDashboard", () => controller.show()),
    // Select Project(fleetest.project の設定更新)に追従する。テストビューは設定変更で
    // refresh するのにこのパネルだけ据え置きだと、切り替えたのにヘッダが旧プロジェクトの
    // まま、に見える(2026-09-01 実害)
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration("fleetest.project")) {
        controller.onProjectSettingChanged();
      }
    }),
  );
  return { relocalize: () => controller.relocalize() };
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** export はテスト(panelRelocalize.test.mjs)が relocalize() を直接検証するため。
 * 生成経路は registerDashboardPanel のみ(シングルトン方針は変えない)。 */
export class DashboardPanelController implements vscode.Disposable {
  private panel: vscode.WebviewPanel | undefined;
  private readonly deps: DashboardPanelDeps;
  /** results/results-run のワンショット spawn(runOneShot 経由。同時に複数走りうる ——
   * refresh と runDetail/trend が重なるケース ——ので Set で持つ)。 */
  private readonly activeChildren = new Set<PipeProcess>();
  private readonly unsubscribeBus: () => void;
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

  constructor(
    private readonly workspaceRoot: string,
    private readonly getConfig: () => FleetestConfig,
    private readonly outputChannel: vscode.OutputChannel,
    eventBus: RunEventBus,
    private readonly extensionUri: vscode.Uri,
  ) {
    this.deps = {
      workspaceRoot: this.workspaceRoot,
      getConfig: this.getConfig,
      outputChannel: this.outputChannel,
      post: (message) => this.post(message),
    };
    this.unsubscribeBus = eventBus.subscribe((message) => this.handleBusMessage(message));
  }

  /** fleetest.project の設定変更(Select Project)への追従。購読は registerDashboardPanel が
   * 行う —— コンストラクタは vscode に触れない契約(panelRelocalize.test.mjs はスタブ下で
   * 直接 new するため。vscodeStubPlugin では namespace import の vscode.workspace が undefined)。 */
  onProjectSettingChanged(): void {
    if (this.panel) {
      void this.refresh();
    }
  }

  dispose(): void {
    this.unsubscribeBus();
    this.killActiveChild();
    const panel = this.panel;
    this.panel = undefined;
    panel?.dispose();
  }

  show(): void {
    if (this.panel) {
      this.panel.reveal(vscode.ViewColumn.Active);
      return;
    }
    const panel = vscode.window.createWebviewPanel(VIEW_TYPE, t("exploreHeal.dashboard.panelTitle"), vscode.ViewColumn.Active, {
      enableScripts: true,
      retainContextWhenHidden: true,
      localResourceRoots: [vscode.Uri.joinPath(this.extensionUri, "media")],
    });
    this.panel = panel;
    panel.webview.html = renderHtml(panel.webview, this.extensionUri);
    panel.webview.onDidReceiveMessage((message: unknown) => this.handleWebviewMessage(message));
    panel.onDidDispose(() => {
      this.panel = undefined;
      this.killActiveChild();
    });
  }

  private post(message: DashboardToWebviewMessage): void {
    void this.panel?.webview.postMessage(message);
  }

  /** fleetest.language 変更で extension.ts から呼ぶ。webview.html の再代入は webview を再読込するが、
   * "ready" ハンドラが refresh() で結果を叩き直して埋め直すため host 側の追加処理は不要
   * (handleWebviewMessage の "ready"/"refresh" 分岐参照)。パネル未生成時は何もしない。 */
  relocalize(): void {
    if (!this.panel) {
      return;
    }
    this.panel.webview.html = renderHtml(this.panel.webview, this.extensionUri);
  }

  /** パネル close 時・dispose 時に results 系の実行中プロセス全部を止める(oneShotCli.ts 呼び出し側
   * 共通の SIGTERM→2秒後 SIGKILL。1本運用時と同じ挙動を各プロセスへ適用する)。 */
  private killActiveChild(): void {
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

  private handleBusMessage(message: RunBusMessage): void {
    switch (message.type) {
      case "runStarted":
        this.lastRunWasDryRun = message.isDryRun;
        break;
      case "runEnded":
        if (!this.lastRunWasDryRun && this.panel) {
          void this.refresh();
        }
        break;
    }
  }

  private handleWebviewMessage(message: unknown): void {
    if (!isDashboardFromWebviewMessage(message)) {
      return;
    }
    switch (message.type) {
      case "ready":
      case "refresh":
        void this.refresh();
        break;
      case "runDetail":
        void this.handleRunDetail(message.runID);
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
   * 設定 fleetest.project を書き換えるだけ —— refresh は registerDashboardPanel の
   * onDidChangeConfiguration 購読が行う(2経路から refresh すると二重 spawn になる)。 */
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

  private async handleRunDetail(runID: string): Promise<void> {
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
      const args = ["api", "results-run", "--project", resolution.project, "--run-id", runID];
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
      this.deps.post({ type: "runDetail", payload: result.json });
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

function generateNonce(): string {
  return randomBytes(16).toString("hex");
}

function renderHtml(webview: vscode.Webview, extensionUri: vscode.Uri): string {
  const nonce = generateNonce();
  const styleUri = webview.asWebviewUri(vscode.Uri.joinPath(extensionUri, "media", "dashboard", "style.css"));
  const scriptUri = webview.asWebviewUri(vscode.Uri.joinPath(extensionUri, "media", "dashboard", "main.js"));
  const csp = [
    "default-src 'none'",
    `style-src ${webview.cspSource} 'unsafe-inline'`,
    `script-src 'nonce-${nonce}'`,
  ].join("; ");

  return `<!doctype html>
<html lang="${currentLocale()}">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="${csp}">
<title>${t("exploreHeal.dashboard.panelTitle")}</title>
<link rel="stylesheet" href="${styleUri}">
</head>
<body>
  <div id="toolbar" class="toolbar">
    <span class="dash-title">${t("exploreHeal.dashboard.title")}</span>
    <select id="dash-project-select" class="dash-project" title="${t("exploreHeal.dashboard.projectSelectTitle")}"></select>
    <button id="btn-refresh" type="button">${t("exploreHeal.dashboard.refreshButton")}</button>
    <span id="dash-generated-at" class="dash-generated-at"></span>
  </div>

  <div id="status-loading" class="status-message" style="display: none;">${t("exploreHeal.dashboard.loading")}</div>
  <div id="status-error" class="status-message status-error" style="display: none;"></div>
  <div id="status-empty" class="status-message" style="display: none;">${t("exploreHeal.dashboard.empty")}</div>

  <div id="content" class="content" style="display: none;">
    <section id="section-performance" class="dash-section" style="display: none;">
      <h2>${t("exploreHeal.dashboard.headingPerformance")}</h2>
      <div id="perf-summary"></div>
      <table id="table-perf-runs" class="dash-table">
        <thead>
          <tr><th>${t("exploreHeal.dashboard.colDateTime")}</th><th>machine</th><th>profile</th><th>${t("exploreHeal.dashboard.colWallClock")}</th><th>${t("exploreHeal.dashboard.colTestTime")}</th><th>${t("exploreHeal.dashboard.colScenarioTotal")}</th><th>${t("exploreHeal.dashboard.colLaneCount")}</th><th>${t("exploreHeal.dashboard.colLaneUtilisation")}</th><th>${t("exploreHeal.dashboard.colMaxScenario")}</th><th>${t("exploreHeal.dashboard.colRuns")}</th><th>${t("exploreHeal.dashboard.colResult")}</th></tr>
        </thead>
        <tbody id="table-perf-runs-body"></tbody>
      </table>
      <h3 id="perf-comparison-heading">${t("exploreHeal.dashboard.headingPerfComparison")}</h3>
      <table id="table-perf-comparison" class="dash-table">
        <thead>
          <tr><th>${t("exploreHeal.dashboard.colScenario")}</th><th>${t("exploreHeal.dashboard.colPlatform")}</th><th>${t("exploreHeal.dashboard.colPrevious")}</th><th>${t("exploreHeal.dashboard.colLatest")}</th><th>Δ%</th></tr>
        </thead>
        <tbody id="table-perf-comparison-body"></tbody>
      </table>
      <div id="perf-empty" class="section-empty" style="display: none;">${t("exploreHeal.dashboard.perfEmpty")}</div>
    </section>

    <section id="section-headline" class="dash-section">
      <h2>${t("exploreHeal.dashboard.headingRecentRuns")}</h2>
      <div id="headline-latest" class="headline-latest"></div>
      <table id="table-runs" class="dash-table">
        <thead>
          <tr><th>${t("exploreHeal.dashboard.colDateTime")}</th><th>trigger</th><th>machine</th><th>profile</th><th>${t("exploreHeal.dashboard.colResult")}</th></tr>
        </thead>
        <tbody id="table-runs-body"></tbody>
      </table>
    </section>

    <section id="section-run-detail" class="dash-section" style="display: none;">
      <h2 id="run-detail-title"></h2>
      <button id="run-detail-close" type="button">${t("exploreHeal.dashboard.closeButton")}</button>
      <div id="run-detail-body"></div>
    </section>

    <section id="section-insights" class="dash-section">
      <h2 id="insights-heading">${t("exploreHeal.dashboard.headingInsights")}</h2>
      <ul id="insights-list" class="insights-list"></ul>
      <div id="insights-empty" class="section-empty" style="display: none;">${t("exploreHeal.dashboard.insightsEmpty")}</div>
    </section>

    <section id="section-triage" class="dash-section" style="display: none;">
      <h2>${t("exploreHeal.dashboard.headingTriage")}</h2>
      <div id="triage-summary"></div>
      <table id="table-triage" class="dash-table">
        <thead>
          <tr><th>${t("exploreHeal.dashboard.colSection")}</th><th>${t("exploreHeal.dashboard.colCommand")}</th><th>${t("exploreHeal.dashboard.colFailureKind")}</th><th>${t("exploreHeal.dashboard.colCount")}</th><th>${t("exploreHeal.dashboard.colScenarioExamples")}</th></tr>
        </thead>
        <tbody id="table-triage-body"></tbody>
      </table>
      <h3>${t("exploreHeal.dashboard.headingTriageNotes")}</h3>
      <table id="table-triage-notes" class="dash-table">
        <thead>
          <tr><th>${t("exploreHeal.dashboard.colNote")}</th><th>${t("exploreHeal.dashboard.colCount")}</th></tr>
        </thead>
        <tbody id="table-triage-notes-body"></tbody>
      </table>
      <div id="triage-empty" class="section-empty" style="display: none;">${t("exploreHeal.dashboard.triageEmpty")}</div>
    </section>

    <section id="section-flaky" class="dash-section">
      <h2>${t("exploreHeal.dashboard.headingFlaky")}</h2>
      <table id="table-flaky" class="dash-table">
        <thead>
          <tr><th>${t("exploreHeal.dashboard.colScenarioId")}</th><th>${t("exploreHeal.dashboard.colRuns")}</th><th>${t("exploreHeal.dashboard.colFailureRate")}</th><th>${t("exploreHeal.dashboard.colFlakinessScore")}</th><th>${t("exploreHeal.dashboard.colRecentResults")}</th></tr>
        </thead>
        <tbody id="table-flaky-body"></tbody>
      </table>
      <div id="flaky-empty" class="section-empty" style="display: none;">${t("exploreHeal.dashboard.flakyEmpty")}</div>
    </section>

    <section id="section-trend" class="dash-section" style="display: none;">
      <h2 id="trend-title"></h2>
      <button id="trend-close" type="button">${t("exploreHeal.dashboard.closeButton")}</button>
      <div id="trend-body"></div>
    </section>

    <section id="section-slow" class="dash-section">
      <h2>${t("exploreHeal.dashboard.headingSlow")}</h2>
      <table id="table-slow" class="dash-table">
        <thead>
          <tr><th>${t("exploreHeal.dashboard.colScenarioId")}</th><th>${t("exploreHeal.dashboard.colRuns")}</th><th>${t("exploreHeal.dashboard.colAverage")}</th><th>p90</th><th>${t("exploreHeal.dashboard.colRegressionRate")}</th><th>${t("exploreHeal.dashboard.colSlowestScene")}</th></tr>
        </thead>
        <tbody id="table-slow-body"></tbody>
      </table>
      <div id="slow-empty" class="section-empty" style="display: none;">${t("exploreHeal.dashboard.slowEmpty")}</div>
    </section>

    <section id="section-matrix" class="dash-section" style="display: none;">
      <h2>${t("exploreHeal.dashboard.headingMatrix")}</h2>
      <div class="matrix-wrap">
        <table id="table-matrix" class="dash-table matrix-table">
          <thead>
            <tr id="table-matrix-head"><th>${t("exploreHeal.dashboard.colScenarioId")}</th><th>${t("exploreHeal.dashboard.colSuccessRate")}</th></tr>
          </thead>
          <tbody id="table-matrix-body"></tbody>
        </table>
      </div>
    </section>

    <section id="section-daily" class="dash-section">
      <h2>${t("exploreHeal.dashboard.headingDaily")}</h2>
      <label class="daily-toggle">
        <input type="checkbox" id="daily-fullsuite-toggle">
        <span id="daily-fullsuite-text"></span>
      </label>
      <div class="daily-chart-wrap">
        <canvas id="daily-chart" class="daily-chart"></canvas>
      </div>
    </section>

    <section id="section-summary" class="dash-section">
      <h2>${t("exploreHeal.dashboard.headingSummary")}</h2>
      <table id="table-summary" class="dash-table">
        <thead>
          <tr><th>${t("exploreHeal.dashboard.colScenarioId")}</th><th>${t("exploreHeal.dashboard.colRuns")}</th><th>${t("exploreHeal.dashboard.colSuccessRate")}</th><th>${t("exploreHeal.dashboard.colAvgMs")}</th><th>${t("exploreHeal.dashboard.colLastRun")}</th><th>${t("exploreHeal.dashboard.colLastResult")}</th></tr>
        </thead>
        <tbody id="table-summary-body"></tbody>
      </table>
    </section>

    <section id="section-devices" class="dash-section">
      <h2>${t("exploreHeal.dashboard.headingDevices")}</h2>
      <table id="table-devices" class="dash-table">
        <thead>
          <tr><th>worker</th><th>${t("exploreHeal.dashboard.colRuns")}</th><th>${t("exploreHeal.dashboard.colSuccessRate")}</th><th>${t("exploreHeal.dashboard.colAvgMs")}</th></tr>
        </thead>
        <tbody id="table-devices-body"></tbody>
      </table>
    </section>
  </div>

  <script nonce="${nonce}" src="${scriptUri}"></script>
</body>
</html>`;
}
