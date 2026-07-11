// main.js
// デバイスモニター webview のロジック。monitorPanel.ts の renderHtml() が生成する
// <script nonce="${nonce}"> ブロック(テンプレート文字列に内蔵されていた JS)から逐語抽出
// したもの(Phase 1: webview 資産の実ファイル化)。抽出前は runLaneModel.ts の3定数
// (MAX_LANE_LINES/OVERALL_LANE_ID/OVERALL_LANE_NAME)をテンプレート補間で注入していたが、
// 通常の import に置き換えた(esbuild が .ts を解決してバンドルできるため)。
// esbuild が media/monitor/main.js に iife 形式でバンドルし、renderHtml() が
// <script src="..."> で読み込む。

import { MAX_LANE_LINES, OVERALL_LANE_ID, OVERALL_LANE_NAME } from "../../runLaneModel";

  (function () {
const vscode = acquireVsCodeApi();


const toolbar = document.getElementById('toolbar');
const grid = document.getElementById('grid');
const emptyMessage = document.getElementById('empty');
const banner = document.getElementById('banner');
const btnUp = document.getElementById('btn-devices-up');
const btnDown = document.getElementById('btn-devices-down');
const btnRestart = document.getElementById('btn-restart');
const profileSelect = document.getElementById('profile-select');

const devicesPanel = document.getElementById('panel-devices');
const tilePane = document.getElementById('tile-pane');
const splitter = document.getElementById('splitter');
const lanesPlaceholder = document.getElementById('lanes-placeholder');
const lanesGrid = document.getElementById('lanes-grid');
const lanesSelectionStatus = document.getElementById('lanes-selection-status');
const lanesRunStatus = document.getElementById('lanes-run-status');

const deviceOpMenu = document.getElementById('device-op-menu');
const deviceOpMenuItemBtn = document.getElementById('device-op-menu-item');

const STATE_LABEL = {
  connected: '接続済み',
  booted: '起動中',
  offline: '未起動',
};

// 複製元: src/monitorModel.ts の deviceOpMenuItem。webview は CSP により import 不可のため
// 複製する(healReviewPanel.ts が healModel.ts の一部ロジックを複製しているのと同じ方針)。
// タイル右クリックメニューの項目ラベル・実行する操作と、実行中/待機中バッジの表示にも共用する。
// busy は { op, status } の形('queued'=順番待ち／'running'=実行中)。無ければ undefined。
function deviceOpMenuItem(state, busy) {
  if (busy && busy.status === 'queued') { return { label: '待機中...', op: busy.op, disabled: true }; }
  if (busy && busy.op === 'up') { return { label: '起動中...', op: 'up', disabled: true }; }
  if (busy && busy.op === 'down') { return { label: '停止中...', op: 'down', disabled: true }; }
  return state === 'offline'
    ? { label: '起動', op: 'up', disabled: false }
    : { label: '停止', op: 'down', disabled: false };
}

// device id -> タイルの DOM 要素・最新フレーム(1枚のみ保持。履歴は溜めない)
const tiles = new Map();
// レーン id(worker id、または OVERALL_LANE_ID) -> DOM 要素・自動スクロール状態
const lanes = new Map();
// タイルクリックで選択された device id 集合(空 = 全ワーカー表示)
const selectedDeviceIds = new Set();

function formatTime(date) {
  const pad = (n) => String(n).padStart(2, '0');
  return pad(date.getHours()) + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds());
}

// ---- 上下ペインのスプリッター ---------------------------------------------
// タイルペイン(上)の高さを JS 側の状態として保持し、setState/getState にも保存して
// パネル再表示時に復元する。出力ペイン(下)は flex の残りスペースを自動的に占有するので、
// 高さを個別に管理する必要はない。

const MIN_PANE_HEIGHT = 120;
const persistedState = vscode.getState() || {};
let tilePaneHeight =
  typeof persistedState.tilePaneHeight === 'number' && persistedState.tilePaneHeight > 0
    ? persistedState.tilePaneHeight
    : Math.round(window.innerHeight * 0.45);

// タイルペイン+出力ペインに配分できる合計の高さ(ツールバー・バナー・スプリッター分を除く)。
// タブ導入前は document.body.clientHeight を基準にしていたが、タブバー分の高さがずれるため、
// 「デバイス」タブのパネル(既存要素一式を包むコンテナ)自身の clientHeight を基準にする。
function availableSplitHeight() {
  const bannerHeight = banner.classList.contains('visible') ? banner.offsetHeight : 0;
  return devicesPanel.clientHeight - toolbar.offsetHeight - bannerHeight - splitter.offsetHeight;
}

// 上下それぞれ最小 MIN_PANE_HEIGHT を確保するようにクランプする。
function clampTilePaneHeight(height) {
  const available = availableSplitHeight();
  const maxHeight = Math.max(MIN_PANE_HEIGHT, available - MIN_PANE_HEIGHT);
  return Math.min(Math.max(height, MIN_PANE_HEIGHT), maxHeight);
}

function applyTilePaneHeight(height) {
  // 「デバイス」タブが非表示(display:none)の間は devicesPanel.clientHeight が 0 になり、
  // clampTilePaneHeight が誤って最小値 120px に丸めてしまう。何もせず抜け、タブが
  // 「デバイス」に戻った直後(switchTab)に呼び直して再クランプする。
  if (devicesPanel.clientHeight === 0 || devicesPanel.offsetParent === null) {
    return;
  }
  tilePaneHeight = clampTilePaneHeight(height);
  tilePane.style.height = tilePaneHeight + 'px';
  relayoutTiles();
}

function persistTilePaneHeight() {
  vscode.setState(Object.assign({}, vscode.getState(), { tilePaneHeight }));
}

applyTilePaneHeight(tilePaneHeight);
// ウィンドウリサイズ/バナー表示切替でも上下の最小高さを維持する。
window.addEventListener('resize', () => applyTilePaneHeight(tilePaneHeight));

let splitterPointerId = null;
let splitterStartY = 0;
let splitterStartHeight = 0;

splitter.addEventListener('pointerdown', (event) => {
  if (event.button !== 0) {
    return;
  }
  splitterPointerId = event.pointerId;
  splitterStartY = event.clientY;
  splitterStartHeight = tilePaneHeight;
  splitter.setPointerCapture(event.pointerId);
  splitter.classList.add('dragging');
  event.preventDefault();
});
splitter.addEventListener('pointermove', (event) => {
  if (splitterPointerId !== event.pointerId) {
    return;
  }
  applyTilePaneHeight(splitterStartHeight + (event.clientY - splitterStartY));
});
const endSplitterDrag = (event) => {
  if (splitterPointerId !== event.pointerId) {
    return;
  }
  splitterPointerId = null;
  splitter.classList.remove('dragging');
  splitter.releasePointerCapture(event.pointerId);
  persistTilePaneHeight();
};
splitter.addEventListener('pointerup', endSplitterDrag);
splitter.addEventListener('pointercancel', endSplitterDrag);

// ---- デバイスタイル -----------------------------------------------------

// タイル内の「画像以外」の高さの合計(px)。CSS の固定高と一致させること:
// padding 上下 8+8 + header 20 + footer 18 + gap 6×2 = 66
const TILE_CHROME_HEIGHT = 66;

// タイルの実測高さ(グリッドの stretch 結果)から画像に使える高さを算出し、
// CSS 変数 --tile-image-h として grid に設定する(タイル幅はこの高さ×アスペクト比で決まる)。
// スプリッター移動・リサイズ・タイル生成のたびに呼ぶ。
function relayoutTiles() {
  const probe = grid.querySelector('.tile');
  if (!probe) {
    return;
  }
  const imageHeight = Math.max(60, probe.clientHeight - TILE_CHROME_HEIGHT);
  grid.style.setProperty('--tile-image-h', imageHeight + 'px');
}

function createTile(device) {
  const tile = document.createElement('div');
  tile.className = 'tile';
  // ボタン廃止(要件1)によりヒントが無くなるため、ツールチップで操作方法を示す
  // (macOS GUI 版のタイルの .help() と同じ趣旨)。
  tile.title = 'クリックで選択 / 右クリックで起動・停止';
  tile.addEventListener('click', () => toggleDeviceSelection(device.id));
  tile.addEventListener('contextmenu', (event) => {
    // 既定の(OS/ブラウザの)コンテキストメニューを抑止し、タイル本体のクリック
    // (レーン絞り込みの選択トグル)にも波及させない。
    event.preventDefault();
    event.stopPropagation();
    openDeviceOpMenu(entry, event.clientX, event.clientY);
  });

  // ヘッダー: 左からプラットフォーム色で装飾したデバイス名、右端に「実行中」
  // (個別起動/停止は右クリックメニューに移動した。ボタンが無くなった分、名前表示が
  // フル幅を使える)
  const header = document.createElement('div');
  header.className = 'tile-header';
  const name = document.createElement('span');
  name.className = 'tile-name';
  const runningBadge = document.createElement('span');
  runningBadge.className = 'badge badge-running';
  runningBadge.textContent = '実行中';
  header.append(name, runningBadge);

  const frameWrap = document.createElement('div');
  frameWrap.className = 'frame-wrap';
  const img = document.createElement('img');
  const placeholder = document.createElement('div');
  placeholder.className = 'frame-placeholder';
  // 起動/停止操作中バッジ(画像左上に重ねる。要件3)。renderFrame() が
  // frame-wrap の中身を作り直すたびに末尾へ再アペンドする。
  const opBadge = document.createElement('span');
  opBadge.className = 'tile-op-badge';

  // フッター: [状態テキスト] [⚠エラー(あれば、中間で省略)] [HH:MM:SS(右寄せ)]
  const footer = document.createElement('div');
  footer.className = 'tile-footer';
  const stateBadge = document.createElement('span');
  stateBadge.className = 'tile-state';
  const updated = document.createElement('span');
  updated.className = 'tile-updated';
  const error = document.createElement('span');
  error.className = 'tile-error';
  footer.append(stateBadge, error, updated);

  tile.append(header, frameWrap, footer);
  grid.appendChild(tile);

  const entry = {
    device,
    tile,
    nameEl: name,
    // そのデバイスの直列キュー上の状態({ op: 'up'|'down', status: 'queued'|'running' })。
    // キューに入っていなければ undefined。
    opBusy: undefined,
    opBadgeEl: opBadge,
    stateBadgeEl: stateBadge,
    runningBadgeEl: runningBadge,
    frameWrapEl: frameWrap,
    imgEl: img,
    placeholderEl: placeholder,
    updatedEl: updated,
    errorEl: error,
    frameSrc: null,
    lastUpdated: null,
  };
  tiles.set(device.id, entry);
  return entry;
}

function renderFrame(entry) {
  entry.frameWrapEl.textContent = '';
  if (entry.device.state !== 'offline' && entry.frameSrc) {
    entry.imgEl.src = entry.frameSrc;
    entry.imgEl.alt = entry.device.name;
    entry.frameWrapEl.appendChild(entry.imgEl);
  } else {
    // フレーム未受信のプレースホルダーはデバイス状態で出し分ける
    // (offline=未起動+電源アイコン / それ以外(booted・接続直後でフレーム未着)=起動中+スピナー)
    const offline = entry.device.state === 'offline';
    entry.placeholderEl.textContent = '';
    const icon = document.createElement('span');
    if (offline) {
      icon.className = 'placeholder-icon offline';
      icon.innerHTML = '<svg width="14" height="14" viewBox="0 0 16 16" fill="none"'
        + ' stroke="currentColor" stroke-width="1.6" stroke-linecap="round">'
        + '<path d="M8 1.8v5.4"/><path d="M4.4 3.9a5.4 5.4 0 1 0 7.2 0"/></svg>';
    } else {
      icon.className = 'placeholder-icon booting';
    }
    const labelSpan = document.createElement('span');
    labelSpan.textContent = offline ? '未起動' : '起動中';
    entry.placeholderEl.append(icon, labelSpan);
    entry.frameWrapEl.appendChild(entry.placeholderEl);
  }
  entry.frameWrapEl.appendChild(entry.opBadgeEl);
}

function renderMeta(entry) {
  entry.nameEl.textContent = entry.device.name;
  entry.nameEl.className = 'tile-name tile-name-' + entry.device.platform;
  entry.nameEl.title = entry.device.name + ' (' + entry.device.platform + ')';
  // フッター左下の表示ルール:
  //   connected(フレーム表示中) → 「接続済み」
  //   booted(iOSブリッジ未接続 / Androidブート完了待ち) → 「接続中」
  //   それ以外(未起動・フレーム未着) → 空(要素は固定高レイアウトのため残す)
  let footerText = '';
  if (entry.device.state === 'connected' && entry.frameSrc) {
    footerText = STATE_LABEL.connected;
  } else if (entry.device.state === 'booted') {
    footerText = '接続中';
  }
  entry.stateBadgeEl.textContent = footerText;
  entry.updatedEl.textContent = entry.lastUpdated ? formatTime(entry.lastUpdated) : '';
  renderOpBadge(entry);
  // 右クリックメニューがこのタイルに対して開いていれば、内容(ラベル/disabled)も
  // 最新の state/opBusy で更新する。
  if (deviceOpMenuEntry === entry) {
    renderDeviceOpMenuItem();
  }
}

// 起動/停止操作中バッジの表示可否・文言を、デバイスの現在状態(state)とそのデバイスで
// 実行中の操作(opBusy)から再計算する。devices サイクル毎(renderMeta 経由)と
// deviceOpBusy 受信時の両方から呼ぶ(モニターの既存ポーリングで状態変化が反映される)。
function renderOpBadge(entry) {
  const item = deviceOpMenuItem(entry.device.state, entry.opBusy);
  entry.opBadgeEl.textContent = item.label;
  entry.opBadgeEl.classList.toggle('visible', item.disabled);
}

// ---- タイル右クリックメニュー ---------------------------------------------

// 現在メニューを開いている対象のタイル entry(未オープンなら null)。
let deviceOpMenuEntry = null;

function renderDeviceOpMenuItem() {
  if (!deviceOpMenuEntry) {
    return;
  }
  const item = deviceOpMenuItem(deviceOpMenuEntry.device.state, deviceOpMenuEntry.opBusy);
  deviceOpMenuItemBtn.textContent = item.label;
  deviceOpMenuItemBtn.disabled = item.disabled;
  deviceOpMenuItemBtn.dataset.op = item.op;
}

function closeDeviceOpMenu() {
  if (!deviceOpMenuEntry) {
    return;
  }
  deviceOpMenuEntry = null;
  deviceOpMenu.classList.remove('visible');
}

// 自作の右クリックメニュー(fixed div)をマウス位置に開く際、画面端でははみ出さないよう
// 実測サイズで座標をクランプする。タイル右クリックメニュー・プロファイルタブのデバイス行
// 右クリックメニュー(machine-device-menu)で共用する。
function clampMenuPosition(menuEl, clientX, clientY) {
  const rect = menuEl.getBoundingClientRect();
  const maxX = Math.max(4, window.innerWidth - rect.width - 4);
  const maxY = Math.max(4, window.innerHeight - rect.height - 4);
  menuEl.style.left = Math.min(Math.max(clientX, 4), maxX) + 'px';
  menuEl.style.top = Math.min(Math.max(clientY, 4), maxY) + 'px';
}

// マウス位置にメニューを開く。
function openDeviceOpMenu(entry, clientX, clientY) {
  deviceOpMenuEntry = entry;
  renderDeviceOpMenuItem();
  deviceOpMenu.classList.add('visible');
  clampMenuPosition(deviceOpMenu, clientX, clientY);
}

deviceOpMenuItemBtn.addEventListener('click', (event) => {
  event.stopPropagation();
  if (!deviceOpMenuEntry || deviceOpMenuItemBtn.disabled) {
    return;
  }
  vscode.postMessage({
    type: 'deviceOp',
    name: deviceOpMenuEntry.device.name,
    op: deviceOpMenuItemBtn.dataset.op,
  });
  closeDeviceOpMenu();
});

// メニュー外クリック・Esc・スクロールで閉じる(要件2)。
document.addEventListener('click', (event) => {
  if (deviceOpMenuEntry && !deviceOpMenu.contains(event.target)) {
    closeDeviceOpMenu();
  }
});
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    closeDeviceOpMenu();
  }
});
// capture:true で登録することで、スクロール可能な子要素(grid の横スクロール・
// lane-body 等)で発生した(バブリングしない)scroll イベントも document 側で拾える。
document.addEventListener('scroll', () => closeDeviceOpMenu(), true);
window.addEventListener('resize', () => closeDeviceOpMenu());
// タイル上での contextmenu は stopPropagation 済みなのでここには来ない。
// タイル外(空きエリア等)で右クリックし、既定のコンテキストメニューが別途開く場合に
// こちらのメニューを残さないようにする。
document.addEventListener('contextmenu', () => closeDeviceOpMenu());

// デバイス名から対応するタイルを探す(deviceOp は --name(論理名)だけを host に渡すため、
// host からの deviceOpBusy/deviceOpFailed 応答も name で返ってくる)。
function findTileByName(name) {
  for (const entry of tiles.values()) {
    if (entry.device.name === name) {
      return entry;
    }
  }
  return undefined;
}

function touch(entry) {
  entry.lastUpdated = new Date();
  renderMeta(entry);
}

// monitorError はタイルに表示したままにせず、そのデバイスの monitorFrame か state 更新
// (devices サイクル)を受信した時点で消す(過渡的なエラーが赤字のまま残り続けないように)。
function setTileError(entry, message) {
  entry.errorEl.textContent = '⚠ ' + message;
  entry.errorEl.title = message;
}

