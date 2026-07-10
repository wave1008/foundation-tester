// healReviewPanel.ts
// 自己修復(--heal)の確認パネル。GUI 版 HealReviewSheet.swift + AppModel.applyHealFixes 相当。
//
// - RunEventBus(runHandler.ts の実行と同じインスタンス)を購読し、HealFixCollector
//   (healModel.ts、vscode 非依存)で fixSuggestion を収集する。実行終了時に候補が1件以上
//   あれば WebviewPanel を開く(monitorPanel.ts と同じシングルトンパターン)。
//   ftester.heal 設定に関わらず「fixSuggestion が届いたら」動く(profile 側の heal 設定で
//   ヒールされた場合にも確認できるようにするため)。dry-run 実行では HealFixCollector が
//   収集自体を行わないため、このパネルが開くことはない。
// - パネルを開く際、各候補の対象ソース行を拡張ホスト側で1回だけ読み、「適用可能か」
//   (旧セレクタの引用符付き文字列がちょうど1回)・行末コメント(説明欄の初期値)を判定して
//   webview へ渡す。以降の編集・diffプレビューは webview 内(素の JS。CSP により
//   healModel.ts を import できないため、同じロジックを手書きで複製している)で完結し、
//   拡張ホストとの往復は「適用」ボタン押下時だけ発生する。
// - 「適用」ボタンで `ftester api apply-heal --project <project>` を stdin 経由の JSON で
//   叩く(cli.ts の stdin 対応 spawn(CliInvocation.stdin)を使う)。適用成功分はパネルから
//   消し、失敗分は残してエラーメッセージを表示する。失敗が0件かつ残り0件のときだけ
//   パネルを自動的に閉じる(GUI の AppModel.applyHealFixes と同じ「レビュー済み」判定)。

import { randomBytes } from "node:crypto";
import * as fs from "node:fs";
import * as path from "node:path";
import * as vscode from "vscode";
import { type CliInvocation, type FtesterCli } from "./cli";
import { type FtesterConfig, resolveProjectName } from "./config";
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

const VIEW_TYPE = "ftesterHealReview";
const PANEL_TITLE = "ftester 自己修復の確認";

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
  getConfig: () => FtesterConfig,
  outputChannel: vscode.OutputChannel,
  eventBus: RunEventBus,
  cli: FtesterCli,
): void {
  const controller = new HealReviewController(workspaceRoot, getConfig, outputChannel, cli, eventBus);
  context.subscriptions.push(controller);
}

class HealReviewController implements vscode.Disposable {
  private panel: vscode.WebviewPanel | undefined;
  private readonly collector = new HealFixCollector();
  /** パネルに表示中(未解決)の候補。適用成功分をここから取り除く。 */
  private items: HealReviewItem[] = [];
  private project: string | undefined;
  private readonly unsubscribeBus: () => void;

  constructor(
    private readonly workspaceRoot: string,
    private readonly getConfig: () => FtesterConfig,
    private readonly outputChannel: vscode.OutputChannel,
    private readonly cli: FtesterCli,
    eventBus: RunEventBus,
  ) {
    this.unsubscribeBus = eventBus.subscribe((message) => this.handleBusMessage(message));
  }

  dispose(): void {
    this.unsubscribeBus();
    this.panel?.dispose();
    this.panel = undefined;
  }

  /** RunEventBus からのメッセージ(runHandler.ts の実行と同じインスタンス)。 */
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

