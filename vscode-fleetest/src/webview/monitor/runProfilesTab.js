// machineProfiles/findMachine(machineProfilesTab.js の状態)はここでは読み取り専用。

import { vscode } from './vscodeApi.js';
import { machineProfiles, findMachine } from './machineProfilesTab.js';
import { t } from '../i18n.js';

// 選択は「編集対象」であり、「テスト実行」タブの実行プロファイル選択(fleetest.profile)とは独立。
// 自動保存(確定ボタンは無い): チェック/選択は change で即、テキストは change(= blur か Enter で
// 入力を終えたとき)で runProfileSave を送る。dirty = フォーム値と runProfileOriginalFields
// (直近に保存/ロードした値)の差。検証で弾かれた値は dirty のまま残り、エラーを出す。
// - 送信中もコントロールは無効化しない(無効化するとフォーカスが外れ、Tab で次の欄へ移った入力が
//   途切れる)。送信中に確定した変更は runProfileSaveQueued に積み、結果の到着後にもう1回送る
//   (並行に2本送らない = 後の保存が先に着いて古い値で上書きされる順序逆転を作らない)。
// - 選択変更(明示操作)と Esc は未保存の編集を破棄して再ロード。
// - profileInfo/machineProfileInfo 再受信時: 編集中なら保持、未編集なら再ロード(消失時はcurrent→先頭)。
// - runProfileFileChanged(外部編集・自分の保存の反響)は同名 && 未編集のときのみ再ロード。

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
const runProfileFm = document.getElementById('run-profile-fm');
const runProfileFmOptions = document.getElementById('run-profile-fm-options');
const runProfileHeal = document.getElementById('run-profile-heal');
const runProfileFalsePositiveCheck = document.getElementById('run-profile-false-positive-check');
const runProfileTriage = document.getElementById('run-profile-triage');
const runProfileScreenLooksLike = document.getElementById('run-profile-screen-looks-like');
const runProfileOcr = document.getElementById('run-profile-ocr');
const runProfileOcrOptions = document.getElementById('run-profile-ocr-options');
const runProfileOcrFalsePositiveCheck = document.getElementById('run-profile-ocr-false-positive-check');
const runProfileContainerInference = document.getElementById('run-profile-container-inference');
const runProfileIosInappEngine = document.getElementById('run-profile-ios-inapp-engine');
const runProfileIosFastInput = document.getElementById('run-profile-ios-fast-input');
const runProfileIosPreActionWarmup = document.getElementById('run-profile-ios-pre-action-warmup');
const runProfileInappOptions = document.getElementById('run-profile-inapp-options');
const runProfileHomeOnStart = document.getElementById('run-profile-home-on-start');
const runProfilePlayProtectBypass = document.getElementById('run-profile-play-protect-bypass');
const runProfileEnableAnimations = document.getElementById('run-profile-enable-animations');
const runProfileUpdateWebView = document.getElementById('run-profile-update-webview');
const runProfileWipeDataOnBloat = document.getElementById('run-profile-wipe-data-on-bloat');
const runProfileRecoverCpuFallback = document.getElementById('run-profile-recover-cpu-fallback');
const runProfileRecord = document.getElementById('run-profile-record');
const runProfileRecordOptions = document.getElementById('run-profile-record-options');
const runProfileRecordFailuresOnly = document.getElementById('run-profile-record-failures-only');
const runProfileRecordBitrate = document.getElementById('run-profile-record-bitrate');
const runProfileRecordFullResolution = document.getElementById('run-profile-record-full-resolution');
const runProfileWipeThreshold = document.getElementById('run-profile-wipe-threshold');
const runProfileLocale = document.getElementById('run-profile-locale');
const runProfileWorkspace = document.getElementById('run-profile-workspace');
const btnRunProfileHookScaffold = document.getElementById('btn-run-profile-hook-scaffold');
const runProfileReportDir = document.getElementById('run-profile-report-dir');
const runProfileDefaultTimeout = document.getElementById('run-profile-default-timeout');
const runProfileError = document.getElementById('run-profile-error');
// 保存時に前後の空白を落として書き戻す欄(送る値と画面の値を一致させ、保存後に dirty が残らないように)
const runProfileTextInputs = [
  runProfileRecordBitrate, runProfileWipeThreshold, runProfileLocale,
  runProfileWorkspace, runProfileReportDir, runProfileDefaultTimeout,
];

