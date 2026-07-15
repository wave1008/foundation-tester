// tiles/selectedDeviceIds/deviceOpMenuEntry の書き込みはこのモジュールに限定する。
// laneLog.js は tiles/selectedDeviceIds を読み取り専用で参照する。

import { vscode } from './vscodeApi.js';
import { grid, emptyMessage, banner, btnUp, btnDown, deviceOpMenu, deviceOpMenuItemBtn, deviceOpMenuItemLabel, deviceOpMenuLiveBtn, profileSelect } from './domRefs.js';
import { updateLaneVisibility, syncLanesToDevices, runningWorkers } from './laneLog.js';
import { createH264Renderer } from './h264Decoder.js';

const STATE_LABEL = {
  connected: '接続済み',
  booted: '起動中',
  offline: '未起動',
};

// bridgeWatch(拡張ホストの自動修復ウォッチドッグ、契約は main.js の 'bridgeWatch' ケース参照)の
// phase→footer表示。'ok'はここに含めず通常表示へフォールバックさせる。
const BRIDGE_WATCH_LABEL = {
  unresponsive: { label: 'ブリッジ応答なし', warn: true },
  repairing: { label: 'ブリッジ再起動中…', warn: false },
  failed: { label: '復旧失敗(ftester出力参照)', warn: true },
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
// bootBusy.bulkOp(「全て起動/終了」がキュー内にある間 'up'/'down'、無ければ null)。
// up の間は未起動タイルを「待機中」、down の間は稼働中タイルを「シャットダウン中」表示にする
// (起動/終了が進み devices サイクルで state が変われば通常表示に遷移)。
let bulkOpActive = null;
// 空 = 全ワーカー表示(絞り込みなし)
export const selectedDeviceIds = new Set();

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

  const footer = document.createElement('div');
  footer.className = 'tile-footer';
  const stateBadge = document.createElement('span');
  stateBadge.className = 'tile-state';
  const error = document.createElement('span');
  error.className = 'tile-error';
  footer.append(stateBadge, error);

  tile.append(header, frameWrap, footer);
  grid.appendChild(tile);

  const entry = {
    device,
    tile,
    nameEl: name,
    // そのデバイスの直列キュー上の状態({ op: 'up'|'down', status: 'queued'|'running' })。
    // キューに入っていなければ undefined。
    opBusy: undefined,
    stateBadgeEl: stateBadge,
    runningBadgeEl: runningBadge,
    frameWrapEl: frameWrap,
    imgEl: img,
    placeholderEl: placeholder,
    errorEl: error,
    frameSrc: null,
    // bridgeWatch の直近 phase('ok'/未受信は undefined)。state==='booted' の間だけ表示に反映する。
    bridgeWatchPhase: undefined,
    // ストリーム描画 ack(streamRendered)の直近送信時刻(ms)。2秒スロットリング用
    // (受け手側 noteStreamRendered は冪等なので多重送信は無害だがスパムを避ける)。
    streamAckAt: 0,
    // キーフレーム未受信のまま届いたデルタチャンク数と streamStall 送信済みフラグ
    // (キーフレーム到着でどちらもリセット=ヘルパー再起動1世代につき最大1回送る)。
    h264DeltasBeforeKey: 0,
    h264StallSent: false,
    // h264 描画中(canvas 表示・img 非表示)かどうか。canvasEl/h264Renderer は初回 h264Chunk で遅延生成。
    // h264ErrorSent は codecError 送信済み(以後 applyH264Chunk を無視、frame 復帰待ち)のガード。
    canvasEl: null,
    h264Renderer: null,
    usingH264: false,
    h264ErrorSent: false,
  };
  tiles.set(device.id, entry);
  return entry;
}

