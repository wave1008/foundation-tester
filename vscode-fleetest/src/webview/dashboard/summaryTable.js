// summaryTable.js
// 「シナリオ別サマリ」セクション(#table-summary、monitorHtml.ts の renderDashboardPanel() が静的
// スケルトンを持つ)。列見出しクリックでの並べ替え・シナリオID部分一致絞り込み・「失敗を含むものだけ」
// チェックをこのファイルに閉じる(列の順序は monitorHtml.ts の #table-summary の見出しと1:1)。

import { t } from '../i18n.js';
import { clearChildren, td, tdMid, tdNum } from './domUtil.js';
import { scenarioIdCell } from './render.js';
import { formatDurationSeconds, formatLocalDateTime, formatPercentInteger, passFailMark } from './format.js';

const table = document.getElementById('table-summary');
const body = document.getElementById('table-summary-body');
const filterInput = document.getElementById('summary-filter');
const failuresOnlyCheckbox = document.getElementById('summary-failures-only');
const countEl = document.getElementById('summary-count');

// getter は昇順比較用。lastPassed は失敗(0)<未実行(-1 相当なので別枠)<成功(1) の順ではなく、
// 「失敗が先」で並ぶよう false=0/true=1/null=-1 にする(絞り込みチェックと同じ「失敗を先に」感覚)。
const SORT_GETTERS = {
  scenarioID: (r) => r.scenarioID,
  lastPassed: (r) => (r.lastPassed === true ? 1 : r.lastPassed === false ? 0 : -1),
  lastRunAt: (r) => r.lastRunAt || '',
  runs: (r) => r.runs,
  successRate: (r) => r.successRate,
  avgDurationMs: (r) => (typeof r.avgDurationMs === 'number' ? r.avgDurationMs : -1),
};

let currentRows = [];
let sortKey = null;
let sortDir = 1;

function applyFilters(rows) {
  const query = filterInput.value.trim().toLowerCase();
  const failuresOnly = failuresOnlyCheckbox.checked;
  return rows.filter((row) => {
    if (query && !row.scenarioID.toLowerCase().includes(query)) {
      return false;
    }
    if (failuresOnly && row.successRate >= 100) {
      return false;
    }
    return true;
  });
}

function sortRows(rows) {
  if (!sortKey) {
    return rows;
  }
  const getter = SORT_GETTERS[sortKey];
  return [...rows].sort((a, b) => {
    const av = getter(a);
    const bv = getter(b);
    if (av < bv) return -sortDir;
    if (av > bv) return sortDir;
    return 0;
  });
}

function summaryRow(row) {
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
  return tr;
}

function renderRows() {
  const filtered = sortRows(applyFilters(currentRows));
  clearChildren(body);
  for (const row of filtered) {
    body.appendChild(summaryRow(row));
  }
  if (countEl) {
    countEl.textContent = t('wvDashboard.summary.countText', {
      shown: String(filtered.length),
      total: String(currentRows.length),
    });
  }
}

filterInput.addEventListener('input', renderRows);
failuresOnlyCheckbox.addEventListener('change', renderRows);

for (const th of table.querySelectorAll('thead th[data-sort-key]')) {
  th.addEventListener('click', () => {
    const key = th.dataset.sortKey;
    if (sortKey === key) {
      sortDir = -sortDir;
    } else {
      sortKey = key;
      sortDir = 1;
    }
    for (const other of table.querySelectorAll('thead th[data-sort-key]')) {
      other.classList.remove('sort-asc', 'sort-desc');
    }
    th.classList.add(sortDir === 1 ? 'sort-asc' : 'sort-desc');
    renderRows();
  });
}

export function renderSummaryTable(summary) {
  currentRows = summary;
  renderRows();
}
