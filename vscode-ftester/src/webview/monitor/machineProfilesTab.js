// machineProfilesTab.js
// 「プロファイル」タブの「マシンプロファイル」節(machines/*.json の一覧・選択・
// デバイス一覧・右ペインの編集フォーム・デバイス行の右クリックメニュー[除去])を担う。
// これらは相互に選択状態・DOM を参照し合うため一体のモジュールにまとめている。
// machineProfiles・selectedMachine・selectedDeviceNames 等は再代入される状態のため、
// 書き込み箇所をすべてこのモジュールに置く。runProfilesTab.js・modals.js からは
// machineProfiles/findMachine/selectedMachine を読み取り専用で参照する。

import { vscode } from './vscodeApi.js';
import { clampMenuPosition } from './deviceTiles.js';

// ---- プロファイルタブ: マシンプロファイル ---------------------------------------
// machines/*.json の内容(machineProfileInfo)を一覧表示し、「+新規作成」/「+既存から選択」
// からそれぞれのデバイス追加モーダルを開く。ホストとの往復が要るのは
// deviceCatalogRequest/createDevice/installedDevicesRequest/machineDevicesSync/
// machineDeviceRemove のみで、マシン選択(select の change)自体は受信済みデータの
// 再描画だけで完結する。

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
const editorOs = document.getElementById('editor-os');
const editorUdid = document.getElementById('editor-udid');
const editorPort = document.getElementById('editor-port');
const editorAvd = document.getElementById('editor-avd');
const editorError = document.getElementById('editor-error');
const editorConfirm = document.getElementById('editor-confirm');
const editorCancel = document.getElementById('editor-cancel');
const machineDeviceMenu = document.getElementById('machine-device-menu');
const machineDeviceMenuItemBtn = document.getElementById('machine-device-menu-item');

// 直近受信の machines 配列(machineProfileInfo)。空なら「マシンプロファイルなし」。
export let machineProfiles = [];
let machineProfileHasError = false;
// 現在選択中とみなすマシン名(select の値。machines が0件なら null)。
export let selectedMachine = null;
// 選択中デバイス名の集合(複数選択に対応するため Set)。通常クリックは「その1台だけを
// 選択」(既にその1台だけの選択状態なら解除)、Shift+クリックはアンカー
// (deviceSelectionAnchor)からの範囲選択、Cmd/Ctrl+クリックは個別の追加/除外トグル
// (Finder/VSCode のリストと同じ標準セマンティクス)。マシン切替・一覧再描画で一覧から
// 消えた名前は Set から取り除く(validateSelectedDeviceName)。右ペインの編集フォームは
// ちょうど1台(size===1)のときだけ表示する。
let selectedDeviceNames = new Set();
// 範囲選択(Shift+クリック)の起点=直近に通常/Cmd(Ctrl)クリックした行の名前。Shift+クリック
// 自体ではアンカーを動かさない(連続 Shift+クリックで同じ起点から範囲を伸縮できる)。
// 一覧から消えたら validateSelectedDeviceName で null に戻す。
let deviceSelectionAnchor = null;
// macOS 判定(行の contextmenu リスナーで Ctrl+クリックを選択トグルへ振り分けるのに使う。
// 下の toggleDeviceRowSelection まわりのコメント参照)。
const isMacPlatform = /^Mac/.test(navigator.platform || '');
// 直近描画したデバイス行の DOM 要素(name -> row)。トグル選択・右クリックメニューの
// 対象存在チェックで、一覧全体を再描画せずに済ませるために使う。
let deviceRowElements = new Map();
// 右クリックメニュー(#machine-device-menu)を開いている対象(未オープンなら null)。
// { machine, name } の形(deviceOpMenuEntry がタイル entry を保持するのと対応)。
let machineDeviceMenuEntry = null;
// 右ペインの編集フォームの対象({ machine, platform, originalName }。未選択なら null)。
let editorTarget = null;
// フォームを最後に作り直した(＝選択・machineProfileInfo再プリフィル)時点の6フィールド値。
// dirty 判定(現在値との比較)・machineProfileInfo 再受信時の再プリフィル可否判定に使う。
let editorOriginalValues = null;
// いずれかのフィールドが元の値(editorOriginalValues)から変わっているか。
let editorDirty = false;
// machineDeviceUpdate の応答待ち中か(二重送信防止・machineProfileInfo 再受信時の
// 再プリフィル抑止に使う)。
let editorSubmitting = false;

export function findMachine(name) {
  return machineProfiles.find((m) => m.name === name);
}