function renderFrame(entry) {
  entry.frameWrapEl.textContent = '';
  const offline = entry.device.state === 'offline';
  // 終了中(一括・個別とも)は最終フレームを凍結表示のまま見せず、プレースホルダに倒す
  // (ストリームは down 開始時に破棄済みで、以後フレームは更新されない)。
  const shuttingDown = !offline && (bulkOpActive === 'down' || entry.opBusy?.op === 'down');
  // まだ offline の起動操作中の表示分け(booted への遷移は devices サイクルの state 更新に任せる):
  //  - 個別起動が実行中(status==='running'=simctl 起動処理が走っている)→「起動中」スピナー(下の booting 分岐)
  //  - 個別起動がキュー待ち(status==='queued')/一括起動(個別 status を持たない)→「待機中」時計
  const upRunning = offline && entry.opBusy?.op === 'up' && entry.opBusy.status === 'running';
  const waitingUp = offline && !upRunning && (bulkOpActive === 'up' || entry.opBusy?.op === 'up');
  if (!offline && !shuttingDown && (entry.frameSrc || entry.usingH264)) {
    if (entry.frameSrc) {
      entry.imgEl.src = entry.frameSrc;
    }
    entry.imgEl.alt = entry.device.name;
    // usingH264 中は img を DOM に残したまま非表示にする(mjpeg フォールバック復帰時に renderFrame
    // だけで即再表示できるようにするため。canvas は h264 停止後も再利用せず null 化する)。
    entry.imgEl.classList.toggle('h264-hidden', entry.usingH264);
    entry.frameWrapEl.appendChild(entry.imgEl);
    if (entry.canvasEl) {
      entry.canvasEl.classList.toggle('visible', entry.usingH264);
      entry.frameWrapEl.appendChild(entry.canvasEl);
    }
  } else {
    // offline→未起動+電源アイコン(起動待ちは待機中+時計)、終了中→シャットダウン中+
    // 無彩色スピナー、それ以外(booted/フレーム未着)→起動中+スピナー。
    entry.placeholderEl.textContent = '';
    const icon = document.createElement('span');
    if (shuttingDown) {
      icon.className = 'placeholder-icon shutdown';
    } else if (waitingUp) {
      icon.className = 'placeholder-icon waiting';
      icon.innerHTML = '<svg width="14" height="14" viewBox="0 0 16 16" fill="none"'
        + ' stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">'
        + '<circle cx="8" cy="8" r="6.2"/><path d="M8 4.6v3.4l2.4 1.5"/></svg>';
    } else if (offline && !upRunning) {
      icon.className = 'placeholder-icon offline';
      icon.innerHTML = '<svg width="14" height="14" viewBox="0 0 16 16" fill="none"'
        + ' stroke="currentColor" stroke-width="1.6" stroke-linecap="round">'
        + '<path d="M8 1.8v5.4"/><path d="M4.4 3.9a5.4 5.4 0 1 0 7.2 0"/></svg>';
    } else {
      // booted 待ち、または個別起動が実行中(offline のまま simctl 起動処理中)。
      icon.className = 'placeholder-icon booting';
    }
    const labelSpan = document.createElement('span');
    labelSpan.textContent = shuttingDown
      ? 'シャットダウン中'
      : waitingUp
        ? '待機中'
        : offline && !upRunning
          ? '未起動'
          : '起動中';
    entry.placeholderEl.append(icon, labelSpan);
    entry.frameWrapEl.appendChild(entry.placeholderEl);
  }
}

// renderDeviceOpMenuItem は内部で呼ぶ(opBusy・state 変化時の一括再描画)。
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
  // booted 離脱時は古い phase を捨てる(再度 booted に戻った際に前回の死活情報を誤って出さないため)。
  if (entry.device.state !== 'booted') {
    entry.bridgeWatchPhase = undefined;
  }
  // deviceOpBusy(実行中の起動/停止操作)がある間は既存表示を優先し、bridgeWatch では上書きしない。
  let warn = false;
  if (entry.device.state === 'booted' && !entry.opBusy && entry.bridgeWatchPhase) {
    const override = BRIDGE_WATCH_LABEL[entry.bridgeWatchPhase];
    if (override) {
      footerText = override.label;
      warn = override.warn;
    }
  }
  entry.stateBadgeEl.classList.toggle('tile-status-warn', warn);
  entry.stateBadgeEl.textContent = footerText;
  if (deviceOpMenuEntry === entry) {
    renderDeviceOpMenuItem();
  }
}

// 現在メニューを開いている対象のタイル entry(未オープンなら null)。
export let deviceOpMenuEntry = null;

