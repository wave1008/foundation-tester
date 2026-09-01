// trend.js
// シナリオ履歴セクション(#section-trend、monitorHtml.ts の renderDashboardPanel() が静的
// スケルトンを持つ)の表示ロジック。
// flaky/summary テーブルの scenarioID セルクリック(render.js)・run 詳細の「実行履歴」ボタン
// (runDetail.js)から requestTrend(scenarioID) で開始し、host からの {type:'trend'|'trendError'}
// 受信時に main.js が showTrendData/showTrendError を呼ぶ。メッセージ型は src/dashboardModel.ts の
// DashboardFromWebviewMessage/DashboardToWebviewMessage と同期。

import { vscode } from './vscodeApi.js';
import { t } from '../i18n.js';
import { clearChildren, td } from './domUtil.js';
import { machineLabel } from './machineNames.js';
import {
  formatDurationHuman,
  formatLocalDateTime,
  passFailMark,
} from './format.js';

const section = document.getElementById('section-trend');
const titleEl = document.getElementById('trend-title');
const bodyEl = document.getElementById('trend-body');
const closeBtn = document.getElementById('trend-close');

closeBtn.addEventListener('click', () => {
  section.style.display = 'none';
});

function titleFor(scenarioID) {
  return t('wvDashboard.trend.title', { scenarioID });
}

export function requestTrend(scenarioID) {
  section.style.display = 'block';
  titleEl.textContent = titleFor(scenarioID);
  clearChildren(bodyEl);
  const loading = document.createElement('div');
  loading.className = 'status-message';
  loading.textContent = t('wvDashboard.trend.loading');
  bodyEl.appendChild(loading);
  vscode.postMessage({ type: 'trend', scenarioID });
}

export function showTrendError(scenarioID, message) {
  if (titleEl.textContent !== titleFor(scenarioID)) {
    return; // 別シナリオのリクエスト後に古いエラーが届いた場合は無視する
  }
  clearChildren(bodyEl);
  const err = document.createElement('div');
  err.className = 'status-message status-error';
  err.textContent = message;
  bodyEl.appendChild(err);
}

function recordRow(record) {
  const tr = document.createElement('tr');
  const runIdCell = td(record.runID.length > 12 ? record.runID.slice(0, 12) + '…' : record.runID);
  runIdCell.title = record.runID;
  tr.append(
    td(formatLocalDateTime(record.startedAt)),
    runIdCell,
    td(passFailMark(record.passed)),
    td(formatDurationHuman(record.durationMs)),
    td(record.worker || '–'),
    td(machineLabel(record.host)),
  );
  return tr;
}

export function showTrendData(scenarioID, records) {
  if (titleEl.textContent !== titleFor(scenarioID)) {
    return; // 別シナリオのリクエスト後に古い応答が届いた場合は無視する
  }
  clearChildren(bodyEl);
  if (records.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'section-empty';
    empty.textContent = t('wvDashboard.trend.empty');
    bodyEl.appendChild(empty);
    return;
  }
  // 新しい順(startedAt 降順)。
  const sorted = [...records].sort((a, b) => (a.startedAt < b.startedAt ? 1 : a.startedAt > b.startedAt ? -1 : 0));
  const table = document.createElement('table');
  table.className = 'dash-table';
  const thead = document.createElement('thead');
  const headRow = document.createElement('tr');
  // t() のキーはこの走査で静的に検出される(test/i18n.test.mjs)ので、動的な文字列結合にしない。
  const headings = [
    t('wvDashboard.trend.colDateTime'),
    t('wvDashboard.trend.colRunId'),
    t('wvDashboard.trend.colResult'),
    t('wvDashboard.trend.colDuration'),
    t('wvDashboard.trend.colWorker'),
    t('wvDashboard.trend.colHost'),
  ];
  for (const heading of headings) {
    const th = document.createElement('th');
    th.textContent = heading;
    headRow.appendChild(th);
  }
  thead.appendChild(headRow);
  const tbody = document.createElement('tbody');
  for (const record of sorted) {
    tbody.appendChild(recordRow(record));
  }
  table.append(thead, tbody);
  bodyEl.appendChild(table);
}