function clearTileError(entry) {
  entry.errorEl.textContent = '';
  entry.errorEl.removeAttribute('title');
}

function applyDevices(devices) {
  const seen = new Set();
  for (const device of devices) {
    seen.add(device.id);
    let entry = tiles.get(device.id);
    if (!entry) {
      entry = createTile(device);
      entry.runningBadgeEl.style.display = runningWorkers.has(device.id) ? 'inline-block' : 'none';
    } else {
      entry.device = device;
    }
    touch(entry);
    renderFrame(entry);
    clearTileError(entry);
  }
  for (const [id, entry] of tiles) {
    if (!seen.has(id)) {
      if (deviceOpMenuEntry === entry) {
        closeDeviceOpMenu();
      }
      entry.tile.remove();
      tiles.delete(id);
      selectedDeviceIds.delete(id);
    }
  }
  emptyMessage.style.display = tiles.size === 0 ? 'flex' : 'none';
  relayoutTiles();
  syncLanesToDevices(devices);
  updateLaneVisibility();
}

function applyFrame(message) {
  const entry = tiles.get(message.device);
  if (!entry) {
    return; // devices サイクルより先に届いた場合は無視する(次の devices で改めて反映される)
  }
  entry.frameSrc = 'data:image/jpeg;base64,' + message.jpegBase64;
  // 実フレームのアスペクト比でタイル幅を決める(縦横比の異なるデバイスが混在しても
  // それぞれの画像幅ちょうどに締まる)
  if (message.width > 0 && message.height > 0) {
    entry.tile.style.setProperty('--tile-aspect', (message.width / message.height).toFixed(4));
  }
  touch(entry);
  renderFrame(entry);
  clearTileError(entry);
}

function applyDeviceError(message) {
  const entry = message.device ? tiles.get(message.device) : undefined;
  if (entry) {
    setTileError(entry, message.message);
    return;
  }
  showBanner(message.message);
}

function showBanner(text) {
  banner.textContent = text;
  banner.classList.add('visible');
}
function hideBanner() {
  banner.textContent = '';
  banner.classList.remove('visible');
}

function setBusy(busy) {
  btnUp.disabled = busy;
  btnDown.disabled = busy;
}

// ---- 実行プロファイル選択 ---------------------------------------------------
// 追加/コピー/削除/名前変更はプロファイルタブ下半分の実行プロファイルセクションに移設した
// (btn-run-profile-*)。ここでは「使用する実行プロファイルを指定するだけ」の select のみを扱う。

const PROFILE_NONE_LABEL = '(プロファイルなし)';

// profileInfo 受信のたびに select の中身を作り直す(現在値が profiles に無い場合も、
// 設定に手書きされた未知の名前として option を補い選択状態を保つ)。
function applyProfileInfo(message) {
  const profiles = Array.isArray(message.profiles) ? message.profiles : [];
  const current = typeof message.current === 'string' ? message.current : '';
  profileSelect.textContent = '';

  const noneOption = document.createElement('option');
  noneOption.value = '';
  noneOption.textContent = PROFILE_NONE_LABEL;
  profileSelect.appendChild(noneOption);

  let matched = current === '';
  for (const name of profiles) {
    const option = document.createElement('option');
    option.value = name;
    option.textContent = name;
    profileSelect.appendChild(option);
    if (name === current) {
      matched = true;
    }
  }
  if (!matched) {
    const unknownOption = document.createElement('option');
    unknownOption.value = current;
    unknownOption.textContent = current;
    profileSelect.appendChild(unknownOption);
  }
  profileSelect.value = current;
  profileSelect.disabled = false;
}

profileSelect.addEventListener('change', () => {
  vscode.postMessage({ type: 'selectProfile', profile: profileSelect.value });
});

function toggleDeviceSelection(id) {
  if (selectedDeviceIds.has(id)) {
    selectedDeviceIds.delete(id);
  } else {
    selectedDeviceIds.add(id);
  }
  updateSelectionUi();
}

function updateSelectionUi() {
  for (const [id, entry] of tiles) {
    entry.tile.classList.toggle('selected', selectedDeviceIds.has(id));
  }
  updateLaneVisibility();
}

// 空きエリア(タイルの外、横スクロールコンテナ内の余白を含む)をクリックしたら選択を全解除する。
grid.addEventListener('click', (event) => {
  if (event.target === grid && selectedDeviceIds.size > 0) {
    selectedDeviceIds.clear();
    updateSelectionUi();
  }
});

// ホイール操作を横スクロールに変換する(下回転→右スクロール、上回転→左スクロール)。
// トラックパッドの横方向(deltaX)はそのまま加算し、縦回転(deltaY)も横スクロールに合算する。
// ページ側の縦スクロールに奪われないよう preventDefault() するため passive:false で登録する。
grid.addEventListener(
  'wheel',
  (event) => {
    grid.scrollLeft += event.deltaX + event.deltaY;
    event.preventDefault();
  },
  { passive: false },
);

// 中ボタン(ホイールボタン)ドラッグでパンスクロール(GUI版のステップ表と同じ操作感)。
// 「掴んで動かす」向き = ポインタを右へ動かすとコンテンツが右へ付いてくる(scrollLeft は減る)。
// Pointer Events + setPointerCapture でグリッド外へ出てもドラッグを継続する。
let panPointerId = null;
let panLastX = 0;
grid.addEventListener('pointerdown', (event) => {
  if (event.button !== 1) {
    return;
  }
  panPointerId = event.pointerId;
  panLastX = event.clientX;
  grid.setPointerCapture(event.pointerId);
  grid.style.cursor = 'grabbing';
  event.preventDefault();
});
grid.addEventListener('pointermove', (event) => {
  if (panPointerId !== event.pointerId) {
    return;
  }
  grid.scrollLeft -= event.clientX - panLastX;
  panLastX = event.clientX;
});
const endPan = (event) => {
  if (panPointerId !== event.pointerId) {
    return;
  }
  panPointerId = null;
  grid.style.cursor = '';
  grid.releasePointerCapture(event.pointerId);
};
grid.addEventListener('pointerup', endPan);
grid.addEventListener('pointercancel', endPan);
// Chromium の中クリック既定動作(オートスクロール等)を抑止する
grid.addEventListener('auxclick', (event) => {
  if (event.button === 1) {
    event.preventDefault();
  }
});

// ---- ログレーン -----------------------------------------------------------

// worker id(またはタイルが存在しない全体レーン)ごとの「実行中」状態。
const runningWorkers = new Set();

function setTileRunning(id, running) {
  if (running) {
    runningWorkers.add(id);
  } else {
    runningWorkers.delete(id);
  }
  const entry = tiles.get(id);
  if (entry) {
    entry.runningBadgeEl.style.display = running ? 'inline-block' : 'none';
  }
}

// レーン名はデバイスタイルのタイトルと同じテキスト・同じ装飾(色付きピル)にする。
// platform 不明(全体レーンやフォールバック)は中立色のピル。
function setLaneHeader(headerEl, name, platform) {
  headerEl.textContent = '';
  const pill = document.createElement('span');
  pill.className = 'lane-name ' + (platform ? 'tile-name-' + platform : 'lane-name-neutral');
  pill.textContent = name;
  headerEl.appendChild(pill);
}

// updateLabel=true は workersReady/hydrate/デバイス同期によるレーン構成時のみ。
// 行追加(appendLaneLine)からの呼び出しで true にすると、フォールバック名(生の worker id)で
// 構成済みの表示名を上書きしてしまう(過去に実際に起きた表記崩れ)。
function ensureLane(id, name, platform, updateLabel) {
  let lane = lanes.get(id);
  if (lane) {
    if (updateLabel) {
      setLaneHeader(lane.headerEl, name, platform);
    }
    return lane;
  }
  const el = document.createElement('div');
  el.className = 'lane';
  const header = document.createElement('div');
  header.className = 'lane-header';
  setLaneHeader(header, name, platform);
  const body = document.createElement('div');
  body.className = 'lane-body';
  el.append(header, body);
  lanesGrid.appendChild(el);

  lane = { el, headerEl: header, bodyEl: body, atBottom: true, lineCount: 0 };
  body.addEventListener('scroll', () => {
    lane.atBottom = body.scrollHeight - body.scrollTop - body.clientHeight < 24;
  });
  lanes.set(id, lane);
  updateLaneVisibility();
  return lane;
}

function appendLaneLine(laneId, text) {
  const lane = ensureLane(laneId, laneId === OVERALL_LANE_ID ? OVERALL_LANE_NAME : laneId, undefined, false);
  const wasAtBottom = lane.atBottom;
  const line = document.createElement('div');
  line.className = 'lane-line';
  line.textContent = text;
  lane.bodyEl.appendChild(line);
  lane.lineCount += 1;
  while (lane.lineCount > MAX_LANE_LINES) {
    const first = lane.bodyEl.firstChild;
    if (!first) {
      break;
    }
    lane.bodyEl.removeChild(first);
    lane.lineCount -= 1;
  }
  if (wasAtBottom) {
    lane.bodyEl.scrollTop = lane.bodyEl.scrollHeight;
  }
}

function clearAllLanes() {
  for (const lane of lanes.values()) {
    lane.el.remove();
  }
  lanes.clear();
  for (const id of [...runningWorkers]) {
    setTileRunning(id, false);
  }
  lanesRunStatus.textContent = '';
  updateLaneVisibility();
}

function configureLanes(laneInfos) {
  const nextIds = new Set(laneInfos.map((l) => l.id));
  for (const [id, lane] of [...lanes]) {
    if (!nextIds.has(id)) {
      lane.el.remove();
      lanes.delete(id);
    }
  }
  for (const info of laneInfos) {
    ensureLane(info.id, info.name, info.platform, true);
  }
  updateLaneVisibility();
}

function updateLaneVisibility() {
  const allIds = [...lanes.keys()];
  const activeIds = selectedDeviceIds.size > 0
    ? allIds.filter((id) => selectedDeviceIds.has(id))
    : allIds;
  const columns = Math.max(1, activeIds.length);
  lanesGrid.style.gridTemplateColumns = 'repeat(' + columns + ', minmax(0, 1fr))';
  for (const [id, lane] of lanes) {
    lane.el.style.display = activeIds.includes(id) ? 'flex' : 'none';
  }
  lanesSelectionStatus.textContent = selectedDeviceIds.size > 0
    ? '選択中' + selectedDeviceIds.size + '台を表示'
    : '全ワーカー';
}

// 出力ペインは常設で、実行前でもデバイス毎の空レーンを表示する(ユーザー指定で
// プレースホルダー文言は廃止)。レーンはモニターの devices サイクルから常時同期する。
function updateLanesPlaceholder() {
  lanesPlaceholder.style.display = 'none';
  lanesGrid.style.display = 'grid';
}
updateLanesPlaceholder();

// モニターのデバイス一覧に合わせて空レーンを用意する(既存レーンはそのまま。
// 実行開始(cleared)で一旦消えても、次の devices サイクル(interval秒毎)で復元される)。
function syncLanesToDevices(devices) {
  for (const device of devices) {
    ensureLane(device.id, device.name, device.platform, true);
  }
}

function applyLaneAction(action) {
  switch (action.type) {
    case 'cleared':
      clearAllLanes();
      break;
    case 'lanesConfigured':
      configureLanes(action.lanes);
      break;
    case 'line':
      appendLaneLine(action.laneId, action.text);
      break;
    case 'workerRunning':
      setTileRunning(action.workerId, action.running);
      break;
    case 'runFinished':
      lanesRunStatus.textContent = '完了: 成功 ' + action.passed + ' / 失敗 ' + action.failed;
      break;
    default:
      break;
  }
}

function applyLaneHydrate(snapshot) {
  clearAllLanes();
  if (snapshot.lanes.length > 0) {
    configureLanes(snapshot.lanes);
  }
  for (const laneId of Object.keys(snapshot.linesByLane)) {
    for (const text of snapshot.linesByLane[laneId]) {
      appendLaneLine(laneId, text);
    }
  }
  for (const workerId of snapshot.runningWorkers) {
    setTileRunning(workerId, true);
  }
}

// ---- ホストメトリクス(ツールバーのミニグラフ) -------------------------------
// host-metrics プロセス(拡張側が1秒間隔で常駐 spawn)からの hostMetrics メッセージ受信の
// たびに、直近60サンプルのローリングバッファへ追加して canvas に再描画する。webview 側は
// 独自のタイマーを持たない(更新頻度は完全に CLI 側の --interval 1 に駆動される)。

const HM_MAX_SAMPLES = 60;
// バリデータ検証済みパレット(ダーク/ライトで系列色を切り替える。グリッド・軸は描かない)。
const HM_COLORS = {
  dark: { cpu: '#f2555a', gpu: '#b8891f', ane: '#a06be0', mem: '#2f9e63' },
  light: { cpu: '#e5484d', gpu: '#e6a700', ane: '#8e4ec6', mem: '#30a46c' },
};

function hmIsLightTheme() {
  return document.body.classList.contains('vscode-light') ||
    document.body.classList.contains('vscode-high-contrast-light');
}

function hmMakeEntry(id, colorKey) {
  const el = document.getElementById(id);
  return {
    el,
    canvas: el.querySelector('.hm-canvas'),
    value: el.querySelector('.hm-value'),
    colorKey,
    samples: [], // 直近 HM_MAX_SAMPLES 件。要素は 0..1 の比率、または欠測を表す null。
  };
}

const hmEntries = {
  cpu: hmMakeEntry('hm-cpu', 'cpu'),
  gpu: hmMakeEntry('hm-gpu', 'gpu'),
  ane: hmMakeEntry('hm-ane', 'ane'),
  mem: hmMakeEntry('hm-mem', 'mem'),
};
const HM_ALL_ENTRIES = [hmEntries.cpu, hmEntries.gpu, hmEntries.ane, hmEntries.mem];

function hmPushSample(entry, ratio) {
  entry.samples.push(ratio);
  if (entry.samples.length > HM_MAX_SAMPLES) {
    entry.samples.shift();
  }
}

// canvas は CSS 上 72x22px 固定。devicePixelRatio に合わせて実ピクセル数(width/height 属性)を
// 上げてから ctx.scale で以後の描画を CSS ピクセル座標系のまま書けるようにする(にじみ防止)。
// width/height 属性への代入は毎回キャンバスの内容をクリアするので、呼び出し側は直後に
// 全内容を描き直すこと。
function hmSetupCanvas(canvas) {
  const dpr = window.devicePixelRatio || 1;
  const width = 72;
  const height = 22;
  canvas.width = Math.round(width * dpr);
  canvas.height = Math.round(height * dpr);
  const ctx = canvas.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  return ctx;
}

function hmDraw(entry) {
  const width = 72;
  const height = 22;
  const ctx = hmSetupCanvas(entry.canvas);
  ctx.clearRect(0, 0, width, height);
  const samples = entry.samples;
  if (samples.length < 2) {
    return;
  }
  const color = HM_COLORS[hmIsLightTheme() ? 'light' : 'dark'][entry.colorKey];
  const stepX = width / (HM_MAX_SAMPLES - 1);
  // samples は「直近 N 件」なので、まだ60件溜まっていない間は右詰めで配置する
  // (新しいサンプルは常に右端、満杯になった後は左へスクロールしていく見た目になる)。
  const startIndex = HM_MAX_SAMPLES - samples.length;
  const points = samples.map((ratio, i) => ({
    x: (startIndex + i) * stepX,
    y: ratio === null ? null : height - ratio * height,
  }));

  // null(欠測)のところで線を分割し、区間ごとに個別のパスとして描く。
  let segment = [];
  const flushSegment = () => {
    if (segment.length >= 2) {
      ctx.beginPath();
      ctx.moveTo(segment[0].x, segment[0].y);
      for (let i = 1; i < segment.length; i++) {
        ctx.lineTo(segment[i].x, segment[i].y);
      }
      ctx.lineWidth = 2;
      ctx.lineJoin = 'round';
      ctx.lineCap = 'round';
      ctx.strokeStyle = color;
      ctx.stroke();

      // 下側の面塗り(線と同色、不透明度 0.18)。
      ctx.beginPath();
      ctx.moveTo(segment[0].x, segment[0].y);
      for (let i = 1; i < segment.length; i++) {
        ctx.lineTo(segment[i].x, segment[i].y);
      }
      ctx.lineTo(segment[segment.length - 1].x, height);
      ctx.lineTo(segment[0].x, height);
      ctx.closePath();
      ctx.globalAlpha = 0.18;
      ctx.fillStyle = color;
      ctx.fill();
      ctx.globalAlpha = 1;
    }
    segment = [];
  };
  for (const point of points) {
    if (point.y === null) {
      flushSegment();
      continue;
    }
    segment.push(point);
  }
  flushSegment();
}

function hmFormatPercent(ratio) {
  return ratio === null || ratio === undefined ? '–' : Math.round(ratio * 100) + '%';
}

function hmFormatGb(bytes) {
  return bytes === null || bytes === undefined ? '–' : (bytes / (1024 * 1024 * 1024)).toFixed(1);
}

