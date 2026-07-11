// modals.js
// 「プロファイル」タブの3モーダル(デバイス追加/名前入力/既存デバイスから選択)をまとめる。
// applyCreateDeviceResult が既存選択モーダルの pendingAutoCheck を直接書き換えるため、
// setter を挟まず同一モジュールに置いている。

import { vscode } from './vscodeApi.js';
import { selectedMachine, findMachine, allDeviceNamesForSelectedMachine, btnDeviceAddExisting } from './machineProfilesTab.js';

// ---- デバイス追加モーダル ---------------------------------------------------

// 複製元: src/monitorModel.ts の validateNewDeviceName(CSP により import 不可のため複製。
// ロジック変更時は両方に反映すること)。
function validateNewDeviceName(name, existing) {
  const trimmed = name.trim();
  if (trimmed.length === 0) {
    return 'デバイス名を入力してください。';
  }
  if (existing.includes(trimmed)) {
    return '「' + trimmed + '」は既に存在します。';
  }
  return null;
}

const deviceAddOverlay = document.getElementById('device-add-overlay');
const dlgPlatformIos = document.getElementById('dlg-platform-ios');
const dlgPlatformAndroid = document.getElementById('dlg-platform-android');
const dlgModel = document.getElementById('dlg-model');
const dlgOs = document.getElementById('dlg-os');
const dlgName = document.getElementById('dlg-name');
const dlgError = document.getElementById('dlg-error');
const dlgCancel = document.getElementById('dlg-cancel');
const dlgOk = document.getElementById('dlg-ok');

let deviceAddOpen = false;
let deviceAddCreating = false;
// deviceCatalogRequest の応答(deviceCatalog.ok:true の catalog)。未着/失敗中は null。
let deviceCatalog = null;
// デバイス名をユーザーが手で編集したか(true の間は自動生成に追従しない)。
let dlgNameDirty = false;
// #device-pick-overlay の「+」から開いたか(devicePickOpen をそのまま流用して判定)。
// true なら createDevice は register:false(物理作成のみ)、成功時 pendingAutoCheck で自動チェック。
let deviceAddFromPicker = false;

// ラジオ2つ(dlg-platform-ios/-android)で1つの select 相当を表す。読み書きをここに集約する。
function getDialogPlatform() {
  return dlgPlatformIos.checked ? 'ios' : 'android';
}
function setDialogPlatform(value) {
  dlgPlatformIos.checked = value === 'ios';
  dlgPlatformAndroid.checked = value === 'android';
}

function setDialogControlsEnabled(enabled) {
  dlgPlatformIos.disabled = !enabled;
  dlgPlatformAndroid.disabled = !enabled;
  dlgModel.disabled = !enabled;
  dlgOs.disabled = !enabled;
  dlgName.disabled = !enabled;
}

function fillSelect(select, options) {
  select.textContent = '';
  for (const opt of options) {
    const el = document.createElement('option');
    el.value = opt.value;
    el.textContent = opt.label;
    select.appendChild(el);
  }
}

function modelOptionsFor(platform) {
  if (!deviceCatalog) {
    return [];
  }
  return platform === 'ios'
    ? deviceCatalog.ios.deviceTypes.map((d) => ({ value: d.identifier, label: d.name }))
    : deviceCatalog.android.models.map((m) => ({ value: m.id, label: m.name }));
}

function osOptionsFor(platform) {
  if (!deviceCatalog) {
    return [];
  }
  if (platform === 'ios') {
    return deviceCatalog.ios.runtimes.map((r) => ({ value: r.identifier, label: r.name }));
  }
  return deviceCatalog.android.systemImages.map((s) => ({
    value: s.package,
    label: s.versionName + '(API ' + s.apiLevel + ') ' + s.tag + ' / ' + s.abi,
  }));
}

function selectedOptionLabel(select) {
  const opt = select.options[select.selectedIndex];
  return opt ? opt.textContent : '';
}

