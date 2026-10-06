// run ボード(フリート横断の実行状況。docs/design.md §18)。ツールバー直下・ラインビューの上に
// 常設(main.js の 'monitorRuns'/'runBoardReset'/'runBoardCollapsed'/'hostMetricsMachines' ケースが
// このモジュールへ渡す。契約: monitorWebviewMessages.ts の同名メッセージ)。
//
// 状態の畳み込みは runBoardModel.ts(vscode 非依存・machineLockModel.ts と同じ立場)に委ね、
// ここは DOM の生成・更新と文言(t())だけを持つ。**経過秒の秒読みは自分の時計で1秒ごとに
// 数字だけ書き換える**(DOM は作り直さない。CLAUDE.md の規律)。

import { t } from '../i18n.js';
import {
  runBoard, runBoardHeader, runBoardToggle, runBoardTitle, runBoardExpandAll, runBoardRows, runBoardSplit,
} from './domRefs.js';
import { vscode, persistedState } from './vscodeApi.js';
import {
  paintMachineBadge, isMachineDisabled, onMachineEnablementChanged, LOCAL_MACHINE_LABEL,
} from './machineColors.js';
import { setHoverTip } from './hoverTip.js';
import {
  deviceIdForLane, selectOnlyDevices, devicesOnMachine,
  isPlatformVisible, onPlatformFilterChanged,
} from './deviceTiles.js';
import { reapplyPaneHeights } from './splitter.js';
import {
  LOCAL_MACHINE_KEY,
  applyMonitorRunsEvent,
  buildRunGroups,
  machinesWithoutRuns,
  liveElapsedSeconds,
  liveRemaining,
} from '../../runBoardModel';

let runsByMachine = new Map();
// ヘッダの機械要約に出すリモート機の一覧(手元は含まない)。'hostMetricsMachines' に相乗りする
// (専用のホスト配線を増やさない —— 対象は「直近の monitorDevices に居る機械」で run ボードが
// 知りたい「フリートに居る機械」と同じ集合)。
let remoteMachines = [];

// ボード全体の開閉。host 復元前の既定は展開(webview 側 splitter.js の isFleetVisible と同じ規律)。
let collapsed = false;
// 「全て展開」トグル。**モードであって一度きりの操作ではない** —— ON の間は、あとから現れた
// run も展開された状態で出る(ユーザー決定)。host が workspaceState に持つ。
let expandAll = false;
// 機械の行の開閉を利用者が変えたもの(**機械の鍵** → 開いているか)。**既定はどの行も閉じ**
// (ユーザー決定)—— expandAll が OFF の間、行は利用者が開かない限り開かない。
// **行の鍵(rowKey)で引かない** —— 行の鍵は run の pid と「run の有無」を含むので、次の run・
// 空き⇔実行中 の切り替わりで変わり、記録を失った行が勝手に開閉する。
// host 側には永続化しない(webview の getState だけ = パネルの寿命)。
const machineExpansion = new Map(
  persistedState.runBoardMachineExpansion && typeof persistedState.runBoardMachineExpansion === 'object'
    ? Object.entries(persistedState.runBoardMachineExpansion).filter(([, v]) => typeof v === 'boolean')
    : [],
);

// 行の鍵。**1行 = 1機械**(ユーザー決定)—— run のある機械は run ごとに1行
// (機械分担の run は機械の数だけ行になる)、run の無い機械は1行。
// **run の行は機械 + pid で引く(groupKey を使わない)** —— 準備中・ビルド中の控えは runID/runGroup が
// nil で、走り出すと同じ pid の控えが runID 入りに上書きされる。groupKey で引くと走り出した瞬間に
// 行の DOM が作り直される。**開閉の記録はこの鍵では引かない**(machineExpansion)
function runRowKey(run) {
  return 'run\u0000' + (run.machine ?? '') + '\u0000' + run.pid;
}
function idleRowKey(machine) {
  return 'idle\u0000' + machine;
}

// 行の DOM とブックキーピング。render() が行の集合に合わせて足し引きする。
const rows = new Map();

/** 開閉の記録の鍵(machineList() の綴り = '' が手元)。同じ機械の run の行と空きの行が共有する。 */
function expansionKey(row) {
  return row.run ? (row.run.machine ?? LOCAL_MACHINE_KEY) : row.idle.machine;
}

/** その行を開くか。**expandAll が ON なら個別の記録によらず開く**(新しい行も含む)。 */
function isRowExpanded(row) {
  return expandAll || machineExpansion.get(expansionKey(row)) === true;
}