function applyHostMetrics(message) {
  const memRatio =
    typeof message.memUsedBytes === 'number' &&
    typeof message.memTotalBytes === 'number' &&
    message.memTotalBytes > 0
      ? message.memUsedBytes / message.memTotalBytes
      : null;

  hmPushSample(hmEntries.cpu, typeof message.cpu === 'number' ? message.cpu : null);
  hmPushSample(hmEntries.gpu, typeof message.gpu === 'number' ? message.gpu : null);
  hmPushSample(hmEntries.ane, typeof message.ane === 'number' ? message.ane : null);
  hmPushSample(hmEntries.mem, memRatio);

  hmEntries.cpu.value.textContent = hmFormatPercent(message.cpu);
  hmEntries.gpu.value.textContent = hmFormatPercent(message.gpu);
  hmEntries.ane.value.textContent = hmFormatPercent(message.ane);
  hmEntries.mem.value.textContent = hmFormatPercent(memRatio);

  hmEntries.cpu.el.title = 'CPU負荷 ' + hmFormatPercent(message.cpu);
  hmEntries.gpu.el.title = 'GPU負荷 ' + hmFormatPercent(message.gpu);
  hmEntries.ane.el.title = 'ANE負荷 ' + hmFormatPercent(message.ane) +
    (typeof message.aneWatts === 'number' ? '(' + message.aneWatts.toFixed(1) + 'W)' : '');
  hmEntries.mem.el.title = 'メモリ使用量 ' + hmFormatGb(message.memUsedBytes) + ' / ' +
    hmFormatGb(message.memTotalBytes) + ' GB(' + hmFormatPercent(memRatio) + ')';

  for (const entry of HM_ALL_ENTRIES) {
    hmDraw(entry);
  }
}

// テーマ切替(body の class に vscode-light 等が付け外しされる)を検知して全グラフを再描画する。
new MutationObserver(() => {
  for (const entry of HM_ALL_ENTRIES) {
    hmDraw(entry);
  }
}).observe(document.body, { attributes: true, attributeFilter: ['class'] });

// ---- メッセージ受信 ---------------------------------------------------------

window.addEventListener('message', (event) => {
  const message = event.data;
  if (!message || typeof message.type !== 'string') {
    return;
  }
  switch (message.type) {
    case 'devices':
      hideBanner();
      applyDevices(message.devices);
      break;
    case 'frame':
      applyFrame(message);
      break;
    case 'deviceError':
      applyDeviceError(message);
      break;
    case 'bootBusy':
      setBusy(!!message.busy);
      break;
    case 'processDown':
      showBanner(message.message);
      break;
    case 'hostMetrics':
      applyHostMetrics(message);
      break;
    case 'deviceOpBusy': {
      const entry = findTileByName(message.name);
      if (entry) {
        entry.opBusy = message.op ? { op: message.op, status: message.status || 'running' } : undefined;
        renderOpBadge(entry);
        if (deviceOpMenuEntry === entry) {
          renderDeviceOpMenuItem();
        }
      }
      break;
    }
    case 'deviceOpFailed':
      showBanner(message.name + ': ' + message.message);
      break;
    case 'laneSectionVisible':
      // レーンは常時表示になったため何もしない(TS側からのメッセージ自体は互換のため残る)
      break;
    case 'runEvent':
      applyLaneAction(message.action);
      break;
    case 'laneHydrate':
      applyLaneHydrate(message.snapshot);
      break;
    case 'profileInfo':
      applyProfileInfo(message);
      applyAppProfileInfo(message);
      applyRunProfileInfo(message);
      break;
    case 'machineProfileInfo':
      applyMachineProfileInfo(message);
      rerenderRunProfileFormIfClean();
      break;
    case 'machineProfileSelected':
      applyMachineProfileSelected(message);
      break;
    case 'deviceCatalog':
      applyDeviceCatalog(message);
      break;
    case 'createDeviceResult':
      applyCreateDeviceResult(message);
      break;
    case 'installedDevices':
      applyInstalledDevices(message);
      break;
    case 'machineDevicesSyncResult':
      applyMachineDevicesSyncResult(message);
      break;
    case 'machineDeviceUpdateResult':
      applyMachineDeviceUpdateResult(message);
      break;
    case 'runProfileSelected':
      applyRunProfileSelected(message);
      break;
    case 'runProfileData':
      applyRunProfileData(message);
      break;
    case 'runProfileSaveResult':
      applyRunProfileSaveResult(message);
      break;
    case 'runProfileFileChanged':
      applyRunProfileFileChanged(message);
      break;
    case 'appProfileSelected':
      applyAppProfileSelected(message);
      break;
    case 'appProfileData':
      applyAppProfileData(message);
      break;
    case 'appProfileSaveResult':
      applyAppProfileSaveResult(message);
      break;
    case 'appProfileFileChanged':
      applyAppProfileFileChanged(message);
      break;
    case 'nameInputOpen':
      applyNameInputOpen(message);
      break;
    default:
      break;
  }
});

btnUp.addEventListener('click', () => vscode.postMessage({ type: 'devicesUp' }));
btnDown.addEventListener('click', () => vscode.postMessage({ type: 'devicesDown' }));
btnRestart.addEventListener('click', () => {
  hideBanner();
  closeDeviceOpMenu();
  for (const entry of tiles.values()) {
    entry.tile.remove();
  }
  tiles.clear();
  selectedDeviceIds.clear();
  emptyMessage.style.display = 'flex';
  vscode.postMessage({ type: 'restartMonitor' });
});

// ---- プロファイルタブ: マシンプロファイル ---------------------------------------
// machines/*.json の内容(machineProfileInfo)を一覧表示し、「+新規作成」/「+既存から選択」
// からそれぞれのデバイス追加モーダルを開く。ホストとの往復が要るのは
// deviceCatalogRequest/createDevice/installedDevicesRequest/machineDevicesSync/
// machineDeviceRemove のみで、マシン選択(select の change)自体は受信済みデータの
// 再描画だけで完結する。

const machineSelect = document.getElementById('machine-select');
const machineNameStatic = document.getElementById('machine-name-static');
const btnMachineAdd = document.getElementById('btn-machine-add');
const btnMachineCopy = document.getElementById('btn-machine-copy');
const btnMachineRemove = document.getElementById('btn-machine-remove');
const btnMachineRename = document.getElementById('btn-machine-rename');
const btnDeviceAddExisting = document.getElementById('btn-device-add-existing');
const machineProfileError = document.getElementById('machine-profile-error');
const machineProfileBody = document.getElementById('machine-profile-body');
const machineDeviceList = document.getElementById('machine-device-list');
const profileDetailPlaceholder = document.getElementById('profile-detail-placeholder');
const machineDeviceEditor = document.getElementById('machine-device-editor');
const editorDeviceName = document.getElementById('editor-device-name');
const editorDevicePlatform = document.getElementById('editor-device-platform');
const editorIosFields = document.getElementById('editor-ios-fields');
const editorAndroidFields = document.getElementById('editor-android-fields');
const editorName = document.getElementById('editor-name');
const editorSimulator = document.getElementById('editor-simulator');
const editorOs = document.getElementById('editor-os');
const editorUdid = document.getElementById('editor-udid');
const editorPort = document.getElementById('editor-port');
const editorAvd = document.getElementById('editor-avd');
const editorError = document.getElementById('editor-error');
const editorConfirm = document.getElementById('editor-confirm');
const editorCancel = document.getElementById('editor-cancel');
const machineDeviceMenu = document.getElementById('machine-device-menu');
const machineDeviceMenuItemBtn = document.getElementById('machine-device-menu-item');

// 直近受信の machines 配列(machineProfileInfo)。空なら「マシンプロファイルなし」。
let machineProfiles = [];
let machineProfileHasError = false;
// 現在選択中とみなすマシン名(select の値。machines が0件なら null)。
let selectedMachine = null;
// 選択中デバイス名の集合(要件5: 複数選択に対応するため Set)。通常クリックは「その1台だけを
// 選択」(既にその1台だけの選択状態なら解除。従来のトグル感を維持)、Shift+クリックは
// アンカー(deviceSelectionAnchor)からの範囲選択、Cmd/Ctrl+クリックは個別の追加/除外トグル
// (Finder/VSCode のリストと同じ標準セマンティクス。2026-07-11 ユーザー指示)。マシン切替・
// 一覧再描画で一覧から消えた名前は Set から取り除く(validateSelectedDeviceName)。
// 右ペインの編集フォームはちょうど1台(size===1)のときだけ表示する。
let selectedDeviceNames = new Set();
// 範囲選択(Shift+クリック)の起点=直近に通常/Cmd(Ctrl)クリックした行の名前。Shift+クリック
// 自体ではアンカーを動かさない(連続 Shift+クリックで同じ起点から範囲を伸縮できる)。
// 一覧から消えたら validateSelectedDeviceName で null に戻す。
let deviceSelectionAnchor = null;
// macOS 判定(行の contextmenu リスナーで Ctrl+クリックを選択トグルへ振り分けるのに使う。
// 下の toggleDeviceRowSelection まわりのコメント参照)。
const isMacPlatform = /^Mac/.test(navigator.platform || '');
// 直近描画したデバイス行の DOM 要素(name -> row)。トグル選択・右クリックメニューの
// 対象存在チェックで、一覧全体を再描画せずに済ませるために使う。
let deviceRowElements = new Map();
// 右クリックメニュー(#machine-device-menu)を開いている対象(未オープンなら null)。
// { machine, name } の形(deviceOpMenuEntry がタイル entry を保持するのと対応)。
let machineDeviceMenuEntry = null;
// 右ペインの編集フォームの対象({ machine, platform, originalName }。未選択なら null)。
let editorTarget = null;
// フォームを最後に作り直した(＝選択・machineProfileInfo再プリフィル)時点の6フィールド値。
// dirty 判定(現在値との比較)・machineProfileInfo 再受信時の再プリフィル可否判定に使う。
let editorOriginalValues = null;
// いずれかのフィールドが元の値(editorOriginalValues)から変わっているか。
let editorDirty = false;
// machineDeviceUpdate の応答待ち中か(二重送信防止・machineProfileInfo 再受信時の
// 再プリフィル抑止に使う)。
let editorSubmitting = false;

function findMachine(name) {
  return machineProfiles.find((m) => m.name === name);
}

// (デバイス一覧と右ペインの分割スプリッター(#profile-splitter)は 2026-07-11 ユーザー指示で
// 廃止した。一覧幅は .machine-device-list の width: max-content で内容に自動フィットする。
// 旧実装の persistedState.machineListWidth は読まなくなるだけで無害なので放置する。)

// selectedDeviceNames のうち、現在の selectedMachine の一覧に存在しない名前を取り除く
// (要件: マシン切替・一覧更新で選択中デバイスが消えた場合)。存在するものは維持する
// (machineProfileInfo 再受信後も選択を名前で照合して引き継ぐ)。
function validateSelectedDeviceName() {
  const machine = findMachine(selectedMachine);
  const names = new Set(machine ? machine.devices.map((d) => d.name) : []);
  for (const name of selectedDeviceNames) {
    if (!names.has(name)) {
      selectedDeviceNames.delete(name);
    }
  }
  // 範囲選択(Shift+クリック)の起点も同様に照合し、一覧から消えていたら捨てる
  // (アンカー不在時の Shift+クリックは通常クリック扱いになる)。
  if (deviceSelectionAnchor !== null && !names.has(deviceSelectionAnchor)) {
    deviceSelectionAnchor = null;
  }
}

// machineProfileInfo 受信のたびに selectedMachine を検証し、無効なら current→先頭の順で
// フォールバックする(要件: 選択中マシンが一覧から消えた場合の復帰先)。
function applyMachineProfileInfo(message) {
  machineProfiles = Array.isArray(message.machines) ? message.machines : [];
  const error = typeof message.error === 'string' ? message.error : null;
  const current = typeof message.current === 'string' ? message.current : null;
  machineProfileHasError = !!error;

  if (!findMachine(selectedMachine)) {
    if (current !== null && findMachine(current)) {
      selectedMachine = current;
    } else {
      selectedMachine = machineProfiles.length > 0 ? machineProfiles[0].name : null;
    }
  }

  validateSelectedDeviceName();
  renderMachineSelect();
  renderMachineProfileBody(error);
  refreshEditorAfterProfileInfo();
  // 「+新規作成」「+既存から選択」は同一条件で有効/無効を切り替える(要件1)。
  btnDeviceAddExisting.disabled = machineProfileHasError || machineProfiles.length === 0;
  // [+] はプロジェクトさえ解決できれば追加先があるので machines 件数は問わない。
  // [−]/[✏] は対象(selectedMachine)が要るので、machines が0件のときも無効化する。
  btnMachineAdd.disabled = machineProfileHasError;
  btnMachineCopy.disabled = machineProfileHasError || machineProfiles.length === 0;
  btnMachineRemove.disabled = machineProfileHasError || machineProfiles.length === 0;
  btnMachineRename.disabled = machineProfileHasError || machineProfiles.length === 0;
}

// 追加/名前変更の直後にホストから届く、選択を新プロファイルへ移す通知。直前の
// machineProfileInfo とは順序が前後しない(postMessage は順序保証)ため、単純に上書きでよい。
// エラー時(machineProfileHasError)にホストがこのメッセージを送ってくることは無い前提だが、
// 念のため無視するガードを入れる。
function applyMachineProfileSelected(message) {
  if (machineProfileHasError) {
    return;
  }
  selectedMachine = message.name;
  validateSelectedDeviceName();
  renderMachineSelect();
  renderMachineProfileBody(null);
}

function renderMachineSelect() {
  if (machineProfiles.length >= 1) {
    machineSelect.style.display = '';
    machineNameStatic.style.display = 'none';
    machineSelect.textContent = '';
    for (const machine of machineProfiles) {
      const option = document.createElement('option');
      option.value = machine.name;
      option.textContent = machine.name;
      machineSelect.appendChild(option);
    }
    machineSelect.value = selectedMachine || '';
  } else {
    machineSelect.style.display = 'none';
    machineNameStatic.style.display = '';
    machineNameStatic.textContent = '(マシンプロファイルなし)';
  }
}

machineSelect.addEventListener('change', () => {
  selectedMachine = machineSelect.value;
  validateSelectedDeviceName();
  renderMachineProfileBody(machineProfileHasError ? machineProfileError.textContent : null);
  // マシン切替は明示操作なので、編集途中の値を破棄してフォームを作り直す(要件2)。
  rebuildEditorForSelection();
});

btnMachineAdd.addEventListener('click', () => vscode.postMessage({ type: 'machineProfileAdd' }));
btnMachineCopy.addEventListener('click', () => {
  if (selectedMachine) {
    vscode.postMessage({ type: 'machineProfileCopy', machine: selectedMachine });
  }
});
btnMachineRemove.addEventListener('click', () => {
  if (selectedMachine) {
    vscode.postMessage({ type: 'machineProfileDelete', machine: selectedMachine });
  }
});
btnMachineRename.addEventListener('click', () => {
  if (selectedMachine) {
    vscode.postMessage({ type: 'machineProfileRename', machine: selectedMachine });
  }
});

// 行クリックの選択(要件5。2026-07-11 ユーザー指示で Finder/VSCode のリストと同じ標準
// セマンティクスに変更)。判定順は shiftKey → metaKey/ctrlKey → 通常(Shift+Cmd 同時は
// Shift 扱い)。
// - Shift+クリック: 表示順(deviceRowElements の挿入順=renderMachineProfileBody の描画順)で
//   アンカー〜クリック行の間(両端含む)を選択に「置き換える」。アンカーは動かさない
//   (連続 Shift+クリックで同じ起点から範囲を伸縮できる)。アンカーが無効(null/一覧に不在)
//   なら通常クリックと同じ扱いにフォールバックする。
// - Cmd(metaKey)/Ctrl(ctrlKey)+クリック: クリック行を個別に追加/除外するトグル(従来の
//   Shift の挙動)。クリック行をアンカーに設定する。
// - 通常クリック: その1台だけを選択(既存の選択を置き換える)+クリック行をアンカーに設定。
//   既に「その1台だけが選択」状態なら解除する(従来のトグル感を維持。解除時はアンカーも null)。
function toggleDeviceRowSelection(name, event) {
  const anchorValid = deviceSelectionAnchor !== null && deviceRowElements.has(deviceSelectionAnchor);
  if (event.shiftKey && anchorValid) {
    const order = [...deviceRowElements.keys()];
    const anchorIndex = order.indexOf(deviceSelectionAnchor);
    const clickedIndex = order.indexOf(name);
    const start = Math.min(anchorIndex, clickedIndex);
    const end = Math.max(anchorIndex, clickedIndex);
    selectedDeviceNames = new Set(order.slice(start, end + 1));
  } else if (!event.shiftKey && (event.metaKey || event.ctrlKey)) {
    if (selectedDeviceNames.has(name)) {
      selectedDeviceNames.delete(name);
    } else {
      selectedDeviceNames.add(name);
    }
    deviceSelectionAnchor = name;
  } else if (selectedDeviceNames.size === 1 && selectedDeviceNames.has(name)) {
    selectedDeviceNames.clear();
    deviceSelectionAnchor = null;
  } else {
    selectedDeviceNames = new Set([name]);
    deviceSelectionAnchor = name;
  }
  updateDeviceSelectionUi();
  // 選択変更は明示操作なので、編集途中の値を破棄してフォームを作り直す(要件2)。
  rebuildEditorForSelection();
}

function updateDeviceSelectionUi() {
  for (const [name, row] of deviceRowElements) {
    row.classList.toggle('selected', selectedDeviceNames.has(name));
  }
}

