// runsCompare.js
// 「直近の実行」で利用者が選んだ2件の計測の比較(#runs-compare、monitorHtml.ts の静的スケルトン)。
// 選択の状態はこのモジュールだけが書く。行の先頭セルは selectCell() が作り、render.js /
// performance.js はそれを呼ぶだけ(render.js からここを import しない = 循環を作らない)。
// 突き合わせの判定は Swift 側 RunResultsQuery.scenarioDurationDeltas(`fleetest api results-compare`)
// だけが持つ。ここでは並べ替え・絞り込みをしない(前回計測との比較と判断が食い違う)。

import { vscode } from './vscodeApi.js';
import { t } from '../i18n.js';
import { clearChildren, td, tdNum } from './domUtil.js';
import { deltaBadgeCell } from './render.js';
import { formatDurationHuman, formatLocalDateTime } from './format.js';

const blockEl = document.getElementById('runs-compare');
const headingEl = document.getElementById('runs-compare-heading');
const noteEl = document.getElementById('runs-compare-note');
const statusEl = document.getElementById('runs-compare-status');
const tableEl = document.getElementById('table-runs-compare');
const bodyEl = document.getElementById('table-runs-compare-body');

/**
 * 選択中の実行(選んだ順・最大2件)。entry = { key, runIDs, startedAt, profile, machines }。
 * key は実行の鍵(runGroup、単機 run は runID)で、「すべて」と「パフォーマンス計測のみ」の行で同じ値。
 */
let selected = [];
/** 選択を持ち越してよいプロジェクト(切り替えたら別の run を指すので捨てる)。 */
let selectedProject = null;
/** 表示中の依頼の鍵(古い応答を捨てる)。 */
let pendingKey = null;

document.getElementById('runs-compare-clear').addEventListener('click', () => {
  selected = [];
  syncCheckboxes();
  update();
});

function requestKey(previousRunIDs, latestRunIDs) {
  return previousRunIDs.join(',') + '|' + latestRunIDs.join(',');
}

function syncCheckboxes() {
  const keys = new Set(selected.map((e) => e.key));
  for (const box of document.querySelectorAll('#table-runs-body input.run-select')) {
    box.checked = keys.has(box.dataset.key);
  }
}

function label(entry) {
  return formatLocalDateTime(entry.startedAt) + '(' + (entry.profile || '–') + ' / ' + entry.machines + ')';
}

function showStatus(text, isError) {
  statusEl.textContent = text;
  statusEl.classList.toggle('status-error', isError);
  statusEl.style.display = 'block';
  tableEl.style.display = 'none';
}

function update() {
  if (selected.length < 2) {
    pendingKey = null;
    blockEl.style.display = 'none';
    return;
  }
  // 開始の古い側を「前回」にする(選んだ順ではない)
  const [previous, latest] = [...selected].sort((a, b) => (a.startedAt < b.startedAt ? -1 : a.startedAt > b.startedAt ? 1 : 0));
  headingEl.textContent = t('wvDashboard.perf.selectedHeading', { previous: label(previous), latest: label(latest) });
  const differs = previous.profile !== latest.profile || previous.machines !== latest.machines;
  noteEl.textContent = differs ? t('wvDashboard.perf.selectedConfigDiffers') : '';
  noteEl.style.display = differs ? 'block' : 'none';
  blockEl.style.display = 'block';
  showStatus(t('wvDashboard.perf.selectedLoading'), false);
  pendingKey = requestKey(previous.runIDs, latest.runIDs);
  vscode.postMessage({ type: 'compareRuns', previousRunIDs: previous.runIDs, latestRunIDs: latest.runIDs });
}

function toggle(entry, checked) {
  selected = selected.filter((e) => e.key !== entry.key);
  if (checked) {
    selected.push(entry);
    // 3件目を選んだら最も前に選んだものを外す
    if (selected.length > 2) selected = selected.slice(-2);
  }
  syncCheckboxes();
  update();
}

/** 行の先頭セル。行クリック(run 詳細)へは伝えない。 */
export function selectCell(entry) {
  const cell = td('');
  cell.className = 'select-col';
  const box = document.createElement('input');
  box.type = 'checkbox';
  box.className = 'run-select';
  box.dataset.key = entry.key;
  box.checked = selected.some((e) => e.key === entry.key);
  box.title = t('wvDashboard.perf.selectTitle');
  box.addEventListener('change', () => toggle(entry, box.checked));
  cell.addEventListener('click', (event) => event.stopPropagation());
  cell.appendChild(box);
  return cell;
}

/** データの描画ごとに呼ぶ(プロジェクトが変わったら選択を捨てる)。 */
export function syncRunsSelectionProject(project) {
  if (selectedProject === project) return;
  selectedProject = project;
  selected = [];
  update();
}

export function showRunsCompare(previousRunIDs, latestRunIDs, comparison) {
  if (requestKey(previousRunIDs, latestRunIDs) !== pendingKey) return;
  clearChildren(bodyEl);
  if (comparison.length === 0) {
    showStatus(t('wvDashboard.perf.selectedEmpty'), false);
    return;
  }
  for (const row of comparison) {
    const tr = document.createElement('tr');
    tr.append(
      td(row.scenarioID),
      td(row.platform),
      tdNum(formatDurationHuman(row.previousMs)),
      tdNum(formatDurationHuman(row.latestMs)),
      deltaBadgeCell(row.deltaPct),
    );
    bodyEl.appendChild(tr);
  }
  statusEl.style.display = 'none';
  tableEl.style.display = 'table';
}

export function showRunsCompareError(previousRunIDs, latestRunIDs, message) {
  if (requestKey(previousRunIDs, latestRunIDs) !== pendingKey) return;
  showStatus(message, true);
}
