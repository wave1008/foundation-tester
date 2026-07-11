// runProfilesTab.js
// 「プロファイル」タブ上段の「実行プロファイル」設定フォームを担う。Phase 3(main.js の
// モジュール分割)で main.js の「---- プロファイルタブ上段: 実行プロファイルの設定フォーム
// ----」節から抽出した。マシンプロファイルの一覧(machineProfiles)・検索(findMachine)は
// machineProfilesTab.js の状態を読み取り専用で参照する(このモジュール側では書き換えない)。

import { vscode } from './vscodeApi.js';
import { machineProfiles, findMachine } from './machineProfilesTab.js';

// ---- プロファイルタブ上段: 実行プロファイルの設定フォーム -----------------------
// 一覧・初期選択は既存 profileInfo(applyProfileInfo とは独立に applyRunProfileInfo で受ける)。
// この選択は「編集対象」であり ftester.profile 設定には触れない(デバイスタブのドロップダウン
// とは独立)。dirty 管理はマシンプロファイルのデバイス編集フォームと同じ方針:
// - フォーム値と runProfileOriginalFields の比較で「確定」を有効化。
// - 選択変更(明示操作)で編集破棄して再ロード。
// - profileInfo/machineProfileInfo 再受信時、編集中(dirty/送信中)ならフォーム値保持、
//   未編集なら再ロード/再描画。編集対象が一覧から消えたらフォールバック(current→先頭)。
// - runProfileFileChanged(外部編集)は編集対象と同名 && 未編集のときのみ再ロード。

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
// 直近ロード(runProfileData ok:true)時点の6フィールド値。null の間はフォーム非表示。
let runProfileOriginalFields = null;
// 現在チェック済みのデバイス名(表示順。チェックボックス操作・machine切替の引き継ぎの正)。
let runProfileCheckedNames = [];
let runProfileDirty = false;
let runProfileSubmitting = false;

function runProfileEditing() {
  return runProfileDirty || runProfileSubmitting;
}

