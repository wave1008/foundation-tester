// エントリポイント。dashboardPanel.ts からの postMessage を受けて3状態
// (loading/error/data。データ0件は data 内で判定)を切り替え、各セクションを描画する。
// メッセージ型は src/dashboardModel.ts の DashboardToWebviewMessage/DashboardFromWebviewMessage と同期。

import { vscode } from './vscodeApi.js';
import { initDailyChart, renderDailyChart } from './charts.js';
import { formatLocalDateTime } from './format.js';
import { t } from '../i18n.js';
import {
  renderDevicesTable,
  renderFlakyTable,
  renderHeadline,
  renderInsights,
  renderRunsTable,
  renderSlowTable,
  renderSummaryTable,
} from './render.js';

const statusLoading = document.getElementById('status-loading');
const statusError = document.getElementById('status-error');
const statusEmpty = document.getElementById('status-empty');
const content = document.getElementById('content');
const projectLabel = document.getElementById('dash-project');
const generatedAtLabel = document.getElementById('dash-generated-at');
const btnRefresh = document.getElementById('btn-refresh');

function showState(state) {
  statusLoading.style.display = state === 'loading' ? 'block' : 'none';
  statusError.style.display = state === 'error' ? 'block' : 'none';
  statusEmpty.style.display = state === 'empty' ? 'block' : 'none';
  content.style.display = state === 'data' ? 'block' : 'none';
}

function applyData(payload) {
  projectLabel.textContent = payload.project;
  generatedAtLabel.textContent = t('wvDashboard.main.generatedAt', { time: formatLocalDateTime(payload.generatedAt) });

  if (payload.runs.length === 0) {
    showState('empty');
    return;
  }
  showState('data');
  renderHeadline(payload.runs[0]);
  renderRunsTable(payload.runs);
  // slow/insights はキー欠落(古い CLI)を許容する契約(dashboardModel.ts)のためデフォルト空配列。
  renderInsights(payload.insights || []);
  renderFlakyTable(payload.flaky);
  renderSlowTable(payload.slow || []);
  renderDailyChart(payload.daily);
  renderSummaryTable(payload.summary);
  renderDevicesTable(payload.devices.byWorker);
}

window.addEventListener('message', (event) => {
  const message = event.data;
  if (!message || typeof message.type !== 'string') {
    return;
  }
  switch (message.type) {
    case 'loading':
      showState('loading');
      break;
    case 'error':
      statusError.textContent = message.message;
      showState('error');
      break;
    case 'data':
      applyData(message.payload);
      break;
    default:
      break;
  }
});

btnRefresh.addEventListener('click', () => {
  vscode.postMessage({ type: 'refresh' });
});

initDailyChart();
vscode.postMessage({ type: 'ready' });
