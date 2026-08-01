// モニターパネル「設定」タブ(#panel-settings)。main.js が applySettings を message
// ディスパッチャに組み込む。対向: src/monitorWebviewMessages.ts の setPollingMode/pollingMode・
// setLanguage/language メッセージ、処理は src/monitorPanel.ts。常駐プロセス一覧は processesTab.js を参照。
// リモート実行の artifacts(results/ 回収モード)セレクタは remoteConfig/setRemoteConfig に相乗り。
//
// 更新セクション: checkUpdate/runUpdate を送り、updateStatus を受ける(実処理は
// src/monitorUpdateController.ts → Scripts/update-check.sh / update.sh)。
// **実行ログはここには出さない** — VSCode の OUTPUT(ftester チャンネル)へ出す。

import { vscode } from './vscodeApi.js';
import { t } from '../i18n.js';
import { switchTab } from './tabs.js';

const pollingModeCheckbox = document.getElementById('settings-polling-mode');
const lptCheckbox = document.getElementById('settings-lpt');
const lptHistoryInput = document.getElementById('settings-lpt-history');
// 拡張から届く既定値(空欄・不正値のときに戻す値)。届くまでは null。
let lptHistoryDefault = null;
const languageSelect = document.getElementById('settings-language');
const remoteTargetSelect = document.getElementById('settings-remote-target');
const remoteArtifactsSelect = document.getElementById('settings-remote-artifacts');
const remoteHostsBody = document.getElementById('settings-remote-hosts-body');
const remoteHostsAddButton = document.getElementById('settings-remote-hosts-add');
const updateStatus = document.getElementById('settings-update-status');
const updateSpinner = document.getElementById('settings-update-spinner');
const updateCheckButton = document.getElementById('settings-update-check');
// 「更新する」は設定タブの中ではなく**タブバー(設定タブの右隣)**にある(どのタブを見ていても目に入る)。
// 更新があるときだけ表示する — 押せない状態のボタンを常時見せても情報にならないため。
const updateRunButton = document.getElementById('tabbar-update');

pollingModeCheckbox.addEventListener('change', () => {
  vscode.postMessage({ type: 'setPollingMode', value: pollingModeCheckbox.checked });
});

// LPT 投入順。拡張側が ftester.lptScheduling 設定を更新し、次の run から効く
// (実行中の run の順序は変わらない)。
lptCheckbox.addEventListener('change', () => {
  vscode.postMessage({ type: 'setLptScheduling', value: lptCheckbox.checked });
});

// 実績走査の run 数。**入力欄には常に実際に使う件数を入れる**(既定でも空欄にしない)。
// 空欄や不正値のときは null を送って拡張側の設定を消し、UI にも既定値を入れ直す。
lptHistoryInput.addEventListener('change', () => {
  const raw = lptHistoryInput.value.trim();
  // parseInt は "2.5" を 2 に切り詰めて黙って別の値にしてしまうので Number() で厳密に見る
  const parsed = Number(raw);
  const valid = raw !== '' && Number.isInteger(parsed) && parsed >= 1;
  if (!valid) {
    // 空欄のままにせず既定値を入れ直す(UI 上は常に実際に使う件数が見えている状態にする)
    lptHistoryInput.value = lptHistoryDefault === null ? '' : String(lptHistoryDefault);
  }
  vscode.postMessage({ type: 'setLptHistoryRuns', value: valid ? parsed : null });
});

// 表示言語の変更。拡張側が ftester.language 設定を更新し、完全反映には再読み込みが要る
// (案内は extension.ts が出す)。
languageSelect.addEventListener('change', () => {
  vscode.postMessage({ type: 'setLanguage', value: languageSelect.value });
});

// ---- リモート実行(ftester.remote.hosts/target・config.ts。docs/remote-runner.md §12) --------
// ホスト一覧は行数が可変のため DOM を直接組み立てる。行の識別は name(変更され得る)ではなく
// 使い捨ての rowId で行う — さもないと「選択中ホストの name を編集する」操作で選択が迷子になる
// (target セレクタの value は rowId、実際に送る target 文字列はそのIDの行の現在の name)。
let hostRows = []; // { id, nameInput, hostInput, dirInput, tr }
let nextRowId = 0;
// 選択中ターゲットの rowId。null = ローカル実行。
let selectedTargetRowId = null;

