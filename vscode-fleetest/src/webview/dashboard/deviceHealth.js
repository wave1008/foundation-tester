// deviceHealth.js
// 「デバイスの健全性」セクション(#section-devices、monitorHtml.ts の renderDashboardPanel() が
// 静的スケルトンを持つ)。1行 = 1台(machine + worker)。回数は api results の deviceHealth
// (renderDeviceHealth の引数)、今の状態とストレージは同じ webview 内のモニター
// (monitor/deviceTiles.js。monitorDevices()/onMonitorDevicesChanged() で読み取り専用に参照する
// —— 可変状態はあちらのモジュールに残す規律)。結合の鍵は machine + worker
// ("<platform>:<論理名>"。machine は含まない)。**モニターにしか居ない台(事象0)・
// 履歴にしか居ない台(今は居ない)も行に出す**。欠けている値は「–」(0 で埋めない)。
//
// worker 行は insights.js の deviceBias リンクから revealWorkerRow() で参照される
// (insight.worker は machine を持たないため、一致する行が複数機械にあれば最初の行へ飛ぶ)。
//
// モニターの台の name は、その台が選択中の実行プロファイルに載っていない(registered:false)
// ときだけ実体(iOS は Simulator 名・Android は AVD 名)になり、結果の記録の worker が使う
// プロファイルの name と食い違う(実測)。resolveDeviceName() が
// 'deviceCatalog'(monitorDashboardController.ts 経由。applyDeviceCatalog)で登録済みの名前へ
// 揃えてから結合する。

import { t } from '../i18n.js';
import { vscode } from './vscodeApi.js';
import { clearChildren, td, tdNum } from './domUtil.js';
import { revealSection } from './domUtil.js';
import { formatLocalDateTime } from './format.js';
import { machineLabel } from './machineNames.js';
import { monitorDevices, onMonitorDevicesChanged } from '../monitor/deviceTiles.js';
import { LOCAL_MACHINE_LABEL, paintMachineBadge } from '../monitor/machineColors.js';
import { adoptTitleHoverTips, setHoverTip } from '../monitor/hoverTip.js';
import { formatBytesAuto } from '../../retentionModel';
import { compareMonitorDeviceOrder } from '../../monitorDeviceModel';

const COLLAPSE_LIMIT = 15;

const section = document.getElementById('section-devices');
const body = document.getElementById('table-device-health-body');
const toggleBtn = document.getElementById('devices-toggle-all');
const emptyEl = document.getElementById('devices-empty');
// 空のときの文言。**モニターの台の一覧と結果の履歴の両方が1回ずつ届くまでは「確認中」** —— 開いた直後は
// どちらもまだ無く(モニターは数秒〜10 秒・履歴は 15〜20 秒)、「記録がありません」と断定してしまう
const noRecordsText = emptyEl ? emptyEl.textContent : '';
let monitorDevicesSeen = false;
let healthRowsSeen = false;
const activeOnlyToggle = document.getElementById('chk-device-health-active-only');

// 静的 HTML(monitorHtml.ts)が title で書いた列見出し・ボタン等の説明も自前のツールチップへ移す
adoptTitleHoverTips('#section-devices [title]');

let expanded = false;
// api results から届いた最新の deviceHealth(renderDeviceHealth のたびに更新)。
// モニターの devices サイクルは api results の再取得より高頻度なので、結合し直すのはこちらから
// 控えを読み直す形にする(可変状態を持つのは deviceTiles.js だけ、という規律を保つ)。
let lastHealthRows = [];
let currentRows = [];
// 対象プロジェクトの実行プロファイル devices[] の和集合(monitorDashboardController.ts が
// refresh のたびに送る 'deviceCatalog'。applyDeviceCatalog で更新)。モニターの台の name を
// 結果の記録の worker(実行プロファイルの name)へ揃えるためだけに使う。
let deviceCatalog = [];

export function applyDeviceCatalog(devices) {
  deviceCatalog = Array.isArray(devices) ? devices : [];
  currentRows = combineRows(lastHealthRows);
  renderRows();
}

function keyOf(machine, worker) {
  return machine + '\u0000' + worker;
}

