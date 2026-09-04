// モニターパネル「設定」タブ(#panel-settings)。main.js が applySettings を message
// ディスパッチャに組み込む。対向: src/monitorWebviewMessages.ts の setPollingMode/pollingMode・
// setLanguage/language メッセージ、処理は src/monitorPanel.ts。常駐プロセス一覧は processesTab.js を参照。
// リモート実行のホスト表と artifacts(results/ 回収モード)セレクタは remoteConfig/setRemoteConfig に相乗り。
//
// 更新セクション: checkUpdate/runUpdate を送り、updateStatus を受ける(実処理は
// src/monitorUpdateController.ts → Scripts/update-check.sh / update.sh)。
// **実行ログはここには出さない** — VSCode の OUTPUT(fleetest チャンネル)へ出す。

import { vscode } from './vscodeApi.js';
import { t } from '../i18n.js';
import { defaultMachineForHost } from '../../remoteRunArgs';
import { switchTab } from './tabs.js';

const pollingModeCheckbox = document.getElementById('settings-polling-mode');
const lptCheckbox = document.getElementById('settings-lpt');
const lptHistoryInput = document.getElementById('settings-lpt-history');
// 拡張から届く既定値(空欄・不正値のときに戻す値)。届くまでは null。
let lptHistoryDefault = null;
const languageSelect = document.getElementById('settings-language');
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

// LPT 投入順。拡張側が fleetest.lptScheduling 設定を更新し、次の run から効く
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

// 表示言語の変更。拡張側が fleetest.language 設定を更新し、完全反映には再読み込みが要る
// (案内は extension.ts が出す)。
languageSelect.addEventListener('change', () => {
  vscode.postMessage({ type: 'setLanguage', value: languageSelect.value });
});

// ---- リモート実行(CLI のホスト登録簿・config.ts。docs/remote-runner.md §12) --------
// ホスト一覧は行数が可変のため DOM を直接組み立てる。行の識別は name(変更され得る)ではなく
// 使い捨ての rowId で行う。
//
// 「追加」で足す行は confirmed:false(未確定)で始まる。未確定行は **host が埋まるまで**
// CLI へ送らない(host の無い登録は宛先を持たない)。埋まったら行内の「確定」ボタンで初めて
// 送る(既存タブの wvMonitor2.common.confirm と同じ語)。確定済み行は今まで通りフィールドの
// change で即同期する。
//
// **マシン名は任意**。空欄なら host のホスト部を名前にする(defaultMachineForHost。CLI 側も
// 同じ既定を持つが、拡張は差分計算(diffRemoteHosts)を machine で行うため、送る時点で
// 埋めておく)。入力欄には「これになる」名前をウォーターマークで出す。
const remoteHostsError = document.getElementById('settings-remote-hosts-error');
let hostRows = []; // { id, tr, machineInput, hostInput, dirInput, fmInput, confirmed, confirmButton }
let nextRowId = 0;
// 未設定時の FM 枠。**CLI が返す値をそのまま使う**(拡張は定数を持たない —— 二重管理にすると
// 片方だけ変わったときにウォーターマークが嘘になる)。未受信のうちは空欄のまま
let defaultFMConcurrency;
// この機械の固定行。**登録簿の行ではない**("local" は予約名)ので hostRows には入れず、
// 表の先頭に別途描く。編集できるのは FM 枠だけで、削除もできない
let localRow;