export function renderDeviceOpMenuItem() {
  if (!deviceOpMenuEntry) {
    return;
  }
  const item = deviceOpMenuItem(deviceOpMenuEntry.device.state, deviceOpMenuEntry.opBusy);
  // ラベルはspanに書く(ボタン直のtextContent代入はアイコンSVGを消す)。data-opはCSSのアイコン切替も担う。
  deviceOpMenuItemLabel.textContent = item.label;
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
  // ライブ操作はブリッジ接続済み(state==='connected')でのみ機能する(liveTab.js の「接続されていません」
  // 警告と対)。未接続では項目自体を出さない。
  deviceOpMenuLiveBtn.style.display = entry.device.state === 'connected' ? '' : 'none';
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
function findTileByName(name) {
  for (const entry of tiles.values()) {
    if (entry.device.name === name) {
      return entry;
    }
  }
  return undefined;
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
    renderMeta(entry);
    renderFrame(entry);
    clearTileError(entry);
  }
  for (const [id, entry] of tiles) {
    if (!seen.has(id)) {
      if (deviceOpMenuEntry === entry) {
        closeDeviceOpMenu();
      }
      disposeH264(entry);
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
  // mjpeg フォールバック復帰(codecError 後は host が mjpeg に切替え以後 frame のみ届く)。
  if (entry.usingH264) {
    disposeH264(entry);
  }
  // --tile-aspect は CSS 側でタイル幅の計算に使われる。
  if (message.width > 0 && message.height > 0) {
    entry.tile.style.setProperty('--tile-aspect', (message.width / message.height).toFixed(4));
  }
  renderMeta(entry);
  renderFrame(entry);
  clearTileError(entry);
  // stream: true = ストリーミングヘルパー(mjpeg)由来。描画できたのでポーリング抑止を ack する
  if (message.stream) {
    ackStreamRendered(entry);
  }
}

function disposeH264(entry) {
  entry.usingH264 = false;
  if (entry.h264Renderer) {
    entry.h264Renderer.dispose();
    entry.h264Renderer = null;
  }
}

// ストリーム由来フレームを実際に描画できたことをホストへ ack する(2秒スロットリング)。
// ホストはこれを受けて初めてポーリングを間引く(契約: monitorDeviceStreamController.ts 冒頭。
// ホスト受信基準で間引くと、webview 準備前に初期キーフレームが落ちた場合にタイルが餓死する)
function ackStreamRendered(entry) {
  const now = Date.now();
  if (now - entry.streamAckAt < 2000) {
    return;
  }
  entry.streamAckAt = now;
  vscode.postMessage({ type: 'streamRendered', device: entry.device.id });
}

// h264Chunk(タイル用ストリーム)。デバイス毎にレンダラ/canvas を遅延生成し、初回描画(onFirstFrame)
// で img→canvas に切り替える。h264ErrorSent 済みなら以後は無視(host が mjpeg に切替済みの前提)。
export function applyH264Chunk(message) {
  const entry = tiles.get(message.device);
  if (!entry || entry.h264ErrorSent) {
    return;
  }
  // デコーダはキーフレームから始まる必要がある。初期キーフレームを取り逃した世代(webview 準備前に
  // 送信済み等)はデルタしか届かず永久に描画できないため、ホストにヘルパー再起動を頼む
  if (message.keyframe) {
    entry.h264DeltasBeforeKey = 0;
    entry.h264StallSent = false;
  } else if (!entry.usingH264) {
    entry.h264DeltasBeforeKey += 1;
    if (entry.h264DeltasBeforeKey >= 30 && !entry.h264StallSent) {
      entry.h264StallSent = true;
      vscode.postMessage({ type: 'streamStall', device: message.device });
    }
  }
  if (!entry.h264Renderer) {
    entry.canvasEl = entry.canvasEl || document.createElement('canvas');
    entry.h264Renderer = createH264Renderer({
      canvas: entry.canvasEl,
      onFirstFrame: (dims) => {
        entry.usingH264 = true;
        if (dims.width > 0 && dims.height > 0) {
          entry.tile.style.setProperty('--tile-aspect', (dims.width / dims.height).toFixed(4));
        }
        renderMeta(entry);
        renderFrame(entry);
      },
      onFrameRendered: () => {
        ackStreamRendered(entry);
      },
      onError: () => {
        entry.h264ErrorSent = true;
        vscode.postMessage({ type: 'codecError', scope: 'tile', device: message.device });
        disposeH264(entry);
        renderFrame(entry);
      },
    });
  }
  entry.h264Renderer.pushChunk(message.data, message.keyframe, message.width, message.height);
}

// 契約: { type: 'deviceOpBusy', name, op, status }(monitorDeviceOps.ts postDeviceLifecycleStatus と対。
// op: 'up'|'down'|null、status: 'queued'|'running'|null)。
export function applyDeviceOpBusy(message) {
  const entry = findTileByName(message.name);
  if (!entry) {
    return;
  }
  const prev = entry.opBusy;
  entry.opBusy = message.op ? { op: message.op, status: message.status || 'running' } : undefined;
  // opBusy の有無は footer の bridgeWatch 優先度判定にも影響するため renderMeta で一括再描画する。
  renderMeta(entry);
  // down 完了直後の稼働中タイルは再描画しない(setBusy の down 解除と同じ理由: state が offline に
  // 更新される前に再描画すると凍結フレームが一瞬再表示される。次の devices 反映で「未起動」へ遷移)。
  if (prev?.op === 'down' && !entry.opBusy && entry.device.state !== 'offline') {
    return;
  }
  renderFrame(entry);
}

// 契約: { type: 'bridgeWatch', name, phase }(name は deviceOpBusy と同じ device.name 名前空間)。
export function applyBridgeWatch(message) {
  const entry = findTileByName(message.name);
  if (!entry) {
    return;
  }
  entry.bridgeWatchPhase = message.phase === 'ok' ? undefined : message.phase;
  renderMeta(entry);
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

export function setBusy(busy, bulkOp) {
  btnUp.disabled = busy;
  btnDown.disabled = busy;
  const next = bulkOp === 'up' || bulkOp === 'down' ? bulkOp : null;
  if (bulkOpActive !== next) {
    const wasDown = bulkOpActive === 'down';
    bulkOpActive = next;
    // 表示(未起動⇔待機中、フレーム⇔シャットダウン中)を即時反映する。次の devices サイクルを
    // 待つと数秒古い表示のままに見える。
    for (const entry of tiles.values()) {
      // down 解除時の稼働中タイルは除外: state が offline に更新される前に再描画すると凍結フレームが
      // 一瞬再表示される。「シャットダウン中」のまま次の devices 反映で「未起動」へ直接遷移させる。
      if (wasDown && entry.device.state !== 'offline') {
        continue;
      }
      renderFrame(entry);
    }
  }
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
