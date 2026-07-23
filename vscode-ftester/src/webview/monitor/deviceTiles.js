// tiles/selectedDeviceIds/deviceOpMenuEntry の書き込みはこのモジュールに限定する。
// laneLog.js は tiles/selectedDeviceIds を読み取り専用で参照する。
// healthWatch(MonitorHealthWatchdog、Android ゲスト OS 異常の自動修復)は state==='connected' の
// 間だけ footer に表示する(bridgeWatch は state==='booted' の間だけ表示、と対で排他)。
// footer 優先順位: opBusy > wipeStatus > bridgeWatch/healthWatch。wipeStatus は Wipe 中に
// offline/booted を経由する(state==='connected' に限定できない)ため他2つと別枠で判定する。

import { t } from '../i18n.js';
import { vscode } from './vscodeApi.js';
import { grid, emptyMessage, banner, btnUp, btnDown, deviceOpMenu, deviceOpMenuItemBtn, deviceOpMenuItemLabel, deviceOpMenuLiveBtn, deviceOpMenuGpuBtn, profileSelect } from './domRefs.js';
import { updateLaneVisibility, syncLanesToDevices, runningWorkers } from './laneLog.js';
import { createH264Renderer } from './h264Decoder.js';
import { clampMenuPosition } from './menu.js';

// bridgeWatch(拡張ホストの自動修復ウォッチドッグ、契約は main.js の 'bridgeWatch' ケース参照)の
// phase→footer表示。'ok'はここに含めず通常表示へフォールバックさせる。
// unresponsive(検知中)・repairing(自動修復中)は表示しない(ユーザー決定 2026-07-16:
// 過渡的・自己解決する内部状態のため)。自動修復が諦めた failed だけ表示する
// (これも消すとブリッジ死亡時にタイルが無言で「接続中」のまま止まり手掛かりが無くなる)。
const BRIDGE_WATCH_LABEL = {
  failed: { label: t('wvMonitor.footer.bridgeRepairFailed'), warn: true },
};

// healthWatch(MonitorHealthWatchdog、契約は main.js の 'healthWatch' ケース参照)の phase→footer表示。
// 'ok' はここに含めず通常表示へフォールバックさせる。bridgeWatch と異なり全 phase を表示する
// (Wi-Fi/時計異常はブリッジ無応答と違い自己解決しないため、修復の進行状況を出す)。
const HEALTH_WATCH_LABEL = {
  unhealthy: { label: t('wvMonitor.footer.healthUnhealthy'), warn: true },
  repairing: { label: t('wvMonitor.footer.healthWifiRepairing'), warn: true },
  streamRepairing: { label: t('wvMonitor.footer.healthStreamRepairing'), warn: true },
  cpuFallback: { label: t('wvMonitor.footer.healthCpuFallback'), warn: true },
  restarting: { label: t('wvMonitor.footer.healthRestarting'), warn: true },
  failed: { label: t('wvMonitor.footer.healthFailed'), warn: true },
};

// wipeStatus(`ftester api run` 開始時の AVD Wipe Data、契約は main.js の 'wipeStatus' ケース参照)の
// phase→footer表示。'done' はここに含めず通常表示へフォールバックさせる。'failed' は次の
// wipeStatus 受信まで残す(applyWipeStatus 参照)。
const WIPE_STATUS_LABEL = {
  stopping: { label: t('wvMonitor.footer.wipeStopping'), warn: false },
  rebooting: { label: t('wvMonitor.footer.wipeRebooting'), warn: false },
  failed: { label: t('wvMonitor.footer.wipeFailed'), warn: true },
};

