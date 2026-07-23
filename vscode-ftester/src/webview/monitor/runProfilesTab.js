// machineProfiles/findMachine(machineProfilesTab.js の状態)はここでは読み取り専用。

import { vscode } from './vscodeApi.js';
import { machineProfiles, findMachine } from './machineProfilesTab.js';
import { t } from '../i18n.js';

// 選択は「編集対象」であり、デバイスタブの実行プロファイル選択(ftester.profile)とは独立。
// dirty管理: フォーム値と runProfileOriginalFields の比較で「確定」を有効化。
// - 選択変更(明示操作)は編集破棄して再ロード。
// - profileInfo/machineProfileInfo 再受信時: 編集中なら保持、未編集なら再ロード(消失時はcurrent→先頭)。
// - runProfileFileChanged(外部編集)は同名 && 未編集のときのみ再ロード。

const runProfileSelect = document.getElementById('run-profile-select');
const runProfileNameStatic = document.getElementById('run-profile-name-static');
const btnRunProfileAdd = document.getElementById('btn-run-profile-add');
const btnRunProfileCopy = document.getElementById('btn-run-profile-copy');
const btnRunProfileRemove = document.getElementById('btn-run-profile-remove');
const btnRunProfileRename = document.getElementById('btn-run-profile-rename');
const runProfilePlaceholder = document.getElementById('run-profile-placeholder');
const runProfileEditor = document.getElementById('run-profile-editor');
const runProfileMachine = document.getElementById('run-profile-machine');
const runProfileApp = document.getElementById('run-profile-app');
const runProfileDevices = document.getElementById('run-profile-devices');
const runProfileHeal = document.getElementById('run-profile-heal');
const runProfileIosInappEngine = document.getElementById('run-profile-ios-inapp-engine');
const runProfileWipeDataOnBloat = document.getElementById('run-profile-wipe-data-on-bloat');
const runProfileRecord = document.getElementById('run-profile-record');
const runProfileWipeThreshold = document.getElementById('run-profile-wipe-threshold');
const runProfileLocale = document.getElementById('run-profile-locale');
const runProfileReportDir = document.getElementById('run-profile-report-dir');
const runProfileDefaultTimeout = document.getElementById('run-profile-default-timeout');
const runProfileError = document.getElementById('run-profile-error');
const runProfileConfirm = document.getElementById('run-profile-confirm');
const runProfileCancel = document.getElementById('run-profile-cancel');

// 直近受信の一覧(profileInfo 由来)。
let runProfileNames = [];
let runProfileApps = [];
// 編集対象の実行プロファイル名(一覧が0件なら null)。
let selectedRunProfile = null;
// 直近ロード(runProfileData ok:true)時点の10フィールド値。null の間はフォーム非表示。
let runProfileOriginalFields = null;
// 現在チェック済みのデバイス名(表示順。チェックボックス操作・machine切替の引き継ぎの正)。
let runProfileCheckedNames = [];
let runProfileDirty = false;
let runProfileSubmitting = false;

function runProfileEditing() {
  return runProfileDirty || runProfileSubmitting;
}

function refreshRunProfileButtonsUi() {
  runProfileConfirm.disabled = runProfileSubmitting || !runProfileDirty;
  runProfileCancel.style.display = runProfileDirty ? '' : 'none';
  runProfileCancel.disabled = runProfileSubmitting;
}
function setRunProfileDirty(dirty) {
  runProfileDirty = dirty;
  refreshRunProfileButtonsUi();
}

function showRunProfilePlaceholder(text) {
  runProfileOriginalFields = null;
  runProfileSubmitting = false;
  runProfileEditor.style.display = 'none';
  runProfilePlaceholder.style.display = '';
  runProfilePlaceholder.textContent = text;
  setRunProfileDirty(false);
}

function requestRunProfileLoad() {
  if (!selectedRunProfile) {
    showRunProfilePlaceholder(t('wvMonitor2.runProfile.none'));
    return;
  }
  // 応答(runProfileData)が来るまで編集させない(レース防止。ローカル読みなので一瞬で置き換わる)。
  showRunProfilePlaceholder(t('wvMonitor2.common.loading'));
  vscode.postMessage({ type: 'runProfileLoad', profile: selectedRunProfile });
}

