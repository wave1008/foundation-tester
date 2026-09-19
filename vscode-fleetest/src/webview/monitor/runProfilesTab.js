// runProfilesTab.js
// 「プロファイル」タブの実行プロファイル節(選択/追加/コピー/削除/名前変更・設定フォーム)を担う。
// デバイス一覧(チェックボックス・行選択・右クリックメニュー)は runProfileDevicesTab.js に
// 分離してある(**この 2 ファイルは互いに import しない**。片方向依存 = このファイルが
// runProfileDevicesTab.js を読むだけ。相互 import が esbuild のバンドル評価順を崩す実害は
// runProfileDevicesTab.js 冒頭コメント参照)。selectedRunProfile はここでは読み取り専用で
// modals.js から参照される。

import { vscode } from './vscodeApi.js';
import { t } from '../i18n.js';
import { clearDeviceRows, currentDeviceEntries, renderDeviceRows } from './runProfileDevicesTab.js';

// 選択は「編集対象」であり、「デバイスモニター」タブの実行プロファイル選択(fleetest.profile)とは独立。
// 自動保存(確定ボタンは無い): チェック/選択は change で即、テキストは change(= blur か Enter で
// 入力を終えたとき)で runProfileSave を送る。dirty = フォーム値と runProfileOriginalFields
// (直近に保存/ロードした値)の差。検証で弾かれた値は dirty のまま残り、エラーを出す。
// - 送信中もコントロールは無効化しない(無効化するとフォーカスが外れ、Tab で次の欄へ移った入力が
//   途切れる)。送信中に確定した変更は runProfileSaveQueued に積み、結果の到着後にもう1回送る
//   (並行に2本送らない = 後の保存が先に着いて古い値で上書きされる順序逆転を作らない)。
// - 選択変更(明示操作)と Esc は未保存の編集を破棄して再ロード。
// - profileInfo 再受信時: 編集中なら保持、未編集なら再ロード(消失時はcurrent→先頭。devices の
//   変化 = プロジェクトのデバイスカタログの変化もこの再ロードで拾う)。
// - runProfileFileChanged(外部編集・自分の保存の反響)は同名 && 未編集のときのみ再ロード。

const runProfileSelect = document.getElementById('run-profile-select');
const runProfileNameStatic = document.getElementById('run-profile-name-static');
const btnRunProfileAdd = document.getElementById('btn-run-profile-add');
const btnRunProfileCopy = document.getElementById('btn-run-profile-copy');
const btnRunProfileRemove = document.getElementById('btn-run-profile-remove');
const btnRunProfileRename = document.getElementById('btn-run-profile-rename');
const runProfilePlaceholder = document.getElementById('run-profile-placeholder');
const runProfileEditor = document.getElementById('run-profile-editor');
const runProfileApp = document.getElementById('run-profile-app');
const runProfileHeal = document.getElementById('run-profile-heal');
const runProfileTextVisualCheck = document.getElementById('run-profile-text-visual-check');
const runProfileScreenLooksLike = document.getElementById('run-profile-screen-looks-like');
const runProfileOcrTextVisualCheck = document.getElementById('run-profile-ocr-text-visual-check');
const runProfilePreferCheckStateClassifier = document.getElementById('run-profile-prefer-check-state-classifier');
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
const runProfileError = document.getElementById('run-profile-error');
// 保存時に前後の空白を落として書き戻す欄(送る値と画面の値を一致させ、保存後に dirty が残らないように)
const runProfileTextInputs = [
  runProfileRecordBitrate, runProfileWipeThreshold, runProfileLocale,
  runProfileWorkspace, runProfileReportDir,
];

// 直近受信の一覧(profileInfo 由来)。
let runProfileNames = [];
let runProfileApps = [];
// 編集対象の実行プロファイル名(一覧が0件なら null)。modals.js が読み取り専用で参照する。
export let selectedRunProfile = null;
// 直近ロード(runProfileData ok:true)時点のフィールド値。null の間はフォーム非表示。
let runProfileOriginalFields = null;
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
  clearDeviceRows();
  setRunProfileDirty(false);
}

/**
 * silent=true: 同じプロファイルの背景更新(devices カタログが**他の**実行プロファイルの編集で
 * 変わったときの profileInfo 再送等)。プレースホルダへ差し替えない —— 差し替えると
 * runProfileDevicesTab.js の選択・編集ペインが全消去され、無関係な編集のたびにデバイス編集中の
 * 画面が点滅して選択も失われる(2026-09-16 の実害)。応答(runProfileData)は
 * applyRunProfileData の「値が同じなら作り直さない」判定に委ねる。
 * silent=false(既定): プロファイル切替・新規作成・Esc破棄等、**別の状態を表示する**遷移。
 * 応答が来るまでプレースホルダで編集をブロックする(レース防止。ローカル読みなので一瞬で置き換わる)。
 */