// src/monitorModel.ts の deviceOpMenuItem の複製(webview は CSP で import 不可のため)。変更時は
// 両方を同期すること。busy は { op, status }('queued'|'running')または undefined。
function deviceOpMenuItem(state, busy) {
  if (busy && busy.status === 'queued') { return { label: t('wvMonitor.deviceOpMenu.queued'), op: busy.op, disabled: true }; }
  if (busy && busy.op === 'up') { return { label: t('wvMonitor.deviceOpMenu.startingUp'), op: 'up', disabled: true }; }
  if (busy && busy.op === 'down') { return { label: t('wvMonitor.deviceOpMenu.stoppingDown'), op: 'down', disabled: true }; }
  return state === 'offline'
    ? { label: t('wvMonitor.deviceOpMenu.start'), op: 'up', disabled: false }
    : { label: t('wvMonitor.deviceOpMenu.stop'), op: 'down', disabled: false };
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
  tile.title = t('wvMonitor.tile.title');
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
  const renderBadge = document.createElement('span');
  renderBadge.className = 'badge badge-render';
  const runningBadge = document.createElement('span');
  runningBadge.className = 'badge badge-running';
  runningBadge.textContent = t('wvMonitor.tile.running');
  // ライフサイクルキュー待ち(queued)の明示チップ。「全て起動」時にどのデバイスが処理待ちか
  // 一目で分かるようにする。タイル左下(フッター先頭)に置く(ユーザー指定)。表示は renderMeta。
  const queuedBadge = document.createElement('span');
  queuedBadge.className = 'badge badge-queued';
  // 録画中バッジ。device.recording が true の間だけ表示(renderMeta が切替)。
  const recordingBadge = document.createElement('span');
  recordingBadge.className = 'badge badge-recording';
  recordingBadge.textContent = t('recordings.deviceBadge');
  header.append(name);

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
  // renderBadge はフッター末尾に置く。tile-error が flex:1 で伸びるため自動的に右端(=タイル右下)に寄る。
  // 実行中/キュー待ち/録画中のバッジはタイル左下(フッター先頭)。録画は実行中の右(ユーザー指定)。
  footer.append(runningBadge, recordingBadge, queuedBadge, stateBadge, error, renderBadge);

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
    queuedBadgeEl: queuedBadge,
    recordingBadgeEl: recordingBadge,
    renderBadgeEl: renderBadge,
    frameWrapEl: frameWrap,
    imgEl: img,
    placeholderEl: placeholder,
    errorEl: error,
    frameSrc: null,
    // bridgeWatch の直近 phase('ok'/未受信は undefined)。state==='booted' の間だけ表示に反映する。
    bridgeWatchPhase: undefined,
    // healthWatch の直近 phase('ok'/未受信は undefined)。state==='connected' の間だけ表示に反映する。
    healthWatchPhase: undefined,
    // wipeStatus の直近 phase('done'/未受信は undefined)。device.state に関わらず表示に反映する。
    wipePhase: undefined,
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
    // 再起動(down 実行)後、monitor の renderMode が再検出されるまで 'cpu' を信用しないフラグ
    // (renderRenderBadge のちらつき対策)。connected を離れたら解除(次の値は再検出値)。
    // down が失敗して実際には落ちなかった場合の保険として、opBusy 無しの connected を
    // 3サイクル連続観測したら「本当にまだ CPU」とみなして解除する(staleConnectedCycles)。
    renderModeStale: false,
    staleConnectedCycles: 0,
  };
  tiles.set(device.id, entry);
  return entry;
}

function renderFrame(entry) {
  entry.frameWrapEl.textContent = '';
  const offline = entry.device.state === 'offline';
  // 終了中(一括・個別とも)は最終フレームを凍結表示のまま見せず、プレースホルダに倒す
  // (ストリームは down 開始時に破棄済みで、以後フレームは更新されない)。
  // ただし個別 down が「キュー待ち(queued)」の間はまだ stopDeviceStreams 前=ストリーム生存中なので
  // シャットダウン扱いにしない(ライブ映像を出したまま順番待ち)。実際に落ち始める running でだけ倒す。
  // これを外すと、一括起動の後ろに積まれた再起動待ちの CPU 機が、まだ動いているのに数分間
  // 「シャットダウン中」表示で固まって見える(順番待ちを停止中と誤認させる)。
  const shuttingDown = !offline && (bulkOpActive === 'down'
    || (entry.opBusy?.op === 'down' && entry.opBusy.status === 'running'));
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
    // 無彩色スピナー、ブート処理中(offline のまま upRunning)→起動中+スピナー、
    // booted でフレーム未着(ブリッジ供給・ストリーム確立待ち)→接続中+スピナー。
    // 「起動中」をブート処理中に限定することで、同時ブート上限(2台)とタイル表示が一致する。
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
      // スピナー色はプラットフォーム別(タイトルのピルと同色。style.css の booting-ios/-android)
      icon.className = 'placeholder-icon booting booting-' + entry.device.platform;
    }
    const labelSpan = document.createElement('span');
    labelSpan.textContent = shuttingDown
      ? t('wvMonitor.tile.shuttingDown')
      : waitingUp
        ? t('wvMonitor.tile.waiting')
        : offline
          ? (upRunning ? t('wvMonitor.deviceState.booting') : t('wvMonitor.deviceState.offline'))
          : t('wvMonitor.tile.connecting');
    entry.placeholderEl.append(icon, labelSpan);
    entry.frameWrapEl.appendChild(entry.placeholderEl);
  }
}