// profileInfo 受信(applyProfileInfo と独立)。選択の維持/フォールバックと再ロードを行う。
export function applyRunProfileInfo(message) {
  runProfileNames = Array.isArray(message.profiles) ? message.profiles : [];
  // apps は後方互換(古いホストからは届かない)のため配列でなければ空扱い。
  runProfileApps = Array.isArray(message.apps) ? message.apps : [];
  const current = typeof message.current === 'string' ? message.current : '';

  const previous = selectedRunProfile;
  if (selectedRunProfile === null || !runProfileNames.includes(selectedRunProfile)) {
    if (current !== '' && runProfileNames.includes(current)) {
      selectedRunProfile = current;
    } else {
      selectedRunProfile = runProfileNames.length > 0 ? runProfileNames[0] : null;
    }
  }
  renderRunProfileSelect();
  // [+]は常に有効(追加先は常にある)。コピー/−/✏は対象が要るため一覧0件時は無効化。
  btnRunProfileAdd.disabled = false;
  btnRunProfileCopy.disabled = runProfileNames.length === 0;
  btnRunProfileRemove.disabled = runProfileNames.length === 0;
  btnRunProfileRename.disabled = runProfileNames.length === 0;

  if (selectedRunProfile !== previous) {
    requestRunProfileLoad();
    return;
  }
  // 未編集なら再ロードして最新化(apps一覧の変化もここで反映される)。
  if (selectedRunProfile !== null && !runProfileEditing()) {
    requestRunProfileLoad();
  } else if (selectedRunProfile === null) {
    showRunProfilePlaceholder(t('wvMonitor2.runProfile.none'));
  }
}

function renderRunProfileSelect() {
  if (runProfileNames.length >= 1) {
    runProfileSelect.style.display = '';
    runProfileNameStatic.style.display = 'none';
    runProfileSelect.textContent = '';
    for (const name of runProfileNames) {
      const option = document.createElement('option');
      option.value = name;
      option.textContent = name;
      runProfileSelect.appendChild(option);
    }
    runProfileSelect.value = selectedRunProfile || '';
  } else {
    runProfileSelect.style.display = 'none';
    runProfileNameStatic.style.display = '';
  }
}

runProfileSelect.addEventListener('change', () => {
  selectedRunProfile = runProfileSelect.value;
  requestRunProfileLoad();
});

btnRunProfileAdd.addEventListener('click', () => vscode.postMessage({ type: 'profileAdd' }));
btnRunProfileCopy.addEventListener('click', () => {
  if (selectedRunProfile) {
    vscode.postMessage({ type: 'profileCopy', profile: selectedRunProfile });
  }
});
btnRunProfileRemove.addEventListener('click', () => {
  if (selectedRunProfile) {
    vscode.postMessage({ type: 'profileDelete', profile: selectedRunProfile });
  }
});
btnRunProfileRename.addEventListener('click', () => {
  if (selectedRunProfile) {
    vscode.postMessage({ type: 'profileRename', profile: selectedRunProfile });
  }
});

// 追加/コピー/名前変更直後にhostから届く選択切替通知。postMessageは順序保証されるため単純に
// 上書きでよいが、一覧に無い名前は無視するガードを入れる。
export function applyRunProfileSelected(message) {
  if (!runProfileNames.includes(message.name)) {
    return;
  }
  selectedRunProfile = message.name;
  renderRunProfileSelect();
  requestRunProfileLoad();
}

// main.js の machineProfileInfo 受信時に呼ばれる。未編集ならマシン/デバイス一覧の変化を反映して再描画。
export function rerenderRunProfileFormIfClean() {
  if (runProfileOriginalFields !== null && !runProfileEditing()) {
    renderRunProfileEditor(runProfileOriginalFields);
  }
}

// 選択変更直後に届く「前の選択」への応答を無視するガード(profile一致チェック)。
export function applyRunProfileData(message) {
  if (message.profile !== selectedRunProfile) {
    return;
  }
  // 編集中(dirty/送信中)は反映しない(保存成功直後の再送は dirty 解除済みなので反映される)。
  if (runProfileEditing()) {
    return;
  }
  if (!message.ok || !message.fields) {
    showRunProfilePlaceholder(message.error || t('wvMonitor2.runProfile.loadFailed'));
    return;
  }
  renderRunProfileEditor(message.fields);
}

