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
  deviceIdForLane, selectOnlyDevices, devicesOnMachine, currentMonitorScope,
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
// run も展開された状態で出る(ユーザー決定 2026-09-20)。host が workspaceState に持つ。
let expandAll = false;
// 個々の run 行の展開。groupKey は run が終われば二度と現れないので、host 側には
// 永続化しない(webview の getState だけ = 同一パネルの再読込(言語切替)を跨ぐだけで十分)。
const expandedGroups = new Set(
  Array.isArray(persistedState.runBoardExpandedGroups) ? persistedState.runBoardExpandedGroups : [],
);

// groupKey -> 行の DOM とブックキーピング。render() が groups の集合に合わせて足し引きする。
const rows = new Map();

/** その run の行を開くか。**expandAll が ON なら個別の記録によらず開く**(新しい行も含む)。 */
function isGroupExpanded(groupKey) {
  return expandAll || expandedGroups.has(groupKey);
}

function persistExpandedGroups() {
  vscode.setState(Object.assign({}, vscode.getState(), { runBoardExpandedGroups: [...expandedGroups] }));
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

// run が1本も走っていない機械の行の鍵。**groupKey と同じ Map に入れる**ので、run の
// groupKey(runGroup/runID/pid)と衝突しない接頭辞を付ける
const MACHINE_ROW_PREFIX = '\u0000machine\u0000';
function machineRowKey(machine) {
  return MACHINE_ROW_PREFIX + machine;
}

function machineList() {
  // **「マシン有効」が off の機械は出さない**(ユーザー決定 2026-09-22)—— ディスパッチの対象外
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
// 呼ばないと隠したはずの台が次の監視サイクルまで残る)
onPlatformFilterChanged(() => render());

// ---- 2カラムの境目(ユーザー決定 2026-09-22) ----
// **px で持つ**(比率ではない) —— ドラッグは px で来るので、比率にすると丸めのたびに境目が滑る。
// null = まだドラッグされていない = 既定(いちばん長いラベルの幅)を毎回引き直す。
// **どこにも保存しない**(ユーザー決定 2026-09-22)—— 寿命はこのパネルそのもの。タブを閉じたら
// 解放し、開き直したら既定へ戻す。**この変数だけが持ち主**なので、host へ送る・getState へ書く
// のどちらも足さない(どちらも閉じても残り、リセットされなくなる)。
// 隠す/再表示は retainContextWhenHidden で webview が生き続けるため、幅も保たれる。
let desiredSplit = null;

// 左右それぞれに最低これだけは残す(境目を端まで引き切って片方を潰さない)。
const MIN_COLUMN_WIDTH = 80;
// 既定は**いちばん長いラベルがちょうど収まる幅**(ユーザー決定 2026-09-22)。
// 比率ではないので、機械名・台名の長さで決まる。ドラッグするまでは毎回引き直す
// (台が増えて名前が伸びたら追従する)。
function naturalLeftWidth() {
  // 測る間だけ左カラムを中身なりの幅にする(flex-basis が効いたままだと今の幅しか返らない)
  runBoardRows.classList.add('run-board-measuring');
  let width = 0;
  for (const el of runBoardRows.querySelectorAll('.run-board-col-left')) {
    // **offsetWidth ではなく矩形の実寸で測る** —— offsetWidth は整数へ丸めた値なので、
    // 中身が 422.4px のときに 422 を返し、0.4px 足りずにその行だけ "…" になる
    // (2026-09-22 に実地で踏んだ: 同じ長さの行が1つだけ切れた)。ceil は最後に1回だけ
    width = Math.max(width, el.getBoundingClientRect().width);
  }
  runBoardRows.classList.remove('run-board-measuring');
  return Math.ceil(width);
}
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
  const left = clampSplit(desiredSplit ?? naturalLeftWidth(), content);
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

/** 台の一覧・モニターの範囲(project/profile)が変わったら main.js から呼ぶ。
 * **run ボードは monitorRuns でしか描き直さない**ので、これが無いとツリーの台が古いまま残る。 */
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
  // ON の見せ方は「デバイスをすべて選択」と同じ .toggled(ユーザー決定 2026-09-20)
  runBoardExpandAll.classList.toggle('toggled', expandAll);
  runBoardExpandAll.setAttribute('aria-pressed', expandAll ? 'true' : 'false');
  // アイコンだけなので(ユーザー決定 2026-09-21)、名前は tooltip と aria-label が持つ。
  // 出し方は「デバイスをすべて選択」と同じ(deviceTiles.js の renderSelectAllButton)。
  // ネイティブ title は使わない(表示まで約1秒で指定できない。setHoverTip が title を空にするので
  // 二重にも出ない)。**文言は ON/OFF で入れ替えない**(ユーザー決定 2026-09-21)
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
    // OFF にしたら個別の記録も畳む(残すと OFF にしたのに全部開いたままになる)
    expandedGroups.clear();
    persistExpandedGroups();
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

// run が1本も走っていない機械の行の中身(行の DOM は run 行と共有する = ensureRow)。
// **run のある機械はここに出さない** —— その機械は run の行として出ているので二重になる。
// **台のツリーは run の有無に関わらず出す**(ユーザー決定 2026-09-22)。
function updateMachineRow(row, machine, status) {
  row.group = null;
  row.machine = machine;
  // 三角を押したときにこの行だけを描き直せるよう控える(toggleGroupExpanded)
  row.machineStatus = status;
  const devices = devicesOnMachine(machineKey(machine));
  // 開くものが無い行は三角を薄くして押せなくする(run 行の空レーンと同じ扱い)
  const expandable = devices.length > 0;
  const expanded = expandable && isGroupExpanded(machineRowKey(machine));
  row.rowEl.classList.toggle('run-board-row-expanded', expanded);
  row.rowEl.classList.toggle('run-board-row-machine', true);
  row.chevronEl.classList.toggle('run-board-chevron-empty', !expandable);
  row.chevronEl.dataset.expanded = expanded ? 'true' : 'false';
  row.chevronEl.setAttribute('aria-expanded', expanded ? 'true' : 'false');

  row.machineBadgeEl.style.display = '';
  row.machineBadgeEl.textContent = machineLabel(machine);
  paintMachineBadge(row.machineBadgeEl, machineKey(machine));

  // 何を見ている台なのか = モニターが台を並べる範囲(ツールバーの選択)。run 行の scope と
  // 同じ形で出す(あちらはその run の project/profile)
  const scope = currentMonitorScope();
  row.scopeEl.textContent = scope.profile ? `${scope.project} / ${scope.profile}` : scope.project;

  row.progressEl.style.display = 'none';
  row.countsEl.textContent = '';
  row.notesEl.style.display = 'none';
  row.issuerEl.style.display = 'none';
  row.timeEl.style.display = 'none';

  // 空きは語、**不明は「—」**(ユーザー決定 2026-09-20。`remote status` の LOCK/FM 欄が
  // 判定不能に使うのと同じ記法・ボードの「残り —」とも同じ文字)。赤字にはしない ——
  // 観測できていないのは異常ではないので、警告色を使うと毎回そこへ目が行く。
  // **何のダッシュかは title で言う**(記号だけだと読み手が意味を持てない)
  row.statusEl.style.display = '';
  row.statusEl.className = 'run-board-idle-machine-status run-board-machine-state-' + status;
  if (status === 'unknown') {
    row.statusEl.textContent = t('runBoard.remainingUnknown');
    row.statusEl.title = t('runBoard.machineUnknown');
  } else {
    row.statusEl.textContent = t('runBoard.machineIdle');
    row.statusEl.title = '';
  }

  row.lanesEl.textContent = '';
  row.laneRows = new Map();
  for (const device of devices) {
    appendDeviceLane(row, machine, device.name, undefined, 0, device.id);
  }
}

function selectRunDevices(group) {
  const ids = [];
  for (const run of group.runs) {
    for (const lane of run.lanes) {
      const id = deviceIdForLane(run.machine, lane.key);
      if (id !== undefined) {
        ids.push(id);
      }
    }
  }
  selectOnlyDevices(ids);
}

function toggleGroupExpanded(groupKey) {
  const leavingExpandAll = expandAll;
  if (expandAll) {
    // **自動展開を抜ける**: いま全行が開いて見えているので、その姿を個別の記録へ写してから
    // 抜ける(写さないと、1行閉じただけで他の行まで畳まれて見える)
    // **いま出ている行の全部**(run の行と機械の行)を写す —— 機械の行を落とすと、
    // 1行畳んだだけで他の機械のツリーまで閉じて見える
    for (const key of rows.keys()) {
      expandedGroups.add(key);
    }
    setExpandAll(false);
  }
  if (expandedGroups.has(groupKey)) {
    expandedGroups.delete(groupKey);
  } else {
    expandedGroups.add(groupKey);
  }
  persistExpandedGroups();
  if (leavingExpandAll) {
    // ヘッダのトグルの見た目(ON/OFF)も変わるので、行だけでなく全体を描き直す
    render();
    return;
  }
  const row = rows.get(groupKey);
  if (!row) {
    return;
  }
  // **押したその場で描き直す** —— 次の監視サイクル(約2秒)まで待つと、押してから開くまで
  // 目に見える遅れになる。機械の行は group を持たないので、こちらも忘れず描き直す
  if (row.group) {
    updateRow(row, row.group);
  } else if (row.machine !== null) {
    updateMachineRow(row, row.machine, row.machineStatus);
  }
}

function ensureRow(groupKey) {
  const existing = rows.get(groupKey);
  if (existing) {
    return existing;
  }
  const rowEl = document.createElement('div');
  rowEl.className = 'run-board-row';
  rowEl.dataset.groupKey = groupKey;

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

  // run の無い機械の行だけが使う(空き / 不明)。run 行では display:none
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

  // 2カラム(ユーザー決定 2026-09-22): 左 = ツリー・右 = ステータス。**箱の幅は全行で同じ**
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
    toggleGroupExpanded(groupKey);
  });
  summaryEl.addEventListener('click', () => {
    const current = rows.get(groupKey);
    if (!current) {
      return;
    }
    if (current.group) {
      selectRunDevices(current.group);
    } else if (current.machine !== null) {
      // 機械の行を押したらその機械の台だけを選ぶ(run 行が run の台を選ぶのと同じ扱い)
      selectOnlyDevices(devicesOnMachine(machineKey(current.machine)).map((d) => d.id));
    }
  });

  const row = {
    rowEl, chevronEl, machineBadgeEl, scopeEl, progressEl, progressBarEl, countsEl, statusEl, notesEl,
    timeEl, elapsedEl, remainingEl, issuerEl, lanesEl,
    group: null, machine: null, machineStatus: null, laneRows: new Map(),
  };
  rows.set(groupKey, row);
  return row;
}

