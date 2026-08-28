// tiles/selectedDeviceIds/deviceOpMenuEntry の書き込みはこのモジュールに限定する。
// laneLog.js は tiles/selectedDeviceIds を読み取り専用で参照する。
// healthWatch(MonitorHealthWatchdog、Android ゲスト OS 異常の自動修復)は state==='connected' の
// 間だけ footer に表示する(bridgeWatch は state==='booted' の間だけ表示、と対で排他)。
// footer 優先順位: opBusy > wipeStatus > bridgeWatch/healthWatch。wipeStatus は Wipe 中に
// offline/booted を経由する(state==='connected' に限定できない)ため他2つと別枠で判定する。

import { t } from '../i18n.js';
import { vscode } from './vscodeApi.js';
import { grid, emptyMessage, banner, btnUp, btnDown, deviceOpMenu, deviceOpMenuItemBtn, deviceOpMenuItemLabel, deviceOpMenuLiveBtn, deviceOpMenuGpuBtn, deviceOpMenuSep, deviceOpMenuSelectAllBtn, deviceOpMenuDeselectAllBtn, profileSelect, tilePane, tileMarquee } from './domRefs.js';
import { updateLaneVisibility, syncLanesToDevices, runningWorkers, relayoutPreviewsForResize } from './laneLog.js';
import { createH264Renderer } from './h264Decoder.js';
import { clampMenuPosition } from './menu.js';
import { setHoverTip } from './hoverTip.js';
import { isDragDistance, marqueeRect, idsInMarquee, mergeMarqueeSelection, rectContains } from './marqueeModel.js';

// bridgeWatch(拡張ホストの自動修復ウォッチドッグ、契約は main.js の 'bridgeWatch' ケース参照)の
// phase→footer表示。'ok'はここに含めず通常表示へフォールバックさせる。
// unresponsive(検知中)・repairing(自動修復中)は表示しない(ユーザー決定:
// 過渡的・自己解決する内部状態のため)。自動修復が諦めた failed だけ表示する
// (これも消すとブリッジ死亡時にタイルが無言で「接続中」のまま止まり手掛かりが無くなる)。
// 実機と仮想機で原因も対処も違うため文言を分ける(実機=ケーブル/信頼設定など接続そのもの、
// 仮想機=ブリッジ供給の失敗)。内部的な「復旧失敗」ではなくユーザーが取れる行動が分かる語にする。
// 診断の入り口(fleetest 出力)はホバーのツールチップに退避する
function bridgeWatchLabel(phase, physical) {
  if (phase !== 'failed') { return undefined; }
  return {
    label: t(physical ? 'wvMonitor.footer.bridgeFailedPhysical' : 'wvMonitor.footer.bridgeFailedVirtual'),
    tip: t('wvMonitor.footer.bridgeFailedTip'),
    warn: true,
  };
}

// healthWatch(MonitorHealthWatchdog、契約は main.js の 'healthWatch' ケース参照)の phase→footer表示。
// 'ok' はここに含めず通常表示へフォールバックさせる。bridgeWatch と異なり全 phase を表示する
// (Wi-Fi/時計異常はブリッジ無応答と違い自己解決しないため、修復の進行状況を出す)。
const HEALTH_WATCH_LABEL = {
  unhealthy: { label: t('wvMonitor.footer.healthUnhealthy'), warn: true },
  repairing: { label: t('wvMonitor.footer.healthWifiRepairing'), warn: true },
  displayRepairing: { label: t('wvMonitor.footer.healthDisplayRepairing'), warn: true },
  streamRepairing: { label: t('wvMonitor.footer.healthStreamRepairing'), warn: true },
  cpuFallback: { label: t('wvMonitor.footer.healthCpuFallback'), warn: true },
  restarting: { label: t('wvMonitor.footer.healthRestarting'), warn: true },
  failed: { label: t('wvMonitor.footer.healthFailed'), warn: true },
};

// wipeStatus(`fleetest api run` 開始時の AVD Wipe Data、契約は main.js の 'wipeStatus' ケース参照)の
// phase→footer表示。'done' はここに含めず通常表示へフォールバックさせる。'failed' は次の
// wipeStatus 受信まで残す(applyWipeStatus 参照)。
const WIPE_STATUS_LABEL = {
  stopping: { label: t('wvMonitor.footer.wipeStopping'), warn: false },
  rebooting: { label: t('wvMonitor.footer.wipeRebooting'), warn: false },
  failed: { label: t('wvMonitor.footer.wipeFailed'), warn: true },
};

// src/monitorDeviceLifecycle.ts の deviceOpMenuItem の複製(webview は CSP で import 不可のため)。変更時は
// 両方を同期すること。busy は { op, status }('queued'|'running')または undefined。
// physical: 実機は端末そのものを起動・停止しない(DeviceBooter の実機分岐)。操作対象は
// **ブリッジだけ**なのでラベルで明示する(「起動/停止」だと端末の電源だと誤解される)。
// 項目自体は隠さない: 隠すとモニターから実機のブリッジを起動できなくなる(タイルが
// 「接続中」のまま何もできない状態になる実害。2026-07-25)
function deviceOpMenuItem(state, busy, physical) {
  if (busy && busy.status === 'queued') { return { label: t('wvMonitor.deviceOpMenu.queued'), op: busy.op, disabled: true }; }
  if (busy && busy.op === 'up') { return { label: t('wvMonitor.deviceOpMenu.startingUp'), op: 'up', disabled: true }; }
  if (busy && busy.op === 'down') { return { label: t('wvMonitor.deviceOpMenu.stoppingDown'), op: 'down', disabled: true }; }
  if (state === 'offline' || state === 'unknown') {
    return {
      label: t(physical ? 'wvMonitor.deviceOpMenu.startBridge' : 'wvMonitor.deviceOpMenu.start'),
      op: 'up', disabled: false,
    };
  }
  return {
    label: t(physical ? 'wvMonitor.deviceOpMenu.stopBridge' : 'wvMonitor.deviceOpMenu.stop'),
    op: 'down', disabled: false,
  };
}

