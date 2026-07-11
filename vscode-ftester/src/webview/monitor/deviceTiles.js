// deviceTiles.js
// 「デバイス」タブのタイルグリッド(生成・フレーム/状態描画)・タイル右クリックメニュー・
// タイル選択・グリッドのホイール横スクロール/中クリックパン・実行プロファイル選択(select)を
// 担う。Phase 3(main.js のモジュール分割)で main.js の「---- デバイスタイル ----」
// 「---- タイル右クリックメニュー ----」「---- 実行プロファイル選択 ----」節と、
// それらに挟まれた無題のヘルパー群(findTileByName 等)・グリッド操作(トグル選択/ホイール/パン)
// をまとめて抽出した。
// tiles(device id -> タイル状態)・selectedDeviceIds(選択中 device id 集合)・
// deviceOpMenuEntry は再代入・変更される状態のため、書き込み箇所をすべてこのモジュールに
// 置く。laneLog.js(旧ログレーン節)からは tiles/selectedDeviceIds を読み取り専用で参照する。

import { vscode } from './vscodeApi.js';
import { grid, emptyMessage, banner, btnUp, btnDown, deviceOpMenu, deviceOpMenuItemBtn, profileSelect } from './domRefs.js';
import { updateLaneVisibility, syncLanesToDevices, runningWorkers } from './laneLog.js';

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
export const tiles = new Map();
// タイルクリックで選択された device id 集合(空 = 全ワーカー表示)
export const selectedDeviceIds = new Set();

function formatTime(date) {
  const pad = (n) => String(n).padStart(2, '0');
  return pad(date.getHours()) + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds());
}

// ---- デバイスタイル -----------------------------------------------------

// タイル内の「画像以外」の高さの合計(px)。CSS の固定高と一致させること:
// padding 上下 8+8 + header 20 + footer 18 + gap 6×2 = 66
const TILE_CHROME_HEIGHT = 66;

// タイルの実測高さ(グリッドの stretch 結果)から画像に使える高さを算出し、
// CSS 変数 --tile-image-h として grid に設定する(タイル幅はこの高さ×アスペクト比で決まる)。
// スプリッター移動・リサイズ・タイル生成のたびに呼ぶ。
export function relayoutTiles() {
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
export function renderOpBadge(entry) {
  const item = deviceOpMenuItem(entry.device.state, entry.opBusy);
  entry.opBadgeEl.textContent = item.label;
  entry.opBadgeEl.classList.toggle('visible', item.disabled);
}

// ---- タイル右クリックメニュー ---------------------------------------------

// 現在メニューを開いている対象のタイル entry(未オープンなら null)。
export let deviceOpMenuEntry = null;

export function renderDeviceOpMenuItem() {
  if (!deviceOpMenuEntry) {
    return;
  }
  const item = deviceOpMenuItem(deviceOpMenuEntry.device.state, deviceOpMenuEntry.opBusy);
  deviceOpMenuItemBtn.textContent = item.label;
  deviceOpMenuItemBtn.disabled = item.disabled;
  deviceOpMenuItemBtn.dataset.op = item.op;
}

export function closeDeviceOpMenu() {
  if (!deviceOpMenuEntry) {
    return;
  }
  deviceOpMenuEntry = null;
  deviceOpMenu.classList.remove('visible');
}

// 自作の右クリックメニュー(fixed div)をマウス位置に開く際、画面端でははみ出さないよう
// 実測サイズで座標をクランプする。タイル右クリックメニュー・プロファイルタブのデバイス行
// 右クリックメニュー(machine-device-menu)で共用する。
export function clampMenuPosition(menuEl, clientX, clientY) {
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
export function findTileByName(name) {
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

export function applyDevices(devices) {
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

export function applyFrame(message) {
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

export function applyDeviceError(message) {
  const entry = message.device ? tiles.get(message.device) : undefined;
  if (entry) {
    setTileError(entry, message.message);
    return;
  }
  showBanner(message.message);
}

export function showBanner(text) {
  banner.textContent = text;
  banner.classList.add('visible');
}
export function hideBanner() {
  banner.textContent = '';
  banner.classList.remove('visible');
}

export function setBusy(busy) {
  btnUp.disabled = busy;
  btnDown.disabled = busy;
}

// ---- 実行プロファイル選択 ---------------------------------------------------
// 追加/コピー/削除/名前変更はプロファイルタブ下半分の実行プロファイルセクションに移設した
// (btn-run-profile-*)。ここでは「使用する実行プロファイルを指定するだけ」の select のみを扱う。

const PROFILE_NONE_LABEL = '(プロファイルなし)';

// profileInfo 受信のたびに select の中身を作り直す(現在値が profiles に無い場合も、
// 設定に手書きされた未知の名前として option を補い選択状態を保つ)。
export function applyProfileInfo(message) {
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