// GPU/CPU はゲスト OS 異常ではなく構成情報のため device.state に関わらず表示してよい
// (offline 等で renderMode 未受信なら非表示)
function renderRenderBadge(entry) {
  const device = entry.device;
  // GPU(host)は既定状態なのでバッジを出さない。CPU(swiftshader=凍結フォールバック)だけ表示する。
  // 表示規則(一貫性のため位相で固定):
  //  - 再起動キュー待ち(opBusy queued): 表示したまま(まだ実際に CPU で動いている。フッターの
  //    「再起動待機中...」が処理予定を伝える)
  //  - down/up 実行中(opBusy running)・未接続: 非表示
  //  - 再起動完了直後: renderModeStale の間は非表示(monitor が connected 降格 debounce+serial
  //    キャッシュで再起動前の 'cpu' を一瞬送り続けるため、そのまま出すとバッジが消えた後に
  //    一瞬再表示されるちらつきになる。ApiMonitorCommand 参照。フラグ管理は applyDevices/applyDeviceOpBusy)
  const isCpu = device.platform === 'android' && device.renderMode === 'cpu'
    && device.state === 'connected'
    && !(entry.opBusy && entry.opBusy.status === 'running')
    && !entry.renderModeStale;
  if (!isCpu) {
    entry.renderBadgeEl.style.display = 'none';
    return;
  }
  // 明示的に inline-block を入れる('' だと CSS の .badge-render{display:none} に戻り永久非表示になる)
  entry.renderBadgeEl.style.display = 'inline-block';
  entry.renderBadgeEl.className = 'badge badge-render render-cpu';
  entry.renderBadgeEl.textContent = 'CPU';
  entry.renderBadgeEl.title = t('wvMonitor.tile.cpuBadgeTitle');
}

