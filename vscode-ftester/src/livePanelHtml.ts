// livePanelHtml.ts
// 独立ライブ操作パネル(livePanel.ts)の webview HTML 生成。CSP・nonce の作り方は monitorHtml.ts と
// 同一。スタイルは media/monitor/style.css を共用する(#panel-live 系の CSS は全てそちらにあり、
// このパネル専用の CSS は無い)。本文は monitorHtml.ts の #panel-live ブロックと同一(id は同じ
// 前提で liveTab.js が参照するため変更しないこと)。

import { randomBytes } from "node:crypto";
import * as vscode from "vscode";
import { currentLocale, t } from "./i18n";

/** ライブ操作パネルのタイトル(VS Code タブ表示・HTML の <title> の両方で使う)。locale 依存の
 * ため関数(module-level const だと initI18n 前の既定 locale で固定されてしまう)。 */
export function livePanelTitle(): string {
  return t("panels.live.panelTitle");
}

function generateNonce(): string {
  return randomBytes(16).toString("hex");
}

export function renderLiveHtml(webview: vscode.Webview, extensionUri: vscode.Uri): string {
  const nonce = generateNonce();
  const styleUri = webview.asWebviewUri(vscode.Uri.joinPath(extensionUri, "media", "monitor", "style.css"));
  const scriptUri = webview.asWebviewUri(vscode.Uri.joinPath(extensionUri, "media", "live", "main.js"));
  const csp = [
    "default-src 'none'",
    "img-src data:",
    `style-src ${webview.cspSource} 'unsafe-inline'`,
    `script-src 'nonce-${nonce}'`,
  ].join("; ");

  return `<!doctype html>
<html lang="${currentLocale()}">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="${csp}">
<title>${livePanelTitle()}</title>
<link rel="stylesheet" href="${styleUri}">
</head>
<body>
  <div id="panel-live" class="tab-panel">
    <div class="toolbar">
      <label for="live-device-select">${t("panels.common.deviceLabelColon")}</label>
      <select id="live-device-select"></select>
      <button id="live-btn-refresh-devices" class="secondary">${t("panels.common.refreshDeviceList")}</button>
      <span id="live-device-warning"></span>
      <span id="live-busy-label"></span>
    </div>
    <div class="toolbar live-record-row">
      <label for="live-app-profile-select">${t("panels.live.appProfileLabelColon")}</label>
      <select id="live-app-profile-select" title="${t("panels.common.appProfile")}"></select>
    </div>
    <div class="toolbar live-app-profile-detail" id="live-app-profile-detail">
      <span class="app-profile-detail-field"><span class="app-profile-detail-label">${t("panels.appProfile.displayNameLabel")}:</span> <span id="live-app-profile-name" class="app-profile-detail-value">—</span></span>
      <span class="app-profile-detail-field"><span class="app-profile-detail-label">${t("panels.appProfile.appIdLabel")}:</span> <span id="live-app-profile-bundle" class="app-profile-detail-value">—</span></span>
      <span class="app-profile-detail-field app-profile-detail-path"><span class="app-profile-detail-label">${t("panels.appProfile.packagePathLabel")}:</span> <span id="live-app-profile-path" class="app-profile-detail-value">—</span></span>
      <button id="live-btn-install" class="secondary" title="${t("panels.live.installButtonTitle")}" disabled>${t("panels.live.installButton")}</button>
    </div>
    <div class="toolbar live-record-actions">
      <button id="live-btn-record">${t("panels.live.startRecording")}</button>
      <button id="live-btn-launch" class="secondary" title="${t("panels.live.launchButtonTitle")}" disabled>${t("panels.live.launchButton")}</button>
      <span id="live-record-status" class="live-record-status"></span>
    </div>
    <div id="live-banner" class="banner"></div>
    <div id="live-action-error"></div>

    <div class="content">
      <div class="screenshot-pane" id="live-screenshot-pane">
        <!-- 画像スロット。内容フィットで画像実寸に縮み pane 上端に付く。liveTab.js の fitScreenshot が
             pane 実測高から actions/gap を引いた残りを #live-screenshot の max-height に反映する。 -->
        <div class="screenshot-frame" id="live-screenshot-frame">
          <div class="screenshot-wrap" id="live-screenshot-wrap">
            <img id="live-screenshot" alt="${t("panels.live.screenshotAlt")}">
            <div id="live-hover-box"></div>
            <svg id="live-drag-overlay" aria-hidden="true"><line id="live-drag-line"/><circle id="live-drag-start" r="6"/></svg>
            <div id="live-screenshot-placeholder">${t("panels.live.screenshotPlaceholder")}</div>
            <div id="live-conn-overlay">
              <div class="conn-title">${t("panels.live.connectionErrorTitle")}</div>
              <div class="conn-note">${t("panels.live.connectionErrorNote")}</div>
              <div id="live-conn-detail"></div>
            </div>
            <div id="live-busy-overlay">
              <div id="live-busy-spinner"></div>
              <div id="live-busy-message"></div>
            </div>
          </div>
        </div>
        <div class="screenshot-actions" id="live-screenshot-actions">
          <button id="live-btn-home" class="secondary" title="${t("panels.live.homeButtonTitle")}">${t("panels.live.homeButton")}</button>
          <button id="live-btn-app-switcher" class="secondary" title="${t("panels.live.appSwitcherTitle")}">${t("panels.live.appSwitcherButton")}</button>
        </div>
      </div>

      <div class="splitter splitter-vertical" id="live-screen-splitter" title="${t("panels.live.screenSplitterTitle")}"></div>

      <div class="control-pane">
        <div class="live-lists">
          <div class="live-elements-section" id="live-elements-section">
            <div class="elements-header">
              <span>${t("panels.live.elementsHeader")}</span>
              <button id="live-btn-refresh-snapshot" class="secondary" title="${t("panels.live.refreshSnapshotTitle")}">${t("panels.live.refreshSnapshot")}</button>
            </div>
            <div id="live-elements-list" class="elements-list"></div>
            <div class="row live-type-row">
              <input id="live-type-text" type="text" placeholder="${t("panels.live.typeTextPlaceholder")}">
            </div>
          </div>
          <div class="splitter" id="live-lists-splitter" title="${t("panels.live.listsSplitterTitle")}"></div>
          <div class="live-oplog-section">
            <div class="oplog-header">
              <span>${t("panels.live.oplogHeader")}</span>
              <button id="live-btn-oplog-clear" class="secondary" type="button">${t("panels.live.oplogClear")}</button>
            </div>
            <div id="live-oplog-list" class="oplog-list"></div>
          </div>
        </div>
      </div>
    </div>
  </div>

  <!-- ライブ操作の画像上で右クリック。開始/終了の活性は liveTab.js が録画状態に応じて切替(#live-btn-record と同ロジック)。 -->
  <div id="live-record-menu" class="device-op-menu" role="menu">
    <button id="live-record-menu-start" class="device-op-menu-item" type="button" role="menuitem">${t("panels.live.startRecording")}</button>
    <button id="live-record-menu-stop" class="device-op-menu-item" type="button" role="menuitem">${t("panels.live.stopRecording")}</button>
  </div>

  <script nonce="${nonce}" src="${scriptUri}"></script>
</body>
</html>`;
}
