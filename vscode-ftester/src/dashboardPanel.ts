// dashboardPanel.ts
// テスト実行結果ダッシュボードの WebviewPanel(コマンド `ftester.showResultsDashboard`)。
// monitorPanel.ts/healReviewPanel.ts と同じシングルトンパターン(1拡張につきパネル1枚)。
//
// - データは `ftester api results --project <名> --since 90d --min-runs 3` を1発叩いて得る
//   1行 JSON(dashboardModel.ts の ApiResultsPayload / Sources/ftester/ApiResultsCommand.swift と同期)。
//   ビルドを伴わない読み取り専用コマンドなので cli.ts の FtesterCli(直列キュー)には乗せず
//   oneShotCli.ts の runOneShot() で単発 spawn する。
// - 更新タイミング: パネルを開いた時(show())・webview の「更新」ボタン(refresh)・
//   RunEventBus の runEnded(GUI 実行完了。dry-run は結果 DB に記録されないため対象外)。
// - webview 資産は src/webview/dashboard/{main.js,style.css}(esbuild が media/dashboard/ へ
//   バンドル)。テンプレートリテラル内蔵は禁止(CLAUDE.md 方針)。

import { randomBytes } from "node:crypto";
import * as vscode from "vscode";
import { type FtesterConfig, resolveProjectName } from "./config";
import { currentLocale, t } from "./i18n";
import { isApiResultsPayload, isDashboardFromWebviewMessage, type DashboardToWebviewMessage } from "./dashboardModel";
import { type OneShotResult, type PipeProcess, runOneShot } from "./oneShotCli";
import type { RunBusMessage, RunEventBus } from "./runEventBus";

const VIEW_TYPE = "ftesterResultsDashboard";
const RESULTS_SINCE = "90d";
const RESULTS_MIN_RUNS = 3;

/** DashboardPanelController が使う狭い窓口(将来サブコントローラへ分割する際も同じ形で注入する)。 */
export interface DashboardPanelDeps {
  readonly workspaceRoot: string;
  getConfig(): FtesterConfig;
  readonly outputChannel: vscode.OutputChannel;
  post(message: DashboardToWebviewMessage): void;
}

export function registerDashboardPanel(
  context: vscode.ExtensionContext,
  workspaceRoot: string,
  getConfig: () => FtesterConfig,
  outputChannel: vscode.OutputChannel,
  eventBus: RunEventBus,
): void {
  const controller = new DashboardPanelController(
    workspaceRoot,
    getConfig,
    outputChannel,
    eventBus,
    context.extensionUri,
  );
  context.subscriptions.push(
    controller,
    vscode.commands.registerCommand("ftester.showResultsDashboard", () => controller.show()),
  );
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

class DashboardPanelController implements vscode.Disposable {
  private panel: vscode.WebviewPanel | undefined;
  private readonly deps: DashboardPanelDeps;
  /** results のワンショット spawn(専用。runOneShot 経由)。 */
  private activeChild: PipeProcess | undefined;
  private readonly unsubscribeBus: () => void;
  /** runStarted の isDryRun を runEnded まで持ち越す(healReviewPanel.ts の HealFixCollector と同じ理由:
   * dry-run 実行は結果 DB に記録されないため runEnded 時点で除外判定するのにここで覚えておく必要がある)。 */
  private lastRunWasDryRun = false;
  /** 同時に複数 refresh() が走らないようにする簡易ガード(更新ボタン連打・runEnded と手動更新の重なり対策)。 */
  private refreshing = false;

  constructor(
    private readonly workspaceRoot: string,
    private readonly getConfig: () => FtesterConfig,
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

  /** パネル close 時・dispose 時に results 実行中プロセスを止める(oneShotCli.ts 呼び出し側共通の
   * SIGTERM→2秒後 SIGKILL)。 */
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
    }
  }

  private async refresh(): Promise<void> {
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    this.deps.post({ type: "loading" });
    try {
      const config = this.deps.getConfig();
      const resolution = resolveProjectName(this.deps.workspaceRoot, config);
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
      let result: OneShotResult;
      try {
        result = await runOneShot(config.binaryPath, this.deps.workspaceRoot, args, this.deps.outputChannel, (proc) => {
          this.activeChild = proc;
        });
      } finally {
        this.activeChild = undefined;
      }
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
    }
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
    <span id="dash-project" class="dash-project"></span>
    <button id="btn-refresh" type="button">${t("exploreHeal.dashboard.refreshButton")}</button>
    <span id="dash-generated-at" class="dash-generated-at"></span>
  </div>

  <div id="status-loading" class="status-message" style="display: none;">${t("exploreHeal.dashboard.loading")}</div>
  <div id="status-error" class="status-message status-error" style="display: none;"></div>
  <div id="status-empty" class="status-message" style="display: none;">${t("exploreHeal.dashboard.empty")}</div>

  <div id="content" class="content" style="display: none;">
    <section id="section-headline" class="dash-section">
      <h2>${t("exploreHeal.dashboard.headingRecentRuns")}</h2>
      <div id="headline-latest" class="headline-latest"></div>
      <table id="table-runs" class="dash-table">
        <thead>
          <tr><th>runID</th><th>${t("exploreHeal.dashboard.colDateTime")}</th><th>trigger</th><th>machine</th><th>profile</th><th>${t("exploreHeal.dashboard.colResult")}</th></tr>
        </thead>
        <tbody id="table-runs-body"></tbody>
      </table>
    </section>

    <section id="section-insights" class="dash-section">
      <h2 id="insights-heading">${t("exploreHeal.dashboard.headingInsights")}</h2>
      <ul id="insights-list" class="insights-list"></ul>
      <div id="insights-empty" class="section-empty" style="display: none;">${t("exploreHeal.dashboard.insightsEmpty")}</div>
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

    <section id="section-daily" class="dash-section">
      <h2>${t("exploreHeal.dashboard.headingDaily")}</h2>
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