/** 固定行(この機械)を表の先頭に描く。host/machine は表示専用、FM 枠だけ編集できる。 */
function renderLocalRow(tbody, local) {
  const tr = document.createElement('tr');
  tr.className = 'settings-remote-hosts-row-local';
  // **読み取り専用の入力欄にする**(素のテキストにしない)。可変行のテキストは td の padding に
  // 加えて input 自身の padding と枠線のぶん内側から始まるので、同じ箱にしないと左端がずれる
  // —— 数値で合わせると input の padding を触ったときに黙ってずれる
  const fixedCell = (text, cellClass) => {
    const td = document.createElement('td');
    if (cellClass) {
      td.className = cellClass;   // 列の幅は CSS 側で決める(可変行と同じクラスを使う)
    }
    const input = document.createElement('input');
    input.type = 'text';
    input.className = 'settings-text settings-remote-hosts-input settings-remote-hosts-fixed';
    input.value = text;
    input.readOnly = true;
    input.tabIndex = -1;
    td.appendChild(input);
    tr.appendChild(td);
  };
  // **列の並びは可変行と揃える**(user@host → マシン → FM 並列枠 → 作業ベースディレクトリ)
  fixedCell(local.host, 'settings-remote-hosts-host');
  fixedCell(local.machine, 'settings-remote-hosts-machine');
  const fmTd = document.createElement('td');
  fmTd.className = 'settings-remote-hosts-fm';
  const input = makeFMConcurrencyInput(local.fmConcurrency);
  input.addEventListener('change', () => onHostsChanged());
  fmTd.appendChild(input);
  tr.appendChild(fmTd);
  fixedCell('', 'settings-remote-hosts-dir');   // 作業ベースディレクトリ(この機械では使わない)
  // 削除ボタンは置かない(固定行)。列数を揃えるため空のセルだけ足す
  tr.appendChild(document.createElement('td'));
  tbody.appendChild(tr);
  localRow = { tr, input, host: local.host };
}

/** FM 並列枠の入力欄。**「直近 N 件までの履歴を使用する」と同じ作り**(`type=number` +
 *  `.settings-number`)。**行の種類を問わずこの関数を通す** —— 固定行(この機械)と可変行で
 *  別々に組むと片方だけ制限や見た目が漏れる。
 *
 *  値は **1〜9 の1桁**に限る。範囲の根拠は docs/performance-tuning.md §3.5(実測でスループットは
 *  並列度5で飽和し、8 まで測っても伸びない)。0 と空欄はどちらも「未設定」= 既定へ倒す扱いなので
 *  0 は打てなくてよい。**`maxLength` は `type=number` では効かない**ので、桁の制限は
 *  input イベントの絞り込みだけが担っている(消すと2桁が入る)。 */
function makeFMConcurrencyInput(value) {
  const input = document.createElement('input');
  input.type = 'number';
  input.className = 'settings-number settings-remote-hosts-fm-input';
  input.min = '1';
  input.max = '9';
  input.step = '1';
  // **未設定(0)のときは既定値を実値として出す** —— 空欄だと「何枠で走るのか」が画面から
  // 読めない。空欄にすれば未設定へ戻せる(送るのは 0 で、CLI が既定へ倒し、次の描画で
  // またこの既定が入る)。既定が読めないときだけウォーターマークに落とす
  input.value = value > 0 ? String(value)
    : (defaultFMConcurrency === undefined ? '' : String(defaultFMConcurrency));
  input.placeholder = defaultFMConcurrency === undefined ? '' : String(defaultFMConcurrency);
  input.addEventListener('input', () => {
    const kept = input.value.replace(/[^1-9]/g, '').slice(0, 1);
    if (kept !== input.value) {
      input.value = kept;
    }
  });
  return input;
}

function currentHostsPayload() {
  // 固定行は登録簿ではなく LocalConfig へ入る(CLI 側が machine:"local" を見て振り分ける)
  const fixed = [];
  if (localRow) {
    const n = Number.parseInt(localRow.input.value.trim(), 10);
    fixed.push({ machine: 'local', host: localRow.host, dir: '',
                 fmConcurrency: Number.isFinite(n) && n > 0 ? n : 0 });
  }
  // 未確定行(confirmed:false)はホストが空のことがあるため、確定済み行だけを送る
  // (「確定」ボタン自体は host が埋まるまで押せないが、ここでも二重に落として安全側に倒す)。
  return fixed.concat(hostRows
    .filter((row) => row.confirmed)
    .map((row) => {
      const host = row.hostInput.value.trim();
      const machine = row.machineInput.value.trim();
      // 空欄・非数値・0 以下は 0 = 解除として送る(CLI 側が 0 を「未設定」に倒す)
      const fm = Number.parseInt(row.fmInput.value.trim(), 10);
      return {
        machine: machine || defaultMachineForHost(host), host, dir: row.dirInput.value.trim(),
        fmConcurrency: Number.isFinite(fm) && fm > 0 ? fm : 0,
      };
    }));
}

