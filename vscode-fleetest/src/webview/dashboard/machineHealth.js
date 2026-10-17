// machineHealth.js
// 「マシンの健全性」セクション(#section-machines。静的スケルトンは monitorHtml.ts)。1行 = 1台の Mac。
// 「集計期間」の列は api results の machineHealth(renderMachineHealth の引数)、「今」の列は同じ
// webview 内のモニター(monitor/hostCharts.js の hostMetricsMachines()/onHostMetricsCommitted()。
// 可変状態はあちらに残す規律で、ここは読み取り専用)。結合の鍵は表示名(machineLabel(host)。
// モニターの手元キー '' は LOCAL_MACHINE_LABEL)。履歴にしか居ない行の「今」・モニターにしか居ない行の
// 「集計期間」は「–」(0 や健康で埋めない)。モニターの最新サンプルが無い行は、履歴が無ければ出さない。

import { t } from '../i18n.js';
import { td, tdNum } from './domUtil.js';
import { syncChildren } from '../monitor/rowSync.js';
import { formatLocalDateTime } from './format.js';
import { machineLabel } from './machineNames.js';
import { hostMetricsMachines, onHostMetricsCommitted } from '../monitor/hostCharts.js';
import { LOCAL_MACHINE_LABEL, paintMachineBadge } from '../monitor/machineColors.js';
import { adoptTitleHoverTips, setHoverTip } from '../monitor/hoverTip.js';

const body = document.getElementById('table-machine-health-body');
const emptyEl = document.getElementById('machines-empty');
// 履歴とモニターの両方が1回ずつ届くまでは「確認中」(deviceHealth.js と同じ)
const noRecordsText = emptyEl ? emptyEl.textContent : '';
let historySeen = false;
let liveSeen = false;

adoptTitleHoverTips('#section-machines [title]');

// StepNote の rawValue(JSON の notes のキー。case 名ではない)と訳キー(Sources/FTCore の追跡集合と同期。キーは t() の字面で i18n.test.mjs が実在確認する)
const OCR_NOTES = {
  'ocr-budget-exhausted': 'wvDashboard.machineHealth.note.ocrBudgetExhausted',
  'ocr-compile-capped': 'wvDashboard.machineHealth.note.ocrCompileCapped',
  'ocr-compile-waited': 'wvDashboard.machineHealth.note.ocrCompileWaited',
  'ocr-shortcut-not-ready': 'wvDashboard.machineHealth.note.ocrShortcutNotReady',
  'ocr-shortcut-busy': 'wvDashboard.machineHealth.note.ocrShortcutBusy',
  'ocr-read-what-fm-missed': 'wvDashboard.machineHealth.note.ocrReadWhatFMMissed',
  'fm-read-what-ocr-missed': 'wvDashboard.machineHealth.note.fmReadWhatOCRMissed',
  'fm-empty-transcript-on-ink': 'wvDashboard.machineHealth.note.fmEmptyTranscriptOnInk',
};
const VISION_NOTES = {
  'vision-anomaly-retried': 'wvDashboard.machineHealth.note.visionAnomalyRetried',
  'vision-helper-rescued': 'wvDashboard.machineHealth.note.visionHelperRescued',
  'vision-helper-unavailable': 'wvDashboard.machineHealth.note.visionHelperUnavailable',
  'vision-classifier-unavailable': 'wvDashboard.machineHealth.note.visionClassifierUnavailable',
  'check-state-classifier-failed': 'wvDashboard.machineHealth.note.checkStateClassifierFailed',
};
// 要注意(警告色)。それ以外の注記は情報で色を付けない
const ATTENTION_NOTES = new Set([
  'ocr-budget-exhausted', 'ocr-compile-capped', 'vision-helper-unavailable',
  'vision-classifier-unavailable', 'check-state-classifier-failed',
]);

let lastHistory = [];
let lastSignature = null;