// モニターの台が実際にどの実行プロファイルの台なのかを解決する。**推測で名前を作らない**
// (AVD 名の変換規則を JS に写さない) —— 当たらなければ今の name のままにする。
//
// - registered(そのプロファイルに載っている台)は name がそのままプロファイルの name。
// - 未登録(registered===false。別プラットフォーム用のプロファイルを選んでいるときに合成される
//   台など)の iOS は udid で、Android は avd(モニターの name が AVD 名そのものになっている)で
//   deviceCatalog を引く。
function resolveDeviceName(device) {
  if (device.registered !== false) {
    return device.name;
  }
  if (device.platform === 'ios' && device.udid) {
    const match = deviceCatalog.find((entry) => entry.platform === 'ios' && entry.udid === device.udid);
    if (match) {
      return match.name;
    }
  }
  if (device.platform === 'android') {
    // プロファイルは手元を "local" と書き、モニターは手元の machine を省く。両側を同じ規則で揃える
    const deviceMachine = machineOfDevice(device);
    const match = deviceCatalog.find(
      (entry) => entry.platform === 'android' && entry.avd === device.name
        && (entry.machine || LOCAL_MACHINE_LABEL) === deviceMachine,
    );
    if (match) {
      return match.name;
    }
  }
  return device.name;
}

function workerOf(device) {
  return device.platform + ':' + resolveDeviceName(device);
}

function machineOfDevice(device) {
  return device.machine || LOCAL_MACHINE_LABEL;
}

// デバイスモニター(タイル)と同じ並び(compareMonitorDeviceOrder を共有)。モニターに居る台はモニターの
// name で比べる(resolveDeviceName で揃えた worker ではなく)—— タイルと同じ名前で比べないと、未登録の台で
// 順が割れる。履歴にしか居ない台は worker("<platform>:<name>")から取り出して比べる
function orderKey(row) {
  const machine = row.machine === LOCAL_MACHINE_LABEL ? undefined : row.machine;
  // 実機かはバッジと同じ判定(モニターの kind、居なければプロファイルの kind)
  const kind = isPhysical(row) ? 'physical' : 'virtual';
  if (row.monitor) {
    return { machine, platform: row.monitor.platform, kind, name: row.monitor.name };
  }
  const colon = row.worker.indexOf(':');
  return { machine, platform: row.worker.slice(0, colon), kind, name: row.worker.slice(colon + 1) };
}

function sortRows(rows) {
  return [...rows].sort((a, b) => compareMonitorDeviceOrder(orderKey(a), orderKey(b)));
}

/** deviceHealth(履歴)と monitorDevices()(今の状態)を machine+worker で結合する。 */
function combineRows(healthRows) {
  const byKey = new Map();
  const order = [];
  for (const health of healthRows) {
    const machine = machineLabel(health.host);
    const key = keyOf(machine, health.worker);
    if (!byKey.has(key)) {
      order.push(key);
      byKey.set(key, { machine, worker: health.worker, health, monitor: undefined });
    }
  }
  for (const device of monitorDevices()) {
    const machine = machineOfDevice(device);
    const worker = workerOf(device);
    const key = keyOf(machine, worker);
    const existing = byKey.get(key);
    if (existing) {
      existing.monitor = device;
    } else {
      order.push(key);
      byKey.set(key, { machine, worker, health: undefined, monitor: device });
    }
  }
  return sortRows(order.map((key) => byKey.get(key)));
}

// "<platform>:<machine>/<name>" 形式(FTCore.DeviceMachineGrouping.workerID と同じ規則)。
// 手元はそのまま worker 文字列("<platform>:<name>")を出す。
/** マシンはデバイスモニターのタイルと同じバッジ(.badge-remote)。色も同じ呼び方で塗る
 * (手元は機械名を渡さず既定色。色設定の変更は repaintMachineBadges が塗り直す) */
function machineCell(machine) {
  const cell = document.createElement('td');
  const badge = document.createElement('span');
  badge.className = 'badge badge-remote';
  badge.textContent = machine;
  paintMachineBadge(badge, machine === LOCAL_MACHINE_LABEL ? undefined : machine);
  cell.appendChild(badge);
  return cell;
}

/** 実機か。モニターに居る台はモニターの kind、居ない台(履歴だけ)は実行プロファイルの kind で決める。
 * どちらも言えなければ付けない(推測しない) */
