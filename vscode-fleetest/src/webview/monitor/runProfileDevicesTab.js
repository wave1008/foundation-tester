// runProfileDevicesTab.js
// 「プロファイル」タブの実行プロファイル節にある「デバイス」一覧(#run-profile-devices)を担う。
// projectDeviceCatalog(プロジェクトのデバイスカタログ。全実行プロファイルの devices[] の和集合)・
// 選択中デバイス・行の描画・右クリックメニューの書き込みはこのモジュールのみで
// 行う。runProfilesTab.js・modals.js からは projectDeviceCatalog/findCatalogEntry を読み取り専用で参照する。
//
// 1つの行が2つの役目を持つ: チェックボックスは「このデバイスが
// 選択中の実行プロファイルに含まれる(かつ enabled)か」、行本体のクリックは選択
// (右クリックメニューの除去・Wipe Data の対象)。チェックボックスのクリックは行選択に
// 波及させない(クリック領域を分ける)。

import { vscode } from './vscodeApi.js';
import { clampMenuPosition } from './menu.js';
import { t } from '../i18n.js';
import { paintMachineBadge } from './machineColors.js';

// **runProfilesTab.js からは import しない**(片方向依存を保つ。modals.js との相互 import も
// 同様に避ける —— 循環にすると esbuild のバンドル評価順が入れ替わり、modals.js 側の
// `btnDeviceAddExisting.addEventListener` が undefined を触って webview 全体が初期化に失敗する
// [実害あり]。選択中の実行プロファイルは renderDeviceRows/clearDeviceRows の呼び分けで
// 暗黙に表す(呼ぶのは常に runProfilesTab.js)。

// ---- プロジェクトのデバイスカタログ(profileInfo.devices) -----------------------------

// profileInfo 受信で更新(main.js が applyRunProfileInfo より先に呼ぶ)。
let projectDeviceCatalog = [];

export function applyProjectDeviceCatalog(message) {
  projectDeviceCatalog = Array.isArray(message.devices) ? message.devices : [];
}

/** 読み取り専用。modals.js の重複判定・devicePickMachine.js 等が使う。 */
export function catalogEntries() {
  return projectDeviceCatalog;
}

// デバイスの同一性。**一意なのは (platform, machine, name)**(machine 省略=手元)。
function refKey(ref) {
  return `${ref.platform}\t${ref.machine ?? ''}\t${ref.name}`;
}

export function findCatalogEntry(key) {
  const target = refKey(key);
  return projectDeviceCatalog.find((entry) => refKey(entry) === target) || null;
}

/** 選択中の実行プロファイルと同じ機械のデバイス名(重複判定・デバイス追加モーダルが使う)。
 * machine は undefined = 手元。 */
export function catalogNamesForMachine(machine) {
  return projectDeviceCatalog.filter((entry) => (entry.machine ?? undefined) === (machine ?? undefined))
    .map((entry) => entry.name);
}

/** installed-devices の素の os(接頭辞なし。例 "27.0"/"13")に、devices[].osVersion の形式
 * (Xcode/端末の表示どおりプラットフォーム接頭辞つき。例 "iOS 27.0"/"Android 13")を足す。
 * 既に接頭辞が付いていれば二重には付けない(modals.js の登録・この編集フォームのフォールバックが
 * 共有する)。 */
export function prefixedOsVersion(platform, os) {
  const prefix = platform === 'ios' ? 'iOS ' : 'Android ';
  return os.startsWith(prefix) ? os : prefix + os;
}

// ---- DOM 定数 ---------------------------------------------------------------------

export const btnDeviceAddExisting = document.getElementById('btn-run-profile-device-add-existing');
const deviceList = document.getElementById('run-profile-devices');
const deviceMenu = document.getElementById('run-profile-device-menu');
const deviceMenuItemBtn = document.getElementById('run-profile-device-menu-item');
const deviceMenuWipeBtn = document.getElementById('run-profile-device-menu-wipe');

// ---- 一覧の行(チェックボックス一覧との統合) ------------------------------------------