function sendRemoteConfig() {
  remoteHostsError.hidden = true;
  vscode.postMessage({
    type: 'setRemoteConfig',
    hosts: currentHostsPayload(),
    artifacts: remoteArtifactsSelect.value,
  });
}

function onHostsChanged() {
  sendRemoteConfig();
}

function removeHostRow(id) {
  const index = hostRows.findIndex((r) => r.id === id);
  if (index === -1) {
    return;
  }
  const [row] = hostRows.splice(index, 1);
  row.tr.remove();
  // 未確定行はまだ CLI へ送っていないので、消すだけで同期は要らない。
  if (row.confirmed) {
    onHostsChanged();
  }
}

// 送れる行か。**マシン名は任意**なので host だけを見る
function rowIsFillable(row) {
  return row.hostInput.value.trim() !== '';
}

// マシン名欄のウォーターマーク。host が入っていれば「省略したらこの名前になる」を出し、
// まだ空なら省略できること自体を出す
function updateMachinePlaceholder(row) {
  const derived = defaultMachineForHost(row.hostInput.value);
  row.machineInput.placeholder = derived || t('wvMonitor2.remote.machinePlaceholder');
}

function confirmHostRow(id) {
  const row = hostRows.find((r) => r.id === id);
  if (!row || row.confirmed || !rowIsFillable(row)) {
    return;
  }
  row.confirmed = true;
  row.confirmButton.remove();
  row.confirmButton = null;
  row.tr.classList.remove('settings-remote-hosts-row-pending');
  onHostsChanged();
}