function persistMachineExpansion() {
  vscode.setState(Object.assign({}, vscode.getState(), {
    runBoardMachineExpansion: Object.fromEntries(machineExpansion),
  }));
}

function formatMinSec(seconds) {
  const safe = Number.isFinite(seconds) && seconds > 0 ? seconds : 0;
  const m = Math.floor(safe / 60);
  const s = Math.floor(safe % 60);
  return `${m}:${String(s).padStart(2, '0')}`;
}

function machineLabel(machine) {
  return machine === LOCAL_MACHINE_KEY || machine === undefined ? LOCAL_MACHINE_LABEL : machine;
}

// machineList() の鍵('' = 手元)を MonitorDevice / monitorRuns の規約(undefined = 手元)へ。
function machineKey(machine) {
  return machine === LOCAL_MACHINE_KEY ? undefined : machine;
}

function machineList() {
  // **「マシン有効」が off の機械は出さない**(ユーザー決定)—— ディスパッチの対象外
  // なので、「空き」と並べると使える機械に見える。isMachineDisabled は '' を手元として読む
  // (LOCAL_MACHINE_KEY と同じ綴り)。**run はこれで消えない** —— 一覧に無い機械の run は
  // render の最後の loop が拾う(走っている事実は隠さない)
  return [LOCAL_MACHINE_KEY, ...remoteMachines].filter((machine) => !isMachineDisabled(machine));
}

// 「マシン有効」の切り替えは remoteConfig で届く(machineColors.js)。届いた時点で並べ直す
onMachineEnablementChanged(() => render());

function applyCollapsedUi() {
  runBoard.dataset.collapsed = collapsed ? 'true' : 'false';
  // 行の chevron と同じ規律 —— 文字は常に ▶ で、向きは CSS の回転で表す
  runBoardToggle.textContent = '▶';
  runBoardToggle.dataset.expanded = collapsed ? 'false' : 'true';
  runBoardToggle.setAttribute('aria-expanded', collapsed ? 'false' : 'true');
  const label = t(collapsed ? 'runBoard.expand' : 'runBoard.collapse');
  runBoardToggle.title = label;
  runBoardToggle.setAttribute('aria-label', label);
  // **畳みは自分で伝える** —— ドラッグで高さを書いてあると箱の大きさが変わらず、splitter.js の
  // ResizeObserver が鳴かない(畳んだのに行の無い高い帯が残る)
  reapplyPaneHeights();
}

// **ヘッダ行のどこを押しても開閉する**(三角だけが当たり判定だと小さすぎる。ユーザー指摘)。
// トグルは <button> なのでキーボードの Enter/Space も click になり、そのままここへ来る
runBoardHeader.addEventListener('click', () => {
  collapsed = !collapsed;
  applyCollapsedUi();
  render();
  vscode.postMessage({ type: 'setRunBoardCollapsed', value: collapsed });
});

/** host からの復元値(sendInitialState)。ユーザー操作の再送はしない(setFleetVisible と同じ規律)。 */
export function setRunBoardCollapsed(value) {
  if (typeof value !== 'boolean') {
    return;
  }
  collapsed = value;
  applyCollapsedUi();
}

// 表示フィルタの切り替えでもツリーを描き直す(deviceTiles.js が入口で落とした一覧を読むので、
// 呼ばないと隠したはずのデバイスが次の監視サイクルまで残る)
onPlatformFilterChanged(() => render());

// ---- 2カラムの境目(ユーザー決定) ----
// **px で持つ**(比率ではない) —— ドラッグは px で来るので、比率にすると丸めのたびに境目が滑る。
// null = まだドラッグされていない = 既定(いちばん長いラベルの幅)を毎回引き直す。
// **どこにも保存しない**(ユーザー決定)—— 寿命はこのパネルそのもの。タブを閉じたら
// 解放し、開き直したら既定へ戻す。**この変数だけが持ち主**なので、host へ送る・getState へ書く
// のどちらも足さない(どちらも閉じても残り、リセットされなくなる)。
// 隠す/再表示は retainContextWhenHidden で webview が生き続けるため、幅も保たれる。
let desiredSplit = null;