function isPhysical(row) {
  if (row.monitor && row.monitor.kind) {
    return row.monitor.kind === 'physical';
  }
  const sep = row.worker.indexOf(':');
  const platform = row.worker.slice(0, sep);
  const name = row.worker.slice(sep + 1);
  const entry = deviceCatalog.find((e) => e.platform === platform && e.name === name
    && (e.machine || LOCAL_MACHINE_LABEL) === row.machine);
  return !!entry && entry.kind === 'physical';
}

/** 台の名前と OS のラベル(worker = "<platform>:<name>")。機械は別の列が持つ */
function deviceCell(row) {
  const cell = document.createElement('td');
  const sep = row.worker.indexOf(':');
  const platform = sep < 0 ? '' : row.worker.slice(0, sep);
  const name = sep < 0 ? row.worker : row.worker.slice(sep + 1);
  // バッジの順は OS 種別 → 実機(ユーザー決定)
  if (platform) {
    const label = document.createElement('span');
    // 色はデバイスモニターのタイルの名前ピルと同じクラス(.tile-name-ios / -android)
    label.className = 'badge dh-platform' + (platform === 'ios' || platform === 'android' ? ' tile-name-' + platform : '');
    label.textContent = platform === 'ios' ? 'iOS' : platform === 'android' ? 'Android' : platform;
    cell.appendChild(label);
  }
  if (isPhysical(row)) {
    // デバイスモニターのタイルと同じバッジ(クラス・文言とも)
    const physical = document.createElement('span');
    physical.className = 'badge badge-kind dh-kind';
    physical.textContent = t('wvMonitor.tile.physicalBadge');
    setHoverTip(physical, t('wvMonitor.tile.physicalBadgeTitle'));
    cell.appendChild(physical);
  }
  cell.appendChild(document.createTextNode(name));
  return cell;
}

const STATE_KEY = {
  connected: 'wvDashboard.deviceHealth.stateConnected',
  booted: 'wvDashboard.deviceHealth.stateBooted',
  offline: 'wvDashboard.deviceHealth.stateOffline',
  unknown: 'wvDashboard.deviceHealth.stateUnknown',
};

const HEALTH_KEY = {
  'wifi-disabled': 'wvDashboard.deviceHealth.healthWifiDisabled',
  'clock-skew': 'wvDashboard.deviceHealth.healthClockSkew',
  'blank-screen': 'wvDashboard.deviceHealth.healthBlankScreen',
};

function chip(className, text) {
  const span = document.createElement('span');
  span.className = className;
  span.textContent = text;
  return span;
}

/** 色は補助で、文字は必ず残す(色だけに意味を持たせない)。 */
function stateCell(monitor) {
  const cell = document.createElement('td');
  if (!monitor) {
    cell.textContent = '–';
    return cell;
  }
  cell.className = 'dh-state';
  const state = STATE_KEY[monitor.state] ? monitor.state : 'unknown';
  const dot = chip('dh-state-dot dh-state-' + state, '●');
  dot.setAttribute('aria-hidden', 'true');
  cell.append(dot, chip('dh-state-label', t(STATE_KEY[state])));
  if (monitor.inRun) {
    cell.appendChild(chip('badge dh-chip-running', t('wvDashboard.deviceHealth.inRun')));
  }
  if (monitor.frozen) {
    cell.appendChild(chip('dh-chip-frozen', '❄️ ' + t('wvDashboard.deviceHealth.frozen')));
  }
  // metal-errors はタイルと同じく出さない(全機に同時に出る背景現象。docs/design.md §12.4)。
  // 未知の種別は訳さず原文のまま出す(判定しない)
  for (const flag of Array.isArray(monitor.health) ? monitor.health : []) {
    if (flag === 'metal-errors') continue;
    cell.appendChild(chip('badge dh-chip-health', '⚠ ' + (HEALTH_KEY[flag] ? t(HEALTH_KEY[flag]) : flag)));
  }
  return cell;
}

function storageCellText(monitor) {
  if (!monitor || !monitor.storage) {
    return '–';
  }
  // 使用量だけを出す(ユーザー決定。「使用」は列見出しが持つ)。空きは母数が OS で違う —— Android は
  // /data 領域の空き、iOS Simulator はホストのボリューム全体の空き —— ので、並べると同じ尺度に見えてしまう
  return formatBytesAuto(monitor.storage.usedBytes);
}

