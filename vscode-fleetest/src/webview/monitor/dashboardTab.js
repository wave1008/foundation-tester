// dashboardTab.js
// モニターパネルの「ダッシュボード」タブ。
// acquireVsCodeApi はこの document で既に './vscodeApi.js' が1回呼んでいるため、
// ダッシュボード側の postMessage は '../dashboard/vscodeApi.js' の setDashboardTransport() で
// 封筒 {type:'dashboard', message} に包んで転送する(webview→host は必ずこの封筒。
// モニター既存の ready/refresh と型が衝突するため生のまま流さない)。
// host→webview は monitor/main.js のディスパッチャが {type:'dashboard', message} を受け、
// この handleDashboardMessage() へ渡す(対向: src/monitorDashboardController.ts)。

import { vscode as monitorVscode } from './vscodeApi.js';
import { vscode, setDashboardTransport } from '../dashboard/vscodeApi.js';
import { initDailyChart, renderDailyChart } from '../dashboard/charts.js';
import { formatLocalDateTime } from '../dashboard/format.js';
import { t } from '../i18n.js';
import {
  renderFlakyTable,
  groupRuns,
  renderHeadline,
  renderRunsTable,
  renderSlowTable,
} from '../dashboard/render.js';
import { renderSummaryTable } from '../dashboard/summaryTable.js';
import { renderInsights } from '../dashboard/insights.js';
import { renderTriage } from '../dashboard/triage.js';
import { renderDevices } from '../dashboard/devices.js';
import { renderPerformance } from '../dashboard/performance.js';
import { setMachineAliases } from '../dashboard/machineNames.js';
import { showRunDetailData, showRunDetailError } from '../dashboard/runDetail.js';
import { showTrendData, showTrendError } from '../dashboard/trend.js';
import {
  clearHeadlineDiff,
  computeHeadlineDiff,
  renderHeadlineDiff,
  selectComparisonGroups,
} from '../dashboard/headlineDiff.js';

setDashboardTransport((message) => monitorVscode.postMessage({ type: 'dashboard', message }));

const statusLoading = document.getElementById('status-loading');
const statusError = document.getElementById('status-error');
const statusEmpty = document.getElementById('status-empty');
const content = document.getElementById('content');
const projectSelect = document.getElementById('dash-project-select');
const sinceSelect = document.getElementById('dash-since-select');
const generatedAtLabel = document.getElementById('dash-generated-at');
const btnRefresh = document.getElementById('btn-refresh');
const updatingLabel = document.getElementById('dash-updating');
const updateErrorEl = document.getElementById('dash-update-error');

// データを一度表示したら 'loading'/'error' で本文を隠さない(更新中はツールバーの表示だけ切る)。
let hasRenderedData = false;

// 送った latestRunIDs の先頭(= 応答の payload.latest[0].run.runID と比較)。古い応答
// (別のデータに対する応答)を捨てるための鍵。
let expectedHeadlineDiffRunID = null;

function showState(state) {
  statusLoading.style.display = state === 'loading' ? 'block' : 'none';
  statusError.style.display = state === 'error' ? 'block' : 'none';
  statusEmpty.style.display = state === 'empty' ? 'block' : 'none';
  content.style.display = state === 'data' ? 'block' : 'none';
}

function setUpdating(active) {
  updatingLabel.style.display = active ? 'inline' : 'none';
}

function setUpdateError(message) {
  if (message) {
    updateErrorEl.textContent = message;
    updateErrorEl.style.display = 'block';
  } else {
    updateErrorEl.style.display = 'none';
  }
}

// projects メッセージ(refresh のたびに届く)でドロップダウンを作り直す。current が '' =
// プロジェクト未解決(設定なし・複数候補)でも、ここから選べば復帰できる。since は webview 再読込
// (言語切替)で選択が既定へ戻るのを防ぐため、毎回ホストの保持値へ合わせる。
function applyProjects(projects, current, since) {
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
  if (since) {
    sinceSelect.value = since;
  }
}