// iOS 実機の state==='booted' は「端末は接続済みだがブリッジが1本も無い」の意味
// (ApiMonitorCommand.iosState。シミュレータの booted=起動済みとは意味が違う)。実機のブリッジは
// 自動供給されない(run かタイルのメニューからのみ起動する)ため、この状態は待っても変わらない。
// 「接続中」スピナーのまま放置すると復帰待ちに見えるので未起動として扱う(ユーザー決定)。
// android 実機の booted は「adb は見えるがブート未完了」= 本当に遷移途中なので対象外。
function bridgeNotRunning(device) {
  return device.kind === 'physical' && device.platform === 'ios' && device.state === 'booted';
}

// device id -> タイルDOM要素・最新フレーム(1枚のみ保持、履歴は溜めない)
export const tiles = new Map();
// bootBusy.bulkOp(「全て起動/終了」がキュー内にある間 'up'/'down'、無ければ null)。
// up の間は未起動タイルを「待機中」、down の間は稼働中タイルを「シャットダウン中」表示にする
// (起動/終了が進み devices サイクルで state が変われば通常表示に遷移)。
let bulkOpActive = null;
// 空 = 全ワーカー表示(絞り込みなし)
export const selectedDeviceIds = new Set();

// 出力ペインの拡大表示(選択したデバイスぶん。DOM は laneLog.js が用意し attach/detach を呼ぶ)。
// canvas も img も DOM の2箇所には置けないので「複製」で描く: mjpeg は同じ data URL を別の img へ、
// h264 はタイルの canvas を drawImage でコピーする(デコードは1回だけ。2重デコードはしない)。
// device id -> { wrapEl, imgEl, canvasEl }
const deviceMirrors = new Map();

// タイル内の「画像以外」の高さの合計(px)。CSS の固定高と一致させること:
// padding 上下 8+8 + header 20 + footer 18 + gap 6×2 = 66
const TILE_CHROME_HEIGHT = 66;
// マシン名バッジの段(.tile-machine-row)。**リモートのデバイスが1台でも居るときだけ**全タイルに
// 確保する —— タイルの画像高さ(--tile-image-h)はグリッド共通の1値で、段の有無が混ざると
// 高さが揃わない。手元だけの構成では従来と1px も変わらない。CSS の .tile-machine-row と一致必須
const TILE_MACHINE_ROW_HEIGHT = 16;
// 直近の applyDevices が「リモート込み」だったか(chrome 高さの算出に使う)
let machineRowReserved = false;

// タイル幅は「--tile-image-h × --tile-aspect」で決まる(style.css の .frame-wrap)。
// **実際にデコードできた画像の実寸からしか設定しない**: ストリームのヘッダ由来の寸法を信じると、
// 境界ズレで壊れたフレーム1枚がタイルを異常な幅に広げ、以後そのまま戻らない(実害 2026-07-26。
// 上流の検出は deviceStream.ts の handleProtocolDesync)。同値なら書かない(毎フレームの
// スタイル書き込みによるレイアウト再計算を避ける)
function setTileAspect(entry, aspect) {
  if (!entry) { return; }
  const value = aspect.toFixed(4);
  if (entry.tileAspect === value) { return; }
  entry.tileAspect = value;
  entry.tile.style.setProperty('--tile-aspect', value);
  // 拡大表示の段組みは縦横比から決まる(初回フレームで確定・解像度変更でも変わる)
  relayoutPreviewsForResize();
  notifyTileLayoutChanged('aspect');
}

// auto-fit(splitter.js)へ「タイル構成が変わった=ちょうど収まる高さが変わった」ことを伝える。
// 通知するのは台数変化('deviceCount')とアスペクト比確定('aspect')の2箇所だけ。reason は
// splitter.js がドラッグ一時停止の解除判定に使う。relayoutTiles からは通知しない
// (auto-fit の再計算が relayoutTiles を呼ぶため、通知すると無限ループになる)。
let tileLayoutObserver = null;

export function setTileLayoutObserver(observer) {
  tileLayoutObserver = observer;
}

function notifyTileLayoutChanged(reason) {
  if (tileLayoutObserver) {
    tileLayoutObserver(reason);
  }
}

// タイル実測高さから --tile-image-h を算出(タイル幅はこの高さ×アスペクト比で決まる)。
// スプリッター移動・リサイズ・タイル生成のたびに呼び直す必要がある。
export function relayoutTiles() {
  const probe = grid.querySelector('.tile');
  if (!probe) {
    return;
  }
  // 「デバイス」タブ非表示中(display:none)は clientHeight=0 で下限 60px に潰れる。書くと
  // 「ペイン高さ ↔ --tile-image-h」の対応が壊れ、タブ復帰時の auto-fit(splitter.js の
  // computeFitTilePaneHeight)が差分計算を誤ってはみ出す。devices は非表示中も届くので必須。
  if (probe.clientHeight === 0) {
    return;
  }
  const chrome = TILE_CHROME_HEIGHT + (machineRowReserved ? TILE_MACHINE_ROW_HEIGHT + 6 : 0);  // +6 = gap
  const imageHeight = Math.max(60, probe.clientHeight - chrome);
  grid.style.setProperty('--tile-image-h', imageHeight + 'px');
}

