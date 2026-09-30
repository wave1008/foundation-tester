// performance.js
// 「直近の実行」セクション(#section-runs-table、monitorHtml.ts の renderDashboardPanel() が
// 静的スケルトンを持つ)の「すべて / パフォーマンス計測のみ」フィルターと、後者の描画。
// 「すべて」は payload.runs(直近 limit 件)を render.js の renderRunsTable で、
// 「パフォーマンス計測のみ」は `--performance` run の集計(ApiResultsPayload.performance)を描く。
// 後者を payload.runs の絞り込みで作らない —— runs は直近 limit 件で切れるので古い計測が消え、
// 計測無効の除外(Swift 側 performanceReport)も再実装になる。フィルターの状態はこのモジュールだけが書く。

import { t } from '../i18n.js';
import { clearChildren, td, tdNum } from './domUtil.js';
import { machineLabels } from './machineNames.js';
import { renderRunsTable } from './render.js';
import { requestRunDetail } from './runDetail.js';
import { selectCell } from './runsCompare.js';
import {
  formatDurationHuman,
  formatLocalDateTime,
  formatPercent,
} from './format.js';

const filterButtons = [...document.querySelectorAll('#runs-filter button[data-filter]')];
const summaryEl = document.getElementById('perf-summary');
const runsTable = document.getElementById('table-runs');
const runsBody = document.getElementById('table-runs-body');
const emptyEl = document.getElementById('perf-empty');

/** 'all' | 'performance' */
let filter = 'all';
/** 最後に描いたデータ(フィルター切り替えで描き直す)。 */
let lastData = null;

for (const button of filterButtons) {
  button.addEventListener('click', () => {
    if (filter === button.dataset.filter) return;
    filter = button.dataset.filter;
    if (lastData) render();
  });
}

function perfRunResultText(row) {
  if (typeof row.passed === 'number' && typeof row.failed === 'number') {
    return row.passed + ' / ' + row.failed;
  }
  return t('wvDashboard.render.runCountsIncomplete');
}

function maxScenarioCell(row) {
  const cell = document.createElement('td');
  cell.className = 'num';
  if (typeof row.maxScenarioMs !== 'number') {
    cell.textContent = '–';
    return cell;
  }
  cell.textContent = formatDurationHuman(row.maxScenarioMs);
  if (row.maxScenarioID) {
    cell.title = row.maxScenarioID;
  }
  return cell;
}

// 1行 = 1実行(フリート計測は複数機械ぶんが畳まれている)。machine 列は全機械を並べる
function rowMachinesText(row) {
  const hosts = row.hosts && row.hosts.length > 0 ? row.hosts : [row.host];
  return machineLabels(hosts).join(' + ');
}

// 列構成は render.js の renderRunsTable と同じ(monitorHtml.ts の #table-runs の見出しが唯一)
function renderPerfRunsTable(runs) {
  clearChildren(runsBody);
  for (const row of runs) {
    // runIDs は昇順。詳細の鍵は「すべて」の行と揃えて新しい順(先頭 = 最新の構成 run)
    const runIDs = row.runIDs && row.runIDs.length > 0 ? [...row.runIDs].reverse() : [row.runID];
    const tr = document.createElement('tr');
    tr.className = 'row-clickable';
    tr.append(
      selectCell({
        key: row.runID,
        runIDs,
        startedAt: row.startedAt,
        profile: row.profile,
        machines: rowMachinesText(row),
      }),
      td(formatLocalDateTime(row.startedAt)),
      td(rowMachinesText(row)),
      td(row.profile || '–'),
      td(perfRunResultText(row)),
      tdNum(formatDurationHuman(row.wallClockMs)),
      tdNum(formatDurationHuman(row.testTimeMs)),
      tdNum(formatDurationHuman(row.scenarioTotalMs)),
      tdNum(String(row.laneCount)),
      tdNum(formatPercent(row.avgLaneUtilisationPct)),
      maxScenarioCell(row),
      tdNum(String(row.scenarioCount)),
    );
    tr.title = runIDs.join('\n');
    tr.addEventListener('click', () => requestRunDetail(runIDs[0], runIDs));
    runsBody.appendChild(tr);
  }
}

// 計測無効 run の注記(表の上の「最新 run の1行サマリ」は置かない = 表の先頭行と二重表示。ユーザー決定)
function renderSummary(invalidCount) {
  clearChildren(summaryEl);
  if (invalidCount > 0) {
    const note = document.createElement('div');
    note.className = 'perf-summary-note';
    note.textContent = t('wvDashboard.perf.invalidCountNote', { count: String(invalidCount) });
    summaryEl.appendChild(note);
  }
}

function hidePerfExtras() {
  clearChildren(summaryEl);
  emptyEl.style.display = 'none';
}

function renderPerformanceOnly(performance) {
  renderSummary(performance.invalidCount);
  const runs = performance.runs;
  if (runs.length === 0) {
    runsTable.style.display = 'none';
    emptyEl.style.display = 'block';
    return;
  }
  emptyEl.style.display = 'none';
  runsTable.style.display = 'table';
  renderPerfRunsTable(runs);
}

function render() {
  for (const button of filterButtons) {
    button.setAttribute('aria-pressed', button.dataset.filter === filter ? 'true' : 'false');
  }
  if (filter === 'performance') {
    renderPerformanceOnly(lastData.performance);
    return;
  }
  hidePerfExtras();
  runsTable.style.display = 'table';
  renderRunsTable(lastData.groups, lastData.statsByRunID, selectCell);
}

/** groups/statsByRunID は renderRunsTable の引数、performance は payload.performance。 */
export function renderRecentRuns(groups, statsByRunID, performance) {
  lastData = { groups, statsByRunID, performance };
  render();
}
