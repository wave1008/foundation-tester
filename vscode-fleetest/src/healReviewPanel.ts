// healReviewPanel.ts
// 自己修復の確認パネル。
//
// RunEventBus(runHandler.ts と同じインスタンス)を購読し、HealFixCollector(healModel.ts)で
// fixSuggestion を収集する。実行終了時に候補が1件以上あれば WebviewPanel を開く
// (monitorPanel.ts と同じシングルトンパターン)。fleetest.heal 設定に関わらず「fixSuggestion が
// 届いたら」動く(profile 側の heal 設定でヒールされた場合にも確認できるようにするため)。
// dry-run 実行では HealFixCollector が収集自体を行わないためパネルは開かない。
//
// webview 資産は src/webview/healReview/{style.css,main.js}(esbuild が media/healReview/ へバンドル)。
// 編集・diffプレビューの判定は main.js が healModel.ts を直接 import する(複製しない)。
//
// 「適用」は `fleetest api apply-heal --project <project>` を stdin 経由の JSON で叩く
// (cli.ts の CliInvocation.stdin)。失敗が0件かつ残り0件のときだけパネルを自動的に閉じる。

import { randomBytes } from "node:crypto";
import * as fs from "node:fs";
import * as path from "node:path";
import * as vscode from "vscode";
import { type CliInvocation, type FleetestCli } from "./cli";
import { type FleetestConfig, resolveProjectName } from "./config";
import { currentLocale, t } from "./i18n";
import {
  buildApplyHealRequest,
  healFixId,
  HealFixCollector,
  type HealApplyFix,
  type HealFix,
  parseApplyHealResponse,
  selectorOccursOnce,
  trailingComment,
} from "./healModel";
import type { RunBusMessage, RunEventBus } from "./runEventBus";

const VIEW_TYPE = "fleetestHealReview";

/** webview へ渡す1件分の初期データ(拡張ホストが1回だけソースを読んで判定した結果)。 */
interface HealReviewItem {
  readonly id: string;
  readonly scenarioID: string;
  readonly file: string;
  readonly line: number;
  readonly oldSelector: string;
  readonly newSelector: string;
  readonly message: string;
  /** ソースが読めない/行が範囲外/旧セレクタがちょうど1回でない = 適用不可。 */
  readonly unavailable: boolean;
  readonly originalLine: string | undefined;
  readonly originalComment: string | undefined;
}

interface ApplyHealFailurePayload {
  readonly id: string;
  readonly message: string;
}

type HealToWebviewMessage =
  | { readonly type: "addItems"; readonly items: readonly HealReviewItem[] }
  | { readonly type: "busy"; readonly busy: boolean }
  | {
      readonly type: "applyResult";
      readonly appliedIds: readonly string[];
      readonly failures: readonly ApplyHealFailurePayload[];
    }
  | { readonly type: "applyError"; readonly message: string };

interface ApplyFromWebviewMessage {
  readonly type: "apply";
  readonly fixes: readonly HealApplyFix[];
}

interface CloseFromWebviewMessage {
  readonly type: "close";
}

type HealFromWebviewMessage = ApplyFromWebviewMessage | CloseFromWebviewMessage;

export function registerHealReviewPanel(
  context: vscode.ExtensionContext,
  workspaceRoot: string,
  getConfig: () => FleetestConfig,
  outputChannel: vscode.OutputChannel,
  eventBus: RunEventBus,
  cli: FleetestCli,
): { relocalize(): void } {
  const controller = new HealReviewController(
    workspaceRoot, getConfig, outputChannel, cli, eventBus,
    webviewAssets(context.extensionUri),
  );
  context.subscriptions.push(controller);
  return { relocalize: () => controller.relocalize() };
}

/** export はテスト(panelRelocalize.test.mjs)が relocalize() を直接検証するため。
 * 生成経路は registerHealReviewPanel のみ(シングルトン方針は変えない)。 */
export class HealReviewController implements vscode.Disposable {
  private panel: vscode.WebviewPanel | undefined;
  private readonly collector = new HealFixCollector();
  /** パネルに表示中(未解決)の候補。適用成功分をここから取り除く。 */
  private items: HealReviewItem[] = [];
  private project: string | undefined;
  private readonly unsubscribeBus: () => void;

  constructor(
    private readonly workspaceRoot: string,
    private readonly getConfig: () => FleetestConfig,
    private readonly outputChannel: vscode.OutputChannel,
    private readonly cli: FleetestCli,
    eventBus: RunEventBus,
    /** テストは vscode.Uri を使えない(vscodeStubPlugin)ため注入する。 */
    private readonly assets: HealReviewWebviewAssets,
  ) {
    this.unsubscribeBus = eventBus.subscribe((message) => this.handleBusMessage(message));
  }

  dispose(): void {
    this.unsubscribeBus();
    this.panel?.dispose();
    this.panel = undefined;
  }