// ロード済みの10フィールド値でフォームを作り直す(編集途中の値は破棄する)。
function renderRunProfileEditor(fields) {
  runProfileOriginalFields = fields;
  runProfileSubmitting = false;
  runProfileError.textContent = '';

  renderRunProfileMachineSelect(fields.machine);
  renderRunProfileAppSelect(fields.app);
  runProfileCheckedNames = fields.devices.slice();
  renderRunProfileDevices();
  runProfileHeal.checked = fields.heal;
  runProfileIosInappEngine.checked = fields.iosInappEngine;
  runProfileWipeDataOnBloat.checked = fields.wipeDataOnBloat;
  runProfileRecord.checked = fields.record;
  runProfileWipeThreshold.value = fields.wipeDataThresholdGB;
  runProfileLocale.value = fields.locale;
  runProfileReportDir.value = fields.reportDir;
  runProfileDefaultTimeout.value = fields.defaultTimeout;

  setRunProfileControlsEnabled(true);
  runProfileConfirm.textContent = t('wvMonitor2.common.confirm');
  runProfilePlaceholder.style.display = 'none';
  runProfileEditor.style.display = '';
  setRunProfileDirty(false);
}

// 選択肢=machineProfilesの名前。未指定("")/一覧に無い値は「(未指定)」を先頭に、非空の未知値は
// オプション補完で表示する(unknownOptionパターン、deviceTiles.applyProfileInfoと同じ)。
function renderRunProfileMachineSelect(value) {
  runProfileMachine.textContent = '';
  const names = machineProfiles.map((m) => m.name);
  if (value === '' || !names.includes(value)) {
    const unspecified = document.createElement('option');
    unspecified.value = '';
    unspecified.textContent = t('wvMonitor2.common.unspecified');
    runProfileMachine.appendChild(unspecified);
  }
  for (const name of names) {
    const option = document.createElement('option');
    option.value = name;
    option.textContent = name;
    runProfileMachine.appendChild(option);
  }
  if (value !== '' && !names.includes(value)) {
    const unknown = document.createElement('option');
    unknown.value = value;
    unknown.textContent = value;
    runProfileMachine.appendChild(unknown);
  }
  runProfileMachine.value = value;
}

// 「アプリ」select。選択肢 = profileInfo.apps。現在値が一覧に無ければオプション補完する。
function renderRunProfileAppSelect(value) {
  runProfileApp.textContent = '';
  let matched = value === '';
  // 空文字(未指定)を常に先頭に置く(app欠落プロファイルの現在値を表す。空のまま確定は検証で弾かれる)。
  const emptyOption = document.createElement('option');
  emptyOption.value = '';
  emptyOption.textContent = t('wvMonitor2.common.unspecified');
  runProfileApp.appendChild(emptyOption);
  for (const name of runProfileApps) {
    const option = document.createElement('option');
    option.value = name;
    option.textContent = name;
    runProfileApp.appendChild(option);
    if (name === value) {
      matched = true;
    }
  }
  if (!matched) {
    const unknown = document.createElement('option');
    unknown.value = value;
    unknown.textContent = value;
    runProfileApp.appendChild(unknown);
  }
  runProfileApp.value = value;
}

// 選択肢=フォーム内選択中マシンのデバイス。checkedNamesにあるがマシンに無い名前は注記付きで
// 末尾表示(チェックを外せば確定時に除去される)。マシン未指定("")の間は案内のみ表示。
function renderRunProfileDevices() {
  runProfileDevices.textContent = '';
  const machineName = runProfileMachine.value;
  if (machineName === '') {
    const note = document.createElement('div');
    note.className = 'run-profile-device-note';
    note.textContent = t('wvMonitor2.runProfile.selectMachineFirst');
    runProfileDevices.appendChild(note);
    return;
  }
  const machine = findMachine(machineName);
  const machineDevices = machine ? machine.devices : [];
  const machineDeviceNames = machineDevices.map((d) => d.name);
  const appendRow = (name, platform, missing) => {
    const row = document.createElement('label');
    row.className = 'run-profile-device-row';
    const checkbox = document.createElement('input');
    checkbox.type = 'checkbox';
    checkbox.checked = runProfileCheckedNames.includes(name);
    checkbox.dataset.deviceName = name;
    checkbox.addEventListener('change', onRunProfileDeviceToggle);
    const pill = document.createElement('span');
    // タイル/レーンと同じ配色ピル。マシンに無い名前は不明色(tile-name-unknown)。
    pill.className = 'tile-name ' + (platform ? 'tile-name-' + platform : 'tile-name-unknown');
    pill.textContent = name;
    row.append(checkbox, pill);
    if (missing) {
      const note = document.createElement('span');
      note.className = 'run-profile-device-note';
      note.textContent = t('wvMonitor2.runProfile.deviceMissingFromMachine');
      row.appendChild(note);
    }
    runProfileDevices.appendChild(row);
  };
  for (const device of machineDevices) {
    appendRow(device.name, device.platform, false);
  }
  for (const name of runProfileCheckedNames) {
    if (!machineDeviceNames.includes(name)) {
      appendRow(name, null, true);
    }
  }
}