// iOS = "モデル名(ランタイム名)"、Android = "モデル名(versionName)"(モデル未選択なら空文字)。
function autoDeviceName() {
  const modelLabel = selectedOptionLabel(dlgModel);
  if (!modelLabel) {
    return '';
  }
  const osLabel = selectedOptionLabel(dlgOs);
  return osLabel ? modelLabel + '(' + osLabel + ')' : modelLabel;
}

function refreshAutoName() {
  if (!dlgNameDirty) {
    dlgName.value = autoDeviceName();
  }
}

// available:false 側のラジオを disabled にし、選択がそちら側なら利用可能な側へ寄せる
// (両方不可なら変更しない)。setDialogControlsEnabled(true) 直後にも呼び直すこと
// (一律 enabled 化で available:false 側まで有効に戻ってしまうため)。
function applyPlatformAvailability() {
  dlgPlatformIos.disabled = !deviceCatalog.ios.available;
  dlgPlatformAndroid.disabled = !deviceCatalog.android.available;
  if (getDialogPlatform() === 'ios' && !deviceCatalog.ios.available && deviceCatalog.android.available) {
    setDialogPlatform('android');
  } else if (getDialogPlatform() === 'android' && !deviceCatalog.android.available && deviceCatalog.ios.available) {
    setDialogPlatform('ios');
  }
}

function refreshModelAndOsOptions() {
  fillSelect(dlgModel, modelOptionsFor(getDialogPlatform()));
  fillSelect(dlgOs, osOptionsFor(getDialogPlatform()));
  refreshAutoName();
}

dlgPlatformIos.addEventListener('change', () => refreshModelAndOsOptions());
dlgPlatformAndroid.addEventListener('change', () => refreshModelAndOsOptions());
dlgModel.addEventListener('change', () => refreshAutoName());
dlgOs.addEventListener('change', () => refreshAutoName());
dlgName.addEventListener('input', () => {
  if (dlgName.value.trim().length === 0) {
    // 空にした = 自動生成への追従を再開する
    dlgNameDirty = false;
    dlgName.value = autoDeviceName();
  } else {
    dlgNameDirty = true;
  }
});

function openDeviceAddModal() {
  if (!selectedMachine) {
    return;
  }
  deviceAddFromPicker = devicePickOpen;
  deviceAddOpen = true;
  deviceAddCreating = false;
  deviceCatalog = null;
  dlgNameDirty = false;
  dlgName.value = '';
  dlgModel.textContent = '';
  dlgOs.textContent = '';
  dlgError.classList.add('info');
  dlgError.textContent = 'カタログを読み込み中...';
  setDialogControlsEnabled(false);
  dlgOk.disabled = true;
  dlgOk.textContent = 'OK';
  dlgCancel.disabled = false;
  deviceAddOverlay.classList.add('visible');
  vscode.postMessage({ type: 'deviceCatalogRequest' });
}

function closeDeviceAddModal() {
  if (!deviceAddOpen || deviceAddCreating) {
    return;
  }
  deviceAddOpen = false;
  deviceAddOverlay.classList.remove('visible');
}

export function applyDeviceCatalog(message) {
  if (!deviceAddOpen) {
    return; // モーダルを閉じた後に届いた応答は無視する
  }
  if (!message.ok || !message.catalog) {
    dlgError.classList.remove('info');
    dlgError.textContent = message.error || 'カタログの取得に失敗しました。';
    dlgOk.disabled = true;
    return;
  }
  deviceCatalog = message.catalog;
  dlgError.classList.remove('info');
  dlgError.textContent = '';
  setDialogControlsEnabled(true);
  applyPlatformAvailability();
  refreshModelAndOsOptions();
  dlgOk.disabled = false;
}