function createTile(device) {
  const tile = document.createElement('div');
  tile.className = 'tile';
  tile.title = t('wvMonitor.tile.title');
  // 選択のクリックはタイルごとに張らず grid へ委譲する(当たりの規則はそちらのコメント)。
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
  // 手元でないデバイスのホスト名(マシンプロファイル/実行プロファイルの一覧と同じバッジ)。
  // **モニターは手元のデバイスしか触れない**ので、リモートのタイルは状態を観測できない ——
  // 「どの機械の台か」を出さないと、未起動表示の理由が分からない
  const remoteBadge = document.createElement('span');
  remoteBadge.className = 'badge badge-remote';
  remoteBadge.style.display = 'none';
  const kindBadge = document.createElement('span');
  kindBadge.className = 'badge badge-kind';
  kindBadge.textContent = t('wvMonitor.tile.physicalBadge');
  kindBadge.title = t('wvMonitor.tile.physicalBadgeTitle');
  kindBadge.style.display = 'none';
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
  // 凍結バッジ。device.frozen(一様フレームが2サイクル連続)の間だけ表示(renderMeta が切替)。
  // **タイルの絵だけでは分からない** —— 凍結時も最後のフレームが残るので、白/黒ベタでなければ
  // 「普通の画面」に見える。ヘッダの Frozen カウンタと同じ判定(ApiMonitorCommand)
  const frozenBadge = document.createElement('span');
  frozenBadge.className = 'badge badge-frozen';
  frozenBadge.textContent = t('wvMonitor.tile.frozen');
  // バッジも絵文字1文字なので説明はホバーが唯一の手段。ネイティブ title(約1秒)ではなく
  // タイルの他の説明と同じ自前ツールチップ(0.2秒)に揃える
  setHoverTip(frozenBadge, t('wvMonitor.tile.frozenTitle'));
  // 未登録(マシンプロファイル未記載の合成デバイス)バッジ。device.state に関わらず常時対象なので
  // kindBadge と同じくヘッダーに置く(renderMode==='cpu' バッジは state==='connected' 限定だが
  // 表示切替の実装パターン=専用要素+専用 render 関数+style.display 切替は揃える)。
  const unregisteredBadge = document.createElement('span');
  unregisteredBadge.className = 'badge badge-unregistered';
  unregisteredBadge.textContent = t('wvMonitor.tile.unregistered');
  unregisteredBadge.title = t('wvMonitor.tile.unregisteredTitle');
  unregisteredBadge.style.display = 'none';
  // 実機バッジはデバイス名の左(ピッカー・一覧・編集フォームと同じ並び)
  header.append(kindBadge, name, unregisteredBadge);
  // ホスト名は**名前の下の段**(2026-08-17 指示)。段の有無はグリッド単位で揃える(上記
  // machineRowReserved)ので、手元のデバイスでも段自体は作る(中身が空になるだけ)
  const machineRow = document.createElement('div');
  machineRow.className = 'tile-machine-row';
  machineRow.appendChild(remoteBadge);

  const frameWrap = document.createElement('div');
  frameWrap.className = 'frame-wrap';
  const img = document.createElement('img');
  // 既定のままだと画像を掴んだ時点でブラウザのドラッグが始まり、範囲選択のドラッグが途切れる
  img.draggable = false;
  // アスペクト比はデコードできた画像の実寸だけから決める(下の setTileAspect のコメント参照)。
  img.addEventListener('load', () => {
    if (img.naturalWidth > 0 && img.naturalHeight > 0) {
      setTileAspect(tiles.get(device.id), img.naturalWidth / img.naturalHeight);
    }
  });
  // デコードできないフレーム(ストリームの境界ズレ等)は黒い矩形を残さずプレースホルダへ倒す。
  // 残すとブリッジ死亡後もタイルに黒画面が居座り、状態を誤認させる
  img.addEventListener('error', () => {
    const entryNow = tiles.get(device.id);
    if (!entryNow || !entryNow.frameSrc) { return; }
    entryNow.frameSrc = null;
    renderFrame(entryNow);
  });
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
  footer.append(runningBadge, recordingBadge, frozenBadge, queuedBadge, stateBadge, error, renderBadge);

  tile.append(header, machineRow, frameWrap, footer);
  grid.appendChild(tile);

  const entry = {
    device,
    tile,
    nameEl: name,
    // 拡大表示(出力ペイン)のタグ段はこの2つの複製で作る(renderMirrorHeader)
    headerEl: header,
    machineRowEl: machineRow,
    // そのデバイスの直列キュー上の状態({ op: 'up'|'down', status: 'queued'|'running' })。
    // キューに入っていなければ undefined。
    opBusy: undefined,
    stateBadgeEl: stateBadge,
    runningBadgeEl: runningBadge,
    queuedBadgeEl: queuedBadge,
    recordingBadgeEl: recordingBadge,
    frozenBadgeEl: frozenBadge,
    renderBadgeEl: renderBadge,
    kindBadgeEl: kindBadge,
    remoteBadgeEl: remoteBadge,
    unregisteredBadgeEl: unregisteredBadge,
    frameWrapEl: frameWrap,
    imgEl: img,
    placeholderEl: placeholder,
    errorEl: error,
    frameSrc: null,
    // 直近 setTileAspect した値(文字列)。同値の再書き込みを避けるためだけに持つ。
    tileAspect: undefined,
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
  // ブリッジ不在の実機は未起動と同じ扱い(bridgeNotRunning のコメント参照)。フレームも出さない:
  // 残っているのはブリッジが死ぬ前の古い1枚で、生きた画面と見分けがつかない
  // unknown(誰も観測していない)もフレームは来ないのでプレースホルダ側で扱う
  const offline = entry.device.state === 'offline' || entry.device.state === 'unknown'
    || bridgeNotRunning(entry.device);
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
    // **リモートのデバイスは状態を観測できない**(モニターの判定は simctl/adb = 手元にしか効かない)。
    // 起動していても offline のままなので「未起動」と言ってはいけない —— 操作中(起動中/待機中)の
    // 表示は本物の進捗なのでそのまま出し、静止状態だけ「状態を取得できない」に置き換える
    const unobservableRemote = entry.device.state === 'unknown'
      && !shuttingDown && !waitingUp && !upRunning;
    if (unobservableRemote) {
      icon.className = 'placeholder-icon remote';
      icon.innerHTML = '';
    }
    // 配信を諦めた台は「接続中」と言わない(待っても来ない)
    const streamUnavailable = !!entry.streamUnavailable && !shuttingDown && !waitingUp && !upRunning
      && !offline;
    if (streamUnavailable) {
      icon.className = 'placeholder-icon remote';  // アイコンは出さない(display:none)
      icon.innerHTML = '';
    }
    // **タイルの文言は短く**(幅は 60px 程度しかなく、長い文は1文字ずつ折り返して潰れる。
    // 2026-08-17 に実際に読めない表示になった)。理由と対処はツールチップと OUTPUT へ
    entry.placeholderEl.title = streamUnavailable
      ? t('wvMonitor.tile.streamUnavailableTip')
      : unobservableRemote ? t('wvMonitor.tile.stateUnknownTip') : t('wvMonitor.tile.title');
    labelSpan.textContent = streamUnavailable
      ? t('wvMonitor.tile.streamUnavailable')
      : unobservableRemote
      ? (entry.device.machine
        ? t('wvMonitor.tile.remoteUnobservable', { machine: entry.device.machine })
        : t('wvMonitor.tile.stateUnknown'))
      : shuttingDown
        ? t('wvMonitor.tile.shuttingDown')
        : waitingUp
          ? t('wvMonitor.tile.waiting')
          : offline
            ? (upRunning
              ? t('wvMonitor.deviceState.booting')
              // 繋がっている実機は「未起動」ではない —— 無いのはブリッジだけ
              : bridgeNotRunning(entry.device)
                ? t('wvMonitor.tile.bridgeNotRunning')
                : t('wvMonitor.deviceState.offline'))
            : t('wvMonitor.tile.connecting');
    entry.placeholderEl.append(icon, labelSpan);
    entry.frameWrapEl.appendChild(entry.placeholderEl);
  }
  renderMirror(entry);
}