// 左右それぞれに最低これだけは残す(境目を端まで引き切って片方を潰さない)。
const MIN_COLUMN_WIDTH = 80;
// 既定は**いちばん長いラベルがちょうど収まる幅 + DEFAULT_SPLIT_EXTRA**(ユーザー決定)。
// 比率ではないので、機械名・デバイス名の長さで決まる。ドラッグするまでは毎回引き直す
// (デバイスが増えて名前が伸びたら追従する)。
function naturalLeftWidth() {
  // 測る間だけ左カラムを中身なりの幅にする(flex-basis が効いたままだと今の幅しか返らない)
  runBoardRows.classList.add('run-board-measuring');
  let width = 0;
  for (const el of runBoardRows.querySelectorAll('.run-board-col-left')) {
    // **offsetWidth ではなく矩形の実寸で測る** —— offsetWidth は整数へ丸めた値なので、
    // 中身が 422.4px のときに 422 を返し、0.4px 足りずにその行だけ "…" になる
    // (実地で踏んだ: 同じ長さの行が1つだけ切れた)。ceil は最後に1回だけ
    width = Math.max(width, el.getBoundingClientRect().width);
  }
  runBoardRows.classList.remove('run-board-measuring');
  return Math.ceil(width);
}
// 既定の幅(ドラッグ前)に足す余白(px。ユーザー決定)。ラベルがちょうど収まる幅では
// 左カラムが詰まって見えるため。右カラムの 80px は clampSplit が別に守る
const DEFAULT_SPLIT_EXTRA = 100;
// 行の左右の padding(style.css の .run-board-row-summary / .run-board-lane と同じ値)。
// **片方だけ変えない** —— 境目の x は 8px + --rb-left で描くので、ここがずれると線と列が割れる。
const ROW_PADDING_X = 8;

function splitContentWidth() {
  return runBoardRows.clientWidth - ROW_PADDING_X * 2;
}

function clampSplit(width, content) {
  return Math.min(Math.max(width, MIN_COLUMN_WIDTH), Math.max(MIN_COLUMN_WIDTH, content - MIN_COLUMN_WIDTH));
}

function renderSplit() {
  const content = splitContentWidth();
  if (content <= 0) {
    return;   // 「デバイスモニター」タブが非表示の間は測れない(splitter.js の panelHidden と同じ規律)
  }
  const left = clampSplit(desiredSplit ?? naturalLeftWidth() + DEFAULT_SPLIT_EXTRA, content);
  runBoard.style.setProperty('--rb-left', left + 'px');
  // 境目は見出し行には掛けない(掴む相手ではないうえ、チェックボックスに重なる)
  runBoard.style.setProperty('--rb-head', runBoardHeader.offsetHeight + 'px');
}

let splitPointerId = null;

runBoardSplit.addEventListener('pointerdown', (event) => {
  if (event.button !== 0) {
    return;
  }
  splitPointerId = event.pointerId;
  runBoardSplit.setPointerCapture(event.pointerId);
  runBoardSplit.classList.add('dragging');
  event.preventDefault();
  event.stopPropagation();
});
runBoardSplit.addEventListener('pointermove', (event) => {
  if (splitPointerId !== event.pointerId) {
    return;
  }
  const content = splitContentWidth();
  if (content <= 0) {
    return;
  }
  // 掴んだ位置ではなく**ポインタの x そのもの**で決める(境目は 7px の当たりに対し線は1px なので、
  // 差分で動かすと掴んだ場所ぶんずれたまま追従する)
  desiredSplit = clampSplit(
    Math.round(event.clientX - runBoardRows.getBoundingClientRect().left - ROW_PADDING_X),
    content,
  );
  renderSplit();
});
const endSplitDrag = (event) => {
  if (splitPointerId !== event.pointerId) {
    return;
  }
  splitPointerId = null;
  runBoardSplit.classList.remove('dragging');
  runBoardSplit.releasePointerCapture(event.pointerId);
};
runBoardSplit.addEventListener('pointerup', endSplitDrag);
runBoardSplit.addEventListener('pointercancel', endSplitDrag);
// **見出し行の開閉へ波及させない**(境目は run ボードの中に居る)
runBoardSplit.addEventListener('click', (event) => event.stopPropagation());
window.addEventListener('resize', () => renderSplit());

/** デバイスの一覧・モニターの範囲(project/profile)が変わったら main.js から呼ぶ。
 * **run ボードは monitorRuns でしか描き直さない**ので、これが無いとツリーのデバイスが古いまま残る。 */
export function refreshRunBoardDevices() {
  render();
}