export function applyCreateDeviceResult(message) {
  if (!deviceAddOpen) {
    return;
  }
  deviceAddCreating = false;
  dlgCancel.disabled = false;
  dlgOk.textContent = 'OK';
  if (message.ok) {
    closeDeviceAddModal();
    // pendingAutoCheck に識別子を保持(次の一覧再描画で自動チェックON。詳細は宣言箇所参照)。
    if (deviceAddFromPicker) {
      pendingAutoCheck = message.device ? { udid: message.device.udid, avd: message.device.avd } : null;
    }
    reloadDevicePickIfOpen();
    return;
  }
  dlgOk.disabled = false;
  setDialogControlsEnabled(true);
  // setDialogControlsEnabled(true) は両ラジオを一律 enabled にするため、applyPlatformAvailability で
  // available:false 側を戻す。
  applyPlatformAvailability();
  dlgError.classList.remove('info');
  dlgError.textContent = message.error || 'デバイスの作成に失敗しました。';
}

// 「+新規作成」ボタンは無く、openDeviceAddModal は #device-pick-overlay 内の「+」からのみ開く。
dlgCancel.addEventListener('click', () => closeDeviceAddModal());
deviceAddOverlay.addEventListener('click', (event) => {
  if (event.target === deviceAddOverlay) {
    closeDeviceAddModal();
  }
});
dlgOk.addEventListener('click', () => {
  if (dlgOk.disabled || deviceAddCreating || !deviceCatalog) {
    return;
  }
  const name = dlgName.value.trim();
  const error = validateNewDeviceName(name, allDeviceNamesForSelectedMachine());
  if (error) {
    dlgError.classList.remove('info');
    dlgError.textContent = error;
    return;
  }
  deviceAddCreating = true;
  setDialogControlsEnabled(false);
  dlgOk.disabled = true;
  dlgCancel.disabled = true;
  dlgOk.textContent = '作成中...';
  dlgError.textContent = '';
  vscode.postMessage({
    type: 'createDevice',
    machine: selectedMachine,
    platform: getDialogPlatform(),
    name: name,
    model: dlgModel.value,
    os: dlgOs.value,
    // ピッカー経由なら register:false(登録はピッカー側 OK の machineDevicesSync で行う)。
    register: !deviceAddFromPicker,
  });
});
// closeDeviceAddModal は自分の状態のみ見るため、他の Esc ハンドラと独立して共存できる。
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    closeDeviceAddModal();
  }
});

// ---- 名前入力モーダル(#name-input-overlay) ----------------------------------------
// 実行/アプリ/マシンプロファイルの追加・コピー・名前変更用 showInputBox 相当。id で拡張側の
// pendingNameInput と突き合わせる。検証ルールは拡張側の validateNew*ProfileName と同一に保つこと。

const nameInputOverlay = document.getElementById('name-input-overlay');
const nameInputTitleEl = document.getElementById('name-input-title');
const nameInputField = document.getElementById('name-input-field');
const nameInputErrorEl = document.getElementById('name-input-error');
const nameInputCancelBtn = document.getElementById('name-input-cancel');
const nameInputOkBtn = document.getElementById('name-input-ok');

const NAME_INPUT_BACKSLASH = String.fromCharCode(92);

// { id, noun, dupLabel, existing, caseInsensitiveDup, touched } | null
let nameInputState = null;

function validateNameInputValue(raw, state) {
  const trimmed = raw.trim();
  if (trimmed.length === 0) {
    return state.noun + 'を入力してください。';
  }
  if (trimmed.indexOf('/') !== -1 || trimmed.indexOf(NAME_INPUT_BACKSLASH) !== -1) {
    return state.noun + 'に "/" や "' + NAME_INPUT_BACKSLASH + '" は使えません。';
  }
  if (trimmed.charAt(0) === '.') {
    return state.noun + 'を "." で始めることはできません。';
  }
  const compareName = state.caseInsensitiveDup ? trimmed.toLowerCase() : trimmed;
  const isDup = state.existing.some((item) => (state.caseInsensitiveDup ? item.toLowerCase() : item) === compareName);
  if (isDup) {
    return state.dupLabel + '「' + trimmed + '」は既に存在します。';
  }
  return null;
}

// touched か value 非空のときだけエラー文言を表示する(開いた直後に空欄でエラー表示するのを
// 防ぐ)。OK の disabled 切替は常に行う。
function refreshNameInputValidation() {
  if (!nameInputState) {
    return;
  }
  const raw = nameInputField.value;
  const error = validateNameInputValue(raw, nameInputState);
  const shouldShowError = raw.trim().length > 0 || nameInputState.touched;
  nameInputErrorEl.textContent = shouldShowError && error ? error : '';
  nameInputOkBtn.disabled = !!error;
}