// (デバイス一覧と右ペインの間にスプリッターは無い。一覧幅は .machine-device-list の
// width: max-content で内容に自動フィットする。)

// selectedDeviceNames のうち、現在の selectedMachine の一覧に存在しない名前を取り除く
// (要件: マシン切替・一覧更新で選択中デバイスが消えた場合)。存在するものは維持する
// (machineProfileInfo 再受信後も選択を名前で照合して引き継ぐ)。
function validateSelectedDeviceName() {
  const machine = findMachine(selectedMachine);
  const names = new Set(machine ? machine.devices.map((d) => d.name) : []);
  for (const name of selectedDeviceNames) {
    if (!names.has(name)) {
      selectedDeviceNames.delete(name);
    }
  }
  // 範囲選択(Shift+クリック)の起点も同様に照合し、一覧から消えていたら捨てる
  // (アンカー不在時の Shift+クリックは通常クリック扱いになる)。
  if (deviceSelectionAnchor !== null && !names.has(deviceSelectionAnchor)) {
    deviceSelectionAnchor = null;
  }
}

// machineProfileInfo 受信のたびに selectedMachine を検証し、無効なら current→先頭の順で
// フォールバックする(要件: 選択中マシンが一覧から消えた場合の復帰先)。
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
  // 「+新規作成」「+既存から選択」は同一条件で有効/無効を切り替える。
  btnDeviceAddExisting.disabled = machineProfileHasError || machineProfiles.length === 0;
  // [+] はプロジェクトさえ解決できれば追加先があるので machines 件数は問わない。
  // [−]/[✏] は対象(selectedMachine)が要るので、machines が0件のときも無効化する。
  btnMachineAdd.disabled = machineProfileHasError;
  btnMachineCopy.disabled = machineProfileHasError || machineProfiles.length === 0;
  btnMachineRemove.disabled = machineProfileHasError || machineProfiles.length === 0;
  btnMachineRename.disabled = machineProfileHasError || machineProfiles.length === 0;
}

// 追加/名前変更の直後にホストから届く、選択を新プロファイルへ移す通知。直前の
// machineProfileInfo とは順序が前後しない(postMessage は順序保証)ため、単純に上書きでよい。
// エラー時(machineProfileHasError)にホストがこのメッセージを送ってくることは無い前提だが、
// 念のため無視するガードを入れる。
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
    machineNameStatic.textContent = '(マシンプロファイルなし)';
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