/** hostMetricsMachines 受信のたびに main.js から呼ぶ(専用のホスト配線を増やさない。上のコメント参照)。 */
export function setRunBoardMachines(machines) {
  remoteMachines = Array.isArray(machines) ? machines.filter((m) => typeof m === 'string' && m !== '') : [];
  render();
}

function renderHeader(groups) {
  runBoardTitle.textContent = t('runBoard.title', { count: String(groups.length) });
  // **折りたたみ中は出さない**(本体が見えないので押しても何も起きない)。run 0 本でも出す ——
  // これはモードのスイッチで、「いま開く行があるか」とは別
  runBoardExpandAll.style.display = collapsed ? 'none' : '';
  // ON の見せ方は「デバイスをすべて選択」と同じ .toggled(ユーザー決定)
  runBoardExpandAll.classList.toggle('toggled', expandAll);
  runBoardExpandAll.setAttribute('aria-pressed', expandAll ? 'true' : 'false');
  // アイコンだけなので(ユーザー決定)、名前は tooltip と aria-label が持つ。
  // 出し方は「デバイスをすべて選択」と同じ(deviceTiles.js の renderSelectAllButton)。
  // ネイティブ title は使わない(表示まで約1秒で指定できない。setHoverTip が title を空にするので
  // 二重にも出ない)。**文言は ON/OFF で入れ替えない**(ユーザー決定)
  const expandAllLabel = t('runBoard.expandAll');
  setHoverTip(runBoardExpandAll, expandAllLabel);
  runBoardExpandAll.setAttribute('aria-label', expandAllLabel);
}

function setExpandAll(value) {
  expandAll = value;
  vscode.postMessage({ type: 'setRunBoardExpandAll', value });
}

// **ヘッダ行の開閉へ波及させない** —— 親(run-board-header)が click で開閉するので、
// stopPropagation を外すとボタンを押した瞬間にボードごと畳まれる
runBoardExpandAll.addEventListener('click', (event) => {
  event.stopPropagation();
  if (expandAll) {
    // OFF にしたら個別の記録も捨てて既定へ戻す(残すと OFF にしたのに全部開いたままになる)
    machineExpansion.clear();
    persistMachineExpansion();
  }
  setExpandAll(!expandAll);
  render();
});

/** host からの復元値(sendInitialState)。ユーザー操作の再送はしない(setRunBoardCollapsed と同じ規律)。 */
export function setRunBoardExpandAll(value) {
  if (typeof value !== 'boolean') {
    return;
  }
  expandAll = value;
  render();
}

// run の無い機械の行(行の DOM は run 行と共有する = ensureRow)。バッジと状態(空き / —)だけを
// 出し、開くとその機械のデバイスが並ぶ。**デバイスはその状態に関わらず出す**(停止中でも消さない)。
function updateIdleRow(row, entry) {
  row.run = null;
  row.idle = entry;
  row.rowEl.classList.remove('run-board-row-hasFailed');
  showMachineBadge(row, machineKey(entry.machine));
  row.scopeEl.textContent = '';
  row.progressEl.style.display = 'none';
  row.countsEl.textContent = '';
  row.notesEl.style.display = 'none';
  row.issuerEl.style.display = 'none';
  row.timeEl.style.display = 'none';
  // 空きは語、**不明は「—」**(ユーザー決定)。どちらもグレーで警告色は使わない ——
  // 観測できていないのは異常ではない。**何のダッシュかは title で言う**
  row.statusEl.style.display = '';
  row.statusEl.className = 'run-board-idle-machine-status run-board-machine-state-' + entry.status;
  if (entry.status === 'unknown') {
    row.statusEl.textContent = t('runBoard.remainingUnknown');
    row.statusEl.title = t('runBoard.machineUnknown');
  } else {
    row.statusEl.textContent = t('runBoard.machineIdle');
    row.statusEl.title = '';
  }
  const expandable = renderDevices(row, machineKey(entry.machine), undefined);
  applyRowExpansion(row, expandable);
}

/** 行の先頭のマシン名バッジ(**run の行も空きの行も同じ見た目**。機械の色も同じ)。 */
function showMachineBadge(row, machine) {
  row.machineBadgeEl.style.display = '';
  row.machineBadgeEl.textContent = machineLabel(machine);
  paintMachineBadge(row.machineBadgeEl, machine);
}