// 直近受信の一覧(profileInfo 由来)。
let runProfileNames = [];
let runProfileApps = [];
// 編集対象の実行プロファイル名(一覧が0件なら null)。
let selectedRunProfile = null;
// 直近ロード(runProfileData ok:true)時点の20フィールド値。null の間はフォーム非表示。
let runProfileOriginalFields = null;
// 現在チェック済みのデバイス参照 { name, machine }(表示順。チェックボックス操作・machine 切替の
// 引き継ぎの正)。**一意なのは (machine, name)** なので名前だけでは持てない
let runProfileCheckedRefs = [];
let runProfileDirty = false;
let runProfileSubmitting = false;
// 送信中(runProfileSubmitting)の保存要求が送った値。成功したらこれが新しい runProfileOriginalFields。
let runProfileSubmittedFields = null;
let runProfileSaveQueued = false;

function runProfileEditing() {
  return runProfileDirty || runProfileSubmitting;
}

function setRunProfileDirty(dirty) {
  runProfileDirty = dirty;
}

function showRunProfilePlaceholder(text) {
  runProfileOriginalFields = null;
  runProfileSubmitting = false;
  runProfileSubmittedFields = null;
  runProfileSaveQueued = false;
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
  // ワークスペース未入力時の既定を透かしで出す。相対パスはリポジトリルート基準なので、
  // この文字列はそのまま入力しても既定と同じ場所を指す(Sources/FTCore/RunProfile.swift の
  // ProfileResolver.resolveWorkspaceRoot と同期)。project が解決できないホストでは出さない
  const project = typeof message.project === 'string' ? message.project : '';
  runProfileWorkspace.placeholder = project === '' ? '' : `TestProjects/${project}/workspace`;
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
  // 自動保存のたびに保存結果の反響として届く。画面と同じ値なら作り直さない(作り直すとデバイスの
  // チェックボックスが作り直され、今触っている欄からフォーカスが外れる)
  if (runProfileOriginalFields !== null && runProfileValuesEqual(message.fields)) {
    runProfileOriginalFields = message.fields;
    return;
  }
  renderRunProfileEditor(message.fields);
}