// host(省略時は空行=追加ボタン用)から1行分の DOM を組み立てて末尾に追加する。
// confirmed=false の行は「確定」ボタンを押すまで CLI へ送らない(currentHostsPayload が除外する)。
function addHostRow(host, confirmed) {
  const id = nextRowId++;
  const tr = document.createElement('tr');
  const row = { id, tr, confirmed };

  const makeTextCell = (value, placeholder, cellClass) => {
    const td = document.createElement('td');
    if (cellClass) {
      td.className = cellClass;   // 列ごとの幅は CSS(.settings-remote-hosts-fm)で決める
    }
    const input = document.createElement('input');
    input.type = 'text';
    input.className = 'settings-text settings-remote-hosts-input';
    input.value = value;
    if (placeholder) {
      input.placeholder = placeholder;
    }
    input.addEventListener('change', () => {
      if (row.confirmed) {
        onHostsChanged();
      }
    });
    // 未確定行は入力のたびに「確定」ボタンの活性を更新する(host が埋まるまで押せない)。
    input.addEventListener('input', () => {
      if (!row.confirmed && row.confirmButton) {
        row.confirmButton.disabled = !rowIsFillable(row);
      }
    });
    td.appendChild(input);
    tr.appendChild(td);
    return input;
  };

  // **列の並び = makeTextCell を呼ぶ順**(td を順に append する)。ホスト → マシン → ディレクトリ。
  // 必須の host を先に置き、任意のマシン名をその右に置く(見出しは monitorHtml.ts と対)
  row.hostInput = makeTextCell(host ? host.host : '', 'user@host', 'settings-remote-hosts-host');
  row.machineInput = makeTextCell(host ? host.machine : '', '', 'settings-remote-hosts-machine');
  // FM 並列枠。**空欄 = 未設定**(ランナー側の既定に任せる)。0 を送ると CLI 側が解除として扱う。
  // 機械によっては FM を2並列以上で呼ぶと壊れるため機械ごとに絞れる(docs/remote-runner.md §19)
  const fmTd = document.createElement('td');
  fmTd.className = 'settings-remote-hosts-fm';
  row.fmInput = makeFMConcurrencyInput(host ? host.fmConcurrency : 0);
  row.fmInput.addEventListener('change', () => { if (row.confirmed) { onHostsChanged(); } });
  fmTd.appendChild(row.fmInput);
  tr.appendChild(fmTd);
  row.dirInput = makeTextCell(host ? host.dir : '', '~/fleetest-runner', 'settings-remote-hosts-dir');
  // ホストを打つたびにマシン名のウォーターマークを追従させる(何になるかを先に見せる)
  row.hostInput.addEventListener('input', () => updateMachinePlaceholder(row));
  updateMachinePlaceholder(row);

  const actionsTd = document.createElement('td');
  actionsTd.className = 'settings-remote-hosts-actions-cell';

  if (!confirmed) {
    tr.classList.add('settings-remote-hosts-row-pending');
    const confirmButton = document.createElement('button');
    confirmButton.type = 'button';
    confirmButton.className = 'secondary settings-remote-hosts-confirm';
    confirmButton.textContent = t('wvMonitor2.common.confirm');
    confirmButton.disabled = !rowIsFillable(row);
    confirmButton.addEventListener('click', () => confirmHostRow(id));
    actionsTd.appendChild(confirmButton);
    row.confirmButton = confirmButton;
  }

  const removeButton = document.createElement('button');
  removeButton.type = 'button';
  removeButton.className = 'secondary settings-remote-hosts-remove';
  removeButton.textContent = '−';
  removeButton.title = t('wvMonitor2.remote.removeTitle');
  // 削除は破壊的操作だが、ホスト登録は再入力が容易な小データなので modal 確認は不要
  // (プロファイル削除の modal 方式はここには適用しない)。
  removeButton.addEventListener('click', () => removeHostRow(id));
  actionsTd.appendChild(removeButton);
  tr.appendChild(actionsTd);

  remoteHostsBody.appendChild(tr);
  hostRows.push(row);
}

remoteHostsAddButton.addEventListener('click', () => {
  addHostRow(null, false);
});

remoteArtifactsSelect.addEventListener('change', () => {
  sendRemoteConfig();
});

// remoteConfig 受信(ready 直後 / setRemoteConfig の応答)で確定済み行を作り直す。
// 未確定行(「追加」を押してまだ確定していない入力中の行)は CLI へ一度も送っていないため
// message.hosts には含まれない。ここで作り直すと消えてしまうので、DOM ごと退避して後ろへ戻す。
function applyRemoteConfig(message) {
  if (typeof message.defaultFMConcurrency === 'number' && message.defaultFMConcurrency > 0) {
    defaultFMConcurrency = message.defaultFMConcurrency;
  }
  const pending = hostRows.filter((row) => !row.confirmed);
  for (const row of hostRows) {
    if (row.confirmed) {
      row.tr.remove();
    }
  }
  hostRows = [];
  if (localRow) {
    localRow.tr.remove();
    localRow = undefined;
  }
  const tbody = document.getElementById('settings-remote-hosts-body');
  if (message.local && typeof message.local.host === 'string') {
    renderLocalRow(tbody, message.local);
  }
  for (const host of Array.isArray(message.hosts) ? message.hosts : []) {
    addHostRow(host, true);
  }
  for (const row of pending) {
    remoteHostsBody.appendChild(row.tr);
    hostRows.push(row);
  }
  remoteArtifactsSelect.value = message.artifacts === 'on-demand' ? 'on-demand' : 'collect';
  if (typeof message.error === 'string' && message.error !== '') {
    remoteHostsError.textContent = t('wvMonitor2.remote.syncFailed', { reason: message.error });
    remoteHostsError.hidden = false;
  } else {
    remoteHostsError.hidden = true;
  }
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