/** 三角と行の開閉。子(デバイス・issuer)が無い行の三角は列を揃えるためだけに出す。 */
function applyRowExpansion(row, expandable) {
  const expanded = expandable && isRowExpanded(row);
  row.rowEl.classList.toggle('run-board-row-expanded', expanded);
  row.chevronEl.classList.toggle('run-board-chevron-empty', !expandable);
  row.chevronEl.dataset.expanded = expanded ? 'true' : 'false';
  row.chevronEl.setAttribute('aria-expanded', expanded ? 'true' : 'false');
  // **ツールチップは出さない**(ユーザー決定)—— 名前は読み上げ用の aria-label だけが持つ
  row.chevronEl.setAttribute('aria-label', t(expanded ? 'runBoard.collapseLanes' : 'runBoard.expandLanes'));
}

// 機械のデバイスを行の子に並べる。**その機械のデバイスを全部並べ、run が使っているデバイスにだけ
// シナリオを添える**(ユーザー決定)—— run に出ていないデバイスも見えるようにする。
// デバイスの一覧と並びはラインビュー(monitorDevices)から採る。戻り値 = 1台でも並んだか。
function renderDevices(row, machine, run) {
  row.lanesEl.textContent = '';
  row.laneRows = new Map();
  const devices = devicesOnMachine(machine);
  const laneByKey = new Map((run?.lanes ?? []).map((lane) => [lane.key, lane]));
  // デバイスの一覧に無いレーン(消えたタイル・観測窓の外)も落とさない —— 走っている事実は隠さない
  const extraLanes = (run?.lanes ?? []).filter((lane) => {
    const hit = devices.some((device) => device.laneKey !== undefined && device.laneKey === lane.key);
    return !hit && !(lane.platform !== undefined && !isPlatformVisible(lane.platform));
  });
  for (const device of devices) {
    const lane = device.laneKey === undefined ? undefined : laneByKey.get(device.laneKey);
    appendDeviceLane(row, machine, device.name, lane, run?.receivedAtMs ?? 0, device.platform);
  }
  for (const lane of extraLanes) {
    appendDeviceLane(row, machine, lane.name, lane, run.receivedAtMs, lane.platform);
  }
  renderLaneTimes(row);
  return devices.length > 0 || extraLanes.length > 0;
}

/** その run がこの機械で使っているデバイスをラインビューで選ぶ。 */
function selectRunDevices(run) {
  const ids = [];
  for (const lane of run.lanes) {
    const id = deviceIdForLane(run.machine, lane.key);
    if (id !== undefined) {
      ids.push(id);
    }
  }
  selectOnlyDevices(ids);
}

function toggleRowExpanded(key) {
  const row = rows.get(key);
  if (!row) {
    return;
  }
  const wasExpanded = row.chevronEl.dataset.expanded === 'true';
  const leavingExpandAll = expandAll;
  if (expandAll) {
    // **自動展開を抜ける**: いま全行が開いて見えているので、その姿を個別の記録へ写してから
    // 抜ける(写さないと、1行閉じただけで他の行まで既定の姿に戻って見える)
    for (const other of rows.values()) {
      machineExpansion.set(expansionKey(other), true);
    }
    setExpandAll(false);
  }
  machineExpansion.set(expansionKey(row), !wasExpanded);
  persistMachineExpansion();
  if (leavingExpandAll) {
    // ヘッダのトグルの見た目(ON/OFF)も変わるので、行だけでなく全体を描き直す
    render();
    return;
  }
  // **押したその場で描き直す** —— 次の監視サイクル(約2秒)まで待つと、押してから開くまで
  // 目に見える遅れになる
  if (row.run) {
    updateRow(row, row.run);
  } else if (row.idle) {
    updateIdleRow(row, row.idle);
  }
}

