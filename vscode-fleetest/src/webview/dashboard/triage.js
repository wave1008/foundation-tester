// triage.js
// 「失敗の内訳」セクション(#section-triage、monitorHtml.ts の renderDashboardPanel() が静的
// スケルトンを持つ)。ApiResultsPayload.triageを描く。section/command/failureKind が欠けている
// 欄は「–」で表示する(「その他」に丸めない。CLAUDE.md の失敗記録の規律と同じ)。
// triage キーが無いペイロード(旧 CLI・型上 optional)ではセクションごと隠す。

import { t } from '../i18n.js';
import { clearChildren, td, tdNum } from './domUtil.js';
import { requestTrend } from './trend.js';

const COLLAPSE_LIMIT = 15;

const section = document.getElementById('section-triage');
const summaryEl = document.getElementById('triage-summary');
const table = document.getElementById('table-triage');
const body = document.getElementById('table-triage-body');
const toggleBtn = document.getElementById('triage-toggle-all');
const notesTable = document.getElementById('table-triage-notes');
const notesBody = document.getElementById('table-triage-notes-body');
const emptyEl = document.getElementById('triage-empty');

let expanded = false;
let currentRows = [];

function scenarioExamplesCell(scenarioIDs) {
  const cell = document.createElement('td');
  if (!scenarioIDs || scenarioIDs.length === 0) {
    cell.textContent = '–';
    return cell;
  }
  scenarioIDs.forEach((id, index) => {
    if (index > 0) {
      cell.appendChild(document.createTextNode(', '));
    }
    const span = document.createElement('span');
    span.textContent = id;
    span.className = 'scenario-id-clickable';
    span.addEventListener('click', () => requestTrend(id));
    cell.appendChild(span);
  });
  return cell;
}

function triageRow(row) {
  const tr = document.createElement('tr');
  tr.append(
    td(row.section || '–'),
    td(row.command || '–'),
    td(row.failureKind || '–'),
    tdNum(String(row.count)),
    tdNum(String(row.scenarioCount)),
    scenarioExamplesCell(row.scenarioIDs),
  );
  return tr;
}

function renderRows() {
  clearChildren(body);
  const rows = expanded ? currentRows : currentRows.slice(0, COLLAPSE_LIMIT);
  for (const row of rows) {
    body.appendChild(triageRow(row));
  }
  if (currentRows.length > COLLAPSE_LIMIT) {
    toggleBtn.style.display = 'inline-block';
    toggleBtn.textContent = expanded
      ? t('wvDashboard.triage.showLess')
      : t('wvDashboard.triage.showAll', { count: String(currentRows.length) });
  } else {
    toggleBtn.style.display = 'none';
  }
}

toggleBtn.addEventListener('click', () => {
  expanded = !expanded;
  renderRows();
});

function noteRow(note) {
  const tr = document.createElement('tr');
  tr.append(td(note.note), tdNum(String(note.count)));
  return tr;
}

/** triage = ApiResultsPayload.triage(undefined なら旧 CLI 相当。セクションごと隠す)。 */
export function renderTriage(triage) {
  if (!triage) {
    section.style.display = 'none';
    return;
  }
  section.style.display = 'block';
  expanded = false;
  currentRows = triage.rows;

  clearChildren(summaryEl);
  const summary = document.createElement('div');
  summary.textContent = t('wvDashboard.triage.summary', {
    count: String(triage.totalFailed),
    unreached: String(triage.unreachedCount),
  });
  summaryEl.appendChild(summary);

  const hasRows = triage.rows.length > 0;
  table.style.display = hasRows ? 'table' : 'none';
  emptyEl.style.display = hasRows ? 'none' : 'block';
  renderRows();

  clearChildren(notesBody);
  notesTable.style.display = triage.noteCounts.length > 0 ? 'table' : 'none';
  for (const note of triage.noteCounts) {
    notesBody.appendChild(noteRow(note));
  }
}
