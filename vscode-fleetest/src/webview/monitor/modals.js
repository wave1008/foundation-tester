// modals.js
// 「プロファイル」タブの3モーダル(デバイス追加/名前入力/既存デバイスから選択)をまとめる。
// applyCreateDeviceResult が既存選択モーダルの pendingAutoChecks を直接書き換えるため、
// setter を挟まず同一モジュールに置いている。

import { t } from '../i18n.js';
import { vscode } from './vscodeApi.js';
import { cachePhysicalDeviceInfo } from './physicalDeviceCache.js';
import { clampMenuPosition } from './menu.js';
import { selectedMachine, findMachine, allDeviceNamesForSelectedMachine, btnDeviceAddExisting, refreshSelectedDeviceEditor } from './machineProfilesTab.js';
import { currentDeviceSource, refreshDeviceAddBadge, resetDevicePickMachine } from './devicePickMachine.js';

// ---- デバイス追加モーダル ---------------------------------------------------

// 複製元: src/monitorProfileForms.ts の validateNewDeviceName(CSP により import 不可のため複製。
// ロジック変更時は両方に反映すること)。
function validateNewDeviceName(name, existing) {
  const trimmed = name.trim();
  if (trimmed.length === 0) {
    return t('wvMonitor.deviceAdd.nameRequired');
  }
  if (existing.includes(trimmed)) {
    return t('wvMonitor.deviceAdd.nameDuplicate', { name: trimmed });
  }
  return null;
}

const deviceAddOverlay = document.getElementById('device-add-overlay');
const dlgPlatformIos = document.getElementById('dlg-platform-ios');
const dlgPlatformAndroid = document.getElementById('dlg-platform-android');
const dlgModel = document.getElementById('dlg-model');
const dlgServiceRow = document.getElementById('dlg-service-row');
const dlgService = document.getElementById('dlg-service');
const dlgOs = document.getElementById('dlg-os');
const dlgName = document.getElementById('dlg-name');
const dlgError = document.getElementById('dlg-error');
const dlgCancel = document.getElementById('dlg-cancel');
const dlgOk = document.getElementById('dlg-ok');
const dlgInstallRow = document.getElementById('dlg-install-row');
const dlgInstall = document.getElementById('dlg-install');
const dlgBatch = document.getElementById('dlg-batch');
const dlgBatchCount = document.getElementById('dlg-batch-count');
const batchOverlay = document.getElementById('device-batch-overlay');
const batchStatus = document.getElementById('device-batch-status');
const batchList = document.getElementById('device-batch-list');
const batchError = document.getElementById('device-batch-error');
const batchOk = document.getElementById('device-batch-ok');

let deviceAddOpen = false;
let deviceAddCreating = false;
// cmdline-tools の導入中(数分)。deviceAddCreating と同じくモーダルを閉じさせない。
let installingCmdlineTools = false;
// 「サービス」の既定(monitorHtml.ts の #dlg-service の selected と一致させる)。Play Store 版は
// Play 保護の分だけ重く、テスト用途では Google APIs で足りることが多いためこちらを既定にする。
const DEFAULT_ANDROID_SERVICE = 'google_apis';
// バッチ作成の既定台数と範囲(monitorHtml.ts の #dlg-batch-count の value/min/max と一致させる)
const DEFAULT_BATCH_COUNT = 2;
const MIN_BATCH_COUNT = 1;
const MAX_BATCH_COUNT = 99;
// deviceCatalogRequest の応答(deviceCatalog.ok:true の catalog)。未着/失敗中は null。
let deviceCatalog = null;
// デバイス名をユーザーが手で編集したか(true の間は自動生成に追従しない)。
let dlgNameDirty = false;
// #device-pick-overlay の「+」から開いたか(devicePickOpen をそのまま流用して判定)。
// true なら createDevice は register:false(物理作成のみ)、成功時 pendingAutoChecks で自動チェック。
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
  dlgBatch.disabled = !enabled;
  dlgBatchCount.disabled = !enabled;
  dlgPlatformIos.disabled = !enabled;
  dlgPlatformAndroid.disabled = !enabled;
  dlgModel.disabled = !enabled;
  dlgService.disabled = !enabled;
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

// Android の OS バージョンは「サービス」(system-images のタグ)で絞る。タグはラベルから外す
// (選択済みの値と重複するため)。
function osOptionsFor(platform) {
  if (!deviceCatalog) {
    return [];
  }
  if (platform === 'ios') {
    return deviceCatalog.ios.runtimes.map((r) => ({ value: r.identifier, label: r.name }));
  }
  return deviceCatalog.android.systemImages
    .filter((s) => s.tag === dlgService.value)
    .map((s) => ({
      value: s.package,
      label: s.versionName + '(API ' + s.apiLevel + ') / ' + s.abi,
    }));
}

// カタログは ok:true のままプラットフォーム単位で部分的に欠ける(例: Android は system-images だけ
// 読めて、avdmanager 不在でモデル定義が空)。error/空リストを出さないと「空のドロップダウンだけが
// 出て理由が分からない」になり、そのまま OK を押しても作成側で同じ理由で失敗する。
function platformIssue(platform) {
  if (!deviceCatalog) {
    return { blocked: true, message: '' };
  }
  const side = platform === 'ios' ? deviceCatalog.ios : deviceCatalog.android;
  const models = modelOptionsFor(platform);
  const oses = osOptionsFor(platform);
  const blocked = models.length === 0 || oses.length === 0;
  // カタログ自体は取れているのに OS だけ空 = 選択中サービスのイメージが無いだけ(サービスを
  // 変えれば解決するので、カタログが空という言い方をしない)
  const serviceOnly = platform === 'android' && models.length > 0
    && deviceCatalog.android.systemImages.length > 0;
  // side.error は CLI 由来の理由文(訳さず素通しする。枠だけ i18n)。
  // **解決手段は呼び手が足す** —— cmdline-tools の導入先はカタログを取った機械なので、
  // リモートのときは remote exec の案内にする(ローカルは下の導入ボタンが出る)
  const source = currentDeviceSource();
  const remedy = side.errorCode === 'avdmanager-missing' && source.kind === 'remote'
    ? ' ' + t('wvMonitor.deviceAdd.installCmdlineToolsOnRemote', { machine: source.machine })
    : '';
  return {
    blocked,
    message: side.error
      ? side.error + remedy
      : (blocked
        ? t(serviceOnly ? 'wvMonitor.deviceAdd.noImageForService' : 'wvMonitor.deviceAdd.catalogEmpty')
        : ''),
    // 導入で解消できる欠け方のときだけボタンを出す(文言では分岐しない)。導入は常にローカルで
    // 実行するため(installCmdlineToolsRequest はホストセレクタの対象外)、ホストがリモートの
    // ときは出さない — 出すと「別マシンの欠けを手元に導入するボタン」という誤動作になる。
    installable: platform === 'android' && side.errorCode === 'avdmanager-missing'
      && source.kind === 'local',
  };
}