function closeNameInputModal() {
  nameInputOverlay.classList.remove('visible');
  nameInputState = null;
}

function confirmNameInput() {
  if (!nameInputState || nameInputOkBtn.disabled) {
    return;
  }
  vscode.postMessage({ type: 'nameInputConfirm', id: nameInputState.id, name: nameInputField.value });
  closeNameInputModal();
}

function cancelNameInput() {
  if (!nameInputState) {
    return;
  }
  vscode.postMessage({ type: 'nameInputCancel', id: nameInputState.id });
  closeNameInputModal();
}

export function applyNameInputOpen(message) {
  // 二重 nameInputOpen 受信時は単に上書き再初期化する(通常は起こらないが念のため)。
  nameInputState = {
    id: message.id,
    noun: message.noun,
    dupLabel: message.dupLabel,
    existing: message.existing,
    caseInsensitiveDup: message.caseInsensitiveDup,
    touched: false,
  };
  nameInputTitleEl.textContent = message.title;
  nameInputField.value = message.value;
  nameInputErrorEl.textContent = '';
  nameInputOverlay.classList.add('visible');
  nameInputField.focus();
  if (message.value.length > 0) {
    nameInputField.select();
  }
  refreshNameInputValidation();
}

nameInputField.addEventListener('input', () => {
  if (!nameInputState) {
    return;
  }
  nameInputState.touched = true;
  refreshNameInputValidation();
});
nameInputField.addEventListener('keydown', (event) => {
  if (event.key === 'Enter') {
    event.preventDefault();
    confirmNameInput();
  }
});
nameInputOkBtn.addEventListener('click', () => confirmNameInput());
nameInputCancelBtn.addEventListener('click', () => cancelNameInput());
nameInputOverlay.addEventListener('click', (event) => {
  if (event.target === nameInputOverlay) {
    cancelNameInput();
  }
});
// 他モーダルと同時には開かないため、独立した専用 Esc リスナーでよい。
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && nameInputState) {
    cancelNameInput();
  }
});

// ---- 「+既存から選択」モーダル(#device-pick-overlay) -----------------------
// チェックボックスは「選択」ではなく「マシンプロファイルへの登録状態そのもの」を表す
// (初期値=現在の登録有無)。OK は初期状態からの差分を machineDevicesSync(add/remove)で送る。

const devicePickOverlay = document.getElementById('device-pick-overlay');
const devicePickIosTitle = document.getElementById('device-pick-ios-title');
const devicePickIosBody = document.getElementById('device-pick-ios-body');
const devicePickAndroidTitle = document.getElementById('device-pick-android-title');
const devicePickAndroidBody = document.getElementById('device-pick-android-body');
const devicePickError = document.getElementById('device-pick-error');
const devicePickCancel = document.getElementById('device-pick-cancel');
const devicePickOk = document.getElementById('device-pick-ok');
const devicePickAddNewBtn = document.getElementById('device-pick-add-new');

let devicePickOpen = false;
let devicePickAdding = false;
// 直近描画した行。initialChecked は描画時点の登録有無(OK 時に checkbox.checked との差分を
// add/remove として組み立てる)。registeredName は未チェックにした場合の削除対象(name)。
let devicePickIosRows = [];
let devicePickAndroidRows = [];
// register:false で作成した直後、次の installedDevices 再描画で自動チェックONにしたい行の
// 識別子(iOS=udid/Android=avd の id)。適用後は必ず null に戻す(一度きりの適用)。
let pendingAutoCheck = null;

