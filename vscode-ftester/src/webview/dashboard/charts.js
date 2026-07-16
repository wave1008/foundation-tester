// 日別成功率チャート(daily を棒グラフで描画。hostCharts.js と同じ自前 canvas 流儀・
// 依存ライブラリなし)。データ0件時は何も描かない(呼び出し側が status-empty を出す)。

import { isLightTheme } from './format.js';

const BAR_WIDTH = 20; // css px。90日分でも横スクロール前提のため詰めすぎない幅にする。
const BAR_GAP = 4;
const CHART_HEIGHT = 160; // css px
const AXIS_LABEL_HEIGHT = 20;

const CHART_COLORS = {
  dark: { good: '#2f9e63', warn: '#b8891f', bad: '#f2555a', empty: 'rgba(127, 127, 127, 0.25)', axis: 'rgba(255, 255, 255, 0.5)' },
  light: { good: '#30a46c', warn: '#e6a700', bad: '#e5484d', empty: 'rgba(127, 127, 127, 0.25)', axis: 'rgba(0, 0, 0, 0.5)' },
};

let currentDaily = [];
let canvas;
let tooltip;

function barColor(rate) {
  const palette = CHART_COLORS[isLightTheme() ? 'light' : 'dark'];
  if (rate >= 90) return palette.good;
  if (rate >= 70) return palette.warn;
  return palette.bad;
}

function successRate(day) {
  return day.total > 0 ? (day.passed / day.total) * 100 : null;
}

function setupCanvas(widthCss) {
  const dpr = window.devicePixelRatio || 1;
  const heightCss = CHART_HEIGHT + AXIS_LABEL_HEIGHT;
  canvas.style.width = widthCss + 'px';
  canvas.style.height = heightCss + 'px';
  canvas.width = Math.round(widthCss * dpr);
  canvas.height = Math.round(heightCss * dpr);
  const ctx = canvas.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  return ctx;
}

function shortDate(dateStr) {
  // "yyyy-MM-dd" -> "MM/DD"
  const parts = dateStr.split('-');
  return parts.length === 3 ? parts[1] + '/' + parts[2] : dateStr;
}

function draw() {
  if (!canvas || currentDaily.length === 0) {
    return;
  }
  const widthCss = currentDaily.length * (BAR_WIDTH + BAR_GAP) + BAR_GAP;
  const ctx = setupCanvas(widthCss);
  ctx.clearRect(0, 0, widthCss, CHART_HEIGHT + AXIS_LABEL_HEIGHT);

  const palette = CHART_COLORS[isLightTheme() ? 'light' : 'dark'];
  ctx.font = '9px var(--vscode-font-family, sans-serif)';
  ctx.textAlign = 'center';

  currentDaily.forEach((day, i) => {
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
    ctx.fillText(shortDate(day.date), x + BAR_WIDTH / 2, CHART_HEIGHT + 14);
  });
}

function barIndexAt(offsetX) {
  const index = Math.floor(offsetX / (BAR_WIDTH + BAR_GAP));
  return index >= 0 && index < currentDaily.length ? index : -1;
}

function handleMouseMove(event) {
  const rect = canvas.getBoundingClientRect();
  const index = barIndexAt(event.clientX - rect.left);
  if (index === -1) {
    tooltip.style.display = 'none';
    return;
  }
  const day = currentDaily[index];
  const rate = successRate(day);
  tooltip.textContent = day.date + ': ' + day.passed + '/' + day.total + ' passed' +
    (rate === null ? '(実行なし)' : '(' + rate.toFixed(1) + '%)') +
    (day.failed > 0 ? ' / 失敗 ' + day.failed : '');
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

  new MutationObserver(draw).observe(document.body, { attributes: true, attributeFilter: ['class'] });
}

export function renderDailyChart(daily) {
  currentDaily = daily;
  draw();
}