function storageCellTitle(monitor) {
  if (!monitor || !monitor.storage) {
    return '';
  }
  const measured = t('wvDashboard.deviceHealth.measuredAtTitle', { time: formatLocalDateTime(monitor.storage.measuredAt) });
  return monitor.storage.carriedOver
    ? measured + '\n' + t('wvDashboard.deviceHealth.storageCarriedOverTitle')
    : measured;
}

function storageCell(monitor) {
  const cell = withTitle(td(storageCellText(monitor)), storageCellTitle(monitor));
  if (monitor && monitor.storage && monitor.storage.carriedOver) {
    cell.classList.add('dh-storage-carried-over');
  }
  if (monitor && isStorageTarget(monitor) && isStoragePending(monitor)) {
    // 測定中は値を出さず「測定中」だけ(ユーザー決定)。前回の値と計測時刻は title に残る
    const mark = document.createElement('span');
    mark.className = 'dh-storage-measuring';
    mark.textContent = t('wvDashboard.deviceHealth.storageMeasuringCell');
    cell.replaceChildren(mark);
  }
  return cell;
}

// ---- 「ストレージ使用を更新」の進捗 --------------------------------------------------------------
// 押した時刻を要求 id にしてモニターへ送り、台ごとの storageRefreshId / storageMeasuring で数える
// (契約は Sources/fleetest/ApiMonitorEvents.swift)。**待ち時間の定数を置かない** —— 「自分の id 以上を
// 受け取った かつ 測定中でない」だけで終わりを決める。押し直すと新しい id で数え直す(モニターが要求を
// 受け取れなかったとき = 0 台のまま進まないときの逃げ道)。
let storageRequestId = null;
let storageFinishedAt = null;
// 押してから、モニターが要求を受け取った(いずれかの台が id 以上を返した)と分かるまで true。
// **測定中は押せない**(ユーザー決定)= この間 と いずれかの台が storageMeasuring の間はボタンを止める。
// 要求が失われた(モニターの起動し直し)ときは storageProgressReset で解く
let awaitingStorageAck = false;

/** モニターを起動し直した(dashboardTab.js の storageProgressReset)。前のモニターへの要求は届かない */
export function resetStorageProgress() {
  storageRequestId = null;
  storageFinishedAt = null;
  awaitingStorageAck = false;
  renderStorageProgress();
  lastMonitorSignature = null;
  currentRows = combineRows(lastHealthRows);
  renderRows();
}

/** モニターが測る台と同じ(DeviceStorageSampler の候補: 動いている仮想デバイス) */
function isStorageTarget(device) {
  return (device.state === 'connected' || device.state === 'booted') && device.kind !== 'physical';
}

function isStoragePending(device) {
  return storageRequestId !== null
    && ((device.storageRefreshId ?? 0) < storageRequestId || device.storageMeasuring === true);
}

function latestMeasuredAt(devices) {
  let latest = null;
  for (const device of devices) {
    const iso = device.storage && device.storage.measuredAt;
    const time = iso ? Date.parse(iso) : NaN;
    if (!Number.isNaN(time) && (latest === null || time > Date.parse(latest))) {
      latest = iso;
    }
  }
  return latest;
}

function updateRefreshStorageButton(targets) {
  if (storageRequestId !== null && (targets.length === 0
      || targets.some((device) => (device.storageRefreshId ?? 0) >= storageRequestId))) {
    awaitingStorageAck = false;
  }
  const btn = document.getElementById('btn-device-health-refresh-storage');
  if (btn) {
    btn.disabled = awaitingStorageAck || targets.some((device) => device.storageMeasuring === true);
  }
}

function renderStorageProgress() {
  updateRefreshStorageButton(monitorDevices().filter(isStorageTarget));
  const el = document.getElementById('dh-storage-progress');
  if (!el) {
    return;
  }
  if (storageRequestId === null) {
    // 押す前(画面を開いたとき): 各台の値の計測時刻のうち最も新しいもの(前回値 = 前のモニターが測った値も含む)
    const latest = latestMeasuredAt(monitorDevices());
    el.textContent = latest ? t('wvDashboard.deviceHealth.storageDone', { time: formatLocalDateTime(latest) }) : '';
    return;
  }
  const targets = monitorDevices().filter(isStorageTarget);
  if (targets.length === 0) {
    el.textContent = t('wvDashboard.deviceHealth.storageNoTargets');
    return;
  }
  const pending = targets.filter(isStoragePending).length;
  if (pending > 0) {
    storageFinishedAt = null;
    el.textContent = t('wvDashboard.deviceHealth.storageProgress', { done: targets.length - pending, total: targets.length });
    return;
  }
  if (storageFinishedAt === null) {
    storageFinishedAt = new Date().toISOString();
  }
  el.textContent = t('wvDashboard.deviceHealth.storageDone', { time: formatLocalDateTime(storageFinishedAt) });
}

