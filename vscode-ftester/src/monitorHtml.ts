// monitorHtml.ts
// デバイスモニターパネル(monitorPanel.ts)の webview HTML 生成部分。generateNonce()/renderHtml()
// (+ その中で参照する PANEL_TITLE)を持つ。webview 資産(スタイル・スクリプト)自体は
// src/webview/monitor/{style.css,main.js} に分離されており、esbuild が
// media/monitor/ にバンドルしたものを renderHtml() が webview.asWebviewUri で読み込む。
// HTML 本文は renderHtml() 内にインライン生成する。

import { randomBytes } from "node:crypto";
import * as vscode from "vscode";
import { DEFAULT_MAX_STEPS } from "./exploreModel";

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
    `style-src ${webview.cspSource} 'unsafe-inline'`,
    `script-src 'nonce-${nonce}'`,
  ].join("; ");

  return `<!doctype html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="${csp}">
<title>${PANEL_TITLE}</title>
<link rel="stylesheet" href="${styleUri}">
</head>
<body>
  <div id="tabbar" role="tablist">
    <button id="tab-devices" class="tab-button active" type="button" role="tab" aria-selected="true" aria-controls="panel-devices">デバイス</button>
    <button id="tab-live" class="tab-button" type="button" role="tab" aria-selected="false" aria-controls="panel-live">ライブ操作</button>
    <button id="tab-profiles" class="tab-button" type="button" role="tab" aria-selected="false" aria-controls="panel-profiles">プロファイル</button>
    <button id="tab-explore" class="tab-button" type="button" role="tab" aria-selected="false" aria-controls="panel-explore">FM探索</button>
    <button id="tab-settings" class="tab-button" type="button" role="tab" aria-selected="false" aria-controls="panel-settings">設定</button>
  </div>

  <div id="panel-devices" class="tab-panel" role="tabpanel" aria-labelledby="tab-devices">
    <div id="toolbar" class="toolbar">
      <label class="profile-label">実行プロファイル
        <select id="profile-select" title="以後のテスト実行・デバッグ実行と、このモニターの監視対象デバイスに使う実行プロファイル(ftester.profile 設定)" disabled></select>
      </label>
      <button id="btn-devices-up">デバイスを全て起動</button>
      <button id="btn-devices-down" class="secondary">全て終了</button>
      <button id="btn-restart" class="secondary">モニター再起動</button>
      <!-- hostMetricsメッセージ受信のたびにmain.js側で再描画(独自タイマーなし)。 -->
      <div id="host-metrics" class="host-metrics">
        <span class="host-metric" id="hm-mem" title="メモリ使用量"><span class="hm-label">MEM</span><canvas class="hm-canvas" width="72" height="22"></canvas><span class="hm-value">–</span></span>
        <span class="host-metric" id="hm-cpu" title="CPU負荷"><span class="hm-label">CPU</span><canvas class="hm-canvas" width="72" height="22"></canvas><span class="hm-value">–</span></span>
        <span class="host-metric" id="hm-gpu" title="GPU負荷"><span class="hm-label">GPU</span><canvas class="hm-canvas" width="72" height="22"></canvas><span class="hm-value">–</span></span>
        <span class="host-metric" id="hm-ane" title="ANE負荷"><span class="hm-label">ANE</span><canvas class="hm-canvas" width="72" height="22"></canvas><span class="hm-value">–</span></span>
      </div>
    </div>
    <div id="banner" class="banner"></div>

    <div id="tile-pane" class="tile-pane">
      <div id="grid" class="grid"></div>
      <div id="empty" class="empty">デバイス情報を待機しています(ポーリング形式のため反映まで数秒かかることがあります)...</div>
    </div>

    <div id="splitter" class="splitter" role="separator" aria-orientation="horizontal" aria-label="タイルと出力の分割境界線"></div>

    <div id="output-pane" class="output-pane">
      <div class="lanes-header">
        <span class="lanes-title">実行ログ</span>
        <span id="lanes-selection-status"></span>
        <span id="lanes-run-status"></span>
      </div>
      <div id="lanes-placeholder" class="lanes-placeholder">テストを実行するとデバイス毎の出力がここに表示されます</div>
      <div id="lanes-grid" class="lanes-grid" style="display: none;"></div>
    </div>
  </div>

  <div id="panel-profiles" class="tab-panel" role="tabpanel" aria-labelledby="tab-profiles" style="display: none;">
    <div id="profile-jump-header" class="profile-jump-header">
      <button type="button" class="profile-jump-link" data-target="run-profile-section">実行プロファイル</button>
      <button type="button" class="profile-jump-link" data-target="app-profile-section">アプリプロファイル</button>
      <button type="button" class="profile-jump-link" data-target="machine-profile-section">マシンプロファイル</button>
    </div>

    <div id="run-profile-section" class="profile-section run-profile-section">
      <div class="profile-toolbar">
        <span class="profile-toolbar-title">実行プロファイル</span>
        <select id="run-profile-select" style="display: none;"></select>
        <span id="run-profile-name-static" class="machine-name-static" style="display: none;">(実行プロファイルなし)</span>
        <!-- アイコンはcodicon "add"/"copy"/"remove"/"edit"と同一パスのインラインSVG
             (CSPで外部codiconフォントを読み込めないため。以下の各プロファイルセクションも同じ)。 -->
        <button id="btn-run-profile-add" class="icon-button" title="実行プロファイルの追加" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M14 7v1H8v6H7V8H1V7h6V1h1v6h6z"/></svg></button>
        <button id="btn-run-profile-copy" class="icon-button" title="実行プロファイルのコピー" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M4 4l1-1h5.414L14 6.586V14l-1 1H5l-1-1V4zm9 3l-3-3H5v10h8V7zM3 1L2 2v10l1 1V2h6.414l-1-1H3z"/></svg></button>
        <button id="btn-run-profile-remove" class="icon-button" title="実行プロファイルの削除" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M15 8H1V7h14v1z"/></svg></button>
        <button id="btn-run-profile-rename" class="icon-button" title="実行プロファイル名の変更" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M13.23 1h-1.46L3.52 9.25l-.16.22L1 13.59 2.41 15l4.12-2.36.22-.16L15 4.23V2.77L13.23 1zM2.41 13.59l1.51-3 1.45 1.45-2.96 1.55zm3.83-2.06L4.47 9.76l8-8 1.77 1.77-8 8z"/></svg></button>
      </div>
      <div id="run-profile-body" class="run-profile-body">
        <div id="run-profile-placeholder" class="profile-detail-placeholder" style="display: none;"></div>
        <div id="run-profile-editor" class="run-profile-editor" style="display: none;">
          <div class="modal-row">
            <label for="run-profile-machine">使用するマシンプロファイル<span class="required-badge">必須</span></label>
            <select id="run-profile-machine"></select>
          </div>
          <div class="modal-row">
            <label for="run-profile-app">アプリ</label>
            <select id="run-profile-app"></select>
          </div>
          <div class="modal-row run-profile-devices-row">
            <label>デバイス</label>
            <div id="run-profile-devices" class="run-profile-devices"></div>
          </div>
          <div class="modal-row profile-checkbox-row">
            <input type="checkbox" id="run-profile-heal">
            <label for="run-profile-heal">自己修復(heal)を有効にする</label>
          </div>
          <div class="modal-row profile-checkbox-row">
            <input type="checkbox" id="run-profile-ios-inapp-engine">
            <label for="run-profile-ios-inapp-engine">高速なinappエンジンを使用する(iOS)</label>
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
            <button id="run-profile-confirm" type="button" disabled>確定</button>
            <button id="run-profile-cancel" class="secondary" type="button" style="display: none;">キャンセル</button>
          </div>
        </div>
      </div>
    </div>

    <div id="app-profile-section" class="profile-section app-profile-section">
      <div class="profile-toolbar">
        <span class="profile-toolbar-title">アプリプロファイル</span>
        <select id="app-profile-select" style="display: none;"></select>
        <span id="app-profile-name-static" class="machine-name-static" style="display: none;">(アプリプロファイルなし)</span>
        <button id="btn-app-profile-add" class="icon-button" title="アプリプロファイルの追加" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M14 7v1H8v6H7V8H1V7h6V1h1v6h6z"/></svg></button>
        <button id="btn-app-profile-copy" class="icon-button" title="アプリプロファイルのコピー" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M4 4l1-1h5.414L14 6.586V14l-1 1H5l-1-1V4zm9 3l-3-3H5v10h8V7zM3 1L2 2v10l1 1V2h6.414l-1-1H3z"/></svg></button>
        <button id="btn-app-profile-remove" class="icon-button" title="アプリプロファイルの削除" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M15 8H1V7h14v1z"/></svg></button>
        <button id="btn-app-profile-rename" class="icon-button" title="アプリプロファイル名の変更" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M13.23 1h-1.46L3.52 9.25l-.16.22L1 13.59 2.41 15l4.12-2.36.22-.16L15 4.23V2.77L13.23 1zM2.41 13.59l1.51-3 1.45 1.45-2.96 1.55zm3.83-2.06L4.47 9.76l8-8 1.77 1.77-8 8z"/></svg></button>
      </div>
      <div id="app-profile-body" class="app-profile-body">
        <div id="app-profile-placeholder" class="profile-detail-placeholder" style="display: none;"></div>
        <div id="app-profile-editor" class="app-profile-editor" style="display: none;">
          <!-- common.app/appPathは廃止済み(ランタイムが無視するため入力欄なし)。
               autoInstallは共通でのみ設定可能(既定OFF)。 -->
          <div class="app-profile-group-title">共通</div>
          <div class="modal-row">
            <label for="app-profile-common-app-name">表示名</label>
            <input type="text" id="app-profile-common-app-name">
          </div>
          <div class="modal-row profile-checkbox-row">
            <input type="checkbox" id="app-profile-common-auto-install">
            <label for="app-profile-common-auto-install">自動インストールを有効にする</label>
          </div>

          <div class="app-profile-group-title app-profile-group-title-ios">iOS</div>
          <div class="modal-row">
            <label for="app-profile-ios-app-name">表示名</label>
            <input type="text" id="app-profile-ios-app-name">
          </div>
          <div class="modal-row">
            <label for="app-profile-ios-app">アプリID</label>
            <input type="text" id="app-profile-ios-app" placeholder="bundle id">
          </div>
          <div class="modal-row">
            <label for="app-profile-ios-app-path">パッケージパス</label>
            <input type="text" id="app-profile-ios-app-path">
          </div>

          <div class="app-profile-group-title app-profile-group-title-android">Android</div>
          <div class="modal-row">
            <label for="app-profile-android-app-name">表示名</label>
            <input type="text" id="app-profile-android-app-name">
          </div>
          <div class="modal-row">
            <label for="app-profile-android-app">アプリID</label>
            <input type="text" id="app-profile-android-app" placeholder="パッケージ名">
          </div>
          <div class="modal-row">
            <label for="app-profile-android-app-path">パッケージパス</label>
            <input type="text" id="app-profile-android-app-path">
          </div>

          <div id="app-profile-error" class="modal-error"></div>
          <div class="modal-buttons form-buttons">
            <button id="app-profile-confirm" type="button" disabled>確定</button>
            <button id="app-profile-cancel" class="secondary" type="button" style="display: none;">キャンセル</button>
          </div>
        </div>
      </div>
    </div>

    <div id="machine-profile-section" class="profile-section">
      <div class="profile-toolbar">
        <span class="profile-toolbar-title">マシンプロファイル</span>
        <select id="machine-select" style="display: none;"></select>
        <span id="machine-name-static" class="machine-name-static" style="display: none;"></span>
        <button id="btn-machine-add" class="icon-button" title="マシンプロファイルの追加" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M14 7v1H8v6H7V8H1V7h6V1h1v6h6z"/></svg></button>
        <button id="btn-machine-copy" class="icon-button" title="マシンプロファイルのコピー" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M4 4l1-1h5.414L14 6.586V14l-1 1H5l-1-1V4zm9 3l-3-3H5v10h8V7zM3 1L2 2v10l1 1V2h6.414l-1-1H3z"/></svg></button>
        <button id="btn-machine-remove" class="icon-button" title="マシンプロファイルの削除" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M15 8H1V7h14v1z"/></svg></button>
        <button id="btn-machine-rename" class="icon-button" title="マシンプロファイル名の変更" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M13.23 1h-1.46L3.52 9.25l-.16.22L1 13.59 2.41 15l4.12-2.36.22-.16L15 4.23V2.77L13.23 1zM2.41 13.59l1.51-3 1.45 1.45-2.96 1.55zm3.83-2.06L4.47 9.76l8-8 1.77 1.77-8 8z"/></svg></button>
      </div>
      <div class="profile-actions">
        <!-- 「+新規作成」ボタンは廃止済み。新規作成は#device-pick-overlay内の「+」(device-pick-add-new)から行う。 -->
        <span class="profile-actions-label">デバイス</span>
        <button id="btn-device-add-existing" class="icon-button" title="インストール済みのシミュレータ/AVDからマシンプロファイルに追加" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M14 7v1H8v6H7V8H1V7h6V1h1v6h6z"/></svg></button>
      </div>
      <div id="machine-profile-error" class="profile-error" style="display: none;"></div>
      <div id="machine-profile-body" class="profile-body">
        <div id="machine-device-list" class="machine-device-list"></div>
        <div id="machine-device-detail-pane" class="machine-device-detail-pane">
          <div id="profile-detail-placeholder" class="profile-detail-placeholder">デバイスを選択すると内容を表示します</div>
          <div id="machine-device-editor" class="machine-device-editor" style="display: none;">
            <div class="machine-device-editor-header">
              <span id="editor-device-name" class="tile-name"></span>
              <span id="editor-device-platform" class="editor-platform-label"></span>
            </div>
            <!-- 機種/OS/UDID/AVDは実体を指す属性でAPIでは変更不可(除去→作り直しが必要)なため
                 inputではなくlabel表示(inputイベントを発火しないのでdirty判定にも入らない)。
                 名前/ポートはプロファイル側設定値なので編集可。 -->
            <div class="modal-row">
              <label for="editor-name">名前</label>
              <input type="text" id="editor-name">
            </div>
            <div id="editor-ios-fields">
              <div class="modal-row">
                <label>機種</label>
                <span id="editor-simulator" class="editor-readonly-value" title="機種は変更できません(変更するにはデバイスを除去して作り直してください)"></span>
              </div>
              <div class="modal-row">
                <label>OS</label>
                <span id="editor-os" class="editor-readonly-value" title="OSは変更できません(変更するにはデバイスを除去して作り直してください)"></span>
              </div>
              <div class="modal-row">
                <label>UDID</label>
                <span id="editor-udid" class="editor-readonly-value" title="UDIDは作成時に決まる識別子のため変更できません"></span>
              </div>
              <div class="modal-row">
                <label for="editor-port">ポート</label>
                <input type="text" id="editor-port">
              </div>
            </div>
            <div id="editor-android-fields">
              <div class="modal-row">
                <label>AVD</label>
                <span id="editor-avd" class="editor-readonly-value" title="AVDは変更できません(変更するにはデバイスを除去して作り直してください)"></span>
              </div>
            </div>
            <div id="editor-error" class="modal-error"></div>
            <div class="modal-buttons form-buttons">
              <button id="editor-confirm" type="button" disabled>確定</button>
              <button id="editor-cancel" class="secondary" type="button" style="display: none;">キャンセル</button>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>

  <div id="panel-live" class="tab-panel" role="tabpanel" aria-labelledby="tab-live" style="display: none;">
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

  <div id="panel-explore" class="tab-panel" role="tabpanel" aria-labelledby="tab-explore" style="display: none;">
    <div class="toolbar">
      <label for="explore-device-select">デバイス:</label>
      <select id="explore-device-select"></select>
      <button id="explore-btn-refresh-devices" class="secondary">デバイス一覧を更新</button>
    </div>
    <div id="explore-banner" class="banner"></div>

    <div class="explore-body">
      <div class="explore-form">
        <div class="explore-form-row">
          <label for="explore-bundle-id">対象アプリの bundle ID / パッケージ名</label>
          <input type="text" id="explore-bundle-id">
        </div>
        <div class="explore-form-row">
          <label for="explore-goal">テストの目標(自然言語)</label>
          <textarea id="explore-goal" placeholder="例: ログインしてホーム画面が表示されることを確認する"></textarea>
        </div>
        <div class="explore-form-row">
          <label for="explore-max-steps">最大ステップ数(1〜50)</label>
          <input type="text" id="explore-max-steps" value="${DEFAULT_MAX_STEPS}">
        </div>
        <div class="explore-form-row explore-form-buttons">
          <button id="explore-btn-start">探索を開始</button>
          <button id="explore-btn-cancel" class="secondary" disabled>キャンセル</button>
          <span id="explore-running-label"></span>
        </div>
        <div id="explore-form-error" class="explore-form-error"></div>
      </div>

      <div class="explore-log-header">実行ログ</div>
      <div id="explore-log" class="explore-log"></div>

      <div id="explore-result" class="explore-result"></div>
      <button id="explore-btn-open-file" class="secondary explore-open-file-btn" style="display: none;">ファイルを開く</button>
    </div>
  </div>

  <div id="panel-settings" class="tab-panel" role="tabpanel" aria-labelledby="tab-settings" style="display: none;">
    <div class="settings-body">
      <label class="settings-item"><input type="checkbox" id="settings-polling-mode"> ポーリングモードを使用する</label>
      <div class="settings-hint">オンにすると画面を映像ストリーミングせず、従来のポーリング(定期スクリーンショット)で更新します。ストリーミングが不安定なときの回避用です。</div>
    </div>
  </div>

  <!-- アイコンはcodicon "vm-running"/"play"/"debug-stop"のインラインSVG。
       #device-op-menu-itemはup/down両方のアイコンを持ち、data-op(deviceTiles.jsが設定)でCSS表示切替。 -->
  <div id="device-op-menu" class="device-op-menu" role="menu">
    <button id="device-op-menu-live" class="device-op-menu-item" type="button" role="menuitem"><svg class="op-icon" width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path fill-rule="evenodd" clip-rule="evenodd" d="M6.607 14C6.79 14.357 7.017 14.689 7.275 15H3.5C3.224 15 3 14.776 3 14.5C3 14.224 3.224 14 3.5 14H5V12H3C1.895 12 1 11.105 1 10V3C1 1.895 1.895 1 3 1H13C14.105 1 15 1.895 15 3V7.293C14.69 7.036 14.357 6.816 14 6.633V3C14 2.448 13.552 2 13 2H3C2.448 2 2 2.448 2 3V10C2 10.552 2.448 11 3 11H6.024C5.994 11.332 6.004 11.666 6.034 12H6V14H6.607ZM16 11.5C16 12.39 15.736 13.26 15.242 14C14.748 14.74 14.045 15.317 13.222 15.657C12.4 15.998 11.495 16.087 10.622 15.913C9.749 15.739 8.947 15.311 8.318 14.681C7.689 14.052 7.26 13.25 7.086 12.377C6.912 11.504 7.001 10.599 7.342 9.777C7.683 8.955 8.259 8.252 8.999 7.757C9.739 7.264 10.609 7 11.499 7C12.692 7 13.837 7.474 14.681 8.318C15.525 9.162 16 10.307 16 11.5ZM13.97 11.499C13.97 11.41 13.946 11.323 13.901 11.246C13.856 11.17 13.791 11.106 13.713 11.063L10.743 9.413C10.667 9.371 10.581 9.349 10.494 9.35C10.407 9.351 10.322 9.375 10.247 9.419C10.171 9.463 10.109 9.526 10.066 9.602C10.023 9.677 10 9.763 10 9.85V13.15C10 13.237 10.023 13.322 10.066 13.398C10.11 13.474 10.172 13.537 10.247 13.581C10.322 13.625 10.407 13.649 10.494 13.65C10.581 13.65 10.667 13.629 10.743 13.587L13.713 11.937C13.791 11.892 13.856 11.829 13.901 11.752C13.946 11.676 13.97 11.588 13.97 11.499Z"/></svg><span>ライブ操作</span></button>
    <button id="device-op-menu-item" class="device-op-menu-item" type="button" role="menuitem"><svg class="op-icon op-icon-up" width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M4.74514 3.06414C4.41183 2.87665 4 3.11751 4 3.49993V12.5002C4 12.8826 4.41182 13.1235 4.74512 12.936L12.7454 8.43601C13.0852 8.24486 13.0852 7.75559 12.7454 7.56443L4.74514 3.06414ZM3 3.49993C3 2.35268 4.2355 1.63011 5.23541 2.19257L13.2357 6.69286C14.2551 7.26633 14.2551 8.73415 13.2356 9.30759L5.23537 13.8076C4.23546 14.37 3 13.6474 3 12.5002V3.49993Z"/></svg><svg class="op-icon op-icon-down" width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M12.5 3.5V12.5H3.5V3.5H12.5ZM12.5 2H3.5C2.672 2 2 2.672 2 3.5V12.5C2 13.328 2.672 14 3.5 14H12.5C13.328 14 14 13.328 14 12.5V3.5C14 2.672 13.328 2 12.5 2Z"/></svg><span id="device-op-menu-item-label"></span></button>
  </div>

  <!-- #device-op-menuとスタイルのみ共用する別要素。「除去」はプロファイルから外すだけで本体は削除しない。 -->
  <div id="machine-device-menu" class="device-op-menu" role="menu">
    <button id="machine-device-menu-item" class="device-op-menu-item" type="button" role="menuitem">除去</button>
  </div>

  <!-- ライブ操作の画像上で右クリック。開始/終了の活性は liveTab.js が録画状態に応じて切替(#live-btn-record と同ロジック)。 -->
  <div id="live-record-menu" class="device-op-menu" role="menu">
    <button id="live-record-menu-start" class="device-op-menu-item" type="button" role="menuitem">レコーディング開始</button>
    <button id="live-record-menu-stop" class="device-op-menu-item" type="button" role="menuitem">レコーディング終了</button>
  </div>

  <div id="device-add-overlay" class="modal-overlay">
    <div class="modal-dialog" role="dialog" aria-modal="true" aria-labelledby="device-add-title">
      <div id="device-add-title" class="modal-title">デバイスを追加</div>
      <div class="modal-row">
        <label>OS種別</label>
        <div class="modal-radio-group">
          <label class="modal-radio"><input type="radio" id="dlg-platform-ios" name="dlg-platform" value="ios" checked>iOS</label>
          <label class="modal-radio"><input type="radio" id="dlg-platform-android" name="dlg-platform" value="android">Android</label>
        </div>
      </div>
      <div class="modal-row">
        <label for="dlg-model">モデル</label>
        <select id="dlg-model"></select>
      </div>
      <div class="modal-row">
        <label for="dlg-os">OSバージョン</label>
        <select id="dlg-os"></select>
      </div>
      <div class="modal-row">
        <label for="dlg-name">デバイス名</label>
        <input type="text" id="dlg-name">
      </div>
      <div id="dlg-error" class="modal-error"></div>
      <div class="modal-buttons">
        <button id="dlg-cancel" class="secondary" type="button">キャンセル</button>
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
        <button id="name-input-cancel" class="secondary" type="button">キャンセル</button>
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
        <span id="device-pick-title">既存のデバイスから選択</span>
        <button id="device-pick-add-new" class="icon-button" type="button" title="デバイスを新規作成"><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M14 7v1H8v6H7V8H1V7h6V1h1v6h6z"/></svg></button>
      </div>
      <div id="device-pick-list" class="device-pick-list">
        <div id="device-pick-ios-group" class="device-pick-group">
          <div class="device-pick-group-title" id="device-pick-ios-title">iOS シミュレータ</div>
          <div id="device-pick-ios-body" class="device-pick-group-body"></div>
        </div>
        <div id="device-pick-android-group" class="device-pick-group">
          <div class="device-pick-group-title" id="device-pick-android-title">Android AVD</div>
          <div id="device-pick-android-body" class="device-pick-group-body"></div>
        </div>
      </div>
      <div id="device-pick-error" class="modal-error"></div>
      <div class="device-pick-note">チェックを外して OK すると登録解除されます(シミュレータ/AVD 本体は削除されません)</div>
      <div class="modal-buttons">
        <button id="device-pick-cancel" class="secondary" type="button">キャンセル</button>
        <button id="device-pick-ok" type="button" disabled>OK</button>
      </div>
    </div>
  </div>

  <script nonce="${nonce}" src="${scriptUri}"></script>
</body>
</html>`;
}
