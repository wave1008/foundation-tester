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
import { clearChildren, td, tdNum } from './domUtil.js';
import { revealSection } from './domUtil.js';
import { formatLocalDateTime } from './format.js';
import { machineLabel } from './machineNames.js';
import { monitorDevices, onMonitorDevicesChanged } from '../monitor/deviceTiles.js';
import { LOCAL_MACHINE_LABEL, paintMachineBadge } from '../monitor/machineColors.js';
import { formatBytesAuto } from '../../retentionModel';

const COLLAPSE_LIMIT = 15;

const section = document.getElementById('section-devices');
const body = document.getElementById('table-device-health-body');
const toggleBtn = document.getElementById('devices-toggle-all');
const emptyEl = document.getElementById('devices-empty');
const activeOnlyToggle = document.getElementById('chk-device-health-active-only');

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

function sortRows(rows) {
  return [...rows].sort((a, b) => {
    if (a.machine !== b.machine) {
      if (a.machine === LOCAL_MACHINE_LABEL) return -1;
      if (b.machine === LOCAL_MACHINE_LABEL) return 1;
      return a.machine < b.machine ? -1 : 1;
    }
    return a.worker < b.worker ? -1 : a.worker > b.worker ? 1 : 0;
  });
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
  if (isPhysical(row)) {
    // デバイスモニターのタイルと同じバッジ(クラス・文言とも)
    const physical = document.createElement('span');
    physical.className = 'badge badge-kind dh-kind';
    physical.textContent = t('wvMonitor.tile.physicalBadge');
    physical.title = t('wvMonitor.tile.physicalBadgeTitle');
    cell.appendChild(physical);
  }
  if (platform) {
    const label = document.createElement('span');
    // 色はデバイスモニターのタイルの名前ピルと同じクラス(.tile-name-ios / -android)
    label.className = 'badge dh-platform' + (platform === 'ios' || platform === 'android' ? ' tile-name-' + platform : '');
    label.textContent = platform === 'ios' ? 'iOS' : platform === 'android' ? 'Android' : platform;
    cell.appendChild(label);
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
  // 使用量だけを出す(ユーザー決定)。空きは母数が OS で違う —— Android は /data 領域の空き、
  // iOS Simulator はホストのボリューム全体の空き —— ので、並べると同じ尺度に見えてしまう
  return t('wvDashboard.deviceHealth.storageUsedOnly', { used: formatBytesAuto(monitor.storage.usedBytes) });
}

function storageCellTitle(monitor) {
  if (!monitor || !monitor.storage) {
    return '';
  }
  return t('wvDashboard.deviceHealth.measuredAtTitle', { time: formatLocalDateTime(monitor.storage.measuredAt) });
}

function countText(health, field) {
  return health ? String(health[field]) : '–';
}

// cause/recovery の内訳を title へ(未知のコードは翻訳せず生の文字列のまま出す ——
// t() は未知キーをキー文字列のまま返すので、それを検出して生コードへ倒す)。
function breakdownTitle(breakdown, namespace) {
  if (!breakdown) {
    return '';
  }
  const entries = Object.entries(breakdown).filter(([, count]) => count > 0);
  if (entries.length === 0) {
    return '';
  }
  return entries
    .map(([code, count]) => {
      const key = 'wvDashboard.deviceHealth.' + namespace + '.' + code;
      const label = t(key);
      return (label === key ? code : label) + ': ' + count;
    })
    .join('\n');
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

function withTitle(cell, title) {
  if (title) {
    cell.title = title;
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
    withTitle(td(storageCellText(row.monitor)), storageCellTitle(row.monitor)),
    withTitle(
      tdNum(countText(row.health, 'removed')),
      breakdownTitle(row.health && row.health.removedByCause, 'cause'),
    ),
    tdNum(countText(row.health, 'requeued')),
    withTitle(td(preRunText(row.health)), t('wvDashboard.deviceHealth.preRunTitle')),
    withTitle(
      tdNum(countText(row.health, 'recovered')),
      breakdownTitle(row.health && row.health.recoveredByKind, 'recovery'),
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
  emptyEl.style.display = shown.length === 0 ? 'block' : 'none';
}

if (activeOnlyToggle) {
  activeOnlyToggle.addEventListener('change', () => renderRows());
}

toggleBtn.addEventListener('click', () => {
  expanded = !expanded;
  renderRows();
});

export function renderDeviceHealth(deviceHealthRows) {
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
      m.storage ? m.storage.usedBytes : null] : null];
  }));
}

onMonitorDevicesChanged(() => {
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
