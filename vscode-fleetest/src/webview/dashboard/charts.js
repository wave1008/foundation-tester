// 日別成功率チャート(daily を棒グラフで描画。hostCharts.js と同じ自前 canvas 流儀・
// 依存ライブラリなし)。データ0件時は何も描かない(呼び出し側が status-empty を出す)。

import { isLightTheme } from './format.js';
import { t } from '../i18n.js';

const BAR_WIDTH = 20; // css px。90日分でも横スクロール前提のため詰めすぎない幅にする。
const BAR_GAP = 4;
const CHART_HEIGHT = 160; // css px
// 軸ラベルは横書きが既定。最長ラベルの実測幅(measureText)が1本ぶんの幅(BAR_WIDTH + BAR_GAP)に
// 収まらないときだけ縦書き(-90°)にする(棒幅 20px に "M/D" は重なる。棒幅は変えない = ユーザー決定)。
// ラベル領域の高さは固定せず、横書きならフォントの高さ、縦書きなら最長ラベルの幅から決める
const AXIS_LABEL_FONT = '9px var(--vscode-font-family, sans-serif)';
const AXIS_LABEL_GAP = 4; // 棒の下端からラベルまで / ラベル下の余白(css px)

const CHART_COLORS = {
  dark: { good: '#2f9e63', warn: '#b8891f', bad: '#f2555a', empty: 'rgba(127, 127, 127, 0.25)', axis: 'rgba(255, 255, 255, 0.5)' },
  light: { good: '#30a46c', warn: '#e6a700', bad: '#e5484d', empty: 'rgba(127, 127, 127, 0.25)', axis: 'rgba(0, 0, 0, 0.5)' },
};

let currentDaily = [];
let currentDailyFullSuite = [];
let useFullSuite = false;
let canvas;
let tooltip;
let toggleInput;
let toggleLabel;
let toggleTextEl;

function activeDaily() {
  return useFullSuite ? currentDailyFullSuite : currentDaily;
}

function barColor(rate) {
  const palette = CHART_COLORS[isLightTheme() ? 'light' : 'dark'];
  if (rate >= 90) return palette.good;
  if (rate >= 70) return palette.warn;
  return palette.bad;
}

function successRate(day) {
  return day.total > 0 ? (day.passed / day.total) * 100 : null;
}

function setupCanvas(widthCss, heightCss) {
  const dpr = window.devicePixelRatio || 1;
  canvas.style.width = widthCss + 'px';
  canvas.style.height = heightCss + 'px';
  canvas.width = Math.round(widthCss * dpr);
  canvas.height = Math.round(heightCss * dpr);
  const ctx = canvas.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  return ctx;
}

function shortDate(dateStr) {
  // "yyyy-MM-dd" -> "M/D"(先頭の 0 は落とす。"07/23" → "7/23")
  const parts = dateStr.split('-');
  return parts.length === 3 ? String(Number(parts[1])) + '/' + String(Number(parts[2])) : dateStr;
}