function ensureRow(key) {
  const existing = rows.get(key);
  if (existing) {
    return existing;
  }
  const rowEl = document.createElement('div');
  rowEl.className = 'run-board-row';
  rowEl.dataset.rowKey = key;

  const summaryEl = document.createElement('div');
  summaryEl.className = 'run-board-row-summary';

  // **文字は常に同じ三角**で、向きは CSS の回転で表す(VSCode のツリーと同じ挙動)。
  // 文字を差し替える形(▸/▾)は字面が細く、展開できる行だと気づかれなかった
  const chevronEl = document.createElement('span');
  chevronEl.className = 'run-board-chevron';
  chevronEl.textContent = '▶';
  chevronEl.setAttribute('role', 'button');

  const machineBadgeEl = document.createElement('span');
  machineBadgeEl.className = 'badge badge-remote run-board-machine-badge';

  const scopeEl = document.createElement('span');
  scopeEl.className = 'run-board-scope';

  const progressEl = document.createElement('span');
  progressEl.className = 'run-board-progress';
  const progressBarEl = document.createElement('span');
  progressBarEl.className = 'run-board-progress-bar';
  progressEl.appendChild(progressBarEl);

  const countsEl = document.createElement('span');
  countsEl.className = 'run-board-counts';

  const notesEl = document.createElement('span');
  notesEl.className = 'run-board-notes';

  // run の無い機械の行だけが使う(空き / 不明)。run の行では display:none
  const statusEl = document.createElement('span');
  statusEl.className = 'run-board-idle-machine-status';
  statusEl.style.display = 'none';

  const timeEl = document.createElement('span');
  timeEl.className = 'run-board-time';
  const elapsedEl = document.createElement('span');
  elapsedEl.className = 'run-board-elapsed';
  const remainingEl = document.createElement('span');
  remainingEl.className = 'run-board-remaining';
  timeEl.append(elapsedEl, document.createTextNode(' / '), remainingEl);

  // 2カラム(ユーザー決定): 左 = ツリー・右 = ステータス。**箱の幅は全行で同じ**
  // ので、境目(--rb-left)が行の種類によらず1本に見える
  const leftEl = document.createElement('span');
  leftEl.className = 'run-board-col-left';
  leftEl.append(chevronEl, machineBadgeEl, scopeEl);
  const rightEl = document.createElement('span');
  rightEl.className = 'run-board-col-right';
  rightEl.append(progressEl, countsEl, statusEl, notesEl, timeEl);
  summaryEl.append(leftEl, rightEl);

  const issuerEl = document.createElement('div');
  issuerEl.className = 'run-board-issuer';

  const lanesEl = document.createElement('div');
  lanesEl.className = 'run-board-lanes';

  rowEl.append(summaryEl, issuerEl, lanesEl);

  chevronEl.addEventListener('click', (event) => {
    event.stopPropagation();
    toggleRowExpanded(key);
  });
  // 行を押したらその機械のデバイスを選ぶ(run の行は run がこの機械で使っているデバイスだけ)
  summaryEl.addEventListener('click', () => {
    const current = rows.get(key);
    if (!current) {
      return;
    }
    if (current.run) {
      selectRunDevices(current.run);
    } else if (current.idle) {
      selectOnlyDevices(devicesOnMachine(machineKey(current.idle.machine)).map((d) => d.id));
    }
  });

  const row = {
    rowEl, chevronEl, machineBadgeEl, scopeEl, progressEl, progressBarEl, countsEl, statusEl, notesEl,
    timeEl, elapsedEl, remainingEl, issuerEl, lanesEl,
    key, run: null, idle: null, laneRows: new Map(),
  };
  rows.set(key, row);
  return row;
}

function renderRowTime(row) {
  const run = row.run;
  if (!run) {
    return;
  }
  const now = Date.now();
  row.elapsedEl.textContent = formatMinSec(liveElapsedSeconds(run.elapsedSeconds, run.receivedAtMs, now));
  const remaining = liveRemaining(run.etaSeconds, run.receivedAtMs, now);
  if (!remaining) {
    row.remainingEl.textContent = t('runBoard.remainingUnknown');
  } else if (remaining.overageSeconds !== undefined) {
    row.remainingEl.textContent = t('runBoard.remainingOverage', { time: formatMinSec(remaining.overageSeconds) });
  } else {
    row.remainingEl.textContent = t('runBoard.remainingTime', { time: formatMinSec(remaining.remainingSeconds) });
  }
}

function renderLaneTimes(row) {
  const now = Date.now();
  for (const entry of row.laneRows.values()) {
    entry.elapsedEl.textContent = formatMinSec(liveElapsedSeconds(entry.base, entry.receivedAtMs, now));
  }
}

