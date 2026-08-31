// テーブル/ヘッドラインの DOM 組み立て(charts.js の日別チャートを除く表示ロジック一式)。
// innerHTML は使わず createElement/textContent で組み立てる(値にシナリオID等の外部由来文字列を
// 含むため)。run 詳細/実行履歴セクション自体の組み立ては runDetail.js/trend.js に分離してある
// (このファイルが肥大しないように。ここは runs/flaky/summary/triage 等のクリックの起点だけ持つ)。

import {
  formatDeltaPercent,
  formatDurationHuman,
  formatDurationMs,
  formatLocalDateTime,
  formatPercent,
  formatShortDateTime,
  passFailMark,
  recentResultsMarks,
} from './format.js';
import { t } from '../i18n.js';
import { clearChildren, td } from './domUtil.js';
import { machineLabel } from './machineNames.js';
import { requestRunDetail } from './runDetail.js';
import { requestTrend } from './trend.js';

const SEVERITY_ICON = { critical: '🔴', warn: '🟡', info: '🔵' };

function runCounts(run) {
  if (typeof run.total === 'number' && typeof run.passed === 'number' && typeof run.failed === 'number') {
    return run.passed + ' / ' + run.failed + ' / ' + run.total + '(passed/failed/total)';
  }
  return t('wvDashboard.render.runCountsIncomplete');
}

export function renderHeadline(latestRun) {
  const el = document.getElementById('headline-latest');
  clearChildren(el);
  if (!latestRun) {
    return;
  }
  const badge = document.createElement('span');
  const hasCounts = typeof latestRun.total === 'number' && typeof latestRun.passed === 'number' &&
    typeof latestRun.failed === 'number';
  badge.className = 'headline-badge ' + (hasCounts && latestRun.failed === 0 ? 'ok' : hasCounts ? 'bad' : 'pending');
  badge.textContent = hasCounts ? (latestRun.passed + ' passed / ' + latestRun.failed + ' failed / ' + latestRun.total + ' total') : t('wvDashboard.render.headlineIncomplete');

  const meta = document.createElement('div');
  meta.className = 'headline-meta';
  const parts = [
    formatLocalDateTime(latestRun.startedAt),
    'trigger: ' + latestRun.trigger,
    'machine: ' + machineLabel(latestRun.host),
    'profile: ' + (latestRun.profile || t('wvDashboard.render.none')),
  ];
  for (const part of parts) {
    const span = document.createElement('span');
    span.textContent = part;
    meta.appendChild(span);
  }

  el.append(badge, meta);
}

function anomalyBreakdown(anomalies) {
  const counts = new Map();
  for (const a of anomalies) {
    counts.set(a.kind, (counts.get(a.kind) || 0) + 1);
  }
  return [...counts.entries()].map(([kind, n]) => kind + '×' + n).join(', ');
}

/** 日時セル。runID は列に出さない(2026-09-01 ユーザー指示。行の title と詳細取得の鍵にだけ使う)。
 * runGroup バッジ(複数機械にまたがった run の束ね)はここに載せる。 */
function runDateCell(run, allRuns) {
  const cell = document.createElement('td');
  cell.textContent = formatLocalDateTime(run.startedAt);
  if (run.runGroup) {
    const badge = document.createElement('span');
    badge.className = 'run-group-badge';
    badge.textContent = run.runGroup.slice(0, 6);
    const siblings = allRuns
      .filter((r) => r.runGroup === run.runGroup && r.runID !== run.runID)
      .map((r) => r.runID);
    badge.title = t('wvDashboard.render.runGroupTitle', { runIDs: siblings.length > 0 ? siblings.join(', ') : '–' });
    cell.appendChild(badge);
  }
  return cell;
}

function runResultCell(run) {
  const cell = td(runCounts(run));
  if (run.workerAnomalies && run.workerAnomalies.length > 0) {
    const warn = document.createElement('span');
    warn.className = 'anomaly-warn';
    warn.textContent = ' ⚠';
    warn.title = t('wvDashboard.render.anomalyHint', { breakdown: anomalyBreakdown(run.workerAnomalies) });
    cell.appendChild(warn);
  }
  return cell;
}

