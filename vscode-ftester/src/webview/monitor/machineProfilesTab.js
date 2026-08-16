// machineProfilesTab.js
// 「プロファイル」タブの「マシンプロファイル」節を担う。
// machineProfiles・selectedMachine・selectedDeviceNames の書き込みはこのモジュールのみで行う。
// runProfilesTab.js・modals.js からは machineProfiles/findMachine/selectedMachine を読み取り専用で参照する。

import { vscode } from './vscodeApi.js';
import { clampMenuPosition } from './menu.js';
import { t } from '../i18n.js';
import { physicalDeviceInfo } from './physicalDeviceCache.js';

// ---- プロファイルタブ: マシンプロファイル ---------------------------------------

const machineSelect = document.getElementById('machine-select');
const machineNameStatic = document.getElementById('machine-name-static');
const btnMachineAdd = document.getElementById('btn-machine-add');
const btnMachineCopy = document.getElementById('btn-machine-copy');
const btnMachineRemove = document.getElementById('btn-machine-remove');
const btnMachineRename = document.getElementById('btn-machine-rename');
export const btnDeviceAddExisting = document.getElementById('btn-device-add-existing');
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
const editorSimulatorRow = document.getElementById('editor-simulator-row');
const editorOsRow = document.getElementById('editor-os-row');
const editorPhysicalFields = document.getElementById('editor-physical-fields');
const editorModel = document.getElementById('editor-model');
const editorModelRow = document.getElementById('editor-model-row');
const editorPhysicalOs = document.getElementById('editor-physical-os');
const editorPhysicalOsRow = document.getElementById('editor-physical-os-row');
const editorOs = document.getElementById('editor-os');
const editorUdid = document.getElementById('editor-udid');
const editorPort = document.getElementById('editor-port');
const editorAvd = document.getElementById('editor-avd');
const editorAvdRow = document.getElementById('editor-avd-row');
const editorSerial = document.getElementById('editor-serial');
const editorSerialRow = document.getElementById('editor-serial-row');
const editorDeviceKind = document.getElementById('editor-device-kind');
const editorError = document.getElementById('editor-error');
const editorConfirm = document.getElementById('editor-confirm');
const editorCancel = document.getElementById('editor-cancel');
const machineDeviceMenu = document.getElementById('machine-device-menu');
const machineDeviceMenuItemBtn = document.getElementById('machine-device-menu-item');

// machineProfileInfo 受信で更新。空なら「マシンプロファイルなし」。
export let machineProfiles = [];
let machineProfileHasError = false;
// select の値。machines が0件なら null。
export let selectedMachine = null;
// 選択中デバイス名(Set、複数選択、Finder/VSCode 標準セマンティクス)。
// マシン切替・一覧再描画時は validateSelectedDeviceName で存在しない名前を除去する。
// 右ペインの編集フォームは size===1 のときだけ表示する。
let selectedDeviceNames = new Set();
// 範囲選択(Shift+クリック)の起点。Shift+クリック自体ではアンカーを動かさない
// (連続 Shift+クリックで同じ起点から範囲を伸縮できる)。一覧から消えたら null に戻す。
let deviceSelectionAnchor = null;
// macOS 判定(行の contextmenu で Ctrl+クリックを選択トグルへ振り分けるのに使う)。
const isMacPlatform = /^Mac/.test(navigator.platform || '');
// 直近描画したデバイス行(name -> row)。挿入順=表示順で、範囲選択(Shift+クリック)の
// 順序計算に使う。
let deviceRowElements = new Map();
// 右クリックメニュー(#machine-device-menu)を開いている対象(未オープンなら null)。
// { machine, names } の形。
let machineDeviceMenuEntry = null;
// 右ペインの編集フォームの対象({ machine, platform, originalName }。未選択なら null)。
let editorTarget = null;
// フォーム再構築時点の6フィールド値。dirty 判定と再プリフィル可否判定に使う。
let editorOriginalValues = null;
let editorDirty = false;
// machineDeviceUpdate 応答待ち中か(二重送信防止・再プリフィル抑止に使う)。
let editorSubmitting = false;

