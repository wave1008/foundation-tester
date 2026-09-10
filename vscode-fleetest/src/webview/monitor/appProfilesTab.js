// 他モジュールの状態には依存しない(vscode の postMessage/受信ハンドラのみで完結)。

import { vscode } from './vscodeApi.js';
import { t } from '../i18n.js';

// 自動保存・dirty管理・再ロードの方針は runProfilesTab.js と同じ(冒頭コメント参照。フォールバックは
// 常に一覧の先頭。「現在値」に相当する設定が無いため)。クライアント側必須検証は無い(全フィールド
// 省略可。Swift側 validate-profile が担当)。

const appProfileSelect = document.getElementById('app-profile-select');
const appProfileNameStatic = document.getElementById('app-profile-name-static');
const btnAppProfileAdd = document.getElementById('btn-app-profile-add');
const btnAppProfileCopy = document.getElementById('btn-app-profile-copy');
const btnAppProfileRemove = document.getElementById('btn-app-profile-remove');
const btnAppProfileRename = document.getElementById('btn-app-profile-rename');
const appProfilePlaceholder = document.getElementById('app-profile-placeholder');
const appProfileEditor = document.getElementById('app-profile-editor');
const appProfileError = document.getElementById('app-profile-error');

// common: autoInstallのみ(表示名はios/androidそれぞれに持ち、commonからは継承しない)。
// ios/android: appName/app/appPath(autoInstallはcommonに一本化)。
// appPathPhysical(実機に配るビルド)はiOSだけ — Androidは同じAPKが両方で動くので欄が無く、
// フィールドにも持たない(持たせるとmonitorProfileForms.tsが手書きのandroid.appPathPhysicalを消す)。
const appProfileGroups = {
  common: {
    autoInstall: document.getElementById('app-profile-common-auto-install'),
  },
  ios: {
    appName: document.getElementById('app-profile-ios-app-name'),
    app: document.getElementById('app-profile-ios-app'),
    appPath: document.getElementById('app-profile-ios-app-path'),
    appPathPhysical: document.getElementById('app-profile-ios-app-path-physical'),
  },
  android: {
    appName: document.getElementById('app-profile-android-app-name'),
    app: document.getElementById('app-profile-android-app'),
    appPath: document.getElementById('app-profile-android-app-path'),
  },
};
// グループごとの欄の集合(monitorProfileForms.ts の AppProfileIOSFields/AppProfilePlatformFields と対)。
const APP_PROFILE_PLATFORM_FIELD_KEYS = {
  ios: ['appName', 'app', 'appPath', 'appPathPhysical'],
  android: ['appName', 'app', 'appPath'],
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
// 送信中の保存要求が送った値(成功したら新しい appProfileOriginalFields)と、送信中に確定した変更の有無。
let appProfileSubmittedFields = null;
let appProfileSaveQueued = false;

function appProfileEditing() {
  return appProfileDirty || appProfileSubmitting;
}

function setAppProfileDirty(dirty) {
  appProfileDirty = dirty;
}

function showAppProfilePlaceholder(text) {
  appProfileOriginalFields = null;
  appProfileSubmitting = false;
  appProfileSubmittedFields = null;
  appProfileSaveQueued = false;
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
  // 保存結果の反響で画面と同じ値なら作り直さない(applyRunProfileData と同じ理由)
  if (appProfileOriginalFields !== null && appProfileValuesEqual(message.fields)) {
    appProfileOriginalFields = message.fields;
    return;
  }
  renderAppProfileEditor(message.fields);
}

// ロード済みの値でフォームを作り直す(編集途中の値は破棄する)。
function renderAppProfileEditor(fields) {
  appProfileOriginalFields = fields;
  appProfileSubmitting = false;
  appProfileSubmittedFields = null;
  appProfileSaveQueued = false;
  appProfileError.textContent = '';

  setAppProfileAutoInstall(appProfileGroups.common, fields.common.autoInstall);
  for (const group of APP_PROFILE_PLATFORM_GROUP_NAMES) {
    const dom = appProfileGroups[group];
    const values = fields[group];
    for (const key of APP_PROFILE_PLATFORM_FIELD_KEYS[group]) {
      dom[key].value = values[key];
    }
  }

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
    const values = {};
    for (const key of APP_PROFILE_PLATFORM_FIELD_KEYS[group]) {
      values[key] = dom[key].value.trim();
    }
    fields[group] = values;
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
    return APP_PROFILE_PLATFORM_FIELD_KEYS[group].every((key) => a[key] === b[key]);
  });
}

function onAppProfileFormInput() {
  if (appProfileOriginalFields === null) {
    return;
  }
  setAppProfileDirty(!appProfileValuesEqual(appProfileOriginalFields));
  // 入力を変えたら前回のエラー表示は古くなるので消す。
  appProfileError.textContent = '';
}

// 入力を終えたとき(change)に呼ぶ(saveRunProfileIfDirty と同じ契約)。
function saveAppProfileIfDirty() {
  if (appProfileOriginalFields === null || !selectedAppProfile) {
    return;
  }
  if (appProfileSubmitting) {
    appProfileSaveQueued = true;
    return;
  }
  appProfileSaveQueued = false;
  if (!appProfileDirty) {
    return;
  }
  appProfileSubmitting = true;
  appProfileSubmittedFields = collectAppProfileFields();
  appProfileError.textContent = '';
  vscode.postMessage({ type: 'appProfileSave', profile: selectedAppProfile, fields: appProfileSubmittedFields });
}

// dirty の更新と保存はフォーム全体でバブリングで受ける(runProfilesTab.js の同名ブロックと同じ方針)。
appProfileEditor.addEventListener('input', onAppProfileFormInput);
appProfileEditor.addEventListener('change', () => {
  onAppProfileFormInput();
  saveAppProfileIfDirty();
});

// Enter = テキスト欄の入力を終えて保存 / Esc = 未保存の編集を破棄して再ロード(runProfilesTab.js と同じ)。
document.getElementById('app-profile-section').addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && event.target.matches('input[type="text"]')) {
    event.preventDefault();
    saveAppProfileIfDirty();
  } else if (event.key === 'Escape' && appProfileDirty && !appProfileSubmitting) {
    event.preventDefault();
    appProfileError.textContent = '';
    requestAppProfileLoad();
  }
});

// ok:trueなら続けてhostからappProfileDataが来る。ok:falseはエラー表示のみで入力値は保持する。
export function applyAppProfileSaveResult(message) {
  if (message.profile !== selectedAppProfile || !appProfileSubmitting) {
    return;
  }
  appProfileSubmitting = false;
  if (message.ok) {
    appProfileOriginalFields = appProfileSubmittedFields;
    appProfileError.textContent = '';
  } else {
    appProfileError.textContent = message.error || t('wvMonitor2.appProfile.saveFailed');
  }
  appProfileSubmittedFields = null;
  setAppProfileDirty(!appProfileValuesEqual(appProfileOriginalFields));
  if (appProfileSaveQueued) {
    saveAppProfileIfDirty();
  }
}

// apps/<name>.json の外部編集(watcher onDidChange)。自分の保存直後の通知も来るが再ロードは冪等。
export function applyAppProfileFileChanged(message) {
  if (message.name === selectedAppProfile && !appProfileEditing()) {
    vscode.postMessage({ type: 'appProfileLoad', profile: selectedAppProfile });
  }
}