function draw() {
  const daily = activeDaily();
  if (!canvas || daily.length === 0) {
    return;
  }
  const widthCss = daily.length * (BAR_WIDTH + BAR_GAP) + BAR_GAP;
  const labels = daily.map((day) => shortDate(day.date));
  // サイズ確定前に同じフォントで測る(canvas のサイズ変更で ctx の状態は消えるため先に測る)
  const measureCtx = canvas.getContext('2d');
  measureCtx.font = AXIS_LABEL_FONT;
  const metrics = labels.map((label) => measureCtx.measureText(label));
  const labelLength = Math.ceil(Math.max(0, ...metrics.map((m) => m.width)));
  const fontHeight = Math.ceil(Math.max(0, ...metrics.map((m) => m.actualBoundingBoxAscent + m.actualBoundingBoxDescent)));
  const vertical = labelLength > BAR_WIDTH + BAR_GAP;
  const labelArea = vertical ? labelLength : fontHeight;
  const heightCss = CHART_HEIGHT + AXIS_LABEL_GAP + labelArea + AXIS_LABEL_GAP;
  const ctx = setupCanvas(widthCss, heightCss);
  ctx.clearRect(0, 0, widthCss, heightCss);

  const palette = CHART_COLORS[isLightTheme() ? 'light' : 'dark'];
  ctx.font = AXIS_LABEL_FONT;

  daily.forEach((day, i) => {
    const x = BAR_GAP + i * (BAR_WIDTH + BAR_GAP);
    const rate = successRate(day);
    if (rate === null) {
      // 実行0件の日は薄いプレースホルダーのみ(高さ0だと軸ラベルとの位置関係が分かりにくいため)。
      ctx.fillStyle = palette.empty;
      ctx.fillRect(x, CHART_HEIGHT - 2, BAR_WIDTH, 2);
    } else {
      const barHeight = Math.max(2, (rate / 100) * CHART_HEIGHT);
      ctx.fillStyle = barColor(rate);
      ctx.fillRect(x, CHART_HEIGHT - barHeight, BAR_WIDTH, barHeight);
    }
    ctx.fillStyle = palette.axis;
    if (vertical) {
      // 棒の直下を起点に下向きへ伸びる縦書き(-90°回転・右揃え = 文末が棒側)
      ctx.save();
      ctx.translate(x + BAR_WIDTH / 2, CHART_HEIGHT + AXIS_LABEL_GAP);
      ctx.rotate(-Math.PI / 2);
      ctx.textAlign = 'right';
      ctx.textBaseline = 'middle';
      ctx.fillText(labels[i], 0, 0);
      ctx.restore();
    } else {
      ctx.textAlign = 'center';
      ctx.textBaseline = 'top';
      ctx.fillText(labels[i], x + BAR_WIDTH / 2, CHART_HEIGHT + AXIS_LABEL_GAP);
    }
  });
}

function barIndexAt(offsetX) {
  const daily = activeDaily();
  const index = Math.floor(offsetX / (BAR_WIDTH + BAR_GAP));
  return index >= 0 && index < daily.length ? index : -1;
}

function handleMouseMove(event) {
  const rect = canvas.getBoundingClientRect();
  const index = barIndexAt(event.clientX - rect.left);
  if (index === -1) {
    tooltip.style.display = 'none';
    return;
  }
  const day = activeDaily()[index];
  const rate = successRate(day);
  tooltip.textContent = day.date + ': ' + day.passed + '/' + day.total + ' passed' +
    (rate === null ? t('wvDashboard.chart.noRuns') : '(' + rate.toFixed(1) + '%)') +
    (day.failed > 0 ? t('wvDashboard.chart.failedCount', { count: day.failed }) : '');
  tooltip.style.display = 'block';
  tooltip.style.left = event.clientX + 'px';
  tooltip.style.top = (rect.top - 28) + 'px';
}

function handleMouseLeave() {
  tooltip.style.display = 'none';
}

export function initDailyChart() {
  canvas = document.getElementById('daily-chart');
  tooltip = document.createElement('div');
  tooltip.id = 'daily-chart-tooltip';
  tooltip.className = 'daily-chart-tooltip';
  tooltip.style.display = 'none';
  document.body.appendChild(tooltip);
  canvas.addEventListener('mousemove', handleMouseMove);
  canvas.addEventListener('mouseleave', handleMouseLeave);

  toggleInput = document.getElementById('daily-fullsuite-toggle');
  toggleLabel = document.querySelector('.daily-toggle');
  toggleTextEl = document.getElementById('daily-fullsuite-text');
  toggleInput.addEventListener('change', () => {
    useFullSuite = toggleInput.checked;
    draw();
  });

  new MutationObserver(draw).observe(document.body, { attributes: true, attributeFilter: ['class'] });
}

// dailyFullSuite/fullSuiteMinScenarios はキー欠落(旧 CLI)を許容する契約(dashboardModel.ts)。
// 欠落時はトグルごと隠し、フルスイート表示には切り替えない。
export function renderDailyChart(daily, dailyFullSuite, fullSuiteMinScenarios) {
  currentDaily = daily;
  currentDailyFullSuite = dailyFullSuite || [];
  if (typeof fullSuiteMinScenarios !== 'number') {
    toggleLabel.style.display = 'none';
    useFullSuite = false;
    toggleInput.checked = false;
  } else {
    toggleLabel.style.display = 'inline-flex';
    toggleTextEl.textContent = t('wvDashboard.chart.fullSuiteToggle', { n: String(fullSuiteMinScenarios) });
  }
  draw();
}