export function findMachine(name) {
  return machineProfiles.find((m) => m.name === name);
}

function validateSelectedDeviceName() {
  const machine = findMachine(selectedMachine);
  const names = new Set(machine ? machine.devices.map((d) => d.name) : []);
  for (const name of selectedDeviceNames) {
    if (!names.has(name)) {
      selectedDeviceNames.delete(name);
    }
  }
  // アンカーが消えていれば null に戻す(不在時の Shift+クリックは通常クリック扱いになる)。
  if (deviceSelectionAnchor !== null && !names.has(deviceSelectionAnchor)) {
    deviceSelectionAnchor = null;
  }
}

export function applyMachineProfileInfo(message) {
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
  btnDeviceAddExisting.disabled = machineProfileHasError || machineProfiles.length === 0;
  // btnMachineAdd だけ machines.length を見ない([+]は対象マシン不要、[−]/[✏]は対象が要る)。
  btnMachineAdd.disabled = machineProfileHasError;
  btnMachineCopy.disabled = machineProfileHasError || machineProfiles.length === 0;
  btnMachineRemove.disabled = machineProfileHasError || machineProfiles.length === 0;
  btnMachineRename.disabled = machineProfileHasError || machineProfiles.length === 0;
}

// 追加/名前変更直後にホストが送る選択移動通知。postMessage は順序保証されるため単純に上書きでよい。
// エラー時にホストが送ってこない前提だが念のためガードする。
export function applyMachineProfileSelected(message) {
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
    machineNameStatic.textContent = t('wvMonitor2.machine.none');
  }
}