function countText(health, field) {
  return health ? String(health[field]) : '–';
}

// cause/recovery の内訳を title へ(未知のコードは翻訳せず生の文字列のまま出す ——
// t() は未知キーをキー文字列のまま返すので、それを検出して生コードへ倒す)。
// total = その欄の件数。内訳を持たない分(2026-09-27 より前の記録・写像できない理由)は
// 「原因の記録なし: n」として足す —— 足さないと、件数はあるのにマウスを載せても何も出なかった
function breakdownTitle(breakdown, namespace, total) {
  const entries = Object.entries(breakdown || {}).filter(([, count]) => count > 0);
  const lines = entries.map(([code, count]) => {
    const key = 'wvDashboard.deviceHealth.' + namespace + '.' + code;
    const label = t(key);
    return (label === key ? code : label) + ': ' + count;
  });
  const unrecorded = (total || 0) - entries.reduce((sum, [, count]) => sum + count, 0);
  if (unrecorded > 0) {
    // キーは組み立てずに書く(i18n.test.mjs が t() の字面でキーの実在を確かめる)
    const label = namespace === 'cause'
      ? t('wvDashboard.deviceHealth.cause.unrecorded')
      : t('wvDashboard.deviceHealth.recovery.unrecorded');
    lines.push(label + ': ' + unrecorded);
  }
  return lines.join('\n');
}

function preRunText(health) {
  if (!health) {
    return '–';
  }
  return health.preRunExcluded + ' / ' + health.preRunRepaired;
}

function lastEventText(health) {
  return health && health.lastEventAt ? formatLocalDateTime(health.lastEventAt) : '–';
}

// 説明はネイティブ title ではなく自前のツールチップ(hoverTip.js。0.2 秒で出る)で出す ——
// ネイティブは約 1 秒待つうえ遅延を指定できず、「マウスを載せても出ない」と見えた
function withTitle(cell, title) {
  if (title) {
    setHoverTip(cell, title);
  }
  return cell;
}

function rowElement(row) {
  const tr = document.createElement('tr');
  tr.dataset.worker = row.worker;
  tr.dataset.rowKey = keyOf(row.machine, row.worker);
  tr.append(
    machineCell(row.machine),
    deviceCell(row),
    stateCell(row.monitor),
    storageCell(row.monitor),
    withTitle(
      tdNum(countText(row.health, 'removed')),
      breakdownTitle(row.health && row.health.removedByCause, 'cause', row.health && row.health.removed),
    ),
    tdNum(countText(row.health, 'requeued')),
    withTitle(tdNum(preRunText(row.health)), t('wvDashboard.deviceHealth.preRunTitle')),
    withTitle(
      tdNum(countText(row.health, 'recovered')),
      breakdownTitle(row.health && row.health.recoveredByKind, 'recovery', row.health && row.health.recovered),
    ),
    tdNum(countText(row.health, 'appCrashes')),
    td(lastEventText(row.health)),
  );
  return tr;
}

/** 「アクティブなデバイスを表示」: モニターが未起動(offline)以外を出している台だけ。
 * モニターに居ない台(履歴だけ)も今は動いていないので隠す */
function visibleRows() {
  if (!activeOnlyToggle || !activeOnlyToggle.checked) {
    return currentRows;
  }
  return currentRows.filter((row) => row.monitor && row.monitor.state !== 'offline');
}

function renderRows() {
  clearChildren(body);
  const shown = visibleRows();
  const rows = expanded ? shown : shown.slice(0, COLLAPSE_LIMIT);
  let previousMachine = null;
  for (const row of rows) {
    const tr = rowElement(row);
    // 機械が変わる行に区切り(並びは sortRows が機械ごとにまとめている)
    if (previousMachine !== null && row.machine !== previousMachine) {
      tr.classList.add('dh-machine-start');
    }
    previousMachine = row.machine;
    body.appendChild(tr);
  }
  if (shown.length > COLLAPSE_LIMIT) {
    toggleBtn.style.display = 'inline-block';
    toggleBtn.textContent = expanded
      ? t('wvDashboard.devices.showLess')
      : t('wvDashboard.devices.showAll', { count: String(shown.length) });
  } else {
    toggleBtn.style.display = 'none';
  }
  emptyEl.textContent = monitorDevicesSeen && healthRowsSeen ? noRecordsText : t('wvDashboard.deviceHealth.checking');
  emptyEl.style.display = shown.length === 0 ? 'block' : 'none';
}

