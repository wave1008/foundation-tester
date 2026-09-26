// insights.js
// 「注意が必要な現象」セクション(#section-insights、monitorHtml.ts の renderDashboardPanel() が
// 静的スケルトンを持つ)。重大度(critical→warn→info)ごとに見出しを分け、その中で kind ごとに
// まとめる。scenarioID を持つ行は requestTrend、worker を持つ行(deviceBias)は devices.js の
// revealWorkerRow へリンクする(一致する行が無ければリンクにしない)。

import { t } from '../i18n.js';
import { clearChildren } from './domUtil.js';
import { requestTrend } from './trend.js';
import { hasWorkerRow, revealWorkerRow } from './devices.js';

const SEVERITY_ICON = { critical: '🔴', warn: '🟡', info: '🔵' };
const SEVERITY_ORDER = ['critical', 'warn', 'info'];
// 同じ kind が4件以上なら先頭3件だけ出して残りを折りたたむ(ユーザー指示)。
const KIND_GROUP_COLLAPSE_FROM = 4;
const KIND_GROUP_SHOWN = 3;

const list = document.getElementById('insights-list');
const emptyEl = document.getElementById('insights-empty');
const heading = document.getElementById('insights-heading');

function severityLabel(severity) {
  if (severity === 'critical') return t('wvDashboard.insights.severityCritical');
  if (severity === 'warn') return t('wvDashboard.insights.severityWarn');
  return t('wvDashboard.insights.severityInfo');
}

function insightLine(insight) {
  const li = document.createElement('li');
  li.className = 'insight-item';
  const icon = document.createElement('span');
  icon.className = 'insight-icon';
  icon.textContent = SEVERITY_ICON[insight.severity] || SEVERITY_ICON.info;
  const message = document.createElement('span');
  message.textContent = insight.message;
  if (insight.scenarioID) {
    message.classList.add('scenario-id-clickable');
    message.addEventListener('click', () => requestTrend(insight.scenarioID));
  }
  li.append(icon, message);
  // deviceBias は scenarioID と worker の両方を持つので、台へのリンクは本文と別に添える
  if (insight.worker && hasWorkerRow(insight.worker)) {
    const workerLink = document.createElement('span');
    workerLink.className = 'scenario-id-clickable insight-worker-link';
    workerLink.dataset.worker = insight.worker;
    workerLink.textContent = t('wvDashboard.insights.showDevice', { worker: insight.worker });
    workerLink.addEventListener('click', () => revealWorkerRow(insight.worker));
    li.appendChild(workerLink);
  }
  return li;
}

function severityHeadingItem(severity) {
  const li = document.createElement('li');
  li.className = 'insight-severity-heading';
  li.textContent = severityLabel(severity);
  return li;
}

function groupBy(items, keyFn) {
  const map = new Map();
  for (const item of items) {
    const key = keyFn(item);
    if (!map.has(key)) {
      map.set(key, []);
    }
    map.get(key).push(item);
  }
  return map;
}

export function renderInsights(insights) {
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
  const bySeverity = groupBy(insights, (i) => i.severity);
  for (const severity of SEVERITY_ORDER) {
    const group = bySeverity.get(severity);
    if (!group || group.length === 0) {
      continue;
    }
    list.appendChild(severityHeadingItem(severity));
    const byKind = groupBy(group, (i) => i.kind);
    for (const kindInsights of byKind.values()) {
      const collapse = kindInsights.length >= KIND_GROUP_COLLAPSE_FROM;
      const shown = collapse ? kindInsights.slice(0, KIND_GROUP_SHOWN) : kindInsights;
      for (const insight of shown) {
        list.appendChild(insightLine(insight));
      }
      if (collapse) {
        const more = document.createElement('li');
        more.className = 'insight-item insight-more';
        more.textContent = t('wvDashboard.insights.moreCount', { count: String(kindInsights.length - KIND_GROUP_SHOWN) });
        list.appendChild(more);
      }
    }
  }
}
