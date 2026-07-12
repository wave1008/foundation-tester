// monitorHtml.ts
// デバイスモニターパネル(monitorPanel.ts)の webview HTML 生成部分。generateNonce()/renderHtml()
// (+ その中で参照する PANEL_TITLE)を持つ。webview 資産(スタイル・スクリプト)自体は
// src/webview/monitor/{style.css,main.js} に分離されており、esbuild が
// media/monitor/ にバンドルしたものを renderHtml() が webview.asWebviewUri で読み込む。
// HTML 本文は renderHtml() 内にインライン生成する。

import { randomBytes } from "node:crypto";
import * as vscode from "vscode";

/** デバイスモニターパネルのタイトル(VS Code タブ表示・HTML の <title> の両方で使う)。 */
export const PANEL_TITLE = "ftester デバイスモニター";

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
    <button id="tab-profiles" class="tab-button" type="button" role="tab" aria-selected="false" aria-controls="panel-profiles">プロファイル</button>
    <button id="tab-settings" class="tab-button" type="button" role="tab" aria-selected="false" aria-controls="panel-settings">設定</button>
  </div>

  <div id="panel-devices" class="tab-panel" role="tabpanel" aria-labelledby="tab-devices">
    <div id="toolbar" class="toolbar">
      <button id="btn-devices-up">デバイスを全て起動</button>
      <button id="btn-devices-down" class="secondary">全て終了</button>
      <button id="btn-restart" class="secondary">モニター再起動</button>
      <label class="profile-label">実行プロファイル
        <select id="profile-select" title="以後のテスト実行・デバッグ実行と、このモニターの監視対象デバイスに使う実行プロファイル(ftester.profile 設定)" disabled></select>
      </label>
      <!-- hostMetricsメッセージ受信のたびにmain.js側で再描画(独自タイマーなし)。 -->
      <div id="host-metrics" class="host-metrics">
        <span class="host-metric" id="hm-cpu" title="CPU負荷"><span class="hm-label">CPU</span><canvas class="hm-canvas" width="72" height="22"></canvas><span class="hm-value">–</span></span>
        <span class="host-metric" id="hm-gpu" title="GPU負荷"><span class="hm-label">GPU</span><canvas class="hm-canvas" width="72" height="22"></canvas><span class="hm-value">–</span></span>
        <span class="host-metric" id="hm-ane" title="ANE負荷"><span class="hm-label">ANE</span><canvas class="hm-canvas" width="72" height="22"></canvas><span class="hm-value">–</span></span>
        <span class="host-metric" id="hm-mem" title="メモリ使用量"><span class="hm-label">MEM</span><canvas class="hm-canvas" width="72" height="22"></canvas><span class="hm-value">–</span></span>
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

  <div id="panel-settings" class="tab-panel" role="tabpanel" aria-labelledby="tab-settings" style="display: none;">
    <div class="tab-placeholder">このタブは準備中です(設定機能を今後追加予定)</div>
  </div>

  <div id="device-op-menu" class="device-op-menu" role="menu">
    <button id="device-op-menu-item" class="device-op-menu-item" type="button" role="menuitem"></button>
  </div>

  <!-- #device-op-menuとスタイルのみ共用する別要素。「除去」はプロファイルから外すだけで本体は削除しない。 -->
  <div id="machine-device-menu" class="device-op-menu" role="menu">
    <button id="machine-device-menu-item" class="device-op-menu-item" type="button" role="menuitem">除去</button>
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