machineSelect.addEventListener('change', () => {
  selectedMachine = machineSelect.value;
  validateSelectedDeviceName();
  renderMachineProfileBody(machineProfileHasError ? machineProfileError.textContent : null);
  // マシン切替は明示操作なので、編集途中の値を破棄してフォームを作り直す。
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

// 行クリックの選択(Finder/VSCode 標準セマンティクス)。判定順は
// shiftKey → metaKey/ctrlKey → 通常(Shift+Cmd 同時は Shift 扱い)。
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
  // 選択変更は明示操作なので、編集途中の値を破棄してフォームを作り直す。
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
    empty.textContent = t('wvMonitor2.machine.deviceEmpty');
    machineDeviceList.appendChild(empty);
  } else {
    for (const device of devices) {
      const row = document.createElement('div');
      row.className = 'machine-device-row';
      const nameLine = document.createElement('div');
      nameLine.className = 'machine-device-name-line';
      const name = document.createElement('span');
      // タイル/レーンのデバイス名ピルと同じ配色クラスを再利用する(tile-name-ios/-android)。
      name.className = 'tile-name tile-name-' + device.platform;
      name.textContent = device.name;
      // 実機バッジはデバイス名の左(ピッカー・タイルと同じ配色 .badge-kind)
      if (device.kind === 'physical') {
        const badge = document.createElement('span');
        badge.className = 'badge badge-kind';
        badge.textContent = t('wvMonitor.tile.physicalBadge');
        nameLine.appendChild(badge);
      }
      nameLine.appendChild(name);
      const detail = document.createElement('div');
      detail.className = 'machine-device-detail';
      // 別の機械のデバイスは同名でありうる(一意なのは (host, name))ので、手元でないものは
      // どの機械のものかを出す。手元だけの構成では何も足さない(既存の見た目を変えない)
      detail.textContent = device.host ? `${device.host} / ${device.detail}` : device.detail;
      row.append(nameLine, detail);
      row.addEventListener('click', (event) => toggleDeviceRowSelection(device.name, event));
      row.addEventListener('contextmenu', (event) => {
        event.preventDefault();
        event.stopPropagation();
        // mac は Ctrl+クリックが click ではなく contextmenu として届くため、ここで選択トグルへ
        // 振り分ける(Win/Linux は通常の click で対応済み)。
        if (isMacPlatform && event.ctrlKey) {
          toggleDeviceRowSelection(device.name, event);
          return;
        }
        // 複数選択(2台以上)に含まれる行なら選択中全台、それ以外はクリックした行単体を対象にする。
        const names =
          selectedDeviceNames.size >= 2 && selectedDeviceNames.has(device.name)
            ? [...selectedDeviceNames]
            : [device.name];
        openMachineDeviceMenu({ machine: selectedMachine, names }, event.clientX, event.clientY);
      });
      deviceRowElements.set(device.name, row);
      machineDeviceList.appendChild(row);
    }
    applyDeviceListHeightCap();
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

// 一覧の高さは10台ぶんで頭打ちにし、それ以上は中でスクロールさせる(台数が多いとセクションが
// 画面外まで伸び、プロファイルタブの他セクションへ辿り着けない)。**1行の高さを定数で持たない** ——
// 行はフォント設定と中身(実機バッジの有無)で伸縮するので、固定値だと行の下段(detail)が切れる。
// 11行目の実位置との差 = ちょうど10行分。
const MAX_VISIBLE_DEVICE_ROWS = 10;
function deviceListHeightCap() {
  const rows = [...machineDeviceList.children];
  if (rows.length <= MAX_VISIBLE_DEVICE_ROWS) {
    return '';
  }
  const tenRows = rows[MAX_VISIBLE_DEVICE_ROWS].offsetTop - rows[0].offsetTop;
  // 非表示(タブ未選択)中とレイアウトを持たない jsdom では 0 になる。ここで上限を付けると
  // 高さ0で全行が隠れるので付けず、可視になった時点の ResizeObserver で測り直す。
  if (tenRows <= 0) {
    return '';
  }
  // border-box なので枠線(と横スクロールバー)のぶんを足さないと10行目が数px欠ける。
  return `${tenRows + machineDeviceList.offsetHeight - machineDeviceList.clientHeight}px`;
}
function applyDeviceListHeightCap() {
  // 値が同じときは書かない: max-height の変更自体が ResizeObserver を再発火させるため。
  // 行の offsetTop は上限やスクロール位置に影響されないので、値は1回で収束する。
  const next = deviceListHeightCap();
  if (machineDeviceList.style.maxHeight !== next) {
    machineDeviceList.style.maxHeight = next;
  }
}
// 一覧はタブが非表示のまま描画されることがある(モニター起動直後は「デバイス」タブが前面)。
// そのときは寸法が取れないので、可視になって箱ができた時点で測り直す。
if (typeof ResizeObserver !== 'undefined') {
  new ResizeObserver(() => applyDeviceListHeightCap()).observe(machineDeviceList);
}

// 選択中マシンのデバイス名(ios/android 横断。デバイス追加モーダルと編集フォームの重複検証用)。
// **host を渡すとその機械のぶんだけ**返す —— 一意なのは (host, name) で、別の機械に同じ名前の
// デバイスが居るのは通常(各機が同じ命名規則でシミュレータを作る)。判定の正は
// Sources/FTCore/DeviceHostGrouping.swift で、ここはその写し。
// host は undefined = 手元。引数を省略すると全ホストぶん(呼び出し側が自分で絞る)。
export function allDeviceNamesForSelectedMachine(host) {
  const machine = findMachine(selectedMachine);
  if (!machine) {
    return [];
  }
  if (arguments.length === 0) {
    return machine.devices.map((d) => d.name);
  }
  return machine.devices.filter((d) => (d.host ?? undefined) === host).map((d) => d.name);
}

// ---- 右ペインの編集フォーム ---------------------------------------------
// dirty 判定は現在値と editorOriginalValues の素の文字列比較(trim しない。見た目上の
// 変化判定であり、送信前の検証・整形とは別の関心事)。

const EDITOR_PLATFORM_LABEL = { ios: 'iOS', android: 'Android' };
// input を購読するのは編集可フィールドのみ(機種/OS/UDID/AVD は読み取り専用のラベル表示)。
const editorFieldInputs = [editorName, editorPort];

// undefined は空文字扱い、port は文字列化してフォーム6フィールド分を組み立てる。
// 機種/OS 取得のために installedDevicesRequest を出したフォーム(machine+デバイス名)。
// 無限要求ループ防止(renderDeviceEditor のコメント参照)。ピッカーを開けばキャッシュは
// 更新されるので、ここを消して再要求させる必要はない
const deviceInfoRequested = new Set();

function deviceFieldValues(device) {
  return {
    name: device.name,
    simulator: device.simulator || '',
    os: device.os || deviceInfoFallback(device).os,
    udid: device.udid || '',
    port: device.port === undefined || device.port === null ? '' : String(device.port),
    avd: device.avd || '',
    serial: device.serial || '',
    // プロファイルに model/os が無い実機(この機能より前に登録したもの)は、接続中の実機から
    // 取れた実値で補う。どちらも無ければ空(行を出さない)
    model: device.model || deviceInfoFallback(device).model,
  };
}

/** 機種/OS の表示用フォールバック。iOS 実機=udid / Android 実機=serial / エミュ=avd で引く
 * (シミュレータは simulator/os をプロファイルが持っているので不要)。取得前・未接続は空。 */
function deviceInfoFallback(device) {
  const key = device.kind === 'physical'
    ? (device.platform === 'ios' ? device.udid : device.serial)
    : (device.platform === 'android' ? device.avd : undefined);
  return physicalDeviceInfo(key) || { model: '', os: '' };
}

function currentEditorValues() {
  // 機種/OS/UDID/AVD はラベル表示なので textContent から読む(editorOriginalValues と同じ形にする)。
  return {
    name: editorName.value,
    simulator: editorSimulator.textContent,
    os: editorOs.textContent,
    udid: editorUdid.textContent,
    port: editorPort.value,
    avd: editorAvd.textContent,
    serial: editorSerial.textContent,
  };
}

function valuesEqual(a, b) {
  return (
    a.name === b.name &&
    a.simulator === b.simulator &&
    a.os === b.os &&
    a.udid === b.udid &&
    a.port === b.port &&
    a.avd === b.avd &&
    a.serial === b.serial
  );
}

// キャンセルは dirty の間だけ表示。送信中は確定・キャンセルとも無効化する。
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
  editorTarget = { machine: machine, platform: device.platform, originalName: device.name,
                   host: device.host ?? undefined };
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
  editorSerial.textContent = editorOriginalValues.serial;
  editorIosFields.style.display = device.platform === 'ios' ? '' : 'none';
  editorAndroidFields.style.display = device.platform === 'android' ? '' : 'none';
  // 実機は同定手段が違う: iOS=udid(既存行を流用)/ Android=serial(AVD の代わり)。
  // 機種/OS は実機にもあるが**登録時に控えた表示専用の値**(model/os)。値が無い実機
  // (旧 CLI で登録した等)は行ごと隠す — 空欄のラベルだけ残ると設定漏れに見えるため
  const physical = device.kind === 'physical';
  editorDeviceKind.style.display = physical ? '' : 'none';
  editorAvdRow.style.display = physical ? 'none' : '';
  editorSerialRow.style.display = physical ? '' : 'none';
  // **iOS シミュレータだけは platform セクションに機種(simulator)/OS の行を持つ**
  // (実体解決に使う値。プロファイルが保持している)。それ以外(iOS 実機・Android の
  // 仮想/実機)は行が無いので共通ブロックで出す。両方出すと OS が 2 行になる(実害)
  const ownsInfoRows = device.platform === 'ios' && !physical;
  editorSimulatorRow.style.display = ownsInfoRows ? '' : 'none';
  editorOsRow.style.display = ownsInfoRows ? '' : 'none';

  // 共通ブロック。**editor-simulator を流用しない**: あれは dirty 判定の比較対象(simulator)
  // なので model を書くと開いた瞬間に dirty になる。値が無ければ行ごと隠す
  // (空欄のラベルだけ残ると設定漏れに見える)
  const hasModel = !ownsInfoRows && !!editorOriginalValues.model;
  const hasOs = !ownsInfoRows && !!editorOriginalValues.os;
  editorModel.textContent = editorOriginalValues.model;
  editorPhysicalOs.textContent = editorOriginalValues.os;
  editorModelRow.style.display = hasModel ? '' : 'none';
  editorPhysicalOsRow.style.display = hasOs ? '' : 'none';
  editorPhysicalFields.style.display = hasModel || hasOs ? '' : 'none';
  // 機種/OS が未取得なら取りに行く(応答は applyInstalledDevices →
  // refreshSelectedDeviceEditor でこのフォームに反映される)。
  // **必ず1デバイス1回に絞る**: installedDevicesRequest は毎回 `ftester api installed-devices` を
  // spawn する(devicectl + adb getprop で数秒)。実機が未接続・AVD の config.ini に
  // hw.device.name が無い等で値が埋まらないケースでは、応答→再描画→再要求が
  // 永久ループになり CLI を叩き続ける(2026-07-25 のレビューで検出)
  const infoKey = machine + '\u0000' + device.name;
  if (!ownsInfoRows && !hasModel && !hasOs && !deviceInfoRequested.has(infoKey)) {
    deviceInfoRequested.add(infoKey);
    vscode.postMessage({ type: 'installedDevicesRequest' });
  }
  editorConfirm.textContent = t('wvMonitor2.common.confirm');
  profileDetailPlaceholder.style.display = 'none';
  machineDeviceEditor.style.display = '';
  setEditorDirty(false);
}

// プレースホルダーの既定文言(HTML の初期テキストをそのまま使い回す。0台選択時に表示する)。
const DEVICE_PLACEHOLDER_DEFAULT_TEXT = profileDetailPlaceholder.textContent;

// text 省略時は既定文言(0台選択)。2台以上選択時は呼び出し側が件数入りの文言を渡す。
function clearDeviceEditor(text) {
  editorTarget = null;
  editorOriginalValues = null;
  editorSubmitting = false;
  machineDeviceEditor.style.display = 'none';
  profileDetailPlaceholder.style.display = '';
  profileDetailPlaceholder.textContent = text !== undefined ? text : DEVICE_PLACEHOLDER_DEFAULT_TEXT;
  setEditorDirty(false);
}

// 選択中デバイスがちょうど1台なら返す(それ以外は null)。
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

// 選択変更・マシン切替用。1台選択ならフォームを作り直し、それ以外はプレースホルダーに戻す。
/** installedDevices 応答が届いたら、開いている編集フォームを埋め直す(modals.js から呼ぶ)。
 * 編集中(dirty)は作り直さない — 入力を破棄してしまうため。 */
export function refreshSelectedDeviceEditor() {
  if (!editorTarget || editorDirty || editorSubmitting) {
    return;
  }
  const device = singleSelectedDevice();
  if (device) {
    renderDeviceEditor(selectedMachine, device);
  }
}

function rebuildEditorForSelection() {
  if (selectedDeviceNames.size >= 2) {
    clearDeviceEditor(t('wvMonitor2.machine.multiSelected', { count: selectedDeviceNames.size }));
    return;
  }
  const device = singleSelectedDevice();
  if (device) {
    renderDeviceEditor(selectedMachine, device);
  } else {
    clearDeviceEditor();
  }
}

// machineProfileInfo 再受信用。dirty または送信中なら再プリフィルしない(入力中の値を保持)。
function refreshEditorAfterProfileInfo() {
  if (machineProfileHasError) {
    clearDeviceEditor();
    return;
  }
  if (selectedDeviceNames.size >= 2) {
    clearDeviceEditor(t('wvMonitor2.machine.multiSelected', { count: selectedDeviceNames.size }));
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
  // 入力変更で前回のエラー表示は古くなるので消す。
  editorError.textContent = '';
}
for (const input of editorFieldInputs) {
  input.addEventListener('input', onEditorFieldInput);
}

// キャンセル: machineProfiles は watcher 経由で常に最新のため、rebuildEditorForSelection が
// そのまま「ファイルの現在値に戻す」動作になる。
editorCancel.addEventListener('click', () => {
  if (editorCancel.disabled) {
    return;
  }
  rebuildEditorForSelection();
});

// Enter=確定 / Esc=キャンセル(runProfilesTab.js の同名ブロックと同じ方針)。
// デバイス右クリックメニュー表示中の Esc はメニュー閉じ(既存リスナー)に譲る。
document.getElementById('machine-profile-section').addEventListener('keydown', (event) => {
  if (machineDeviceMenuEntry) {
    return;
  }
  if (event.key === 'Enter' && !event.target.closest('button') && !editorConfirm.disabled) {
    event.preventDefault();
    editorConfirm.click();
  } else if (event.key === 'Escape' && editorDirty && !editorCancel.disabled) {
    event.preventDefault();
    editorCancel.click();
  }
});

// 複製元: src/monitorProfileForms.ts の updateDeviceInMachineProfile の検証部分(CSP により import 不可
// のため複製。ロジック変更時は両方に反映すること)。
function validateDeviceEditorFields(name) {
  if (name.length === 0) {
    return t('wvMonitor2.machine.validation.nameRequired');
  }
  // 重複はそのデバイスが居る機械の中だけで見る(一意なのは (host, name))。
  const others = allDeviceNamesForSelectedMachine(editorTarget.host)
    .filter((n) => n !== editorTarget.originalName);
  if (others.includes(name)) {
    return t('wvMonitor2.machine.validation.nameExists', { name });
  }
  if (editorTarget.platform === 'ios') {
    const portValue = editorPort.value.trim();
    if (portValue.length > 0 && (!/^\d+$/.test(portValue) || Number(portValue) > 65535)) {
      return t('wvMonitor2.machine.validation.portInvalid');
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
  editorConfirm.textContent = t('wvMonitor2.common.confirming');
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
      serial: editorTarget.platform === 'android' ? editorSerial.textContent.trim() : '',
    },
  });
});