function renderMachineProfileBody(error) {
  if (error) {
    machineProfileBody.style.display = 'none';
    machineProfileError.style.display = 'flex';
    machineProfileError.textContent = error;
    machineDeviceList.textContent = '';
    deviceRowElements = new Map();
    closeMachineDeviceMenu();
    return;
  }
  machineProfileError.style.display = 'none';
  machineProfileBody.style.display = 'flex';

  const machine = findMachine(selectedMachine);
  const devices = machine ? machine.devices : [];
  machineDeviceList.textContent = '';
  deviceRowElements = new Map();
  if (devices.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'machine-device-empty';
    empty.textContent = 'デバイスがありません。上のボタンから追加できます。';
    machineDeviceList.appendChild(empty);
  } else {
    for (const device of devices) {
      const row = document.createElement('div');
      row.className = 'machine-device-row';
      const name = document.createElement('span');
      // タイル/レーンのデバイス名ピルと同じ配色クラスを再利用する(tile-name-ios/-android)。
      name.className = 'tile-name tile-name-' + device.platform;
      name.textContent = device.name;
      const detail = document.createElement('div');
      detail.className = 'machine-device-detail';
      detail.textContent = device.detail;
      row.append(name, detail);
      row.addEventListener('click', (event) => toggleDeviceRowSelection(device.name, event));
      row.addEventListener('contextmenu', (event) => {
        event.preventDefault();
        event.stopPropagation();
        // macOS では Ctrl+クリックが OS レベルで右クリック扱いになり click イベントは発生せず
        // contextmenu として届くため、ここで選択トグルへ振り分ける(2026-07-11 ユーザー要望:
        // Cmd と同様に Ctrl でも追加選択したい)。contextmenu イベントにも
        // shiftKey/ctrlKey/metaKey は載っているので event をそのまま渡せば既存の判定
        // (Shift優先→Ctrl/Cmdで個別トグル)がそのまま効く。mac では物理右クリック+Ctrl
        // 押下も選択トグルになるが、メニューは素の右クリックで開けるため許容。
        // Windows/Linux の Ctrl+クリックは通常の click イベントで既に対応済みなので、
        // この振り分けは mac のみ。
        if (isMacPlatform && event.ctrlKey) {
          toggleDeviceRowSelection(device.name, event);
          return;
        }
        // クリックした行が現在の複数選択(2台以上)に含まれる場合は選択中全台を対象にする。
        // それ以外は従来どおりクリックした行単体を対象にする(要件5)。選択状態自体は
        // 右クリックでは変更しない。
        const names =
          selectedDeviceNames.size >= 2 && selectedDeviceNames.has(device.name)
            ? [...selectedDeviceNames]
            : [device.name];
        openMachineDeviceMenu({ machine: selectedMachine, names }, event.clientX, event.clientY);
      });
      deviceRowElements.set(device.name, row);
      machineDeviceList.appendChild(row);
    }
  }
  // 一覧再描画で対象デバイス/マシンが変わった場合、開いたままの右クリックメニューを残さない。
  if (
    machineDeviceMenuEntry &&
    (machineDeviceMenuEntry.machine !== selectedMachine ||
      !machineDeviceMenuEntry.names.every((name) => deviceRowElements.has(name)))
  ) {
    closeMachineDeviceMenu();
  }
  updateDeviceSelectionUi();
}

// 選択中マシンの全デバイス名(ios/android 横断。デバイス追加モーダルの重複検証に使う)。
function allDeviceNamesForSelectedMachine() {
  const machine = findMachine(selectedMachine);
  return machine ? machine.devices.map((d) => d.name) : [];
}

// ---- 右ペインの編集フォーム(要件2) ---------------------------------------------
// 行選択中は #machine-device-editor を表示し、machineDeviceUpdate で machines/*.json を
// 更新する。dirty(未確定の編集があるか)は6フィールドの現在値と、フォームを最後に作り直した
// 時点の値(editorOriginalValues)を素の文字列比較するだけで判定する(trim はしない。
// 「元の値から変わったか」という見た目上の判定であり、送信直前の検証・整形とは別の関心事)。

const EDITOR_PLATFORM_LABEL = { ios: 'iOS', android: 'Android' };
// input イベントを購読するのは編集可のフィールドだけ(機種/OS/UDID/AVD は選択・コピー可能な
// ラベル表示(span)であり、値が変わることはない)。
const editorFieldInputs = [editorName, editorPort];

// machines/*.json のデバイス1件(machineProfileInfo の生フィールド付き)から、フォームの
// 6フィールド分の文字列を組み立てる(undefined は空文字扱い。port は文字列化する)。
function deviceFieldValues(device) {
  return {
    name: device.name,
    simulator: device.simulator || '',
    os: device.os || '',
    udid: device.udid || '',
    port: device.port === undefined || device.port === null ? '' : String(device.port),
    avd: device.avd || '',
  };
}

function currentEditorValues() {
  // 機種/OS/UDID/AVD はラベル表示(span)なので textContent から読む(変わることはないが、
  // dirty 判定の比較対象として editorOriginalValues と同じ6フィールドの形を保つ)。
  return {
    name: editorName.value,
    simulator: editorSimulator.textContent,
    os: editorOs.textContent,
    udid: editorUdid.textContent,
    port: editorPort.value,
    avd: editorAvd.textContent,
  };
}

function valuesEqual(a, b) {
  return (
    a.name === b.name &&
    a.simulator === b.simulator &&
    a.os === b.os &&
    a.udid === b.udid &&
    a.port === b.port &&
    a.avd === b.avd
  );
}

// dirty(=確定ボタン有効)と、それに連動する確定/キャンセルボタンの見た目をまとめて更新する。
// キャンセルは dirty の間だけ表示し(要件2)、送信中(editorSubmitting)は確定・キャンセルとも
// 無効化する(確定は「確定中...」表示、キャンセルは表示は保ったまま押せなくする)。
function refreshEditorButtonsUi() {
  editorConfirm.disabled = editorSubmitting || !editorDirty;
  editorCancel.style.display = editorDirty ? '' : 'none';
  editorCancel.disabled = editorSubmitting;
}
function setEditorDirty(dirty) {
  editorDirty = dirty;
  refreshEditorButtonsUi();
}

// 選択中デバイスの値でフォームを作り直す(編集途中の値は破棄する)。
function renderDeviceEditor(machine, device) {
  editorTarget = { machine: machine, platform: device.platform, originalName: device.name };
  editorOriginalValues = deviceFieldValues(device);
  editorSubmitting = false;
  editorError.textContent = '';
  editorDeviceName.className = 'tile-name tile-name-' + device.platform;
  editorDeviceName.textContent = device.name;
  editorDevicePlatform.textContent = EDITOR_PLATFORM_LABEL[device.platform] || device.platform;
  editorName.value = editorOriginalValues.name;
  editorSimulator.textContent = editorOriginalValues.simulator;
  editorOs.textContent = editorOriginalValues.os;
  editorUdid.textContent = editorOriginalValues.udid;
  editorPort.value = editorOriginalValues.port;
  editorAvd.textContent = editorOriginalValues.avd;
  editorIosFields.style.display = device.platform === 'ios' ? '' : 'none';
  editorAndroidFields.style.display = device.platform === 'android' ? '' : 'none';
  editorConfirm.textContent = '確定';
  profileDetailPlaceholder.style.display = 'none';
  machineDeviceEditor.style.display = '';
  setEditorDirty(false);
}

// プレースホルダーの既定文言(HTML の初期テキストをそのまま使い回す。0台選択時に表示する)。
const DEVICE_PLACEHOLDER_DEFAULT_TEXT = profileDetailPlaceholder.textContent;

// text 省略時は既定文言(0台選択)。2台以上選択時は呼び出し側が件数入りの文言を渡す(要件5)。
function clearDeviceEditor(text) {
  editorTarget = null;
  editorOriginalValues = null;
  editorSubmitting = false;
  machineDeviceEditor.style.display = 'none';
  profileDetailPlaceholder.style.display = '';
  profileDetailPlaceholder.textContent = text !== undefined ? text : DEVICE_PLACEHOLDER_DEFAULT_TEXT;
  setEditorDirty(false);
}

// 右ペインの編集フォームは「ちょうど1台選択」のときだけ表示する(要件5)。0台は既定の
// プレースホルダー、2台以上は「<N>台選択中(右クリックで一括除去できます)」を表示する。
function singleSelectedDevice() {
  if (selectedDeviceNames.size !== 1) {
    return null;
  }
  const machine = findMachine(selectedMachine);
  if (!machine) {
    return null;
  }
  const [name] = selectedDeviceNames;
  return machine.devices.find((d) => d.name === name) || null;
}

// 選択変更・マシン切替(明示操作)用: ちょうど1台選択中ならその値でフォームを作り直し、
// それ以外(0台/2台以上)はプレースホルダーに戻す。編集途中の値は常に破棄する。
function rebuildEditorForSelection() {
  if (selectedDeviceNames.size >= 2) {
    clearDeviceEditor(selectedDeviceNames.size + '台選択中(右クリックで一括除去できます)');
    return;
  }
  const device = singleSelectedDevice();
  if (device) {
    renderDeviceEditor(selectedMachine, device);
  } else {
    clearDeviceEditor();
  }
}

// machineProfileInfo 再受信用: 選択中デバイスが消えていれば選択解除、存在してかつ未編集
// (dirty でない・送信中でない)なら新データで再プリフィルする。編集中(dirty)なら入力値を
// 保持する(watcher 経由の再送で入力が消えるのを防ぐ。要件2)。
function refreshEditorAfterProfileInfo() {
  if (machineProfileHasError) {
    clearDeviceEditor();
    return;
  }
  if (selectedDeviceNames.size >= 2) {
    clearDeviceEditor(selectedDeviceNames.size + '台選択中(右クリックで一括除去できます)');
    return;
  }
  if (selectedDeviceNames.size === 0) {
    clearDeviceEditor();
    return;
  }
  const device = singleSelectedDevice();
  if (!device) {
    clearDeviceEditor();
    return;
  }
  if (!editorDirty && !editorSubmitting) {
    renderDeviceEditor(selectedMachine, device);
  }
}

function onEditorFieldInput() {
  if (!editorTarget || editorSubmitting) {
    return;
  }
  setEditorDirty(!valuesEqual(currentEditorValues(), editorOriginalValues));
  // 入力を変えたら前回のエラー表示は古くなるので消す(次の「確定」クリックで再検証される)。
  editorError.textContent = '';
}
for (const input of editorFieldInputs) {
  input.addEventListener('input', onEditorFieldInput);
}

// キャンセル: 編集を破棄して選択中デバイスの最新値でフォームを作り直す。machineProfiles は
// 常に最新(watcher経由で追従)なので、rebuildEditorForSelection がそのまま
// 「現在のファイル状態に戻す」動作になる(エラー表示のクリアも rebuildEditorForSelection
// →renderDeviceEditor/clearDeviceEditor 内で行われる)。
editorCancel.addEventListener('click', () => {
  if (editorCancel.disabled) {
    return;
  }
  rebuildEditorForSelection();
});

// 複製元: src/monitorModel.ts の updateDeviceInMachineProfile の検証部分。webview は CSP により
// import 不可のため複製する(validateNewDeviceName の複製と同じ方針。ロジックを変更したら
// 両方に反映すること)。
function validateDeviceEditorFields(name) {
  if (name.length === 0) {
    return 'デバイス名を入力してください。';
  }
  const others = allDeviceNamesForSelectedMachine().filter((n) => n !== editorTarget.originalName);
  if (others.includes(name)) {
    return '「' + name + '」は既に存在します。';
  }
  if (editorTarget.platform === 'ios') {
    const portValue = editorPort.value.trim();
    // 注意: この関数は renderHtml のテンプレートリテラル内なので、正規表現の \d は \\d と
    // 書く必要がある(\d のままだと生成される webview JS では /^d+$/ になり、正しい数値入力を
    // 誤って弾くバグになる。v0.0.30 までの回帰)。
    if (portValue.length > 0 && (!/^\\d+$/.test(portValue) || Number(portValue) > 65535)) {
      return 'port は 0〜65535 の整数で入力してください。';
    }
  }
  return null;
}

editorConfirm.addEventListener('click', () => {
  if (editorConfirm.disabled || editorSubmitting || !editorTarget) {
    return;
  }
  const name = editorName.value.trim();
  const validationError = validateDeviceEditorFields(name);
  if (validationError) {
    editorError.textContent = validationError;
    return;
  }
  editorSubmitting = true;
  editorConfirm.textContent = '確定中...';
  editorError.textContent = '';
  refreshEditorButtonsUi();
  vscode.postMessage({
    type: 'machineDeviceUpdate',
    machine: editorTarget.machine,
    platform: editorTarget.platform,
    originalName: editorTarget.originalName,
    fields: {
      name: name,
      // 編集不可フィールドはラベル表示(span)の textContent = 元の値をそのまま往復させる。
      simulator: editorTarget.platform === 'ios' ? editorSimulator.textContent.trim() : '',
      os: editorTarget.platform === 'ios' ? editorOs.textContent.trim() : '',
      udid: editorTarget.platform === 'ios' ? editorUdid.textContent.trim() : '',
      port: editorTarget.platform === 'ios' ? editorPort.value.trim() : '',
      avd: editorTarget.platform === 'android' ? editorAvd.textContent.trim() : '',
    },
  });
});

// machineDeviceUpdate の結果(ok:true ならリネーム追従+一覧/フォームは直後の
// machineProfileInfo 再送(refreshEditorAfterProfileInfo)で最新化される。ok:false なら
// エラー表示のみで、入力値はそのまま残す=再操作可能)。
function applyMachineDeviceUpdateResult(message) {
  editorSubmitting = false;
  editorConfirm.textContent = '確定';
  if (message.ok) {
    selectedDeviceNames = new Set([message.name]);
    editorError.textContent = '';
    setEditorDirty(false);
  } else {
    refreshEditorButtonsUi();
    editorError.textContent = message.error || 'デバイスの更新に失敗しました。';
  }
}

// ---- デバイス行の右クリックメニュー(除去) -------------------------------------
// 見た目・挙動はタイルの #device-op-menu(openDeviceOpMenu/closeDeviceOpMenu)を踏襲するが、
// 状態(machineDeviceMenuEntry)・DOM要素は独立させる(タイルメニューの挙動に影響しないため)。

function closeMachineDeviceMenu() {
  if (!machineDeviceMenuEntry) {
    return;
  }
  machineDeviceMenuEntry = null;
  machineDeviceMenu.classList.remove('visible');
}

// entry は { machine, names }(names は1件以上)。複数選択(2台以上)を対象にする場合は
// メニュー項目のラベルを「選択した<N>台を除去」に変える(要件5)。
function openMachineDeviceMenu(entry, clientX, clientY) {
  machineDeviceMenuEntry = entry;
  machineDeviceMenuItemBtn.textContent =
    entry.names.length >= 2 ? '選択した' + entry.names.length + '台を除去' : '除去';
  machineDeviceMenu.classList.add('visible');
  clampMenuPosition(machineDeviceMenu, clientX, clientY);
}

machineDeviceMenuItemBtn.addEventListener('click', (event) => {
  event.stopPropagation();
  if (!machineDeviceMenuEntry) {
    return;
  }
  vscode.postMessage({
    type: 'machineDeviceRemove',
    machine: machineDeviceMenuEntry.machine,
    names: machineDeviceMenuEntry.names,
  });
  closeMachineDeviceMenu();
});

// 外クリック・Esc・スクロール・リサイズで閉じる(#device-op-menu と同じ方針だが、
// 独立したリスナーとして登録する)。
document.addEventListener('click', (event) => {
  if (machineDeviceMenuEntry && !machineDeviceMenu.contains(event.target)) {
    closeMachineDeviceMenu();
  }
});
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    closeMachineDeviceMenu();
  }
});
document.addEventListener('scroll', () => closeMachineDeviceMenu(), true);
window.addEventListener('resize', () => closeMachineDeviceMenu());
// 行上の contextmenu は stopPropagation 済みなのでここには来ない(行外で右クリックした
// 場合に残さないためのガード。#device-op-menu の同種ハンドラと同じ理由)。
document.addEventListener('contextmenu', () => closeMachineDeviceMenu());

// ---- プロファイルタブ中段: アプリプロファイルの設定フォーム -----------------------
// 一覧・初期選択は既存 profileInfo(applyProfileInfo/applyRunProfileInfo とは独立に
// applyAppProfileInfo で受ける。message.apps を使う)。この選択は webview 内だけで完結し、
// 他のどの設定にも連動しない(実行プロファイルセクションと違い「現在値」に相当する設定が
// 無いため、フォールバックは常に一覧の先頭)。dirty 管理・再ロードの方針は実行プロファイル
// セクション(下記)と同じ:
// - フォーム値と appProfileOriginalFields の比較で「確定」を有効化。
// - 選択変更(明示操作)で編集破棄して再ロード。
// - profileInfo 再受信時、編集中(dirty/送信中)ならフォーム値保持、未編集なら再ロード。
//   編集対象が一覧から消えたらフォールバック(先頭)。
// - appProfileFileChanged(外部編集)は編集対象と同名 && 未編集のときのみ再ロード。
// クライアント側の必須検証は無い(common/ios/android の全フィールドが省略可のため。
// Swift 側 validate-profile の役割)。