// 識別値→マシンプロファイル上の name の対応表(初期チェック判定・remove 対象名の特定に使う)。
// Android は avd の id/displayName どちらの一致も登録済みとみなす。
function registeredIosNameByUdid() {
  const machine = findMachine(selectedMachine);
  const map = new Map();
  if (machine) {
    for (const d of machine.devices) {
      if (d.platform === 'ios' && d.udid) {
        map.set(d.udid, d.name);
      }
    }
  }
  return map;
}
function registeredAndroidNameByAvd() {
  const machine = findMachine(selectedMachine);
  const map = new Map();
  if (machine) {
    for (const d of machine.devices) {
      if (d.platform === 'android' && d.avd) {
        map.set(d.avd, d.name);
      }
    }
  }
  return map;
}

// OK は初期状態からの差分が1件以上あるときだけ有効(チェック済み数では判定できない)。
function updateDevicePickOkState() {
  if (devicePickAdding) {
    return;
  }
  const anyDiff =
    devicePickIosRows.some((row) => row.checkbox.checked !== row.initialChecked) ||
    devicePickAndroidRows.some((row) => row.checkbox.checked !== row.initialChecked);
  devicePickOk.disabled = !anyDiff;
}

function buildDevicePickEmptyRow(container, text) {
  const empty = document.createElement('div');
  empty.className = 'device-pick-empty';
  empty.textContent = text;
  container.appendChild(empty);
}

// checkbox.checked → .checked クラス(CSS 配色)に同期する。プログラム的な checked 変更は
// change イベントを発火しないため、変更経路ごとに明示的に呼ぶこと。
function syncDevicePickRowChecked(row, checkbox) {
  row.classList.toggle('checked', checkbox.checked);
}

// 行クリックでチェックを切り替える。checkbox 自体のクリックはネイティブトグルに任せ、row 側で
// 拾うと二重トグルで元に戻るため除外する。disabled 中は何もしない。
function attachDevicePickRowToggle(row, checkbox) {
  row.addEventListener('click', (event) => {
    if (event.target === checkbox || checkbox.disabled) {
      return;
    }
    checkbox.checked = !checkbox.checked;
    syncDevicePickRowChecked(row, checkbox);
    updateDevicePickOkState();
  });
}

// installedDevices(InstalledDevices の形)から2グループ分の行を組み立てる。
function renderDevicePickGroups(data) {
  devicePickIosRows = [];
  devicePickAndroidRows = [];
  devicePickIosBody.textContent = '';
  devicePickAndroidBody.textContent = '';

  const iosNameByUdid = registeredIosNameByUdid();
  const iosData = data.ios;
  devicePickIosTitle.textContent = 'iOS シミュレータ (' + iosData.devices.length + ')';
  if (!iosData.available) {
    buildDevicePickEmptyRow(devicePickIosBody, iosData.error || 'iOS シミュレータを取得できませんでした。');
  } else if (iosData.devices.length === 0) {
    buildDevicePickEmptyRow(devicePickIosBody, 'iOS シミュレータがありません。');
  } else {
    for (const device of iosData.devices) {
      const registeredName = iosNameByUdid.get(device.udid);
      const registered = registeredName !== undefined;
      const row = document.createElement('div');
      row.className = 'device-pick-row';
      const checkbox = document.createElement('input');
      checkbox.type = 'checkbox';
      checkbox.checked = registered;
      checkbox.addEventListener('change', () => {
        syncDevicePickRowChecked(row, checkbox);
        updateDevicePickOkState();
      });
      const textWrap = document.createElement('div');
      textWrap.className = 'device-pick-row-text';
      // タイル配色ピル(.tile-name/-ios)を共用。
      const nameEl = document.createElement('span');
      nameEl.className = 'device-pick-row-name tile-name tile-name-ios';
      nameEl.textContent = device.name;
      const detailEl = document.createElement('div');
      detailEl.className = 'device-pick-row-detail';
      detailEl.textContent = 'iOS ' + device.os + ' / ' + device.udid.slice(0, 8);
      textWrap.append(nameEl, detailEl);
      row.append(checkbox, textWrap);
      attachDevicePickRowToggle(row, checkbox);
      syncDevicePickRowChecked(row, checkbox);
      devicePickIosBody.appendChild(row);
      devicePickIosRows.push({ checkbox: checkbox, device: device, initialChecked: registered, registeredName: registeredName, rowEl: row });
    }
  }

  const androidNameByAvd = registeredAndroidNameByAvd();
  const androidData = data.android;
  devicePickAndroidTitle.textContent = 'Android AVD (' + androidData.avds.length + ')';
  if (!androidData.available) {
    buildDevicePickEmptyRow(devicePickAndroidBody, androidData.error || 'Android AVD を取得できませんでした。');
  } else if (androidData.avds.length === 0) {
    buildDevicePickEmptyRow(devicePickAndroidBody, 'Android AVD がありません。');
  } else {
    for (const avd of androidData.avds) {
      const registeredName = androidNameByAvd.get(avd.id) ?? androidNameByAvd.get(avd.displayName);
      const registered = registeredName !== undefined;
      const row = document.createElement('div');
      row.className = 'device-pick-row';
      const checkbox = document.createElement('input');
      checkbox.type = 'checkbox';
      checkbox.checked = registered;
      checkbox.addEventListener('change', () => {
        syncDevicePickRowChecked(row, checkbox);
        updateDevicePickOkState();
      });
      const textWrap = document.createElement('div');
      textWrap.className = 'device-pick-row-text';
      // タイル配色ピル(.tile-name/-android)を共用。
      const nameEl = document.createElement('span');
      nameEl.className = 'device-pick-row-name tile-name tile-name-android';
      nameEl.textContent = avd.displayName;
      const detailEl = document.createElement('div');
      detailEl.className = 'device-pick-row-detail';
      const detailParts = [];
      if (avd.id !== avd.displayName) {
        detailParts.push(avd.id);
      }
      detailEl.textContent = detailParts.join('・');
      textWrap.append(nameEl, detailEl);
      row.append(checkbox, textWrap);
      attachDevicePickRowToggle(row, checkbox);
      syncDevicePickRowChecked(row, checkbox);
      devicePickAndroidBody.appendChild(row);
      devicePickAndroidRows.push({ checkbox: checkbox, avd: avd, initialChecked: registered, registeredName: registeredName, rowEl: row });
    }
  }
}