// ok:true なら直後の machineProfileInfo 再送で一覧/フォームが最新化される。ok:false なら
// エラー表示のみで入力値は保持する。
export function applyMachineDeviceUpdateResult(message) {
  editorSubmitting = false;
  editorConfirm.textContent = t('wvMonitor2.common.confirm');
  if (message.ok) {
    selectedDeviceNames = new Set([message.name]);
    editorError.textContent = '';
    setEditorDirty(false);
  } else {
    refreshEditorButtonsUi();
    editorError.textContent = message.error || t('wvMonitor2.machine.updateFailed');
  }
}

// ---- デバイス行の右クリックメニュー(除去) -------------------------------------
// タイルの #device-op-menu と見た目・挙動は同じだが、状態・DOM要素は独立させている。

export function closeMachineDeviceMenu() {
  if (!machineDeviceMenuEntry) {
    return;
  }
  machineDeviceMenuEntry = null;
  machineDeviceMenu.classList.remove('visible');
}

// entry は { machine, names }(1件以上)。2台以上なら項目ラベルを「選択した<N>台を除去」に変える。
function openMachineDeviceMenu(entry, clientX, clientY) {
  machineDeviceMenuEntry = entry;
  machineDeviceMenuItemBtn.textContent =
    entry.names.length >= 2
      ? t('wvMonitor2.machine.removeSelectedCount', { count: entry.names.length })
      : t('wvMonitor2.common.remove');
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

// 外クリック・Esc・スクロール・リサイズで閉じる(#device-op-menu と同じ方針、独立リスナー)。
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
// 行上の contextmenu は stopPropagation 済み。行外で右クリックした場合に残さないためのガード。
document.addEventListener('contextmenu', () => closeMachineDeviceMenu());