const appProfileSelect = document.getElementById('app-profile-select');
const appProfileNameStatic = document.getElementById('app-profile-name-static');
const btnAppProfileAdd = document.getElementById('btn-app-profile-add');
const btnAppProfileCopy = document.getElementById('btn-app-profile-copy');
const btnAppProfileRemove = document.getElementById('btn-app-profile-remove');
const btnAppProfileRename = document.getElementById('btn-app-profile-rename');
const appProfilePlaceholder = document.getElementById('app-profile-placeholder');
const appProfileEditor = document.getElementById('app-profile-editor');
const appProfileError = document.getElementById('app-profile-error');
const appProfileConfirm = document.getElementById('app-profile-confirm');
const appProfileCancel = document.getElementById('app-profile-cancel');

// common/ios/android それぞれの DOM 参照をまとめて持つ(renderAppProfileEditor・
// collectAppProfileFields・appProfileValuesEqual・setAppProfileControlsEnabled が使う)。
// common は表示名(appName)+自動インストールのチェックボックス(heal と同じマークアップ。
// 既定=チェックOFF=無効)、ios/android は app/appPath が廃止されフォーム自体に無いため
// 表示名/アプリID/パッケージパスの3項目のみ(自動インストールを common に一本化した
// 2026-07-11 指示に伴い、以前ここにあった autoInstall チェックボックスは common へ移設)。
const appProfileGroups = {
  common: {
    appName: document.getElementById('app-profile-common-app-name'),
    autoInstall: document.getElementById('app-profile-common-auto-install'),
  },
  ios: {
    appName: document.getElementById('app-profile-ios-app-name'),
    app: document.getElementById('app-profile-ios-app'),
    appPath: document.getElementById('app-profile-ios-app-path'),
  },
  android: {
    appName: document.getElementById('app-profile-android-app-name'),
    app: document.getElementById('app-profile-android-app'),
    appPath: document.getElementById('app-profile-android-app-path'),
  },
};
const APP_PROFILE_GROUP_NAMES = ['common', 'ios', 'android'];
// app/appPath を持つのは ios/android のみ(common には無い)。
const APP_PROFILE_PLATFORM_GROUP_NAMES = ['ios', 'android'];

// 自動インストールはチェックボックス1つで内部表現("true"/"false")の読み書きを行う
// (monitorModel.ts の AppProfileCommonFields.autoInstall と同じ2値の文字列。common に
// 一本化される前は AppProfilePlatformFields.autoInstall として ios/android 別に持っていたが、
// dom.autoInstall を読み書きする形自体は変わらないため、呼び出し側を
// appProfileGroups.common に変えるだけで済んだ。保存意味論(true→autoInstall:trueをセット、
// false→キー削除)も不変)。
function getAppProfileAutoInstall(dom) {
  return dom.autoInstall.checked ? 'true' : 'false';
}
function setAppProfileAutoInstall(dom, value) {
  dom.autoInstall.checked = value === 'true';
}

// 直近受信の一覧(profileInfo.apps 由来)。
let appProfileNames = [];
// 編集対象のアプリプロファイル名(一覧が0件なら null)。
let selectedAppProfile = null;
// 直近ロード(appProfileData ok:true)時点のフィールド値。null の間はフォーム非表示。
let appProfileOriginalFields = null;
let appProfileDirty = false;
let appProfileSubmitting = false;

function appProfileEditing() {
  return appProfileDirty || appProfileSubmitting;
}

// dirty(=確定ボタン有効)と、それに連動する確定/キャンセルボタンの見た目をまとめて更新する
// (editorForm の refreshEditorButtonsUi/setEditorDirty と同じ方針)。
function refreshAppProfileButtonsUi() {
  appProfileConfirm.disabled = appProfileSubmitting || !appProfileDirty;
  appProfileCancel.style.display = appProfileDirty ? '' : 'none';
  appProfileCancel.disabled = appProfileSubmitting;
}
function setAppProfileDirty(dirty) {
  appProfileDirty = dirty;
  refreshAppProfileButtonsUi();
}

function showAppProfilePlaceholder(text) {
  appProfileOriginalFields = null;
  appProfileSubmitting = false;
  appProfileEditor.style.display = 'none';
  appProfilePlaceholder.style.display = '';
  appProfilePlaceholder.textContent = text;
  setAppProfileDirty(false);
}

function requestAppProfileLoad() {
  if (!selectedAppProfile) {
    showAppProfilePlaceholder('アプリプロファイルがありません。');
    return;
  }
  // 応答(appProfileData)が来るまで編集させない(requestRunProfileLoad と同じ理由)。
  showAppProfilePlaceholder('読み込み中...');
  vscode.postMessage({ type: 'appProfileLoad', profile: selectedAppProfile });
}

// profileInfo 受信(applyProfileInfo/applyRunProfileInfo と独立)。選択の維持/フォールバックと
// 再ロードを行う。「現在値」に相当する設定が無いため、applyRunProfileInfo と違い先頭への
// フォールバックのみ。
function applyAppProfileInfo(message) {
  appProfileNames = Array.isArray(message.apps) ? message.apps : [];

  const previous = selectedAppProfile;
  if (selectedAppProfile === null || !appProfileNames.includes(selectedAppProfile)) {
    selectedAppProfile = appProfileNames.length > 0 ? appProfileNames[0] : null;
  }
  renderAppProfileSelect();
  // [+] は profileInfo を受信できた時点で追加先(プロジェクト)があるので常に有効。
  // コピー/−/✏ は対象(選択中のアプリプロファイル)が要るので、一覧0件のときは無効化する
  // (applyRunProfileInfo と同じ方針)。
  btnAppProfileAdd.disabled = false;
  btnAppProfileCopy.disabled = appProfileNames.length === 0;
  btnAppProfileRemove.disabled = appProfileNames.length === 0;
  btnAppProfileRename.disabled = appProfileNames.length === 0;

  if (selectedAppProfile !== previous) {
    requestAppProfileLoad();
    return;
  }
  if (selectedAppProfile !== null && !appProfileEditing()) {
    requestAppProfileLoad();
  } else if (selectedAppProfile === null) {
    showAppProfilePlaceholder('アプリプロファイルがありません。');
  }
}

function renderAppProfileSelect() {
  if (appProfileNames.length >= 1) {
    appProfileSelect.style.display = '';
    appProfileNameStatic.style.display = 'none';
    appProfileSelect.textContent = '';
    for (const name of appProfileNames) {
      const option = document.createElement('option');
      option.value = name;
      option.textContent = name;
      appProfileSelect.appendChild(option);
    }
    appProfileSelect.value = selectedAppProfile || '';
  } else {
    appProfileSelect.style.display = 'none';
    appProfileNameStatic.style.display = '';
  }
}

appProfileSelect.addEventListener('change', () => {
  // 選択変更は明示操作なので、編集途中の値を破棄して選択先を再ロードする。
  selectedAppProfile = appProfileSelect.value;
  requestAppProfileLoad();
});

btnAppProfileAdd.addEventListener('click', () => vscode.postMessage({ type: 'appProfileAdd' }));
btnAppProfileCopy.addEventListener('click', () => {
  if (selectedAppProfile) {
    vscode.postMessage({ type: 'appProfileCopy', profile: selectedAppProfile });
  }
});
btnAppProfileRemove.addEventListener('click', () => {
  if (selectedAppProfile) {
    vscode.postMessage({ type: 'appProfileDelete', profile: selectedAppProfile });
  }
});
btnAppProfileRename.addEventListener('click', () => {
  if (selectedAppProfile) {
    vscode.postMessage({ type: 'appProfileRename', profile: selectedAppProfile });
  }
});

// 追加/コピー/名前変更の直後にホストから届く、選択(編集対象)を新プロファイルへ移す通知
// (applyRunProfileSelected と同じ趣旨)。
function applyAppProfileSelected(message) {
  if (!appProfileNames.includes(message.name)) {
    return;
  }
  selectedAppProfile = message.name;
  renderAppProfileSelect();
  requestAppProfileLoad();
}

// appProfileData 受信: 編集対象と同じプロファイルの応答のみ反映する(applyRunProfileData と
// 同じガード)。
function applyAppProfileData(message) {
  if (message.profile !== selectedAppProfile) {
    return;
  }
  if (appProfileEditing()) {
    return;
  }
  if (!message.ok || !message.fields) {
    showAppProfilePlaceholder(message.error || 'アプリプロファイルを読み込めませんでした。');
    return;
  }
  renderAppProfileEditor(message.fields);
}

// iOS/Android の表示名(appName)入力欄のプレースホルダーに、共通(common)の表示名フィールドの
// 現在の入力値を表示する。appName は common → platform の順で後勝ちマージされるため、platform
// 側が空欄のときの実効値は common の値になる — その「継承される値」をウォーターマークとして
// 見せることで、空欄の意味(未入力=common の値がそのまま使われる)を一目で分かるようにする。
// 共通の表示名が空ならプレースホルダーも空でよい(素の value をそのまま使う)。
function updateAppProfileNamePlaceholders() {
  const inherited = appProfileGroups.common.appName.value;
  for (const group of APP_PROFILE_PLATFORM_GROUP_NAMES) {
    appProfileGroups[group].appName.placeholder = inherited;
  }
}

// ロード済みの値でフォームを作り直す(編集途中の値は破棄する)。
function renderAppProfileEditor(fields) {
  appProfileOriginalFields = fields;
  appProfileSubmitting = false;
  appProfileError.textContent = '';

  // 表示名(appName)は common/ios/android 共通で持つ唯一のフィールドなので3グループまとめて
  // 設定する。
  for (const group of APP_PROFILE_GROUP_NAMES) {
    appProfileGroups[group].appName.value = fields[group].appName;
  }
  // 自動インストールは common に一本化されている(2026-07-11 指示)。
  setAppProfileAutoInstall(appProfileGroups.common, fields.common.autoInstall);
  // アプリID・パッケージパスは ios/android のみ(common には無い)。
  for (const group of APP_PROFILE_PLATFORM_GROUP_NAMES) {
    const dom = appProfileGroups[group];
    const values = fields[group];
    dom.app.value = values.app;
    dom.appPath.value = values.appPath;
  }
  // プリフィル直後の共通表示名を反映してプレースホルダーを初期化する。
  updateAppProfileNamePlaceholders();

  setAppProfileControlsEnabled(true);
  appProfileConfirm.textContent = '確定';
  appProfilePlaceholder.style.display = 'none';
  appProfileEditor.style.display = '';
  setAppProfileDirty(false);
}

// 現在のフォーム入力値を、appProfileSave の fields と同じ形(common は表示名+自動インストールの
// 2項目、ios/android は表示名/アプリID/パッケージパスの3項目。text 系は trim 済み)で集める。
function collectAppProfileFields() {
  const fields = {
    common: {
      appName: appProfileGroups.common.appName.value.trim(),
      autoInstall: getAppProfileAutoInstall(appProfileGroups.common),
    },
  };
  for (const group of APP_PROFILE_PLATFORM_GROUP_NAMES) {
    const dom = appProfileGroups[group];
    fields[group] = {
      appName: dom.appName.value.trim(),
      app: dom.app.value.trim(),
      appPath: dom.appPath.value.trim(),
    };
  }
  return fields;
}

function appProfileValuesEqual(fields) {
  const current = collectAppProfileFields();
  if (
    current.common.appName !== fields.common.appName ||
    current.common.autoInstall !== fields.common.autoInstall
  ) {
    return false;
  }
  return APP_PROFILE_PLATFORM_GROUP_NAMES.every((group) => {
    const a = current[group];
    const b = fields[group];
    return a.appName === b.appName && a.app === b.app && a.appPath === b.appPath;
  });
}

function onAppProfileFormInput() {
  if (appProfileOriginalFields === null || appProfileSubmitting) {
    return;
  }
  setAppProfileDirty(!appProfileValuesEqual(appProfileOriginalFields));
  // 入力を変えたら前回のエラー表示は古くなるので消す(runProfileError と同じ方針)。
  appProfileError.textContent = '';
}

for (const group of APP_PROFILE_GROUP_NAMES) {
  appProfileGroups[group].appName.addEventListener('input', onAppProfileFormInput);
}
appProfileGroups.common.autoInstall.addEventListener('change', onAppProfileFormInput);
// 共通の表示名を編集するたび、iOS/Android のプレースホルダー(継承値のライブプレビュー)を
// 更新する。
appProfileGroups.common.appName.addEventListener('input', updateAppProfileNamePlaceholders);
for (const group of APP_PROFILE_PLATFORM_GROUP_NAMES) {
  const dom = appProfileGroups[group];
  dom.app.addEventListener('input', onAppProfileFormInput);
  dom.appPath.addEventListener('input', onAppProfileFormInput);
}

function setAppProfileControlsEnabled(enabled) {
  for (const group of APP_PROFILE_GROUP_NAMES) {
    appProfileGroups[group].appName.disabled = !enabled;
  }
  appProfileGroups.common.autoInstall.disabled = !enabled;
  for (const group of APP_PROFILE_PLATFORM_GROUP_NAMES) {
    const dom = appProfileGroups[group];
    dom.app.disabled = !enabled;
    dom.appPath.disabled = !enabled;
  }
}

appProfileConfirm.addEventListener('click', () => {
  if (appProfileConfirm.disabled || appProfileSubmitting || !selectedAppProfile) {
    return;
  }
  appProfileSubmitting = true;
  setAppProfileControlsEnabled(false);
  appProfileConfirm.textContent = '確定中...';
  appProfileError.textContent = '';
  refreshAppProfileButtonsUi();
  vscode.postMessage({
    type: 'appProfileSave',
    profile: selectedAppProfile,
    fields: collectAppProfileFields(),
  });
});

// キャンセル: dirty/送信中フラグを先に解除してから appProfileLoad を再送する
// (applyAppProfileData は appProfileEditing() の間は応答を無視するガードがあるため、
// 先に解除しておかないと再ロード結果が反映されない)。requestAppProfileLoad は内部で
// showAppProfilePlaceholder→setAppProfileDirty(false) を呼ぶため、この順序を満たす。
appProfileCancel.addEventListener('click', () => {
  if (appProfileCancel.disabled) {
    return;
  }
  appProfileError.textContent = '';
  requestAppProfileLoad();
});

// appProfileSave の結果。ok なら dirty 解除(ホストが続けて appProfileData を送るので、
// フォームはそこで最新値に作り直される)。ok:false ならエラー表示のみで入力値は残す。
function applyAppProfileSaveResult(message) {
  if (message.profile !== selectedAppProfile) {
    return;
  }
  appProfileSubmitting = false;
  appProfileConfirm.textContent = '確定';
  setAppProfileControlsEnabled(true);
  if (message.ok) {
    appProfileError.textContent = '';
    setAppProfileDirty(false);
  } else {
    refreshAppProfileButtonsUi();
    appProfileError.textContent = message.error || 'アプリプロファイルの更新に失敗しました。';
  }
}

// apps/<name>.json の外部編集(watcher onDidChange)。編集対象と同名 && 未編集のときのみ
// 再ロードして自動反映する(applyRunProfileFileChanged と同じ方針)。
function applyAppProfileFileChanged(message) {
  if (message.name === selectedAppProfile && !appProfileEditing()) {
    vscode.postMessage({ type: 'appProfileLoad', profile: selectedAppProfile });
  }
}

// ---- プロファイルタブ上段: 実行プロファイルの設定フォーム -----------------------
// 一覧・初期選択は既存 profileInfo(applyProfileInfo とは独立に applyRunProfileInfo で受ける)。
// この選択は「編集対象」であり ftester.profile 設定には触れない(デバイスタブのドロップダウン
// とは独立)。dirty 管理はマシンプロファイルのデバイス編集フォームと同じ方針:
// - フォーム値と runProfileOriginalFields の比較で「確定」を有効化。
// - 選択変更(明示操作)で編集破棄して再ロード。
// - profileInfo/machineProfileInfo 再受信時、編集中(dirty/送信中)ならフォーム値保持、
//   未編集なら再ロード/再描画。編集対象が一覧から消えたらフォールバック(current→先頭)。
// - runProfileFileChanged(外部編集)は編集対象と同名 && 未編集のときのみ再ロード。

const runProfileSelect = document.getElementById('run-profile-select');
const runProfileNameStatic = document.getElementById('run-profile-name-static');
const btnRunProfileAdd = document.getElementById('btn-run-profile-add');
const btnRunProfileCopy = document.getElementById('btn-run-profile-copy');
const btnRunProfileRemove = document.getElementById('btn-run-profile-remove');
const btnRunProfileRename = document.getElementById('btn-run-profile-rename');
const runProfilePlaceholder = document.getElementById('run-profile-placeholder');
const runProfileEditor = document.getElementById('run-profile-editor');
const runProfileMachine = document.getElementById('run-profile-machine');
const runProfileApp = document.getElementById('run-profile-app');
const runProfileDevices = document.getElementById('run-profile-devices');
const runProfileHeal = document.getElementById('run-profile-heal');
const runProfileReportDir = document.getElementById('run-profile-report-dir');
const runProfileDefaultTimeout = document.getElementById('run-profile-default-timeout');
const runProfileError = document.getElementById('run-profile-error');
const runProfileConfirm = document.getElementById('run-profile-confirm');
const runProfileCancel = document.getElementById('run-profile-cancel');

// 直近受信の一覧(profileInfo 由来)。
let runProfileNames = [];
let runProfileApps = [];
// 編集対象の実行プロファイル名(一覧が0件なら null)。
let selectedRunProfile = null;
// 直近ロード(runProfileData ok:true)時点の6フィールド値。null の間はフォーム非表示。
let runProfileOriginalFields = null;
// 現在チェック済みのデバイス名(表示順。チェックボックス操作・machine切替の引き継ぎの正)。
let runProfileCheckedNames = [];
let runProfileDirty = false;
let runProfileSubmitting = false;

