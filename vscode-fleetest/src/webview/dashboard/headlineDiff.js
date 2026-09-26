// headlineDiff.js
// 「最新の実行」見出しの直下(#headline-diff、monitorHtml.ts の renderDashboardPanel() が静的
// スケルトンを持つ)に前回比を描く。判定は headlineDiffLogic.js の純関数へ切り出してあり、
// ここは DOM 組み立てだけを持つ(document 参照はこのファイルの中だけ)。

import { t } from '../i18n.js';
import { clearChildren } from './domUtil.js';
import { requestTrend } from './trend.js';

export { computeHeadlineDiff, selectComparisonGroups } from './headlineDiffLogic.js';

function listSection(heading, entries) {
  const wrap = document.createElement('div');
  wrap.className = 'headline-diff-group';
  const h = document.createElement('div');
  h.className = 'headline-diff-heading';
  h.textContent = heading;
  const ul = document.createElement('ul');
  ul.className = 'headline-diff-list';
  for (const entry of entries) {
    const li = document.createElement('li');
    const span = document.createElement('span');
    span.className = 'scenario-id-clickable';
    span.textContent = entry.scenarioID + ' [' + entry.platform + ']';
    span.addEventListener('click', () => requestTrend(entry.scenarioID));
    li.appendChild(span);
    ul.appendChild(li);
  }
  wrap.append(h, ul);
  return wrap;
}

export function clearHeadlineDiff() {
  const container = document.getElementById('headline-diff');
  if (container) {
    clearChildren(container);
  }
}

/** diff = computeHeadlineDiff() の戻り値、または比較相手が無い場合は null。 */
export function renderHeadlineDiff(diff) {
  const container = document.getElementById('headline-diff');
  if (!container) {
    return;
  }
  clearChildren(container);
  if (!diff || (diff.newFailures.length === 0 && diff.recovered.length === 0)) {
    return;
  }
  if (diff.newFailures.length > 0) {
    container.appendChild(listSection(t('wvDashboard.headlineDiff.newFailuresHeading'), diff.newFailures));
  }
  if (diff.recovered.length > 0) {
    container.appendChild(listSection(t('wvDashboard.headlineDiff.recoveredHeading'), diff.recovered));
  }
}
