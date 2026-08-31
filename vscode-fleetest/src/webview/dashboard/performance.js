// performance.js
// ダッシュボード最上部のパフォーマンスセクション(#section-performance、dashboardPanel.ts の
// 静的スケルトン参照)。`--performance` run の集計(ApiResultsPayload.performance)を描画する。
// キー欠落(旧 CLI)は main.js 側で undefined のまま渡ってくるので、performance が undefined なら
// セクションごと非表示にする(dashboardModel.ts の isApiResultsPayload と同じ契約)。

import { t } from '../i18n.js';
import { clearChildren, td } from './domUtil.js';
import { machineLabel } from './machineNames.js';
import { deltaBadgeCell } from './render.js';
import {
  formatDurationHuman,
  formatLocalDateTime,
  formatPercent,
} from './format.js';

const section = document.getElementById('section-performance');
const summaryEl = document.getElementById('perf-summary');
const runsTable = document.getElementById('table-perf-runs');
const runsBody = document.getElementById('table-perf-runs-body');
const comparisonHeadingEl = document.getElementById('perf-comparison-heading');
const comparisonTable = document.getElementById('table-perf-comparison');
const comparisonBody = document.getElementById('table-perf-comparison-body');
const emptyEl = document.getElementById('perf-empty');

// 比較相手が無いときに戻す既定の見出し(host 側 i18n で描画済みの文言をそのまま流用する)。
const defaultComparisonHeadingText = comparisonHeadingEl.textContent;

function perfRunResultText(row) {
  if (typeof row.passed === 'number' && typeof row.failed === 'number') {
    return row.passed + ' / ' + row.failed;
  }
  return t('wvDashboard.render.runCountsIncomplete');
}

function maxScenarioCell(row) {
  const cell = document.createElement('td');
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

function renderRunsTable(runs) {
  clearChildren(runsBody);
  for (const row of runs) {
    const tr = document.createElement('tr');
    tr.append(
      td(formatLocalDateTime(row.startedAt)),
      td(machineLabel(row.host)),
      td(row.profile || '–'),
      td(formatDurationHuman(row.wallClockMs)),
      td(formatDurationHuman(row.testTimeMs)),
      td(formatDurationHuman(row.scenarioTotalMs)),
      td(String(row.laneCount)),
      td(formatPercent(row.avgLaneUtilisationPct)),
      maxScenarioCell(row),
      td(String(row.scenarioCount)),
      td(perfRunResultText(row)),
    );
    tr.title = row.runID;
    runsBody.appendChild(tr);
  }
}

function renderSummary(latest, invalidCount) {
  clearChildren(summaryEl);
  const line = document.createElement('div');
  line.className = 'perf-summary-line';
  const parts = [
    formatLocalDateTime(latest.startedAt),
    t('wvDashboard.perf.wallClockLabel', { value: formatDurationHuman(latest.wallClockMs) }),
    t('wvDashboard.perf.testTimeLabel', { value: formatDurationHuman(latest.testTimeMs) }),
    t('wvDashboard.perf.scenarioTotalLabel', { value: formatDurationHuman(latest.scenarioTotalMs) }),
    t('wvDashboard.perf.maxScenarioLabel', {
      value: typeof latest.maxScenarioMs === 'number' ? formatDurationHuman(latest.maxScenarioMs) : '–',
    }),
    t('wvDashboard.perf.laneUtilisationLabel', { value: formatPercent(latest.avgLaneUtilisationPct) }),
  ];
  for (const part of parts) {
    const span = document.createElement('span');
    span.textContent = part;
    line.appendChild(span);
  }
  if (latest.maxScenarioID) {
    line.title = latest.maxScenarioID;
  }
  summaryEl.appendChild(line);

  if (invalidCount > 0) {
    const note = document.createElement('div');
    note.className = 'perf-summary-note';
    note.textContent = t('wvDashboard.perf.invalidCountNote', { count: String(invalidCount) });
    summaryEl.appendChild(note);
  }
}

function runLabel(runID, runs) {
  const target = runs.find((r) => r.runID === runID);
  return target ? formatLocalDateTime(target.startedAt) + '(' + machineLabel(target.host) + ')' : runID;
}

function renderComparisonHeading(comparisonRunID, comparedRunID, runs) {
  if (!comparedRunID) {
    comparisonHeadingEl.textContent = defaultComparisonHeadingText;
    return;
  }
  // 比較の最新側は runs の先頭とは限らない(フリート計測では初計測の機械が最新に来る)ので、
  // どの run とどの run の比較かを両方明示する
  if (comparisonRunID) {
    comparisonHeadingEl.textContent = t('wvDashboard.perf.comparisonHeadingPair', {
      latest: runLabel(comparisonRunID, runs),
      target: runLabel(comparedRunID, runs),
    });
    return;
  }
  comparisonHeadingEl.textContent = t('wvDashboard.perf.comparisonHeadingWith', { target: runLabel(comparedRunID, runs) });
}

function renderComparisonTable(comparison) {
  clearChildren(comparisonBody);
  for (const row of comparison) {
    const tr = document.createElement('tr');
    tr.append(
      td(row.scenarioID),
      td(row.platform),
      td(formatDurationHuman(row.previousMs)),
      td(formatDurationHuman(row.latestMs)),
      deltaBadgeCell(row.deltaPct),
    );
    comparisonBody.appendChild(tr);
  }
}

export function renderPerformance(performance) {
  if (!performance) {
    section.style.display = 'none';
    return;
  }
  section.style.display = 'block';

  const runs = performance.runs;
  if (runs.length === 0) {
    runsTable.style.display = 'none';
    comparisonTable.style.display = 'none';
    comparisonHeadingEl.style.display = 'none';
    clearChildren(summaryEl);
    if (performance.invalidCount > 0) {
      const note = document.createElement('div');
      note.className = 'perf-summary-note';
      note.textContent = t('wvDashboard.perf.invalidCountNote', { count: String(performance.invalidCount) });
      summaryEl.appendChild(note);
    }
    emptyEl.style.display = 'block';
    return;
  }

  emptyEl.style.display = 'none';
  runsTable.style.display = 'table';
  renderRunsTable(runs);
  renderSummary(runs[0], performance.invalidCount);

  if (performance.comparison.length === 0) {
    comparisonTable.style.display = 'none';
    comparisonHeadingEl.style.display = 'none';
    return;
  }
  comparisonHeadingEl.style.display = 'block';
  comparisonTable.style.display = 'table';
  renderComparisonHeading(performance.comparisonRunID, performance.comparedRunID, runs);
  renderComparisonTable(performance.comparison);
}