export function renderRunsTable(runs) {
  const body = document.getElementById('table-runs-body');
  clearChildren(body);
  // 最大10行(呼び出し側で既に runID 降順)。
  for (const run of runs.slice(0, 10)) {
    const row = document.createElement('tr');
    row.className = 'row-clickable';
    row.title = run.runID;
    row.append(
      runDateCell(run, runs),
      td(run.trigger),
      td(machineLabel(run.host)),
      td(run.profile || '–'),
      runResultCell(run),
    );
    row.addEventListener('click', () => requestRunDetail(run.runID));
    body.appendChild(row);
  }
}

function scenarioIdCell(scenarioID) {
  const cell = document.createElement('td');
  cell.textContent = scenarioID;
  cell.className = 'scenario-id-clickable';
  cell.addEventListener('click', () => requestTrend(scenarioID));
  return cell;
}

export function renderFlakyTable(flaky) {
  const body = document.getElementById('table-flaky-body');
  const emptyEl = document.getElementById('flaky-empty');
  clearChildren(body);
  emptyEl.style.display = flaky.length === 0 ? 'block' : 'none';
  document.getElementById('table-flaky').style.display = flaky.length === 0 ? 'none' : 'table';
  for (const row of flaky) {
    const tr = document.createElement('tr');
    tr.append(
      scenarioIdCell(row.scenarioID),
      td(String(row.runs)),
      td(formatPercent(row.failureRate)),
      td(row.flakinessScore.toFixed(2)),
      td(recentResultsMarks(row.recentResults)),
    );
    body.appendChild(tr);
  }
}

export function renderSummaryTable(summary) {
  const body = document.getElementById('table-summary-body');
  clearChildren(body);
  for (const row of summary) {
    const tr = document.createElement('tr');
    tr.append(
      scenarioIdCell(row.scenarioID),
      td(String(row.runs)),
      td(formatPercent(row.successRate)),
      td(formatDurationMs(row.avgDurationMs)),
      td(formatLocalDateTime(row.lastRunAt)),
      td(typeof row.lastPassed === 'boolean' ? passFailMark(row.lastPassed) : '–'),
    );
    body.appendChild(tr);
  }
}

export function renderDevicesTable(byWorker) {
  const body = document.getElementById('table-devices-body');
  clearChildren(body);
  for (const row of byWorker) {
    const tr = document.createElement('tr');
    tr.append(
      td(row.worker),
      td(String(row.runs)),
      td(formatPercent(row.successRate)),
      td(formatDurationMs(row.avgDurationMs)),
    );
    body.appendChild(tr);
  }
}

export function renderInsights(insights) {
  const list = document.getElementById('insights-list');
  const emptyEl = document.getElementById('insights-empty');
  const heading = document.getElementById('insights-heading');
  clearChildren(list);
  const hasCritical = insights.some((insight) => insight.severity === 'critical');
  heading.classList.toggle('insights-heading-critical', hasCritical);
  if (insights.length === 0) {
    list.style.display = 'none';
    emptyEl.style.display = 'block';
    return;
  }
  list.style.display = 'flex';
  emptyEl.style.display = 'none';
  for (const insight of insights) {
    const li = document.createElement('li');
    li.className = 'insight-item';
    const icon = document.createElement('span');
    icon.className = 'insight-icon';
    icon.textContent = SEVERITY_ICON[insight.severity] || SEVERITY_ICON.info;
    const message = document.createElement('span');
    message.textContent = insight.message;
    li.append(icon, message);
    list.appendChild(li);
  }
}

export function deltaBadgeCell(deltaPct) {
  const cell = document.createElement('td');
  if (typeof deltaPct !== 'number') {
    cell.textContent = '–';
    return cell;
  }
  const badge = document.createElement('span');
  badge.className = 'delta-badge ' + (deltaPct > 0 ? 'delta-up' : deltaPct < 0 ? 'delta-down' : 'delta-flat');
  badge.textContent = formatDeltaPercent(deltaPct);
  cell.appendChild(badge);
  return cell;
}

function slowestSceneText(slowestScene, slowestSceneAvgMs) {
  if (!slowestScene) return '–';
  return typeof slowestSceneAvgMs === 'number'
    ? slowestScene + '(' + formatDurationHuman(slowestSceneAvgMs) + ')'
    : slowestScene;
}

function matrixScenarioNameCell(scenario) {
  const cell = document.createElement('td');
  cell.textContent = scenario.title || scenario.scenarioID;
  if (scenario.title && scenario.title !== scenario.scenarioID) {
    cell.title = scenario.scenarioID;
  }
  return cell;
}