// ロード済みの20フィールド値でフォームを作り直す(編集途中の値は破棄する)。
function renderRunProfileEditor(fields) {
  runProfileOriginalFields = fields;
  runProfileSubmitting = false;
  runProfileSubmittedFields = null;
  runProfileSaveQueued = false;
  runProfileError.textContent = '';

  renderRunProfileMachineSelect(fields.machine);
  renderRunProfileAppSelect(fields.app);
  runProfileCheckedRefs = fields.devices.map((d) => ({ name: d.name, machine: d.machine }));
  renderRunProfileDevices();
  runProfileFm.checked = fields.fm;
  runProfileHeal.checked = fields.heal;
  runProfileFalsePositiveCheck.checked = fields.falsePositiveCheck;
  runProfileTriage.checked = fields.triage;
  runProfileScreenLooksLike.checked = fields.screenLooksLike;
  runProfileOcr.checked = fields.ocr;
  runProfileOcrFalsePositiveCheck.checked = fields.ocrFalsePositiveCheck;
  updateFmOptionsVisibility();
  updateOcrOptionsVisibility();
  updateInappOptionsVisibility();
  runProfileIosInappEngine.checked = fields.iosInappEngine;
  runProfileIosFastInput.checked = fields.iosFastInput;
  runProfileIosPreActionWarmup.checked = fields.iosPreActionWarmup;
  runProfileHomeOnStart.checked = fields.homeOnStart;
  runProfilePlayProtectBypass.checked = fields.playProtectBypass;
  runProfileEnableAnimations.checked = fields.enableAnimations;
  runProfileContainerInference.checked = fields.containerInference;
  runProfileUpdateWebView.checked = fields.updateWebView;
  runProfileWipeDataOnBloat.checked = fields.wipeDataOnBloat;
  runProfileRecoverCpuFallback.checked = fields.recoverCpuFallbackToGpu;
  runProfileRecord.checked = fields.record;
  runProfileRecordFailuresOnly.checked = fields.recordFailuresOnly;
  runProfileRecordBitrate.value = fields.recordBitrateKbps;
  runProfileRecordFullResolution.checked = fields.recordFullResolution;
  updateRecordOptionsVisibility();
  runProfileWipeThreshold.value = fields.wipeDataThresholdGB;
  runProfileLocale.value = fields.locale;
  runProfileWorkspace.value = fields.workspace;
  runProfileReportDir.value = fields.reportDir;
  runProfileDefaultTimeout.value = fields.defaultTimeout;

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
  // 空文字(未指定)を常に先頭に置く(app欠落プロファイルの現在値を表す。空のままの保存は検証で弾かれる)。
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
// 末尾表示(チェックを外せば保存時に除去される)。マシン未指定("")の間は案内のみ表示。
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
  // 並び順はマシンプロファイルと同じ(config.ts の listMachineProfiles が
  // 手元 → ホスト名順、その中で名前順に並べたもの)。ここでは並べ替えない
  const machineDevices = machine ? machine.devices : [];
  const appendRow = (name, machine, platform, kind, missing) => {
    const row = document.createElement('label');
    row.className = 'run-profile-device-row';
    const checkbox = document.createElement('input');
    checkbox.type = 'checkbox';
    checkbox.checked = runProfileCheckedRefs.some((r) => refKey(r) === refKey({ name, machine }));
    checkbox.dataset.deviceName = name;
    // **参照は (machine, name)**。名前だけを保存すると、同名が別マシンに並ぶプロファイルで
    // どちらのデバイスか決まらない(run が候補を挙げて止まる)
    if (machine) {
      checkbox.dataset.deviceMachine = machine;
    }
    checkbox.addEventListener('change', onRunProfileDeviceToggle);
    const pill = document.createElement('span');
    // タイル/レーンと同じ配色ピル。マシンに無い名前は不明色(tile-name-unknown)。
    pill.className = 'tile-name ' + (platform ? 'tile-name-' + platform : 'tile-name-unknown');
    pill.textContent = name;
    row.append(checkbox);
    // 実機バッジはデバイス名の左(マシンプロファイル一覧・ピッカー・タイルと同じ配色 .badge-kind)
    if (kind === 'physical') {
      const kindBadge = document.createElement('span');
      kindBadge.className = 'badge badge-kind';
      kindBadge.textContent = t('wvMonitor.tile.physicalBadge');
      row.appendChild(kindBadge);
    }
    row.appendChild(pill);
    // 手元でないデバイスは名前の右にマシン名(マシンプロファイルの一覧と同じバッジ)
    if (machine) {
      const badge = document.createElement('span');
      badge.className = 'badge badge-remote';
      badge.textContent = machine;
      row.appendChild(badge);
    }
    if (missing) {
      const note = document.createElement('span');
      note.className = 'run-profile-device-note';
      note.textContent = t('wvMonitor2.runProfile.deviceMissingFromMachine');
      row.appendChild(note);
    }
    runProfileDevices.appendChild(row);
  };
  const machineKeys = new Set(machineDevices.map((d) => refKey({ name: d.name, machine: d.machine })));
  for (const device of machineDevices) {
    appendRow(device.name, device.machine, device.platform, device.kind, false);
  }
  for (const ref of runProfileCheckedRefs) {
    if (!machineKeys.has(refKey(ref))) {
      appendRow(ref.name, ref.machine, null, null, true);
    }
  }
}

// デバイス参照の同一性。**一意なのは (machine, name)**(machine 省略=手元)
function refKey(ref) {
  return `${ref.machine ?? ''}\t${ref.name}`;
}

// チェックボックス操作: DOM の表示順(マシンのデバイス順+欠落分)で checked を集め直す。
function onRunProfileDeviceToggle() {
  const checked = [];
  for (const checkbox of runProfileDevices.querySelectorAll('input[type="checkbox"]')) {
    if (checkbox.checked) {
      checked.push({ name: checkbox.dataset.deviceName, machine: checkbox.dataset.deviceMachine });
    }
  }
  runProfileCheckedRefs = checked;
}