// ホストは refresh の頭で控え(表示中と同じペイロード)を再送する。同じものを描き直すと
// 「すべて表示」等の開閉と前回比の問い合わせがやり直しになるので、中身が同一なら描かない
// (generatedAt は CLI のキャッシュ命中でも呼ぶたびに変わるので鍵にならない。比較は中身全体)
let lastAppliedKey = null;

function applyData(payload) {
  const key = JSON.stringify(payload);
  if (key === lastAppliedKey && hasRenderedData) {
    return;
  }
  lastAppliedKey = key;
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
  // 直近の実行も実行(runGroup)単位に畳む(パフォーマンス一覧と同じ規則)
  const runGroups = groupRuns(payload.runs);
  const statsByRunID = new Map((payload.runStats || []).map((s) => [s.runID, s]));
  renderHeadline(runGroups[0]);
  requestHeadlineDiff(runGroups);
  // devices は insights より先に描く: deviceBias リンクの可否(hasWorkerRow)が devices.js の
  // currentWorkers を参照するため
  renderDevices(payload.devices);
  renderTriage(payload.triage);
  renderRunsTable(runGroups, statsByRunID);
  // キー欠落(旧 CLI)を許容する契約(dashboardModel.ts)のため performance は undefined のことがある。
  renderPerformance(payload.performance);
  // slow/insights はキー欠落(古い CLI)を許容する契約(dashboardModel.ts)のためデフォルト空配列。
  renderSlowTable(payload.slow || []);
  renderInsights(payload.insights || []);
  renderFlakyTable(payload.flaky);
  renderDailyChart(payload.daily);
  renderSummaryTable(payload.summary);
}

// 直前の実行(同じ profile・全構成 run の集計が揃っている最も新しいグループ)が見つかれば
// ホストへ問い合わせる。見つからなければ何も送らず前回比セクションを畳む。
function requestHeadlineDiff(runGroups) {
  const comparison = selectComparisonGroups(runGroups);
  if (!comparison) {
    expectedHeadlineDiffRunID = null;
    clearHeadlineDiff();
    return;
  }
  expectedHeadlineDiffRunID = comparison.latest[0].runID;
  vscode.postMessage({
    type: 'headlineDiff',
    latestRunIDs: comparison.latest.map((r) => r.runID),
    previousRunIDs: comparison.previous.map((r) => r.runID),
  });
}

/** monitor/main.js の直下ディスパッチャの case 'dashboard' から呼ぶ(message = 封筒の中身)。 */
export function handleDashboardMessage(message) {
  switch (message.type) {
    case 'loading':
      if (hasRenderedData) {
        setUpdating(true);
      } else {
        showState('loading');
      }
      break;
    case 'error':
      if (hasRenderedData) {
        setUpdating(false);
        setUpdateError(message.message);
      } else {
        statusError.textContent = message.message;
        showState('error');
      }
      break;
    case 'data':
      setUpdating(false);
      setUpdateError(null);
      applyData(message.payload);
      hasRenderedData = true;
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
    case 'headlineDiff':
      if (message.latest[0]?.run.runID !== expectedHeadlineDiffRunID) {
        break; // 別のデータに対する古い応答
      }
      renderHeadlineDiff(computeHeadlineDiff(message.latest, message.previous));
      break;
    case 'headlineDiffError':
      clearHeadlineDiff();
      break;
    case 'projects':
      applyProjects(message.projects, message.current, message.since);
      break;
    default:
      break;
  }
}

btnRefresh.addEventListener('click', () => {
  vscode.postMessage({ type: 'refresh' });
});

projectSelect.addEventListener('change', () => {
  if (projectSelect.value !== '') {
    vscode.postMessage({ type: 'selectProject', project: projectSelect.value });
  }
});

sinceSelect.addEventListener('change', () => {
  vscode.postMessage({ type: 'setSince', since: sinceSelect.value });
});

initDailyChart();
vscode.postMessage({ type: 'ready' });
