// runDetail.js
// run 詳細セクション(#section-run-detail、dashboardPanel.ts の静的スケルトン参照)の表示ロジック。
// runs テーブルの行クリック(render.js)から requestRunDetail(runID) で開始し、host からの
// {type:'runDetail'|'runDetailError'} 受信時に main.js が showRunDetailData/showRunDetailError を呼ぶ。
// メッセージ型は src/dashboardModel.ts の DashboardFromWebviewMessage/DashboardToWebviewMessage と同期。

import { vscode } from './vscodeApi.js';
import { t } from '../i18n.js';
import { clearChildren, td } from './domUtil.js';
import { machineLabel } from './machineNames.js';
import { requestTrend } from './trend.js';
import {
  formatDurationHuman,
  formatLocalDateTime,
  passFailMark,
} from './format.js';

const section = document.getElementById('section-run-detail');
const titleEl = document.getElementById('run-detail-title');
const bodyEl = document.getElementById('run-detail-body');
const closeBtn = document.getElementById('run-detail-close');

closeBtn.addEventListener('click', () => {
  section.style.display = 'none';
});

function titleFor(runID) {
  return t('wvDashboard.runDetail.title', { runID });
}

/** runIDs = 同じ実行の構成 run 全部(先頭 = runID)。単機は省略可。 */
export function requestRunDetail(runID, runIDs) {
  section.style.display = 'block';
  titleEl.textContent = titleFor(runID);
  clearChildren(bodyEl);
  const loading = document.createElement('div');
  loading.className = 'status-message';
  loading.textContent = t('wvDashboard.runDetail.loading');
  bodyEl.appendChild(loading);
  vscode.postMessage({ type: 'runDetail', runID, runIDs: runIDs && runIDs.length > 0 ? runIDs : [runID] });
}

export function showRunDetailError(runID, message) {
  if (titleEl.textContent !== titleFor(runID)) {
    return; // 別 run のリクエスト後に古いエラーが届いた場合は無視する
  }
  clearChildren(bodyEl);
  const err = document.createElement('div');
  err.className = 'status-message status-error';
  err.textContent = message;
  bodyEl.appendChild(err);
}

function metaRow(label, value) {
  const row = document.createElement('div');
  row.className = 'detail-meta-row';
  const labelSpan = document.createElement('span');
  labelSpan.className = 'detail-meta-label';
  labelSpan.textContent = label;
  const valueSpan = document.createElement('span');
  valueSpan.textContent = value;
  row.append(labelSpan, valueSpan);
  return row;
}

function countsText(run) {
  if (typeof run.total === 'number' && typeof run.passed === 'number' && typeof run.failed === 'number') {
    return t('wvDashboard.runDetail.labelCounts', {
      passed: String(run.passed),
      failed: String(run.failed),
      total: String(run.total),
    });
  }
  return t('wvDashboard.render.runCountsIncomplete');
}

function renderMeta(run) {
  const wrap = document.createElement('div');
  wrap.className = 'detail-meta';
  wrap.append(
    metaRow(t('wvDashboard.runDetail.labelStarted'), formatLocalDateTime(run.startedAt)),
    metaRow(t('wvDashboard.runDetail.labelFinished'), run.finishedAt ? formatLocalDateTime(run.finishedAt) : t('wvDashboard.runDetail.none')),
    metaRow(t('wvDashboard.runDetail.labelHost'), machineLabel(run.host)),
    metaRow(t('wvDashboard.runDetail.labelProfile'), run.profile || t('wvDashboard.runDetail.none')),
    metaRow(t('wvDashboard.runDetail.labelTrigger'), run.trigger),
    metaRow(t('wvDashboard.runDetail.colResult'), countsText(run)),
  );
  if (run.measurementInvalid === true) {
    const warn = document.createElement('div');
    warn.className = 'status-message status-error detail-measurement-warning';
    const reasons = run.measurementInvalidReasons && run.measurementInvalidReasons.length > 0
      ? run.measurementInvalidReasons.join(', ')
      : t('wvDashboard.runDetail.none');
    warn.textContent = t('wvDashboard.runDetail.measurementInvalid', { reasons });
    wrap.appendChild(warn);
  }
  return wrap;
}

function stringListSection(heading, items) {
  if (!items || items.length === 0) {
    return null;
  }
  const wrap = document.createElement('div');
  wrap.className = 'detail-subsection';
  const h = document.createElement('h3');
  h.textContent = heading;
  const ul = document.createElement('ul');
  for (const item of items) {
    const li = document.createElement('li');
    li.textContent = item;
    ul.appendChild(li);
  }
  wrap.append(h, ul);
  return wrap;
}

