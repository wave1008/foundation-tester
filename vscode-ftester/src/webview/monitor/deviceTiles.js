// tiles/selectedDeviceIds/deviceOpMenuEntry の書き込みはこのモジュールに限定する。
// laneLog.js は tiles/selectedDeviceIds を読み取り専用で参照する。

import { vscode } from './vscodeApi.js';
import { grid, emptyMessage, banner, btnUp, btnDown, deviceOpMenu, deviceOpMenuItemBtn, deviceOpMenuLiveBtn, profileSelect } from './domRefs.js';
import { updateLaneVisibility, syncLanesToDevices, runningWorkers } from './laneLog.js';

const STATE_LABEL = {
  connected: '接続済み',
  booted: '起動中',
  offline: '未起動',
};

// src/monitorModel.ts の deviceOpMenuItem の複製(webview は CSP で import 不可のため)。変更時は
// 両方を同期すること。busy は { op, status }('queued'|'running')または undefined。
function deviceOpMenuItem(state, busy) {
  if (busy && busy.status === 'queued') { return { label: '待機中...', op: busy.op, disabled: true }; }
  if (busy && busy.op === 'up') { return { label: '起動中...', op: 'up', disabled: true }; }
  if (busy && busy.op === 'down') { return { label: '停止中...', op: 'down', disabled: true }; }
  return state === 'offline'
    ? { label: '起動', op: 'up', disabled: false }
    : { label: '停止', op: 'down', disabled: false };
}

// device id -> タイルDOM要素・最新フレーム(1枚のみ保持、履歴は溜めない)
export const tiles = new Map();
// 空 = 全ワーカー表示(絞り込みなし)
export const selectedDeviceIds = new Set();

function formatTime(date) {
  const pad = (n) => String(n).padStart(2, '0');
  return pad(date.getHours()) + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds());
}

// タイル内の「画像以外」の高さの合計(px)。CSS の固定高と一致させること:
// padding 上下 8+8 + header 20 + footer 18 + gap 6×2 = 66
const TILE_CHROME_HEIGHT = 66;

// タイル実測高さから --tile-image-h を算出(タイル幅はこの高さ×アスペクト比で決まる)。
// スプリッター移動・リサイズ・タイル生成のたびに呼び直す必要がある。
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
  tile.title = 'クリックで選択 / 右クリックで起動・停止・ライブ操作';
  tile.addEventListener('click', () => toggleDeviceSelection(device.id));
  tile.addEventListener('contextmenu', (event) => {
    // 既定メニュー抑止+タイルクリック(選択トグル)への波及防止。
    event.preventDefault();
    event.stopPropagation();
    openDeviceOpMenu(entry, event.clientX, event.clientY);
  });

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
  // renderFrame() が frame-wrap を作り直す際に毎回末尾へ再アペンドする(忘れると消える)。
  const opBadge = document.createElement('span');
  opBadge.className = 'tile-op-badge';

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
    // offline→未起動+電源アイコン、それ以外(booted/フレーム未着)→起動中+スピナー。
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
  // connected+フレーム有→「接続済み」、booted→「接続中」、それ以外→空(要素は固定高のため残す)。
  let footerText = '';
  if (entry.device.state === 'connected' && entry.frameSrc) {
    footerText = STATE_LABEL.connected;
  } else if (entry.device.state === 'booted') {
    footerText = '接続中';
  }
  entry.stateBadgeEl.textContent = footerText;
  entry.updatedEl.textContent = entry.lastUpdated ? formatTime(entry.lastUpdated) : '';
  renderOpBadge(entry);
  if (deviceOpMenuEntry === entry) {
    renderDeviceOpMenuItem();
  }
}

// devices サイクル(renderMeta 経由)と deviceOpBusy 受信(main.js)の両方から呼ばれる。
export function renderOpBadge(entry) {
  const item = deviceOpMenuItem(entry.device.state, entry.opBusy);
  entry.opBadgeEl.textContent = item.label;
  entry.opBadgeEl.classList.toggle('visible', item.disabled);
}

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

// 画面端クランプ。タイル右クリックメニューとプロファイルタブの行メニュー(machineProfilesTab.js)で共用。
export function clampMenuPosition(menuEl, clientX, clientY) {
  const rect = menuEl.getBoundingClientRect();
  const maxX = Math.max(4, window.innerWidth - rect.width - 4);
  const maxY = Math.max(4, window.innerHeight - rect.height - 4);
  menuEl.style.left = Math.min(Math.max(clientX, 4), maxX) + 'px';
  menuEl.style.top = Math.min(Math.max(clientY, 4), maxY) + 'px';
}

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

// 受け手は liveTab.js(タブ切替+host への openDevice 送信)。
deviceOpMenuLiveBtn.addEventListener('click', (event) => {
  event.stopPropagation();
  if (!deviceOpMenuEntry) {
    return;
  }
  document.dispatchEvent(new CustomEvent('ft-live-open-device', { detail: { id: deviceOpMenuEntry.device.id } }));
  closeDeviceOpMenu();
});

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
// capture:true: scroll はバブリングしないため、子要素(grid横スクロール等)のscrollも拾うために必要。
document.addEventListener('scroll', () => closeDeviceOpMenu(), true);
window.addEventListener('resize', () => closeDeviceOpMenu());
// タイル外の右クリック(OS既定メニューが開く場合)用。タイル上はstopPropagation済みで来ない。
document.addEventListener('contextmenu', () => closeDeviceOpMenu());

// deviceOp は device.name(論理名)だけをhostに渡すため、host応答(deviceOpBusy等)もnameで来る。
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

// 次の frame/devices 受信で自動的にクリアされる(表示し続けない設計)。
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
  // --tile-aspect は CSS 側でタイル幅の計算に使われる。
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

// この select は「使用する実行プロファイルの指定」のみ。追加/編集は runProfilesTab.js が担当。

const PROFILE_NONE_LABEL = '(プロファイルなし)';

// 現在値が profiles に無ければ(手書き設定等)unknownOption で補い選択状態を保つ。
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

// event.target===grid は「タイル自体ではなく空きエリア」をクリックした場合の判定。
grid.addEventListener('click', (event) => {
  if (event.target === grid && selectedDeviceIds.size > 0) {
    selectedDeviceIds.clear();
    updateSelectionUi();
  }
});

// deltaX(トラックパッド横)+deltaY(ホイール縦)を横スクロールに変換。preventDefault に passive:false が必須。
grid.addEventListener(
  'wheel',
  (event) => {
    grid.scrollLeft += event.deltaX + event.deltaY;
    event.preventDefault();
  },
  { passive: false },
);

// 「掴んで動かす」向き: ポインタ右へ動くとcontentも右へ(scrollLeft -= dx)。
// setPointerCapture によりグリッド外へ出てもドラッグを継続できる。
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
// Chromium の中クリック既定動作(オートスクロール等)を抑止する。
grid.addEventListener('auxclick', (event) => {
  if (event.button === 1) {
    event.preventDefault();
  }
});