function sortLabels(labels) {
  return [...labels].sort((a, b) => {
    if (a === LOCAL_MACHINE_LABEL) return b === LOCAL_MACHINE_LABEL ? 0 : -1;
    if (b === LOCAL_MACHINE_LABEL) return 1;
    return a < b ? -1 : a > b ? 1 : 0;
  });
}

/** 履歴(machineHealth)とモニターの行を表示名で結合する。 */
function combineRows() {
  const byLabel = new Map();
  for (const health of lastHistory) {
    byLabel.set(machineLabel(health.host), { label: machineLabel(health.host), health, live: undefined });
  }
  for (const live of hostMetricsMachines()) {
    const label = live.machine === '' ? LOCAL_MACHINE_LABEL : live.machine;
    const existing = byLabel.get(label);
    if (existing) {
      existing.live = live;
    } else if (!live.stale) {
      byLabel.set(label, { label, health: undefined, live });
    }
  }
  return sortLabels(byLabel.keys()).map((label) => byLabel.get(label));
}

function pct(ratio) {
  return ratio === null || ratio === undefined ? '–' : Math.round(ratio * 100) + '%';
}

function seconds(ms) {
  return (ms / 1000).toFixed(1);
}

function timeText(iso) {
  return iso ? formatLocalDateTime(iso) : '–';
}

function withTip(cell, text) {
  if (text) {
    setHoverTip(cell, text);
  }
  return cell;
}

function warn(cell, on) {
  if (on) {
    cell.classList.add('mh-warn');
  }
  return cell;
}

function chip(className, text) {
  const span = document.createElement('span');
  span.className = className;
  span.textContent = text;
  return span;
}

function machineCell(label) {
  const cell = document.createElement('td');
  const badge = document.createElement('span');
  badge.className = 'badge badge-remote';
  badge.textContent = label;
  paintMachineBadge(badge, label === LOCAL_MACHINE_LABEL ? undefined : label);
  cell.appendChild(badge);
  return cell;
}

function fmStateOf(live, path) {
  if (!live || live.stale) return 'unknown';
  const state = live.liveness[path];
  return state === 'alive' || state === 'dead' ? state : 'unknown';
}

/** 色は補助。記号と文字を必ず残す。 */
function fmCell(live) {
  const cell = document.createElement('td');
  cell.className = 'mh-fm';
  const marks = { alive: '●', dead: '✕', unknown: '?' };
  const labels = {
    alive: t('wvDashboard.machineHealth.fmAlive'),
    dead: t('wvDashboard.machineHealth.fmDead'),
    unknown: t('wvDashboard.machineHealth.fmUnknown'),
  };
  const paths = [['text', t('wvDashboard.machineHealth.chipText')], ['vision', t('wvDashboard.machineHealth.chipImage')]];
  for (const [path, name] of paths) {
    const state = fmStateOf(live, path);
    cell.appendChild(chip('mh-chip mh-fm-' + state, marks[state] + ' ' + name + ' ' + labels[state]));
  }
  const tips = [];
  if (!live || live.stale) {
    tips.push(t('wvDashboard.machineHealth.fmNoObservation'));
  } else {
    if (live.liveness.reason) tips.push(live.liveness.reason);
    if (typeof live.liveness.checkedAt === 'number') {
      tips.push(t('wvDashboard.machineHealth.fmCheckedAt', {
        time: formatLocalDateTime(new Date(live.liveness.checkedAt * 1000).toISOString()),
      }));
    }
  }
  return withTip(cell, tips.join('\n'));
}

function visionCell(live) {
  const cell = document.createElement('td');
  if (!live || live.stale || live.visionCalls === null) {
    cell.textContent = '–';
  } else {
    cell.textContent = t('wvDashboard.machineHealth.visionCalls', {
      calls: String(live.visionCalls), failures: String(live.visionFailures),
    });
    warn(cell, live.visionFailures > 0);
    setHoverTip(cell, t('wvDashboard.machineHealth.visionWindowTitle', { seconds: String(live.windowTicks) }));
  }
  if (live && !live.stale && live.ocrCompiling) {
    const compiling = chip('badge mh-chip-compiling', t('wvDashboard.machineHealth.ocrCompiling'));
    setHoverTip(compiling, t('wvDashboard.machineHealth.ocrCompilingTitle'));
    cell.appendChild(compiling);
  }
  return cell;
}