function workerAnomaliesTable(anomalies) {
  const wrap = document.createElement('div');
  wrap.className = 'detail-subsection';
  const h = document.createElement('h3');
  h.textContent = t('wvDashboard.runDetail.headingWorkerAnomalies');
  const table = document.createElement('table');
  table.className = 'dash-table';
  const thead = document.createElement('thead');
  const headRow = document.createElement('tr');
  headRow.append(
    (() => { const th = document.createElement('th'); th.textContent = t('wvDashboard.runDetail.colKind'); return th; })(),
    (() => { const th = document.createElement('th'); th.textContent = t('wvDashboard.runDetail.colWorker'); return th; })(),
    (() => { const th = document.createElement('th'); th.textContent = t('wvDashboard.runDetail.colScenarioId'); return th; })(),
    (() => { const th = document.createElement('th'); th.textContent = t('wvDashboard.runDetail.colReason'); return th; })(),
  );
  thead.appendChild(headRow);
  const tbody = document.createElement('tbody');
  for (const a of anomalies) {
    const tr = document.createElement('tr');
    tr.append(td(a.kind), td(a.worker || '–'), td(a.scenarioID || '–'), td(a.reason));
    tbody.appendChild(tr);
  }
  table.append(thead, tbody);
  wrap.append(h, table);
  return wrap;
}

function renderAnomalies(run) {
  const frag = document.createDocumentFragment();
  if (run.workerAnomalies && run.workerAnomalies.length > 0) {
    frag.appendChild(workerAnomaliesTable(run.workerAnomalies));
  } else {
    const degraded = stringListSection(t('wvDashboard.runDetail.headingDegradedWorkers'), run.degradedWorkers);
    if (degraded) frag.appendChild(degraded);
    const freeze = stringListSection(t('wvDashboard.runDetail.headingFreezeRetries'), run.freezeRetries);
    if (freeze) frag.appendChild(freeze);
  }
  const repairs = stringListSection(t('wvDashboard.runDetail.headingBlankRepairs'), run.blankRepairs);
  if (repairs) frag.appendChild(repairs);
  const exclusions = stringListSection(t('wvDashboard.runDetail.headingBlankExclusions'), run.blankExclusions);
  if (exclusions) frag.appendChild(exclusions);
  return frag;
}

function failedStepRow(step) {
  const tr = document.createElement('tr');
  const fileLine = step.file ? step.file + (typeof step.line === 'number' ? ':' + step.line : '') : '–';
  tr.append(
    td(String(step.index)),
    td(step.description),
    td(step.section || '–'),
    td(step.command || '–'),
    td(step.failureKind || '–'),
    td(step.notes && step.notes.length > 0 ? step.notes.join(', ') : '–'),
    td(step.detail || '–'),
    td(fileLine),
  );
  return tr;
}

function failedStepsTableHeadings() {
  // t() のキーはこの走査で静的に検出される(test/i18n.test.mjs)ので、動的な文字列結合にしない。
  return [
    t('wvDashboard.runDetail.colStep'),
    t('wvDashboard.runDetail.colDescription'),
    t('wvDashboard.runDetail.colSection'),
    t('wvDashboard.runDetail.colCommand'),
    t('wvDashboard.runDetail.colFailureKind'),
    t('wvDashboard.runDetail.colNotes'),
    t('wvDashboard.runDetail.colDetail'),
    t('wvDashboard.runDetail.colFileLine'),
  ];
}

function failedStepsTable(steps) {
  const table = document.createElement('table');
  table.className = 'dash-table';
  const thead = document.createElement('thead');
  const headRow = document.createElement('tr');
  for (const heading of failedStepsTableHeadings()) {
    const th = document.createElement('th');
    th.textContent = heading;
    headRow.appendChild(th);
  }
  thead.appendChild(headRow);
  const tbody = document.createElement('tbody');
  for (const step of steps) {
    tbody.appendChild(failedStepRow(step));
  }
  table.append(thead, tbody);
  return table;
}

function errorLogsBlock(errorLogs) {
  const wrap = document.createElement('div');
  wrap.className = 'detail-subsection';
  const h = document.createElement('h3');
  h.textContent = t('wvDashboard.runDetail.headingErrorLogs');
  const pre = document.createElement('pre');
  pre.className = 'error-log';
  pre.textContent = errorLogs.join('\n');
  wrap.append(h, pre);
  return wrap;
}