function runProfileEditing() {
  return runProfileDirty || runProfileSubmitting;
}

// dirty(=確定ボタン有効)と、それに連動する確定/キャンセルボタンの見た目をまとめて更新する
// (editorForm の refreshEditorButtonsUi/setEditorDirty と同じ方針)。
function refreshRunProfileButtonsUi() {
  runProfileConfirm.disabled = runProfileSubmitting || !runProfileDirty;
  runProfileCancel.style.display = runProfileDirty ? '' : 'none';
  runProfileCancel.disabled = runProfileSubmitting;
}
function setRunProfileDirty(dirty) {
  runProfileDirty = dirty;
  refreshRunProfileButtonsUi();
}

function showRunProfilePlaceholder(text) {
  runProfileOriginalFields = null;
  runProfileSubmitting = false;
  runProfileEditor.style.display = 'none';
  runProfilePlaceholder.style.display = '';
  runProfilePlaceholder.textContent = text;
  setRunProfileDirty(false);
}

function requestRunProfileLoad() {
  if (!selectedRunProfile) {
    showRunProfilePlaceholder('実行プロファイルがありません。');
    return;
  }
  // 応答(runProfileData)が来るまで編集させない(応答前の編集がロード結果に上書きされる
  // レースを避ける。ローカルファイル読みなので一瞬で置き換わる)。
  showRunProfilePlaceholder('読み込み中...');
  vscode.postMessage({ type: 'runProfileLoad', profile: selectedRunProfile });
}

// profileInfo 受信(applyProfileInfo と独立)。選択の維持/フォールバックと再ロードを行う。
function applyRunProfileInfo(message) {
  runProfileNames = Array.isArray(message.profiles) ? message.profiles : [];
  // apps は後方互換(古いホストからは届かない)のため配列でなければ空扱い。
  runProfileApps = Array.isArray(message.apps) ? message.apps : [];
  const current = typeof message.current === 'string' ? message.current : '';

  const previous = selectedRunProfile;
  if (selectedRunProfile === null || !runProfileNames.includes(selectedRunProfile)) {
    // 編集対象が未定/一覧から消えた: current→先頭の順でフォールバック(編集破棄)。
    if (current !== '' && runProfileNames.includes(current)) {
      selectedRunProfile = current;
    } else {
      selectedRunProfile = runProfileNames.length > 0 ? runProfileNames[0] : null;
    }
  }
  renderRunProfileSelect();
  // [+] は profileInfo を受信できた時点で追加先(プロジェクト)があるので常に有効。
  // コピー/−/✏ は対象(選択中の実行プロファイル)が要るので、一覧0件のときは無効化する
  // (マシンプロファイルの btnMachineCopy/Remove/Rename と同じ方針)。
  btnRunProfileAdd.disabled = false;
  btnRunProfileCopy.disabled = runProfileNames.length === 0;
  btnRunProfileRemove.disabled = runProfileNames.length === 0;
  btnRunProfileRename.disabled = runProfileNames.length === 0;

  if (selectedRunProfile !== previous) {
    requestRunProfileLoad();
    return;
  }
  // 選択が変わらない場合: 編集中ならフォーム値を保持し、未編集なら再ロードして最新化する
  // (apps 一覧の変化もロード後の再描画で反映される)。
  if (selectedRunProfile !== null && !runProfileEditing()) {
    requestRunProfileLoad();
  } else if (selectedRunProfile === null) {
    showRunProfilePlaceholder('実行プロファイルがありません。');
  }
}

function renderRunProfileSelect() {
  if (runProfileNames.length >= 1) {
    runProfileSelect.style.display = '';
    runProfileNameStatic.style.display = 'none';
    runProfileSelect.textContent = '';
    for (const name of runProfileNames) {
      const option = document.createElement('option');
      option.value = name;
      option.textContent = name;
      runProfileSelect.appendChild(option);
    }
    runProfileSelect.value = selectedRunProfile || '';
  } else {
    runProfileSelect.style.display = 'none';
    runProfileNameStatic.style.display = '';
  }
}

runProfileSelect.addEventListener('change', () => {
  // 選択変更は明示操作なので、編集途中の値を破棄して選択先を再ロードする。
  selectedRunProfile = runProfileSelect.value;
  requestRunProfileLoad();
});

btnRunProfileAdd.addEventListener('click', () => vscode.postMessage({ type: 'profileAdd' }));
btnRunProfileCopy.addEventListener('click', () => {
  if (selectedRunProfile) {
    vscode.postMessage({ type: 'profileCopy', profile: selectedRunProfile });
  }
});
btnRunProfileRemove.addEventListener('click', () => {
  if (selectedRunProfile) {
    vscode.postMessage({ type: 'profileDelete', profile: selectedRunProfile });
  }
});
btnRunProfileRename.addEventListener('click', () => {
  if (selectedRunProfile) {
    vscode.postMessage({ type: 'profileRename', profile: selectedRunProfile });
  }
});

// 追加/コピー/名前変更の直後にホストから届く、選択(編集対象)を新プロファイルへ移す通知
// (machineProfileSelected と同じ趣旨)。直前の profileInfo とは順序が前後しない
// (postMessage は順序保証)ため単純に上書きでよいが、念のため一覧に無い名前は無視するガードを
// 入れる(applyRunProfileInfo のフォールバック判定と同じ runProfileNames.includes を使う)。
function applyRunProfileSelected(message) {
  if (!runProfileNames.includes(message.name)) {
    return;
  }
  selectedRunProfile = message.name;
  renderRunProfileSelect();
  requestRunProfileLoad();
}

// machineProfileInfo 再受信時(メッセージスイッチから呼ばれる): 未編集ならロード済みの値で
// フォームを作り直す(マシン一覧・デバイス一覧の変化を反映)。編集中なら入力値を保持する。
function rerenderRunProfileFormIfClean() {
  if (runProfileOriginalFields !== null && !runProfileEditing()) {
    renderRunProfileEditor(runProfileOriginalFields);
  }
}

// runProfileData 受信: 編集対象と同じプロファイルの応答のみ反映する(選択変更直後に届く
// 前の選択への応答を無視するガード)。
function applyRunProfileData(message) {
  if (message.profile !== selectedRunProfile) {
    return;
  }
  // 編集中(dirty/送信中)は反映しない(保存成功直後の再送は dirty 解除済みなので反映される)。
  if (runProfileEditing()) {
    return;
  }
  if (!message.ok || !message.fields) {
    showRunProfilePlaceholder(message.error || '実行プロファイルを読み込めませんでした。');
    return;
  }
  renderRunProfileEditor(message.fields);
}

// ロード済みの6フィールド値でフォームを作り直す(編集途中の値は破棄する)。
function renderRunProfileEditor(fields) {
  runProfileOriginalFields = fields;
  runProfileSubmitting = false;
  runProfileError.textContent = '';

  renderRunProfileMachineSelect(fields.machine);
  renderRunProfileAppSelect(fields.app);
  runProfileCheckedNames = fields.devices.slice();
  renderRunProfileDevices();
  runProfileHeal.checked = fields.heal;
  runProfileReportDir.value = fields.reportDir;
  runProfileDefaultTimeout.value = fields.defaultTimeout;

  setRunProfileControlsEnabled(true);
  runProfileConfirm.textContent = '確定';
  runProfilePlaceholder.style.display = 'none';
  runProfileEditor.style.display = '';
  setRunProfileDirty(false);
}

// 「使用するマシンプロファイル」select。選択肢 = machineProfiles(machineProfileInfo 由来)の
// 名前。value が未指定("")/一覧に無い場合は先頭に「(未指定)」(value="")を付け、一覧に無い
// 非空値はオプション補完で表示する(デバイスタブの applyProfileInfo の unknownOption と同じ方針)。
function renderRunProfileMachineSelect(value) {
  runProfileMachine.textContent = '';
  const names = machineProfiles.map((m) => m.name);
  if (value === '' || !names.includes(value)) {
    const unspecified = document.createElement('option');
    unspecified.value = '';
    unspecified.textContent = '(未指定)';
    runProfileMachine.appendChild(unspecified);
  }
  for (const name of names) {
    const option = document.createElement('option');
    option.value = name;
    option.textContent = name;
    runProfileMachine.appendChild(option);
  }
  if (value !== '' && !names.includes(value)) {
    const unknown = document.createElement('option');
    unknown.value = value;
    unknown.textContent = value;
    runProfileMachine.appendChild(unknown);
  }
  runProfileMachine.value = value;
}

// 「アプリ」select。選択肢 = profileInfo.apps。現在値が一覧に無ければオプション補完する。
function renderRunProfileAppSelect(value) {
  runProfileApp.textContent = '';
  let matched = value === '';
  // 空文字(未指定)の option を常に先頭に置く(app 欠落プロファイルの現在値を表せるように。
  // 空のまま確定しようとするとクライアント検証で弾かれる)。
  const emptyOption = document.createElement('option');
  emptyOption.value = '';
  emptyOption.textContent = '(未指定)';
  runProfileApp.appendChild(emptyOption);
  for (const name of runProfileApps) {
    const option = document.createElement('option');
    option.value = name;
    option.textContent = name;
    runProfileApp.appendChild(option);
    if (name === value) {
      matched = true;
    }
  }
  if (!matched) {
    const unknown = document.createElement('option');
    unknown.value = value;
    unknown.textContent = value;
    runProfileApp.appendChild(unknown);
  }
  runProfileApp.value = value;
}

// デバイスのチェックボックス一覧。選択肢 = フォームで選択中のマシンプロファイルのデバイス。
// runProfileCheckedNames に含まれる名前はチェック済み。チェック済みだがマシンに存在しない
// 名前は末尾に注記付きで表示する(チェックを外して確定すれば取り除ける)。マシン未指定("")の
// 間は案内のみ表示する。
function renderRunProfileDevices() {
  runProfileDevices.textContent = '';
  const machineName = runProfileMachine.value;
  if (machineName === '') {
    const note = document.createElement('div');
    note.className = 'run-profile-device-note';
    note.textContent = 'マシンプロファイルを指定するとデバイスを選択できます';
    runProfileDevices.appendChild(note);
    return;
  }
  const machine = findMachine(machineName);
  const machineDevices = machine ? machine.devices : [];
  const machineDeviceNames = machineDevices.map((d) => d.name);
  const appendRow = (name, platform, missing) => {
    const row = document.createElement('label');
    row.className = 'run-profile-device-row';
    const checkbox = document.createElement('input');
    checkbox.type = 'checkbox';
    checkbox.checked = runProfileCheckedNames.includes(name);
    checkbox.dataset.deviceName = name;
    checkbox.addEventListener('change', onRunProfileDeviceToggle);
    const pill = document.createElement('span');
    // タイル/レーンと同じ配色ピル(.tile-name-ios/-android)。マシンに存在しない名前は
    // プラットフォームが分からないので中立色(.tile-name-unknown)にする。
    pill.className = 'tile-name ' + (platform ? 'tile-name-' + platform : 'tile-name-unknown');
    pill.textContent = name;
    row.append(checkbox, pill);
    if (missing) {
      const note = document.createElement('span');
      note.className = 'run-profile-device-note';
      note.textContent = '(マシンプロファイルにありません)';
      row.appendChild(note);
    }
    runProfileDevices.appendChild(row);
  };
  for (const device of machineDevices) {
    appendRow(device.name, device.platform, false);
  }
  for (const name of runProfileCheckedNames) {
    if (!machineDeviceNames.includes(name)) {
      appendRow(name, null, true);
    }
  }
}

// チェックボックス操作: DOM の表示順(マシンのデバイス順+欠落分)で checked を集め直す。
function onRunProfileDeviceToggle() {
  const checked = [];
  for (const checkbox of runProfileDevices.querySelectorAll('input[type="checkbox"]')) {
    if (checkbox.checked) {
      checked.push(checkbox.dataset.deviceName);
    }
  }
  runProfileCheckedNames = checked;
  onRunProfileFormInput();
}

// マシン切替: チェック状態(runProfileCheckedNames)は名前で引き継いだまま一覧を作り直す。
runProfileMachine.addEventListener('change', () => {
  renderRunProfileDevices();
  onRunProfileFormInput();
});
runProfileApp.addEventListener('change', onRunProfileFormInput);
runProfileHeal.addEventListener('change', onRunProfileFormInput);
runProfileReportDir.addEventListener('input', onRunProfileFormInput);
runProfileDefaultTimeout.addEventListener('input', onRunProfileFormInput);

// devices は「同じ集合なら並び順が違っても未変更」とみなす(マシンのデバイス順とプロファイル
// の記載順は独立で、チェック操作をしていないのに dirty になるのを避けるため)。
function runProfileDevicesEqual(a, b) {
  if (a.length !== b.length) {
    return false;
  }
  const setB = new Set(b);
  return a.every((name) => setB.has(name));
}

function runProfileValuesEqual(fields) {
  return (
    runProfileMachine.value === fields.machine &&
    runProfileApp.value === fields.app &&
    runProfileDevicesEqual(runProfileCheckedNames, fields.devices) &&
    runProfileHeal.checked === fields.heal &&
    runProfileReportDir.value === fields.reportDir &&
    runProfileDefaultTimeout.value === fields.defaultTimeout
  );
}

function onRunProfileFormInput() {
  if (runProfileOriginalFields === null || runProfileSubmitting) {
    return;
  }
  setRunProfileDirty(!runProfileValuesEqual(runProfileOriginalFields));
  // 入力を変えたら前回のエラー表示は古くなるので消す(editorError と同じ方針)。
  runProfileError.textContent = '';
}

function setRunProfileControlsEnabled(enabled) {
  runProfileMachine.disabled = !enabled;
  runProfileApp.disabled = !enabled;
  runProfileHeal.disabled = !enabled;
  runProfileReportDir.disabled = !enabled;
  runProfileDefaultTimeout.disabled = !enabled;
  for (const checkbox of runProfileDevices.querySelectorAll('input[type="checkbox"]')) {
    checkbox.disabled = !enabled;
  }
}

// クライアント検証(確定時)。問題なければ null。
function validateRunProfileFields() {
  const machine = runProfileMachine.value.trim();
  if (machine === '') {
    return '使用するマシンプロファイルを指定してください。';
  }
  if (!findMachine(machine)) {
    return 'マシンプロファイル「' + machine + '」が見つかりません。';
  }
  if (runProfileApp.value.trim() === '') {
    return 'アプリを指定してください。';
  }
  if (runProfileCheckedNames.length === 0) {
    return 'デバイスを1台以上選択してください。';
  }
  const timeout = runProfileDefaultTimeout.value.trim();
  if (timeout !== '' && (!/^\\d+$/.test(timeout) || Number(timeout) <= 0)) {
    return 'defaultTimeout は正の整数で入力してください。';
  }
  return null;
}

runProfileConfirm.addEventListener('click', () => {
  if (runProfileConfirm.disabled || runProfileSubmitting || !selectedRunProfile) {
    return;
  }
  const validationError = validateRunProfileFields();
  if (validationError) {
    runProfileError.textContent = validationError;
    return;
  }
  runProfileSubmitting = true;
  setRunProfileControlsEnabled(false);
  runProfileConfirm.textContent = '確定中...';
  runProfileError.textContent = '';
  refreshRunProfileButtonsUi();
  vscode.postMessage({
    type: 'runProfileSave',
    profile: selectedRunProfile,
    fields: {
      machine: runProfileMachine.value.trim(),
      app: runProfileApp.value.trim(),
      devices: runProfileCheckedNames.slice(),
      heal: runProfileHeal.checked,
      reportDir: runProfileReportDir.value.trim(),
      defaultTimeout: runProfileDefaultTimeout.value.trim(),
    },
  });
});

// キャンセル: dirty/送信中フラグを先に解除してから runProfileLoad を再送する
// (applyRunProfileData は runProfileEditing() の間は応答を無視するガードがあるため、
// 先に解除しておかないと再ロード結果が反映されない)。requestRunProfileLoad は内部で
// showRunProfilePlaceholder→setRunProfileDirty(false) を呼ぶため、この順序を満たす。
runProfileCancel.addEventListener('click', () => {
  if (runProfileCancel.disabled) {
    return;
  }
  runProfileError.textContent = '';
  requestRunProfileLoad();
});

// runProfileSave の結果。ok なら dirty 解除(ホストが続けて runProfileData を送るので、
// フォームはそこで最新値に作り直される)。ok:false ならエラー表示のみで入力値は残す。
function applyRunProfileSaveResult(message) {
  if (message.profile !== selectedRunProfile) {
    return;
  }
  runProfileSubmitting = false;
  runProfileConfirm.textContent = '確定';
  setRunProfileControlsEnabled(true);
  if (message.ok) {
    runProfileError.textContent = '';
    setRunProfileDirty(false);
  } else {
    refreshRunProfileButtonsUi();
    runProfileError.textContent = message.error || '実行プロファイルの更新に失敗しました。';
  }
}

// runs/<name>.json の外部編集(watcher onDidChange)。編集対象と同名 && 未編集のときのみ
// 再ロードして自動反映する(自分の保存直後の通知も来るが、その再ロードは冪等)。
function applyRunProfileFileChanged(message) {
  if (message.name === selectedRunProfile && !runProfileEditing()) {
    vscode.postMessage({ type: 'runProfileLoad', profile: selectedRunProfile });
  }
}

// ---- デバイス追加モーダル ---------------------------------------------------