function loadCell(live) {
  if (!live || live.stale) return td('–');
  return td(t('wvDashboard.machineHealth.load', { cpu: pct(live.cpu), mem: pct(live.memRatio) }));
}

function nz(value) {
  return value !== null && value !== undefined;
}

function fmDeadTip(dead) {
  if (!dead) return '';
  const lines = [t('wvDashboard.machineHealth.lastFmDeadTitle', { time: timeText(dead.at), paths: (dead.paths || []).join(', ') })];
  if (dead.reason) lines.push(t('wvDashboard.machineHealth.lastFmDeadReason', { reason: dead.reason }));
  return lines.join('\n');
}

function fmUsageTip(fm) {
  const lines = [t('wvDashboard.machineHealth.fmUsageTitle', {
    retries: String(fm.retries), retrySuccesses: String(fm.retrySuccesses), skipped: String(fm.skipped),
    avg: String(fm.calls > 0 ? Math.round(fm.totalMs / fm.calls) : 0), max: String(fm.maxMs),
    scenarios: String(fm.scenarios),
  })];
  if (fm.lastError) {
    lines.push(t('wvDashboard.machineHealth.fmLastError', {
      time: timeText(fm.lastError.at), scenarioID: fm.lastError.scenarioID, message: fm.lastError.message,
    }));
  }
  return lines.join('\n');
}

function noteLabel(code, keys) {
  const key = keys[code];
  return key ? t(key) : code;
}

/** 注記群の合計セル。要注意を含めば警告色、内訳は注記ごとの訳と件数(未知のコードは rawValue のまま) */
function notesCell(health, keys) {
  if (!health) return tdNum('–');
  const notes = health.notes || {};
  const present = Object.keys(keys).filter((code) => (notes[code] || 0) > 0);
  const total = present.reduce((sum, code) => sum + notes[code], 0);
  const cell = withTip(
    tdNum(String(total)),
    present.map((code) => noteLabel(code, keys) + ': ' + notes[code]).join('\n'),
  );
  return warn(cell, present.some((code) => ATTENTION_NOTES.has(code)));
}

function guardCell(health) {
  if (!health || (!nz(health.guarded) && !nz(health.guardSkipped))) return tdNum('–');
  const text = (nz(health.guardSkipped) ? health.guardSkipped : '–') + ' / ' + (nz(health.guarded) ? health.guarded : '–');
  const lines = [t('wvDashboard.machineHealth.guardTitle')];
  if (nz(health.guardStaleFrame)) {
    lines.push(t('wvDashboard.machineHealth.guardStaleFrame', { count: String(health.guardStaleFrame) }));
  }
  return warn(withTip(tdNum(text), lines.join('\n')), (health.guardSkipped || 0) > 0);
}

function rowElement(row) {
  const { health, live } = row;
  const fm = health && health.fm;
  const tr = document.createElement('tr');
  tr.dataset.machine = row.label;
  tr.append(
    machineCell(row.label),
    ...LIVE_CELL_BUILDERS.map((build) => build(live)),
    withTip(tdNum(health ? String(health.runs) : '–'),
      health && health.lastRunAt ? t('wvDashboard.machineHealth.lastRunTitle', { time: timeText(health.lastRunAt) }) : ''),
    warn(withTip(tdNum(health ? String(health.fmDeadRuns) : '–'), health ? fmDeadTip(health.lastFMDead) : ''),
      !!health && health.fmDeadRuns > 0),
    warn(withTip(tdNum(fm ? fm.failures + ' / ' + fm.calls : '–'), fm ? fmUsageTip(fm) : ''), !!fm && fm.failures > 0),
    guardCell(health),
    withTip(tdNum(fm ? seconds(fm.gateWaitMaxMs) : '–'),
      fm ? t('wvDashboard.machineHealth.gateTotalTitle', { seconds: seconds(fm.gateWaitTotalMs) }) : ''),
    notesCell(health, OCR_NOTES),
    notesCell(health, VISION_NOTES),
    withTip(tdNum(health && nz(health.pacedSteps) ? String(health.pacedSteps) : '–'),
      health && nz(health.pacedMs) ? t('wvDashboard.machineHealth.pacedTitle', { seconds: seconds(health.pacedMs) }) : ''),
  );
  return tr;
}