// ツリーの1行(= 1台)。`lane` 省略 = そのデバイスは今の run に出ていない(名前だけ出す)。
// machine は machineList() の鍵でも monitorRuns の規約でも受ける(呼び手が揃える)。
function appendDeviceLane(row, machine, name, lane, receivedAtMs, platform) {
  const laneEl = document.createElement('div');
  laneEl.className = 'run-board-lane';

  // デバイスのアイコン(ユーザー決定)。**色はプラットフォームのバッジと同じ**
  // (iOS / Android。CSS の .run-board-lane-icon-* が持つ)。platform を持たないデバイスは
  // 色を付けない(既定の文字色)—— 知らないものを iOS にも Android にも見せない
  const iconEl = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  iconEl.setAttribute('class', 'run-board-lane-icon'
    + (platform === 'ios' || platform === 'android' ? ` run-board-lane-icon-${platform}` : ''));
  iconEl.setAttribute('viewBox', '0 0 16 16');
  iconEl.setAttribute('width', '12');
  iconEl.setAttribute('height', '12');
  iconEl.setAttribute('aria-hidden', 'true');
  const body = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
  body.setAttribute('x', '4.2');
  body.setAttribute('y', '1.2');
  body.setAttribute('width', '7.6');
  body.setAttribute('height', '13.6');
  body.setAttribute('rx', '1.8');
  body.setAttribute('fill', 'none');
  body.setAttribute('stroke', 'currentColor');
  body.setAttribute('stroke-width', '1.2');
  const indicator = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
  indicator.setAttribute('x', '6.6');
  indicator.setAttribute('y', '11.6');
  indicator.setAttribute('width', '2.8');
  indicator.setAttribute('height', '1.1');
  indicator.setAttribute('rx', '0.55');
  indicator.setAttribute('fill', 'currentColor');
  iconEl.append(body, indicator);

  const nameEl = document.createElement('span');
  nameEl.className = 'run-board-lane-name';
  nameEl.textContent = name;

  const scenarioEl = document.createElement('span');
  scenarioEl.className = 'run-board-lane-scenario';
  // scenario 省略 = そのレーンに今の割り当てが無い(直前の1本を終えて次を待つ。
  // FTCore.RunProgressLane の契約)。**レーンごとの残り本数は持たない**(design.md §18.1)。
  const idle = lane !== undefined && lane.scenario === undefined;
  scenarioEl.textContent = lane === undefined ? '' : (idle ? t('runBoard.laneIdle') : `▶ ${lane.scenario}`);

  const elapsedEl = document.createElement('span');
  elapsedEl.className = 'run-board-lane-elapsed';
  // 待機中は経過も無い(「—」は run 側の見積もり無し表示と同じ、i18n を通さない記号)。
  elapsedEl.textContent = idle ? '—' : '';

  const leftEl = document.createElement('span');
  leftEl.className = 'run-board-col-left';
  leftEl.append(iconEl, nameEl);
  const rightEl = document.createElement('span');
  rightEl.className = 'run-board-col-right';
  rightEl.append(scenarioEl, elapsedEl);
  laneEl.append(leftEl, rightEl);
  // **デバイスの行は押しても何も起きない**(ユーザー決定)—— ここは実行状況を読む場所で、
  // ラインビューの選択を動かす口ではない(選択は機械の行が持つ)
  row.lanesEl.appendChild(laneEl);

  if (lane !== undefined && !idle && lane.scenarioElapsedSeconds !== undefined) {
    row.laneRows.set((machine ?? '') + '\u0000' + lane.key, {
      elapsedEl, base: lane.scenarioElapsedSeconds, receivedAtMs,
    });
  }
}