    const panel = vscode.window.createWebviewPanel(VIEW_TYPE, PANEL_TITLE, vscode.ViewColumn.Active, {
      enableScripts: true,
      retainContextWhenHidden: true,
    });
    this.panel = panel;
    panel.webview.html = renderHtml(this.items);
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
      this.outputChannel.appendLine(`[ftester] 自己修復確認: ${fix.file} を読み込めません(${String(error)})`);
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
        message: "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
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
          message: `apply-heal の応答を解析できませんでした(exit code: ${String(result.exitCode)})。出力パネル「ftester」を確認してください。`,
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
      this.outputChannel.appendLine(`[ftester] apply-heal の実行に失敗しました: ${messageText}`);
      this.post({ type: "applyError", message: `apply-heal の実行に失敗しました: ${messageText}` });
    } finally {
      this.post({ type: "busy", busy: false });
    }
  }

  private post(message: HealToWebviewMessage): void {
    void this.panel?.webview.postMessage(message);
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

/** webview の HTML をインライン生成する。外部リソースは一切読み込まない(CSP: default-src 'none')。 */
function renderHtml(items: readonly HealReviewItem[]): string {
  const nonce = generateNonce();
  const csp = ["default-src 'none'", "style-src 'unsafe-inline'", `script-src 'nonce-${nonce}'`].join("; ");

  return `<!doctype html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="${csp}">
<title>${PANEL_TITLE}</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    padding: 16px 20px 20px 20px;
    font-family: var(--vscode-font-family, sans-serif);
    font-size: var(--vscode-font-size, 13px);
    color: var(--vscode-foreground);
    background-color: var(--vscode-editor-background);
  }
  h1 {
    font-size: 1.2em;
    margin: 0 0 4px 0;
  }
  p.intro {
    margin: 0 0 16px 0;
    color: var(--vscode-descriptionForeground);
  }
  .row {
    display: flex;
    align-items: flex-start;
    gap: 10px;
    padding: 12px 0;
    border-bottom: 1px solid var(--vscode-widget-border, var(--vscode-panel-border));
  }
  .row.applied { display: none; }
  .row input[type="checkbox"] {
    margin-top: 4px;
  }
  .row-body {
    flex: 1 1 auto;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .scenario-id {
    font-weight: 600;
  }
  .location {
    color: var(--vscode-descriptionForeground);
    font-size: 0.9em;
  }
  .field {
    display: flex;
    align-items: baseline;
    gap: 8px;
  }
  .field .label {
    flex: 0 0 110px;
    color: var(--vscode-descriptionForeground);
    font-size: 0.9em;
  }
  .field code, .field input[type="text"] {
    font-family: var(--vscode-editor-font-family, monospace);
  }
  .field input[type="text"] {
    flex: 1 1 auto;
    min-width: 0;
    padding: 2px 6px;
    background-color: var(--vscode-input-background);
    color: var(--vscode-input-foreground);
    border: 1px solid var(--vscode-input-border, transparent);
    border-radius: 2px;
  }
  .warn {
    color: var(--vscode-editorWarning-foreground, #cca700);
    font-size: 0.9em;
  }
  .preview {
    font-family: var(--vscode-editor-font-family, monospace);
    font-size: 0.9em;
    background-color: var(--vscode-textCodeBlock-background, rgba(127, 127, 127, 0.1));
    border-radius: 4px;
    padding: 6px 8px;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }
  .preview .del { color: var(--vscode-gitDecoration-deletedResourceForeground, #f14c4c); }
  .preview .add { color: var(--vscode-gitDecoration-addedResourceForeground, #73c991); }
  .message {
    color: var(--vscode-descriptionForeground);
    font-size: 0.9em;
  }
  .footer {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-top: 16px;
  }
  button {
    font-family: inherit;
    font-size: inherit;
    padding: 5px 12px;
    border: 1px solid var(--vscode-button-border, transparent);
    border-radius: 2px;
    background-color: var(--vscode-button-background);
    color: var(--vscode-button-foreground);
    cursor: pointer;
  }
  button:hover:not(:disabled) { background-color: var(--vscode-button-hoverBackground); }
  button:disabled { opacity: 0.5; cursor: default; }
  button.secondary {
    background-color: var(--vscode-button-secondaryBackground, transparent);
    color: var(--vscode-button-secondaryForeground, var(--vscode-foreground));
  }
  #error-area {
    margin-top: 10px;
    color: var(--vscode-errorForeground, #f14c4c);
    white-space: pre-wrap;
    display: none;
  }
  #empty {
    display: none;
    color: var(--vscode-descriptionForeground);
    padding: 20px 0;
  }
</style>
</head>
<body>
  <h1>自己修復の確認</h1>
  <p class="intro">自己修復されたセレクタがあります。修復内容をシナリオのソースに反映しますか?
    (「変更後」と「説明」は反映前に編集できます)</p>
  <div id="rows"></div>
  <div id="empty">対象の候補はありません。</div>
  <div class="footer">
    <button id="btn-apply">選択した 0 件を適用</button>
    <button id="btn-close" class="secondary">閉じる</button>
    <span id="busy-label" style="display:none;">適用中...</span>
  </div>
  <div id="error-area"></div>

  <script nonce="${nonce}">
  (function () {
    const vscode = acquireVsCodeApi();
    const rowsEl = document.getElementById('rows');
    const emptyEl = document.getElementById('empty');
    const btnApply = document.getElementById('btn-apply');
    const btnClose = document.getElementById('btn-close');
    const busyLabel = document.getElementById('busy-label');
    const errorArea = document.getElementById('error-area');

    // id -> row handle(DOM要素・item データ)
    const rows = new Map();
    let busy = false;

    // ---- healModel.ts の純粋ロジックの手書き複製(webview は CSP により import 不可) ----

    function isValidSelector(selector) {
      return selector.length > 0 && selector.indexOf('"') === -1
        && selector.indexOf('\\n') === -1 && selector.indexOf('\\r') === -1;
    }
    function isValidComment(comment) {
      return comment.indexOf('\\n') === -1 && comment.indexOf('\\r') === -1;
    }
    function trailingCommentIndex(line) {
      let inString = false;
      let escaped = false;
      let prevSlash = -1;
      for (let i = 0; i < line.length; i += 1) {
        const ch = line[i];
        if (inString) {
          if (escaped) { escaped = false; }
          else if (ch === '\\\\') { escaped = true; }
          else if (ch === '"') { inString = false; }
          prevSlash = -1;
        } else if (ch === '"') {
          inString = true;
          prevSlash = -1;
        } else if (ch === '/') {
          if (prevSlash !== -1) { return prevSlash; }
          prevSlash = i;
        } else {
          prevSlash = -1;
        }
      }
      return -1;
    }
    function setTrailingCommentPreview(line, newComment) {
      const start = trailingCommentIndex(line);
      if (start === -1) {
        if (newComment.length === 0) { return line; }
        let end = line.length;
        while (end > 0 && (line[end - 1] === ' ' || line[end - 1] === '\\t')) { end -= 1; }
        return line.slice(0, end) + '  // ' + newComment;
      }
      if (newComment.length === 0) {
        let end = start;
        while (end > 0 && (line[end - 1] === ' ' || line[end - 1] === '\\t')) { end -= 1; }
        return line.slice(0, end);
      }
      let textStart = start + 2;
      while (textStart < line.length && (line[textStart] === ' ' || line[textStart] === '\\t')) { textStart += 1; }
      return line.slice(0, textStart) + newComment;
    }
    function buildPreviewAfterLine(originalLine, oldSelector, newSelector, originalComment, editedComment) {
      const quotedOld = '"' + oldSelector + '"';
      const quotedNew = '"' + newSelector + '"';
      let replaced = originalLine.split(quotedOld).join(quotedNew);
      if (isValidComment(editedComment)) {
        const trimmed = editedComment.trim();
        if (trimmed !== (originalComment || '')) {
          replaced = setTrailingCommentPreview(replaced, trimmed);
        }
      }
      return replaced;
    }
    function computeNewComment(originalComment, editedComment) {
      const trimmed = editedComment.trim();
      return trimmed === (originalComment || '') ? null : trimmed;
    }

    // ---- 行の構築・更新 ----------------------------------------------------------

    function createRow(item) {
      const row = document.createElement('div');
      row.className = 'row';

      const checkbox = document.createElement('input');
      checkbox.type = 'checkbox';
      checkbox.checked = !item.unavailable;
      checkbox.disabled = item.unavailable;

      const body = document.createElement('div');
      body.className = 'row-body';

      const scenarioEl = document.createElement('div');
      scenarioEl.className = 'scenario-id';
      scenarioEl.textContent = item.scenarioID;

      const locationEl = document.createElement('div');
      locationEl.className = 'location';
      locationEl.textContent = item.file + ':' + item.line;

      const beforeField = document.createElement('div');
      beforeField.className = 'field';
      const beforeLabel = document.createElement('span');
      beforeLabel.className = 'label';
      beforeLabel.textContent = '変更前';
      const beforeCode = document.createElement('code');
      beforeCode.textContent = item.oldSelector;
      beforeField.append(beforeLabel, beforeCode);

      const afterField = document.createElement('div');
      afterField.className = 'field';
      const afterLabel = document.createElement('span');
      afterLabel.className = 'label';
      afterLabel.textContent = '変更後';
      const selectorInput = document.createElement('input');
      selectorInput.type = 'text';
      selectorInput.value = item.newSelector;
      afterField.append(afterLabel, selectorInput);

      const selectorWarn = document.createElement('div');
      selectorWarn.className = 'warn';
      selectorWarn.textContent = '⚠️ 適用できません(セレクタは空にできず、「"」と改行は使えません)';
      selectorWarn.style.display = 'none';

      const commentField = document.createElement('div');
      commentField.className = 'field';
      const commentLabel = document.createElement('span');
      commentLabel.className = 'label';
      commentLabel.textContent = '説明';
      const commentInput = document.createElement('input');
      commentInput.type = 'text';
      commentInput.value = item.originalComment || '';
      commentField.append(commentLabel, commentInput);

      const commentWarn = document.createElement('div');
      commentWarn.className = 'warn';
      commentWarn.textContent = '⚠️ 適用できません(説明に改行は使えません)';
      commentWarn.style.display = 'none';

      const preview = document.createElement('div');
      preview.className = 'preview';

      const unavailableWarn = document.createElement('div');
      unavailableWarn.className = 'warn';
      unavailableWarn.textContent = '⚠️ 適用できません(ソースが変更されています)';

      const messageEl = document.createElement('div');
      messageEl.className = 'message';
      messageEl.textContent = item.message || '';

      body.append(scenarioEl, locationEl, beforeField, afterField, selectorWarn, commentField, commentWarn);
      if (item.unavailable) {
        body.appendChild(unavailableWarn);
      } else {
        body.appendChild(preview);
      }
      if (item.message) {
        body.appendChild(messageEl);
      }

      row.append(checkbox, body);
      rowsEl.appendChild(row);

      const handle = { item, row, checkbox, selectorInput, commentInput, selectorWarn, commentWarn, preview };
      rows.set(item.id, handle);

      function revalidate() {
        const selectorValid = isValidSelector(selectorInput.value);
        const commentValid = isValidComment(commentInput.value);
        selectorWarn.style.display = selectorValid ? 'none' : 'block';
        commentWarn.style.display = commentValid ? 'none' : 'block';
        if ((!selectorValid || !commentValid) && checkbox.checked) {
          checkbox.checked = false;
        }
        checkbox.disabled = item.unavailable || !selectorValid || !commentValid;
        if (!item.unavailable && selectorValid) {
          const after = buildPreviewAfterLine(
            item.originalLine, item.oldSelector, selectorInput.value,
            item.originalComment, commentValid ? commentInput.value : (item.originalComment || ''),
          );
          preview.textContent = '';
          const delLine = document.createElement('div');
          delLine.className = 'del';
          delLine.textContent = '- ' + item.originalLine;
          const addLine = document.createElement('div');
          addLine.className = 'add';
          addLine.textContent = '+ ' + after;
          preview.append(delLine, addLine);
        }
        updateApplyButton();
      }

      selectorInput.addEventListener('input', revalidate);
      commentInput.addEventListener('input', revalidate);
      checkbox.addEventListener('change', updateApplyButton);
      revalidate();

      return handle;
    }

    function addItems(items) {
      for (const item of items) {
        if (!rows.has(item.id)) {
          createRow(item);
        }
      }
      updateEmptyState();
      updateApplyButton();
    }

    function updateEmptyState() {
      const visible = [...rows.values()].some((h) => h.row.style.display !== 'none');
      emptyEl.style.display = visible ? 'none' : 'block';
    }

    function updateApplyButton() {
      const checkedCount = [...rows.values()].filter((h) => !h.row.classList.contains('applied') && h.checkbox.checked).length;
      btnApply.textContent = '選択した ' + checkedCount + ' 件を適用';
      btnApply.disabled = busy || checkedCount === 0;
      btnClose.disabled = busy;
    }

    function setBusy(value) {
      busy = value;
      busyLabel.style.display = busy ? 'inline' : 'none';
      updateApplyButton();
    }

    function collectFixes() {
      const fixes = [];
      for (const handle of rows.values()) {
        if (handle.row.classList.contains('applied') || !handle.checkbox.checked) {
          continue;
        }
        const selector = handle.selectorInput.value;
        const comment = handle.commentInput.value;
        if (!isValidSelector(selector) || !isValidComment(comment)) {
          continue;
        }
        fixes.push({
          scenarioID: handle.item.scenarioID,
          file: handle.item.file,
          line: handle.item.line,
          oldSelector: handle.item.oldSelector,
          newSelector: selector,
          newComment: computeNewComment(handle.item.originalComment, comment),
        });
      }
      return fixes;
    }

    function showError(text) {
      errorArea.textContent = text;
      errorArea.style.display = text ? 'block' : 'none';
    }

    btnApply.addEventListener('click', () => {
      const fixes = collectFixes();
      if (fixes.length === 0) { return; }
      showError('');
      vscode.postMessage({ type: 'apply', fixes });
    });
    btnClose.addEventListener('click', () => {
      vscode.postMessage({ type: 'close' });
    });

    window.addEventListener('message', (event) => {
      const message = event.data;
      if (!message || typeof message.type !== 'string') { return; }
      switch (message.type) {
        case 'addItems':
          addItems(message.items);
          break;
        case 'busy':
          setBusy(!!message.busy);
          break;
        case 'applyResult': {
          for (const id of message.appliedIds) {
            const handle = rows.get(id);
            if (handle) {
              handle.row.classList.add('applied');
              handle.row.style.display = 'none';
            }
          }
          if (message.failures.length > 0) {
            const lines = message.failures.map((f) => {
              const handle = rows.get(f.id);
              const label = handle ? handle.item.scenarioID + '(' + handle.item.file + ':' + handle.item.line + ')' : f.id;
              return label + ': ' + f.message;
            });
            showError(lines.join('\\n'));
          } else {
            showError('');
          }
          updateEmptyState();
          updateApplyButton();
          break;
        }
        case 'applyError':
          showError(message.message);
          break;
        default:
          break;
      }
    });

    addItems(${JSON.stringify(items)});
  })();
  </script>
</body>
</html>`;
}