// 複製元: src/monitorModel.ts の validateNewDeviceName。webview は CSP により import 不可のため
// 複製する(deviceOpMenuItem の複製と同じ方針。ロジックを変更したら両方に反映すること)。
function validateNewDeviceName(name, existing) {
  const trimmed = name.trim();
  if (trimmed.length === 0) {
    return 'デバイス名を入力してください。';
  }
  if (existing.includes(trimmed)) {
    return '「' + trimmed + '」は既に存在します。';
  }
  return null;
}

const deviceAddOverlay = document.getElementById('device-add-overlay');
const dlgPlatformIos = document.getElementById('dlg-platform-ios');
const dlgPlatformAndroid = document.getElementById('dlg-platform-android');
const dlgModel = document.getElementById('dlg-model');
const dlgOs = document.getElementById('dlg-os');
const dlgName = document.getElementById('dlg-name');
const dlgError = document.getElementById('dlg-error');
const dlgCancel = document.getElementById('dlg-cancel');
const dlgOk = document.getElementById('dlg-ok');

let deviceAddOpen = false;
let deviceAddCreating = false;
// deviceCatalogRequest の応答(deviceCatalog.ok:true の catalog)。未着/失敗中は null。
let deviceCatalog = null;
// デバイス名をユーザーが手で編集したか(true の間は自動生成に追従しない)。
let dlgNameDirty = false;
// このモーダルを #device-pick-overlay の「+」(device-pick-add-new)から開いたか。
// #device-pick-overlay はフルスクリーンのオーバーレイなので、openDeviceAddModal() 呼び出し時点の
// devicePickOpen がそのまま「ピッカー経由かどうか」の判定になる(下の openDeviceAddModal 参照)。
// true の間は createDevice に register:false を送り(物理作成のみ)、成功時は pendingAutoCheck を
// 使って一覧再描画時に該当行をチェックONにする(2026-07-11 指示)。
let deviceAddFromPicker = false;

// OS種別はラジオボタン2つ(dlg-platform-ios/-android、name="dlg-platform")で1つの select 相当を
// 表す。読み書きをここに集約し、他の場所は select だった頃と同じ感覚で扱えるようにする。
function getDialogPlatform() {
  return dlgPlatformIos.checked ? 'ios' : 'android';
}
function setDialogPlatform(value) {
  dlgPlatformIos.checked = value === 'ios';
  dlgPlatformAndroid.checked = value === 'android';
}

function setDialogControlsEnabled(enabled) {
  dlgPlatformIos.disabled = !enabled;
  dlgPlatformAndroid.disabled = !enabled;
  dlgModel.disabled = !enabled;
  dlgOs.disabled = !enabled;
  dlgName.disabled = !enabled;
}

function fillSelect(select, options) {
  select.textContent = '';
  for (const opt of options) {
    const el = document.createElement('option');
    el.value = opt.value;
    el.textContent = opt.label;
    select.appendChild(el);
  }
}

function modelOptionsFor(platform) {
  if (!deviceCatalog) {
    return [];
  }
  return platform === 'ios'
    ? deviceCatalog.ios.deviceTypes.map((d) => ({ value: d.identifier, label: d.name }))
    : deviceCatalog.android.models.map((m) => ({ value: m.id, label: m.name }));
}

function osOptionsFor(platform) {
  if (!deviceCatalog) {
    return [];
  }
  if (platform === 'ios') {
    return deviceCatalog.ios.runtimes.map((r) => ({ value: r.identifier, label: r.name }));
  }
  return deviceCatalog.android.systemImages.map((s) => ({
    value: s.package,
    label: s.versionName + '(API ' + s.apiLevel + ') ' + s.tag + ' / ' + s.abi,
  }));
}

function selectedOptionLabel(select) {
  const opt = select.options[select.selectedIndex];
  return opt ? opt.textContent : '';
}

// iOS = "モデル名(ランタイム名)"、Android = "モデル名(versionName)"(モデル未選択なら空文字)。
function autoDeviceName() {
  const modelLabel = selectedOptionLabel(dlgModel);
  if (!modelLabel) {
    return '';
  }
  const osLabel = selectedOptionLabel(dlgOs);
  return osLabel ? modelLabel + '(' + osLabel + ')' : modelLabel;
}

function refreshAutoName() {
  if (!dlgNameDirty) {
    dlgName.value = autoDeviceName();
  }
}

// カタログの available:false 側はラジオ自体を disabled にし、現在の選択がその側だった場合は
// 利用可能な側へ寄せる(両方 available:false の場合は変更しない = OK 側で弾かれる想定)。
// setDialogControlsEnabled(true) の直後にも呼び直すことで、いったん disabled にした
// ラジオを一律 enabled に戻す際、available:false 側を誤って有効に戻さないようにする
// (select だった頃は select 自体の disabled と option 個別の disabled が独立していたが、
// ラジオは disabled が1階層しかないため、有効化のたびに可用性を再適用する必要がある)。
function applyPlatformAvailability() {
  dlgPlatformIos.disabled = !deviceCatalog.ios.available;
  dlgPlatformAndroid.disabled = !deviceCatalog.android.available;
  if (getDialogPlatform() === 'ios' && !deviceCatalog.ios.available && deviceCatalog.android.available) {
    setDialogPlatform('android');
  } else if (getDialogPlatform() === 'android' && !deviceCatalog.android.available && deviceCatalog.ios.available) {
    setDialogPlatform('ios');
  }
}

function refreshModelAndOsOptions() {
  fillSelect(dlgModel, modelOptionsFor(getDialogPlatform()));
  fillSelect(dlgOs, osOptionsFor(getDialogPlatform()));
  refreshAutoName();
}

dlgPlatformIos.addEventListener('change', () => refreshModelAndOsOptions());
dlgPlatformAndroid.addEventListener('change', () => refreshModelAndOsOptions());
dlgModel.addEventListener('change', () => refreshAutoName());
dlgOs.addEventListener('change', () => refreshAutoName());
dlgName.addEventListener('input', () => {
  if (dlgName.value.trim().length === 0) {
    // 空にした = 自動生成への追従を再開する
    dlgNameDirty = false;
    dlgName.value = autoDeviceName();
  } else {
    dlgNameDirty = true;
  }
});

function openDeviceAddModal() {
  if (!selectedMachine) {
    return;
  }
  // devicePickOpen は #device-pick-overlay がフルスクリーンのオーバーレイであるため、
  // ここで呼ばれた時点の値がそのまま「ピッカーの「+」から開いたか」の判定になる
  // (btn-device-add はピッカー表示中はオーバーレイに隠れてクリックできない)。
  deviceAddFromPicker = devicePickOpen;
  deviceAddOpen = true;
  deviceAddCreating = false;
  deviceCatalog = null;
  dlgNameDirty = false;
  dlgName.value = '';
  dlgModel.textContent = '';
  dlgOs.textContent = '';
  dlgError.classList.add('info');
  dlgError.textContent = 'カタログを読み込み中...';
  setDialogControlsEnabled(false);
  dlgOk.disabled = true;
  dlgOk.textContent = 'OK';
  dlgCancel.disabled = false;
  deviceAddOverlay.classList.add('visible');
  vscode.postMessage({ type: 'deviceCatalogRequest' });
}

function closeDeviceAddModal() {
  if (!deviceAddOpen || deviceAddCreating) {
    return;
  }
  deviceAddOpen = false;
  deviceAddOverlay.classList.remove('visible');
}

function applyDeviceCatalog(message) {
  if (!deviceAddOpen) {
    return; // モーダルを閉じた後に届いた応答は無視する
  }
  if (!message.ok || !message.catalog) {
    dlgError.classList.remove('info');
    dlgError.textContent = message.error || 'カタログの取得に失敗しました。';
    dlgOk.disabled = true;
    return;
  }
  deviceCatalog = message.catalog;
  dlgError.classList.remove('info');
  dlgError.textContent = '';
  setDialogControlsEnabled(true);
  applyPlatformAvailability();
  refreshModelAndOsOptions();
  dlgOk.disabled = false;
}

function applyCreateDeviceResult(message) {
  if (!deviceAddOpen) {
    return;
  }
  deviceAddCreating = false;
  dlgCancel.disabled = false;
  dlgOk.textContent = 'OK';
  if (message.ok) {
    closeDeviceAddModal();
    // register:false(ピッカー経由)で作成できた場合、次の一覧再読込でその行を自動チェックONに
    // するための識別子を保持しておく(pendingAutoCheck。renderDevicePickGroups 参照)。
    if (deviceAddFromPicker) {
      pendingAutoCheck = message.device ? { udid: message.device.udid, avd: message.device.avd } : null;
    }
    reloadDevicePickIfOpen();
    return;
  }
  dlgOk.disabled = false;
  setDialogControlsEnabled(true);
  // setDialogControlsEnabled(true) は両ラジオを一律 enabled にするため、available:false 側を
  // 再度 disabled に戻す(applyPlatformAvailability 冒頭のコメント参照)。
  applyPlatformAvailability();
  dlgError.classList.remove('info');
  dlgError.textContent = message.error || 'デバイスの作成に失敗しました。';
}

// 「+新規作成」ボタンは廃止(2026-07-11 指示)。新規作成モーダル(openDeviceAddModal)は
// 「+」で開く選択画面(#device-pick-overlay)内の「+」からのみ開く(=常に register:false 経路)。
dlgCancel.addEventListener('click', () => closeDeviceAddModal());
deviceAddOverlay.addEventListener('click', (event) => {
  if (event.target === deviceAddOverlay) {
    closeDeviceAddModal();
  }
});
dlgOk.addEventListener('click', () => {
  if (dlgOk.disabled || deviceAddCreating || !deviceCatalog) {
    return;
  }
  const name = dlgName.value.trim();
  const error = validateNewDeviceName(name, allDeviceNamesForSelectedMachine());
  if (error) {
    dlgError.classList.remove('info');
    dlgError.textContent = error;
    return;
  }
  deviceAddCreating = true;
  setDialogControlsEnabled(false);
  dlgOk.disabled = true;
  dlgCancel.disabled = true;
  dlgOk.textContent = '作成中...';
  dlgError.textContent = '';
  vscode.postMessage({
    type: 'createDevice',
    machine: selectedMachine,
    platform: getDialogPlatform(),
    name: name,
    model: dlgModel.value,
    os: dlgOs.value,
    // ピッカー経由(deviceAddFromPicker)なら物理作成のみ(register:false)。登録はピッカーの
    // OK(machineDevicesSync)で行う。.profile-actions の「+新規作成」から直接開いた場合は
    // 従来どおり即登録する。
    register: !deviceAddFromPicker,
  });
});
// 既存の Esc ハンドラ(closeDeviceOpMenu)とは別のリスナーとして追加する(closeDeviceAddModal
// は自分の状態(deviceAddOpen/deviceAddCreating)だけを見るので、両者は独立して安全に共存する)。
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    closeDeviceAddModal();
  }
});

// ---- 名前入力モーダル(#name-input-overlay) ----------------------------------------
// 実行/アプリ/マシンプロファイルの追加・コピー・名前変更(9箇所)を担う、showInputBox 相当の
// 置き換え。拡張側の nameInputOpen で開き、OK/キャンセルは nameInputConfirm/nameInputCancel を
// id 付きで返す(拡張側の pendingNameInput と突き合わせる)。検証ルールは拡張側の
// validateNewRunProfileName/validateNewAppProfileName/validateNewMachineProfileName と同一
// (空/"/""\""/"."始まり/重複)。renderHtml() の巨大テンプレートリテラル内でバックスラッシュ文字を
// 直に書くと二重エスケープが必要になり事故りやすいため(#run-profile-devices-row 付近の \\d の
// 教訓と同じ理由)、String.fromCharCode(92) で組み立てて回避する。

const nameInputOverlay = document.getElementById('name-input-overlay');
const nameInputTitleEl = document.getElementById('name-input-title');
const nameInputField = document.getElementById('name-input-field');
const nameInputErrorEl = document.getElementById('name-input-error');
const nameInputCancelBtn = document.getElementById('name-input-cancel');
const nameInputOkBtn = document.getElementById('name-input-ok');

const NAME_INPUT_BACKSLASH = String.fromCharCode(92);

// { id, noun, dupLabel, existing, caseInsensitiveDup, touched } | null
let nameInputState = null;

function validateNameInputValue(raw, state) {
  const trimmed = raw.trim();
  if (trimmed.length === 0) {
    return state.noun + 'を入力してください。';
  }
  if (trimmed.indexOf('/') !== -1 || trimmed.indexOf(NAME_INPUT_BACKSLASH) !== -1) {
    return state.noun + 'に "/" や "' + NAME_INPUT_BACKSLASH + '" は使えません。';
  }
  if (trimmed.charAt(0) === '.') {
    return state.noun + 'を "." で始めることはできません。';
  }
  const compareName = state.caseInsensitiveDup ? trimmed.toLowerCase() : trimmed;
  const isDup = state.existing.some((item) => (state.caseInsensitiveDup ? item.toLowerCase() : item) === compareName);
  if (isDup) {
    return state.dupLabel + '「' + trimmed + '」は既に存在します。';
  }
  return null;
}

// エラー文言の表示・OKボタンの disabled 状態を、現在の入力値で更新する。開いた直後の空欄に
// いきなり「入力してください」を出さないよう、value が非空 or 一度でも入力があった(touched)
// 場合のみエラー文言を表示する(disabled の切替自体は常に行う)。
function refreshNameInputValidation() {
  if (!nameInputState) {
    return;
  }
  const raw = nameInputField.value;
  const error = validateNameInputValue(raw, nameInputState);
  const shouldShowError = raw.trim().length > 0 || nameInputState.touched;
  nameInputErrorEl.textContent = shouldShowError && error ? error : '';
  nameInputOkBtn.disabled = !!error;
}

function closeNameInputModal() {
  nameInputOverlay.classList.remove('visible');
  nameInputState = null;
}

function confirmNameInput() {
  if (!nameInputState || nameInputOkBtn.disabled) {
    return;
  }
  vscode.postMessage({ type: 'nameInputConfirm', id: nameInputState.id, name: nameInputField.value });
  closeNameInputModal();
}

function cancelNameInput() {
  if (!nameInputState) {
    return;
  }
  vscode.postMessage({ type: 'nameInputCancel', id: nameInputState.id });
  closeNameInputModal();
}

function applyNameInputOpen(message) {
  // 二重 nameInputOpen 受信時は単に上書き再初期化する(通常は起こらないが念のため)。
  nameInputState = {
    id: message.id,
    noun: message.noun,
    dupLabel: message.dupLabel,
    existing: message.existing,
    caseInsensitiveDup: message.caseInsensitiveDup,
    touched: false,
  };
  nameInputTitleEl.textContent = message.title;
  nameInputField.value = message.value;
  nameInputErrorEl.textContent = '';
  nameInputOverlay.classList.add('visible');
  nameInputField.focus();
  if (message.value.length > 0) {
    nameInputField.select();
  }
  refreshNameInputValidation();
}

nameInputField.addEventListener('input', () => {
  if (!nameInputState) {
    return;
  }
  nameInputState.touched = true;
  refreshNameInputValidation();
});
nameInputField.addEventListener('keydown', (event) => {
  if (event.key === 'Enter') {
    event.preventDefault();
    confirmNameInput();
  }
});
nameInputOkBtn.addEventListener('click', () => confirmNameInput());
nameInputCancelBtn.addEventListener('click', () => cancelNameInput());
nameInputOverlay.addEventListener('click', (event) => {
  if (event.target === nameInputOverlay) {
    cancelNameInput();
  }
});
// 名前入力モーダルは他のモーダル(デバイス追加/デバイス選択)と同時には開かないため、
// device-add-overlay の Esc ハンドラ(上記)と同じ独立した専用リスナーとして追加する
// (deviceAddOpen 等の他モーダルの状態は見なくてよい)。
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && nameInputState) {
    cancelNameInput();
  }
});

// ---- 「+既存から選択」モーダル(#device-pick-overlay。要件2) -----------------------
// インストール済みの iOS シミュレータ/Android AVD を一覧表示する。チェックボックスは
// 「選択」ではなく「マシンプロファイルへの登録状態そのもの」を表す(初期値=現在の登録有無)。
// OK は行ごとの初期状態からの差分をまとめて machineDevicesSync(add/remove)で送る。
// 実機で数十件規模になりうる前提(コーディネーター指示)。

const devicePickOverlay = document.getElementById('device-pick-overlay');
const devicePickIosTitle = document.getElementById('device-pick-ios-title');
const devicePickIosBody = document.getElementById('device-pick-ios-body');
const devicePickAndroidTitle = document.getElementById('device-pick-android-title');
const devicePickAndroidBody = document.getElementById('device-pick-android-body');
const devicePickError = document.getElementById('device-pick-error');
const devicePickCancel = document.getElementById('device-pick-cancel');
const devicePickOk = document.getElementById('device-pick-ok');
const devicePickAddNewBtn = document.getElementById('device-pick-add-new');

let devicePickOpen = false;
let devicePickAdding = false;
// 直近描画した行(チェックボックス+対応データ+初期状態)。チェックボックスは「選択」ではなく
// 「登録状態そのもの」を表すので、initialChecked(=描画時点の登録有無)を保持しておき、OK
// クリック時にそこからの差分(行ごとの checkbox.checked !== initialChecked)だけを
// machineDevicesSync の add/remove として組み立てる。registeredName は登録済みだった行を
// 未チェックにした場合の削除対象(マシンプロファイル上の name)。
let devicePickIosRows = [];
let devicePickAndroidRows = [];
// register:false で新規作成した直後、次の installedDevices 再描画で自動チェックONにしたい行の
// 識別子(iOS=udid/Android=avd の id)。作成に成功していない/一致する行が無い場合はどちらも
// null のままでよい(applyPendingAutoCheck が静かに諦める)。適用後は必ず null に戻す
// (一度きりの適用。2026-07-11 指示)。
let pendingAutoCheck = null;

