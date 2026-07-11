// appProfilesTab.js
// 「プロファイル」タブ中段の「アプリプロファイル」設定フォームを担う。他モジュールの状態には
// 依存せず、vscode の postMessage/受信ハンドラのみで完結する。

import { vscode } from './vscodeApi.js';

// ---- プロファイルタブ中段: アプリプロファイルの設定フォーム -----------------------
// 一覧・初期選択は既存 profileInfo(applyProfileInfo/applyRunProfileInfo とは独立に
// applyAppProfileInfo で受ける。message.apps を使う)。この選択は webview 内だけで完結し、
// 他のどの設定にも連動しない(実行プロファイルセクションと違い「現在値」に相当する設定が
// 無いため、フォールバックは常に一覧の先頭)。dirty 管理・再ロードの方針は実行プロファイル
// セクション(下記)と同じ:
// - フォーム値と appProfileOriginalFields の比較で「確定」を有効化。
// - 選択変更(明示操作)で編集破棄して再ロード。
// - profileInfo 再受信時、編集中(dirty/送信中)ならフォーム値保持、未編集なら再ロード。
//   編集対象が一覧から消えたらフォールバック(先頭)。
// - appProfileFileChanged(外部編集)は編集対象と同名 && 未編集のときのみ再ロード。
// クライアント側の必須検証は無い(common/ios/android の全フィールドが省略可のため。
// Swift 側 validate-profile の役割)。

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

// common/ios/android それぞれの DOM 参照をまとめて持つ(renderAppProfileEditor・
// collectAppProfileFields・appProfileValuesEqual・setAppProfileControlsEnabled が使う)。
// common は表示名(appName)+自動インストールのチェックボックス(heal と同じマークアップ。
// 既定=チェックOFF=無効)を持ち、ios/android は自動インストールを持たず表示名/アプリID/
// パッケージパスの3項目のみ(自動インストールは common に一本化されている)。
const appProfileGroups = {
  common: {
    appName: document.getElementById('app-profile-common-app-name'),
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
const APP_PROFILE_GROUP_NAMES = ['common', 'ios', 'android'];
// app/appPath を持つのは ios/android のみ(common には無い)。
const APP_PROFILE_PLATFORM_GROUP_NAMES = ['ios', 'android'];

// 自動インストールはチェックボックス1つで内部表現("true"/"false")の読み書きを行う
// (monitorModel.ts の AppProfileCommonFields.autoInstall と同じ2値の文字列)。保存意味論:
// true→autoInstall:true をセット、false→キー削除。
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

// dirty(=確定ボタン有効)と、それに連動する確定/キャンセルボタンの見た目をまとめて更新する
// (editorForm の refreshEditorButtonsUi/setEditorDirty と同じ方針)。
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
    showAppProfilePlaceholder('アプリプロファイルがありません。');
    return;
  }
  // 応答(appProfileData)が来るまで編集させない(requestRunProfileLoad と同じ理由)。
  showAppProfilePlaceholder('読み込み中...');
  vscode.postMessage({ type: 'appProfileLoad', profile: selectedAppProfile });
}

