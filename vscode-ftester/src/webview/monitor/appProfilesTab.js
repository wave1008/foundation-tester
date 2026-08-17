// 他モジュールの状態には依存しない(vscode の postMessage/受信ハンドラのみで完結)。

import { vscode } from './vscodeApi.js';
import { t } from '../i18n.js';

// dirty管理・再ロードの方針は runProfilesTab.js と同じ(フォールバックは常に一覧の先頭。
// 「現在値」に相当する設定が無いため)。クライアント側必須検証は無い(全フィールド省略可。
// Swift側 validate-profile が担当)。

const appProfileSelect = document.getElementById('app-profile-select');
const appProfileNameStatic = document.getElementById('app-profile-name-static');
const btnAppProfileAdd = document.getElementById('btn-app-profile-add');
const btnAppProfileCopy = document.getElementById('btn-app-profile-copy');
const btnAppProfileRemove = document.getElementById('btn-app-profile-remove');
const btnAppProfileRename = document.getElementById('btn-app-profile-rename');
const appProfilePlaceholder = document.getElementById('app-profile-placeholder');
const appProfileEditor = document.getElementById('app-profile-editor');
const appProfileError = document.getElementById('app-profile-error');
const appProfileConfirm = document.getElementById('app-profile-confirm');
const appProfileCancel = document.getElementById('app-profile-cancel');

// common: autoInstallのみ(表示名はios/androidそれぞれに持ち、commonからは継承しない)。
// ios/android: appName/app/appPath(autoInstallはcommonに一本化)。
const appProfileGroups = {
  common: {
    autoInstall: document.getElementById('app-profile-common-auto-install'),
  },
  ios: {
    appName: document.getElementById('app-profile-ios-app-name'),
    app: document.getElementById('app-profile-ios-app'),
    appPath: document.getElementById('app-profile-ios-app-path'),
  },
  android: {
    appName: document.getElementById('app-profile-android-app-name'),
    app: document.getElementById('app-profile-android-app'),
    appPath: document.getElementById('app-profile-android-app-path'),
  },
};
const APP_PROFILE_PLATFORM_GROUP_NAMES = ['ios', 'android'];

// チェックボックス⇄"true"/"false"文字列(monitorProfileForms.ts AppProfileCommonFields.autoInstallと同じ)。
// 保存意味論: true→autoInstall:trueをセット、false→キー削除。
function getAppProfileAutoInstall(dom) {
  return dom.autoInstall.checked ? 'true' : 'false';
}
function setAppProfileAutoInstall(dom, value) {
  dom.autoInstall.checked = value === 'true';
}

// 直近受信の一覧(profileInfo.apps 由来)。
let appProfileNames = [];
// 編集対象のアプリプロファイル名(一覧が0件なら null)。
let selectedAppProfile = null;
// 直近ロード(appProfileData ok:true)時点のフィールド値。null の間はフォーム非表示。
let appProfileOriginalFields = null;
let appProfileDirty = false;
let appProfileSubmitting = false;

function appProfileEditing() {
  return appProfileDirty || appProfileSubmitting;
}

function refreshAppProfileButtonsUi() {
  appProfileConfirm.disabled = appProfileSubmitting || !appProfileDirty;
  appProfileCancel.style.display = appProfileDirty ? '' : 'none';
  appProfileCancel.disabled = appProfileSubmitting;
}
function setAppProfileDirty(dirty) {
  appProfileDirty = dirty;
  refreshAppProfileButtonsUi();
}

function showAppProfilePlaceholder(text) {
  appProfileOriginalFields = null;
  appProfileSubmitting = false;
  appProfileEditor.style.display = 'none';
  appProfilePlaceholder.style.display = '';
  appProfilePlaceholder.textContent = text;
  setAppProfileDirty(false);
}

function requestAppProfileLoad() {
  if (!selectedAppProfile) {
    showAppProfilePlaceholder(t('wvMonitor2.appProfile.none'));
    return;
  }
  // 応答(appProfileData)が来るまで編集させない(requestRunProfileLoad と同じ理由)。
  showAppProfilePlaceholder(t('wvMonitor2.common.loading'));
  vscode.postMessage({ type: 'appProfileLoad', profile: selectedAppProfile });
}