// いま選んでいるホストで name が衝突するか(実体・登録のどちらか)。**別ホストの同名は衝突ではない**
// (FTCore.DeviceMachineGrouping と同じ「一意なのは (machine, name)」)。
function nameClashesOnCurrentMachine(name, platform, source) {
  const machine = source.kind === 'remote' ? source.machine : undefined;
  if (allDeviceNamesForSelectedMachine(machine).includes(name)) {
    return true;
  }
  // 実体側(このホストから取得済みの一覧)。ピッカー経由で開いているので行が揃っている
  const rows = platform === 'ios' ? devicePickIosRows : devicePickAndroidRows;
  return rows.some((row) => {
    if (row.missing) { return false; }         // 実体が無い行は衝突しない
    if (row.device) { return row.device.name === name; }
    if (row.avd) { return row.avd.displayName === name; }
    return false;
  });
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

// 選択中プラットフォームの選択肢とエラー表示・OK 可否を1箇所で同期する(プラットフォーム切替でも
// カタログ受信直後でも同じ結果になるよう、呼び出し側で dlgError/dlgOk を触らない)。
function refreshModelAndOsOptions() {
  const platform = getDialogPlatform();
  dlgServiceRow.hidden = platform !== 'android';
  fillSelect(dlgModel, modelOptionsFor(platform));
  fillSelect(dlgOs, osOptionsFor(platform));
  refreshAutoName();
  const issue = platformIssue(platform);
  dlgError.classList.remove('info');
  dlgError.textContent = issue.message;
  dlgOk.disabled = issue.blocked;
  dlgInstallRow.hidden = !issue.installable;
}

dlgPlatformIos.addEventListener('change', () => refreshModelAndOsOptions());
dlgPlatformAndroid.addEventListener('change', () => refreshModelAndOsOptions());
// サービスを変えると選べる OS バージョンが変わる(モデルは変わらないが、空になったときの
// 理由表示と OK 可否も refreshModelAndOsOptions が面倒を見る)
dlgService.addEventListener('change', () => refreshModelAndOsOptions());
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

/** `platform` を渡すと OS 種別をそれで開く。**カタログ受信前に決める** ――
 *  受信後の applyPlatformAvailability が「その OS が使えない」ときだけ他方へ倒す。 */
function openDeviceAddModal(platform) {
  if (!selectedMachine) {
    return;
  }
  if (platform) {
    setDialogPlatform(platform);
  }
  deviceAddFromPicker = devicePickOpen;
  deviceAddOpen = true;
  deviceAddCreating = false;
  dlgNameDirty = false;
  dlgName.value = '';
  dlgBatchCount.value = String(DEFAULT_BATCH_COUNT);
  dlgService.value = DEFAULT_ANDROID_SERVICE;
  refreshDeviceAddBadge();
  requestDeviceCatalog();
  dlgOk.textContent = 'OK';
  dlgCancel.disabled = false;
  deviceAddOverlay.classList.add('visible');
}

// カタログ取得中の見た目(モーダルを開いた直後と、cmdline-tools 導入成功後の再取得で共通)
function requestDeviceCatalog() {
  deviceCatalog = null;
  dlgModel.textContent = '';
  dlgOs.textContent = '';
  dlgError.classList.add('info');
  dlgError.textContent = t('wvMonitor.deviceAdd.catalogLoading');
  dlgInstallRow.hidden = true;
  setDialogControlsEnabled(false);
  dlgOk.disabled = true;
  vscode.postMessage({ type: 'deviceCatalogRequest', source: currentDeviceSource() });
}

// 導入中(数分)は閉じられる: CLI が固まってもモーダルが永久に閉じなくなるのを避ける。
// 二重起動は installingCmdlineTools(モジュール状態・開閉をまたぐ)とボタン無効化で止める。
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
    dlgError.textContent = message.error || t('wvMonitor.deviceAdd.catalogFailed');
    dlgOk.disabled = true;
    return;
  }
  deviceCatalog = message.catalog;
  setDialogControlsEnabled(true);
  applyPlatformAvailability();
  // dlgError / dlgOk は refreshModelAndOsOptions が選択中プラットフォームに応じて設定する
  refreshModelAndOsOptions();
}

// avdmanager が無いときだけ出る導入ボタン。完了まで数分かかるため、押下後はモーダル全体を
// 固め(閉じるのも止め)、進捗は OUTPUT 側で見せる。
dlgInstall.addEventListener('click', () => {
  if (installingCmdlineTools) {
    return;
  }
  installingCmdlineTools = true;
  dlgInstall.disabled = true;
  dlgOk.disabled = true;
  setDialogControlsEnabled(false);
  dlgError.classList.add('info');
  dlgError.textContent = t('wvMonitor.deviceAdd.installing');
  vscode.postMessage({ type: 'installCmdlineToolsRequest' });
});

