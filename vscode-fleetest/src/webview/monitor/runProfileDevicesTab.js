// runProfileDevicesTab.js
// 「プロファイル」タブの実行プロファイル節にある「デバイス」一覧(#run-profile-devices)を担う。
// projectDeviceCatalog(プロジェクトのデバイスカタログ。全実行プロファイルの devices[] の和集合)・
// 選択中デバイス・行の描画・右ペイン編集フォーム・右クリックメニューの書き込みはこのモジュールのみで
// 行う。runProfilesTab.js・modals.js からは projectDeviceCatalog/findCatalogEntry を読み取り専用で参照する。
//
// 1つの行が2つの役目を持つ: チェックボックスは「このデバイスが
// 選択中の実行プロファイルに含まれる(かつ enabled)か」、行本体のクリックは右ペイン編集フォームの
// 選択。チェックボックスのクリックは行選択に波及させない(クリック領域を分ける)。

import { vscode } from './vscodeApi.js';
import { clampMenuPosition } from './menu.js';
import { t } from '../i18n.js';
import { physicalDeviceInfo } from './physicalDeviceCache.js';
import { paintMachineBadge } from './machineColors.js';

// **runProfilesTab.js からは import しない**(片方向依存を保つ。相互 import が esbuild の
// バンドル評価順を崩す実害は physicalDeviceCache.js 冒頭コメント参照)。選択中の実行プロファイルは
// renderDeviceRows/clearDeviceRows の呼び分けで暗黙に表す(呼ぶのは常に runProfilesTab.js)。

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

// ---- DOM 定数 ---------------------------------------------------------------------

export const btnDeviceAddExisting = document.getElementById('btn-run-profile-device-add-existing');
const deviceList = document.getElementById('run-profile-devices');
const detailPlaceholder = document.getElementById('run-profile-device-placeholder');
const deviceEditor = document.getElementById('run-profile-device-editor');
const headerKind = document.getElementById('run-profile-device-header-kind');
const headerName = document.getElementById('run-profile-device-header-name');
const headerPlatform = document.getElementById('run-profile-device-header-platform');
const iosFields = document.getElementById('run-profile-device-ios-fields');
const androidFields = document.getElementById('run-profile-device-android-fields');
const nameInput = document.getElementById('run-profile-device-name-input');
const simulatorValue = document.getElementById('run-profile-device-simulator');
const simulatorRow = document.getElementById('run-profile-device-simulator-row');
const osRow = document.getElementById('run-profile-device-os-row');
const physicalFields = document.getElementById('run-profile-device-physical-fields');
const modelValue = document.getElementById('run-profile-device-model');
const modelRow = document.getElementById('run-profile-device-model-row');
const physicalOsValue = document.getElementById('run-profile-device-physical-os');
const physicalOsRow = document.getElementById('run-profile-device-physical-os-row');
const osValue = document.getElementById('run-profile-device-os');
const udidValue = document.getElementById('run-profile-device-udid');
const portInput = document.getElementById('run-profile-device-port');
const avdValue = document.getElementById('run-profile-device-avd');
const avdRow = document.getElementById('run-profile-device-avd-row');
const serialValue = document.getElementById('run-profile-device-serial');
const serialRow = document.getElementById('run-profile-device-serial-row');
const editorError = document.getElementById('run-profile-device-error');
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
const isMacPlatform = /^Mac/.test(navigator.platform || '');

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
  refreshEditorForSelection();
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
  clearEditor();
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

function deviceDetail(entry) {
  if (entry.platform === 'ios') {
    if (entry.simulator) {
      return entry.os ? `${entry.simulator} / iOS ${entry.os}` : entry.simulator;
    }
    if (entry.udid) {
      return entry.udid.slice(0, 8);
    }
    return 'iOS';
  }
  if (entry.avd) {
    return `AVD: ${entry.avd}`;
  }
  return entry.serial || 'Android';
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
  // **force**: クリックによる明示的な選択切替は、前の行が dirty/送信中でも必ず切り替える
  // (このガードは renderDeviceRows の受動的な再描画専用 —— 同じ行を編集中に外部更新が来ても
  // 打鍵中の内容を消さないためのもの。クリックにまで適用すると別の行へ移れなくなる)。
  refreshEditorForSelection(true);
}