// profileInfo受信(他の2ハンドラと独立)。「現在値」相当が無いため、フォールバックは常に先頭。
export function applyAppProfileInfo(message) {
  appProfileNames = Array.isArray(message.apps) ? message.apps : [];

  const previous = selectedAppProfile;
  if (selectedAppProfile === null || !appProfileNames.includes(selectedAppProfile)) {
    selectedAppProfile = appProfileNames.length > 0 ? appProfileNames[0] : null;
  }
  renderAppProfileSelect();
  // [+]は常に有効(追加先は常にある)。コピー/−/✏は対象が要るため一覧0件時は無効化。
  btnAppProfileAdd.disabled = false;
  btnAppProfileCopy.disabled = appProfileNames.length === 0;
  btnAppProfileRemove.disabled = appProfileNames.length === 0;
  btnAppProfileRename.disabled = appProfileNames.length === 0;

  if (selectedAppProfile !== previous) {
    requestAppProfileLoad();
    return;
  }
  if (selectedAppProfile !== null && !appProfileEditing()) {
    requestAppProfileLoad();
  } else if (selectedAppProfile === null) {
    showAppProfilePlaceholder(t('wvMonitor2.appProfile.none'));
  }
}

function renderAppProfileSelect() {
  if (appProfileNames.length >= 1) {
    appProfileSelect.style.display = '';
    appProfileNameStatic.style.display = 'none';
    appProfileSelect.textContent = '';
    for (const name of appProfileNames) {
      const option = document.createElement('option');
      option.value = name;
      option.textContent = name;
      appProfileSelect.appendChild(option);
    }
    appProfileSelect.value = selectedAppProfile || '';
  } else {
    appProfileSelect.style.display = 'none';
    appProfileNameStatic.style.display = '';
  }
}

appProfileSelect.addEventListener('change', () => {
  selectedAppProfile = appProfileSelect.value;
  requestAppProfileLoad();
});

btnAppProfileAdd.addEventListener('click', () => vscode.postMessage({ type: 'appProfileAdd' }));
btnAppProfileCopy.addEventListener('click', () => {
  if (selectedAppProfile) {
    vscode.postMessage({ type: 'appProfileCopy', profile: selectedAppProfile });
  }
});
btnAppProfileRemove.addEventListener('click', () => {
  if (selectedAppProfile) {
    vscode.postMessage({ type: 'appProfileDelete', profile: selectedAppProfile });
  }
});
btnAppProfileRename.addEventListener('click', () => {
  if (selectedAppProfile) {
    vscode.postMessage({ type: 'appProfileRename', profile: selectedAppProfile });
  }
});

// 追加/コピー/名前変更直後にhostから届く選択切替通知(applyRunProfileSelectedと同じ、詳細はそちら参照)。
export function applyAppProfileSelected(message) {
  if (!appProfileNames.includes(message.name)) {
    return;
  }
  selectedAppProfile = message.name;
  renderAppProfileSelect();
  requestAppProfileLoad();
}

// 選択変更直後に届く「前の選択」への応答を無視するガード(applyRunProfileDataと同じ)。
export function applyAppProfileData(message) {
  if (message.profile !== selectedAppProfile) {
    return;
  }
  if (appProfileEditing()) {
    return;
  }
  if (!message.ok || !message.fields) {
    showAppProfilePlaceholder(message.error || t('wvMonitor2.appProfile.loadFailed'));
    return;
  }
  renderAppProfileEditor(message.fields);
}

// ロード済みの値でフォームを作り直す(編集途中の値は破棄する)。
function renderAppProfileEditor(fields) {
  appProfileOriginalFields = fields;
  appProfileSubmitting = false;
  appProfileError.textContent = '';

  setAppProfileAutoInstall(appProfileGroups.common, fields.common.autoInstall);
  for (const group of APP_PROFILE_PLATFORM_GROUP_NAMES) {
    const dom = appProfileGroups[group];
    const values = fields[group];
    dom.appName.value = values.appName;
    dom.app.value = values.app;
    dom.appPath.value = values.appPath;
  }

  setAppProfileControlsEnabled(true);
  appProfileConfirm.textContent = t('wvMonitor2.common.confirm');
  appProfilePlaceholder.style.display = 'none';
  appProfileEditor.style.display = '';
  setAppProfileDirty(false);
}