// 行クリックの選択(Finder/VSCode のリストと同じ標準セマンティクス)。判定順は
// shiftKey → metaKey/ctrlKey → 通常(Shift+Cmd 同時は Shift 扱い)。
// - Shift+クリック: 表示順(deviceRowElements の挿入順=renderMachineProfileBody の描画順)で
//   アンカー〜クリック行の間(両端含む)を選択に「置き換える」。アンカーは動かさない
//   (連続 Shift+クリックで同じ起点から範囲を伸縮できる)。アンカーが無効(null/一覧に不在)
//   なら通常クリックと同じ扱いにフォールバックする。
// - Cmd(metaKey)/Ctrl(ctrlKey)+クリック: クリック行を個別に追加/除外するトグル。
//   クリック行をアンカーに設定する。
// - 通常クリック: その1台だけを選択(既存の選択を置き換える)+クリック行をアンカーに設定。
//   既に「その1台だけが選択」状態なら解除する(解除時はアンカーも null)。
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
    empty.textContent = 'デバイスがありません。上のボタンから追加できます。';
    machineDeviceList.appendChild(empty);
  } else {
    for (const device of devices) {
      const row = document.createElement('div');
      row.className = 'machine-device-row';
      const name = document.createElement('span');
      // タイル/レーンのデバイス名ピルと同じ配色クラスを再利用する(tile-name-ios/-android)。
      name.className = 'tile-name tile-name-' + device.platform;
      name.textContent = device.name;
      const detail = document.createElement('div');
      detail.className = 'machine-device-detail';
      detail.textContent = device.detail;
      row.append(name, detail);
      row.addEventListener('click', (event) => toggleDeviceRowSelection(device.name, event));
      row.addEventListener('contextmenu', (event) => {
        event.preventDefault();
        event.stopPropagation();
        // macOS では Ctrl+クリックが OS レベルで右クリック扱いになり click イベントは発生せず
        // contextmenu として届くため、ここで選択トグルへ振り分ける(Cmd と同様に Ctrl でも
        // 追加選択できるようにするため)。contextmenu イベントにも shiftKey/ctrlKey/metaKey は
        // 載っているので event をそのまま渡せば既存の判定(Shift優先→Ctrl/Cmdで個別トグル)が
        // そのまま効く。mac では物理右クリック+Ctrl 押下も選択トグルになるが、メニューは素の
        // 右クリックで開けるため許容している。
        // Windows/Linux の Ctrl+クリックは通常の click イベントで既に対応済みなので、
        // この振り分けは mac のみ。
        if (isMacPlatform && event.ctrlKey) {
          toggleDeviceRowSelection(device.name, event);
          return;
        }
        // クリックした行が現在の複数選択(2台以上)に含まれる場合は選択中全台を対象にする。
        // それ以外はクリックした行単体を対象にする。選択状態自体は
        // 右クリックでは変更しない。
        const names =
          selectedDeviceNames.size >= 2 && selectedDeviceNames.has(device.name)
            ? [...selectedDeviceNames]
            : [device.name];
        openMachineDeviceMenu({ machine: selectedMachine, names }, event.clientX, event.clientY);
      });
      deviceRowElements.set(device.name, row);
      machineDeviceList.appendChild(row);
    }
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

// 選択中マシンの全デバイス名(ios/android 横断。デバイス追加モーダルの重複検証に使う)。
export function allDeviceNamesForSelectedMachine() {
  const machine = findMachine(selectedMachine);
  return machine ? machine.devices.map((d) => d.name) : [];
}

// ---- 右ペインの編集フォーム ---------------------------------------------
// 行選択中は #machine-device-editor を表示し、machineDeviceUpdate で machines/*.json を
// 更新する。dirty(未確定の編集があるか)は6フィールドの現在値と、フォームを最後に作り直した
// 時点の値(editorOriginalValues)を素の文字列比較するだけで判定する(trim はしない。
// 「元の値から変わったか」という見た目上の判定であり、送信直前の検証・整形とは別の関心事)。

const EDITOR_PLATFORM_LABEL = { ios: 'iOS', android: 'Android' };
// input イベントを購読するのは編集可のフィールドだけ(機種/OS/UDID/AVD は選択・コピー可能な
// ラベル表示(span)であり、値が変わることはない)。
const editorFieldInputs = [editorName, editorPort];

// machines/*.json のデバイス1件(machineProfileInfo の生フィールド付き)から、フォームの
// 6フィールド分の文字列を組み立てる(undefined は空文字扱い。port は文字列化する)。
function deviceFieldValues(device) {
  return {
    name: device.name,
    simulator: device.simulator || '',
    os: device.os || '',
    udid: device.udid || '',
    port: device.port === undefined || device.port === null ? '' : String(device.port),
    avd: device.avd || '',
  };
}

function currentEditorValues() {
  // 機種/OS/UDID/AVD はラベル表示(span)なので textContent から読む(変わることはないが、
  // dirty 判定の比較対象として editorOriginalValues と同じ6フィールドの形を保つ)。
  return {
    name: editorName.value,
    simulator: editorSimulator.textContent,
    os: editorOs.textContent,
    udid: editorUdid.textContent,
    port: editorPort.value,
    avd: editorAvd.textContent,
  };
}

function valuesEqual(a, b) {
  return (
    a.name === b.name &&
    a.simulator === b.simulator &&
    a.os === b.os &&
    a.udid === b.udid &&
    a.port === b.port &&
    a.avd === b.avd
  );
}

// dirty(=確定ボタン有効)と、それに連動する確定/キャンセルボタンの見た目をまとめて更新する。
// キャンセルは dirty の間だけ表示し、送信中(editorSubmitting)は確定・キャンセルとも
// 無効化する(確定は「確定中...」表示、キャンセルは表示は保ったまま押せなくする)。
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
  editorTarget = { machine: machine, platform: device.platform, originalName: device.name };
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
  editorIosFields.style.display = device.platform === 'ios' ? '' : 'none';
  editorAndroidFields.style.display = device.platform === 'android' ? '' : 'none';
  editorConfirm.textContent = '確定';
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

// 右ペインの編集フォームは「ちょうど1台選択」のときだけ表示する。0台は既定の
// プレースホルダー、2台以上は「<N>台選択中(右クリックで一括除去できます)」を表示する。
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

// 選択変更・マシン切替(明示操作)用: ちょうど1台選択中ならその値でフォームを作り直し、
// それ以外(0台/2台以上)はプレースホルダーに戻す。編集途中の値は常に破棄する。
function rebuildEditorForSelection() {
  if (selectedDeviceNames.size >= 2) {
    clearDeviceEditor(selectedDeviceNames.size + '台選択中(右クリックで一括除去できます)');
    return;
  }
  const device = singleSelectedDevice();
  if (device) {
    renderDeviceEditor(selectedMachine, device);
  } else {
    clearDeviceEditor();
  }
}

// machineProfileInfo 再受信用: 選択中デバイスが消えていれば選択解除、存在してかつ未編集
// (dirty でない・送信中でない)なら新データで再プリフィルする。編集中(dirty)なら入力値を
// 保持する(watcher 経由の再送で入力が消えるのを防ぐ)。
function refreshEditorAfterProfileInfo() {
  if (machineProfileHasError) {
    clearDeviceEditor();
    return;
  }
  if (selectedDeviceNames.size >= 2) {
    clearDeviceEditor(selectedDeviceNames.size + '台選択中(右クリックで一括除去できます)');
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
  // 入力を変えたら前回のエラー表示は古くなるので消す(次の「確定」クリックで再検証される)。
  editorError.textContent = '';
}
for (const input of editorFieldInputs) {
  input.addEventListener('input', onEditorFieldInput);
}

// キャンセル: 編集を破棄して選択中デバイスの最新値でフォームを作り直す。machineProfiles は
// 常に最新(watcher経由で追従)なので、rebuildEditorForSelection がそのまま
// 「現在のファイル状態に戻す」動作になる(エラー表示のクリアも rebuildEditorForSelection
// →renderDeviceEditor/clearDeviceEditor 内で行われる)。
editorCancel.addEventListener('click', () => {
  if (editorCancel.disabled) {
    return;
  }
  rebuildEditorForSelection();
});

// 複製元: src/monitorModel.ts の updateDeviceInMachineProfile の検証部分。webview は CSP により
// import 不可のため複製する(validateNewDeviceName の複製と同じ方針。ロジックを変更したら
// 両方に反映すること)。
function validateDeviceEditorFields(name) {
  if (name.length === 0) {
    return 'デバイス名を入力してください。';
  }
  const others = allDeviceNamesForSelectedMachine().filter((n) => n !== editorTarget.originalName);
  if (others.includes(name)) {
    return '「' + name + '」は既に存在します。';
  }
  if (editorTarget.platform === 'ios') {
    const portValue = editorPort.value.trim();
    if (portValue.length > 0 && (!/^\d+$/.test(portValue) || Number(portValue) > 65535)) {
      return 'port は 0〜65535 の整数で入力してください。';
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
  editorConfirm.textContent = '確定中...';
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
    },
  });
});