// マシン切替: チェック状態(runProfileCheckedRefs)は (machine, name) で引き継いだまま一覧を作り直す。
runProfileMachine.addEventListener('change', () => {
  renderRunProfileDevices();
});
// fm ON のときだけ配下のサブオプション(heal/falsePositiveCheck/screenLooksLike)を表示する
// (値そのものは fm の状態に関わらず保持・保存する)。
function updateFmOptionsVisibility() {
  runProfileFmOptions.style.display = runProfileFm.checked ? '' : 'none';
}
runProfileFm.addEventListener('change', () => {
  updateFmOptionsVisibility();
});
// ocr ON のときだけ配下のサブオプションを表示する(値は親の状態に関わらず保持・保存する)
function updateOcrOptionsVisibility() {
  runProfileOcrOptions.style.display = runProfileOcr.checked ? '' : 'none';
}
runProfileOcr.addEventListener('change', () => {
  updateOcrOptionsVisibility();
});
// inapp エンジン ON のときだけ配下のサブオプション(iosPreActionWarmup)を表示する
// (暖機は hybrid の domInterop 経路にしか無い = xcuitest エンジンでは効果が無いため。
//  値そのものはエンジンの状態に関わらず保持・保存する = FM サブオプションと同じ方針)。
function updateInappOptionsVisibility() {
  runProfileInappOptions.style.display = runProfileIosInappEngine.checked ? '' : 'none';
}
runProfileIosInappEngine.addEventListener('change', () => {
  updateInappOptionsVisibility();
});
// record ON のときだけ配下のサブオプション(recordFailuresOnly/recordBitrateKbps/
// recordFullResolution)を表示する(値そのものは record の状態に関わらず保持・保存する)。
function updateRecordOptionsVisibility() {
  runProfileRecordOptions.style.display = runProfileRecord.checked ? '' : 'none';
}
runProfileRecord.addEventListener('change', () => {
  updateRecordOptionsVisibility();
});

// 雛形の作成はフォームの値ではなくファイルを作る操作なので dirty にしない。ワークスペースは
// **入力中の値**を送る(検証で弾かれて未保存でも、画面に見えている場所へ作られる)
btnRunProfileHookScaffold.addEventListener('click', () => {
  if (btnRunProfileHookScaffold.disabled || !selectedRunProfile) {
    return;
  }
  vscode.postMessage({
    type: 'runProfileHookScaffold',
    profile: selectedRunProfile,
    workspace: runProfileWorkspace.value.trim(),
  });
});

// devicesは集合比較(順序無視)。マシンのデバイス順とプロファイル記載順は独立なため、配列比較だと
// チェック操作なしでdirtyになってしまう。
function runProfileDevicesEqual(a, b) {
  if (a.length !== b.length) {
    return false;
  }
  const setB = new Set(b.map(refKey));
  return a.every((ref) => setB.has(refKey(ref)));
}

function runProfileValuesEqual(fields) {
  return (
    runProfileMachine.value === fields.machine &&
    runProfileApp.value === fields.app &&
    runProfileDevicesEqual(runProfileCheckedRefs, fields.devices) &&
    runProfileFm.checked === fields.fm &&
    runProfileHeal.checked === fields.heal &&
    runProfileFalsePositiveCheck.checked === fields.falsePositiveCheck &&
    runProfileTriage.checked === fields.triage &&
    runProfileScreenLooksLike.checked === fields.screenLooksLike &&
    runProfileOcr.checked === fields.ocr &&
    runProfileOcrFalsePositiveCheck.checked === fields.ocrFalsePositiveCheck &&
    runProfileIosInappEngine.checked === fields.iosInappEngine &&
    runProfileIosFastInput.checked === fields.iosFastInput &&
    runProfileIosPreActionWarmup.checked === fields.iosPreActionWarmup &&
    runProfileHomeOnStart.checked === fields.homeOnStart &&
    runProfilePlayProtectBypass.checked === fields.playProtectBypass &&
    runProfileEnableAnimations.checked === fields.enableAnimations &&
    runProfileContainerInference.checked === fields.containerInference &&
    runProfileUpdateWebView.checked === fields.updateWebView &&
    runProfileWipeDataOnBloat.checked === fields.wipeDataOnBloat &&
    runProfileRecoverCpuFallback.checked === fields.recoverCpuFallbackToGpu &&
    runProfileRecord.checked === fields.record &&
    runProfileRecordFailuresOnly.checked === fields.recordFailuresOnly &&
    runProfileRecordBitrate.value === fields.recordBitrateKbps &&
    runProfileRecordFullResolution.checked === fields.recordFullResolution &&
    runProfileWipeThreshold.value === fields.wipeDataThresholdGB &&
    runProfileLocale.value === fields.locale &&
    runProfileWorkspace.value === fields.workspace &&
    runProfileReportDir.value === fields.reportDir &&
    runProfileDefaultTimeout.value === fields.defaultTimeout
  );
}

