// monitorHtml.ts
// デバイスモニターパネル(monitorPanel.ts)の webview HTML 生成部分。generateNonce()/renderHtml()
// (+ その中で参照する PANEL_TITLE)を持つ。webview 資産(スタイル・スクリプト)自体は
// src/webview/monitor/{style.css,main.js} に分離されており、esbuild が
// media/monitor/ にバンドルしたものを renderHtml() が webview.asWebviewUri で読み込む。
// HTML 本文はタブ/セクション単位の render*() ヘルパーに分割されており、renderHtml() は
// CSP/nonce の組み立てと各ヘルパーの連結だけを行う。

import { randomBytes } from "node:crypto";
import * as vscode from "vscode";
import { currentLocale, t } from "./i18n";

/** デバイスモニターパネルのタイトル(VS Code タブ表示・HTML の <title> の両方で使う)。 */
export const PANEL_TITLE = "fleetest mobile";

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
  ${renderTabBar()}

  ${renderDevicesPanel()}

  ${renderProfilesPanel()}

  ${renderRecordingsPanel()}

  ${renderProcessesPanel()}

  ${renderSettingsPanel()}

  ${renderDeviceOpMenu()}

  ${renderMachineDeviceMenu()}

  ${renderDevicePickDeleteMenu()}

  ${renderDeviceAddOverlay()}
  ${renderDeviceBatchOverlay()}

  ${renderNameInputOverlay()}

  ${renderDevicePickOverlay()}

  <script nonce="${nonce}" src="${scriptUri}"></script>