// machineDeviceUpdate の結果(ok:true ならリネーム追従+一覧/フォームは直後の
// machineProfileInfo 再送(refreshEditorAfterProfileInfo)で最新化される。ok:false なら
// エラー表示のみで、入力値はそのまま残す=再操作可能)。
export function applyMachineDeviceUpdateResult(message) {
  editorSubmitting = false;
  editorConfirm.textContent = '確定';
  if (message.ok) {
    selectedDeviceNames = new Set([message.name]);
    editorError.textContent = '';
    setEditorDirty(false);
  } else {
    refreshEditorButtonsUi();
    editorError.textContent = message.error || 'デバイスの更新に失敗しました。';
  }
}

// ---- デバイス行の右クリックメニュー(除去) -------------------------------------
// 見た目・挙動はタイルの #device-op-menu(openDeviceOpMenu/closeDeviceOpMenu)を踏襲するが、
// 状態(machineDeviceMenuEntry)・DOM要素は独立させる(タイルメニューの挙動に影響しないため)。

export function closeMachineDeviceMenu() {
  if (!machineDeviceMenuEntry) {
    return;
  }
  machineDeviceMenuEntry = null;
  machineDeviceMenu.classList.remove('visible');
}

// entry は { machine, names }(names は1件以上)。複数選択(2台以上)を対象にする場合は
// メニュー項目のラベルを「選択した<N>台を除去」に変える。
function openMachineDeviceMenu(entry, clientX, clientY) {
  machineDeviceMenuEntry = entry;
  machineDeviceMenuItemBtn.textContent =
    entry.names.length >= 2 ? '選択した' + entry.names.length + '台を除去' : '除去';
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

// 外クリック・Esc・スクロール・リサイズで閉じる(#device-op-menu と同じ方針だが、
// 独立したリスナーとして登録する)。
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
// 行上の contextmenu は stopPropagation 済みなのでここには来ない(行外で右クリックした
// 場合に残さないためのガード。#device-op-menu の同種ハンドラと同じ理由)。
document.addEventListener('contextmenu', () => closeMachineDeviceMenu());