// pendingAutoCheck が指す行の checkbox だけ ON にする(initialChecked は false のままなので
// 差分としてカウントされ OK が有効になる)。renderDevicePickGroups 直後に呼ぶこと。
function applyPendingAutoCheck() {
  if (!pendingAutoCheck) {
    return;
  }
  const target = pendingAutoCheck;
  pendingAutoCheck = null;
  if (target.udid) {
    const row = devicePickIosRows.find((r) => r.device.udid === target.udid);
    if (row) {
      row.checkbox.checked = true;
      syncDevicePickRowChecked(row.rowEl, row.checkbox);
    }
  }
  if (target.avd) {
    const row = devicePickAndroidRows.find((r) => r.avd.id === target.avd);
    if (row) {
      row.checkbox.checked = true;
      syncDevicePickRowChecked(row.rowEl, row.checkbox);
    }
  }
}

// 送信中は checkbox も含め全コントロールを disabled にする。再有効化時は一律 enabled でよい。
function setDevicePickControlsEnabled(enabled) {
  for (const row of devicePickIosRows.concat(devicePickAndroidRows)) {
    row.checkbox.disabled = !enabled;
  }
}

// 作成成功後、モーダルが開いていれば一覧を再取得する(他行の未確定差分は破棄される。単純さ優先)。
function reloadDevicePickIfOpen() {
  if (!devicePickOpen) {
    return;
  }
  devicePickError.classList.add('info');
  devicePickError.textContent = '一覧を読み込み中...';
  devicePickOk.disabled = true;
  vscode.postMessage({ type: 'installedDevicesRequest' });
}