// ストレージは自動では測り直さない(ユーザー決定)。押したらモニターへ全台の測り直しを頼む
// (対向: src/monitorDashboardController.ts の refreshStorage → モニターの storageRefresh)
const refreshStorageBtn = document.getElementById('btn-device-health-refresh-storage');
if (refreshStorageBtn) {
  refreshStorageBtn.addEventListener('click', () => {
    if (refreshStorageBtn.disabled) {
      return;
    }
    storageRequestId = Date.now();
    storageFinishedAt = null;
    awaitingStorageAck = true;
    vscode.postMessage({ type: 'refreshStorage', id: storageRequestId });
    renderStorageProgress();
    // 各セルの「測定中」を次のモニター周期を待たずに出す
    lastMonitorSignature = null;
    currentRows = combineRows(lastHealthRows);
    renderRows();
  });
}

if (activeOnlyToggle) {
  activeOnlyToggle.addEventListener('change', () => renderRows());
}

toggleBtn.addEventListener('click', () => {
  expanded = !expanded;
  renderRows();
});

export function renderDeviceHealth(deviceHealthRows) {
  healthRowsSeen = true;
  expanded = false;
  lastHealthRows = deviceHealthRows || [];
  currentRows = combineRows(lastHealthRows);
  renderRows();
}

// モニターの devices サイクルは api results の再取得より高頻度に届く。控え(lastHealthRows)は
// そのままに結合だけ作り直して描き直す。
// モニターは 1〜2 秒ごとに全台を送ってくる。表に出る値が変わっていない周期は描き直さない
// (タブが隠れていても毎周期 DOM を組み直すことになり、モニターの webview の負荷になる)
let lastMonitorSignature = null;

function monitorSignature(rows) {
  return JSON.stringify(rows.map((row) => {
    const m = row.monitor;
    return [row.machine, row.worker, m ? [m.state, !!m.inRun, !!m.frozen, m.health || [],
      m.storage ? [m.storage.usedBytes, m.storage.carriedOver] : null, isStoragePending(m)] : null];
  }));
}

onMonitorDevicesChanged(() => {
  if (!monitorDevicesSeen) {
    // 最初の1回は表の中身が変わらなくても(0 台のまま)空の文言を「記録がありません」へ変えるため描き直す
    monitorDevicesSeen = true;
    lastMonitorSignature = null;
  }
  renderStorageProgress();
  const rows = combineRows(lastHealthRows);
  const signature = monitorSignature(rows);
  if (signature === lastMonitorSignature) {
    return;
  }
  lastMonitorSignature = signature;
  currentRows = rows;
  renderRows();
});

/** insights.js が deviceBias のリンク可否を判断するための存在チェック(副作用なし)。 */
export function hasWorkerRow(worker) {
  return currentRows.some((r) => r.worker === worker);
}

/** insights.js の deviceBias リンククリックから呼ぶ: 一致する最初の行までスクロールして
 * 一時的に強調する(insight.worker は machine を持たないため、複数機械に居れば最初の行)。
 * 折りたたまれていれば展開してから探す。一致しなければ何もしない。 */
export function revealWorkerRow(worker) {
  // 飛び先が「アクティブなデバイスを表示」で隠れているなら、絞り込みを外してから探す
  if (activeOnlyToggle && activeOnlyToggle.checked && !visibleRows().some((r) => r.worker === worker)) {
    activeOnlyToggle.checked = false;
    renderRows();
  }
  if (!expanded && visibleRows().findIndex((r) => r.worker === worker) >= COLLAPSE_LIMIT) {
    expanded = true;
    renderRows();
  }
  let target = null;
  for (const row of body.children) {
    if (row.dataset.worker === worker) {
      target = row;
      break;
    }
  }
  if (!target) {
    return;
  }
  revealSection(section);
  target.classList.add('row-highlight');
  setTimeout(() => target.classList.remove('row-highlight'), 1500);
}
