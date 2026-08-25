// テーブル/ヘッドラインの DOM 組み立て(charts.js の日別チャートを除く表示ロジック一式)。
// innerHTML は使わず createElement/textContent で組み立てる(値にシナリオID等の外部由来文字列を
// 含むため)。

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

const SEVERITY_ICON = { critical: '🔴', warn: '🟡', info: '🔵' };

function clearChildren(el) {
  while (el.firstChild) {
    el.removeChild(el.firstChild);
  }
}

function td(text) {
  const cell = document.createElement('td');
  cell.textContent = text;
  return cell;
}

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
    'host: ' + latestRun.host,
    'profile: ' + (latestRun.profile || t('wvDashboard.render.none')),
  ];
  for (const part of parts) {
    const span = document.createElement('span');
    span.textContent = part;
    meta.appendChild(span);
  }

  el.append(badge, meta);
}

export function renderRunsTable(runs) {
  const body = document.getElementById('table-runs-body');
  clearChildren(body);
  // 最大10行(呼び出し側で既に runID 降順)。
  for (const run of runs.slice(0, 10)) {
    const row = document.createElement('tr');
    row.append(
      td(run.runID),
      td(formatLocalDateTime(run.startedAt)),
      td(run.trigger),
      td(run.host),
      td(run.profile || '–'),
      td(runCounts(run)),
    );
    body.appendChild(row);
  }
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
      td(row.scenarioID),
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
      td(row.scenarioID),
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

function deltaBadgeCell(deltaPct) {
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
