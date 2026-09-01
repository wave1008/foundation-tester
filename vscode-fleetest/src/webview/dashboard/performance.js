// performance.js
// ダッシュボード最上部のパフォーマンスセクション(#section-performance、monitorHtml.ts の
// renderDashboardPanel() が静的スケルトンを持つ)。`--performance` run の集計
// (ApiResultsPayload.performance)を描画する。
// キー欠落(旧 CLI)は main.js 側で undefined のまま渡ってくるので、performance が undefined なら
// セクションごと非表示にする(dashboardModel.ts の isApiResultsPayload と同じ契約)。

import { t } from '../i18n.js';
import { clearChildren, td, tdNum } from './domUtil.js';
import { machineLabels } from './machineNames.js';
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

function renderRunsTable(runs) {
  clearChildren(runsBody);
  for (const row of runs) {
    const tr = document.createElement('tr');
    tr.append(
      td(formatLocalDateTime(row.startedAt)),
      td(rowMachinesText(row)),
      td(row.profile || '–'),
      tdNum(formatDurationHuman(row.wallClockMs)),
      tdNum(formatDurationHuman(row.testTimeMs)),
      tdNum(formatDurationHuman(row.scenarioTotalMs)),
      tdNum(String(row.laneCount)),
      tdNum(formatPercent(row.avgLaneUtilisationPct)),
      maxScenarioCell(row),
      tdNum(String(row.scenarioCount)),
      td(perfRunResultText(row)),
    );
    tr.title = row.runIDs && row.runIDs.length > 0 ? row.runIDs.join('\n') : row.runID;
    runsBody.appendChild(tr);
  }
}

// 表の上の「最新 run の1行サマリ」は置かない(表の先頭行が最新 = 同じ値の二重表示。ユーザー決定)。
// 残すのは計測無効 run の注記だけ
function renderSummary(invalidCount) {
  clearChildren(summaryEl);
  if (invalidCount > 0) {
    const note = document.createElement('div');
    note.className = 'perf-summary-note';
    note.textContent = t('wvDashboard.perf.invalidCountNote', { count: String(invalidCount) });
    summaryEl.appendChild(note);
  }
}

function runLabel(runID, runs) {
  const target = runs.find((r) => r.runID === runID);
  return target ? formatLocalDateTime(target.startedAt) + '(' + rowMachinesText(target) + ')' : runID;
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
      tdNum(formatDurationHuman(row.previousMs)),
      tdNum(formatDurationHuman(row.latestMs)),
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
  renderSummary(performance.invalidCount);

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