function renderRowTime(row) {
  const group = row.group;
  if (!group) {
    return;
  }
  const now = Date.now();
  row.elapsedEl.textContent = formatMinSec(liveElapsedSeconds(group.elapsedSeconds, group.receivedAtMs, now));
  const remaining = liveRemaining(group.etaSeconds, group.receivedAtMs, now);
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

// レーンの一覧は run が続く間ほぼ動かない(監視サイクルごとに毎回作り直しても軽い)ので
// diff はしない。作り直すのは展開したときと監視サイクルごとの update だけ(1秒ごとの秒読みは
// renderLaneTimes が数字だけ書き換える)。
function renderLanes(row, group) {
  row.lanesEl.textContent = '';
  row.laneRows = new Map();
  const multiMachine = group.runs.length > 1;
  for (const run of group.runs) {
    if (multiMachine) {
      const header = document.createElement('div');
      header.className = 'run-board-lane-machine-header';
      // **run 行のバッジと同じ見た目**(機械の色も同じ)—— 機械分担の run では
      // run 行にバッジを出せない(複数機械にまたがる)ので、ここが唯一の機械の目印になる
      const badge = document.createElement('span');
      badge.className = 'badge badge-remote run-board-machine-badge';
      badge.textContent = machineLabel(run.machine);
      paintMachineBadge(badge, run.machine);
      header.appendChild(badge);
      row.lanesEl.appendChild(header);
    }
    // **その機械の台を全部並べ、run が使っている台にだけシナリオを添える**
    // (ユーザー決定 2026-09-22)—— run に出ていない台も見えるようにする。台の一覧と並びは
    // ラインビュー(monitorDevices)から採る
    const laneByKey = new Map(run.lanes.map((lane) => [lane.key, lane]));
    const used = new Set();
    for (const device of devicesOnMachine(run.machine)) {
      const lane = device.laneKey === undefined ? undefined : laneByKey.get(device.laneKey);
      if (lane) {
        used.add(lane.key);
      }
      appendDeviceLane(row, run.machine, device.name, lane, run.receivedAtMs, device.id);
    }
    // **レーンの側にしか無い台は落とさない** —— 消えたタイル・観測窓の外でも run の事実は残す。
    // ただし表示フィルタで隠した側は出さない(台の一覧は入口で落ちているが、こちらは別経路)
    for (const lane of run.lanes) {
      if (used.has(lane.key) || (lane.platform !== undefined && !isPlatformVisible(lane.platform))) {
        continue;
      }
      appendDeviceLane(row, run.machine, lane.name, lane, run.receivedAtMs, undefined);
    }
  }
  renderLaneTimes(row);
}

// ツリーの1行(= 1台)。`lane` 省略 = その台は今の run に出ていない(名前だけ出す)。
// machine は machineList() の鍵でも monitorRuns の規約でも受ける(deviceIdForLane へはそのまま
// 渡すので、呼び手が揃える)。
function appendDeviceLane(row, machine, name, lane, receivedAtMs, deviceId) {
  const laneEl = document.createElement('div');
  laneEl.className = 'run-board-lane';

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
  leftEl.appendChild(nameEl);
  const rightEl = document.createElement('span');
  rightEl.className = 'run-board-col-right';
  rightEl.append(scenarioEl, elapsedEl);
  laneEl.append(leftEl, rightEl);
  laneEl.addEventListener('click', (event) => {
    event.stopPropagation();
    const id = deviceId ?? (lane === undefined ? undefined : deviceIdForLane(machine, lane.key));
    if (id !== undefined) {
      selectOnlyDevices([id]);
    }
  });
  row.lanesEl.appendChild(laneEl);

  if (lane !== undefined && !idle && lane.scenarioElapsedSeconds !== undefined) {
    row.laneRows.set((machine ?? '') + '\u0000' + lane.key, {
      elapsedEl, base: lane.scenarioElapsedSeconds, receivedAtMs,
    });
  }
}

function updateRow(row, group) {
  row.group = group;
  row.machine = null;
  // 行の DOM は機械の行と共有しているので、あちらの痕跡を必ず消す(使い回しで残る)
  row.rowEl.classList.remove('run-board-row-machine');
  row.chevronEl.classList.remove('run-board-chevron-empty');
  row.statusEl.style.display = 'none';
  row.timeEl.style.display = '';
  row.rowEl.classList.toggle('run-board-row-hasFailed', group.failed > 0);
  const expanded = isGroupExpanded(group.groupKey);
  row.rowEl.classList.toggle('run-board-row-expanded', expanded);
  row.chevronEl.dataset.expanded = expanded ? 'true' : 'false';
  row.chevronEl.setAttribute('aria-expanded', expanded ? 'true' : 'false');
  const chevronLabel = t(expanded ? 'runBoard.collapseLanes' : 'runBoard.expandLanes');
  row.chevronEl.title = chevronLabel;
  row.chevronEl.setAttribute('aria-label', chevronLabel);

  if (group.runs.length === 1) {
    row.machineBadgeEl.style.display = '';
    row.machineBadgeEl.textContent = machineLabel(group.runs[0].machine);
    paintMachineBadge(row.machineBadgeEl, group.runs[0].machine);
  } else {
    row.machineBadgeEl.style.display = 'none';
    paintMachineBadge(row.machineBadgeEl, undefined);
  }

  // profile はプロファイル無し実行(--dry-run 等)では省略されうる(FTCore.RunProgressRecord.profile)。
  row.scopeEl.textContent = group.profile ? `${group.project} / ${group.profile}` : group.project;

  // **走り出す前(ビルド中・供給中)は進捗を出さない** —— 本数も割合もまだ意味を持たない
  // (docs/design.md §18.5)。経過だけは出す(どれくらい待っているかが分かる)
  const beforeRunning = group.phase !== 'running';
  row.progressEl.style.display = beforeRunning ? 'none' : '';
  if (beforeRunning) {
    row.countsEl.textContent = t(group.phase === 'building' ? 'runBoard.building' : 'runBoard.preparing');
  } else {
    const pct = group.total > 0 ? Math.max(0, Math.min(1, group.done / group.total)) * 100 : 0;
    row.progressBarEl.style.width = pct + '%';
    row.countsEl.textContent = group.failed > 0
      ? `${group.done}/${group.total} ✕${group.failed}`
      : `${group.done}/${group.total}`;
  }

  // **詰まりは事実だけ**(0 のときは出さない)。「遅い」「異常」とは書かない ——
  // アプリが重いのか機械が混んでいるのかツールには分けられない(docs/design.md §18.5)
  const notes = [];
  if (group.requeued > 0) {
    notes.push(t('runBoard.requeued', { count: String(group.requeued) }));
  }
  if (group.laneDropouts > 0) {
    notes.push(t('runBoard.laneDropouts', { count: String(group.laneDropouts) }));
  }
  row.notesEl.textContent = notes.join('  ');
  row.notesEl.style.display = notes.length > 0 ? '' : 'none';

  if (!group.mine && group.issuer) {
    row.issuerEl.textContent = t('runBoard.issuerRun', { issuer: group.issuer });
    row.issuerEl.style.display = '';
  } else {
    row.issuerEl.style.display = 'none';
  }

  renderRowTime(row);
  renderLanes(row, group);
}

function render() {
  const groups = buildRunGroups(runsByMachine);
  renderHeader(groups);
  const idleStatus = new Map(
    machinesWithoutRuns(runsByMachine, machineList(), groups).map((e) => [e.machine, e.status]),
  );

  // **並びは常に機械の順**(machineList = local → 登録簿の順)。run が始まっても機械の位置は
  // 動かさない(ユーザー決定 2026-09-20)—— 動くと目が追えない
  const seen = new Set();
  const placed = new Set();
  const place = (group) => {
    placed.add(group.groupKey);
    seen.add(group.groupKey);
    const row = ensureRow(group.groupKey);
    updateRow(row, group);
    // 既存ノードへの appendChild は移動として働く(重複しない)
    runBoardRows.appendChild(row.rowEl);
  };
  for (const machine of machineList()) {
    for (const group of groups) {
      if (placed.has(group.groupKey)) {
        continue;
      }
      // 機械分担の run は**最初に現れた機械の位置**に1行だけ置く
      if (group.runs.some((run) => (run.machine ?? LOCAL_MACHINE_KEY) === machine)) {
        place(group);
      }
    }
    const status = idleStatus.get(machine);
    if (status !== undefined) {
      // 機械の行も run 行と同じ rows へ入れる(展開の記録・行の作りを共有する)
      const key = machineRowKey(machine);
      seen.add(key);
      const row = ensureRow(key);
      updateMachineRow(row, machine, status);
      runBoardRows.appendChild(row.rowEl);
    }
  }
  // 登録簿に無い機械の run も落とさない(machineList に出てこないぶん)
  for (const group of groups) {
    if (!placed.has(group.groupKey)) {
      place(group);
    }
  }

  for (const [groupKey, row] of rows) {
    if (!seen.has(groupKey)) {
      row.rowEl.remove();
      rows.delete(groupKey);
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
    if (row.group) {
      renderRowTime(row);
      renderLaneTimes(row);
    }
  }
}, 1000);