function onRunProfileFormInput() {
  if (runProfileOriginalFields === null) {
    return;
  }
  setRunProfileDirty(!runProfileValuesEqual(runProfileOriginalFields));
  // 入力を変えたら前回のエラー表示は古くなるので消す。
  runProfileError.textContent = '';
}

// クライアント検証(保存前)。問題なければ null。
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
  if (runProfileCheckedRefs.length === 0) {
    return t('wvMonitor2.runProfile.validation.deviceRequired');
  }
  // 1台もこのマシンに無い参照は保存しない: `api monitor` / run が noDevicesInMachineProfile で落ちる
  // (Sources/FTCore/RunProfileScope.swift)。**マシンを切り替えた直後は前のマシンの参照が残る**ので、
  // 自動保存だとこれが無いと切り替えた瞬間に壊れたプロファイルを書く。一部だけ無いのは許す
  // (monitor/run は警告して続行する。「マシンに無い」の注記と同じ判定)
  const machineKeys = new Set(findMachine(machine).devices.map((d) => refKey({ name: d.name, machine: d.machine })));
  if (!runProfileCheckedRefs.some((ref) => machineKeys.has(refKey(ref)))) {
    return t('wvMonitor2.runProfile.validation.noDeviceOnMachine', { machine });
  }
  const timeout = runProfileDefaultTimeout.value.trim();
  if (timeout !== '' && (!/^\d+(\.\d+)?$/.test(timeout) || Number(timeout) <= 0)) {
    return t('wvMonitor2.runProfile.validation.timeoutInvalid');
  }
  const threshold = runProfileWipeThreshold.value.trim();
  if (threshold !== '' && (!/^\d+(\.\d+)?$/.test(threshold) || Number(threshold) <= 0)) {
    return t('wvMonitor2.runProfile.validation.wipeThresholdInvalid');
  }
  const bitrate = runProfileRecordBitrate.value.trim();
  if (bitrate !== '' && (!/^\d+$/.test(bitrate) || Number(bitrate) <= 0)) {
    return t('wvMonitor2.runProfile.validation.recordBitrateInvalid');
  }
  const locale = runProfileLocale.value.trim();
  if (locale !== '' && !/^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$/.test(locale)) {
    return t('wvMonitor2.runProfile.validation.localeInvalid');
  }
  return null;
}

// 入力を終えたとき(change)に呼ぶ。未編集なら何もしない・送信中なら結果の到着後へ回す。
function saveRunProfileIfDirty() {
  if (runProfileOriginalFields === null || !selectedRunProfile) {
    return;
  }
  if (runProfileSubmitting) {
    runProfileSaveQueued = true;
    return;
  }
  runProfileSaveQueued = false;
  if (!runProfileDirty) {
    return;
  }
  const validationError = validateRunProfileFields();
  if (validationError) {
    runProfileError.textContent = validationError;
    return;
  }
  for (const input of runProfileTextInputs) {
    const trimmed = input.value.trim();
    if (input.value !== trimmed) {
      input.value = trimmed;
    }
  }
  runProfileSubmitting = true;
  runProfileSubmittedFields = collectRunProfileFields();
  runProfileError.textContent = '';
  vscode.postMessage({ type: 'runProfileSave', profile: selectedRunProfile, fields: runProfileSubmittedFields });
}