function requestRunProfileLoad(silent) {
  if (!selectedRunProfile) {
    showRunProfilePlaceholder(t('wvMonitor2.runProfile.none'));
    return;
  }
  if (!silent) {
    showRunProfilePlaceholder(t('wvMonitor2.common.loading'));
  }
  vscode.postMessage({ type: 'runProfileLoad', profile: selectedRunProfile });
}

// profileInfo 受信(applyProfileInfo と独立)。選択の維持/フォールバックと再ロードを行う。
// devices(プロジェクトのデバイスカタログ)は main.js が applyProjectDeviceCatalog を先に
// 呼んでから applyRunProfileInfo を呼ぶので、ここでの再ロードは常に最新のカタログを反映する。
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
  // 未編集なら再ロードして最新化(apps一覧・デバイスカタログの変化もここで反映される)。
  // **silent** —— 同じプロファイルのままの背景更新でプレースホルダへ差し替えない
  // (デバイス編集フォームの選択・入力中の内容を消さないため)。
  if (selectedRunProfile !== null && !runProfileEditing()) {
    requestRunProfileLoad(true);
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

// ロード済みのフィールド値でフォームを作り直す(編集途中の値は破棄する)。
function renderRunProfileEditor(fields) {
  runProfileOriginalFields = fields;
  runProfileSubmitting = false;
  runProfileSubmittedFields = null;
  runProfileSaveQueued = false;
  runProfileError.textContent = '';

  renderRunProfileAppSelect(fields.app);
  renderDeviceRows(fields.devices);
  runProfileHeal.checked = fields.heal;
  runProfileTextVisualCheck.checked = fields.textVisualCheck;
  runProfileScreenLooksLike.checked = fields.screenLooksLike;
  runProfileOcrTextVisualCheck.checked = fields.ocrTextVisualCheck;
  runProfilePreferCheckStateClassifier.checked = fields.preferCheckStateClassifier;
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

  runProfilePlaceholder.style.display = 'none';
  runProfileEditor.style.display = '';
  setRunProfileDirty(false);
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

// inapp エンジン ON のときだけ配下のサブオプション(iosPreActionWarmup)を表示する
// (暖機は hybrid の domInterop 経路にしか無い = xcuitest エンジンでは効果が無いため。
//  値そのものはエンジンの状態に関わらず保持・保存する)。
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

// devices は (platform, machine, name, enabled) の集合比較(順序無視)。
function deviceSetKey(ref) {
  return `${ref.platform}\t${ref.machine ?? ''}\t${ref.name}\t${ref.enabled}`;
}
function runProfileDevicesEqual(a, b) {
  if (a.length !== b.length) {
    return false;
  }
  const setB = new Set(b.map(deviceSetKey));
  return a.every((ref) => setB.has(deviceSetKey(ref)));
}

function runProfileValuesEqual(fields) {
  return (
    runProfileApp.value === fields.app &&
    runProfileDevicesEqual(currentDeviceEntries(), fields.devices) &&
    runProfileHeal.checked === fields.heal &&
    runProfileTextVisualCheck.checked === fields.textVisualCheck &&
    runProfileScreenLooksLike.checked === fields.screenLooksLike &&
    runProfileOcrTextVisualCheck.checked === fields.ocrTextVisualCheck &&
    runProfilePreferCheckStateClassifier.checked === fields.preferCheckStateClassifier &&
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
    runProfileReportDir.value === fields.reportDir
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
  if (runProfileApp.value.trim() === '') {
    return t('wvMonitor2.runProfile.validation.appRequired');
  }
  if (currentDeviceEntries().filter((d) => d.enabled).length === 0) {
    return t('wvMonitor2.runProfile.validation.deviceRequired');
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
    app: runProfileApp.value.trim(),
    devices: currentDeviceEntries(),
    heal: runProfileHeal.checked,
    textVisualCheck: runProfileTextVisualCheck.checked,
    screenLooksLike: runProfileScreenLooksLike.checked,
    ocrTextVisualCheck: runProfileOcrTextVisualCheck.checked,
    preferCheckStateClassifier: runProfilePreferCheckStateClassifier.checked,
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
