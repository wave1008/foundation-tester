// run ボード(フリート横断の実行状況。docs/design.md §18)。ツールバー直下・ラインビューの上に
// 常設(main.js の 'monitorRuns'/'runBoardReset'/'runBoardCollapsed'/'hostMetricsMachines' ケースが
// このモジュールへ渡す。契約: monitorWebviewMessages.ts の同名メッセージ)。
//
// 状態の畳み込みは runBoardModel.ts(vscode 非依存・machineLockModel.ts と同じ立場)に委ね、
// ここは DOM の生成・更新と文言(t())だけを持つ。**経過秒の秒読みは自分の時計で1秒ごとに
// 数字だけ書き換える**(DOM は作り直さない。CLAUDE.md の規律)。

import { t } from '../i18n.js';
import { runBoard, runBoardHeader, runBoardToggle, runBoardTitle, runBoardExpandAll, runBoardRows } from './domRefs.js';
import { vscode, persistedState } from './vscodeApi.js';
import { paintMachineBadge } from './machineColors.js';
import { setHoverTip } from './hoverTip.js';
import { deviceIdForLane, selectOnlyDevices } from './deviceTiles.js';
import { reapplyPaneHeights } from './splitter.js';
import {
  LOCAL_MACHINE_KEY,
  applyMonitorRunsEvent,
  buildRunGroups,
  machinesWithoutRuns,
  liveElapsedSeconds,
  liveRemaining,
} from '../../runBoardModel';

// 手元の表示名。hostCharts.js の HM_LOCAL_LABEL と同じ規律(機械名なので翻訳しない)。
const LOCAL_LABEL = 'local';

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
  return machine === LOCAL_MACHINE_KEY || machine === undefined ? LOCAL_LABEL : machine;
}

function machineList() {
  return [LOCAL_MACHINE_KEY, ...remoteMachines];
}

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

// run が走っていない機械(展開時のみ。折りたたみ時はボード本体ごと隠れる)。
// **run のある機械はここに出さない** —— その機械は run の行として出ているので二重になる。
// **1つの grid に入れる**(行ごとに独立した flex にすると、機械名の長さで状態の列がガタつく)
function makeIdleMachineRow(machine, status) {
  const el = document.createElement('div');
  el.className = 'run-board-idle-machine';

  // **子を持たない行にも三角を出す**(ユーザー決定 2026-09-20)—— 空白にすると列は揃うが
  // 行の作りが run 行と違って見える。開くものが無いので押せない(薄く出すだけ)
  const chevron = document.createElement('span');
  chevron.className = 'run-board-chevron run-board-chevron-empty';
  chevron.textContent = '▶';

  const name = document.createElement('span');
  name.className = 'run-board-idle-machine-name';
  name.textContent = machineLabel(machine);

  // 空きは語、**不明は「—」**(ユーザー決定 2026-09-20。`remote status` の LOCK/FM 欄が
  // 判定不能に使うのと同じ記法・ボードの「残り —」とも同じ文字)。赤字にはしない ——
  // 観測できていないのは異常ではないので、警告色を使うと毎回そこへ目が行く。
  // **何のダッシュかは title で言う**(記号だけだと読み手が意味を持てない)
  const word = document.createElement('span');
  word.className = 'run-board-idle-machine-status run-board-machine-state-' + status;
  if (status === 'unknown') {
    word.textContent = t('runBoard.remainingUnknown');
    word.title = t('runBoard.machineUnknown');
  } else {
    word.textContent = t('runBoard.machineIdle');
  }

  el.append(chevron, name, word);
  return el;
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
    for (const group of buildRunGroups(runsByMachine)) {
      expandedGroups.add(group.groupKey);
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
  if (row && row.group) {
    updateRow(row, row.group);
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

  const timeEl = document.createElement('span');
  timeEl.className = 'run-board-time';
  const elapsedEl = document.createElement('span');
  elapsedEl.className = 'run-board-elapsed';
  const remainingEl = document.createElement('span');
  remainingEl.className = 'run-board-remaining';
  timeEl.append(elapsedEl, document.createTextNode(' / '), remainingEl);

  summaryEl.append(chevronEl, machineBadgeEl, scopeEl, progressEl, countsEl, notesEl, timeEl);

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
    if (current && current.group) {
      selectRunDevices(current.group);
    }
  });

  const row = {
    rowEl, chevronEl, machineBadgeEl, scopeEl, progressEl, progressBarEl, countsEl, notesEl, elapsedEl, remainingEl,
    issuerEl, lanesEl, group: null, laneRows: new Map(),
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
    for (const lane of run.lanes) {
      const laneEl = document.createElement('div');
      laneEl.className = 'run-board-lane';

      const nameEl = document.createElement('span');
      nameEl.className = 'run-board-lane-name';
      nameEl.textContent = lane.name;

      const scenarioEl = document.createElement('span');
      scenarioEl.className = 'run-board-lane-scenario';
      // scenario 省略 = そのレーンに今の割り当てが無い(直前の1本を終えて次を待つ。
      // FTCore.RunProgressLane の契約)。**レーンごとの残り本数は持たない**(design.md §18.1)。
      const idle = lane.scenario === undefined;
      scenarioEl.textContent = idle ? t('runBoard.laneIdle') : `▶ ${lane.scenario}`;

      const elapsedEl = document.createElement('span');
      elapsedEl.className = 'run-board-lane-elapsed';
      // 待機中は経過も無い(「—」は run 側の見積もり無し表示と同じ、i18n を通さない記号)。
      elapsedEl.textContent = idle ? '—' : '';

      laneEl.append(nameEl, scenarioEl, elapsedEl);
      laneEl.addEventListener('click', (event) => {
        event.stopPropagation();
        const id = deviceIdForLane(run.machine, lane.key);
        if (id !== undefined) {
          selectOnlyDevices([id]);
        }
      });
      row.lanesEl.appendChild(laneEl);

      if (!idle && lane.scenarioElapsedSeconds !== undefined) {
        row.laneRows.set((run.machine ?? '') + '\u0000' + lane.key, {
          elapsedEl, base: lane.scenarioElapsedSeconds, receivedAtMs: run.receivedAtMs,
        });
      }
    }
  }
  renderLaneTimes(row);
}

function updateRow(row, group) {
  row.group = group;
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
  // 機械行は状態を持たないので毎回作り直す(run 行は展開・秒読みを持つので rows で使い回す)
  for (const el of runBoardRows.querySelectorAll('.run-board-idle-machine')) {
    el.remove();
  }
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
      runBoardRows.appendChild(makeIdleMachineRow(machine, status));
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