function renderRows(rows) {
  // 表を描き直すとき(結果の取り直し・マシンの増減)も、同じ位置が同じマシンなら行を残して変わったセルだけ差し替える
  syncChildren(body, rows.map(rowElement), { recurseWhen: (old, next) => old.dataset.machine === next.dataset.machine });
  emptyEl.textContent = historySeen && liveSeen ? noRecordsText : t('wvDashboard.machineHealth.checking');
  emptyEl.style.display = rows.length === 0 ? 'block' : 'none';
}

/** 見出し「集計期間」に窓を付ける。from = payload.since(窓の開始)・to = payload.generatedAt(集計した時刻)。
 *  どちらかが無ければ静的 HTML の「集計期間」のまま */
function renderPeriodHeader(period) {
  const header = document.getElementById('mh-period-header');
  if (!header || !period || !period.since || !period.generatedAt) {
    return;
  }
  header.textContent = t('wvDashboard.machineHealth.periodHeader', {
    from: formatLocalDateTime(period.since), to: formatLocalDateTime(period.generatedAt),
  });
}

export function renderMachineHealth(machineHealthRows, period) {
  renderPeriodHeader(period);
  historySeen = true;
  lastHistory = machineHealthRows || [];
  lastSignature = null;
  renderRows(combineRows());
}

// 「今」の列は 1Hz で届く。表に出る値が変わらない周期は描き直さない(deviceHealth.js の monitorSignature と同じ方針)
function liveSignature(rows) {
  return JSON.stringify(rows.map((row) => {
    const l = row.live;
    return [row.label, l ? [l.stale, pct(l.cpu), pct(l.memRatio), l.liveness, l.visionCalls, l.visionFailures,
      l.windowTicks, l.ocrCompiling] : null];
  }));
}

const LIVE_CELL_BUILDERS = [fmCell, visionCell, loadCell];
// 「今」の列は rowElement の中でマシンの列の直後(rowElement もこの一覧から作る)
const LIVE_CELL_OFFSET = 1;

/** 行の並びが同じなら「今」の列だけを**同じ td の中身の差し替え**で更新する。行を作り直すと、マウスを載せている
 *  セル(集計期間の列を含む)が消えてツールチップが出直す = 1Hz で点滅する。並びが変わったら false(呼び手が作り直す) */
function patchLiveCells(rows) {
  const trs = [...body.children];
  if (trs.length !== rows.length || trs.some((tr, i) => tr.dataset.machine !== rows[i].label)) {
    return false;
  }
  rows.forEach((row, i) => {
    LIVE_CELL_BUILDERS.forEach((build, j) => {
      const cell = trs[i].children[LIVE_CELL_OFFSET + j];
      const next = build(row.live);
      if (cell.outerHTML === next.outerHTML) {
        return;
      }
      cell.className = next.className;
      cell.replaceChildren(...next.childNodes);
      const tip = next.getAttribute('data-hover-tip');
      setHoverTip(cell, tip || '');
    });
  });
  return true;
}

onHostMetricsCommitted(() => {
  const first = !liveSeen;
  liveSeen = true;
  const rows = combineRows();
  const signature = liveSignature(rows);
  if (!first && signature === lastSignature) {
    return;
  }
  lastSignature = signature;
  if (first || !patchLiveCells(rows)) {
    renderRows(rows);
  }
});