export function applyInstallCmdlineToolsResult(message) {
  // 状態の解除だけは閉じていても必ず行う(閉じている間に終わると、次に開いたとき
  // ボタンが無効のまま二度と押せなくなる)
  installingCmdlineTools = false;
  dlgInstall.disabled = false;
  if (!deviceAddOpen) {
    return; // 表示の更新だけ捨てる(applyDeviceCatalog と同じ方針)
  }
  dlgCancel.disabled = false;
  if (message.ok) {
    // 導入できたので取り直す。モデルが並べば dlgInstallRow は自動で隠れる
    requestDeviceCatalog();
    return;
  }
  setDialogControlsEnabled(true);
  applyPlatformAvailability();
  refreshModelAndOsOptions();
  dlgError.classList.remove('info');
  dlgError.textContent = message.error || t('wvMonitor.deviceAdd.installFailed');
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
    // pendingAutoChecks に識別子を保持(次の一覧再描画で自動チェックON。詳細は宣言箇所参照)。
    if (deviceAddFromPicker) {
      pendingAutoChecks = message.device
        ? [{ udid: message.device.udid, avd: message.device.avd, name: message.name }]
        : [];
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
  dlgError.textContent = message.error || t('wvMonitor.deviceAdd.createFailed');
}

// 「+新規作成」ボタンは無く、openDeviceAddModal は #device-pick-overlay 内の「+」からのみ開く。
dlgCancel.addEventListener('click', () => closeDeviceAddModal());
deviceAddOverlay.addEventListener('click', (event) => {
  if (event.target === deviceAddOverlay) {
    closeDeviceAddModal();
  }
});
// Enter で OK。**入力欄・選択欄のどこにいても効かせる**(名前を打ってそのまま Enter が自然)。
// ボタン上の Enter は既定のクリック動作に任せる(二重発火を避ける)。IME の変換確定 Enter は
// 拾わない(isComposing / keyCode 229。liveTab.js と同じ規律 —— 日本語入力で確定した瞬間に
// ダイアログが閉じると入力し直しになる)。
deviceAddOverlay.addEventListener('keydown', (event) => {
  if (event.key !== 'Enter' || event.isComposing || event.keyCode === 229) {
    return;
  }
  if (event.target.closest('button') || dlgOk.disabled || deviceAddCreating) {
    return;
  }
  event.preventDefault();
  dlgOk.click();
});
dlgOk.addEventListener('click', () => {
  if (dlgOk.disabled || deviceAddCreating || !deviceCatalog) {
    return;
  }
  const name = dlgName.value.trim();
  const source = currentDeviceSource();
  if (name.length === 0) {
    dlgError.classList.remove('info');
    dlgError.textContent = t('wvMonitor.deviceAdd.nameRequired');
    return;
  }
  // **同名は拒否せず「上書きするか」を聞く**(2026-08-17 指示)。判定は選択中のホストのぶんだけ
  // (一意なのは (machine, name)。別の機械の同名は衝突ではない)。実体と登録のどちらの衝突でも、
  // 上書き = 実体を消して作り直す + 古い登録を新しい実体で置き換える。
  // 確認ダイアログはホスト側(webview の window.confirm は効かない)。
  const overwrite = nameClashesOnCurrentMachine(name, getDialogPlatform(), source);
  deviceAddCreating = true;
  setDialogControlsEnabled(false);
  dlgOk.disabled = true;
  dlgCancel.disabled = true;
  dlgOk.textContent = t('wvMonitor.deviceAdd.creating');
  dlgError.textContent = '';
  vscode.postMessage({
    type: 'createDevice',
    machine: selectedMachine,
    platform: getDialogPlatform(),
    name: name,
    model: dlgModel.value,
    os: dlgOs.value,
    // ピッカー経由なら register:false(登録はピッカー側 OK の machineDevicesSync で行う)。
    // source が remote のときはホスト側が register によらず --no-register を強制する(§13)。
    register: !deviceAddFromPicker,
    overwrite: overwrite,
    source: currentDeviceSource(),
  });
});

// ---- バッチ作成 -------------------------------------------------------------

/** 「デバイス名 + `-` + 連番2桁」。**`-01` 始まり**(2026-08-25 指示。既存フリートの命名と同じ)で、
 *  #dlg-batch-count の上限 99 とあわせて -01〜-99 の範囲に収まる。 */
export function batchDeviceNames(base, count) {
  const names = [];
  for (let i = 1; i <= count; i += 1) {
    names.push(base + '-' + String(i).padStart(2, '0'));
  }
  return names;
}

/** #dlg-batch-count の値。**number 入力の min/max に任せない** —— 手打ちの範囲外や空欄は
 *  そのまま読めてしまうので、ここで弾いて null を返す。 */
export function parseBatchCount(raw) {
  const value = Number(String(raw).trim());
  if (!Number.isInteger(value) || value < MIN_BATCH_COUNT || value > MAX_BATCH_COUNT) {
    return null;
  }
  return value;
}

// 進行窓に出す行(index → { row, state })。started で組み直す
let batchRows = [];
// finished で受けた「作れた台」。OK を押した時点で pendingAutoChecks へ移す
let batchCreatedDevices = [];
let batchTotal = 0;
let batchDone = 0;

function openBatchModal(names) {
  batchRows = [];
  batchTotal = names.length;
  batchDone = 0;
  batchList.textContent = '';
  batchError.textContent = '';
  batchOk.disabled = true;
  batchStatus.textContent = t('wvMonitor.deviceBatch.progress', { done: '0', total: String(batchTotal) });
  for (const name of names) {
    const row = document.createElement('div');
    row.className = 'device-batch-row';
    const nameEl = document.createElement('span');
    nameEl.className = 'device-batch-name';
    nameEl.textContent = name;
    const stateEl = document.createElement('span');
    stateEl.className = 'device-batch-state';
    stateEl.textContent = t('wvMonitor.deviceBatch.waiting');
    row.appendChild(nameEl);
    row.appendChild(stateEl);
    batchList.appendChild(row);
    batchRows.push(stateEl);
  }
  batchOverlay.classList.add('visible');
}

/** 追加ダイアログを操作できる状態へ戻す(確認をキャンセルされた・多重実行で弾かれた場合)。 */
function restoreDeviceAddAfterBatch(error) {
  deviceAddCreating = false;
  setDialogControlsEnabled(true);
  applyPlatformAvailability();
  dlgOk.disabled = false;
  dlgCancel.disabled = false;
  dlgError.classList.remove('info');
  dlgError.textContent = error || '';
}

dlgBatch.addEventListener('click', () => {
  if (dlgBatch.disabled || deviceAddCreating || !deviceCatalog) {
    return;
  }
  const base = dlgName.value.trim();
  if (base.length === 0) {
    dlgError.classList.remove('info');
    dlgError.textContent = t('wvMonitor.deviceAdd.nameRequired');
    return;
  }
  const count = parseBatchCount(dlgBatchCount.value);
  if (count === null) {
    dlgError.classList.remove('info');
    dlgError.textContent = t('wvMonitor.deviceAdd.batchCountInvalid');
    return;
  }
  const platform = getDialogPlatform();
  const source = currentDeviceSource();
  const names = batchDeviceNames(base, count);
  // 上書きの確認はホスト側(webview の window.confirm は効かない)。衝突の判定はこちら ――
  // 一覧(登録済み+実体)を持っているのは webview だけ。単発 OK と同じ規則を名前ごとに当てる
  const overwriteNames = names.filter((name) => nameClashesOnCurrentMachine(name, platform, source));
  // 確認中も追加ダイアログを固める(Enter 連打・×での取り消しを止める)。
  // 開始できなければ batchCreateFinished(started:false)で元に戻す
  deviceAddCreating = true;
  setDialogControlsEnabled(false);
  dlgOk.disabled = true;
  dlgCancel.disabled = true;
  dlgError.textContent = '';
  vscode.postMessage({
    type: 'batchCreateDevices',
    machine: selectedMachine,
    platform: platform,
    names: names,
    model: dlgModel.value,
    os: dlgOs.value,
    overwriteNames: overwriteNames,
    source: source,
  });
});

export function applyBatchCreateStarted(message) {
  // 「デバイスを追加」を閉じ、代わりに進行窓を出す。deviceAddCreating を先に下ろさないと閉じられない
  deviceAddCreating = false;
  closeDeviceAddModal();
  openBatchModal(message.names || []);
}

export function applyBatchCreateProgress(message) {
  const stateEl = batchRows[message.index];
  if (!stateEl) {
    return;
  }
  if (message.state === 'running') {
    stateEl.textContent = t('wvMonitor.deviceBatch.creating');
    stateEl.className = 'device-batch-state running';
    return;
  }
  const ok = message.state === 'ok';
  stateEl.textContent = ok
    ? t('wvMonitor.deviceBatch.done')
    : t('wvMonitor.deviceBatch.failed') + (message.error ? ': ' + message.error : '');
  stateEl.className = 'device-batch-state ' + (ok ? 'ok' : 'failed');
  batchDone += 1;
  batchStatus.textContent = t('wvMonitor.deviceBatch.progress', {
    done: String(batchDone),
    total: String(batchTotal),
  });
}

export function applyBatchCreateFinished(message) {
  if (!message.started) {
    // 確認をキャンセルされた等。進行窓は開いていないので追加ダイアログを元に戻すだけ
    restoreDeviceAddAfterBatch(message.error);
    return;
  }
  const created = message.created || [];
  const failed = message.failed || [];
  batchStatus.textContent = failed.length === 0
    ? t('wvMonitor.deviceBatch.finishedAllOk', { created: String(created.length) })
    : t('wvMonitor.deviceBatch.finished', { created: String(created.length), failed: String(failed.length) });
  batchOk.disabled = false;
  batchOk.focus();
  // **ここでは pendingAutoChecks を立てない**(2026-08-25 の実害)。立てると、OK を押すまでの間に
  // 別経路の installedDevices 応答(machineProfilesTab の機種/OS 取得)が届いた時点で
  // **一度きりの適用を使い切り**、そのあと OK の再取得で行が作り直されてチェックが消える。
  // 立てるのは OK を押して再取得を投げる直前(batchOk のリスナー)
  batchCreatedDevices = created.map((device) => ({
    udid: device.udid,
    avd: device.avd,
    name: device.name,
  }));
}

// **Esc は進行窓が食う**。奥の「デバイスを選択」の Esc ハンドラは defaultPrevented を見るので、
// ここで消費しないと**手前の進行窓を残したまま奥だけ閉じる**(追加ダイアログと同じ規律)。
// 作成中は何もしない(閉じ先が無い)。終わっていれば OK と同じ扱い
document.addEventListener('keydown', (event) => {
  if (event.key !== 'Escape' || !batchOverlay.classList.contains('visible')) {
    return;
  }
  event.preventDefault();
  if (!batchOk.disabled) {
    batchOk.click();
  }
});

batchOk.addEventListener('click', () => {
  if (batchOk.disabled) {
    return;
  }
  batchOverlay.classList.remove('visible');
  // 「デバイスを選択」へ戻り、作成できたぶんへチェックを入れる(再取得後に applyPendingAutoCheck)。
  // **再取得を投げる直前に立てる** —— 先に立てると別経路の応答に食われる(宣言箇所参照)
  pendingAutoChecks = batchCreatedDevices;
  batchCreatedDevices = [];
  reloadDevicePickIfOpen();
});

// **Esc は手前の1枚だけ閉じる**。document 上に Esc ハンドラが3つ(この追加ダイアログ /
// 削除メニュー / 選択ダイアログ)あり、**手前を閉じた時点でフラグが下りる**ため、後続の
// ハンドラが「奥も閉じてよい」と誤判定して2枚同時に閉じていた(2026-08-17 実機で確認)。
// 消費したら preventDefault で印を付け、奥のハンドラはそれを見て降りる
// (フラグの読み合いだと登録順に依存する)。
document.addEventListener('keydown', (event) => {
  if (event.key !== 'Escape' || !deviceAddOpen || deviceAddCreating) {
    return;
  }
  closeDeviceAddModal();
  event.preventDefault();
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
    return t('wvMonitor.nameInput.required', { noun: state.noun });
  }
  if (trimmed.indexOf('/') !== -1 || trimmed.indexOf(NAME_INPUT_BACKSLASH) !== -1) {
    return t('wvMonitor.nameInput.forbiddenChars', { noun: state.noun, backslash: NAME_INPUT_BACKSLASH });
  }
  if (trimmed.charAt(0) === '.') {
    return t('wvMonitor.nameInput.leadingDot', { noun: state.noun });
  }
  const compareName = state.caseInsensitiveDup ? trimmed.toLowerCase() : trimmed;
  const isDup = state.existing.some((item) => (state.caseInsensitiveDup ? item.toLowerCase() : item) === compareName);
  if (isDup) {
    return t('wvMonitor.nameInput.duplicate', { dupLabel: state.dupLabel, name: trimmed });
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
const devicePickIosAddNewBtn = document.getElementById('device-pick-ios-add-new');
const devicePickAndroidAddNewBtn = document.getElementById('device-pick-android-add-new');
const devicePickMachineSelect = document.getElementById('device-pick-machine-select');
const devicePickList = document.getElementById('device-pick-list');
const devicePickLoading = document.getElementById('device-pick-loading');
const devicePickDeleteMenu = document.getElementById('device-pick-delete-menu');
const devicePickDeleteMenuItemBtn = document.getElementById('device-pick-delete-menu-item');

let devicePickOpen = false;
let devicePickAdding = false;
// 直近描画した行。initialChecked は描画時点の登録有無(OK 時に checkbox.checked との差分を
// add/remove として組み立てる)。registeredName は未チェックにした場合の削除対象(name)。
let devicePickIosRows = [];
let devicePickAndroidRows = [];
// register:false で作成した直後、次の installedDevices 再描画で自動チェックONにしたい行の
// 識別子(iOS=udid/Android=avd の id)。**当たった行のぶんだけ**空にする(一度きりの適用だが、
// まだ一覧に出ていない台は次の再描画まで残す)。**配列**なのはバッチ作成のため
// (単発作成は1件だけ入れる)。
let pendingAutoChecks = [];
// 行右クリック「削除」メニュー(#device-pick-delete-menu)を開いている対象
// ({ platform, identifier, name, rowEl, checkbox })。未オープンなら null。実機行は対象外
// (シミュレータ/AVD のような「削除できる実体」を持たない)。
let devicePickDeleteMenuEntry = null;
// devicePickDeviceDelete を送信中の identifier 集合。その行だけ操作不可にする(他行・OK/Cancel は
// 引き続き操作できる)。応答は devicePickOpen の状態に関わらず届きうる(削除は数秒かかるため、
// その間にダイアログを閉じられることがある)。
const devicePickDeletingIdentifiers = new Set();

// **いま選んでいるホストに居る登録済みデバイスだけ**を返す。ホストを跨いで見ると、
// 別の機械の同じ AVD id(各機が同じ命名規則で作るので普通に一致する)を「登録済み」と
// 誤判定し、チェックを外すと**別ホストの登録を消す**(FTCore.DeviceMachineGrouping と同じ
// 「一意なのは (machine, name)」)。
function registeredDevicesForCurrentMachine() {
  const profile = findMachine(selectedMachine);
  if (!profile) {
    return [];
  }
  const source = currentDeviceSource();
  const machine = source.kind === 'remote' ? source.machine : undefined;
  return profile.devices.filter((d) => (d.machine ?? undefined) === machine);
}

// 識別値→マシンプロファイル上の name の対応表(初期チェック判定・remove 対象名の特定に使う)。
// Android は avd の id/displayName どちらの一致も登録済みとみなす。
function registeredIosNameByUdid() {
  const map = new Map();
  for (const d of registeredDevicesForCurrentMachine()) {
    if (d.platform === 'ios' && d.udid) {
      map.set(d.udid, d.name);
    }
  }
  return map;
}
function registeredAndroidNameByAvd() {
  const map = new Map();
  for (const d of registeredDevicesForCurrentMachine()) {
    if (d.platform === 'android' && d.avd) {
      map.set(d.avd, d.name);
    }
  }
  return map;
}

// 実機は serial で登録済みを判定する(AVD は持たないため registeredAndroidNameByAvd に載らない)。
function registeredAndroidNameBySerial() {
  const map = new Map();
  for (const d of registeredDevicesForCurrentMachine()) {
    if (d.platform === 'android' && d.serial) {
      map.set(d.serial, d.name);
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

// 個体を識別できる部分だけを出す(ハイフン以降。無ければ全体)
function physicalUdidLabel(udid) {
  const dash = udid.indexOf('-');
  return dash >= 0 ? udid.slice(dash + 1) : udid;
}

// 実機 1 行。シミュレータ/AVD 行と同じ見た目に「実機」バッジを足しただけ
// (取り違えると署名・接続の前提が違うため必ず出す)。
function buildPhysicalPickRow(spec) {
  const rowEl = document.createElement('div');
  rowEl.className = 'device-pick-row';
  const checkbox = document.createElement('input');
  checkbox.type = 'checkbox';
  checkbox.checked = spec.registered;
  checkbox.addEventListener('change', () => {
    syncDevicePickRowChecked(rowEl, checkbox);
    updateDevicePickOkState();
  });
  const textWrap = document.createElement('div');
  textWrap.className = 'device-pick-row-text';
  // バッジはデバイス名の左。横並びの行に入れる(textWrap 直下は column flex なので、
  // 直接置くとバッジが行幅いっぱいに伸びる)
  const nameRow = document.createElement('div');
  nameRow.className = 'device-pick-row-name-line';
  const badge = document.createElement('span');
  badge.className = 'badge badge-kind';
  badge.textContent = t('wvMonitor.tile.physicalBadge');
  const nameEl = document.createElement('span');
  nameEl.className = 'device-pick-row-name tile-name tile-name-' + spec.platform;
  nameEl.textContent = spec.name;
  nameRow.append(badge, nameEl);
  const detailEl = document.createElement('div');
  detailEl.className = 'device-pick-row-detail';
  detailEl.textContent = spec.detail;
  textWrap.append(nameRow, detailEl);
  rowEl.append(checkbox, textWrap);
  attachDevicePickRowToggle(rowEl, checkbox);
  syncDevicePickRowChecked(rowEl, checkbox);
  return { rowEl: rowEl, checkbox: checkbox };
}

// installedDevices(InstalledDevices の形)から2グループ分の行を組み立てる。
/** 再描画をまたいで行を突き合わせる鍵。実体の識別子(udid / avd id / serial)を使い、
 *  実体の無い「登録だけ残っている行」は登録名で引く。 */
function devicePickRowKey(row) {
  if (row.missing) { return 'missing\u0000' + (row.registeredName || ''); }
  if (row.device) { return 'ios\u0000' + row.device.udid; }
  if (row.physicalDevice) { return 'android\u0000' + row.physicalDevice.serial; }
  if (row.avd) { return 'android\u0000' + row.avd.id; }
  return '';
}

/** **まだ OK していない手作業のチェック**(登録状態と食い違っている行)を鍵ごとに控える。
 *  一覧はデバイスを作るたびに取り直して行 DOM を作り直すので、控えて戻さないと
 *  「作成を続けざまにやると前のチェックが外れる」(2026-08-25 の報告)。
 *  **initialChecked と一致する行は控えない** —— 登録状態そのものは新しい一覧の値が正しく、
 *  古い値で上書きすると別経路の登録変更を打ち消してしまう。 */
function capturePendingDevicePickEdits() {
  const pending = new Map();
  for (const row of devicePickIosRows.concat(devicePickAndroidRows)) {
    if (row.checkbox.checked === row.initialChecked) { continue; }
    const key = devicePickRowKey(row);
    if (key) { pending.set(key, row.checkbox.checked); }
  }
  return pending;
}

/** capturePendingDevicePickEdits で控えた手作業のチェックを、作り直した行へ戻す。 */
function restorePendingDevicePickEdits(pending) {
  if (pending.size === 0) { return; }
  for (const row of devicePickIosRows.concat(devicePickAndroidRows)) {
    const key = devicePickRowKey(row);
    if (!key || !pending.has(key)) { continue; }
    const checked = pending.get(key);
    if (row.checkbox.checked === checked) { continue; }
    row.checkbox.checked = checked;
    syncDevicePickRowChecked(row.rowEl, row.checkbox);
  }
}

function renderDevicePickGroups(data) {
  const pendingEdits = capturePendingDevicePickEdits();
  devicePickIosRows = [];
  devicePickAndroidRows = [];
  devicePickIosBody.textContent = '';
  devicePickAndroidBody.textContent = '';
  // 再描画で行 DOM を作り直すため、開いたままの削除メニューは対象行を失う(machineProfilesTab.js の
  // renderMachineProfileBody と同じ理由)。
  closeDevicePickDeleteMenu();

  // 登録はあるのに一覧に無いデバイス(実体を手で消した等)。**出さないと気付けない** ——
  // リモートの実体は手元から見えず、実行して「AVD が無い」で落ちるまで分からない。
  // チェックを外して OK すれば登録だけ解除できる(実体は元から無い)
  const missingRows = (bodyEl, rows, platform, installedIdentifiers, identifierOf) => {
    for (const d of registeredDevicesForCurrentMachine()) {
      if (d.platform !== platform) { continue; }
      const identifier = identifierOf(d);
      if (!identifier || installedIdentifiers.has(identifier)) { continue; }
      const row = buildMissingPickRow(platform, d.name, identifier);
      bodyEl.appendChild(row.rowEl);
      rows.push({
        checkbox: row.checkbox, missing: true,
        initialChecked: true, registeredName: d.name, rowEl: row.rowEl,
      });
    }
  };

  const iosNameByUdid = registeredIosNameByUdid();
  const iosData = data.ios;
  // 実機はシミュレータと同じ iOS グループの先頭に出す(登録判定は udid で共通)
  const iosPhysical = iosData.physicalDevices || [];
  // 台数はグループの中身(シミュレータ+実機)の合計
  devicePickIosTitle.textContent = t('wvMonitor.devicePick.iosCountTitle', {
    count: iosData.devices.length + iosPhysical.length,
  });
  for (const device of iosPhysical) {
    const registeredName = iosNameByUdid.get(device.udid);
    const registered = registeredName !== undefined;
    const row = buildPhysicalPickRow({
      platform: 'ios',
      name: device.name,
      // UDID は**先頭を切らない**: "00008130-..." の前半は機種共通の固定値なので、
      // 先頭8文字だと同型機が全部同じ表示になって区別できない(後半が個体固有)
      detail: (device.model ? device.model + ' / ' : '') + 'iOS ' + device.os
        + ' / ' + device.transport + ' / ' + physicalUdidLabel(device.udid),
      registered: registered,
    });
    devicePickIosBody.appendChild(row.rowEl);
    devicePickIosRows.push({
      checkbox: row.checkbox, device: device, physical: true,
      initialChecked: registered, registeredName: registeredName, rowEl: row.rowEl,
    });
  }
  if (!iosData.available) {
    buildDevicePickEmptyRow(devicePickIosBody, iosData.error || t('wvMonitor.devicePick.iosFetchFailed'));
  } else if (iosData.devices.length === 0 && iosPhysical.length === 0) {
    buildDevicePickEmptyRow(devicePickIosBody, t('wvMonitor.devicePick.iosEmpty'));
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
      // シミュレータ本体(実体)の削除。実機行(buildPhysicalPickRow)には付けない —— 実機は
      // 「削除できる実体」を持たない。
      row.addEventListener('contextmenu', (event) => {
        event.preventDefault();
        event.stopPropagation();
        openDevicePickDeleteMenu(
          { platform: 'ios', identifier: device.udid, name: device.name, rowEl: row, checkbox: checkbox },
          event.clientX,
          event.clientY,
        );
      });
      devicePickIosBody.appendChild(row);
      devicePickIosRows.push({ checkbox: checkbox, device: device, initialChecked: registered, registeredName: registeredName, rowEl: row });
    }
  }

  const androidNameByAvd = registeredAndroidNameByAvd();
  const androidNameBySerial = registeredAndroidNameBySerial();
  const androidData = data.android;
  const androidPhysical = androidData.physicalDevices || [];
  devicePickAndroidTitle.textContent = t('wvMonitor.devicePick.androidCountTitle', {
    count: androidData.avds.length + androidPhysical.length,
  });
  for (const device of androidPhysical) {
    const registeredName = androidNameBySerial.get(device.serial);
    const registered = registeredName !== undefined;
    const row = buildPhysicalPickRow({
      platform: 'android',
      name: device.model,
      detail: (device.os ? 'Android ' + device.os + ' / ' : '') + device.serial,
      registered: registered,
    });
    devicePickAndroidBody.appendChild(row.rowEl);
    devicePickAndroidRows.push({
      checkbox: row.checkbox, physicalDevice: device, physical: true,
      initialChecked: registered, registeredName: registeredName, rowEl: row.rowEl,
    });
  }
  if (!androidData.available) {
    buildDevicePickEmptyRow(devicePickAndroidBody, androidData.error || t('wvMonitor.devicePick.androidFetchFailed'));
  } else if (androidData.avds.length === 0 && androidPhysical.length === 0) {
    buildDevicePickEmptyRow(devicePickAndroidBody, t('wvMonitor.devicePick.androidEmpty'));
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
      detailEl.textContent = detailParts.join(t('wvMonitor.devicePick.detailSeparator'));
      textWrap.append(nameEl, detailEl);
      row.append(checkbox, textWrap);
      attachDevicePickRowToggle(row, checkbox);
      syncDevicePickRowChecked(row, checkbox);
      // AVD 本体(実体)の削除。実機行には付けない(iOS ループと同じ理由)。
      row.addEventListener('contextmenu', (event) => {
        event.preventDefault();
        event.stopPropagation();
        openDevicePickDeleteMenu(
          { platform: 'android', identifier: avd.id, name: avd.displayName, rowEl: row, checkbox: checkbox },
          event.clientX,
          event.clientY,
        );
      });
      devicePickAndroidBody.appendChild(row);
      devicePickAndroidRows.push({ checkbox: checkbox, avd: avd, initialChecked: registered, registeredName: registeredName, rowEl: row });
    }
  }

  missingRows(devicePickIosBody, devicePickIosRows, 'ios',
              new Set([...iosData.devices, ...iosPhysical].map((d) => d.udid).filter(Boolean)),
              (d) => d.udid);
  missingRows(devicePickAndroidBody, devicePickAndroidRows, 'android',
              new Set([...androidData.avds.map((a) => a.id),
                       ...androidData.avds.map((a) => a.displayName),
                       ...androidPhysical.map((p) => p.serial)].filter(Boolean)),
              (d) => d.avd || d.serial);

  // **手作業のチェックは再描画をまたいで残す**(デバイスを続けて作ると一覧を取り直すため)
  restorePendingDevicePickEdits(pendingEdits);
}

// 「登録はあるが実体が無い」行。チェックは ON(登録済み)で始まり、外して OK すると登録だけ消える。
// 実体を指す操作(右クリック削除)は付けない —— 消す対象が無い
function buildMissingPickRow(platform, name, identifier) {
  const rowEl = document.createElement('div');
  rowEl.className = 'device-pick-row device-pick-row-missing';
  const checkbox = document.createElement('input');
  checkbox.type = 'checkbox';
  checkbox.checked = true;
  checkbox.addEventListener('change', () => {
    syncDevicePickRowChecked(rowEl, checkbox);
    updateDevicePickOkState();
  });
  const textWrap = document.createElement('div');
  textWrap.className = 'device-pick-row-text';
  const nameRow = document.createElement('div');
  nameRow.className = 'device-pick-row-name-line';
  const badge = document.createElement('span');
  badge.className = 'badge badge-missing';
  badge.textContent = t('wvMonitor.devicePick.missingBadge');
  const nameEl = document.createElement('span');
  nameEl.className = 'device-pick-row-name tile-name tile-name-' + platform;
  nameEl.textContent = name;
  nameRow.append(badge, nameEl);
  const detailEl = document.createElement('div');
  detailEl.className = 'device-pick-row-detail';
  detailEl.textContent = t('wvMonitor.devicePick.missingDetail', { identifier: identifier });
  textWrap.append(nameRow, detailEl);
  rowEl.append(checkbox, textWrap);
  attachDevicePickRowToggle(rowEl, checkbox);
  syncDevicePickRowChecked(rowEl, checkbox);
  return { rowEl: rowEl, checkbox: checkbox };
}

// pendingAutoChecks が指す行の checkbox だけ ON にする(initialChecked は false のままなので
// 差分としてカウントされ OK が有効になる)。renderDevicePickGroups 直後に呼ぶこと。
function applyPendingAutoCheck() {
  if (pendingAutoChecks.length === 0) {
    return;
  }
  const targets = pendingAutoChecks;
  // **当たった行のぶんだけ消費する**。一覧にまだ出ていない台(取得の行き違い)を
  // 消してしまうと、次の再描画で永久にチェックが入らない
  pendingAutoChecks = [];
  const unmatched = [];
  // **チェックだけでは足りない** —— 一覧は端末が数百行あり、作った行が画面外だと
  // 「作ったのに出てこない」と読める(2026-08-25 の報告)。最初の1行を見える位置へ運び、
  // 作った行には印を付ける
  let firstChecked = null;
  for (const target of targets) {
    // 上書きで作り直した場合、同名の古い登録が「実体なし」行として残る。**自動で外す** ——
    // 外さないと OK を押しても古い登録が残り、同名2件(片方は実体なし)になる
    if (target.name) {
      for (const row of devicePickIosRows.concat(devicePickAndroidRows)) {
        if (row.missing && row.registeredName === target.name && row.checkbox.checked) {
          row.checkbox.checked = false;
          syncDevicePickRowChecked(row.rowEl, row.checkbox);
        }
      }
    }
    let matched = false;
    if (target.udid) {
      const row = devicePickIosRows.find((r) => r.device && r.device.udid === target.udid);
      if (row) {
        row.checkbox.checked = true;
        syncDevicePickRowChecked(row.rowEl, row.checkbox);
        row.rowEl.classList.add('just-created');
        firstChecked = firstChecked || row.rowEl;
        matched = true;
      }
    }
    if (target.avd) {
      const row = devicePickAndroidRows.find((r) => r.avd && r.avd.id === target.avd);
      if (row) {
        row.checkbox.checked = true;
        syncDevicePickRowChecked(row.rowEl, row.checkbox);
        row.rowEl.classList.add('just-created');
        firstChecked = firstChecked || row.rowEl;
        matched = true;
      }
    }
    if (!matched) {
      unmatched.push(target);
    }
  }
  pendingAutoChecks = unmatched;
  if (firstChecked && typeof firstChecked.scrollIntoView === 'function') {
    firstChecked.scrollIntoView({ block: 'center' });
  }
}

// 送信中は checkbox も含め全コントロールを disabled にする。再有効化時は一律 enabled でよい。
function setDevicePickControlsEnabled(enabled) {
  for (const row of devicePickIosRows.concat(devicePickAndroidRows)) {
    row.checkbox.disabled = !enabled;
  }
}

/** 取得中の表示。**一覧は消さずに保つ** —— 空にするとダイアログが一度縮んでから
 * 新しい一覧で伸び直し、切り替えのたびに画面が跳ねる(2026-08-17 ユーザー指摘)。
 * 代わりに薄くして操作を止め、**ホストのリストボックスの右**に「読み込み中...」を出す
 * (一覧側に出すと同じ理由で高さが変わる)。中身の入れ替えは応答が届いた1回だけ。
 * 取得中はホスト選択も止める(往復が重なると、あとから来た応答がどちらのものか分からなくなる)。 */
function beginDevicePickLoading() {
  devicePickList.classList.add('loading');
  for (const row of devicePickIosRows.concat(devicePickAndroidRows)) {
    row.checkbox.disabled = true;
  }
  devicePickLoading.style.display = '';
  devicePickOk.disabled = true;
  devicePickMachineSelect.disabled = true;
}

/** 応答(成功・失敗どちらでも)が届いたら操作を戻す。ここで戻さないとホストを二度と切り替えられない。 */
function endDevicePickLoading() {
  devicePickList.classList.remove('loading');
  devicePickLoading.style.display = 'none';
  devicePickMachineSelect.disabled = false;
  // **行のチェックも戻す**。begin 側で無効化しているので、ここで戻さないと取得に失敗したとき
  // 見た目は通常なのに全行が反応しない状態が残る(2026-08-17 のレビュー指摘)。
  // 応答が来て再描画される場合は新しい行に置き換わるため二重には効かない
  for (const row of devicePickIosRows.concat(devicePickAndroidRows)) {
    row.checkbox.disabled = false;
  }
}

// 作成成功後、モーダルが開いていれば一覧を再取得する(他行の未確定差分は破棄される。単純さ優先)。
function reloadDevicePickIfOpen() {
  if (!devicePickOpen) {
    return;
  }
  beginDevicePickLoading();
  vscode.postMessage({ type: 'installedDevicesRequest', source: currentDeviceSource() });
}

function openDevicePickModal() {
  if (!selectedMachine) {
    return;
  }
  devicePickOpen = true;
  devicePickAdding = false;
  pendingAutoChecks = []; // 前回開いた際の残留分があれば捨てて、新規セッションはクリーンに始める
  devicePickOk.textContent = 'OK';
  devicePickCancel.disabled = false;
  const machine = findMachine(selectedMachine);
  // ホストを先に確定させてから取得表示を出す(表示に「どこから取るか」を載せるため)
  resetDevicePickMachine(machine ? machine.machine ?? null : null);
  beginDevicePickLoading();
  devicePickOverlay.classList.add('visible');
  vscode.postMessage({ type: 'installedDevicesRequest', source: currentDeviceSource() });
}

function closeDevicePickModal() {
  if (!devicePickOpen || devicePickAdding) {
    return;
  }
  devicePickOpen = false;
  pendingAutoChecks = []; // 閉じた後に届く installedDevices 応答で誤適用しないようクリアする
  batchCreatedDevices = [];
  closeDevicePickDeleteMenu();
  devicePickOverlay.classList.remove('visible');
}

export function applyInstalledDevices(message) {
  endDevicePickLoading();
  if (message.ok && message.data) {
    // モーダルが閉じていてもキャッシュだけは更新する(編集フォームが使うため)
    cachePhysicalDeviceInfo(message.data);
    refreshSelectedDeviceEditor();
  }
  if (!devicePickOpen) {
    return; // モーダルを閉じた後に届いた応答は無視する(applyDeviceCatalog と同じ方針)
  }
  if (!message.ok || !message.data) {
    devicePickError.classList.remove('info');
    devicePickError.textContent = message.error || t('wvMonitor.devicePick.fetchFailed');
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
  devicePickError.textContent = message.error || t('wvMonitor.devicePick.syncFailed');
}

// ---- 行の右クリックメニュー(削除。#device-pick-delete-menu) --------------------------
// machineProfilesTab.js の #machine-device-menu(プロファイルからの除去)と見た目・挙動は同じ
// パターンだが、DOM 要素・対象は独立させている(こちらはホスト上の実体を消す)。

function closeDevicePickDeleteMenu() {
  if (!devicePickDeleteMenuEntry) {
    return;
  }
  devicePickDeleteMenuEntry = null;
  devicePickDeleteMenu.classList.remove('visible');
}

function openDevicePickDeleteMenu(entry, clientX, clientY) {
  devicePickDeleteMenuEntry = entry;
  devicePickDeleteMenu.classList.add('visible');
  clampMenuPosition(devicePickDeleteMenu, clientX, clientY);
}

// その行だけ操作不可にする(checkbox 無効化 + 薄く表示。他の行・OK/Cancel は引き続き操作できる)。
function setDevicePickRowDeleting(rowEl, checkbox, deleting) {
  rowEl.classList.toggle('deleting', deleting);
  checkbox.disabled = deleting;
}

devicePickDeleteMenuItemBtn.addEventListener('click', (event) => {
  event.stopPropagation();
  const entry = devicePickDeleteMenuEntry;
  closeDevicePickDeleteMenu();
  if (!entry || devicePickDeletingIdentifiers.has(entry.identifier)) {
    return;
  }
  devicePickDeletingIdentifiers.add(entry.identifier);
  setDevicePickRowDeleting(entry.rowEl, entry.checkbox, true);
  vscode.postMessage({
    type: 'devicePickDeviceDelete',
    platform: entry.platform,
    identifier: entry.identifier,
    name: entry.name,
    source: currentDeviceSource(),
  });
});

// devicePickDeviceDelete への応答。確認モーダル(ホスト側)を含めると数秒かかるため、その間に
// ダイアログを閉じ直されうる(closeDevicePickModal は削除中でも通す設計)。行が現存すれば
// 操作可能に戻し、モーダルが閉じていれば表示更新はしない(applyInstalledDevices と同じ方針。
// 失敗・referencedBy の通知はホスト側の vscode 通知が担うため、閉じていても利用者に届く)。
export function applyDevicePickDeviceDeleteResult(message) {
  devicePickDeletingIdentifiers.delete(message.identifier);
  const row =
    devicePickIosRows.find((r) => r.device && r.device.udid === message.identifier) ||
    devicePickAndroidRows.find((r) => r.avd && r.avd.id === message.identifier);
  if (row) {
    setDevicePickRowDeleting(row.rowEl, row.checkbox, false);
  }
  if (message.ok) {
    // 削除できた実体を一覧から落とすため取り直す(reloadDevicePickIfOpen は devicePickOpen を
    // 見て自分で no-op になる)。
    reloadDevicePickIfOpen();
    return;
  }
  if (!devicePickOpen) {
    return;
  }
  devicePickError.classList.remove('info');
  devicePickError.textContent = message.error || t('wvMonitor.devicePick.deleteFailed');
}

document.addEventListener('click', (event) => {
  if (devicePickDeleteMenuEntry && !devicePickDeleteMenu.contains(event.target)) {
    closeDevicePickDeleteMenu();
  }
});
document.addEventListener('keydown', (event) => {
  if (event.key !== 'Escape' || !devicePickDeleteMenuEntry) {
    return;
  }
  closeDevicePickDeleteMenu();
  event.preventDefault();   // メニューを閉じただけで、奥のダイアログは閉じない
});
document.addEventListener('scroll', () => closeDevicePickDeleteMenu(), true);
window.addEventListener('resize', () => closeDevicePickDeleteMenu());
// 行上の contextmenu は stopPropagation 済み。行外で右クリックした場合に残さないためのガード。
document.addEventListener('contextmenu', () => closeDevicePickDeleteMenu());

btnDeviceAddExisting.addEventListener('click', () => openDevicePickModal());
// 見出しの「+」は**押した側の OS 種別**で開く(どちらを増やしたいかは見出しで表明済み)
devicePickIosAddNewBtn.addEventListener('click', () => openDeviceAddModal('ios'));
devicePickAndroidAddNewBtn.addEventListener('click', () => openDeviceAddModal('android'));
devicePickCancel.addEventListener('click', () => closeDevicePickModal());
// ホスト選択を開いたまま変更した場合、選び直したホストから一覧を取り直す。
devicePickMachineSelect.addEventListener('change', () => reloadDevicePickIfOpen());
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
      // 実機は simulator/os を持たない(実体を指すのは udid だけ)
      add.push(row.physical
        ? { platform: 'ios', kind: 'physical', name: row.device.name, udid: row.device.udid,
            model: row.device.model, os: row.device.os }
        : {
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
      add.push(row.physical
        ? { platform: 'android', kind: 'physical', name: row.physicalDevice.model,
            serial: row.physicalDevice.serial,
            model: row.physicalDevice.model, os: row.physicalDevice.os }
        : { platform: 'android', name: row.avd.displayName, avd: row.avd.id });
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
  devicePickOk.textContent = t('wvMonitor.devicePick.applying');
  devicePickError.classList.remove('info');
  devicePickError.textContent = '';
  vscode.postMessage({ type: 'machineDevicesSync', machine: selectedMachine, add: add, remove: remove, source: currentDeviceSource() });
});
// 手前(追加ダイアログ・削除メニュー)が消費した Esc では閉じない。判定は
// event.defaultPrevented ―― deviceAddOpen を見る形だと、手前が先に閉じてフラグを下ろした後に
// ここが走り、2枚同時に閉じる(登録順に依存する読み合いになっていた)。
document.addEventListener('keydown', (event) => {
  if (event.key !== 'Escape' || event.defaultPrevented) {
    return;
  }
  closeDevicePickModal();
});
