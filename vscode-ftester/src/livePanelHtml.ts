// livePanelHtml.ts
// 独立ライブ操作パネル(livePanel.ts)の webview HTML 生成。CSP・nonce の作り方は monitorHtml.ts と
// 同一。スタイルは media/monitor/style.css を共用する(#panel-live 系の CSS は全てそちらにあり、
// このパネル専用の CSS は無い)。本文は monitorHtml.ts の #panel-live ブロックと同一(id は同じ
// 前提で liveTab.js が参照するため変更しないこと)。

import { randomBytes } from "node:crypto";
import * as vscode from "vscode";

/** ライブ操作パネルのタイトル(VS Code タブ表示・HTML の <title> の両方で使う)。 */
export const LIVE_PANEL_TITLE = "ライブ操作";

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
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="${csp}">
<title>${LIVE_PANEL_TITLE}</title>
<link rel="stylesheet" href="${styleUri}">
</head>
<body>
  <div id="panel-live" class="tab-panel">
    <div class="toolbar">
      <label for="live-device-select">デバイス:</label>
      <select id="live-device-select"></select>
      <button id="live-btn-refresh-devices" class="secondary">デバイス一覧を更新</button>
      <span id="live-device-warning"></span>
      <span id="live-busy-label"></span>
    </div>
    <div class="toolbar live-record-row">
      <label for="live-app-profile-select">アプリプロファイル:</label>
      <select id="live-app-profile-select" title="アプリプロファイル"></select>
      <button id="live-btn-record">レコーディング開始</button>
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
            <img id="live-screenshot" alt="スクリーンショット">
            <div id="live-hover-box"></div>
            <svg id="live-drag-overlay" aria-hidden="true"><line id="live-drag-line"/><circle id="live-drag-start" r="6"/></svg>
            <div id="live-screenshot-placeholder">「更新」ボタンで画面を取得してください</div>
            <div id="live-conn-overlay">
              <div class="conn-title">⚠ デバイスに接続できません</div>
              <div class="conn-note">表示中の画面は最後に取得した状態です</div>
              <div id="live-conn-detail"></div>
            </div>
            <div id="live-busy-overlay">
              <div id="live-busy-spinner"></div>
              <div id="live-busy-message"></div>
            </div>
          </div>
        </div>
        <div class="screenshot-actions" id="live-screenshot-actions">
          <button id="live-btn-home" class="secondary" title="ホーム画面に戻ります">ホーム</button>
          <button id="live-btn-app-switcher" class="secondary" title="アプリスイッチャー(タスク一覧)を開きます">タスク切替</button>
        </div>
      </div>

      <div class="control-pane">
        <div class="live-lists">
          <div class="live-elements-section" id="live-elements-section">
            <div class="elements-header">
              <span>要素一覧(クリックでタップ)</span>
              <button id="live-btn-refresh-snapshot" class="secondary" title="要素一覧とタップ座標を現在の画面で取り直します。映像は自動更新されますが、操作なしで画面が変わった直後(非同期ロード・端末を直接操作など)に押すと要素一覧を拾い直せます。">要素一覧を更新</button>
            </div>
            <div id="live-elements-list" class="elements-list"></div>
            <div class="row live-type-row">
              <input id="live-type-text" type="text" placeholder="入力するテキスト(Enterで送信)">
            </div>
          </div>
          <div class="splitter" id="live-lists-splitter" title="ドラッグで要素一覧と操作記録の高さを調整"></div>
          <div class="live-oplog-section">
            <div class="oplog-header">
              <span>操作記録</span>
              <button id="live-btn-oplog-clear" class="secondary" type="button">クリア</button>
            </div>
            <div id="live-oplog-list" class="oplog-list"></div>
          </div>
        </div>
      </div>
    </div>
  </div>

  <!-- ライブ操作の画像上で右クリック。開始/終了の活性は liveTab.js が録画状態に応じて切替(#live-btn-record と同ロジック)。 -->
  <div id="live-record-menu" class="device-op-menu" role="menu">
    <button id="live-record-menu-start" class="device-op-menu-item" type="button" role="menuitem">レコーディング開始</button>
    <button id="live-record-menu-stop" class="device-op-menu-item" type="button" role="menuitem">レコーディング終了</button>
  </div>

  <script nonce="${nonce}" src="${scriptUri}"></script>
</body>
</html>`;
}