function currentHostsPayload() {
  return hostRows.map((row) => ({
    name: row.nameInput.value.trim(),
    host: row.hostInput.value.trim(),
    dir: row.dirInput.value.trim(),
  }));
}

function currentTargetPayload() {
  if (selectedTargetRowId === null) {
    return '';
  }
  const row = hostRows.find((r) => r.id === selectedTargetRowId);
  return row ? row.nameInput.value.trim() : '';
}

function sendRemoteConfig() {
  vscode.postMessage({
    type: 'setRemoteConfig',
    hosts: currentHostsPayload(),
    target: currentTargetPayload(),
    artifacts: remoteArtifactsSelect.value,
  });
}

// 実行先セレクタの選択肢を現在の行の name で作り直す(rowId を value にすることで name 変更中も
// 選択を見失わない)。selectedTargetRowId が指す行が無くなっていれば local へ落とす。
function rebuildTargetOptions() {
  if (selectedTargetRowId !== null && !hostRows.some((r) => r.id === selectedTargetRowId)) {
    selectedTargetRowId = null;
  }
  remoteTargetSelect.textContent = '';
  const localOption = document.createElement('option');
  localOption.value = '';
  localOption.textContent = t('wvMonitor2.remote.localOption');
  remoteTargetSelect.appendChild(localOption);
  for (const row of hostRows) {
    const option = document.createElement('option');
    option.value = String(row.id);
    option.textContent = row.nameInput.value.trim() || t('wvMonitor2.remote.unnamed');
    remoteTargetSelect.appendChild(option);
  }
  remoteTargetSelect.value = selectedTargetRowId === null ? '' : String(selectedTargetRowId);
}

function onHostsChanged() {
  rebuildTargetOptions();
  sendRemoteConfig();
}

function removeHostRow(id) {
  const index = hostRows.findIndex((r) => r.id === id);
  if (index === -1) {
    return;
  }
  hostRows[index].tr.remove();
  hostRows.splice(index, 1);
  onHostsChanged();
}

// host(省略時は空行=追加ボタン用)から1行分の DOM を組み立てて末尾に追加する。
function addHostRow(host) {
  const id = nextRowId++;
  const tr = document.createElement('tr');

  const makeTextCell = (value, placeholder) => {
    const td = document.createElement('td');
    const input = document.createElement('input');
    input.type = 'text';
    input.className = 'settings-text settings-remote-hosts-input';
    input.value = value;
    if (placeholder) {
      input.placeholder = placeholder;
    }
    input.addEventListener('change', onHostsChanged);
    td.appendChild(input);
    tr.appendChild(td);
    return input;
  };

  const nameInput = makeTextCell(host ? host.name : '');
  const hostInput = makeTextCell(host ? host.host : '', 'user@host');
  const dirInput = makeTextCell(host ? host.dir : '', '~/ftester-runner');

  const removeButton = document.createElement('button');
  removeButton.type = 'button';
  removeButton.className = 'secondary settings-remote-hosts-remove';
  removeButton.textContent = '−';
  removeButton.title = t('wvMonitor2.remote.removeTitle');
  // 削除は破壊的操作だが、ホスト登録は再入力が容易な小データなので modal 確認は不要
  // (プロファイル削除の modal 方式はここには適用しない)。
  removeButton.addEventListener('click', () => removeHostRow(id));
  const removeTd = document.createElement('td');
  removeTd.appendChild(removeButton);
  tr.appendChild(removeTd);

  remoteHostsBody.appendChild(tr);
  hostRows.push({ id, tr, nameInput, hostInput, dirInput });
}

remoteHostsAddButton.addEventListener('click', () => {
  addHostRow(null);
  onHostsChanged();
});

remoteTargetSelect.addEventListener('change', () => {
  selectedTargetRowId = remoteTargetSelect.value === '' ? null : Number(remoteTargetSelect.value);
  sendRemoteConfig();
});

remoteArtifactsSelect.addEventListener('change', () => {
  sendRemoteConfig();
});