// 選択中マシンの既存デバイスから、識別値→マシンプロファイル上の name への対応表を作る
// (初期チェック状態の判定と、登録解除[remove]時にどの name を消せばよいかの両方に使う)。
// iOS は udid 一致、Android は avd が id または displayName に一致するものを登録済みとみなす
// (要件2)。
function registeredIosNameByUdid() {
  const machine = findMachine(selectedMachine);
  const map = new Map();
  if (machine) {
    for (const d of machine.devices) {
      if (d.platform === 'ios' && d.udid) {
        map.set(d.udid, d.name);
      }
    }
  }
  return map;
}
function registeredAndroidNameByAvd() {
  const machine = findMachine(selectedMachine);
  const map = new Map();
  if (machine) {
    for (const d of machine.devices) {
      if (d.platform === 'android' && d.avd) {
        map.set(d.avd, d.name);
      }
    }
  }
  return map;
}

// OK は「行ごとの初期状態(登録有無)からの差分が1件以上ある」ときだけ有効にする
// (チェックボックス=登録状態の設計上、単に何かがチェックされているかどうかでは判定できない)。
function updateDevicePickOkState() {
  if (devicePickAdding) {
    return;
  }
  const anyDiff =
    devicePickIosRows.some((row) => row.checkbox.checked !== row.initialChecked) ||
    devicePickAndroidRows.some((row) => row.checkbox.checked !== row.initialChecked);
  devicePickOk.disabled = !anyDiff;
}

function buildDevicePickEmptyRow(container, text) {
  const empty = document.createElement('div');
  empty.className = 'device-pick-empty';
  empty.textContent = text;
  container.appendChild(empty);
}

// checked クラス(選択配色。CSS側 .device-pick-row.checked)を checkbox.checked に同期する。
// checkbox.checked のプログラム的変更は change イベントを発火しないため、変更経路
// (初期描画/行クリック/自動チェック)ごとに明示的に呼ぶ。
function syncDevicePickRowChecked(row, checkbox) {
  row.classList.toggle('checked', checkbox.checked);
}

// 行のどこをクリックしてもチェックが切り替わるようにする(ユーザー指定)。チェックボックス
// 自体のクリックはネイティブのトグルに任せる(row の click でも拾ってしまうと二重トグルで
// 元に戻ってしまうため除外する)。適用中等で checkbox が disabled の間は何もしない。
function attachDevicePickRowToggle(row, checkbox) {
  row.addEventListener('click', (event) => {
    if (event.target === checkbox || checkbox.disabled) {
      return;
    }
    checkbox.checked = !checkbox.checked;
    syncDevicePickRowChecked(row, checkbox);
    // プログラム的な .checked 変更は change イベントを発火しないため、明示的に更新する。
    updateDevicePickOkState();
  });
}

// installedDevices(InstalledDevices の形)から2グループ分の行を組み立てる。
function renderDevicePickGroups(data) {
  devicePickIosRows = [];
  devicePickAndroidRows = [];
  devicePickIosBody.textContent = '';
  devicePickAndroidBody.textContent = '';

  const iosNameByUdid = registeredIosNameByUdid();
  const iosData = data.ios;
  devicePickIosTitle.textContent = 'iOS シミュレータ (' + iosData.devices.length + ')';
  if (!iosData.available) {
    buildDevicePickEmptyRow(devicePickIosBody, iosData.error || 'iOS シミュレータを取得できませんでした。');
  } else if (iosData.devices.length === 0) {
    buildDevicePickEmptyRow(devicePickIosBody, 'iOS シミュレータがありません。');
  } else {
    for (const device of iosData.devices) {
      const registeredName = iosNameByUdid.get(device.udid);
      const registered = registeredName !== undefined;
      const row = document.createElement('div');
      row.className = 'device-pick-row';
      const checkbox = document.createElement('input');
      checkbox.type = 'checkbox';
      checkbox.checked = registered;
      checkbox.addEventListener('change', () => {
        syncDevicePickRowChecked(row, checkbox);
        updateDevicePickOkState();
      });
      const textWrap = document.createElement('div');
      textWrap.className = 'device-pick-row-text';
      // タイル/レーン/マシンプロファイル一覧と同じ配色ピル(.tile-name/-ios)を共用する(要件2)。
      const nameEl = document.createElement('span');
      nameEl.className = 'device-pick-row-name tile-name tile-name-ios';
      nameEl.textContent = device.name;
      const detailEl = document.createElement('div');
      detailEl.className = 'device-pick-row-detail';
      detailEl.textContent = 'iOS ' + device.os + ' / ' + device.udid.slice(0, 8);
      textWrap.append(nameEl, detailEl);
      row.append(checkbox, textWrap);
      attachDevicePickRowToggle(row, checkbox);
      syncDevicePickRowChecked(row, checkbox);
      devicePickIosBody.appendChild(row);
      devicePickIosRows.push({ checkbox: checkbox, device: device, initialChecked: registered, registeredName: registeredName, rowEl: row });
    }
  }

  const androidNameByAvd = registeredAndroidNameByAvd();
  const androidData = data.android;
  devicePickAndroidTitle.textContent = 'Android AVD (' + androidData.avds.length + ')';
  if (!androidData.available) {
    buildDevicePickEmptyRow(devicePickAndroidBody, androidData.error || 'Android AVD を取得できませんでした。');
  } else if (androidData.avds.length === 0) {
    buildDevicePickEmptyRow(devicePickAndroidBody, 'Android AVD がありません。');
  } else {
    for (const avd of androidData.avds) {
      const registeredName = androidNameByAvd.get(avd.id) ?? androidNameByAvd.get(avd.displayName);
      const registered = registeredName !== undefined;
      const row = document.createElement('div');
      row.className = 'device-pick-row';
      const checkbox = document.createElement('input');
      checkbox.type = 'checkbox';
      checkbox.checked = registered;
      checkbox.addEventListener('change', () => {
        syncDevicePickRowChecked(row, checkbox);
        updateDevicePickOkState();
      });
      const textWrap = document.createElement('div');
      textWrap.className = 'device-pick-row-text';
      // タイル/レーン/マシンプロファイル一覧と同じ配色ピル(.tile-name/-android)を共用する(要件2)。
      const nameEl = document.createElement('span');
      nameEl.className = 'device-pick-row-name tile-name tile-name-android';
      nameEl.textContent = avd.displayName;
      const detailEl = document.createElement('div');
      detailEl.className = 'device-pick-row-detail';
      const detailParts = [];
      if (avd.id !== avd.displayName) {
        detailParts.push(avd.id);
      }
      detailEl.textContent = detailParts.join('・');
      textWrap.append(nameEl, detailEl);
      row.append(checkbox, textWrap);
      attachDevicePickRowToggle(row, checkbox);
      syncDevicePickRowChecked(row, checkbox);
      devicePickAndroidBody.appendChild(row);
      devicePickAndroidRows.push({ checkbox: checkbox, avd: avd, initialChecked: registered, registeredName: registeredName, rowEl: row });
    }
  }
}

// pendingAutoCheck(register:false で新規作成した直後の識別子)が指す行があれば、その行の
// チェックボックスだけを ON にする(initialChecked は renderDevicePickGroups が判定した
// 「登録済みかどうか」のまま false なので、ここで checked を true にすれば差分[ユーザー操作扱い]
// として OK ボタンが有効になる)。一致する行が無ければ何もしない(静かに諦める。2026-07-11 指示)。
// renderDevicePickGroups の直後(devicePickIosRows/devicePickAndroidRows が最新化された後)に
// 呼ぶこと。呼んだら pendingAutoCheck は必ずクリアする(一度きりの適用)。
function applyPendingAutoCheck() {
  if (!pendingAutoCheck) {
    return;
  }
  const target = pendingAutoCheck;
  pendingAutoCheck = null;
  if (target.udid) {
    const row = devicePickIosRows.find((r) => r.device.udid === target.udid);
    if (row) {
      row.checkbox.checked = true;
      syncDevicePickRowChecked(row.rowEl, row.checkbox);
    }
  }
  if (target.avd) {
    const row = devicePickAndroidRows.find((r) => r.avd.id === target.avd);
    if (row) {
      row.checkbox.checked = true;
      syncDevicePickRowChecked(row.rowEl, row.checkbox);
    }
  }
}

// 同期リクエスト送信中(devicePickAdding)はチェックボックスも含めて全コントロールを disabled
// にする。チェックボックスは「登録状態そのもの」で常に操作可能な設計になったため、再度
// 有効化する際も一律 enabled に戻せばよい(以前のような「登録済み行だけ disabled のまま戻す」
// 例外はもう無い)。
function setDevicePickControlsEnabled(enabled) {
  for (const row of devicePickIosRows.concat(devicePickAndroidRows)) {
    row.checkbox.disabled = !enabled;
  }
}

// #device-add-overlay(「+新規作成」)での作成が成功した後、このモーダルがまだ開いていれば
// 一覧を再取得して作り直す。全行が installedDevicesRequest の新しい応答から再描画されるため、
// 登録状態は最新値に自然と揃う(=他行の未確定の差分は破棄される。単純さを優先した設計判断)。
function reloadDevicePickIfOpen() {
  if (!devicePickOpen) {
    return;
  }
  devicePickError.classList.add('info');
  devicePickError.textContent = '一覧を読み込み中...';
  devicePickOk.disabled = true;
  vscode.postMessage({ type: 'installedDevicesRequest' });
}

function openDevicePickModal() {
  if (!selectedMachine) {
    return;
  }
  devicePickOpen = true;
  devicePickAdding = false;
  pendingAutoCheck = null; // 前回開いた際の残留分があれば捨てて、新規セッションはクリーンに始める
  devicePickIosRows = [];
  devicePickAndroidRows = [];
  devicePickIosBody.textContent = '';
  devicePickAndroidBody.textContent = '';
  devicePickIosTitle.textContent = 'iOS シミュレータ';
  devicePickAndroidTitle.textContent = 'Android AVD';
  devicePickError.classList.add('info');
  devicePickError.textContent = '一覧を読み込み中...';
  devicePickOk.disabled = true;
  devicePickOk.textContent = 'OK';
  devicePickCancel.disabled = false;
  devicePickOverlay.classList.add('visible');
  vscode.postMessage({ type: 'installedDevicesRequest' });
}

function closeDevicePickModal() {
  if (!devicePickOpen || devicePickAdding) {
    return;
  }
  devicePickOpen = false;
  pendingAutoCheck = null; // 閉じた後に届く installedDevices 応答で誤適用しないようクリアする
  devicePickOverlay.classList.remove('visible');
}

function applyInstalledDevices(message) {
  if (!devicePickOpen) {
    return; // モーダルを閉じた後に届いた応答は無視する(applyDeviceCatalog と同じ方針)
  }
  if (!message.ok || !message.data) {
    devicePickError.classList.remove('info');
    devicePickError.textContent = message.error || '一覧の取得に失敗しました。';
    devicePickOk.disabled = true;
    return;
  }
  devicePickError.classList.remove('info');
  devicePickError.textContent = '';
  renderDevicePickGroups(message.data);
  applyPendingAutoCheck();
  updateDevicePickOkState();
}

function applyMachineDevicesSyncResult(message) {
  if (!devicePickOpen) {
    return;
  }
  devicePickAdding = false;
  devicePickCancel.disabled = false;
  devicePickOk.textContent = 'OK';
  if (message.ok) {
    closeDevicePickModal();
    return;
  }
  setDevicePickControlsEnabled(true);
  updateDevicePickOkState();
  devicePickError.classList.remove('info');
  devicePickError.textContent = message.error || 'デバイスの同期に失敗しました。';
}

btnDeviceAddExisting.addEventListener('click', () => openDevicePickModal());
devicePickAddNewBtn.addEventListener('click', () => openDeviceAddModal());
devicePickCancel.addEventListener('click', () => closeDevicePickModal());
devicePickOverlay.addEventListener('click', (event) => {
  if (event.target === devicePickOverlay) {
    closeDevicePickModal();
  }
});
devicePickOk.addEventListener('click', () => {
  if (devicePickOk.disabled || devicePickAdding) {
    return;
  }
  const add = [];
  const remove = [];
  for (const row of devicePickIosRows) {
    if (row.checkbox.checked && !row.initialChecked) {
      add.push({
        platform: 'ios',
        name: row.device.name,
        simulator: row.device.name,
        os: row.device.os,
        udid: row.device.udid,
      });
    } else if (!row.checkbox.checked && row.initialChecked) {
      remove.push(row.registeredName);
    }
  }
  for (const row of devicePickAndroidRows) {
    if (row.checkbox.checked && !row.initialChecked) {
      add.push({ platform: 'android', name: row.avd.displayName, avd: row.avd.id });
    } else if (!row.checkbox.checked && row.initialChecked) {
      remove.push(row.registeredName);
    }
  }
  if (add.length === 0 && remove.length === 0) {
    return; // OK は差分がある間だけ有効なので通常ここには来ない(防御的ガード)
  }
  devicePickAdding = true;
  setDevicePickControlsEnabled(false);
  devicePickOk.disabled = true;
  devicePickCancel.disabled = true;
  devicePickOk.textContent = '適用中...';
  devicePickError.classList.remove('info');
  devicePickError.textContent = '';
  vscode.postMessage({ type: 'machineDevicesSync', machine: selectedMachine, add: add, remove: remove });
});
// 既存の Esc ハンドラとは別のリスナーとして追加する(closeDeviceAddModal の Esc ハンドラと
// 同じ方針。closeDevicePickModal は自分の状態[devicePickOpen/devicePickAdding]だけを見るので
// 独立して安全に共存する)。ただし今回から「+」ボタンでこのモーダルの上に #device-add-overlay を
// 重ねて開けるようになったため、その間は Esc で奥のこのモーダルまで一緒に閉じないよう
// deviceAddOpen を先にチェックする(手前の device-add-overlay 自身の Esc ハンドラは
// deviceAddOpen だけを見るので、そちらは今まで通り自分自身を閉じる)。
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    if (deviceAddOpen) {
      return;
    }
    closeDevicePickModal();
  }
});

// ---- タブ切り替え(デバイス/プロファイル/設定) -----------------------------
// 「設定」タブは現状プレースホルダーのみ(将来の機能追加先)。ここは
// closeDeviceOpMenu・closeMachineDeviceMenu・applyTilePaneHeight・tilePaneHeight・
// persistedState のいずれもが既に定義済みであることに依存するため、
// スクリプトの最後(呼び出し側)にまとめて置く(関数宣言のホイスティングにより、
// ソース上の定義順に関わらず参照できる)。

const TAB_IDS = ['devices', 'profiles', 'settings'];
const tabButtons = {
  devices: document.getElementById('tab-devices'),
  profiles: document.getElementById('tab-profiles'),
  settings: document.getElementById('tab-settings'),
};
const tabPanels = {
  devices: devicesPanel,
  profiles: document.getElementById('panel-profiles'),
  settings: document.getElementById('panel-settings'),
};

function persistActiveTab(tab) {
  vscode.setState(Object.assign({}, vscode.getState(), { activeTab: tab }));
}

function switchTab(tab) {
  // タブ切替中に前のタブで開いていた右クリックメニューを残さない。
  closeDeviceOpMenu();
  closeMachineDeviceMenu();
  for (const id of TAB_IDS) {
    const isActive = id === tab;
    tabButtons[id].classList.toggle('active', isActive);
    tabButtons[id].setAttribute('aria-selected', String(isActive));
    tabPanels[id].style.display = isActive ? 'flex' : 'none';
  }
  if (tab === 'devices') {
    // 非表示だった間 devicesPanel.clientHeight が 0 になり、applyTilePaneHeight が
    // ガードで何もせず抜けていた(誤クランプ防止)。再表示直後に呼び直して再クランプ+
    // relayoutTiles() する(applyTilePaneHeight が内部で relayoutTiles() まで行う)。
    applyTilePaneHeight(tilePaneHeight);
  }
}

for (const id of TAB_IDS) {
  tabButtons[id].addEventListener('click', () => {
    if (tabButtons[id].classList.contains('active')) {
      return;
    }
    switchTab(id);
    persistActiveTab(id);
  });
}

// プロファイルタブ先頭の sticky ジャンプヘッダー(#profile-jump-header)から各セクションへ
// スクロールする(data-target=セクションの id)。scroll-margin-top(.profile-section)で
// sticky ヘッダーの裏に見出しが隠れないようにしてある。
for (const link of document.querySelectorAll('.profile-jump-link')) {
  link.addEventListener('click', () => {
    const target = document.getElementById(link.dataset.target);
    if (target) {
      target.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
  });
}

// 選択タブの永続化(vscode.getState())から復元する。不正値・未設定は 'devices'。
const initialTab = TAB_IDS.includes(persistedState.activeTab) ? persistedState.activeTab : 'devices';
switchTab(initialTab);

updateLaneVisibility();
updateLanesPlaceholder();

// 初期化完了(全リスナー登録済み)を拡張側へ通知する(ready ハンドシェイク)。
// 拡張側はこれを受けて初期状態(laneHydrate/profileInfo等)を送る。
vscode.postMessage({ type: 'ready' });
  })();