  handleBusMessage(message: RunBusMessage): void {
    switch (message.type) {
      case "runStarted":
        this.collector.begin(message.isDryRun);
        break;
      case "event":
        this.collector.collect(message.event);
        break;
      case "runEnded":
        if (!this.collector.isEmpty()) {
          this.openReview(this.collector.list());
        }
        break;
    }
  }

  private openReview(fixes: readonly HealFix[]): void {
    const config = this.getConfig();
    const resolution = resolveProjectName(this.workspaceRoot, config);
    this.project = resolution.kind === "resolved" ? resolution.project : undefined;

    const existingIds = new Set(this.items.map((item) => item.id));
    const newItems = fixes.map((fix) => this.loadItem(fix)).filter((item) => !existingIds.has(item.id));
    this.items = [...this.items, ...newItems];

    if (this.panel) {
      this.panel.reveal(vscode.ViewColumn.Active);
      if (newItems.length > 0) {
        this.post({ type: "addItems", items: newItems });
      }
      return;
    }

    const panel = vscode.window.createWebviewPanel(VIEW_TYPE, t("exploreHeal.heal.panelTitle"), vscode.ViewColumn.Active, {
      enableScripts: true,
      retainContextWhenHidden: true,
      localResourceRoots: this.assets.localResourceRoots,
    });
    this.panel = panel;
    panel.webview.html = renderHtml(this.items, this.assets.resolve(panel.webview));
    panel.webview.onDidReceiveMessage((message: unknown) => this.handleWebviewMessage(message));
    panel.onDidDispose(() => {
      this.panel = undefined;
      this.items = [];
    });
  }

  /** 対象ソース行を1回だけ読み、適用可否・行末コメントを判定する。 */
  private loadItem(fix: HealFix): HealReviewItem {
    const id = healFixId(fix);
    const absolute = path.isAbsolute(fix.file) ? fix.file : path.join(this.workspaceRoot, fix.file);
    let originalLine: string | undefined;
    let originalComment: string | undefined;
    let unavailable = true;
    try {
      const source = fs.readFileSync(absolute, "utf8");
      const lines = source.split("\n");
      if (fix.line >= 1 && fix.line <= lines.length) {
        const line = lines[fix.line - 1] ?? "";
        if (selectorOccursOnce(line, fix.oldSelector)) {
          originalLine = line;
          originalComment = trailingComment(line);
          unavailable = false;
        }
      }
    } catch (error) {
      this.outputChannel.appendLine(t("exploreHeal.heal.log.readFailed", { file: fix.file, error: String(error) }));
    }
    return {
      id,
      scenarioID: fix.scenarioID,
      file: fix.file,
      line: fix.line,
      oldSelector: fix.oldSelector,
      newSelector: fix.newSelector,
      message: fix.message,
      unavailable,
      originalLine,
      originalComment,
    };
  }

  private handleWebviewMessage(message: unknown): void {
    if (!isHealFromWebviewMessage(message)) {
      return;
    }
    if (message.type === "close") {
      this.panel?.dispose();
      this.panel = undefined;
      return;
    }
    void this.applyFixes(message.fixes);
  }

  private async applyFixes(fixes: readonly HealApplyFix[]): Promise<void> {
    if (fixes.length === 0 || !this.panel) {
      return;
    }
    if (!this.project) {
      this.post({
        type: "applyError",
        message: t("exploreHeal.common.projectUnresolved"),
      });
      return;
    }
    const config = this.getConfig();
    const request = buildApplyHealRequest(fixes);
    const invocation: CliInvocation = {
      args: ["api", "apply-heal", "--project", this.project],
      stdin: JSON.stringify(request),
      onLog: (line, stream) => this.outputChannel.appendLine(`[apply-heal ${stream}] ${line}`),
    };

    this.post({ type: "busy", busy: true });
    try {
      const result = await this.cli.invoke(config.binaryPath, this.workspaceRoot, invocation);
      const response = parseApplyHealResponse(result.json);
      if (!response) {
        this.post({
          type: "applyError",
          message: t("exploreHeal.heal.applyResponseParseFailed", { exitCode: String(result.exitCode) }),
        });
        return;
      }
      const appliedSet = new Set(response.applied);
      this.items = this.items.filter((item) => !appliedSet.has(item.id));
      this.post({ type: "applyResult", appliedIds: response.applied, failures: response.failures });
      if (response.failures.length === 0 && this.items.length === 0) {
        this.panel.dispose();
        this.panel = undefined;
      }
    } catch (error) {
      const messageText = error instanceof Error ? error.message : String(error);
      this.outputChannel.appendLine(t("exploreHeal.heal.log.applyFailed", { message: messageText }));
      this.post({ type: "applyError", message: t("exploreHeal.heal.applyFailed", { message: messageText }) });
    } finally {
      this.post({ type: "busy", busy: false });
    }
  }