// dirty(=確定ボタン有効)と、それに連動する確定/キャンセルボタンの見た目をまとめて更新する
// (editorForm の refreshEditorButtonsUi/setEditorDirty と同じ方針)。
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
    showRunProfilePlaceholder('実行プロファイルがありません。');
    return;
  }
  // 応答(runProfileData)が来るまで編集させない(応答前の編集がロード結果に上書きされる
  // レースを避ける。ローカルファイル読みなので一瞬で置き換わる)。
  showRunProfilePlaceholder('読み込み中...');
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
    // 編集対象が未定/一覧から消えた: current→先頭の順でフォールバック(編集破棄)。
    if (current !== '' && runProfileNames.includes(current)) {
      selectedRunProfile = current;
    } else {
      selectedRunProfile = runProfileNames.length > 0 ? runProfileNames[0] : null;
    }
  }
  renderRunProfileSelect();
  // [+] は profileInfo を受信できた時点で追加先(プロジェクト)があるので常に有効。
  // コピー/−/✏ は対象(選択中の実行プロファイル)が要るので、一覧0件のときは無効化する
  // (マシンプロファイルの btnMachineCopy/Remove/Rename と同じ方針)。
  btnRunProfileAdd.disabled = false;
  btnRunProfileCopy.disabled = runProfileNames.length === 0;
  btnRunProfileRemove.disabled = runProfileNames.length === 0;
  btnRunProfileRename.disabled = runProfileNames.length === 0;

  if (selectedRunProfile !== previous) {
    requestRunProfileLoad();
    return;
  }
  // 選択が変わらない場合: 編集中ならフォーム値を保持し、未編集なら再ロードして最新化する
  // (apps 一覧の変化もロード後の再描画で反映される)。
  if (selectedRunProfile !== null && !runProfileEditing()) {
    requestRunProfileLoad();
  } else if (selectedRunProfile === null) {
    showRunProfilePlaceholder('実行プロファイルがありません。');
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
  // 選択変更は明示操作なので、編集途中の値を破棄して選択先を再ロードする。
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

// 追加/コピー/名前変更の直後にホストから届く、選択(編集対象)を新プロファイルへ移す通知
// (machineProfileSelected と同じ趣旨)。直前の profileInfo とは順序が前後しない
// (postMessage は順序保証)ため単純に上書きでよいが、念のため一覧に無い名前は無視するガードを
// 入れる(applyRunProfileInfo のフォールバック判定と同じ runProfileNames.includes を使う)。
export function applyRunProfileSelected(message) {
  if (!runProfileNames.includes(message.name)) {
    return;
  }
  selectedRunProfile = message.name;
  renderRunProfileSelect();
  requestRunProfileLoad();
}

// machineProfileInfo 再受信時(メッセージスイッチから呼ばれる): 未編集ならロード済みの値で
// フォームを作り直す(マシン一覧・デバイス一覧の変化を反映)。編集中なら入力値を保持する。
export function rerenderRunProfileFormIfClean() {
  if (runProfileOriginalFields !== null && !runProfileEditing()) {
    renderRunProfileEditor(runProfileOriginalFields);
  }
}

// runProfileData 受信: 編集対象と同じプロファイルの応答のみ反映する(選択変更直後に届く
// 前の選択への応答を無視するガード)。
export function applyRunProfileData(message) {
  if (message.profile !== selectedRunProfile) {
    return;
  }
  // 編集中(dirty/送信中)は反映しない(保存成功直後の再送は dirty 解除済みなので反映される)。
  if (runProfileEditing()) {
    return;
  }
  if (!message.ok || !message.fields) {
    showRunProfilePlaceholder(message.error || '実行プロファイルを読み込めませんでした。');
    return;
  }
  renderRunProfileEditor(message.fields);
}

// ロード済みの6フィールド値でフォームを作り直す(編集途中の値は破棄する)。
function renderRunProfileEditor(fields) {
  runProfileOriginalFields = fields;
  runProfileSubmitting = false;
  runProfileError.textContent = '';

  renderRunProfileMachineSelect(fields.machine);
  renderRunProfileAppSelect(fields.app);
  runProfileCheckedNames = fields.devices.slice();
  renderRunProfileDevices();
  runProfileHeal.checked = fields.heal;
  runProfileReportDir.value = fields.reportDir;
  runProfileDefaultTimeout.value = fields.defaultTimeout;

  setRunProfileControlsEnabled(true);
  runProfileConfirm.textContent = '確定';
  runProfilePlaceholder.style.display = 'none';
  runProfileEditor.style.display = '';
  setRunProfileDirty(false);
}

// 「使用するマシンプロファイル」select。選択肢 = machineProfiles(machineProfileInfo 由来)の
// 名前。value が未指定("")/一覧に無い場合は先頭に「(未指定)」(value="")を付け、一覧に無い
// 非空値はオプション補完で表示する(デバイスタブの applyProfileInfo の unknownOption と同じ方針)。
function renderRunProfileMachineSelect(value) {
  runProfileMachine.textContent = '';
  const names = machineProfiles.map((m) => m.name);
  if (value === '' || !names.includes(value)) {
    const unspecified = document.createElement('option');
    unspecified.value = '';
    unspecified.textContent = '(未指定)';
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
  // 空文字(未指定)の option を常に先頭に置く(app 欠落プロファイルの現在値を表せるように。
  // 空のまま確定しようとするとクライアント検証で弾かれる)。
  const emptyOption = document.createElement('option');
  emptyOption.value = '';
  emptyOption.textContent = '(未指定)';
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

// デバイスのチェックボックス一覧。選択肢 = フォームで選択中のマシンプロファイルのデバイス。
// runProfileCheckedNames に含まれる名前はチェック済み。チェック済みだがマシンに存在しない
// 名前は末尾に注記付きで表示する(チェックを外して確定すれば取り除ける)。マシン未指定("")の
// 間は案内のみ表示する。
function renderRunProfileDevices() {
  runProfileDevices.textContent = '';
  const machineName = runProfileMachine.value;
  if (machineName === '') {
    const note = document.createElement('div');
    note.className = 'run-profile-device-note';
    note.textContent = 'マシンプロファイルを指定するとデバイスを選択できます';
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
    // タイル/レーンと同じ配色ピル(.tile-name-ios/-android)。マシンに存在しない名前は
    // プラットフォームが分からないので中立色(.tile-name-unknown)にする。
    pill.className = 'tile-name ' + (platform ? 'tile-name-' + platform : 'tile-name-unknown');
    pill.textContent = name;
    row.append(checkbox, pill);
    if (missing) {
      const note = document.createElement('span');
      note.className = 'run-profile-device-note';
      note.textContent = '(マシンプロファイルにありません)';
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
runProfileReportDir.addEventListener('input', onRunProfileFormInput);
runProfileDefaultTimeout.addEventListener('input', onRunProfileFormInput);

// devices は「同じ集合なら並び順が違っても未変更」とみなす(マシンのデバイス順とプロファイル
// の記載順は独立で、チェック操作をしていないのに dirty になるのを避けるため)。
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
    runProfileReportDir.value === fields.reportDir &&
    runProfileDefaultTimeout.value === fields.defaultTimeout
  );
}

function onRunProfileFormInput() {
  if (runProfileOriginalFields === null || runProfileSubmitting) {
    return;
  }
  setRunProfileDirty(!runProfileValuesEqual(runProfileOriginalFields));
  // 入力を変えたら前回のエラー表示は古くなるので消す(editorError と同じ方針)。
  runProfileError.textContent = '';
}

function setRunProfileControlsEnabled(enabled) {
  runProfileMachine.disabled = !enabled;
  runProfileApp.disabled = !enabled;
  runProfileHeal.disabled = !enabled;
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
    return '使用するマシンプロファイルを指定してください。';
  }
  if (!findMachine(machine)) {
    return 'マシンプロファイル「' + machine + '」が見つかりません。';
  }
  if (runProfileApp.value.trim() === '') {
    return 'アプリを指定してください。';
  }
  if (runProfileCheckedNames.length === 0) {
    return 'デバイスを1台以上選択してください。';
  }
  const timeout = runProfileDefaultTimeout.value.trim();
  if (timeout !== '' && (!/^\\d+$/.test(timeout) || Number(timeout) <= 0)) {
    return 'defaultTimeout は正の整数で入力してください。';
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
  runProfileConfirm.textContent = '確定中...';
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
      reportDir: runProfileReportDir.value.trim(),
      defaultTimeout: runProfileDefaultTimeout.value.trim(),
    },
  });
});