function openDevicePickModal() {
  if (!selectedMachine) {
    return;
  }
  devicePickOpen = true;
  devicePickAdding = false;
  pendingAutoCheck = null; // 前回開いた際の残留分があれば捨てて、新規セッションはクリーンに始める
  devicePickIosRows = [];
  devicePickAndroidRows = [];
  devicePickIosBody.textContent = '';
  devicePickAndroidBody.textContent = '';
  devicePickIosTitle.textContent = 'iOS シミュレータ';
  devicePickAndroidTitle.textContent = 'Android AVD';
  devicePickError.classList.add('info');
  devicePickError.textContent = '一覧を読み込み中...';
  devicePickOk.disabled = true;
  devicePickOk.textContent = 'OK';
  devicePickCancel.disabled = false;
  devicePickOverlay.classList.add('visible');
  vscode.postMessage({ type: 'installedDevicesRequest' });
}

function closeDevicePickModal() {
  if (!devicePickOpen || devicePickAdding) {
    return;
  }
  devicePickOpen = false;
  pendingAutoCheck = null; // 閉じた後に届く installedDevices 応答で誤適用しないようクリアする
  devicePickOverlay.classList.remove('visible');
}

export function applyInstalledDevices(message) {
  if (!devicePickOpen) {
    return; // モーダルを閉じた後に届いた応答は無視する(applyDeviceCatalog と同じ方針)
  }
  if (!message.ok || !message.data) {
    devicePickError.classList.remove('info');
    devicePickError.textContent = message.error || '一覧の取得に失敗しました。';
    devicePickOk.disabled = true;
    return;
  }
  devicePickError.classList.remove('info');
  devicePickError.textContent = '';
  renderDevicePickGroups(message.data);
  applyPendingAutoCheck();
  updateDevicePickOkState();
}

export function applyMachineDevicesSyncResult(message) {
  if (!devicePickOpen) {
    return;
  }
  devicePickAdding = false;
  devicePickCancel.disabled = false;
  devicePickOk.textContent = 'OK';
  if (message.ok) {
    closeDevicePickModal();
    return;
  }
  setDevicePickControlsEnabled(true);
  updateDevicePickOkState();
  devicePickError.classList.remove('info');
  devicePickError.textContent = message.error || 'デバイスの同期に失敗しました。';
}

btnDeviceAddExisting.addEventListener('click', () => openDevicePickModal());
devicePickAddNewBtn.addEventListener('click', () => openDeviceAddModal());
devicePickCancel.addEventListener('click', () => closeDevicePickModal());
devicePickOverlay.addEventListener('click', (event) => {
  if (event.target === devicePickOverlay) {
    closeDevicePickModal();
  }
});
devicePickOk.addEventListener('click', () => {
  if (devicePickOk.disabled || devicePickAdding) {
    return;
  }
  const add = [];
  const remove = [];
  for (const row of devicePickIosRows) {
    if (row.checkbox.checked && !row.initialChecked) {
      add.push({
        platform: 'ios',
        name: row.device.name,
        simulator: row.device.name,
        os: row.device.os,
        udid: row.device.udid,
      });
    } else if (!row.checkbox.checked && row.initialChecked) {
      remove.push(row.registeredName);
    }
  }
  for (const row of devicePickAndroidRows) {
    if (row.checkbox.checked && !row.initialChecked) {
      add.push({ platform: 'android', name: row.avd.displayName, avd: row.avd.id });
    } else if (!row.checkbox.checked && row.initialChecked) {
      remove.push(row.registeredName);
    }
  }
  if (add.length === 0 && remove.length === 0) {
    return; // OK は差分がある間だけ有効なので通常ここには来ない(防御的ガード)
  }
  devicePickAdding = true;
  setDevicePickControlsEnabled(false);
  devicePickOk.disabled = true;
  devicePickCancel.disabled = true;
  devicePickOk.textContent = '適用中...';
  devicePickError.classList.remove('info');
  devicePickError.textContent = '';
  vscode.postMessage({ type: 'machineDevicesSync', machine: selectedMachine, add: add, remove: remove });
});
// #device-add-overlay をこのモーダルの上に重ねて開けるため、deviceAddOpen 中は Esc で奥の
// このモーダルまで閉じないよう先にチェックする(手前側は自身の Esc ハンドラで閉じる)。
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    if (deviceAddOpen) {
      return;
    }
    closeDevicePickModal();
  }
});
