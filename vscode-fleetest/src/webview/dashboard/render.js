// テーブル/ヘッドラインの DOM 組み立て(charts.js の日別チャートを除く表示ロジック一式)。
// innerHTML は使わず createElement/textContent で組み立てる(値にシナリオID等の外部由来文字列を
// 含むため)。run 詳細/実行履歴セクション自体の組み立ては runDetail.js/trend.js に分離してある
// (このファイルが肥大しないように。ここは runs/flaky/summary 等のクリックの起点だけ持つ)。

import {
  formatDeltaPercent,
  formatDurationHuman,
  formatDurationSeconds,
  formatLocalDateTime,
  formatPercent,
  formatPercentInteger,
  passFailMark,
  recentResultsMarks,
} from './format.js';
import { t } from '../i18n.js';
import { clearChildren, td, tdMid, tdNum } from './domUtil.js';
import { machineLabels } from './machineNames.js';
import { requestRunDetail } from './runDetail.js';
import { requestTrend } from './trend.js';

const SEVERITY_ICON = { critical: '🔴', warn: '🟡', info: '🔵' };

/** latestGroup = groupRuns(runs)[0](最新の実行の構成 run 配列)。 */
export function renderHeadline(latestGroup) {
  const el = document.getElementById('headline-latest');
  clearChildren(el);
  if (!latestGroup || latestGroup.length === 0) {
    return;
  }
  const counts = groupCounts(latestGroup);
  const badge = document.createElement('span');
  badge.className = 'headline-badge ' + (counts && counts.failed === 0 ? 'ok' : counts ? 'bad' : 'pending');
  badge.textContent = counts
    ? (counts.passed + ' passed / ' + counts.failed + ' failed')
    : t('wvDashboard.render.headlineIncomplete');

  const meta = document.createElement('div');
  meta.className = 'headline-meta';
  const parts = [
    formatLocalDateTime(groupStartedAt(latestGroup)),
    'machine: ' + groupMachinesText(latestGroup),
    'profile: ' + (latestGroup[0].profile || t('wvDashboard.render.none')),
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

/** runs(runID 降順)を実行(runGroup。無ければ runID)単位に畳む。パフォーマンス一覧と同じ規則。
 * グループの表示位置は最も新しい構成 run の並び位置(= 最初に現れた位置)。 */
export function groupRuns(runs) {
  const groups = new Map();
  for (const run of runs) {
    const key = run.runGroup || run.runID;
    if (!groups.has(key)) {
      groups.set(key, []);
    }
    groups.get(key).push(run);
  }
  return [...groups.values()];
}

/** グループの合算 total/passed/failed(どれか1つでも未完了なら null = まだ言えない)。 */
function groupCounts(members) {
  let total = 0;
  let passed = 0;
  let failed = 0;
  for (const run of members) {
    if (typeof run.total !== 'number' || typeof run.passed !== 'number' || typeof run.failed !== 'number') {
      return null;
    }
    total += run.total;
    passed += run.passed;
    failed += run.failed;
  }
  return { total, passed, failed };
}

function groupStartedAt(members) {
  return members.reduce((min, run) => (run.startedAt < min ? run.startedAt : min), members[0].startedAt);
}

function groupMachinesText(members) {
  return machineLabels([...new Set(members.map((r) => r.host))]).join(' + ');
}

/** 日時セル。runID もバッジも列に出さない(2026-09-01 ユーザー指示。runID は行の title と
 * 詳細取得の鍵にだけ使い、何台構成かは machine 列が示す)。 */
function groupDateCell(members) {
  return td(formatLocalDateTime(groupStartedAt(members)));
}

/** グループの時間統計(壁時計・テスト時間・所要合計・レーン・稼働率)。統計の合成規則は
 * パフォーマンスセクション(Swift 側 performanceReport)と同じ:
 * 壁時計 = 最初の開始〜最後の完了 / テスト時間 = 最初のシナリオ開始〜最後の完了 /
 * 稼働率 = 所要合計 ÷ Σ(構成 run ごとのレーン数×テスト時間窓)。
 * どれか1つでも統計が欠けたグループは null(表示は「–」)。 */
function groupStats(members, statsByRunID) {
  const stats = members.map((r) => statsByRunID.get(r.runID));
  if (stats.some((s) => !s)) {
    return {
      wallClockMs: null, testTimeMs: null, scenarioTotalMs: null, scenarioCount: null,
      laneCount: null, utilPct: null, maxScenarioMs: null, maxScenarioID: null,
    };
  }
  let minStart = null;
  let maxFinish = null;
  let wallOk = true;
  for (let i = 0; i < members.length; i += 1) {
    const start = new Date(members[i].startedAt).getTime();
    if (!isFinite(start) || typeof stats[i].wallClockMs !== 'number') {
      wallOk = false;
      break;
    }
    minStart = minStart === null ? start : Math.min(minStart, start);
    maxFinish = maxFinish === null ? start + stats[i].wallClockMs : Math.max(maxFinish, start + stats[i].wallClockMs);
  }
  let testStart = null;
  let testFinish = null;
  for (const s of stats) {
    if (typeof s.testStartedAt !== 'string' || typeof s.testFinishedAt !== 'string') continue;
    const start = new Date(s.testStartedAt).getTime();
    const finish = new Date(s.testFinishedAt).getTime();
    if (!isFinite(start) || !isFinite(finish)) continue;
    testStart = testStart === null ? start : Math.min(testStart, start);
    testFinish = testFinish === null ? finish : Math.max(testFinish, finish);
  }
  const scenarioTotalMs = stats.reduce((sum, s) => sum + s.scenarioTotalMs, 0);
  const laneCount = stats.reduce((sum, s) => sum + s.laneCount, 0);
  const capacityMs = stats.reduce(
    (sum, s) => (typeof s.testTimeMs === 'number' && s.laneCount > 0 ? sum + s.laneCount * s.testTimeMs : sum),
    0,
  );
  // 最長1本(同値は scenarioID 昇順 = Swift 側 perfMaxScenario と同じ規律)
  let maxScenarioMs = null;
  let maxScenarioID = null;
  for (const s of stats) {
    if (typeof s.maxScenarioMs !== 'number') continue;
    if (maxScenarioMs === null || s.maxScenarioMs > maxScenarioMs ||
        (s.maxScenarioMs === maxScenarioMs && typeof s.maxScenarioID === 'string' && s.maxScenarioID < maxScenarioID)) {
      maxScenarioMs = s.maxScenarioMs;
      maxScenarioID = s.maxScenarioID || null;
    }
  }
  return {
    wallClockMs: wallOk && minStart !== null ? maxFinish - minStart : null,
    testTimeMs: testStart !== null && testFinish !== null ? testFinish - testStart : null,
    scenarioTotalMs,
    scenarioCount: stats.reduce((sum, s) => sum + s.scenarioCount, 0),
    laneCount: laneCount > 0 ? laneCount : null,
    utilPct: capacityMs > 0 ? (scenarioTotalMs / capacityMs) * 100 : null,
    maxScenarioMs,
    maxScenarioID,
  };
}

function groupResultCell(members) {
  const counts = groupCounts(members);
  // パフォーマンス表の結果列と同じ形(passed / failed)。総数は「本数」列が持つ
  const cell = td(counts
    ? counts.passed + ' / ' + counts.failed
    : t('wvDashboard.render.runCountsIncomplete'));
  const anomalies = members.flatMap((r) => r.workerAnomalies || []);
  if (anomalies.length > 0) {
    const warn = document.createElement('span');
    warn.className = 'anomaly-warn';
    warn.textContent = ' ⚠';
    warn.title = t('wvDashboard.render.anomalyHint', { breakdown: anomalyBreakdown(anomalies) });
    cell.appendChild(warn);
  }
  return cell;
}

/** groups = groupRuns(runs) の結果(1要素 = 1実行の構成 run 配列)。statsByRunID は
 * payload.runStats の Map(旧 CLI では空 = 時間統計の列は「–」)。 */
export function renderRunsTable(groups, statsByRunID) {
  const body = document.getElementById('table-runs-body');
  clearChildren(body);
  // 最大10行(呼び出し側で既に新しい順)。
  for (const members of groups.slice(0, 10)) {
    const stats = groupStats(members, statsByRunID);
    const maxCell = tdNum(formatDurationHuman(stats.maxScenarioMs));
    if (stats.maxScenarioID) {
      maxCell.title = stats.maxScenarioID;
    }
    const row = document.createElement('tr');
    row.className = 'row-clickable';
    row.title = members.map((r) => r.runID).join('\n');
    // 列構成はパフォーマンス表と同じ(2026-09-01 ユーザー指示)
    row.append(
      groupDateCell(members),
      td(groupMachinesText(members)),
      td(members[0].profile || '–'),
      tdNum(formatDurationHuman(stats.wallClockMs)),
      tdNum(formatDurationHuman(stats.testTimeMs)),
      tdNum(formatDurationHuman(stats.scenarioTotalMs)),
      tdNum(stats.laneCount === null ? '–' : String(stats.laneCount)),
      tdNum(formatPercent(stats.utilPct === null ? undefined : stats.utilPct)),
      maxCell,
      tdNum(stats.scenarioCount === null ? '–' : String(stats.scenarioCount)),
      groupResultCell(members),
    );
    row.addEventListener('click', () => requestRunDetail(members[0].runID, members.map((r) => r.runID)));
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
    // 列の順序は monitorHtml.ts renderDashboardPanel() の #table-summary の見出しと1:1
    // (位置で対応するので片方だけ並べ替えると値が別の見出しの下に出る)
    tr.append(
      scenarioIdCell(row.scenarioID),
      tdMid(typeof row.lastPassed === 'boolean' ? passFailMark(row.lastPassed) : '–'),
      td(formatLocalDateTime(row.lastRunAt)),
      tdNum(String(row.runs)),
      tdNum(formatPercentInteger(row.successRate)),
      tdNum(formatDurationSeconds(row.avgDurationMs)),
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
  cell.className = 'num';
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
      td(row.platform || '–'),
      tdNum(String(row.runs)),
      tdNum(formatDurationHuman(row.avgDurationMs)),
      tdNum(formatDurationHuman(row.p90DurationMs)),
      deltaBadgeCell(row.deltaPct),
      td(slowestSceneText(row.slowestScene, row.slowestSceneAvgMs)),
    );
    body.appendChild(tr);
  }
}