// ---- 拡大表示(出力ペイン)----
// 「絵かプレースホルダか」はタイルの描画結果(frameWrapEl の中身)をそのまま写す。判定を
// 書き直すと renderFrame の分岐(未起動・終了中・観測不能・配信断念…)と食い違う。
function renderMirror(entry) {
  const mirror = deviceMirrors.get(entry.device.id);
  if (!mirror) {
    return;
  }
  renderMirrorHeader(entry, mirror);
  mirror.frameEl.textContent = '';
  if (entry.frameWrapEl.contains(entry.placeholderEl)) {
    mirror.frameEl.appendChild(entry.placeholderEl.cloneNode(true));
    return;
  }
  if (entry.usingH264 && entry.canvasEl) {
    mirror.frameEl.appendChild(mirror.canvasEl);
    copyMirrorFrame(entry);
    return;
  }
  if (entry.frameSrc) {
    mirror.imgEl.src = entry.frameSrc;
    mirror.imgEl.alt = entry.device.name;
    mirror.frameEl.appendChild(mirror.imgEl);
  }
}

// 絵の上のタグ段。タイルのヘッダ(実機バッジ・デバイス名のピル・未登録バッジ)をそのまま複製する
// —— フリートと同じ見た目・同じ内容にするため(組み立て直すと renderMeta の切替と食い違う)。
// ホスト名の段(タイルと同じく名前の下)は**常に置く**。リモートの台にだけ段を足すと、
// その台だけ絵の上端が下がって手元と高さが揃わない(2026-08-24 のユーザー指摘)。
// 手元の台には**見えないダミーのバッジ**を入れて高さだけ合わせる(中身が空の段は高さ 0)。
function renderMirrorHeader(entry, mirror) {
  mirror.headerEl.textContent = '';
  mirror.headerEl.appendChild(entry.headerEl.cloneNode(true));
  const machineRow = entry.machineRowEl.cloneNode(true);
  const badge = machineRow.querySelector('.badge-remote');
  if (badge && entry.remoteBadgeEl.style.display === 'none') {
    badge.textContent = '\u00a0';
    badge.style.display = 'inline-block';
    badge.style.visibility = 'hidden';
  }
  mirror.headerEl.appendChild(machineRow);
}

// h264 は1フレーム描画するたびに呼ぶ(タイルの canvas → 拡大表示の canvas への転写)。
// 転写元はデコード実寸の canvas なので、拡大表示でも解像度は落ちない。
function copyMirrorFrame(entry) {
  const mirror = deviceMirrors.get(entry.device.id);
  if (!mirror || !entry.usingH264 || !entry.canvasEl) {
    return;
  }
  const source = entry.canvasEl;
  if (!(source.width > 0) || !(source.height > 0)) {
    return;
  }
  if (mirror.canvasEl.width !== source.width || mirror.canvasEl.height !== source.height) {
    mirror.canvasEl.width = source.width;
    mirror.canvasEl.height = source.height;
  }
  // jsdom(テスト)には 2d コンテキストが無い
  const ctx = mirror.canvasEl.getContext('2d');
  if (!ctx) {
    return;
  }
  ctx.drawImage(source, 0, 0);
}

// laneLog.js から: 選択デバイスのレーンに拡大表示を付ける/外す。同じ wrapEl への再 attach は
// 要素を作り直さない(devices サイクルのたびに呼ばれるため)。
// 登録の寿命はレーンの寿命と同じ(タイルが消えた台は laneLog.js の removeLane が detach する)。
// ここで tiles の削除に合わせて外すと所有者が2つになる。
export function attachDeviceMirror(deviceId, wrapEl) {
  const entry = tiles.get(deviceId);
  if (!entry) {
    return;
  }
  let mirror = deviceMirrors.get(deviceId);
  if (!mirror || mirror.wrapEl !== wrapEl) {
    const imgEl = document.createElement('img');
    imgEl.className = 'lane-preview-media';
    imgEl.draggable = false;  // タイルの img と同じ(ネイティブの画像ドラッグを止める)
    const canvasEl = document.createElement('canvas');
    canvasEl.className = 'lane-preview-media';
    const headerEl = document.createElement('div');
    headerEl.className = 'lane-preview-header';
    const frameEl = document.createElement('div');
    frameEl.className = 'lane-preview-frame';
    wrapEl.textContent = '';
    wrapEl.append(headerEl, frameEl);
    mirror = { wrapEl, headerEl, frameEl, imgEl, canvasEl };
    deviceMirrors.set(deviceId, mirror);
  }
  renderMirror(entry);
}