// 直近ロードした実行プロファイルの devices(フルボディ + enabled。runProfilesTab.js の
// renderRunProfileEditor が渡す)。
let profileDevices = [];
// 表示順の行モデル(key/platform/machine/name/enabled/wasInProfile/body)。
let rows = [];
// 直近描画した行要素(key -> { rowEl, checkbox }})。
let rowElements = new Map();
// 選択中デバイスの**キー**(複数選択、Finder/VSCode 標準セマンティクス)。
let selectedKeys = new Set();
let selectionAnchor = null;

/** runProfilesTab.js の renderRunProfileEditor / requestRunProfileLoad が、選択中プロファイルの
 * devices(フルボディ)で行一覧を作り直すときに呼ぶ。 */
export function renderDeviceRows(devices) {
  profileDevices = Array.isArray(devices) ? devices : [];
  const seen = new Set();
  const nextRows = [];
  for (const device of profileDevices) {
    const key = refKey(device);
    seen.add(key);
    nextRows.push({ key, platform: device.platform, machine: device.machine, name: device.name,
                    enabled: device.enabled, wasInProfile: true, body: device });
  }
  for (const entry of projectDeviceCatalog) {
    const key = refKey(entry);
    if (seen.has(key)) {
      continue;
    }
    nextRows.push({ key, platform: entry.platform, machine: entry.machine, name: entry.name,
                    enabled: false, wasInProfile: false, body: entry });
  }
  rows = nextRows;
  // 選択が一覧から消えていれば落とす。
  const keys = new Set(rows.map((r) => r.key));
  for (const key of selectedKeys) {
    if (!keys.has(key)) {
      selectedKeys.delete(key);
    }
  }
  if (selectionAnchor !== null && !keys.has(selectionAnchor)) {
    selectionAnchor = null;
  }
  renderRows();
  btnDeviceAddExisting.disabled = false;
}

/** クリアする(実行プロファイル未選択時。runProfilesTab.js の showRunProfilePlaceholder が呼ぶ)。 */
export function clearDeviceRows() {
  profileDevices = [];
  rows = [];
  selectedKeys = new Set();
  selectionAnchor = null;
  rowElements = new Map();
  deviceList.textContent = '';
  closeDeviceMenu();
  btnDeviceAddExisting.disabled = true;
}

/**
 * 現在チェックされている行から、runProfileSave の fields.devices を組み立てる
 * (runProfilesTab.js の collectRunProfileFields / runProfileValuesEqual が使う)。
 * **元々このプロファイルに居た行は、チェックを外していても enabled:false で残す**
 * (host 側との契約: 除去は別操作)。カタログにしか無かった行は、チェックしたときだけ追加する。
 */
export function currentDeviceEntries() {
  const result = [];
  for (const row of rows) {
    const el = rowElements.get(row.key);
    const checked = el ? el.checkbox.checked : row.wasInProfile && row.enabled;
    if (!row.wasInProfile && !checked) {
      continue;
    }
    result.push({ ...row.body, platform: row.platform, machine: row.machine, name: row.name, enabled: checked });
  }
  return result;
}

// monitorProfileForms.ts の machineDeviceDetail と同じ規則(片方だけ変えない)。osVersion には
// 既にプラットフォーム接頭辞が付いている(例 "iOS 27.0")ので、ここでは付け足さない。
// iOS はシミュレータ/実機とも osVersion があれば "<model> / <osVersion>"(model 欠落は
// osVersion のみ)、osVersion も無ければ "iOS"(udid は出さない)。Android は avd があれば
// "AVD: "+avd、実機は model があれば "<model> / <osVersion>"、無ければ serial、どちらも無ければ "Android"。
// 規則は monitorProfileForms.ts の machineDeviceDetail と同じ(片方だけ変えない)
function deviceDetail(entry) {
  if (entry.platform === 'android' && entry.avd) {
    return `AVD: ${entry.avd}`;
  }
  const id = entry.platform === 'ios' ? entry.udid : entry.serial;
  const parts = [entry.model, entry.osVersion, id].filter((part) => part);
  return parts.length > 0 ? parts.join(' / ') : (entry.platform === 'ios' ? 'iOS' : 'Android');
}