// renderDeviceOpMenuItem は内部で呼ぶ(opBusy・state 変化時の一括再描画)。
function renderMeta(entry) {
  entry.nameEl.textContent = entry.device.name;
  entry.nameEl.className = 'tile-name tile-name-' + entry.device.platform;
  entry.nameEl.title = entry.device.name + ' (' + entry.device.platform + ')';
  entry.recordingBadgeEl.style.display = entry.device.recording ? 'inline-block' : 'none';
  renderRenderBadge(entry);
  // 通常時は空(接続済みは画面表示自体が、接続待ちはプレースホルダの「接続中」が伝えるため
  // 冗長で出さない。ユーザー決定 2026-07-16)。bridgeWatch の異常時だけ下で埋める。
  // 要素は固定高のため空でも残す(タイル高の計算は createTile 付近のコメント参照)。
  let footerText = '';
  // booted/connected 離脱時は古い phase を捨てる(再度その state に戻った際に前回の死活情報を
  // 誤って出さないため)。再起動中は connected を離れる=healthWatchPhase が捨てられ、opBusy
  // バッジ(「起動中」等)に表示を譲る。
  if (entry.device.state !== 'booted') {
    entry.bridgeWatchPhase = undefined;
  }
  if (entry.device.state !== 'connected') {
    entry.healthWatchPhase = undefined;
  }
  // 優先順位: deviceOpBusy(手動の起動/停止操作) > wipeStatus > bridgeWatch/healthWatch。
  // state で排他(booted/connected)のため bridgeWatch と healthWatch は衝突しない。
  let warn = false;
  if (entry.opBusy) {
    // 何もしない: footerText は空のまま(キュー待ちは左下の queuedBadge チップが伝える。
    // 実行中の down/up はプレースホルダ側のラベルに譲る)。
  } else if (entry.wipePhase) {
    const override = WIPE_STATUS_LABEL[entry.wipePhase];
    if (override) {
      footerText = override.label;
      warn = override.warn;
    }
  } else if (entry.device.state === 'booted' && entry.bridgeWatchPhase) {
    const override = BRIDGE_WATCH_LABEL[entry.bridgeWatchPhase];
    if (override) {
      footerText = override.label;
      warn = override.warn;
    }
  } else if (entry.device.state === 'connected' && entry.healthWatchPhase) {
    const override = HEALTH_WATCH_LABEL[entry.healthWatchPhase];
    if (override) {
      footerText = override.label;
      warn = override.warn;
    }
  }
  entry.stateBadgeEl.classList.toggle('tile-status-warn', warn);
  entry.stateBadgeEl.textContent = footerText;

  // キュー待ちチップ(ヘッダー)。per-device の queued(再起動待ち/個別起動待ち)に加え、
  // 一括起動中で CLI が未到達の未起動機(per-device 状態なし)にも「起動待機」を出す。
  // bulkOpActive 変化時の再評価は setBusy 側の renderMeta 一括呼び出しが担う。
  let queuedText = '';
  if (entry.opBusy?.status === 'queued') {
    queuedText = entry.opBusy.op === 'down' ? t('wvMonitor.tile.queuedRestart') : t('wvMonitor.tile.queuedStart');
  } else if (!entry.opBusy && bulkOpActive === 'up' && entry.device.state === 'offline') {
    queuedText = t('wvMonitor.tile.queuedStart');
  }
  entry.queuedBadgeEl.style.display = queuedText ? 'inline-block' : 'none';
  entry.queuedBadgeEl.textContent = queuedText;

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

function openDeviceOpMenu(entry, clientX, clientY) {
  deviceOpMenuEntry = entry;
  renderDeviceOpMenuItem();
  // ライブ操作はブリッジ接続済み(state==='connected')でのみ機能する(liveTab.js の「接続されていません」
  // 警告と対)。未接続では項目自体を出さない。
  deviceOpMenuLiveBtn.style.display = entry.device.state === 'connected' ? '' : 'none';
  // 「GPUで再起動」は CPU 描画フォールバック中(CPU バッジ)の Android タイルでのみ意味を持つ。
  // 起動/停止のライフサイクル操作中(opBusy)は再起動を積んでも enqueueRestart が無視するため出さない。
  deviceOpMenuGpuBtn.style.display =
    !entry.opBusy && entry.device.platform === 'android' && entry.device.renderMode === 'cpu' ? '' : 'none';
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

// CPU 描画フォールバックを解除して host GPU で再起動(受け手は monitorPanel.ts の deviceRestartGpu)。
deviceOpMenuGpuBtn.addEventListener('click', (event) => {
  event.stopPropagation();
  if (!deviceOpMenuEntry) {
    return;
  }
  vscode.postMessage({ type: 'deviceRestartGpu', name: deviceOpMenuEntry.device.name });
  closeDeviceOpMenu();
});

// 受け手: monitorPanel.ts → livePanel.ts の openForDevice(独立ライブ操作パネルを表示)。
deviceOpMenuLiveBtn.addEventListener('click', (event) => {
  event.stopPropagation();
  if (!deviceOpMenuEntry) {
    return;
  }
  vscode.postMessage({ type: 'openLiveForDevice', id: deviceOpMenuEntry.device.id });
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
      // renderModeStale の解除判定(フラグの意味は createTile の初期化コメント参照)。
      if (entry.renderModeStale) {
        if (device.state !== 'connected') {
          entry.renderModeStale = false;
        } else if (!entry.opBusy) {
          entry.staleConnectedCycles += 1;
          if (entry.staleConnectedCycles >= 3) {
            entry.renderModeStale = false;
          }
        }
      }
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
  // タイルの DOM 順を devices 順(host が sortMonitorDevices で整列済み)に合わせる。
  // 生成順は概ね一致するが、モニター再起動でデバイスが増えた場合などは末尾追加でずれるため、
  // 不一致のときだけ並べ直す(毎サイクルの appendChild は無駄な DOM 移動になるので避ける)。
  const ordered = devices.map((device) => tiles.get(device.id)).filter(Boolean);
  if (ordered.some((entry, index) => grid.children[index] !== entry.tile)) {
    for (const entry of ordered) {
      grid.appendChild(entry.tile);
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
// op: 'up'|'down'|null、status: 'queued'|'running'|null)。一括起動時は executeBulkJob の
// devices-up NDJSON 中継からも同形のメッセージが飛ぶ(op:'up'→null。由来は個別デバイスではなく一括起動)。
export function applyDeviceOpBusy(message) {
  const entry = findTileByName(message.name);
  if (!entry) {
    return;
  }
  const prev = entry.opBusy;
  entry.opBusy = message.op ? { op: message.op, status: message.status || 'running' } : undefined;
  // down が実際に走り始めた時点から、monitor の 'cpu' は再起動前の残存値になりうる
  // (フラグの意味・解除は createTile 初期化コメントと applyDevices 参照)。
  if (entry.device.platform === 'android'
      && entry.opBusy?.op === 'down' && entry.opBusy.status === 'running') {
    entry.renderModeStale = true;
    entry.staleConnectedCycles = 0;
  }
  // opBusy の有無は footer の bridgeWatch 優先度判定にも影響するため renderMeta で一括再描画する。
  renderMeta(entry);
  // down 完了直後の稼働中タイルは再描画しない(setBusy の down 解除と同じ理由: state が offline に
  // 更新される前に再描画すると凍結フレームが一瞬再表示される。次の devices 反映で「未起動」へ遷移)。
  if (prev?.op === 'down' && !entry.opBusy && entry.device.state !== 'offline') {
    return;
  }
  renderFrame(entry);
}

// 契約: { type: 'deviceDownFinished', name }(monitorModel.ts / monitorDeviceOps.ts の api devices-down)。
// 一括 down で1台の停止が完了した通知。down 中はモニターが pause で state 更新を出さないため、この
// タイルだけ offline を先行反映して「未起動」へ倒す(次の devices 反映=resume 後に本物の state で
// 上書きされる)。opBusy も解除する。offline を立てることで renderFrame が凍結フレームを出さない
// (applyDeviceOpBusy の「down 完了直後は再描画しない」フリッカ回避と同じ問題をここで解消する)。
export function applyDeviceDownFinished(message) {
  const entry = findTileByName(message.name);
  if (!entry) {
    return;
  }
  entry.device = { ...entry.device, state: 'offline' };
  entry.opBusy = undefined;
  renderMeta(entry);
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

// 契約: { type: 'healthWatch', name, phase }(name は deviceOpBusy と同じ device.name 名前空間)。
export function applyHealthWatch(message) {
  const entry = findTileByName(message.name);
  if (!entry) {
    return;
  }
  entry.healthWatchPhase = message.phase === 'ok' ? undefined : message.phase;
  renderMeta(entry);
}

// 契約: { type: 'wipeStatus', name, phase }(name は deviceOpBusy と同じ device.name 名前空間。
// 契約元は model.ts の WipeStatusEvent / monitorPanel.ts の handleWipeStatusEvent)。
export function applyWipeStatus(message) {
  const entry = findTileByName(message.name);
  if (!entry) {
    return;
  }
  entry.wipePhase = message.phase === 'done' ? undefined : message.phase;
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
  // bulk up 実行中は「全て起動」ボタンを中断ボタンに転用する(クリック時の分岐は main.js。
  // 受け手: monitorPanel.ts devicesUpCancel → MonitorDeviceOps.cancelBulkUp)。
  const upCancelMode = busy && bulkOp === 'up';
  btnUp.disabled = busy && !upCancelMode;
  btnUp.textContent = upCancelMode ? t('wvMonitor.bulk.cancelStart') : t('wvMonitor.bulk.startAll');
  btnDown.disabled = busy;
  const next = bulkOp === 'up' || bulkOp === 'down' ? bulkOp : null;
  if (bulkOpActive !== next) {
    const wasDown = bulkOpActive === 'down';
    bulkOpActive = next;
    // 表示(未起動⇔待機中、フレーム⇔シャットダウン中)を即時反映する。次の devices サイクルを
    // 待つと数秒古い表示のままに見える。
    for (const entry of tiles.values()) {
      // キュー待ちチップ(起動待機)は bulkOpActive に依存するため全タイル再評価する。
      renderMeta(entry);
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

const PROFILE_NONE_LABEL = t('wvMonitor.profile.none');

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
