// monitorHtml.ts
// デバイスモニターパネル(monitorPanel.ts)の webview HTML 生成部分。generateNonce()/renderHtml()
// (+ その中で参照する PANEL_TITLE)を持つ。webview 資産(スタイル・スクリプト)自体は
// src/webview/monitor/{style.css,main.js} に分離されており、esbuild が
// media/monitor/ にバンドルしたものを renderHtml() が webview.asWebviewUri で読み込む。
// HTML 本文は renderHtml() 内にインライン生成する。

import { randomBytes } from "node:crypto";
import * as vscode from "vscode";
import { currentLocale, t } from "./i18n";

/** デバイスモニターパネルのタイトル(VS Code タブ表示・HTML の <title> の両方で使う)。 */
export const PANEL_TITLE = "Foundation Tester";

function generateNonce(): string {
  return randomBytes(16).toString("hex");
}

export function renderHtml(webview: vscode.Webview, extensionUri: vscode.Uri): string {
  const nonce = generateNonce();
  const styleUri = webview.asWebviewUri(vscode.Uri.joinPath(extensionUri, "media", "monitor", "style.css"));
  const scriptUri = webview.asWebviewUri(vscode.Uri.joinPath(extensionUri, "media", "monitor", "main.js"));
  const csp = [
    "default-src 'none'",
    "img-src data:",
    // 録画タブの <video src> (webview.asWebviewUri 経由の mp4)読み込みに必要。
    `media-src ${webview.cspSource}`,
    `style-src ${webview.cspSource} 'unsafe-inline'`,
    `script-src 'nonce-${nonce}'`,
  ].join("; ");

  return `<!doctype html>
<html lang="${currentLocale()}">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="${csp}">
<title>${PANEL_TITLE}</title>
<link rel="stylesheet" href="${styleUri}">
</head>
<body>
  <div id="tabbar" role="tablist">
    <button id="tab-devices" class="tab-button active" type="button" role="tab" aria-selected="true" aria-controls="panel-devices">${t("panels.tabs.devices")}</button>
    <button id="tab-profiles" class="tab-button" type="button" role="tab" aria-selected="false" aria-controls="panel-profiles">${t("panels.tabs.profiles")}</button>
    <button id="tab-processes" class="tab-button" type="button" role="tab" aria-selected="false" aria-controls="panel-processes">${t("panels.tabs.processes")}</button>
    <button id="tab-recordings" class="tab-button" type="button" role="tab" aria-selected="false" aria-controls="panel-recordings">${t("panels.tabs.recordings")}</button>
    <button id="tab-settings" class="tab-button" type="button" role="tab" aria-selected="false" aria-controls="panel-settings">${t("panels.tabs.settings")}</button>
  </div>

  <div id="panel-devices" class="tab-panel" role="tabpanel" aria-labelledby="tab-devices">
    <div id="toolbar" class="toolbar">
      <label class="profile-label">${t("panels.common.runProfile")}
        <select id="profile-select" title="${t("panels.toolbar.runProfileSelectTitle")}" disabled></select>
      </label>
      <button id="btn-devices-up">${t("panels.toolbar.startAllDevices")}</button>
      <button id="btn-devices-down" class="secondary">${t("panels.toolbar.stopAll")}</button>
      <button id="btn-restart" class="secondary">${t("panels.toolbar.restartMonitor")}</button>
      <!-- hostMetricsメッセージ受信のたびにmain.js側で再描画(独自タイマーなし)。 -->
      <div id="host-metrics" class="host-metrics">
        <span class="host-metric" id="hm-mem" title="${t("panels.hostMetrics.memTitle")}"><span class="hm-label">MEM</span><canvas class="hm-canvas" width="72" height="22"></canvas><span class="hm-value">–</span></span>
        <span class="host-metric" id="hm-cpu" title="${t("panels.hostMetrics.cpuTitle")}"><span class="hm-label">CPU</span><canvas class="hm-canvas" width="72" height="22"></canvas><span class="hm-value">–</span></span>
        <span class="host-metric" id="hm-gpu" title="${t("panels.hostMetrics.gpuTitle")}"><span class="hm-label">GPU</span><canvas class="hm-canvas" width="72" height="22"></canvas><span class="hm-value">–</span></span>
        <span class="host-metric" id="hm-fm" title="${t("panels.hostMetrics.fmTitle")}"><span class="hm-label">FM</span><canvas class="hm-canvas" width="72" height="22"></canvas><span class="hm-value">–</span></span>
      </div>
    </div>
    <div id="banner" class="banner"></div>

    <div id="tile-pane" class="tile-pane">
      <div id="grid" class="grid"></div>
      <div id="empty" class="empty">${t("panels.devices.emptyMessage")}</div>
    </div>

    <div id="splitter" class="splitter" role="separator" aria-orientation="horizontal" aria-label="${t("panels.devices.splitterAriaLabel")}"></div>

    <div id="output-pane" class="output-pane">
      <div class="lanes-header">
        <span class="lanes-title">${t("panels.common.runLog")}</span>
        <span id="lanes-selection-status"></span>
        <span id="lanes-run-status"></span>
      </div>
      <div id="lanes-placeholder" class="lanes-placeholder">${t("panels.devices.lanesPlaceholder")}</div>
      <div id="lanes-grid" class="lanes-grid" style="display: none;"></div>
    </div>
  </div>

  <div id="panel-profiles" class="tab-panel" role="tabpanel" aria-labelledby="tab-profiles" style="display: none;">
    <div id="profile-jump-header" class="profile-jump-header">
      <button type="button" class="profile-jump-link" data-target="run-profile-section">${t("panels.common.runProfile")}</button>
      <button type="button" class="profile-jump-link" data-target="app-profile-section">${t("panels.common.appProfile")}</button>
      <button type="button" class="profile-jump-link" data-target="machine-profile-section">${t("panels.common.machineProfile")}</button>
    </div>

    <div id="run-profile-section" class="profile-section run-profile-section">
      <div class="profile-toolbar">
        <span class="profile-toolbar-title">${t("panels.common.runProfile")}</span>
        <select id="run-profile-select" style="display: none;"></select>
        <span id="run-profile-name-static" class="machine-name-static" style="display: none;">${t("panels.runProfile.noneSelected")}</span>
        <!-- アイコンはcodicon "add"/"copy"/"remove"/"edit"と同一パスのインラインSVG
             (CSPで外部codiconフォントを読み込めないため。以下の各プロファイルセクションも同じ)。 -->
        <button id="btn-run-profile-add" class="icon-button" title="${t("panels.runProfile.addTitle")}" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M14 7v1H8v6H7V8H1V7h6V1h1v6h6z"/></svg></button>
        <button id="btn-run-profile-copy" class="icon-button" title="${t("panels.runProfile.copyTitle")}" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M4 4l1-1h5.414L14 6.586V14l-1 1H5l-1-1V4zm9 3l-3-3H5v10h8V7zM3 1L2 2v10l1 1V2h6.414l-1-1H3z"/></svg></button>
        <button id="btn-run-profile-remove" class="icon-button" title="${t("panels.runProfile.removeTitle")}" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M15 8H1V7h14v1z"/></svg></button>
        <button id="btn-run-profile-rename" class="icon-button" title="${t("panels.runProfile.renameTitle")}" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M13.23 1h-1.46L3.52 9.25l-.16.22L1 13.59 2.41 15l4.12-2.36.22-.16L15 4.23V2.77L13.23 1zM2.41 13.59l1.51-3 1.45 1.45-2.96 1.55zm3.83-2.06L4.47 9.76l8-8 1.77 1.77-8 8z"/></svg></button>
      </div>
      <div id="run-profile-body" class="run-profile-body">
        <div id="run-profile-placeholder" class="profile-detail-placeholder" style="display: none;"></div>
        <div id="run-profile-editor" class="run-profile-editor" style="display: none;">
          <div class="modal-row">
            <label for="run-profile-machine">${t("panels.runProfile.machineLabel")}<span class="required-badge">${t("panels.common.required")}</span></label>
            <select id="run-profile-machine"></select>
          </div>
          <div class="modal-row">
            <label for="run-profile-app">${t("panels.runProfile.appLabel")}</label>
            <select id="run-profile-app"></select>
          </div>
          <div class="modal-row run-profile-devices-row">
            <label>${t("panels.common.devices")}</label>
            <div id="run-profile-devices" class="run-profile-devices"></div>
          </div>
          <div class="modal-row profile-checkbox-row">
            <input type="checkbox" id="run-profile-record">
            <label for="run-profile-record">${t("panels.runProfile.recordLabel")}</label>
          </div>
          <div class="modal-row profile-checkbox-row">
            <input type="checkbox" id="run-profile-heal">
            <label for="run-profile-heal">${t("panels.runProfile.healLabel")}</label>
          </div>
          <div class="modal-row profile-checkbox-row">
            <input type="checkbox" id="run-profile-ios-inapp-engine">
            <label for="run-profile-ios-inapp-engine">${t("panels.runProfile.inappEngineLabel")}</label>
          </div>
          <div class="modal-row profile-checkbox-row">
            <input type="checkbox" id="run-profile-wipe-data-on-bloat">
            <label for="run-profile-wipe-data-on-bloat">${t("panels.runProfile.wipeOnBloatLabel")}</label>
          </div>
          <div class="modal-row">
            <label for="run-profile-wipe-threshold">${t("panels.runProfile.wipeThresholdLabel")}</label>
            <input type="text" id="run-profile-wipe-threshold" placeholder="8">
          </div>
          <div class="modal-row">
            <label for="run-profile-locale">${t("panels.runProfile.localeLabel")}</label>
            <input type="text" id="run-profile-locale" placeholder="ja_JP">
          </div>
          <div class="modal-row">
            <label for="run-profile-report-dir">reportDir</label>
            <input type="text" id="run-profile-report-dir" placeholder="reports">
          </div>
          <div class="modal-row">
            <label for="run-profile-default-timeout">defaultTimeout</label>
            <input type="text" id="run-profile-default-timeout">
          </div>
          <div id="run-profile-error" class="modal-error"></div>
          <div class="modal-buttons form-buttons">
            <button id="run-profile-confirm" type="button" disabled>${t("panels.common.confirm")}</button>
            <button id="run-profile-cancel" class="secondary" type="button" style="display: none;">${t("panels.common.cancel")}</button>
          </div>
        </div>
      </div>
    </div>

    <div id="app-profile-section" class="profile-section app-profile-section">
      <div class="profile-toolbar">
        <span class="profile-toolbar-title">${t("panels.common.appProfile")}</span>
        <select id="app-profile-select" style="display: none;"></select>
        <span id="app-profile-name-static" class="machine-name-static" style="display: none;">${t("panels.appProfile.noneSelected")}</span>
        <button id="btn-app-profile-add" class="icon-button" title="${t("panels.appProfile.addTitle")}" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M14 7v1H8v6H7V8H1V7h6V1h1v6h6z"/></svg></button>
        <button id="btn-app-profile-copy" class="icon-button" title="${t("panels.appProfile.copyTitle")}" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M4 4l1-1h5.414L14 6.586V14l-1 1H5l-1-1V4zm9 3l-3-3H5v10h8V7zM3 1L2 2v10l1 1V2h6.414l-1-1H3z"/></svg></button>
        <button id="btn-app-profile-remove" class="icon-button" title="${t("panels.appProfile.removeTitle")}" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M15 8H1V7h14v1z"/></svg></button>
        <button id="btn-app-profile-rename" class="icon-button" title="${t("panels.appProfile.renameTitle")}" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M13.23 1h-1.46L3.52 9.25l-.16.22L1 13.59 2.41 15l4.12-2.36.22-.16L15 4.23V2.77L13.23 1zM2.41 13.59l1.51-3 1.45 1.45-2.96 1.55zm3.83-2.06L4.47 9.76l8-8 1.77 1.77-8 8z"/></svg></button>
      </div>
      <div id="app-profile-body" class="app-profile-body">
        <div id="app-profile-placeholder" class="profile-detail-placeholder" style="display: none;"></div>
        <div id="app-profile-editor" class="app-profile-editor" style="display: none;">
          <!-- common.app/appPathは廃止済み(ランタイムが無視するため入力欄なし)。
               autoInstallは共通でのみ設定可能(既定OFF)。 -->
          <div class="app-profile-group-title">${t("panels.appProfile.commonGroupTitle")}</div>
          <div class="modal-row">
            <label for="app-profile-common-app-name">${t("panels.appProfile.displayNameLabel")}</label>
            <input type="text" id="app-profile-common-app-name">
          </div>
          <div class="modal-row profile-checkbox-row">
            <input type="checkbox" id="app-profile-common-auto-install">
            <label for="app-profile-common-auto-install">${t("panels.appProfile.autoInstallLabel")}</label>
          </div>

          <div class="app-profile-group-title app-profile-group-title-ios">iOS</div>
          <div class="modal-row">
            <label for="app-profile-ios-app-name">${t("panels.appProfile.displayNameLabel")}</label>
            <input type="text" id="app-profile-ios-app-name">
          </div>
          <div class="modal-row">
            <label for="app-profile-ios-app">${t("panels.appProfile.appIdLabel")}</label>
            <input type="text" id="app-profile-ios-app" placeholder="bundle id">
          </div>
          <div class="modal-row">
            <label for="app-profile-ios-app-path">${t("panels.appProfile.packagePathLabel")}</label>
            <input type="text" id="app-profile-ios-app-path">
          </div>

          <div class="app-profile-group-title app-profile-group-title-android">Android</div>
          <div class="modal-row">
            <label for="app-profile-android-app-name">${t("panels.appProfile.displayNameLabel")}</label>
            <input type="text" id="app-profile-android-app-name">
          </div>
          <div class="modal-row">
            <label for="app-profile-android-app">${t("panels.appProfile.appIdLabel")}</label>
            <input type="text" id="app-profile-android-app" placeholder="${t("panels.appProfile.packageNamePlaceholder")}">
          </div>
          <div class="modal-row">
            <label for="app-profile-android-app-path">${t("panels.appProfile.packagePathLabel")}</label>
            <input type="text" id="app-profile-android-app-path">
          </div>

          <div id="app-profile-error" class="modal-error"></div>
          <div class="modal-buttons form-buttons">
            <button id="app-profile-confirm" type="button" disabled>${t("panels.common.confirm")}</button>
            <button id="app-profile-cancel" class="secondary" type="button" style="display: none;">${t("panels.common.cancel")}</button>
          </div>
        </div>
      </div>
    </div>

    <div id="machine-profile-section" class="profile-section">
      <div class="profile-toolbar">
        <span class="profile-toolbar-title">${t("panels.common.machineProfile")}</span>
        <select id="machine-select" style="display: none;"></select>
        <span id="machine-name-static" class="machine-name-static" style="display: none;"></span>
        <button id="btn-machine-add" class="icon-button" title="${t("panels.machineProfile.addTitle")}" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M14 7v1H8v6H7V8H1V7h6V1h1v6h6z"/></svg></button>
        <button id="btn-machine-copy" class="icon-button" title="${t("panels.machineProfile.copyTitle")}" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M4 4l1-1h5.414L14 6.586V14l-1 1H5l-1-1V4zm9 3l-3-3H5v10h8V7zM3 1L2 2v10l1 1V2h6.414l-1-1H3z"/></svg></button>
        <button id="btn-machine-remove" class="icon-button" title="${t("panels.machineProfile.removeTitle")}" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M15 8H1V7h14v1z"/></svg></button>
        <button id="btn-machine-rename" class="icon-button" title="${t("panels.machineProfile.renameTitle")}" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M13.23 1h-1.46L3.52 9.25l-.16.22L1 13.59 2.41 15l4.12-2.36.22-.16L15 4.23V2.77L13.23 1zM2.41 13.59l1.51-3 1.45 1.45-2.96 1.55zm3.83-2.06L4.47 9.76l8-8 1.77 1.77-8 8z"/></svg></button>
      </div>
      <div class="profile-actions">
        <!-- 「+新規作成」ボタンは廃止済み。新規作成は#device-pick-overlay内の「+」(device-pick-add-new)から行う。 -->
        <span class="profile-actions-label">${t("panels.common.devices")}</span>
        <button id="btn-device-add-existing" class="icon-button" title="${t("panels.machineProfile.addExistingTitle")}" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M14 7v1H8v6H7V8H1V7h6V1h1v6h6z"/></svg></button>
      </div>
      <div id="machine-profile-error" class="profile-error" style="display: none;"></div>
      <div id="machine-profile-body" class="profile-body">
        <div id="machine-device-list" class="machine-device-list"></div>
        <div id="machine-device-detail-pane" class="machine-device-detail-pane">
          <div id="profile-detail-placeholder" class="profile-detail-placeholder">${t("panels.machineProfile.selectPrompt")}</div>
          <div id="machine-device-editor" class="machine-device-editor" style="display: none;">
            <div class="machine-device-editor-header">
              <span id="editor-device-name" class="tile-name"></span>
              <span id="editor-device-platform" class="editor-platform-label"></span>
            </div>
            <!-- 機種/OS/UDID/AVDは実体を指す属性でAPIでは変更不可(除去→作り直しが必要)なため
                 inputではなくlabel表示(inputイベントを発火しないのでdirty判定にも入らない)。
                 名前/ポートはプロファイル側設定値なので編集可。 -->
            <div class="modal-row">
              <label for="editor-name">${t("panels.machineProfile.nameLabel")}</label>
              <input type="text" id="editor-name">
            </div>
            <div id="editor-ios-fields">
              <div class="modal-row">
                <label>${t("panels.machineProfile.modelLabel")}</label>
                <span id="editor-simulator" class="editor-readonly-value" title="${t("panels.machineProfile.modelReadonlyTitle")}"></span>
              </div>
              <div class="modal-row">
                <label>OS</label>
                <span id="editor-os" class="editor-readonly-value" title="${t("panels.machineProfile.osReadonlyTitle")}"></span>
              </div>
              <div class="modal-row">
                <label>UDID</label>
                <span id="editor-udid" class="editor-readonly-value" title="${t("panels.machineProfile.udidReadonlyTitle")}"></span>
              </div>
              <div class="modal-row">
                <label for="editor-port">${t("panels.common.port")}</label>
                <input type="text" id="editor-port">
              </div>
            </div>
            <div id="editor-android-fields">
              <div class="modal-row">
                <label>AVD</label>
                <span id="editor-avd" class="editor-readonly-value" title="${t("panels.machineProfile.avdReadonlyTitle")}"></span>
              </div>
            </div>
            <div id="editor-error" class="modal-error"></div>
            <div class="modal-buttons form-buttons">
              <button id="editor-confirm" type="button" disabled>${t("panels.common.confirm")}</button>
              <button id="editor-cancel" class="secondary" type="button" style="display: none;">${t("panels.common.cancel")}</button>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>

  <div id="panel-processes" class="tab-panel" role="tabpanel" aria-labelledby="tab-processes" style="display: none;">
    <div class="processes-body">
      <div class="processes-title">${t("panels.processes.title")}</div>
      <div id="resident-updated" class="resident-updated"></div>
      <div class="resident-toolbar">
        <button id="resident-kill-all" class="resident-danger" type="button">${t("panels.processes.killAll")}</button>
        <span id="resident-status" class="resident-status"></span>
      </div>
      <div id="resident-list" class="resident-list">
        <table class="resident-table">
          <thead>
            <tr><th class="col-type" data-sort="type">${t("panels.processes.colType")}</th><th class="col-port" data-sort="port">${t("panels.common.port")}</th><th class="col-pid" data-sort="pid">PID</th><th class="col-detail" data-sort="detail">${t("panels.processes.colDetail")}</th><th class="col-ppid" data-sort="ppid">${t("panels.processes.colParentPid")}</th><th class="col-pdesc" data-sort="parentDescription">${t("panels.processes.colParentProcess")}</th><th class="col-note" data-sort="note">${t("panels.processes.colNote")}</th></tr>
          </thead>
          <tbody id="resident-tbody"></tbody>
        </table>
      </div>
    </div>
  </div>

  <div id="panel-recordings" class="tab-panel" role="tabpanel" aria-labelledby="tab-recordings" style="display: none;">
    <div id="recordings-list-view" class="recordings-list-view">
      <div class="recordings-toolbar">
        <span class="recordings-toolbar-title">${t("panels.recordings.sessionsTitle")}</span>
        <button id="recordings-refresh" class="secondary" type="button">${t("panels.recordings.refresh")}</button>
      </div>
      <div id="recordings-empty" class="recordings-empty" style="display: none;"></div>
      <div id="recordings-sessions" class="recordings-sessions"></div>
    </div>
    <div id="recordings-player-view" class="recordings-player-view" style="display: none;">
      <div class="recordings-player-toolbar">
        <button id="recordings-back" class="icon-button" type="button" title="${t("panels.recordings.backTitle")}"><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path fill-rule="evenodd" clip-rule="evenodd" d="M7.146 3.646a.5.5 0 0 1 .708.708L4.707 7.5H13.5a.5.5 0 0 1 0 1H4.707l3.147 3.146a.5.5 0 0 1-.708.708l-4-4a.5.5 0 0 1 0-.708l4-4z"/></svg></button>
        <span id="recordings-session-title" class="recordings-session-title"></span>
        <div id="recordings-worker-tabs" class="recordings-worker-tabs"></div>
      </div>
      <div class="recordings-body">
        <div class="recordings-video-pane">
          <video id="recordings-video" class="recordings-video" playsinline></video>
          <div class="recordings-now-playing">
            <div id="recordings-now-playing-class" class="recordings-now-playing-line"></div>
            <div id="recordings-now-playing-detail" class="recordings-now-playing-line recordings-now-playing-detail"></div>
          </div>
          <div class="recordings-controls">
            <select id="recordings-speed" class="recordings-speed">
              <option value="0.5">0.5x</option>
              <option value="1" selected>1x</option>
              <option value="2">2x</option>
              <option value="4">4x</option>
            </select>
            <input id="recordings-seek" class="recordings-seek-bar" type="range" min="0" max="1000" value="0" step="1" aria-label="${t("panels.recordings.seekAriaLabel")}">
            <span id="recordings-time-current" class="recordings-time">0:00</span>
            <span class="recordings-time-sep">/</span>
            <span id="recordings-time-total" class="recordings-time">0:00</span>
            <button id="recordings-rewind" type="button" class="recordings-seek-button" title="${t("panels.recordings.rewindTitle")}">−10s</button>
            <button id="recordings-play" type="button" class="icon-button recordings-play-button" title="${t("panels.recordings.playPauseTitle")}"></button>
            <button id="recordings-forward" type="button" class="recordings-seek-button" title="${t("panels.recordings.forwardTitle")}">+10s</button>
            <button id="recordings-prev-test" type="button" class="icon-button recordings-nav-button" title="${t("panels.recordings.prevTestTitle")}"><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M3.5 3H5v10H3.5z"/><path d="M12.5 3v10L6 8z"/></svg></button>
            <button id="recordings-next-test" type="button" class="icon-button recordings-nav-button" title="${t("panels.recordings.nextTestTitle")}"><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M11 3h1.5v10H11z"/><path d="M3.5 3v10L10 8z"/></svg></button>
          </div>
        </div>
        <div class="splitter splitter-vertical" id="recordings-splitter-tree" role="separator" aria-orientation="vertical" title="${t("panels.recordings.splitterTitle")}"></div>
        <div class="recordings-tree-pane">
          <div class="recordings-tree-header">
            <span class="recordings-tree-title">${t("panels.recordings.treeTitle")}</span>
            <button id="recordings-tree-expand-all" class="icon-button" type="button" title="${t("panels.recordings.expandAllTitle")}"><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M6 7h1v2h2v1H7v2H6v-2H4V9h2V7z"/><path fill-rule="evenodd" clip-rule="evenodd" d="M5 3l1-1h7l1 1v7l-1 1h-2v2l-1 1H3l-1-1V6l1-1h2V3zm1 2h4l1 1v4h2V3H6v2zm4 1H3v7h7V6z"/></svg></button>
            <button id="recordings-tree-collapse-all" class="icon-button" type="button" title="${t("panels.recordings.collapseAllTitle")}"><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M9 9H4v1h5V9z"/><path fill-rule="evenodd" clip-rule="evenodd" d="M5 3l1-1h7l1 1v7l-1 1h-2v2l-1 1H3l-1-1V6l1-1h2V3zm1 2h4l1 1v4h2V3H6v2zm4 1H3v7h7V6z"/></svg></button>
          </div>
          <div id="recordings-tree-empty" class="recordings-tree-empty" style="display: none;"></div>
          <div id="recordings-tree" class="recordings-tree" role="tree"></div>
        </div>
        <div class="splitter splitter-vertical splitter-static" id="recordings-splitter-errors" role="separator" aria-orientation="vertical"></div>
        <div class="recordings-errors-pane">
          <div class="recordings-errors-title">${t("panels.recordings.errorsTitle")}</div>
          <div id="recordings-errors-filter" class="recordings-errors-filter" style="display: none;">
            <span id="recordings-errors-filter-label" class="recordings-errors-filter-label"></span>
            <button id="recordings-errors-filter-clear" class="recordings-errors-filter-clear" type="button" title="${t("panels.recordings.filterClearTitle")}">${t("panels.recordings.filterClear")}</button>
          </div>
          <div id="recordings-errors-empty" class="recordings-errors-empty" style="display: none;"></div>
          <div id="recordings-errors-list" class="recordings-errors-list"></div>
        </div>
      </div>
    </div>
  </div>

  <div id="panel-settings" class="tab-panel" role="tabpanel" aria-labelledby="tab-settings" style="display: none;">
    <div class="settings-body">
      <div class="settings-group">
        <label class="settings-label" for="settings-language">${t("panels.settings.languageLabel")}</label>
        <select id="settings-language" class="settings-select">
          <option value="auto">${t("panels.settings.languageAuto")}</option>
          <option value="ja">${t("panels.settings.languageJa")}</option>
          <option value="en">${t("panels.settings.languageEn")}</option>
        </select>
        <div class="settings-hint">${t("panels.settings.languageHint")}</div>
      </div>
      <div class="settings-group">
        <label class="settings-item"><input type="checkbox" id="settings-polling-mode"> ${t("panels.settings.pollingModeLabel")}</label>
        <div class="settings-hint">${t("panels.settings.pollingModeHint")}</div>
      </div>
    </div>
  </div>

  <!-- アイコンはcodicon "vm-running"/"play"/"debug-stop"のインラインSVG。
       #device-op-menu-itemはup/down両方のアイコンを持ち、data-op(deviceTiles.jsが設定)でCSS表示切替。 -->
  <div id="device-op-menu" class="device-op-menu" role="menu">
    <button id="device-op-menu-live" class="device-op-menu-item" type="button" role="menuitem"><svg class="op-icon" width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path fill-rule="evenodd" clip-rule="evenodd" d="M6.607 14C6.79 14.357 7.017 14.689 7.275 15H3.5C3.224 15 3 14.776 3 14.5C3 14.224 3.224 14 3.5 14H5V12H3C1.895 12 1 11.105 1 10V3C1 1.895 1.895 1 3 1H13C14.105 1 15 1.895 15 3V7.293C14.69 7.036 14.357 6.816 14 6.633V3C14 2.448 13.552 2 13 2H3C2.448 2 2 2.448 2 3V10C2 10.552 2.448 11 3 11H6.024C5.994 11.332 6.004 11.666 6.034 12H6V14H6.607ZM16 11.5C16 12.39 15.736 13.26 15.242 14C14.748 14.74 14.045 15.317 13.222 15.657C12.4 15.998 11.495 16.087 10.622 15.913C9.749 15.739 8.947 15.311 8.318 14.681C7.689 14.052 7.26 13.25 7.086 12.377C6.912 11.504 7.001 10.599 7.342 9.777C7.683 8.955 8.259 8.252 8.999 7.757C9.739 7.264 10.609 7 11.499 7C12.692 7 13.837 7.474 14.681 8.318C15.525 9.162 16 10.307 16 11.5ZM13.97 11.499C13.97 11.41 13.946 11.323 13.901 11.246C13.856 11.17 13.791 11.106 13.713 11.063L10.743 9.413C10.667 9.371 10.581 9.349 10.494 9.35C10.407 9.351 10.322 9.375 10.247 9.419C10.171 9.463 10.109 9.526 10.066 9.602C10.023 9.677 10 9.763 10 9.85V13.15C10 13.237 10.023 13.322 10.066 13.398C10.11 13.474 10.172 13.537 10.247 13.581C10.322 13.625 10.407 13.649 10.494 13.65C10.581 13.65 10.667 13.629 10.743 13.587L13.713 11.937C13.791 11.892 13.856 11.829 13.901 11.752C13.946 11.676 13.97 11.588 13.97 11.499Z"/></svg><span>${t("panels.deviceMenu.liveControl")}</span></button>
    <button id="device-op-menu-item" class="device-op-menu-item" type="button" role="menuitem"><svg class="op-icon op-icon-up" width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M4.74514 3.06414C4.41183 2.87665 4 3.11751 4 3.49993V12.5002C4 12.8826 4.41182 13.1235 4.74512 12.936L12.7454 8.43601C13.0852 8.24486 13.0852 7.75559 12.7454 7.56443L4.74514 3.06414ZM3 3.49993C3 2.35268 4.2355 1.63011 5.23541 2.19257L13.2357 6.69286C14.2551 7.26633 14.2551 8.73415 13.2356 9.30759L5.23537 13.8076C4.23546 14.37 3 13.6474 3 12.5002V3.49993Z"/></svg><svg class="op-icon op-icon-down" width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M12.5 3.5V12.5H3.5V3.5H12.5ZM12.5 2H3.5C2.672 2 2 2.672 2 3.5V12.5C2 13.328 2.672 14 3.5 14H12.5C13.328 14 14 13.328 14 12.5V3.5C14 2.672 13.328 2 12.5 2Z"/></svg><span id="device-op-menu-item-label"></span></button>
    <!-- CPU 描画フォールバックを解除して host GPU で再起動。deviceTiles.js が CPU バッジのタイルでのみ表示。 -->
    <button id="device-op-menu-gpu" class="device-op-menu-item" type="button" role="menuitem"><svg class="op-icon" width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M4.681 3H2V2h3.5l.5.5V6H5V4a5 5 0 1 0 4.53-.635l.418-.909A6 6 0 1 1 4.681 3z"/></svg><span>${t("panels.deviceMenu.restartWithGpu")}</span></button>
  </div>

  <!-- #device-op-menuとスタイルのみ共用する別要素。「除去」はプロファイルから外すだけで本体は削除しない。 -->
  <div id="machine-device-menu" class="device-op-menu" role="menu">
    <button id="machine-device-menu-item" class="device-op-menu-item" type="button" role="menuitem">${t("panels.deviceMenu.remove")}</button>
  </div>

  <div id="device-add-overlay" class="modal-overlay">
    <div class="modal-dialog" role="dialog" aria-modal="true" aria-labelledby="device-add-title">
      <div id="device-add-title" class="modal-title">${t("panels.deviceAdd.title")}</div>
      <div class="modal-row">
        <label>${t("panels.deviceAdd.osTypeLabel")}</label>
        <div class="modal-radio-group">
          <label class="modal-radio"><input type="radio" id="dlg-platform-ios" name="dlg-platform" value="ios" checked>iOS</label>
          <label class="modal-radio"><input type="radio" id="dlg-platform-android" name="dlg-platform" value="android">Android</label>
        </div>
      </div>
      <div class="modal-row">
        <label for="dlg-model">${t("panels.deviceAdd.modelLabel")}</label>
        <select id="dlg-model"></select>
      </div>
      <div class="modal-row">
        <label for="dlg-os">${t("panels.deviceAdd.osVersionLabel")}</label>
        <select id="dlg-os"></select>
      </div>
      <div class="modal-row">
        <label for="dlg-name">${t("panels.deviceAdd.nameLabel")}</label>
        <input type="text" id="dlg-name">
      </div>
      <div id="dlg-error" class="modal-error"></div>
      <div class="modal-buttons">
        <button id="dlg-cancel" class="secondary" type="button">${t("panels.common.cancel")}</button>
        <button id="dlg-ok" type="button">OK</button>
      </div>
    </div>
  </div>

  <!-- 実行/アプリ/マシンプロファイルの追加・コピー・名前変更で共通利用(showInputBox相当)。
       拡張側nameInputOpenでtitle/初期値/検証パラメータ(noun/dupLabel/existing/caseInsensitiveDup)を
       受け取り、OK/キャンセルはnameInputConfirm/nameInputCancelをid付きで返す(拡張側pendingNameInputと突合)。 -->
  <div id="name-input-overlay" class="modal-overlay">
    <div class="modal-dialog" role="dialog" aria-modal="true" aria-labelledby="name-input-title">
      <div id="name-input-title" class="modal-title"></div>
      <div class="modal-row">
        <input type="text" id="name-input-field">
      </div>
      <div id="name-input-error" class="modal-error"></div>
      <div class="modal-buttons">
        <button id="name-input-cancel" class="secondary" type="button">${t("panels.common.cancel")}</button>
        <button id="name-input-ok" type="button">OK</button>
      </div>
    </div>
  </div>

  <!-- 中身(#device-pick-ios-body/-android-body)はJSがinstalledDevices受信時に組み立てる。
       チェックボックスは「選択」ではなく登録状態そのもの(登録済み=初期チェック、disabled化しない)。
       OKは初期状態からの差分がある間だけ有効(JS側)。「+」(device-pick-add-new)はこのモーダルを
       閉じずに#device-add-overlayを重ねて開く(z-indexは#device-add-overlayのCSSルール参照)。 -->
  <div id="device-pick-overlay" class="modal-overlay">
    <div class="modal-dialog" role="dialog" aria-modal="true" aria-labelledby="device-pick-title">
      <div class="modal-title device-pick-title-row">
        <span id="device-pick-title">${t("panels.devicePick.title")}</span>
        <button id="device-pick-add-new" class="icon-button" type="button" title="${t("panels.devicePick.addNewTitle")}"><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M14 7v1H8v6H7V8H1V7h6V1h1v6h6z"/></svg></button>
      </div>
      <div id="device-pick-list" class="device-pick-list">
        <div id="device-pick-ios-group" class="device-pick-group">
          <div class="device-pick-group-title" id="device-pick-ios-title">${t("panels.devicePick.iosGroupTitle")}</div>
          <div id="device-pick-ios-body" class="device-pick-group-body"></div>
        </div>
        <div id="device-pick-android-group" class="device-pick-group">
          <div class="device-pick-group-title" id="device-pick-android-title">Android AVD</div>
          <div id="device-pick-android-body" class="device-pick-group-body"></div>
        </div>
      </div>
      <div id="device-pick-error" class="modal-error"></div>
      <div class="device-pick-note">${t("panels.devicePick.note")}</div>
      <div class="modal-buttons">
        <button id="device-pick-cancel" class="secondary" type="button">${t("panels.common.cancel")}</button>
        <button id="device-pick-ok" type="button" disabled>OK</button>
      </div>
    </div>
  </div>

  <script nonce="${nonce}" src="${scriptUri}"></script>
</body>
</html>`;
}