function toggleRowSelection(key, event) {
  const anchorValid = selectionAnchor !== null && rowElements.has(selectionAnchor);
  if (event.shiftKey && anchorValid) {
    const order = [...rowElements.keys()];
    const anchorIndex = order.indexOf(selectionAnchor);
    const clickedIndex = order.indexOf(key);
    const start = Math.min(anchorIndex, clickedIndex);
    const end = Math.max(anchorIndex, clickedIndex);
    selectedKeys = new Set(order.slice(start, end + 1));
  } else if (!event.shiftKey && (event.metaKey || event.ctrlKey)) {
    if (selectedKeys.has(key)) {
      selectedKeys.delete(key);
    } else {
      selectedKeys.add(key);
    }
    selectionAnchor = key;
  } else if (selectedKeys.size === 1 && selectedKeys.has(key)) {
    selectedKeys.clear();
    selectionAnchor = null;
  } else {
    selectedKeys = new Set([key]);
    selectionAnchor = key;
  }
  updateSelectionUi();
}

function updateSelectionUi() {
  for (const [key, el] of rowElements) {
    el.rowEl.classList.toggle('selected', selectedKeys.has(key));
  }
}

// 表示順: OS(iOS → Android)→ machine(手元が先頭、以降は昇順)→ 仮想デバイス → 実機。
// 同順位は rows の順(= ファイルの記述順)のまま。**並べ替えるのは表示だけ** ——
// rows の順は currentDeviceEntries が保存に使う(起動順の契約)ので変えない
const PLATFORM_ORDER = { ios: 0, android: 1 };
export function compareDeviceRowsForDisplay(a, b) {
  const pa = PLATFORM_ORDER[a.platform] ?? 2;
  const pb = PLATFORM_ORDER[b.platform] ?? 2;
  if (pa !== pb) {
    return pa - pb;
  }
  const ma = a.machine && a.machine !== 'local' ? a.machine : '';
  const mb = b.machine && b.machine !== 'local' ? b.machine : '';
  if (ma !== mb) {
    if (ma === '') return -1;
    if (mb === '') return 1;
    return ma < mb ? -1 : 1;
  }
  const ka = a.body?.kind === 'physical' ? 1 : 0;
  const kb = b.body?.kind === 'physical' ? 1 : 0;
  return ka - kb;
}

function renderRows() {
  deviceList.textContent = '';
  rowElements = new Map();
  if (rows.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'run-profile-device-empty';
    empty.textContent = t('wvMonitor2.runProfileDevice.empty');
    deviceList.appendChild(empty);
    updateSelectionUi();
    return;
  }
  for (const row of [...rows].sort(compareDeviceRowsForDisplay)) {
    const rowEl = document.createElement('div');
    rowEl.className = 'run-profile-device-row-item';
    const checkbox = document.createElement('input');
    checkbox.type = 'checkbox';
    checkbox.checked = row.wasInProfile && row.enabled;
    checkbox.addEventListener('click', (event) => event.stopPropagation());
    const nameLine = document.createElement('div');
    nameLine.className = 'run-profile-device-name-line';
    const name = document.createElement('span');
    name.className = 'tile-name tile-name-' + row.platform;
    name.textContent = row.name;
    nameLine.appendChild(name);
    if (row.machine) {
      const remote = document.createElement('span');
      remote.className = 'badge badge-remote';
      remote.textContent = row.machine;
      paintMachineBadge(remote, row.machine);
      nameLine.appendChild(remote);
    }
    if (row.body.kind === 'physical') {
      const badge = document.createElement('span');
      badge.className = 'badge badge-kind';
      badge.textContent = t('wvMonitor.tile.physicalBadge');
      nameLine.appendChild(badge);
    }
    // 1段表示: 名前段の末尾に detail を並べる(長ければ detail だけが省略される)
    const detail = document.createElement('span');
    detail.className = 'run-profile-device-detail';
    detail.textContent = deviceDetail(row.body);
    detail.title = detail.textContent;
    nameLine.appendChild(detail);
    const textCol = document.createElement('div');
    textCol.className = 'run-profile-device-text';
    textCol.append(nameLine);
    rowEl.append(checkbox, textCol);
    // 修飾キー付きの押下は行の選択操作なので、文字の範囲選択を始めさせない(click は消えない)
    rowEl.addEventListener('mousedown', (event) => {
      if (event.shiftKey || event.metaKey || event.ctrlKey) event.preventDefault();
    });
    rowEl.addEventListener('click', (event) => {
      // 文字をドラッグで選び終えた mouseup の click は行の選択を切り替えない(選んだ文字が消える)
      const selection = window.getSelection();
      if (selection && !selection.isCollapsed && rowEl.contains(selection.anchorNode)) return;
      toggleRowSelection(row.key, event);
    });
    rowEl.addEventListener('contextmenu', (event) => {
      event.preventDefault();
      event.stopPropagation();
      if (event.ctrlKey) {
        toggleRowSelection(row.key, event);
        return;
      }
      const targetRows =
        selectedKeys.size >= 2 && selectedKeys.has(row.key)
          ? rows.filter((r) => selectedKeys.has(r.key))
          : [row];
      openDeviceMenu(targetRows, event.clientX, event.clientY);
    });
    rowElements.set(row.key, { rowEl, checkbox });
    deviceList.appendChild(rowEl);
  }
  updateSelectionUi();
}