// チェックボックス操作: DOM の表示順(マシンのデバイス順+欠落分)で checked を集め直す。
function onRunProfileDeviceToggle() {
  const checked = [];
  for (const checkbox of runProfileDevices.querySelectorAll('input[type="checkbox"]')) {
    if (checkbox.checked) {
      checked.push(checkbox.dataset.deviceName);
    }
  }
  runProfileCheckedNames = checked;
  onRunProfileFormInput();
}

// マシン切替: チェック状態(runProfileCheckedNames)は名前で引き継いだまま一覧を作り直す。
runProfileMachine.addEventListener('change', () => {
  renderRunProfileDevices();
  onRunProfileFormInput();
});
runProfileApp.addEventListener('change', onRunProfileFormInput);
runProfileHeal.addEventListener('change', onRunProfileFormInput);
runProfileIosInappEngine.addEventListener('change', onRunProfileFormInput);
runProfileWipeDataOnBloat.addEventListener('change', onRunProfileFormInput);
runProfileRecord.addEventListener('change', onRunProfileFormInput);
runProfileWipeThreshold.addEventListener('input', onRunProfileFormInput);
runProfileLocale.addEventListener('input', onRunProfileFormInput);
runProfileReportDir.addEventListener('input', onRunProfileFormInput);
runProfileDefaultTimeout.addEventListener('input', onRunProfileFormInput);

// devicesは集合比較(順序無視)。マシンのデバイス順とプロファイル記載順は独立なため、配列比較だと
// チェック操作なしでdirtyになってしまう。
function runProfileDevicesEqual(a, b) {
  if (a.length !== b.length) {
    return false;
  }
  const setB = new Set(b);
  return a.every((name) => setB.has(name));
}

function runProfileValuesEqual(fields) {
  return (
    runProfileMachine.value === fields.machine &&
    runProfileApp.value === fields.app &&
    runProfileDevicesEqual(runProfileCheckedNames, fields.devices) &&
    runProfileHeal.checked === fields.heal &&
    runProfileIosInappEngine.checked === fields.iosInappEngine &&
    runProfileWipeDataOnBloat.checked === fields.wipeDataOnBloat &&
    runProfileRecord.checked === fields.record &&
    runProfileWipeThreshold.value === fields.wipeDataThresholdGB &&
    runProfileLocale.value === fields.locale &&
    runProfileReportDir.value === fields.reportDir &&
    runProfileDefaultTimeout.value === fields.defaultTimeout
  );
}

function onRunProfileFormInput() {
  if (runProfileOriginalFields === null || runProfileSubmitting) {
    return;
  }
  setRunProfileDirty(!runProfileValuesEqual(runProfileOriginalFields));
  // 入力を変えたら前回のエラー表示は古くなるので消す。
  runProfileError.textContent = '';
}

function setRunProfileControlsEnabled(enabled) {
  runProfileMachine.disabled = !enabled;
  runProfileApp.disabled = !enabled;
  runProfileHeal.disabled = !enabled;
  runProfileIosInappEngine.disabled = !enabled;
  runProfileWipeDataOnBloat.disabled = !enabled;
  runProfileRecord.disabled = !enabled;
  runProfileWipeThreshold.disabled = !enabled;
  runProfileLocale.disabled = !enabled;
  runProfileReportDir.disabled = !enabled;
  runProfileDefaultTimeout.disabled = !enabled;
  for (const checkbox of runProfileDevices.querySelectorAll('input[type="checkbox"]')) {
    checkbox.disabled = !enabled;
  }
}