// run のある機械の行。**1行に「(マシン名) プロジェクト / 実行プロファイル  進捗  経過 / 残り」**
// (ユーザー決定)。値はこの機械の run のもの —— 機械分担の run は機械ごとに行が分かれ、
// それぞれが自分の進捗を出す(束ねた合計は「実行中 N」の件数だけが使う)。
function updateRow(row, run) {
  row.run = run;
  row.idle = null;
  row.statusEl.style.display = 'none';
  row.timeEl.style.display = '';
  row.rowEl.classList.toggle('run-board-row-hasFailed', run.failed > 0);
  showMachineBadge(row, run.machine);

  // profile はプロファイル無し実行(--dry-run 等)では省略されうる(FTCore.RunProgressRecord.profile)。
  row.scopeEl.textContent = run.profile ? `${run.project} / ${run.profile}` : run.project;

  // **走り出す前(ビルド中・供給中・Vision のコンパイル待ち)は進捗を出さない** —— 本数も割合もまだ意味を持たない
  // (docs/design.md §18.5)。経過だけは出す(どれくらい待っているかが分かる)
  const beforeRunning = run.phase !== 'running';
  row.progressEl.style.display = beforeRunning ? 'none' : '';
  if (beforeRunning) {
    row.countsEl.textContent = t(run.phase === 'building' ? 'runBoard.building'
      : run.phase === 'compiling' ? 'runBoard.compiling' : 'runBoard.preparing');
  } else {
    const pct = run.total > 0 ? Math.max(0, Math.min(1, run.done / run.total)) * 100 : 0;
    row.progressBarEl.style.width = pct + '%';
    row.countsEl.textContent = `${run.done}/${run.total}`;
    if (run.failed > 0) {
      const failedEl = document.createElement('span');
      failedEl.className = 'run-board-counts-failed';
      failedEl.textContent = `❌${run.failed}`;
      row.countsEl.append(failedEl);
    }
  }

  // **詰まりは事実だけ**(0 のときは出さない)。「遅い」「異常」とは書かない ——
  // アプリが重いのか機械が混んでいるのかツールには分けられない(docs/design.md §18.5)
  const notes = [];
  if (run.requeued > 0) {
    notes.push(t('runBoard.requeued', { count: String(run.requeued) }));
  }
  if (run.laneDropouts > 0) {
    notes.push(t('runBoard.laneDropouts', { count: String(run.laneDropouts) }));
  }
  row.notesEl.textContent = notes.join('  ');
  row.notesEl.style.display = notes.length > 0 ? '' : 'none';

  const showIssuer = !run.mine && Boolean(run.issuer);
  if (showIssuer) {
    row.issuerEl.textContent = t('runBoard.issuerRun', { issuer: run.issuer });
    row.issuerEl.style.display = '';
  } else {
    row.issuerEl.style.display = 'none';
  }

  renderRowTime(row);
  const hasDevices = renderDevices(row, run.machine, run);
  applyRowExpansion(row, hasDevices || showIssuer);
}

function render() {
  const groups = buildRunGroups(runsByMachine);
  renderHeader(groups);
  const idleByMachine = new Map(
    machinesWithoutRuns(runsByMachine, machineList(), groups).map((e) => [e.machine, e]),
  );

  // **並びは常に機械の順**(machineList = local → 登録簿の順)。run が始まっても機械の位置は
  // 動かさない(ユーザー決定)—— 動くと目が追えない
  const seen = new Set();
  const placeRun = (run) => {
    const key = runRowKey(run);
    seen.add(key);
    const row = ensureRow(key);
    updateRow(row, run);
    // 既存ノードへの appendChild は移動として働く(重複しない)
    runBoardRows.appendChild(row.rowEl);
  };
  const placedMachines = new Set();
  for (const machine of machineList()) {
    placedMachines.add(machine);
    // 同じ機械で run が複数走っていれば、その機械の行が run の数だけ続く
    for (const group of groups) {
      for (const run of group.runs) {
        if ((run.machine ?? LOCAL_MACHINE_KEY) === machine) {
          placeRun(run);
        }
      }
    }
    const idle = idleByMachine.get(machine);
    if (idle) {
      const key = idleRowKey(machine);
      seen.add(key);
      const row = ensureRow(key);
      updateIdleRow(row, idle);
      runBoardRows.appendChild(row.rowEl);
    }
  }
  // 登録簿に無い機械(無効にした機械を含む)の run も落とさない —— 走っている事実は隠さない
  for (const group of groups) {
    for (const run of group.runs) {
      if (!placedMachines.has(run.machine ?? LOCAL_MACHINE_KEY)) {
        placeRun(run);
      }
    }
  }

  for (const [key, row] of rows) {
    if (!seen.has(key)) {
      row.rowEl.remove();
      rows.delete(key);
    }
  }

  // **行を作り終えてから測る** —— 既定の幅はいちばん長いラベルから決めるので、
  // 行が揃っていないと短い側に決まってしまう
  renderSplit();
}

/** main.js の 'monitorRuns' ケースから渡す(1件 = 1機械ぶん。契約は monitorDeviceModel.ts)。 */
export function applyMonitorRuns(message) {
  runsByMachine = applyMonitorRunsEvent(runsByMachine, {
    machine: message.machine,
    observed: message.observed,
    runs: message.runs,
  });
  render();
}

/** monitor プロセスの(再)起動の合図。machineLocks と同じ寿命 —— 古い run の控えを畳む。 */
export function resetRunBoard() {
  runsByMachine = new Map();
  render();
}

applyCollapsedUi();
render();

// 経過・残りの秒読み(webview の時計)。**DOM は作り直さず数字だけ**書き換える(CLAUDE.md の規律)。
setInterval(() => {
  for (const row of rows.values()) {
    if (row.run) {
      renderRowTime(row);
      renderLaneTimes(row);
    }
  }
}, 1000);