// appProfileSaveのfieldsと同じ形で集める(text系はtrim済み)。
function collectAppProfileFields() {
  const fields = {
    common: {
      autoInstall: getAppProfileAutoInstall(appProfileGroups.common),
    },
  };
  for (const group of APP_PROFILE_PLATFORM_GROUP_NAMES) {
    const dom = appProfileGroups[group];
    fields[group] = {
      appName: dom.appName.value.trim(),
      app: dom.app.value.trim(),
      appPath: dom.appPath.value.trim(),
    };
  }
  return fields;
}

function appProfileValuesEqual(fields) {
  const current = collectAppProfileFields();
  if (current.common.autoInstall !== fields.common.autoInstall) {
    return false;
  }
  return APP_PROFILE_PLATFORM_GROUP_NAMES.every((group) => {
    const a = current[group];
    const b = fields[group];
    return a.appName === b.appName && a.app === b.app && a.appPath === b.appPath;
  });
}

function onAppProfileFormInput() {
  if (appProfileOriginalFields === null || appProfileSubmitting) {
    return;
  }
  setAppProfileDirty(!appProfileValuesEqual(appProfileOriginalFields));
  // 入力を変えたら前回のエラー表示は古くなるので消す。
  appProfileError.textContent = '';
}

appProfileGroups.common.autoInstall.addEventListener('change', onAppProfileFormInput);
for (const group of APP_PROFILE_PLATFORM_GROUP_NAMES) {
  const dom = appProfileGroups[group];
  dom.appName.addEventListener('input', onAppProfileFormInput);
  dom.app.addEventListener('input', onAppProfileFormInput);
  dom.appPath.addEventListener('input', onAppProfileFormInput);
}

function setAppProfileControlsEnabled(enabled) {
  appProfileGroups.common.autoInstall.disabled = !enabled;
  for (const group of APP_PROFILE_PLATFORM_GROUP_NAMES) {
    const dom = appProfileGroups[group];
    dom.appName.disabled = !enabled;
    dom.app.disabled = !enabled;
    dom.appPath.disabled = !enabled;
  }
}

appProfileConfirm.addEventListener('click', () => {
  if (appProfileConfirm.disabled || appProfileSubmitting || !selectedAppProfile) {
    return;
  }
  appProfileSubmitting = true;
  setAppProfileControlsEnabled(false);
  appProfileConfirm.textContent = t('wvMonitor2.common.confirming');
  appProfileError.textContent = '';
  refreshAppProfileButtonsUi();
  vscode.postMessage({
    type: 'appProfileSave',
    profile: selectedAppProfile,
    fields: collectAppProfileFields(),
  });
});

// requestAppProfileLoad内部でshowAppProfilePlaceholder→setAppProfileDirty(false)の順に呼ばれるため、
// dirty解除→再ロードの順序が保たれる(順序を崩すとapplyAppProfileDataの編集中ガードに阻まれる)。
appProfileCancel.addEventListener('click', () => {
  if (appProfileCancel.disabled) {
    return;
  }
  appProfileError.textContent = '';
  requestAppProfileLoad();
});

// Enter=確定 / Esc=キャンセル(runProfilesTab.js の同名ブロックと同じ方針)。
document.getElementById('app-profile-section').addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && !event.target.closest('button') && !appProfileConfirm.disabled) {
    event.preventDefault();
    appProfileConfirm.click();
  } else if (event.key === 'Escape' && appProfileDirty && !appProfileCancel.disabled) {
    event.preventDefault();
    appProfileCancel.click();
  }
});

// ok:trueなら続けてhostからappProfileDataが来てフォームが最新化される。ok:falseはエラー表示のみ。
export function applyAppProfileSaveResult(message) {
  if (message.profile !== selectedAppProfile) {
    return;
  }
  appProfileSubmitting = false;
  appProfileConfirm.textContent = t('wvMonitor2.common.confirm');
  setAppProfileControlsEnabled(true);
  if (message.ok) {
    appProfileError.textContent = '';
    setAppProfileDirty(false);
  } else {
    refreshAppProfileButtonsUi();
    appProfileError.textContent = message.error || t('wvMonitor2.appProfile.saveFailed');
  }
}

// apps/<name>.json の外部編集(watcher onDidChange)。自分の保存直後の通知も来るが再ロードは冪等。
export function applyAppProfileFileChanged(message) {
  if (message.name === selectedAppProfile && !appProfileEditing()) {
    vscode.postMessage({ type: 'appProfileLoad', profile: selectedAppProfile });
  }
}
