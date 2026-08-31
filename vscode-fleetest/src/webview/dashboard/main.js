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
  groupRuns,
  renderHeadline,
  renderInsights,
  renderMatrixTable,
  renderRunsTable,
  renderSlowTable,
  renderSummaryTable,
  renderTriageTable,
} from './render.js';
import { renderPerformance } from './performance.js';
import { setMachineAliases } from './machineNames.js';
import { showRunDetailData, showRunDetailError } from './runDetail.js';
import { showTrendData, showTrendError } from './trend.js';

const statusLoading = document.getElementById('status-loading');
const statusError = document.getElementById('status-error');
const statusEmpty = document.getElementById('status-empty');
const content = document.getElementById('content');
const projectSelect = document.getElementById('dash-project-select');
const generatedAtLabel = document.getElementById('dash-generated-at');
const btnRefresh = document.getElementById('btn-refresh');

function showState(state) {
  statusLoading.style.display = state === 'loading' ? 'block' : 'none';
  statusError.style.display = state === 'error' ? 'block' : 'none';
  statusEmpty.style.display = state === 'empty' ? 'block' : 'none';
  content.style.display = state === 'data' ? 'block' : 'none';
}

// projects メッセージ(refresh のたびに届く)でドロップダウンを作り直す。current が '' =
// プロジェクト未解決(設定なし・複数候補)でも、ここから選べば復帰できる。
function applyProjects(projects, current) {
  while (projectSelect.firstChild) {
    projectSelect.removeChild(projectSelect.firstChild);
  }
  if (current === '') {
    const placeholder = document.createElement('option');
    placeholder.value = '';
    placeholder.disabled = true;
    placeholder.selected = true;
    placeholder.textContent = t('wvDashboard.main.projectPlaceholder');
    projectSelect.appendChild(placeholder);
  }
  for (const name of projects) {
    const option = document.createElement('option');
    option.value = name;
    option.textContent = name;
    projectSelect.appendChild(option);
  }
  projectSelect.value = current;
}

function applyData(payload) {
  if (projectSelect.value !== payload.project) {
    projectSelect.value = payload.project;
  }
  generatedAtLabel.textContent = t('wvDashboard.main.generatedAt', { time: formatLocalDateTime(payload.generatedAt) });

  if (payload.runs.length === 0) {
    showState('empty');
    return;
  }
  showState('data');
  // 各セクションの host 表示を machine へ読み替えるため、描画より先に対応表を差し替える
  setMachineAliases(payload.machines || []);
  // キー欠落(旧 CLI)を許容する契約(dashboardModel.ts)のため performance は undefined のことがある。
  renderPerformance(payload.performance);
  // 直近の実行も実行(runGroup)単位に畳む(パフォーマンス一覧と同じ規則)
  const runGroups = groupRuns(payload.runs);
  const statsByRunID = new Map((payload.runStats || []).map((s) => [s.runID, s]));
  renderHeadline(runGroups[0]);
  renderRunsTable(runGroups, statsByRunID);
  // slow/insights はキー欠落(古い CLI)を許容する契約(dashboardModel.ts)のためデフォルト空配列。
  renderInsights(payload.insights || []);
  renderFlakyTable(payload.flaky);
  renderSlowTable(payload.slow || []);
  const matrixSection = document.getElementById('section-matrix');
  if (payload.matrix) {
    matrixSection.style.display = 'block';
    renderMatrixTable(payload.matrix);
  } else {
    matrixSection.style.display = 'none';
  }
  // triage/dailyFullSuite/fullSuiteMinScenarios はキー欠落(古い CLI)を許容する契約(dashboardModel.ts)。
  renderTriageTable(payload.triage);
  renderDailyChart(payload.daily, payload.dailyFullSuite, payload.fullSuiteMinScenarios);
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
    case 'runDetail':
      showRunDetailData(message.payloads);
      break;
    case 'runDetailError':
      showRunDetailError(message.runID, message.message);
      break;
    case 'trend':
      showTrendData(message.scenarioID, message.records);
      break;
    case 'trendError':
      showTrendError(message.scenarioID, message.message);
      break;
    case 'projects':
      applyProjects(message.projects, message.current);
      break;
    default:
      break;
  }
});

btnRefresh.addEventListener('click', () => {
  vscode.postMessage({ type: 'refresh' });
});

projectSelect.addEventListener('change', () => {
  if (projectSelect.value !== '') {
    vscode.postMessage({ type: 'selectProject', project: projectSelect.value });
  }
});

initDailyChart();
vscode.postMessage({ type: 'ready' });