// クライアント検証(確定時)。問題なければ null。
function validateRunProfileFields() {
  const machine = runProfileMachine.value.trim();
  if (machine === '') {
    return t('wvMonitor2.runProfile.validation.machineRequired');
  }
  if (!findMachine(machine)) {
    return t('wvMonitor2.runProfile.validation.machineNotFound', { machine });
  }
  if (runProfileApp.value.trim() === '') {
    return t('wvMonitor2.runProfile.validation.appRequired');
  }
  if (runProfileCheckedNames.length === 0) {
    return t('wvMonitor2.runProfile.validation.deviceRequired');
  }
  const timeout = runProfileDefaultTimeout.value.trim();
  if (timeout !== '' && (!/^\d+$/.test(timeout) || Number(timeout) <= 0)) {
    return t('wvMonitor2.runProfile.validation.timeoutInvalid');
  }
  const threshold = runProfileWipeThreshold.value.trim();
  if (threshold !== '' && (!/^\d+(\.\d+)?$/.test(threshold) || Number(threshold) <= 0)) {
    return t('wvMonitor2.runProfile.validation.wipeThresholdInvalid');
  }
  const locale = runProfileLocale.value.trim();
  if (locale !== '' && !/^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$/.test(locale)) {
    return t('wvMonitor2.runProfile.validation.localeInvalid');
  }
  return null;
}

runProfileConfirm.addEventListener('click', () => {
  if (runProfileConfirm.disabled || runProfileSubmitting || !selectedRunProfile) {
    return;
  }
  const validationError = validateRunProfileFields();
  if (validationError) {
    runProfileError.textContent = validationError;
    return;
  }
  runProfileSubmitting = true;
  setRunProfileControlsEnabled(false);
  runProfileConfirm.textContent = t('wvMonitor2.common.confirming');
  runProfileError.textContent = '';
  refreshRunProfileButtonsUi();
  vscode.postMessage({
    type: 'runProfileSave',
    profile: selectedRunProfile,
    fields: {
      machine: runProfileMachine.value.trim(),
      app: runProfileApp.value.trim(),
      devices: runProfileCheckedNames.slice(),
      heal: runProfileHeal.checked,
      iosInappEngine: runProfileIosInappEngine.checked,
      wipeDataOnBloat: runProfileWipeDataOnBloat.checked,
      record: runProfileRecord.checked,
      wipeDataThresholdGB: runProfileWipeThreshold.value.trim(),
      locale: runProfileLocale.value.trim(),
      reportDir: runProfileReportDir.value.trim(),
      defaultTimeout: runProfileDefaultTimeout.value.trim(),
    },
  });
});

// requestRunProfileLoad内部でshowRunProfilePlaceholder→setRunProfileDirty(false)の順に呼ばれるため、
// dirty解除→再ロードの順序が保たれる(順序を崩すとapplyRunProfileDataの編集中ガードに阻まれる)。
runProfileCancel.addEventListener('click', () => {
  if (runProfileCancel.disabled) {
    return;
  }
  runProfileError.textContent = '';
  requestRunProfileLoad();
});

// ok:trueなら続けてhostからrunProfileDataが来てフォームが最新化される。ok:falseはエラー表示のみ。
export function applyRunProfileSaveResult(message) {
  if (message.profile !== selectedRunProfile) {
    return;
  }
  runProfileSubmitting = false;
  runProfileConfirm.textContent = t('wvMonitor2.common.confirm');
  setRunProfileControlsEnabled(true);
  if (message.ok) {
    runProfileError.textContent = '';
    setRunProfileDirty(false);
  } else {
    refreshRunProfileButtonsUi();
    runProfileError.textContent = message.error || t('wvMonitor2.runProfile.saveFailed');
  }
}

// runs/<name>.json の外部編集(watcher onDidChange)。自分の保存直後の通知も来るが再ロードは冪等。
export function applyRunProfileFileChanged(message) {
  if (message.name === selectedRunProfile && !runProfileEditing()) {
    vscode.postMessage({ type: 'runProfileLoad', profile: selectedRunProfile });
  }
}