</body>
</html>`;
}

function renderTabBar(): string {
  return `<div id="tabbar" role="tablist">
    <button id="tab-devices" class="tab-button active" type="button" role="tab" aria-selected="true" aria-controls="panel-devices">${t("panels.tabs.devices")}</button>
    <button id="tab-profiles" class="tab-button" type="button" role="tab" aria-selected="false" aria-controls="panel-profiles">${t("panels.tabs.profiles")}</button>
    <button id="tab-recordings" class="tab-button" type="button" role="tab" aria-selected="false" aria-controls="panel-recordings">${t("panels.tabs.recordings")}</button>
    <button id="tab-processes" class="tab-button" type="button" role="tab" aria-selected="false" aria-controls="panel-processes">${t("panels.tabs.processes")}</button>
    <button id="tab-settings" class="tab-button" type="button" role="tab" aria-selected="false" aria-controls="panel-settings">${t("panels.tabs.settings")}</button>
    <!-- 更新があるときだけ現れるボタン(タブの並びの直後。タブに関係なく常に見える)。
         押すと設定タブへ切り替える。対向: settingsTab.js -->
    <button id="tabbar-update" class="tabbar-update" type="button" style="display: none;">${t("panels.settings.updateRunButton")}</button>
  </div>`;
}

function renderDevicesPanel(): string {
  return `<div id="panel-devices" class="tab-panel" role="tabpanel" aria-labelledby="tab-devices">
    <div id="toolbar" class="toolbar">
      <label class="profile-label">${t("panels.common.runProfile")}
        <select id="profile-select" title="${t("panels.toolbar.runProfileSelectTitle")}" disabled></select>
      </label>
      <button id="btn-devices-up">${t("panels.toolbar.startAllDevices")}</button>
      <button id="btn-devices-down" class="secondary">${t("panels.toolbar.stopAll")}</button>
      <button id="btn-restart" class="secondary">${t("panels.toolbar.restartMonitor")}</button>
      <!-- hostMetricsメッセージ受信のたびにmain.js側で再描画(独自タイマーなし)。
           **リモート機のぶんは行が増える**(hostCharts.js が data-machine="" の行を複製する)ので、
           行の中身は data-metric で引く(id は手元の行にしか無い)。 -->
      <div id="host-metrics" class="host-metrics">
        <div class="hm-row" data-machine="">
          <!-- リモートの行があるときだけ出す(.host-metrics.hm-multi)。手元は "local" 固定 -->
          <span class="hm-machine">local</span>
          <span class="host-metric" id="hm-mem" data-metric="mem" title="${t("panels.hostMetrics.memTitle")}"><span class="hm-label">MEM</span><canvas class="hm-canvas" width="72" height="22"></canvas><span class="hm-value">–</span></span>
          <span class="host-metric" id="hm-cpu" data-metric="cpu" title="${t("panels.hostMetrics.cpuTitle")}"><span class="hm-label">CPU</span><canvas class="hm-canvas" width="72" height="22"></canvas><span class="hm-value">–</span></span>
          <span class="host-metric" id="hm-gpu" data-metric="gpu" title="${t("panels.hostMetrics.gpuTitle")}"><span class="hm-label">GPU</span><canvas class="hm-canvas" width="72" height="22"></canvas><span class="hm-value">–</span></span>
          <span class="host-metric" id="hm-fm" data-metric="fm" title="${t("panels.hostMetrics.fmTitle")}"><span class="hm-label">FM</span><canvas class="hm-canvas" width="72" height="22"></canvas><span class="hm-value">–</span></span>
        </div>
      </div>
      <!-- グラフの右・ツールバー右端の2つ。左が全選択トグル・右が高さの自動調整。
           **どちらもタイルの見え方を操るので1つのグループに入れる**(枠の中でだけ隣接させ、
           ツールバーの他のボタンとは gap で切る)。
           **title/aria-label は webview 側(deviceTiles.js)が入れる** —— 押すたびに
           「すべて選択」⇄「すべて解除」で入れ替わるので、静的 HTML に置くと二重管理になる。 -->
      <div id="toolbar-tail" class="toolbar-icon-group toolbar-tail-start">
        <button id="btn-select-all" class="icon-button" type="button" aria-pressed="false"><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path fill-rule="evenodd" d="M1 2h14v12H1V2zm1 1v10h12V3H2z"/><path d="M7 11.4 3.9 8.3l.9-.9L7 9.6l4.2-4.2.9.9z"/></svg></button>
        <!-- ON の間、タイル高さを「全デバイスが横幅にちょうど収まる」高さへ自動調整する
             (状態と再計算契機は splitter.js)。左右の縁へ向かう両矢印の自作SVG。 -->
        <button id="btn-auto-fit" class="icon-button toolbar-auto-fit" type="button" aria-pressed="false" title="${t("panels.toolbar.autoFitTitle")}"><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M1 3h1v10H1zM14 3h1v10h-1zM5 7.5h6v1H5zM6 5.5L3 8l3 2.5zM13 8l-3-2.5v5z"/></svg></button>
      </div>
    </div>
    <div id="banner" class="banner"></div>

    <div id="tile-pane" class="tile-pane">
      <div id="grid" class="grid"></div>
      <div id="empty" class="empty">${t("panels.devices.emptyMessage")}</div>
      <!-- 範囲選択の矩形(ドラッグ中だけ deviceTiles.js が位置と大きさを書く) -->
      <div id="tile-marquee" class="tile-marquee"></div>
    </div>

    <div id="splitter" class="splitter" role="separator" aria-orientation="horizontal" aria-label="${t("panels.devices.splitterAriaLabel")}"></div>

    <div id="output-pane" class="output-pane">
      <div class="lanes-header">
        <span id="lanes-title" class="lanes-title">${t("panels.common.runLog")}</span>
        <span id="lanes-selection-status"></span>
        <span id="lanes-run-status"></span>
      </div>
      <div id="lanes-placeholder" class="lanes-placeholder">${t("panels.devices.lanesPlaceholder")}</div>
      <div id="lanes-grid" class="lanes-grid" style="display: none;"></div>
    </div>
  </div>`;
}

// 該当セクションへスクロールするインラインリンク(クリック処理は tabs.js が
// .profile-jump-link 一括で張る)。label の中に置くが、interactive content なので
// label の for による転送は起きない(HTML 仕様。押しても select にフォーカスは移らない)。
function profileJumpLink(targetId: string, label: string): string {
  return `<button type="button" class="profile-jump-link" data-target="${targetId}">${label}</button>`;
}

function renderRunProfileSection(): string {
  return `<div id="run-profile-section" class="profile-section run-profile-section">
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
        <!-- 確定/キャンセルはフォーム末尾ではなく sticky なツールバーに置く(フォームが長く
             スクロールしないと届かないため)。エラーもボタンの隣でないと押下時に見えない。 -->
        <div class="profile-toolbar-buttons">
          <button id="run-profile-confirm" type="button" disabled>${t("panels.common.confirm")}</button>
          <button id="run-profile-cancel" class="secondary" type="button" style="display: none;">${t("panels.common.cancel")}</button>
          <span id="run-profile-error" class="modal-error profile-toolbar-error"></span>
        </div>
      </div>
      <div id="run-profile-body" class="run-profile-body">
        <div id="run-profile-placeholder" class="profile-detail-placeholder" style="display: none;"></div>
        <div id="run-profile-editor" class="run-profile-editor" style="display: none;">
          <div class="modal-row">
            <label for="run-profile-app">${t("panels.runProfile.appLabel", {
              link: profileJumpLink("app-profile-section", t("panels.common.appProfile")),
            })}</label>
            <select id="run-profile-app"></select>
          </div>
          <div class="modal-row">
            <label for="run-profile-machine">${t("panels.runProfile.machineLabel", {
              link: profileJumpLink("machine-profile-section", t("panels.common.machineProfile")),
            })}</label>
            <select id="run-profile-machine"></select>
          </div>
          <div class="modal-row run-profile-devices-row">
            <label>${t("panels.common.devices")}</label>
            <div id="run-profile-devices" class="run-profile-devices"></div>
          </div>
          <div class="run-profile-section-group">
            <div class="run-profile-section-title">${t("panels.runProfile.fmSectionTitle")}</div>
            <div class="modal-row profile-checkbox-row">
              <input type="checkbox" id="run-profile-fm">
              <label for="run-profile-fm">${t("panels.runProfile.fmLabel")}</label>
            </div>
            <div id="run-profile-fm-options" class="run-profile-fm-options" style="display: none;">
              <div class="modal-row profile-checkbox-row">
                <input type="checkbox" id="run-profile-heal">
                <label for="run-profile-heal">${t("panels.runProfile.healLabel")}</label>
              </div>
              <div class="modal-row profile-checkbox-row">
                <input type="checkbox" id="run-profile-screen-looks-like">
                <label for="run-profile-screen-looks-like">${t("panels.runProfile.screenLooksLikeLabel")}</label>
              </div>
              <div class="modal-row profile-checkbox-row">
                <input type="checkbox" id="run-profile-false-positive-check">
                <label for="run-profile-false-positive-check">${t("panels.runProfile.falsePositiveCheckLabel")}</label>
              </div>
            </div>
          </div>
          <div class="run-profile-section-group">
            <div class="run-profile-section-title">${t("panels.runProfile.recordSectionTitle")}</div>
            <div class="modal-row profile-checkbox-row">
              <input type="checkbox" id="run-profile-record">
              <label for="run-profile-record">${t("panels.runProfile.recordLabel")}</label>
            </div>
            <div id="run-profile-record-options" class="run-profile-record-options" style="display: none;">
              <div class="modal-row profile-checkbox-row">
                <input type="checkbox" id="run-profile-record-failures-only">
                <label for="run-profile-record-failures-only">${t("panels.runProfile.recordFailuresOnlyLabel")}</label>
              </div>
              <div class="modal-row">
                <label for="run-profile-record-bitrate">${t("panels.runProfile.recordBitrateLabel")}</label>
                <input type="text" id="run-profile-record-bitrate" placeholder="1500">
              </div>
              <div class="modal-row profile-checkbox-row">
                <input type="checkbox" id="run-profile-record-full-resolution">
                <label for="run-profile-record-full-resolution">${t("panels.runProfile.recordFullResolutionLabel")}</label>
              </div>
            </div>
          </div>
          <div class="run-profile-section-group">
            <div class="run-profile-section-title">${t("panels.runProfile.iosSectionTitle")}</div>
            <div class="modal-row profile-checkbox-row">
              <input type="checkbox" id="run-profile-ios-inapp-engine">
              <label for="run-profile-ios-inapp-engine">${t("panels.runProfile.inappEngineLabel")}</label>
            </div>
            <div class="modal-row profile-checkbox-row">
              <input type="checkbox" id="run-profile-ios-fast-input">
              <label for="run-profile-ios-fast-input">${t("panels.runProfile.iosFastInputLabel")}</label>
            </div>
          </div>
          <div class="run-profile-section-group">
            <div class="run-profile-section-title">${t("panels.runProfile.androidSectionTitle")}</div>
            <div class="modal-row profile-checkbox-row">
              <input type="checkbox" id="run-profile-recover-cpu-fallback">
              <label for="run-profile-recover-cpu-fallback">${t("panels.runProfile.recoverCpuFallbackLabel")}</label>
            </div>
            <div class="modal-row profile-checkbox-row">
              <input type="checkbox" id="run-profile-update-webview">
              <label for="run-profile-update-webview">${t("panels.runProfile.updateWebViewLabel")}</label>
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
          </div>
          <div class="run-profile-section-group">
            <div class="run-profile-section-title">${t("panels.runProfile.remoteControlSectionTitle")}</div>
            <div class="modal-row">
              <label for="run-profile-workspace">${t("panels.runProfile.workspaceLabel")}</label>
              <input type="text" id="run-profile-workspace">
            </div>
            <div class="modal-row profile-hint">${t("panels.runProfile.workspaceHint")}</div>
            <div class="modal-row">
              <button id="btn-run-profile-hook-scaffold" class="secondary" type="button">${t("panels.runProfile.hookScaffoldButton")}</button>
            </div>
          </div>
          <div class="run-profile-section-group">
            <div class="run-profile-section-title">${t("panels.runProfile.miscSectionTitle")}</div>
            <div class="modal-row profile-checkbox-row">
              <input type="checkbox" id="run-profile-home-on-start">
              <label for="run-profile-home-on-start">${t("panels.runProfile.homeOnStartLabel")}</label>
            </div>
            <div class="modal-row profile-checkbox-row">
              <input type="checkbox" id="run-profile-enable-animations">
              <label for="run-profile-enable-animations">${t("panels.runProfile.enableAnimationsLabel")}</label>
            </div>
            <div class="modal-row profile-checkbox-row">
              <input type="checkbox" id="run-profile-container-inference">
              <label for="run-profile-container-inference">${t("panels.runProfile.containerInferenceLabel")}</label>
            </div>
            <div class="modal-row">
              <label for="run-profile-default-timeout">defaultTimeout</label>
              <input type="text" id="run-profile-default-timeout">
            </div>
            <div class="modal-row">
              <label for="run-profile-report-dir">reportDir</label>
              <input type="text" id="run-profile-report-dir" placeholder="reports">
            </div>
          </div>
        </div>
      </div>
    </div>`;
}

function renderAppProfileSection(): string {
  return `<div id="app-profile-section" class="profile-section app-profile-section">
      <div class="profile-toolbar">
        <span class="profile-toolbar-title">${t("panels.common.appProfile")}</span>
        <select id="app-profile-select" style="display: none;"></select>
        <span id="app-profile-name-static" class="machine-name-static" style="display: none;">${t("panels.appProfile.noneSelected")}</span>
        <button id="btn-app-profile-add" class="icon-button" title="${t("panels.appProfile.addTitle")}" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M14 7v1H8v6H7V8H1V7h6V1h1v6h6z"/></svg></button>
        <button id="btn-app-profile-copy" class="icon-button" title="${t("panels.appProfile.copyTitle")}" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M4 4l1-1h5.414L14 6.586V14l-1 1H5l-1-1V4zm9 3l-3-3H5v10h8V7zM3 1L2 2v10l1 1V2h6.414l-1-1H3z"/></svg></button>
        <button id="btn-app-profile-remove" class="icon-button" title="${t("panels.appProfile.removeTitle")}" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M15 8H1V7h14v1z"/></svg></button>
        <button id="btn-app-profile-rename" class="icon-button" title="${t("panels.appProfile.renameTitle")}" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M13.23 1h-1.46L3.52 9.25l-.16.22L1 13.59 2.41 15l4.12-2.36.22-.16L15 4.23V2.77L13.23 1zM2.41 13.59l1.51-3 1.45 1.45-2.96 1.55zm3.83-2.06L4.47 9.76l8-8 1.77 1.77-8 8z"/></svg></button>
        <div class="profile-toolbar-buttons">
          <button id="app-profile-confirm" type="button" disabled>${t("panels.common.confirm")}</button>
          <button id="app-profile-cancel" class="secondary" type="button" style="display: none;">${t("panels.common.cancel")}</button>
          <span id="app-profile-error" class="modal-error profile-toolbar-error"></span>
        </div>
      </div>
      <div id="app-profile-body" class="app-profile-body">
        <div id="app-profile-placeholder" class="profile-detail-placeholder" style="display: none;"></div>
        <div id="app-profile-editor" class="app-profile-editor" style="display: none;">
          <!-- common.app/appPath/appNameは廃止済み(ランタイムが無視するため入力欄なし。表示名は
               ios/androidのみで指定し、commonからは継承しない)。
               autoInstallは共通でのみ設定可能。**未指定の既定はパッケージパスの有無**
               (RunProfile.swift の resolve と同期。片方だけ変えない)。 -->
          <div class="app-profile-group-title">${t("panels.appProfile.commonGroupTitle")}</div>
          <div class="modal-row profile-checkbox-row">
            <input type="checkbox" id="app-profile-common-auto-install">
            <label for="app-profile-common-auto-install">${t("panels.appProfile.autoInstallLabel")}</label>
          </div>
          <div class="modal-row profile-hint">${t("panels.appProfile.autoInstallHint")}</div>

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
          <!-- 実機に配るビルドは iOS だけ別物(シミュレータ用は未署名で実機に入らない)。
               Android は同じ APK が両方で動くため欄を置かない(RunProfile.swift の
               AppProfileSection.appPathPhysical と同期。片方だけ変えない)。 -->
          <div class="modal-row">
            <label for="app-profile-ios-app-path-physical">${t("panels.appProfile.packagePathPhysicalLabel")}</label>
            <input type="text" id="app-profile-ios-app-path-physical">
          </div>
          <div class="modal-row profile-hint">${t("panels.appProfile.packagePathPhysicalHint")}</div>

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

        </div>
      </div>
    </div>`;
}

function renderMachineProfileSection(): string {
  return `<div id="machine-profile-section" class="profile-section">
      <div class="profile-toolbar">
        <span class="profile-toolbar-title">${t("panels.common.machineProfile")}</span>
        <select id="machine-select" style="display: none;"></select>
        <span id="machine-name-static" class="machine-name-static" style="display: none;"></span>
        <button id="btn-machine-add" class="icon-button" title="${t("panels.machineProfile.addTitle")}" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M14 7v1H8v6H7V8H1V7h6V1h1v6h6z"/></svg></button>
        <button id="btn-machine-copy" class="icon-button" title="${t("panels.machineProfile.copyTitle")}" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M4 4l1-1h5.414L14 6.586V14l-1 1H5l-1-1V4zm9 3l-3-3H5v10h8V7zM3 1L2 2v10l1 1V2h6.414l-1-1H3z"/></svg></button>
        <button id="btn-machine-remove" class="icon-button" title="${t("panels.machineProfile.removeTitle")}" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M15 8H1V7h14v1z"/></svg></button>
        <button id="btn-machine-rename" class="icon-button" title="${t("panels.machineProfile.renameTitle")}" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M13.23 1h-1.46L3.52 9.25l-.16.22L1 13.59 2.41 15l4.12-2.36.22-.16L15 4.23V2.77L13.23 1zM2.41 13.59l1.51-3 1.45 1.45-2.96 1.55zm3.83-2.06L4.47 9.76l8-8 1.77 1.77-8 8z"/></svg></button>
        <div class="profile-toolbar-buttons">
          <button id="editor-confirm" type="button" disabled>${t("panels.common.confirm")}</button>
          <button id="editor-cancel" class="secondary" type="button" style="display: none;">${t("panels.common.cancel")}</button>
          <span id="editor-error" class="modal-error profile-toolbar-error"></span>
        </div>
      </div>
      <div class="profile-actions">
        <!-- 「+新規作成」ボタンは廃止済み。新規作成は#device-pick-overlayの各グループ見出しの「+」から行う。 -->
        <span class="profile-actions-label">${t("panels.machineProfile.addDevicesLabel")}</span>
        <button id="btn-device-add-existing" class="icon-button" title="${t("panels.machineProfile.addExistingTitle")}" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M14 7v1H8v6H7V8H1V7h6V1h1v6h6z"/></svg></button>
      </div>
      <div id="machine-profile-error" class="profile-error" style="display: none;"></div>
      <div id="machine-profile-body" class="profile-body">
        <div id="machine-device-list" class="machine-device-list"></div>
        <div id="machine-device-detail-pane" class="machine-device-detail-pane">
          <div id="profile-detail-placeholder" class="profile-detail-placeholder">${t("panels.machineProfile.selectPrompt")}</div>
          <div id="machine-device-editor" class="machine-device-editor" style="display: none;">
            <div class="machine-device-editor-header">
              <!-- 実機バッジはデバイス名の左(ピッカー・一覧・タイルと同じ並び) -->
              <span id="editor-device-kind" class="editor-kind-badge" style="display: none;">${t("monitor.device.physicalBadge")}</span>
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
            <!-- 実機の機種/OS。登録時に控えた表示専用の値(model/os)で、実体の同定には使わない。
                 platform セクションの外に置き iOS/Android 共通で使う -->
            <div id="editor-physical-fields" style="display: none;">
              <div class="modal-row" id="editor-model-row">
                <label>${t("panels.machineProfile.modelLabel")}</label>
                <span id="editor-model" class="editor-readonly-value" title="${t("panels.machineProfile.physicalInfoReadonlyTitle")}"></span>
              </div>
              <div class="modal-row" id="editor-physical-os-row">
                <label>OS</label>
                <span id="editor-physical-os" class="editor-readonly-value" title="${t("panels.machineProfile.physicalInfoReadonlyTitle")}"></span>
              </div>
            </div>
            <div id="editor-ios-fields">
              <div class="modal-row" id="editor-simulator-row">
                <label>${t("panels.machineProfile.modelLabel")}</label>
                <span id="editor-simulator" class="editor-readonly-value" title="${t("panels.machineProfile.modelReadonlyTitle")}"></span>
              </div>
              <div class="modal-row" id="editor-os-row">
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
              <div class="modal-row" id="editor-avd-row">
                <label>AVD</label>
                <span id="editor-avd" class="editor-readonly-value" title="${t("panels.machineProfile.avdReadonlyTitle")}"></span>
              </div>
              <!-- 実機のみ。AVD と同じく実体を指す属性なので readonly 表示 -->
              <div class="modal-row" id="editor-serial-row" style="display: none;">
                <label>serial</label>
                <span id="editor-serial" class="editor-readonly-value" title="${t("panels.machineProfile.serialReadonlyTitle")}"></span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>`;
}

function renderProfilesPanel(): string {
  return `<div id="panel-profiles" class="tab-panel" role="tabpanel" aria-labelledby="tab-profiles" style="display: none;">
    ${renderRunProfileSection()}

    ${renderMachineProfileSection()}

    ${renderAppProfileSection()}
  </div>`;
}

function renderProcessesPanel(): string {
  return `<div id="panel-processes" class="tab-panel" role="tabpanel" aria-labelledby="tab-processes" style="display: none;">
    <div class="processes-body">
      <div class="processes-title">${t("panels.processes.title")}</div>
      <div id="resident-updated" class="resident-updated"></div>
      <div class="resident-toolbar">
        <button id="resident-kill-close" class="resident-danger" type="button">${t("panels.processes.killAllAndClose")}</button>
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
  </div>`;
}

function renderRecordingsPanel(): string {
  return `<div id="panel-recordings" class="tab-panel" role="tabpanel" aria-labelledby="tab-recordings" style="display: none;">
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
        <!-- 実行マシン(run.json の machine)。**束ねたセッションでは複数**入るので、これは
             バッジそのものではなくバッジの入れ物(recordingsTab.js が中身と表示を切り替える) -->
        <span id="recordings-session-machine" class="recordings-session-machines" style="display: none;"></span>
      </div>
      <div class="recordings-body">
        <div class="recordings-video-pane">
          <video id="recordings-video" class="recordings-video" playsinline></video>
          <div class="recordings-now-playing">
            <!-- 再生中のシナリオを撮った台(index.json の worker)。空なら非表示 -->
            <div id="recordings-now-playing-device" class="recordings-now-playing-device" style="display: none;"></div>
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
            <label class="recordings-auto-advance">
              <input type="checkbox" id="recordings-auto-advance">
              ${t("panels.recordings.autoAdvanceLabel")}
            </label>
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
  </div>`;
}

function renderSettingsPanel(): string {
  return `<div id="panel-settings" class="tab-panel" role="tabpanel" aria-labelledby="tab-settings" style="display: none;">
    <div class="settings-body">
      <!-- 更新セクション。判定は Scripts/update-check.sh、取り込みは Scripts/update.sh
           (拡張は実行して結果を出すだけ)。対向: settingsTab.js / monitorUpdateController.ts -->
      <div class="settings-group">
        <div class="settings-section-title">${t("panels.settings.updateLabel")}</div>
        <div class="settings-update-statusline">
          <span id="settings-update-spinner" class="settings-update-spinner" style="display: none;" aria-hidden="true"></span>
          <span id="settings-update-status" class="settings-update-status">${t("panels.settings.updateChecking")}</span>
        </div>
        <div class="settings-update-actions">
          <button id="settings-update-check" class="secondary" type="button">${t("panels.settings.updateCheckButton")}</button>
        </div>
      </div>
      <div class="settings-group">
        <label class="settings-section-title" for="settings-language">${t("panels.settings.languageLabel")}</label>
        <select id="settings-language" class="settings-select">
          <option value="auto">${t("panels.settings.languageAuto")}</option>
          <option value="ja">${t("panels.settings.languageJa")}</option>
          <option value="en">${t("panels.settings.languageEn")}</option>
        </select>
      </div>
      <div class="settings-group">
        <div class="settings-section-title">${t("panels.settings.schedulingSectionTitle")}</div>
        <label class="settings-item"><input type="checkbox" id="settings-lpt"> ${t("panels.settings.lptSchedulingLabel")}</label>
        <div class="settings-hint">${t("panels.settings.lptSchedulingHint")}</div>
        <label class="settings-item settings-item-inline" for="settings-lpt-history">
          ${t("panels.settings.lptHistoryRunsLabel")}
          <input type="number" id="settings-lpt-history" class="settings-number" min="1" step="1">
        </label>
      </div>
      <div class="settings-group">
        <div class="settings-section-title">${t("panels.settings.deviceScreenSectionTitle")}</div>
        <label class="settings-item"><input type="checkbox" id="settings-polling-mode"> ${t("panels.settings.pollingModeLabel")}</label>
        <div class="settings-hint">${t("panels.settings.pollingModeHint")}</div>
      </div>
      <!-- 実機だけに効く設定。対向: settingsTab.js の applySettings / setKeepPhysicalDevicesAwake、
           拡張側は monitorPanel.ts(fleetest.suppressPhysicalDeviceAutoLock 設定を更新する)。
           シミュレータ・エミュレータには効かない(自動ロックが無い/エミュレータは対象外)。 -->
      <div class="settings-group">
        <div class="settings-section-title">${t("panels.settings.physicalSectionTitle")}</div>
        <label class="settings-item"><input type="checkbox" id="settings-keep-awake"> ${t("panels.settings.keepAwakeLabel")}</label>
        <div class="settings-hint">${t("panels.settings.keepAwakeHint")}</div>
      </div>
      <!-- 実体は CLI のホスト登録簿("fleetest api remote-hosts")+ fleetest.remote.artifacts 設定
           (config.ts)。ここはもう1つの操作口(docs/remote-runner.md §12)。ホスト一覧
           (#settings-remote-hosts-body)は行数が可変のため settingsTab.js が動的に組み立てる。
           「追加」で足した行は name/host が埋まって行内の「確定」ボタンを押すまで CLI へ送らない
           (未確定のまま送ると空の name を CLI が拒否し、失敗経路が旧一覧を再送して行が消える)。
           artifacts セレクタは remoteConfig/setRemoteConfig に相乗り(専用メッセージ型は無い)。
           #settings-remote-hosts-error は直前の同期が失敗したときの理由(remoteConfig.error)。
           対向: settingsTab.js の applySettings / setRemoteConfig, monitorPanel.ts。 -->
      <div class="settings-group">
        <div class="settings-section-title">${t("panels.settings.remoteSectionTitle")}</div>
        <label class="settings-item settings-item-inline" for="settings-remote-artifacts">
          ${t("panels.settings.remoteArtifactsLabel")}
          <select id="settings-remote-artifacts" class="settings-select">
            <option value="collect">${t("panels.settings.remoteArtifactsCollect")}</option>
            <option value="on-demand">${t("panels.settings.remoteArtifactsOnDemand")}</option>
          </select>
        </label>
        <div class="settings-remote-hosts-actions">
          <button id="settings-remote-hosts-add" class="secondary" type="button">${t("panels.settings.remoteHostsAdd")}</button>
        </div>
        <table class="settings-remote-hosts-table">
          <thead>
            <tr>
              <th>${t("panels.settings.remoteHostsColHost")}</th>
              <th>${t("panels.settings.remoteHostsColMachine")}</th>
              <th>${t("panels.settings.remoteHostsColDir")}</th>
              <th></th>
            </tr>
          </thead>
          <tbody id="settings-remote-hosts-body"></tbody>
        </table>
        <div id="settings-remote-hosts-error" class="settings-hint settings-remote-hosts-error" hidden></div>
      </div>
    </div>
  </div>`;
}

function renderDeviceOpMenu(): string {
  return `<!-- アイコンはcodicon "vm-running"/"play"/"debug-stop"のインラインSVG。
       #device-op-menu-itemはup/down両方のアイコンを持ち、data-op(deviceTiles.jsが設定)でCSS表示切替。 -->
  <div id="device-op-menu" class="device-op-menu" role="menu">
    <button id="device-op-menu-live" class="device-op-menu-item" type="button" role="menuitem"><svg class="op-icon" width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path fill-rule="evenodd" clip-rule="evenodd" d="M6.607 14C6.79 14.357 7.017 14.689 7.275 15H3.5C3.224 15 3 14.776 3 14.5C3 14.224 3.224 14 3.5 14H5V12H3C1.895 12 1 11.105 1 10V3C1 1.895 1.895 1 3 1H13C14.105 1 15 1.895 15 3V7.293C14.69 7.036 14.357 6.816 14 6.633V3C14 2.448 13.552 2 13 2H3C2.448 2 2 2.448 2 3V10C2 10.552 2.448 11 3 11H6.024C5.994 11.332 6.004 11.666 6.034 12H6V14H6.607ZM16 11.5C16 12.39 15.736 13.26 15.242 14C14.748 14.74 14.045 15.317 13.222 15.657C12.4 15.998 11.495 16.087 10.622 15.913C9.749 15.739 8.947 15.311 8.318 14.681C7.689 14.052 7.26 13.25 7.086 12.377C6.912 11.504 7.001 10.599 7.342 9.777C7.683 8.955 8.259 8.252 8.999 7.757C9.739 7.264 10.609 7 11.499 7C12.692 7 13.837 7.474 14.681 8.318C15.525 9.162 16 10.307 16 11.5ZM13.97 11.499C13.97 11.41 13.946 11.323 13.901 11.246C13.856 11.17 13.791 11.106 13.713 11.063L10.743 9.413C10.667 9.371 10.581 9.349 10.494 9.35C10.407 9.351 10.322 9.375 10.247 9.419C10.171 9.463 10.109 9.526 10.066 9.602C10.023 9.677 10 9.763 10 9.85V13.15C10 13.237 10.023 13.322 10.066 13.398C10.11 13.474 10.172 13.537 10.247 13.581C10.322 13.625 10.407 13.649 10.494 13.65C10.581 13.65 10.667 13.629 10.743 13.587L13.713 11.937C13.791 11.892 13.856 11.829 13.901 11.752C13.946 11.676 13.97 11.588 13.97 11.499Z"/></svg><span>${t("panels.deviceMenu.liveControl")}</span></button>
    <button id="device-op-menu-item" class="device-op-menu-item" type="button" role="menuitem"><svg class="op-icon op-icon-up" width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M4.74514 3.06414C4.41183 2.87665 4 3.11751 4 3.49993V12.5002C4 12.8826 4.41182 13.1235 4.74512 12.936L12.7454 8.43601C13.0852 8.24486 13.0852 7.75559 12.7454 7.56443L4.74514 3.06414ZM3 3.49993C3 2.35268 4.2355 1.63011 5.23541 2.19257L13.2357 6.69286C14.2551 7.26633 14.2551 8.73415 13.2356 9.30759L5.23537 13.8076C4.23546 14.37 3 13.6474 3 12.5002V3.49993Z"/></svg><svg class="op-icon op-icon-down" width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M12.5 3.5V12.5H3.5V3.5H12.5ZM12.5 2H3.5C2.672 2 2 2.672 2 3.5V12.5C2 13.328 2.672 14 3.5 14H12.5C13.328 14 14 13.328 14 12.5V3.5C14 2.672 13.328 2 12.5 2Z"/></svg><span id="device-op-menu-item-label"></span></button>
    <!-- CPU 描画フォールバックを解除して host GPU で再起動。deviceTiles.js が CPU バッジのタイルでのみ表示。 -->
    <button id="device-op-menu-gpu" class="device-op-menu-item" type="button" role="menuitem"><svg class="op-icon" width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M4.681 3H2V2h3.5l.5.5V6H5V4a5 5 0 1 0 4.53-.635l.418-.909A6 6 0 1 1 4.681 3z"/></svg><span>${t("panels.deviceMenu.restartWithGpu")}</span></button>
    <!-- ここから下はデバイスに紐づかない項目(空きエリアの右クリックでも出る)。区切りは
         上のデバイス項目が1つでも出ているときだけ deviceTiles.js が表示する。 -->
    <div id="device-op-menu-sep" class="device-op-menu-sep"></div>
    <button id="device-op-menu-select-all" class="device-op-menu-item" type="button" role="menuitem"><svg class="op-icon" width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M2 2h12v12H2V2zm1 1v10h10V3H3z"/><path d="M6.9 11.2 4 8.3l.7-.7 2.2 2.2 4.4-4.4.7.7-5.1 5.1z"/></svg><span>${t("panels.deviceMenu.selectAll")}</span></button>
    <button id="device-op-menu-deselect-all" class="device-op-menu-item" type="button" role="menuitem"><svg class="op-icon" width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M2 2h12v12H2V2zm1 1v10h10V3H3z"/></svg><span>${t("panels.deviceMenu.deselectAll")}</span></button>
  </div>`;
}

function renderMachineDeviceMenu(): string {
  return `<!-- #device-op-menuとスタイルのみ共用する別要素。「除去」はプロファイルから外すだけで本体は削除しない。 -->
  <div id="machine-device-menu" class="device-op-menu" role="menu">
    <button id="machine-device-menu-item" class="device-op-menu-item" type="button" role="menuitem">${t("panels.deviceMenu.remove")}</button>
  </div>`;
}

function renderDevicePickDeleteMenu(): string {
  return `<!-- #device-op-menuとスタイルのみ共用する別要素。#device-pick-overlay の行専用。
       machineDeviceMenu の「除去」(プロファイルから外すだけ)と違い、ホスト上の実体(シミュレータ/AVD)
       そのものを fleetest api delete-device で消す(modals.js が実機行にはこのメニューを出さない)。 -->
  <div id="device-pick-delete-menu" class="device-op-menu" role="menu">
    <button id="device-pick-delete-menu-item" class="device-op-menu-item" type="button" role="menuitem">${t("panels.deviceMenu.delete")}</button>
  </div>`;
}

function renderDeviceAddOverlay(): string {
  return `<div id="device-add-overlay" class="modal-overlay">
    <div class="modal-dialog" role="dialog" aria-modal="true" aria-labelledby="device-add-title">
      <div class="modal-title device-pick-title-row">
        <span id="device-add-title">${t("panels.deviceAdd.title")}</span>
        <!-- どのホストから作成するかを常時表示(§13 段2。黙って別マシンを操作しない)。このダイアログは
             常に #device-pick-overlay の中から開くので、読み取り専用でその時点の選択(host select)を
             映すだけ(devicePickMachine.js の refreshDeviceAddBadge)。 -->
        <span id="device-add-source-badge" class="modal-hint"></span>
      </div>
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
      <!-- Android のみ。値は system-images のタグそのもの(JS が dlg-os の絞り込みに使う)。
           2択に限っているため他タグ(default = AOSP、*_atd 等)のイメージは選べない。
           選べるようにするならここに option を足すだけでよい(絞り込みはタグ一致のみ)。 -->
      <div class="modal-row" id="dlg-service-row" hidden>
        <label for="dlg-service">${t("panels.deviceAdd.servicesLabel")}</label>
        <select id="dlg-service">
          <option value="google_apis_playstore">Google Play Store</option>
          <option value="google_apis" selected>Google APIs</option>
        </select>
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
      <!-- avdmanager 不在(errorCode: "avdmanager-missing")のときだけ JS が表示する導入ボタン。
           数分かかるので押下後はラベルを進行中に変え、詳細な進捗は OUTPUT へ出す。 -->
      <div class="modal-row" id="dlg-install-row" hidden>
        <button id="dlg-install" class="secondary" type="button">${t("panels.deviceAdd.installCmdlineTools")}</button>
        <span class="modal-hint">${t("panels.deviceAdd.installCmdlineToolsHint")}</span>
      </div>
      <div class="modal-buttons">
        <!-- 左下。同じ設定(OS種別/モデル/OSバージョン)で「デバイス名-連番2桁(-01 始まり)」を一括作成する。
             件数は 1-99(min/max は JS 側でも検証する ―― number 入力は手打ちで範囲外を通す)。 -->
        <div class="modal-buttons-left">
          <button id="dlg-batch" class="secondary" type="button">${t("panels.deviceAdd.batchCreate")}</button>
          <input type="number" id="dlg-batch-count" min="1" max="99" step="1" value="2"
                 title="${t("panels.deviceAdd.batchCountTitle")}">
        </div>
        <button id="dlg-cancel" class="secondary" type="button">${t("panels.common.cancel")}</button>
        <button id="dlg-ok" type="button">OK</button>
      </div>
    </div>
  </div>`;
}

/** バッチ作成の進行ウィンドウ。「デバイスを追加」を閉じた直後に開き、1台ずつの結果を並べる。
 *  OK は全件終わるまで無効(途中で閉じると進行中の作成の行き先が無くなる)。押すと
 *  #device-pick-overlay へ戻り、作成できたデバイスに自動でチェックが入る(modals.js)。 */
function renderDeviceBatchOverlay(): string {
  return `<div id="device-batch-overlay" class="modal-overlay">
    <div class="modal-dialog" role="dialog" aria-modal="true" aria-labelledby="device-batch-title">
      <div class="modal-title" id="device-batch-title">${t("panels.deviceBatch.title")}</div>
      <div id="device-batch-status" class="modal-hint"></div>
      <div id="device-batch-list" class="device-batch-list"></div>
      <div id="device-batch-error" class="modal-error"></div>
      <div class="modal-buttons">
        <button id="device-batch-ok" type="button" disabled>OK</button>
      </div>
    </div>
  </div>`;
}

function renderNameInputOverlay(): string {
  return `<!-- 実行/アプリ/マシンプロファイルの追加・コピー・名前変更で共通利用(showInputBox相当)。
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
  </div>`;
}

function renderDevicePickOverlay(): string {
  return `<!-- 中身(#device-pick-ios-body/-android-body)はJSがinstalledDevices受信時に組み立てる。
       チェックボックスは「選択」ではなく登録状態そのもの(登録済み=初期チェック、disabled化しない)。
       OKは初期状態からの差分がある間だけ有効(JS側)。各グループ見出しの右端の「+」
       (device-pick-ios-add-new / -android-add-new)はこのモーダルを閉じずに
       #device-add-overlayを重ねて開く(z-indexは#device-add-overlayのCSSルール参照)。
       **押した見出しのOS種別で開く** — 一覧のどちら側を増やしたいかは見出しで表明済みなので、
       ダイアログでもう一度選ばせない。
       #device-pick-machine-select はこのダイアログのデバイス候補のマシン(ローカル/登録済みの
       リモートマシン)。選択肢は devicePickMachine.js が remoteConfig(設定タブと同じメッセージ)を
       購読して組み立てる。初期値はダイアログを開いたときの編集対象マシンプロファイルの machine
       フィールド(未設定ならローカル)。変更すると installed-devices を選び直したマシンから
       再取得する(modals.js の change リスナー)。 -->
  <div id="device-pick-overlay" class="modal-overlay">
    <div class="modal-dialog" role="dialog" aria-modal="true" aria-labelledby="device-pick-title">
      <div class="modal-title device-pick-title-row">
        <span id="device-pick-title">${t("panels.devicePick.title")}</span>
        <span class="device-pick-machine-group">
          <label for="device-pick-machine-select">${t("panels.devicePick.machineLabel")}</label>
          <select id="device-pick-machine-select"></select>
          <!-- ホスト切替中のインジケーター。**リストボックスの右に置く**(一覧側に出すと
               ダイアログの高さが変わって画面が跳ねる。2026-08-17 ユーザー指示) -->
          <span id="device-pick-loading" class="device-pick-loading" style="display: none;">
            <span class="device-pick-spinner"></span>
            <span>${t("panels.devicePick.loading")}</span>
          </span>
        </span>
      </div>
      <div id="device-pick-list" class="device-pick-list">
        <div id="device-pick-ios-group" class="device-pick-group">
          <!-- 見出しの文言は JS が台数付きで差し替えるので、**内側の span を名前付きにする**
               (見出し div へ直接書くと textContent の代入で「デバイスを作成 +」ごと消える)。 -->
          <div class="device-pick-group-title">
            <span id="device-pick-ios-title">${t("panels.devicePick.iosGroupTitle")}</span>
            <span class="device-pick-add-label">${t("panels.devicePick.addNewLabel")}</span>
            <button id="device-pick-ios-add-new" class="icon-button" type="button" title="${t("panels.devicePick.addNewIosTitle")}"><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M14 7v1H8v6H7V8H1V7h6V1h1v6h6z"/></svg></button>
          </div>
          <div id="device-pick-ios-body" class="device-pick-group-body"></div>
        </div>
        <div id="device-pick-android-group" class="device-pick-group">
          <div class="device-pick-group-title">
            <span id="device-pick-android-title">${t("panels.devicePick.androidGroupTitle")}</span>
            <span class="device-pick-add-label">${t("panels.devicePick.addNewLabel")}</span>
            <button id="device-pick-android-add-new" class="icon-button" type="button" title="${t("panels.devicePick.addNewAndroidTitle")}"><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M14 7v1H8v6H7V8H1V7h6V1h1v6h6z"/></svg></button>
          </div>
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
  </div>`;
}