function scenarioDetailRow(scenario, colSpan) {
  const tr = document.createElement('tr');
  tr.className = 'step-detail-row';
  const cell = document.createElement('td');
  cell.colSpan = colSpan;
  const wrap = document.createElement('div');
  wrap.className = 'scenario-detail';

  if (scenario.failedSteps && scenario.failedSteps.length > 0) {
    wrap.appendChild(failedStepsTable(scenario.failedSteps));
  }
  if (scenario.errorLogs && scenario.errorLogs.length > 0) {
    wrap.appendChild(errorLogsBlock(scenario.errorLogs));
  }

  const actions = document.createElement('div');
  actions.className = 'detail-actions';
  if (scenario.reportPath) {
    const openBtn = document.createElement('button');
    openBtn.type = 'button';
    openBtn.textContent = t('wvDashboard.runDetail.buttonOpenReport');
    openBtn.addEventListener('click', () => {
      vscode.postMessage({ type: 'openReport', path: scenario.reportPath });
    });
    actions.appendChild(openBtn);
  }
  const trendBtn = document.createElement('button');
  trendBtn.type = 'button';
  trendBtn.textContent = t('wvDashboard.runDetail.buttonTrend');
  trendBtn.addEventListener('click', () => {
    requestTrend(scenario.scenarioID);
  });
  actions.appendChild(trendBtn);
  wrap.appendChild(actions);

  cell.appendChild(wrap);
  tr.appendChild(cell);
  return tr;
}

function scenarioRow(scenario, colSpan) {
  const tr = document.createElement('tr');
  tr.append(
    td(passFailMark(scenario.passed)),
    td(scenario.scenarioID),
    td(scenario.worker || '–'),
    td(formatDurationHuman(scenario.durationMs)),
    td(scenario.skipKind || '–'),
  );
  const idCell = tr.children[1];
  if (scenario.title && scenario.title !== scenario.scenarioID) {
    idCell.title = scenario.title;
  }

  if (scenario.passed) {
    return [tr];
  }
  tr.className = 'scenario-row-clickable';
  let expanded = false;
  const detailRow = scenarioDetailRow(scenario, colSpan);
  detailRow.style.display = 'none';
  tr.addEventListener('click', () => {
    expanded = !expanded;
    detailRow.style.display = expanded ? 'table-row' : 'none';
  });
  return [tr, detailRow];
}

const SCENARIOS_TABLE_COL_COUNT = 5;

function scenariosTableHeadings() {
  // t() のキーはこの走査で静的に検出される(test/i18n.test.mjs)ので、動的な文字列結合にしない。
  return [
    t('wvDashboard.runDetail.colResult'),
    t('wvDashboard.runDetail.colScenarioId'),
    t('wvDashboard.runDetail.colWorker'),
    t('wvDashboard.runDetail.colDuration'),
    t('wvDashboard.runDetail.colSkipKind'),
  ];
}

function scenariosTable(scenarios) {
  const wrap = document.createElement('div');
  wrap.className = 'detail-subsection';
  const h = document.createElement('h3');
  h.textContent = t('wvDashboard.runDetail.headingScenarios');
  const table = document.createElement('table');
  table.className = 'dash-table';
  const thead = document.createElement('thead');
  const headRow = document.createElement('tr');
  for (const heading of scenariosTableHeadings()) {
    const th = document.createElement('th');
    th.textContent = heading;
    headRow.appendChild(th);
  }
  thead.appendChild(headRow);
  const tbody = document.createElement('tbody');
  for (const scenario of scenarios) {
    for (const row of scenarioRow(scenario, SCENARIOS_TABLE_COL_COUNT)) {
      tbody.appendChild(row);
    }
  }
  table.append(thead, tbody);
  wrap.append(h, table);
  return wrap;
}

/** payloads = 構成 run ごとの results-run 応答(先頭 = リクエストした primary)。
 * フリート実行は機械ごとの見出しを立てて縦に並べる。 */
export function showRunDetailData(payloads) {
  if (payloads.length === 0) {
    return;
  }
  if (titleEl.textContent !== titleFor(payloads[0].run.runID)) {
    return; // 別 run のリクエスト後に古い応答が届いた場合は無視する
  }
  clearChildren(bodyEl);
  for (const payload of payloads) {
    if (payloads.length > 1) {
      const heading = document.createElement('h3');
      heading.className = 'detail-machine-heading';
      heading.textContent = machineLabel(payload.run.host);
      bodyEl.appendChild(heading);
    }
    bodyEl.appendChild(renderMeta(payload.run));
    bodyEl.appendChild(renderAnomalies(payload.run));
    bodyEl.appendChild(scenariosTable(payload.scenarios));
  }
}