// キャンセル: dirty/送信中フラグを先に解除してから runProfileLoad を再送する
// (applyRunProfileData は runProfileEditing() の間は応答を無視するガードがあるため、
// 先に解除しておかないと再ロード結果が反映されない)。requestRunProfileLoad は内部で
// showRunProfilePlaceholder→setRunProfileDirty(false) を呼ぶため、この順序を満たす。
runProfileCancel.addEventListener('click', () => {
  if (runProfileCancel.disabled) {
    return;
  }
  runProfileError.textContent = '';
  requestRunProfileLoad();
});

// runProfileSave の結果。ok なら dirty 解除(ホストが続けて runProfileData を送るので、
// フォームはそこで最新値に作り直される)。ok:false ならエラー表示のみで入力値は残す。
export function applyRunProfileSaveResult(message) {
  if (message.profile !== selectedRunProfile) {
    return;
  }
  runProfileSubmitting = false;
  runProfileConfirm.textContent = '確定';
  setRunProfileControlsEnabled(true);
  if (message.ok) {
    runProfileError.textContent = '';
    setRunProfileDirty(false);
  } else {
    refreshRunProfileButtonsUi();
    runProfileError.textContent = message.error || '実行プロファイルの更新に失敗しました。';
  }
}

// runs/<name>.json の外部編集(watcher onDidChange)。編集対象と同名 && 未編集のときのみ
// 再ロードして自動反映する(自分の保存直後の通知も来るが、その再ロードは冪等)。
export function applyRunProfileFileChanged(message) {
  if (message.name === selectedRunProfile && !runProfileEditing()) {
    vscode.postMessage({ type: 'runProfileLoad', profile: selectedRunProfile });
  }
}