// runProfileSave の fields(monitorWebviewMessages.ts の検証と対)。text 系は trim 済み。
function collectRunProfileFields() {
  return {
    machine: runProfileMachine.value.trim(),
    app: runProfileApp.value.trim(),
    devices: runProfileCheckedRefs.map((r) => (r.machine ? { name: r.name, machine: r.machine } : { name: r.name })),
    fm: runProfileFm.checked,
    heal: runProfileHeal.checked,
    falsePositiveCheck: runProfileFalsePositiveCheck.checked,
    triage: runProfileTriage.checked,
    screenLooksLike: runProfileScreenLooksLike.checked,
    ocr: runProfileOcr.checked,
    ocrFalsePositiveCheck: runProfileOcrFalsePositiveCheck.checked,
    iosInappEngine: runProfileIosInappEngine.checked,
    iosFastInput: runProfileIosFastInput.checked,
    iosPreActionWarmup: runProfileIosPreActionWarmup.checked,
    homeOnStart: runProfileHomeOnStart.checked,
    playProtectBypass: runProfilePlayProtectBypass.checked,
    enableAnimations: runProfileEnableAnimations.checked,
    containerInference: runProfileContainerInference.checked,
    updateWebView: runProfileUpdateWebView.checked,
    wipeDataOnBloat: runProfileWipeDataOnBloat.checked,
    recoverCpuFallbackToGpu: runProfileRecoverCpuFallback.checked,
    record: runProfileRecord.checked,
    recordFailuresOnly: runProfileRecordFailuresOnly.checked,
    recordBitrateKbps: runProfileRecordBitrate.value.trim(),
    recordFullResolution: runProfileRecordFullResolution.checked,
    wipeDataThresholdGB: runProfileWipeThreshold.value.trim(),
    locale: runProfileLocale.value.trim(),
    workspace: runProfileWorkspace.value.trim(),
    reportDir: runProfileReportDir.value.trim(),
    defaultTimeout: runProfileDefaultTimeout.value.trim(),
  };
}

// dirty の更新と保存はフォーム全体でバブリングで受ける(欄ごとに購読すると付け忘れた欄の変更が
// 保存されない。実際に homeOnStart/playProtectBypass/updateWebView が漏れていた)。各欄の固有の
// リスナー(表示切替・デバイス一覧の作り直し)は target で先に走るので、ここは確定後の値を見る。
// 保存の契機は change だけ —— input(打鍵ごと)では送らない = 入力途中の値を検証してエラーを
// 出したり書き込んだりしない。
runProfileEditor.addEventListener('input', onRunProfileFormInput);
runProfileEditor.addEventListener('change', () => {
  onRunProfileFormInput();
  saveRunProfileIfDirty();
});

// Enter = テキスト欄の入力を終えて保存 / Esc = 未保存の編集(検証で弾かれた値)を破棄して再ロード。
// フォーカスがセクション内にある間だけ効く(セクション要素で bubbling を受けるためモーダル側の
// document レベル Esc リスナーとは衝突しない)。
document.getElementById('run-profile-section').addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && event.target.matches('input[type="text"]')) {
    event.preventDefault();
    saveRunProfileIfDirty();
  } else if (event.key === 'Escape' && runProfileDirty && !runProfileSubmitting) {
    event.preventDefault();
    runProfileError.textContent = '';
    requestRunProfileLoad();
  }
});

// ok:trueなら続けてhostからrunProfileDataが来る(値が画面と同じなら作り直さない)。ok:falseはエラー表示のみで
// 入力値は保持する(dirty のまま)。
export function applyRunProfileSaveResult(message) {
  if (message.profile !== selectedRunProfile || !runProfileSubmitting) {
    return;
  }
  runProfileSubmitting = false;
  if (message.ok) {
    runProfileOriginalFields = runProfileSubmittedFields;
    runProfileError.textContent = '';
  } else {
    runProfileError.textContent = message.error || t('wvMonitor2.runProfile.saveFailed');
  }
  runProfileSubmittedFields = null;
  setRunProfileDirty(!runProfileValuesEqual(runProfileOriginalFields));
  if (runProfileSaveQueued) {
    saveRunProfileIfDirty();
  }
}

// runs/<name>.json の外部編集(watcher onDidChange)。自分の保存直後の通知も来るが再ロードは冪等。
export function applyRunProfileFileChanged(message) {
  if (message.name === selectedRunProfile && !runProfileEditing()) {
    vscode.postMessage({ type: 'runProfileLoad', profile: selectedRunProfile });
  }
}