  private post(message: HealToWebviewMessage): void {
    void this.panel?.webview.postMessage(message);
  }

  /** fleetest.language 変更で extension.ts から呼ぶ。this.items(未解決候補)を埋め込んだ静的 HTML を
   * 組み直すだけでよい(状態を watch していない・"ready" 相当のイベントも持たない)。
   * パネル未生成時は何もしない。 */
  relocalize(): void {
    if (!this.panel) {
      return;
    }
    this.panel.webview.html = renderHtml(this.items, this.assets.resolve(this.panel.webview));
  }
}

function isHealFromWebviewMessage(value: unknown): value is HealFromWebviewMessage {
  if (typeof value !== "object" || value === null) {
    return false;
  }
  const v = value as { type?: unknown };
  if (v.type === "close") {
    return true;
  }
  if (v.type !== "apply") {
    return false;
  }
  const fixes = (value as { fixes?: unknown }).fixes;
  return Array.isArray(fixes) && fixes.every((fix) => isHealApplyFixLike(fix));
}

function isHealApplyFixLike(value: unknown): value is HealApplyFix {
  if (typeof value !== "object" || value === null) {
    return false;
  }
  const fix = value as Record<string, unknown>;
  return (
    typeof fix.scenarioID === "string" &&
    typeof fix.file === "string" &&
    typeof fix.line === "number" &&
    typeof fix.oldSelector === "string" &&
    typeof fix.newSelector === "string" &&
    (fix.newComment === null || typeof fix.newComment === "string")
  );
}

function generateNonce(): string {
  return randomBytes(16).toString("hex");
}

/** webview 資産(media/healReview/。src/webview/healReview/ を esbuild がバンドル)の URI。 */
export interface HealReviewAssets {
  readonly styleUri: string;
  readonly scriptUri: string;
  readonly cspSource: string;
}

export interface HealReviewWebviewAssets {
  readonly localResourceRoots: readonly vscode.Uri[];
  resolve(webview: vscode.Webview): HealReviewAssets;
}

function webviewAssets(extensionUri: vscode.Uri): HealReviewWebviewAssets {
  const root = vscode.Uri.joinPath(extensionUri, "media", "healReview");
  return {
    localResourceRoots: [root],
    resolve: (webview) => ({
      styleUri: webview.asWebviewUri(vscode.Uri.joinPath(root, "style.css")).toString(),
      scriptUri: webview.asWebviewUri(vscode.Uri.joinPath(root, "main.js")).toString(),
      cspSource: webview.cspSource,
    }),
  };
}

/** script 要素の中に置く JSON。`<` を逃がさないとセレクタ中の `</script>` で要素が閉じる。 */
function jsonForScriptElement(value: unknown): string {
  return JSON.stringify(value).replace(/</g, "\\u003c");
}

/** 初期データ(文言 + 候補)は #heal-review-data の JSON で渡す(読み手: src/webview/healReview/main.js)。 */
function renderHtml(items: readonly HealReviewItem[], assets: HealReviewAssets): string {
  const nonce = generateNonce();
  const csp = [
    "default-src 'none'",
    `style-src ${assets.cspSource}`,
    `script-src 'nonce-${nonce}'`,
  ].join("; ");
  // applyButtonTemplate は '{count}' を残したまま渡す(webview が件数で置換する)。
  const initialData = {
    txt: {
      fieldBefore: t("exploreHeal.heal.fieldBefore"),
      fieldAfter: t("exploreHeal.heal.fieldAfter"),
      fieldComment: t("exploreHeal.heal.fieldComment"),
      selectorWarn: t("exploreHeal.heal.selectorWarn"),
      commentWarn: t("exploreHeal.heal.commentWarn"),
      unavailableWarn: t("exploreHeal.heal.unavailableWarn"),
      applyButtonTemplate: t("exploreHeal.heal.applyButtonLabel"),
    },
    items,
  };

  return `<!doctype html>
<html lang="${currentLocale()}">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="${csp}">
<title>${t("exploreHeal.heal.panelTitle")}</title>
<link rel="stylesheet" href="${assets.styleUri}">
</head>
<body>
  <h1>${t("exploreHeal.heal.heading")}</h1>
  <p class="intro">${t("exploreHeal.heal.intro")}</p>
  <div id="rows"></div>
  <div id="empty">${t("exploreHeal.heal.empty")}</div>
  <div class="footer">
    <button id="btn-apply">${t("exploreHeal.heal.applyButtonLabel", { count: "0" })}</button>
    <button id="btn-close" class="secondary">${t("exploreHeal.heal.closeButton")}</button>
    <span id="busy-label">${t("exploreHeal.heal.busyLabel")}</span>
  </div>
  <div id="error-area"></div>

  <script type="application/json" id="heal-review-data">${jsonForScriptElement(initialData)}</script>
  <script nonce="${nonce}" src="${assets.scriptUri}"></script>
</body>
</html>`;
}