export function detachDeviceMirror(deviceId) {
  const mirror = deviceMirrors.get(deviceId);
  if (!mirror) {
    return;
  }
  mirror.wrapEl.textContent = '';
  deviceMirrors.delete(deviceId);
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
  setHoverTip(entry.nameEl, entry.device.name + ' (' + entry.device.platform + ')');
  entry.recordingBadgeEl.style.display = entry.device.recording ? 'inline-block' : 'none';
  // 接続中のときだけ出す(未接続の機は「凍結」ではない。Swift 側も接続断で記憶を捨てる)
  entry.frozenBadgeEl.style.display =
    entry.device.frozen && entry.device.state === 'connected' ? 'inline-block' : 'none';
  // 実機は署名・接続の前提がシミュレータ/エミュレータと違うので取り違えないよう明示する
  entry.kindBadgeEl.style.display = entry.device.kind === 'physical' ? 'inline-block' : 'none';
  // リモートのデバイスはホスト名を出す(手元は出さない = 既存の見た目のまま)
  if (entry.device.machine) {
    entry.remoteBadgeEl.textContent = entry.device.machine;
    entry.remoteBadgeEl.style.display = 'inline-block';
  } else {
    entry.remoteBadgeEl.style.display = 'none';
  }
  // マシンプロファイル未記載の合成デバイス(「(起動中のデバイス)」フィルタでのみ現れる)。
  // 起動(up)と GPU 再起動が成立しないことをタイル上でも明示する(停止・ライブ操作は可)
  entry.unregisteredBadgeEl.style.display = entry.device.registered === false ? 'inline-block' : 'none';
  renderRenderBadge(entry);
  // 通常時は空(接続済みは画面表示自体が、接続待ちはプレースホルダの「接続中」が伝えるため
  // 冗長で出さない。ユーザー決定)。bridgeWatch の異常時だけ下で埋める。
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
  let footerTip = '';
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
    const override = bridgeWatchLabel(entry.bridgeWatchPhase, entry.device.kind === 'physical');
    if (override) {
      footerText = override.label;
      footerTip = override.tip;
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
  setHoverTip(entry.stateBadgeEl, footerTip);

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
  const device = deviceOpMenuEntry.device;
  // ブリッジ不在の実機は offline と同じ扱い(そのまま booted を渡すと「ブリッジを停止」が出て、
  // 止まっているものを止める操作しか選べなくなる)
  const item = deviceOpMenuItem(bridgeNotRunning(device) ? 'offline' : device.state,
                                deviceOpMenuEntry.opBusy, device.kind === 'physical');
  // 未登録(マシンプロファイル未記載)のシミュレータ/エミュレータは起動(up)が --name 前提のため
  // 成立しない。停止(down)だけ出す。
  // **実機は例外** —— 実機の up は「ブリッジを起動」であって端末の電源ではなく、udid で撃てる
  // (device-up --udid)。ここで隠すと、繋がっている実機がタイルに出るのに何も操作できない
  // (2026-07-25 に一度直した実害が、未登録デバイスを出すようになった時点で実機に再発していた)
  if (device.registered === false && item.op !== 'down' && device.kind !== 'physical') {
    deviceOpMenuItemBtn.style.display = 'none';
    return;
  }
  deviceOpMenuItemBtn.style.display = '';
  // ラベルはspanに書く(ボタン直のtextContent代入はアイコンSVGを消す)。data-opはCSSのアイコン切替も担う。
  deviceOpMenuItemLabel.textContent = item.label;
  deviceOpMenuItemBtn.disabled = item.disabled;
  deviceOpMenuItemBtn.dataset.op = item.op;
}

// 「開いているか」は entry では判定できない —— 空きエリアの右クリックでは entry が無いまま開く。
let deviceOpMenuOpen = false;

export function closeDeviceOpMenu() {
  if (!deviceOpMenuOpen) {
    return;
  }
  deviceOpMenuOpen = false;
  deviceOpMenuEntry = null;
  deviceOpMenu.classList.remove('visible');
}

// entry=null はグリッドの空きエリアでの右クリック(デバイスの項目は出さず、全体の項目だけ)。
function openDeviceOpMenu(entry, clientX, clientY) {
  deviceOpMenuEntry = entry;
  deviceOpMenuOpen = true;
  renderSelectionMenuItems();
  if (!entry) {
    deviceOpMenuItemBtn.style.display = 'none';
    deviceOpMenuLiveBtn.style.display = 'none';
    deviceOpMenuGpuBtn.style.display = 'none';
    deviceOpMenuSep.style.display = 'none';
    deviceOpMenu.classList.add('visible');
    clampMenuPosition(deviceOpMenu, clientX, clientY);
    return;
  }
  deviceOpMenuItemBtn.style.display = '';
  deviceOpMenuSep.style.display = '';
  renderDeviceOpMenuItem();
  // GPU再起動はマシンプロファイル前提(name 解決)のため未登録では出さない
  // (起動/停止項目は renderDeviceOpMenuItem 側、ライブ操作は下で個別に扱う)。
  const unregistered = entry.device.registered === false;
  // ライブ操作はブリッジ接続済み(state==='connected')でのみ機能する(liveTab.js の「接続されていません」
  // 警告と対)。未登録でも connected なら udid/serial 直指定でブリッジ自動起動が効く
  // (ApiListDevicesCommand の registered:false・ApiLiveCommand --udid 自動起動)ため、
  // registered と同条件(state のみ)で出す。
  deviceOpMenuLiveBtn.style.display = entry.device.state === 'connected' ? '' : 'none';
  // 「GPUで再起動」は CPU 描画フォールバック中(CPU バッジ)の Android タイルでのみ意味を持つ。
  // 起動/停止のライフサイクル操作中(opBusy)は再起動を積んでも enqueueRestart が無視するため出さない。
  deviceOpMenuGpuBtn.style.display =
    !unregistered && !entry.opBusy && entry.device.platform === 'android' && entry.device.renderMode === 'cpu'
      ? '' : 'none';
  deviceOpMenu.classList.add('visible');
  clampMenuPosition(deviceOpMenu, clientX, clientY);
}

// 「すべて選択」「すべて解除」は今の状態で押せるかが決まる(結果が変わらないなら押させない)。
function renderSelectionMenuItems() {
  deviceOpMenuSelectAllBtn.disabled = tiles.size === 0 || selectedDeviceIds.size === tiles.size;
  deviceOpMenuDeselectAllBtn.disabled = selectedDeviceIds.size === 0;
}

deviceOpMenuSelectAllBtn.addEventListener('click', (event) => {
  event.stopPropagation();
  if (deviceOpMenuSelectAllBtn.disabled) {
    return;
  }
  for (const id of tiles.keys()) {
    selectedDeviceIds.add(id);
  }
  updateSelectionUi();
  closeDeviceOpMenu();
});

deviceOpMenuDeselectAllBtn.addEventListener('click', (event) => {
  event.stopPropagation();
  if (deviceOpMenuDeselectAllBtn.disabled) {
    return;
  }
  selectedDeviceIds.clear();
  updateSelectionUi();
  closeDeviceOpMenu();
});

deviceOpMenuItemBtn.addEventListener('click', (event) => {
  event.stopPropagation();
  if (!deviceOpMenuEntry || deviceOpMenuItemBtn.disabled) {
    return;
  }
  const device = deviceOpMenuEntry.device;
  // **machine も載せる** —— 同名の台が別の機械にも居るのは通常で、名前だけだと
  // 手元のマシンプロファイルの同名エントリを引いて**別の機械の設定でこの Mac に1台作る**
  // (machine は api monitor のワイヤ名。値はマシン名 = エイリアス)
  const message = {
    type: 'deviceOp', name: device.name, op: deviceOpMenuItemBtn.dataset.op,
    machine: device.machine,
  };
  // 未登録(registered:false)はマシンプロファイルに無いため --name で引けない。udid(iOS)/
  // serial(Android)を載せ、拡張側(monitorDeviceOps.ts)が device-down --udid/--serial の
  // 直指定モードへ振り分ける(契約: monitorWebviewMessages.ts の "deviceOp")。
  if (device.registered === false) {
    message.registered = false;
    if (device.platform === 'ios' && device.udid) {
      message.udid = device.udid;
    } else if (device.platform === 'android' && device.serial) {
      message.serial = device.serial;
    }
  }
  vscode.postMessage(message);
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

// 応答(deviceOpBusy 等)は (name, machine) で引く。**machine 省略は「手元」の意味**であって
// 「どれでもよい」ではない —— 同名のデバイスが別の機械にも居るのは通常なので、省略を
// ワイルドカードにすると**先頭のタイル(= 手元)を書き換える**。実際
// 「M2Ultra の台を停止」で手元のタイルに「シャットダウン中」が出た。
// 手元だけの構成では machine が全て undefined なので挙動は変わらない。
// bridgeWatch/healthWatch/wipeStatus は手元のデバイスにしか出さないので machine を持たない
function findTileByName(name, machine) {
  for (const entry of tiles.values()) {
    if (entry.device.name !== name) {
      continue;
    }
    if ((entry.device.machine ?? undefined) !== (machine ?? undefined)) {
      continue;
    }
    return entry;
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
  const previousTileCount = tiles.size;
  // リモートのデバイスが混ざる構成でだけホスト名の段を出す(全タイルで高さを揃えるため
  // グリッド単位のクラスで制御する。判定は machine の有無)
  const nextMachineRow = devices.some((device) => !!device.machine);
  if (nextMachineRow !== machineRowReserved) {
    machineRowReserved = nextMachineRow;
    grid.classList.toggle('with-machine-row', nextMachineRow);
    notifyTileLayoutChanged('deviceCount');
  }
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
  // devices は数秒ごとのポーリングで届くため、台数が変わったときだけ通知する
  // (毎サイクル通知すると auto-fit の再計測が無駄に走る)。
  if (tiles.size !== previousTileCount) {
    notifyTileLayoutChanged('deviceCount');
  }
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
  // message.width/height はここでは使わない(アスペクト比は img の load で実寸から決める)。
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
// 契約: { type:'streamUnavailable', device, unavailable }。配信を諦めた台は「接続中」を出さない
// —— プロファイル未選択(未登録デバイス)の iOS はブリッジが無くポーリングのフレームも来ないので、
// 黙っていると永久に「接続中」に見える(2026-08-17 の実害)
export function applyStreamUnavailable(message) {
  const entry = tiles.get(message.device);
  if (!entry) {
    return;
  }
  entry.streamUnavailable = !!message.unavailable;
  renderFrame(entry);
}

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
      onFirstFrame: () => {
        entry.usingH264 = true;
        renderMeta(entry);
        renderFrame(entry);
      },
      // デコード後の実寸(VideoFrame)なのでそのまま採用してよい
      onDimensions: (dims) => {
        setTileAspect(entry, dims.width / dims.height);
      },
      onFrameRendered: () => {
        copyMirrorFrame(entry);
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
  const entry = findTileByName(message.name, message.machine);
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

// 契約: { type: 'deviceDownFinished', name }(monitorWebviewMessages.ts / monitorDeviceOps.ts の api devices-down)。
// 一括 down で1台の停止が完了した通知。down 中はモニターが pause で state 更新を出さないため、この
// タイルだけ offline を先行反映して「未起動」へ倒す(次の devices 反映=resume 後に本物の state で
// 上書きされる)。opBusy も解除する。offline を立てることで renderFrame が凍結フレームを出さない
// (applyDeviceOpBusy の「down 完了直後は再描画しない」フリッカ回避と同じ問題をここで解消する)。
export function applyDeviceDownFinished(message) {
  const entry = findTileByName(message.name, message.machine);
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

// 一括ボタンの状態は setBusy(キュー稼働)と applyProfileInfo(表示フィルタ)の2経路から
// 変わるため、双方の入力をここに保持して refreshBulkButtons() で一括評価する。
let bulkBusy = false;
let bulkBusyOp = null;
let runningFilterActive = false;

function refreshBulkButtons() {
  // bulk up 実行中は「全て起動」ボタンを中断ボタンに転用する(クリック時の分岐は main.js。
  // 受け手: monitorPanel.ts devicesUpCancel → MonitorDeviceOps.cancelBulkUp)。
  const upCancelMode = bulkBusy && bulkBusyOp === 'up';
  // 「起動中のデバイス」表示中の一括起動は禁止(一覧に出ていない未起動デバイスまで起動するため)。
  // 中断ボタンとして使っている間は無効化しない(進行中のジョブを止める導線を残す)。
  const blockedByFilter = runningFilterActive && !upCancelMode;
  btnUp.disabled = (bulkBusy && !upCancelMode) || blockedByFilter;
  btnUp.textContent = upCancelMode ? t('wvMonitor.bulk.cancelStart') : t('wvMonitor.bulk.startAll');
  btnUp.title = blockedByFilter ? t('wvMonitor.bulk.startAllDisabledRunning') : '';
  btnDown.disabled = bulkBusy;
}

export function setBusy(busy, bulkOp) {
  bulkBusy = busy;
  bulkBusyOp = bulkOp;
  refreshBulkButtons();
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
const PROFILE_RUNNING_LABEL = t('wvMonitor.profile.running');
// src/monitorDeviceModel.ts の RUNNING_DEVICES_PROFILE_VALUE の複製(webview は CSP で import 不可)。
// 変更時は両方揃える。実行プロファイルではなく表示フィルタで、送信先の分解は
// monitorProfilesController.selectProfile が行う。
const PROFILE_RUNNING_VALUE = '@running';

// 現在値が profiles に無ければ(手書き設定等)unknownOption で補い選択状態を保つ。
export function applyProfileInfo(message) {
  const profiles = Array.isArray(message.profiles) ? message.profiles : [];
  const current = typeof message.current === 'string' ? message.current : '';
  // filter==='running' は profile 未選択(current==='')と組で来る。選択表示は予約値側にする。
  runningFilterActive = message.filter === 'running';
  profileSelect.textContent = '';

  const noneOption = document.createElement('option');
  noneOption.value = '';
  noneOption.textContent = PROFILE_NONE_LABEL;
  profileSelect.appendChild(noneOption);

  const runningOption = document.createElement('option');
  runningOption.value = PROFILE_RUNNING_VALUE;
  runningOption.textContent = PROFILE_RUNNING_LABEL;
  profileSelect.appendChild(runningOption);

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
  profileSelect.value = runningFilterActive ? PROFILE_RUNNING_VALUE : current;
  profileSelect.disabled = false;
  refreshBulkButtons();
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

// クリックの当たり(ユーザー決定)。タイルごとに張らず委譲するのは判定を1箇所に持つため。
//  - 「画像の高さの帯 × タイルの幅」= そのデバイスの選択トグル
//    (画像の左右の余白を押しても押したことにする)
//  - タイルの中でその帯の外(見出し・ホスト名の段・脚、およびその左右)= **何もしない**
//    (押し損ねで選択を全部失わないため)
//  - タイルの外(タイルとタイルの間・右端の余り)でも、**画像の高さに収まっていれば何もしない**
//    —— タイルの隙間は 8px しかなく、狙って押すものではない
//  - 解除は「画像の高さの外」を押したときだけ(グリッドの上下の余白・タイルの見出しや脚の高さ)
//
// **決めるのは pointerup で、click は保険**。詰まっている間の押下→離上では click が
// そもそも来ないことがある(押下と離上で当たり先が変わると合成されない)ので、click を待つと
// 選択も解除も落ちる。pointerup で処理したぶんは pointerHandledClick で後続の click を1回捨てる。
grid.addEventListener('click', (event) => {
  if (pointerHandledClick) {
    pointerHandledClick = false;
    return;
  }
  applyTileClickAt(event.clientX, event.clientY);
});

// クリックの高さがどれかのデバイスの画像の高さに収まっているか(タイルの外で使う)。
// 画像の高さはグリッド共通(--tile-image-h)だが、1台ずつ見て一致を取る。
function deviceBandContainsY(y) {
  for (const entry of tiles.values()) {
    const rect = entry.frameWrapEl.getBoundingClientRect();
    if (rect.height > 0 && y >= rect.top && y <= rect.top + rect.height) {
      return true;
    }
  }
  return false;
}

// 当たり矩形: 横はタイル幅いっぱい・縦は画像の高さだけ。範囲選択(marqueeSelect)も同じものを使う。
function deviceHitRect(entry) {
  const tileRect = entry.tile.getBoundingClientRect();
  const frameRect = entry.frameWrapEl.getBoundingClientRect();
  return { left: tileRect.left, width: tileRect.width, top: frameRect.top, height: frameRect.height };
}

// { tile: タイルの中か, entry: 当たり矩形の中ならそのタイル }。2つに分けるのは、タイルの中の
// 帯の外(何もしない)とタイルの外(全解除)を区別するため。
//
// **判定は座標だけで行う(event.target を見ない)**。フリートは配信の描画と同じ main thread に
// 載っており(実測 2026-08-28: 配信ヘルパー 22 本 × 12fps)、詰まっている間に押下と離上をまたいで
// タイルが描き直されると、`event.target.closest('.tile')` は入れ替わった DOM を指して当たりを
// 落とす —— 選択も解除も黙って効かない(2026-08-28 の報告)。タイルは重ならないので、
// 座標で引くほうが DOM の入れ替わりに影響されない。
function tileHitAtPoint(x, y) {
  const point = { x, y };
  for (const entry of tiles.values()) {
    const rect = entry.tile.getBoundingClientRect();
    const tileBox = { left: rect.left, top: rect.top, width: rect.width, height: rect.height };
    if (!rectContains(tileBox, point)) {
      continue;
    }
    return { tile: true, entry: rectContains(deviceHitRect(entry), point) ? entry : null };
  }
  return { tile: false, entry: null };
}

// クリック1回ぶんの判定(当たりの規則は grid の click リスナのコメント)。
// pointerup と click の**どちらから来ても同じ**ものを通す = 規則を2つ持たない。
function applyTileClickAt(x, y) {
  const hit = tileHitAtPoint(x, y);
  if (hit.tile) {
    if (hit.entry) {
      toggleDeviceSelection(hit.entry.device.id);
    }
    return;
  }
  if (deviceBandContainsY(y)) {
    return;
  }
  if (selectedDeviceIds.size > 0) {
    selectedDeviceIds.clear();
    updateSelectionUi();
  }
}

// タイルの外(空きエリア)の右クリック。stopPropagation しないと、下の document の
// contextmenu リスナが開いた直後に閉じる(タイル側と同じ理由)。
grid.addEventListener('contextmenu', (event) => {
  event.preventDefault();
  event.stopPropagation();
  openDeviceOpMenu(null, event.clientX, event.clientY);
});

// ---- 範囲選択(左ドラッグの矩形。中ボタンの掴んで横スクロールとは別) ----
// しきい値を超えるまでは何も出さない = 動かさなければ従来どおりタイルのクリック(選択トグル)。
// 超えたらその時点から矩形を出し、**重なったタイルだけの選択に置き換える**(Ctrl/Cmd を
// 押している間だけ前の選択を残して足す。空振りのドラッグは全解除)。
let marqueePointerId = null;
let marqueeOrigin = null;
let marqueeActive = false;
// ドラッグを始めた時点の選択(Ctrl/Cmd を押しながらのときはこれを残して足す)。
let marqueeBaseIds = [];
// ドラッグの終わりに来る click を1回だけ捨てるための旗(下の capture リスナが読む)。
let marqueeSuppressClick = false;
// pointerup で選択を処理済み = 後続の click を1回だけ捨てる(二重トグル防止)。
// **pointerdown で必ず倒す** —— click が来ないまま残ると次の1回を飲み込む(marqueeSuppressClick
// が 2026-08-24 に踏んだのと同じ穴)。
let pointerHandledClick = false;

// additive は pointermove ごとに見る(ドラッグ中に押した・離したがそのまま効く)。
function marqueeSelect(rect, additive) {
  // 重なりを見るのはクリックと同じ当たり矩形(画像の高さの帯。見出し・脚をかすめても選ばない)
  const items = [...tiles].map(([id, entry]) => ({ id, rect: deviceHitRect(entry) }));
  const hit = idsInMarquee(rect, items);
  // 消えたデバイスの id は捨てる(ドラッグ中に devices サイクルで居なくなることがある)。
  const next = mergeMarqueeSelection(marqueeBaseIds, hit, additive).filter((id) => tiles.has(id));
  // 同じ集合なら何もしない: ドラッグ中は毎フレーム来るので、変わっていないのに
  // 選択を作り直すと拡大表示の付け直しと段組みの再計算を無駄に払う。
  if (next.length === selectedDeviceIds.size && next.every((id) => selectedDeviceIds.has(id))) {
    return;
  }
  selectedDeviceIds.clear();
  for (const id of next) {
    selectedDeviceIds.add(id);
  }
  updateSelectionUi();
}

function renderMarquee(rect) {
  const paneRect = tilePane.getBoundingClientRect();
  tileMarquee.style.left = (rect.left - paneRect.left) + 'px';
  tileMarquee.style.top = (rect.top - paneRect.top) + 'px';
  tileMarquee.style.width = rect.width + 'px';
  tileMarquee.style.height = rect.height + 'px';
}

function endMarquee() {
  marqueeOrigin = null;
  marqueePointerId = null;
  if (!marqueeActive) {
    return;
  }
  marqueeActive = false;
  marqueeSuppressClick = true;
  tileMarquee.style.display = 'none';
  grid.classList.remove('marquee-dragging');
}

grid.addEventListener('pointerdown', (event) => {
  // 前のドラッグの取り残し。**その click は必ずこの pointerdown より前に来る**ので、ここで
  // 落としてよい。落とさないと、グリッドの外(ペイン・セパレーター等)で離したドラッグの
  // click は grid に来ない = 旗が立ったまま残り、**次の普通のクリックを1回飲み込む**
  // (範囲選択の直後に未選択のデバイスを押しても選ばれず、2回目で選ばれる。実害 2026-08-24)。
  marqueeSuppressClick = false;
  pointerHandledClick = false;
  if (event.button !== 0) {
    return;
  }
  marqueePointerId = event.pointerId;
  marqueeOrigin = { x: event.clientX, y: event.clientY };
  marqueeBaseIds = [...selectedDeviceIds];
});
grid.addEventListener('pointermove', (event) => {
  if (marqueePointerId !== event.pointerId || !marqueeOrigin) {
    return;
  }
  const point = { x: event.clientX, y: event.clientY };
  if (!marqueeActive) {
    if (!isDragDistance(point.x - marqueeOrigin.x, point.y - marqueeOrigin.y)) {
      return;
    }
    marqueeActive = true;
    // 捕捉はドラッグと分かってから(pointerdown で捕らえると、ただのクリックの当たり先が
    // タイルから grid へ移ってしまう)。掴んだ時点で選択中の文字列は捨てる。
    grid.setPointerCapture(event.pointerId);
    grid.classList.add('marquee-dragging');
    tileMarquee.style.display = 'block';
    const selection = window.getSelection();
    if (selection) {
      selection.removeAllRanges();
    }
  }
  const rect = marqueeRect(marqueeOrigin, point);
  renderMarquee(rect);
  marqueeSelect(rect, event.ctrlKey || event.metaKey);
});
grid.addEventListener('pointerup', (event) => {
  if (marqueePointerId !== event.pointerId) {
    return;
  }
  // endMarquee() が origin を捨てるので先に控える
  const origin = marqueeOrigin;
  const wasDrag = marqueeActive;
  if (marqueeActive) {
    grid.releasePointerCapture(event.pointerId);
  }
  endMarquee();
  // ドラッグでなければここが本番の判定。**当たりは押し始めの座標**で見る ——
  // 詰まっている間に指がぶれても、しきい値未満なら押した先が対象という体感どおりになる
  if (!wasDrag && origin) {
    pointerHandledClick = true;
    applyTileClickAt(origin.x, origin.y);
  }
});
grid.addEventListener('pointercancel', (event) => {
  if (marqueePointerId === event.pointerId) {
    endMarquee();
  }
});
// ドラッグ直後の click を止める(capture = タイル側・grid 側どちらのハンドラより先)。
// 止めないと、掴んだタイルの選択トグルや空きエリアの全解除が範囲選択を上書きする。
grid.addEventListener('click', (event) => {
  if (!marqueeSuppressClick) {
    return;
  }
  marqueeSuppressClick = false;
  event.stopPropagation();
  event.preventDefault();
}, true);

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