function matrixSuccessRateCell(cells) {
  const nonNull = cells.filter((c) => c !== null);
  const passCount = nonNull.filter((c) => c === 1).length;
  const rate = nonNull.length > 0 ? (passCount / nonNull.length) * 100 : null;
  return td(formatPercent(rate));
}

function matrixDotCell(cell) {
  const wrap = document.createElement('td');
  const dot = document.createElement('span');
  dot.className = 'matrix-dot ' + (cell === 1 ? 'matrix-dot-pass' : cell === 0 ? 'matrix-dot-fail' : 'matrix-dot-empty');
  wrap.appendChild(dot);
  return wrap;
}

export function renderMatrixTable(matrix) {
  const headRow = document.getElementById('table-matrix-head');
  const body = document.getElementById('table-matrix-body');

  // 先頭2列(シナリオ名・成功率)は dashboardPanel.ts の静的 HTML(i18n 済み見出し)。
  // run 列は本数が可変なのでここで都度再構築する(未翻訳の技術的な日時見出しのみ)。
  while (headRow.children.length > 2) {
    headRow.removeChild(headRow.lastChild);
  }
  for (const run of matrix.runs) {
    const th = document.createElement('th');
    th.textContent = formatShortDateTime(run.startedAt);
    th.title = run.runID + (run.profile ? ' / ' + run.profile : '');
    headRow.appendChild(th);
  }

  clearChildren(body);
  for (const scenario of matrix.scenarios) {
    const tr = document.createElement('tr');
    tr.append(matrixScenarioNameCell(scenario), matrixSuccessRateCell(scenario.cells));
    for (const cell of scenario.cells) {
      tr.appendChild(matrixDotCell(cell));
    }
    body.appendChild(tr);
  }
}

export function renderSlowTable(slow) {
  const body = document.getElementById('table-slow-body');
  const emptyEl = document.getElementById('slow-empty');
  clearChildren(body);
  const hasRows = slow.length > 0;
  document.getElementById('table-slow').style.display = hasRows ? 'table' : 'none';
  emptyEl.style.display = hasRows ? 'none' : 'block';
  for (const row of slow) {
    const tr = document.createElement('tr');
    tr.append(
      td(row.scenarioID),
      td(String(row.runs)),
      td(formatDurationHuman(row.avgDurationMs)),
      td(formatDurationHuman(row.p90DurationMs)),
      deltaBadgeCell(row.deltaPct),
      td(slowestSceneText(row.slowestScene, row.slowestSceneAvgMs)),
    );
    body.appendChild(tr);
  }
}

export function renderTriageTable(triage) {
  const section = document.getElementById('section-triage');
  if (!triage) {
    section.style.display = 'none';
    return;
  }
  section.style.display = 'block';

  const summaryEl = document.getElementById('triage-summary');
  clearChildren(summaryEl);
  const summarySpan = document.createElement('span');
  summarySpan.textContent = t('wvDashboard.render.triageSummary', {
    totalFailed: String(triage.totalFailed),
    unreachedCount: String(triage.unreachedCount),
  });
  summaryEl.appendChild(summarySpan);

  const body = document.getElementById('table-triage-body');
  const table = document.getElementById('table-triage');
  const notesBody = document.getElementById('table-triage-notes-body');
  const notesTable = document.getElementById('table-triage-notes');
  const emptyEl = document.getElementById('triage-empty');
  clearChildren(body);
  clearChildren(notesBody);

  const hasRows = triage.rows.length > 0;
  table.style.display = hasRows ? 'table' : 'none';
  emptyEl.style.display = hasRows ? 'none' : 'block';
  for (const row of triage.rows) {
    const tr = document.createElement('tr');
    tr.append(
      td(row.section || '–'),
      td(row.command || '–'),
      td(row.failureKind || '–'),
      td(String(row.count)),
      td(row.scenarioIDs.join(', ')),
    );
    body.appendChild(tr);
  }

  notesTable.style.display = triage.noteCounts.length === 0 ? 'none' : 'table';
  for (const row of triage.noteCounts) {
    const tr = document.createElement('tr');
    tr.append(td(row.note), td(String(row.count)));
    notesBody.appendChild(tr);
  }
}