// profileInfo 受信(applyProfileInfo/applyRunProfileInfo と独立)。選択の維持/フォールバックと
// 再ロードを行う。「現在値」に相当する設定が無いため、applyRunProfileInfo と違い先頭への
// フォールバックのみ。
export function applyAppProfileInfo(message) {
  appProfileNames = Array.isArray(message.apps) ? message.apps : [];

  const previous = selectedAppProfile;
  if (selectedAppProfile === null || !appProfileNames.includes(selectedAppProfile)) {
    selectedAppProfile = appProfileNames.length > 0 ? appProfileNames[0] : null;
  }
  renderAppProfileSelect();
  // [+] は profileInfo を受信できた時点で追加先(プロジェクト)があるので常に有効。
  // コピー/−/✏ は対象(選択中のアプリプロファイル)が要るので、一覧0件のときは無効化する
  // (applyRunProfileInfo と同じ方針)。
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
    showAppProfilePlaceholder('アプリプロファイルがありません。');
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
  // 選択変更は明示操作なので、編集途中の値を破棄して選択先を再ロードする。
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

// 追加/コピー/名前変更の直後にホストから届く、選択(編集対象)を新プロファイルへ移す通知
// (applyRunProfileSelected と同じ趣旨)。
export function applyAppProfileSelected(message) {
  if (!appProfileNames.includes(message.name)) {
    return;
  }
  selectedAppProfile = message.name;
  renderAppProfileSelect();
  requestAppProfileLoad();
}

// appProfileData 受信: 編集対象と同じプロファイルの応答のみ反映する(applyRunProfileData と
// 同じガード)。
export function applyAppProfileData(message) {
  if (message.profile !== selectedAppProfile) {
    return;
  }
  if (appProfileEditing()) {
    return;
  }
  if (!message.ok || !message.fields) {
    showAppProfilePlaceholder(message.error || 'アプリプロファイルを読み込めませんでした。');
    return;
  }
  renderAppProfileEditor(message.fields);
}

// iOS/Android の表示名(appName)入力欄のプレースホルダーに、共通(common)の表示名フィールドの
// 現在の入力値を表示する。appName は common → platform の順で後勝ちマージされるため、platform
// 側が空欄のときの実効値は common の値になる — その「継承される値」をウォーターマークとして
// 見せることで、空欄の意味(未入力=common の値がそのまま使われる)を一目で分かるようにする。
// 共通の表示名が空ならプレースホルダーも空でよい(素の value をそのまま使う)。
function updateAppProfileNamePlaceholders() {
  const inherited = appProfileGroups.common.appName.value;
  for (const group of APP_PROFILE_PLATFORM_GROUP_NAMES) {
    appProfileGroups[group].appName.placeholder = inherited;
  }
}

// ロード済みの値でフォームを作り直す(編集途中の値は破棄する)。
function renderAppProfileEditor(fields) {
  appProfileOriginalFields = fields;
  appProfileSubmitting = false;
  appProfileError.textContent = '';

  // 表示名(appName)は common/ios/android 共通で持つ唯一のフィールドなので3グループまとめて
  // 設定する。
  for (const group of APP_PROFILE_GROUP_NAMES) {
    appProfileGroups[group].appName.value = fields[group].appName;
  }
  // 自動インストールは common に一本化されている。
  setAppProfileAutoInstall(appProfileGroups.common, fields.common.autoInstall);
  // アプリID・パッケージパスは ios/android のみ(common には無い)。
  for (const group of APP_PROFILE_PLATFORM_GROUP_NAMES) {
    const dom = appProfileGroups[group];
    const values = fields[group];
    dom.app.value = values.app;
    dom.appPath.value = values.appPath;
  }
  // プリフィル直後の共通表示名を反映してプレースホルダーを初期化する。
  updateAppProfileNamePlaceholders();

  setAppProfileControlsEnabled(true);
  appProfileConfirm.textContent = '確定';
  appProfilePlaceholder.style.display = 'none';
  appProfileEditor.style.display = '';
  setAppProfileDirty(false);
}

// 現在のフォーム入力値を、appProfileSave の fields と同じ形(common は表示名+自動インストールの
// 2項目、ios/android は表示名/アプリID/パッケージパスの3項目。text 系は trim 済み)で集める。
function collectAppProfileFields() {
  const fields = {
    common: {
      appName: appProfileGroups.common.appName.value.trim(),
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
  if (
    current.common.appName !== fields.common.appName ||
    current.common.autoInstall !== fields.common.autoInstall
  ) {
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
  // 入力を変えたら前回のエラー表示は古くなるので消す(runProfileError と同じ方針)。
  appProfileError.textContent = '';
}

for (const group of APP_PROFILE_GROUP_NAMES) {
  appProfileGroups[group].appName.addEventListener('input', onAppProfileFormInput);
}
appProfileGroups.common.autoInstall.addEventListener('change', onAppProfileFormInput);
// 共通の表示名を編集するたび、iOS/Android のプレースホルダー(継承値のライブプレビュー)を
// 更新する。
appProfileGroups.common.appName.addEventListener('input', updateAppProfileNamePlaceholders);
for (const group of APP_PROFILE_PLATFORM_GROUP_NAMES) {
  const dom = appProfileGroups[group];
  dom.app.addEventListener('input', onAppProfileFormInput);
  dom.appPath.addEventListener('input', onAppProfileFormInput);
}

function setAppProfileControlsEnabled(enabled) {
  for (const group of APP_PROFILE_GROUP_NAMES) {
    appProfileGroups[group].appName.disabled = !enabled;
  }
  appProfileGroups.common.autoInstall.disabled = !enabled;
  for (const group of APP_PROFILE_PLATFORM_GROUP_NAMES) {
    const dom = appProfileGroups[group];
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
  appProfileConfirm.textContent = '確定中...';
  appProfileError.textContent = '';
  refreshAppProfileButtonsUi();
  vscode.postMessage({
    type: 'appProfileSave',
    profile: selectedAppProfile,
    fields: collectAppProfileFields(),
  });
});

// キャンセル: dirty/送信中フラグを先に解除してから appProfileLoad を再送する
// (applyAppProfileData は appProfileEditing() の間は応答を無視するガードがあるため、
// 先に解除しておかないと再ロード結果が反映されない)。requestAppProfileLoad は内部で
// showAppProfilePlaceholder→setAppProfileDirty(false) を呼ぶため、この順序を満たす。
appProfileCancel.addEventListener('click', () => {
  if (appProfileCancel.disabled) {
    return;
  }
  appProfileError.textContent = '';
  requestAppProfileLoad();
});

// appProfileSave の結果。ok なら dirty 解除(ホストが続けて appProfileData を送るので、
// フォームはそこで最新値に作り直される)。ok:false ならエラー表示のみで入力値は残す。
export function applyAppProfileSaveResult(message) {
  if (message.profile !== selectedAppProfile) {
    return;
  }
  appProfileSubmitting = false;
  appProfileConfirm.textContent = '確定';
  setAppProfileControlsEnabled(true);
  if (message.ok) {
    appProfileError.textContent = '';
    setAppProfileDirty(false);
  } else {
    refreshAppProfileButtonsUi();
    appProfileError.textContent = message.error || 'アプリプロファイルの更新に失敗しました。';
  }
}

// apps/<name>.json の外部編集(watcher onDidChange)。編集対象と同名 && 未編集のときのみ
// 再ロードして自動反映する(applyRunProfileFileChanged と同じ方針)。
export function applyAppProfileFileChanged(message) {
  if (message.name === selectedAppProfile && !appProfileEditing()) {
    vscode.postMessage({ type: 'appProfileLoad', profile: selectedAppProfile });
  }
}