// remoteConfig 受信(ready 直後・削除で target の指す先が消えたときの拡張側補正)で全行を作り直す。
function applyRemoteConfig(message) {
  remoteHostsBody.textContent = '';
  hostRows = [];
  for (const host of Array.isArray(message.hosts) ? message.hosts : []) {
    addHostRow(host);
  }
  const matched = hostRows.find((row) => row.nameInput.value.trim() === message.target);
  selectedTargetRowId = matched ? matched.id : null;
  rebuildTargetOptions();
  remoteArtifactsSelect.value = message.artifacts === 'on-demand' ? 'on-demand' : 'collect';
}

updateCheckButton.addEventListener('click', () => {
  vscode.postMessage({ type: 'checkUpdate' });
});

// 確認ダイアログは**ホスト側**(monitorUpdateController.ts の showWarningMessage modal)。
// webview では window.confirm/alert が効かない(VSCode の制約。他タブの削除確認も同じ方式)。
updateRunButton.addEventListener('click', () => {
  // 進行は OUTPUT パネル(ホスト側が前面に出す)と、この状態行のスピナーで見せる。
  // どのタブから押しても状態が見えるよう設定タブへ移動する。
  switchTab('settings');
  vscode.postMessage({ type: 'runUpdate' });
});

// 実行中はラベルを差し替えるので、初期ラベル(拡張側 t() で描画済み)を控えておく。
const updateRunLabel = updateRunButton.textContent;

function shortSha(value) {
  return typeof value === 'string' ? value.slice(0, 8) : '';
}

function applyUpdateStatus(message) {
  const running = message.state === 'running';
  // 実行中は確認を止める(更新の最中に判定を走らせない)。
  updateCheckButton.disabled = running || message.state === 'checking';
  // 「更新する」は**更新があるときだけ**出す。実行中は押せない状態で残す(消すと進行が分からない)。
  updateRunButton.style.display = message.state === 'update-available' || running ? 'block' : 'none';
  updateRunButton.disabled = running;
  updateRunButton.classList.toggle('busy', running);
  updateRunButton.textContent = running ? t('wvMonitor2.update.runningButton') : updateRunLabel;
  // 待たされる2状態(確認中・更新中)だけスピナーを回す。
  updateSpinner.style.display = running || message.state === 'checking' ? 'block' : 'none';
  updateStatus.classList.remove('available', 'attention');

  switch (message.state) {
    case 'checking':
      updateStatus.textContent = t('wvMonitor2.update.checking');
      break;
    case 'running':
      updateStatus.textContent = t('wvMonitor2.update.running');
      break;
    case 'up-to-date':
      updateStatus.textContent = t('wvMonitor2.update.upToDate', { local: shortSha(message.localHead) });
      break;
    case 'update-available':
      updateStatus.textContent = t('wvMonitor2.update.available', {
        local: shortSha(message.localHead),
        remote: shortSha(message.remoteHead),
      });
      updateStatus.classList.add('available');
      break;
    case 'pinned':
      updateStatus.textContent = t('wvMonitor2.update.pinned', { reason: message.reason || '' });
      updateStatus.classList.add('attention');
      break;
    case 'unavailable':
      updateStatus.textContent = t('wvMonitor2.update.unavailable');
      updateStatus.classList.add('attention');
      break;
    default:
      updateStatus.textContent = t('wvMonitor2.update.unknown', { reason: message.reason || '' });
      updateStatus.classList.add('attention');
  }
}

export function applySettings(message) {
  if (message.type === 'pollingMode') {
    pollingModeCheckbox.checked = !!message.value;
  } else if (message.type === 'lptScheduling') {
    lptCheckbox.checked = !!message.value;
  } else if (message.type === 'lptHistoryRuns') {
    // 実際に使う件数を常に値として入れる(既定でも空欄にしない)。placeholder は
    // 入力を消した一瞬に既定値が見えるようにするための保険。
    lptHistoryDefault = message.default;
    lptHistoryInput.placeholder = String(message.default);
    lptHistoryInput.value = String(message.value);
  } else if (message.type === 'language') {
    languageSelect.value = message.value;
  } else if (message.type === 'remoteConfig') {
    applyRemoteConfig(message);
  } else if (message.type === 'updateStatus') {
    applyUpdateStatus(message);
  }
}