// ---- 行の右クリックメニュー(除去・Wipe Data) -----------------------------------------

let deviceMenuEntry = null; // { rows: [row, ...] }

export function closeDeviceMenu() {
  if (!deviceMenuEntry) {
    return;
  }
  deviceMenuEntry = null;
  deviceMenu.classList.remove('visible');
}

function wipeIdentifier(entry) {
  const value = entry.platform === 'ios' ? entry.udid : entry.avd;
  return typeof value === 'string' && value !== '' ? value : null;
}

function openDeviceMenu(targetRows, clientX, clientY) {
  deviceMenuEntry = { rows: targetRows };
  deviceMenuItemBtn.textContent =
    targetRows.length >= 2
      ? t('wvMonitor2.runProfileDevice.removeSelectedCount', { count: targetRows.length })
      : t('wvMonitor2.common.remove');
  const wipable = targetRows.every((r) => r.body.kind !== 'physical' && wipeIdentifier(r.body) !== null);
  deviceMenuWipeBtn.style.display = wipable ? '' : 'none';
  deviceMenuWipeBtn.textContent =
    targetRows.length >= 2
      ? t('wvMonitor2.runProfileDevice.wipeSelectedCount', { count: targetRows.length })
      : t('wvMonitor2.runProfileDevice.wipeData');
  deviceMenu.classList.add('visible');
  clampMenuPosition(deviceMenu, clientX, clientY);
}

deviceMenuItemBtn.addEventListener('click', (event) => {
  event.stopPropagation();
  if (!deviceMenuEntry) {
    return;
  }
  vscode.postMessage({
    type: 'runProfileDeviceRemove',
    devices: deviceMenuEntry.rows.map((r) => ({
      platform: r.platform, name: r.name, ...(r.machine ? { machine: r.machine } : {}),
    })),
  });
  closeDeviceMenu();
});

deviceMenuWipeBtn.addEventListener('click', (event) => {
  event.stopPropagation();
  if (!deviceMenuEntry) {
    return;
  }
  const devices = deviceMenuEntry.rows
    .map((r) => {
      const identifier = wipeIdentifier(r.body);
      return identifier === null ? null : {
        name: r.name, platform: r.platform, identifier, ...(r.machine ? { machine: r.machine } : {}),
      };
    })
    .filter((d) => d !== null);
  if (devices.length === 0) {
    return;
  }
  vscode.postMessage({ type: 'runProfileDeviceWipe', devices });
  closeDeviceMenu();
});

document.addEventListener('click', (event) => {
  if (deviceMenuEntry && !deviceMenu.contains(event.target)) {
    closeDeviceMenu();
  }
});
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    closeDeviceMenu();
  }
});
document.addEventListener('scroll', () => closeDeviceMenu(), true);
window.addEventListener('resize', () => closeDeviceMenu());
document.addEventListener('contextmenu', () => closeDeviceMenu());