function updateSelectionUi() {
  for (const [key, el] of rowElements) {
    el.rowEl.classList.toggle('selected', selectedKeys.has(key));
  }
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
  for (const row of rows) {
    const rowEl = document.createElement('div');
    rowEl.className = 'run-profile-device-row-item';
    const checkbox = document.createElement('input');
    checkbox.type = 'checkbox';
    checkbox.checked = row.wasInProfile && row.enabled;
    checkbox.addEventListener('click', (event) => event.stopPropagation());
    const nameLine = document.createElement('div');
    nameLine.className = 'run-profile-device-name-line';
    if (row.body.kind === 'physical') {
      const badge = document.createElement('span');
      badge.className = 'badge badge-kind';
      badge.textContent = t('wvMonitor.tile.physicalBadge');
      nameLine.appendChild(badge);
    }
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
    const detail = document.createElement('div');
    detail.className = 'run-profile-device-detail';
    detail.textContent = deviceDetail(row.body);
    const textCol = document.createElement('div');
    textCol.className = 'run-profile-device-text';
    textCol.append(nameLine, detail);
    rowEl.append(checkbox, textCol);
    rowEl.addEventListener('click', (event) => toggleRowSelection(row.key, event));
    rowEl.addEventListener('contextmenu', (event) => {
      event.preventDefault();
      event.stopPropagation();
      if (isMacPlatform && event.ctrlKey) {
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

// ---- 右ペインの編集フォーム ---------------------------------------------------------

const EDITOR_PLATFORM_LABEL = { ios: 'iOS', android: 'Android' };
const editorFieldInputs = [nameInput, portInput];

// 機種/OS取得のために installedDevicesRequest を出したキー(無限要求ループ防止。
// 実機が未接続・AVD の config.ini に hw.device.name が無い等で値が埋まらないケースでは、
// 応答→再描画→再要求が永久ループになり CLI を叩き続けるため、1デバイス1回に絞る)。
const deviceInfoRequested = new Set();

let editorTarget = null; // { platform, machine, originalName, kind }
let editorOriginalValues = null;
let editorDirty = false;
let editorSubmitting = false;
const editorPendingSaves = [];
let editorSaveQueued = false;

function deviceFieldValues(entry) {
  return {
    name: entry.name,
    simulator: entry.simulator || '',
    os: entry.os || deviceInfoFallback(entry).os,
    udid: entry.udid || '',
    port: entry.port === undefined || entry.port === null ? '' : String(entry.port),
    avd: entry.avd || '',
    serial: entry.serial || '',
    model: entry.model || deviceInfoFallback(entry).model,
  };
}

function deviceInfoFallback(entry) {
  const key = entry.kind === 'physical'
    ? (entry.platform === 'ios' ? entry.udid : entry.serial)
    : (entry.platform === 'android' ? entry.avd : undefined);
  return physicalDeviceInfo(key) || { model: '', os: '' };
}

function currentEditorValues() {
  return {
    name: nameInput.value,
    simulator: simulatorValue.textContent,
    os: osValue.textContent,
    udid: udidValue.textContent,
    port: portInput.value,
    avd: avdValue.textContent,
    serial: serialValue.textContent,
  };
}

function valuesEqual(a, b) {
  return (
    a.name === b.name && a.simulator === b.simulator && a.os === b.os && a.udid === b.udid &&
    a.port === b.port && a.avd === b.avd && a.serial === b.serial
  );
}

function setEditorDirty(dirty) {
  editorDirty = dirty;
}

function renderEditor(row) {
  const entry = row.body;
  editorTarget = { platform: row.platform, machine: row.machine, originalName: row.name, kind: entry.kind };
  editorOriginalValues = deviceFieldValues(entry);
  editorSubmitting = false;
  editorSaveQueued = false;
  editorError.textContent = '';
  headerName.className = 'tile-name tile-name-' + row.platform;
  headerName.textContent = row.name;
  headerPlatform.textContent = EDITOR_PLATFORM_LABEL[row.platform] || row.platform;
  nameInput.value = editorOriginalValues.name;
  simulatorValue.textContent = editorOriginalValues.simulator;
  osValue.textContent = editorOriginalValues.os;
  udidValue.textContent = editorOriginalValues.udid;
  portInput.value = editorOriginalValues.port;
  avdValue.textContent = editorOriginalValues.avd;
  serialValue.textContent = editorOriginalValues.serial;
  iosFields.style.display = row.platform === 'ios' ? '' : 'none';
  androidFields.style.display = row.platform === 'android' ? '' : 'none';
  const physical = entry.kind === 'physical';
  headerKind.style.display = physical ? '' : 'none';
  avdRow.style.display = physical ? 'none' : '';
  serialRow.style.display = physical ? '' : 'none';
  const ownsInfoRows = row.platform === 'ios' && !physical;
  simulatorRow.style.display = ownsInfoRows ? '' : 'none';
  osRow.style.display = ownsInfoRows ? '' : 'none';

  const hasModel = !ownsInfoRows && !!editorOriginalValues.model;
  const hasOs = !ownsInfoRows && !!editorOriginalValues.os;
  modelValue.textContent = editorOriginalValues.model;
  physicalOsValue.textContent = editorOriginalValues.os;
  modelRow.style.display = hasModel ? '' : 'none';
  physicalOsRow.style.display = hasOs ? '' : 'none';
  physicalFields.style.display = hasModel || hasOs ? '' : 'none';
  const infoKey = row.key;
  if (!ownsInfoRows && !hasModel && !hasOs && !deviceInfoRequested.has(infoKey)) {
    deviceInfoRequested.add(infoKey);
    vscode.postMessage({ type: 'installedDevicesRequest', source: { kind: 'local' } });
  }
  detailPlaceholder.style.display = 'none';
  deviceEditor.style.display = '';
  setEditorDirty(false);
}

const PLACEHOLDER_DEFAULT_TEXT = detailPlaceholder.textContent;

function clearEditor(text) {
  editorTarget = null;
  editorOriginalValues = null;
  editorSubmitting = false;
  editorSaveQueued = false;
  deviceEditor.style.display = 'none';
  detailPlaceholder.style.display = '';
  detailPlaceholder.textContent = text !== undefined ? text : PLACEHOLDER_DEFAULT_TEXT;
  setEditorDirty(false);
}

function singleSelectedRow() {
  if (selectedKeys.size !== 1) {
    return null;
  }
  const [key] = selectedKeys;
  return rows.find((r) => r.key === key) || null;
}

/** installedDevices 応答が届いたら、開いている編集フォームを埋め直す(modals.js から呼ぶ)。 */
export function refreshSelectedDeviceEditor() {
  if (!editorTarget || editorDirty || editorSubmitting) {
    return;
  }
  const row = singleSelectedRow();
  if (row) {
    renderEditor(row);
  }
}

/** force=true(明示的な選択切替): dirty/送信中でも必ず renderEditor する。
 * force=false(renderDeviceRows からの受動的な再描画): 選択中の行を編集中なら打鍵内容を保つ。 */
function refreshEditorForSelection(force) {
  if (selectedKeys.size >= 2) {
    clearEditor(t('wvMonitor2.runProfileDevice.multiSelected', { count: selectedKeys.size }));
    return;
  }
  const row = singleSelectedRow();
  if (!row) {
    clearEditor();
    return;
  }
  if (force || (!editorDirty && !editorSubmitting)) {
    renderEditor(row);
  }
}

function onEditorFieldInput() {
  if (!editorTarget) {
    return;
  }
  setEditorDirty(!valuesEqual(currentEditorValues(), editorOriginalValues));
  editorError.textContent = '';
}
for (const input of editorFieldInputs) {
  input.addEventListener('input', onEditorFieldInput);
}

// **stopPropagation** —— #run-profile-editor の change リスナー(runProfilesTab.js の
// 自動保存)へ波及させない。この編集は別経路(runProfileDeviceUpdate)で保存する。
deviceEditor.addEventListener('change', (event) => {
  event.stopPropagation();
  onEditorFieldInput();
  saveEditorIfDirty();
});

// Enter = 入力を終えて保存 / Esc = 未保存の編集を破棄(フォーカスがエディタ内にある間だけ効く。
// メニュー表示中の Esc はメニュー閉じ[document 側リスナー]に譲る)。
deviceEditor.addEventListener('keydown', (event) => {
  if (deviceMenuEntry) {
    return;
  }
  if (event.key === 'Enter' && event.target.matches('#run-profile-device-editor input[type="text"]')) {
    event.preventDefault();
    saveEditorIfDirty();
  } else if (event.key === 'Escape' && editorDirty && !editorSubmitting) {
    event.preventDefault();
    const row = singleSelectedRow();
    if (row) {
      renderEditor(row);
    }
  }
});

function validateEditorFields(name) {
  if (name.length === 0) {
    return t('wvMonitor2.runProfileDevice.validation.nameRequired');
  }
  const others = catalogNamesForMachine(editorTarget.machine).filter((n) => n !== editorTarget.originalName);
  if (others.includes(name)) {
    return t('wvMonitor2.runProfileDevice.validation.nameExists', { name });
  }
  if (editorTarget.platform === 'ios') {
    const portValue = portInput.value.trim();
    if (portValue.length > 0 && (!/^\d+$/.test(portValue) || Number(portValue) > 65535)) {
      return t('wvMonitor2.runProfileDevice.validation.portInvalid');
    }
  }
  return null;
}

function saveEditorIfDirty() {
  if (!editorTarget) {
    return;
  }
  if (editorSubmitting) {
    editorSaveQueued = true;
    return;
  }
  editorSaveQueued = false;
  if (!editorDirty) {
    return;
  }
  const name = nameInput.value.trim();
  const validationError = validateEditorFields(name);
  if (validationError) {
    editorError.textContent = validationError;
    return;
  }
  if (nameInput.value !== name) {
    nameInput.value = name;
  }
  if (portInput.value !== portInput.value.trim()) {
    portInput.value = portInput.value.trim();
  }
  editorSubmitting = true;
  editorPendingSaves.push({ target: editorTarget, values: currentEditorValues() });
  editorError.textContent = '';
  vscode.postMessage({
    type: 'runProfileDeviceUpdate',
    platform: editorTarget.platform,
    ...(editorTarget.machine ? { machine: editorTarget.machine } : {}),
    originalName: editorTarget.originalName,
    fields: {
      name,
      simulator: editorTarget.platform === 'ios' ? simulatorValue.textContent.trim() : '',
      os: editorTarget.platform === 'ios' ? osValue.textContent.trim() : '',
      udid: editorTarget.platform === 'ios' ? udidValue.textContent.trim() : '',
      port: editorTarget.platform === 'ios' ? portInput.value.trim() : '',
      avd: editorTarget.platform === 'android' ? avdValue.textContent.trim() : '',
      serial: editorTarget.platform === 'android' ? serialValue.textContent.trim() : '',
    },
  });
}

export function applyRunProfileDeviceUpdateResult(message) {
  const submitted = editorPendingSaves.shift();
  if (!submitted) {
    return;
  }
  if (submitted.target !== editorTarget) {
    if (!message.ok) {
      editorError.textContent = message.error || t('wvMonitor2.runProfileDevice.updateFailed');
    }
    return;
  }
  editorSubmitting = false;
  if (message.ok) {
    // リネームで名前が変わるのでキーを作り直す(ホストが続けて送る profileInfo/runProfileData の
    // 再描画でも選択を保つため)。
    const newKey = refKey({ platform: editorTarget.platform, machine: editorTarget.machine, name: message.name });
    selectedKeys = new Set([newKey]);
    selectionAnchor = newKey;
    editorTarget.originalName = message.name;
    editorOriginalValues = { ...editorOriginalValues, ...submitted.values };
    editorError.textContent = '';
    // ホストは続けて profileInfo/runProfileData を再送する。ここでは反映を待たず、
    // その再送(renderDeviceRows)で行一覧・選択・フォームが最新化される。
  } else {
    editorError.textContent = message.error || t('wvMonitor2.runProfileDevice.updateFailed');
  }
  setEditorDirty(!valuesEqual(currentEditorValues(), editorOriginalValues));
  if (editorSaveQueued) {
    saveEditorIfDirty();
  }
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
