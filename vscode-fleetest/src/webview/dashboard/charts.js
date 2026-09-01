// 日別成功率チャート(daily を棒グラフで描画。hostCharts.js と同じ自前 canvas 流儀・
// 依存ライブラリなし)。データ0件時は何も描かない(呼び出し側が status-empty を出す)。

import { isLightTheme } from './format.js';
import { t } from '../i18n.js';

const BAR_WIDTH = 20; // css px。90日分でも横スクロール前提のため詰めすぎない幅にする。
const BAR_GAP = 4;
const CHART_HEIGHT = 160; // css px
// ◀▶ ボタンは棒の領域の下 1/3(ユーザー決定)。◀ は縦軸の列で軸名の下、▶ は右のガター。
// 軸名はボタンの上の領域(上 2/3)の中央に描く = 「軸名の下にボタン」が重ならず成り立つ
const SCROLL_BUTTON_HEIGHT = CHART_HEIGHT / 3;
// ◀ は縦軸の列に置くので、列の幅はボタン幅を下回らないようにする(目盛りラベルに食い込まない)
const SCROLL_BUTTON_WIDTH = 22;
// 軸ラベルは横書きが既定。最長ラベルの実測幅(measureText)が1本ぶんの幅(BAR_WIDTH + BAR_GAP)に
// 収まらないときだけ縦書き(-90°)にする(棒幅 20px に "M/D" は重なる。棒幅は変えない = ユーザー決定)。
// ラベル領域の高さは固定せず、横書きならフォントの高さ、縦書きなら最長ラベルの幅から決める
const AXIS_LABEL_FONT = '9px var(--vscode-font-family, sans-serif)';
const AXIS_LABEL_GAP = 4; // 棒の下端からラベルまで / ラベル下の余白(css px)
// 縦軸(成功率 %)。目盛りは 0/25/50/75/100 で、棒側には同じ高さに薄い水平線を引く。
// 軸は横スクロールする棒の canvas とは別の canvas(#daily-chart-axis)に描き、左に固定する
const Y_TICKS = [0, 25, 50, 75, 100];
const Y_AXIS_GAP = 4; // 目盛りラベルと棒領域の間 / 軸名と目盛りラベルの間(css px)

const CHART_COLORS = {
  dark: { good: '#2f9e63', warn: '#b8891f', bad: '#f2555a', empty: 'rgba(127, 127, 127, 0.25)', axis: 'rgba(255, 255, 255, 0.5)', grid: 'rgba(255, 255, 255, 0.12)' },
  light: { good: '#30a46c', warn: '#e6a700', bad: '#e5484d', empty: 'rgba(127, 127, 127, 0.25)', axis: 'rgba(0, 0, 0, 0.5)', grid: 'rgba(0, 0, 0, 0.12)' },
};

let currentDaily = [];
let canvas;
let axisCanvas;
let chartWrap;
/** 次に表示されたとき右端(最新日)へ寄せる。データ受信時にタブが display:none だと
 * scrollWidth が 0 で寄せられないので、表示された時点(ft-tab-activated)まで持ち越す */
let scrollToEndPending = false;
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

function setupCanvas(target, widthCss, heightCss) {
  const dpr = window.devicePixelRatio || 1;
  target.style.width = widthCss + 'px';
  target.style.height = heightCss + 'px';
  target.width = Math.round(widthCss * dpr);
  target.height = Math.round(heightCss * dpr);
  const ctx = target.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  return ctx;
}

function yOf(rate) {
  return CHART_HEIGHT - (rate / 100) * CHART_HEIGHT;
}

/** 左の固定 canvas に目盛りラベル(右揃え)と軸名(縦書き)を描く。高さは棒側と同じにして
 * 目盛りの高さ = 棒側の水平線の高さ(yOf)にする */
function drawAxis(heightCss, palette) {
  const measureCtx = axisCanvas.getContext('2d');
  measureCtx.font = AXIS_LABEL_FONT;
  const tickWidths = Y_TICKS.map((v) => measureCtx.measureText(v + '%').width);
  const tickWidth = Math.ceil(Math.max(...tickWidths));
  const title = t('wvDashboard.chart.yAxisTitle');
  const titleMetrics = measureCtx.measureText(title);
  const titleHeight = Math.ceil(titleMetrics.actualBoundingBoxAscent + titleMetrics.actualBoundingBoxDescent);
  // ◀ は下 1/3 の段に居るので、横に並ぶのはその段の目盛り(0%・25%)だけ。ラベルは右揃えで
  // 「100%」より短いぶん左に空きができるため、ボタンの右端は**その段で最も長いラベルの左端から
  // Y_AXIS_GAP** に置く(全ラベルの最大幅を基準にすると 1 文字ぶん余計に空く。2026-09-01 指摘)
  const buttonTop = CHART_HEIGHT - SCROLL_BUTTON_HEIGHT;
  const besideButton = Math.ceil(Math.max(0, ...Y_TICKS
    .filter((v) => yOf(v) >= buttonTop)
    .map((v) => tickWidths[Y_TICKS.indexOf(v)])));
  // 幅 = 軸名の列(縦書き = 高さぶん)+ 余白 + ラベル幅、ただしボタン + 余白 + 隣のラベル + 余白は下回らない
  const widthCss = Math.max(
    titleHeight + Y_AXIS_GAP + tickWidth + Y_AXIS_GAP,
    SCROLL_BUTTON_WIDTH + Y_AXIS_GAP + besideButton + Y_AXIS_GAP);
  const titleColumn = widthCss - Y_AXIS_GAP - tickWidth;
  scrollButtons.left.style.left = (widthCss - Y_AXIS_GAP - besideButton - Y_AXIS_GAP - SCROLL_BUTTON_WIDTH) + 'px';
  const ctx = setupCanvas(axisCanvas, widthCss, heightCss);
  ctx.clearRect(0, 0, widthCss, heightCss);
  ctx.font = AXIS_LABEL_FONT;
  ctx.fillStyle = palette.axis;
  ctx.textAlign = 'right';
  ctx.textBaseline = 'middle';
  for (const value of Y_TICKS) {
    // 端の目盛り(0/100)は半分はみ出るので中へ寄せる
    const y = Math.min(CHART_HEIGHT - titleHeight / 2, Math.max(titleHeight / 2, yOf(value)));
    ctx.fillText(value + '%', widthCss - Y_AXIS_GAP, y);
  }
  ctx.save();
  ctx.translate(titleColumn / 2, (CHART_HEIGHT - SCROLL_BUTTON_HEIGHT) / 2);
  ctx.rotate(-Math.PI / 2);
  ctx.textAlign = 'center';
  ctx.fillText(title, 0, 0);
  ctx.restore();
}

function shortDate(dateStr) {
  // "yyyy-MM-dd" -> "M/D"(先頭の 0 は落とす。"07/23" → "7/23")
  const parts = dateStr.split('-');
  return parts.length === 3 ? String(Number(parts[1])) + '/' + String(Number(parts[2])) : dateStr;
}

function draw() {
  const daily = currentDaily;
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
  const ctx = setupCanvas(canvas, widthCss, heightCss);
  ctx.clearRect(0, 0, widthCss, heightCss);

  const palette = CHART_COLORS[isLightTheme() ? 'light' : 'dark'];
  drawAxis(heightCss, palette);
  // 目盛りの水平線(棒より先に描いて棒の下に敷く。0% は棒の下端と重なるので省く)
  ctx.strokeStyle = palette.grid;
  ctx.lineWidth = 1;
  for (const value of Y_TICKS) {
    if (value === 0) continue;
    const y = Math.round(yOf(value)) + 0.5;
    ctx.beginPath();
    ctx.moveTo(0, y);
    ctx.lineTo(widthCss, y);
    ctx.stroke();
  }
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
  const daily = currentDaily;
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
  const day = currentDaily[index];
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

/** 続きがある側の端にフェードを出す(CSS の .can-scroll-left / -right)。
 * ::before/::after は sticky ではないので、位置は wrap 基準 = スクロールしても端に留まる */
function updateScrollHints() {
  const maxLeft = chartWrap.scrollWidth - chartWrap.clientWidth;
  const canLeft = chartWrap.scrollLeft > 0;
  const canRight = chartWrap.scrollLeft < maxLeft - 1;
  chartWrap.classList.toggle('can-scroll-left', canLeft);
  chartWrap.classList.toggle('can-scroll-right', canRight);
  // ◀▶ は常時表示。続きが無い側は disabled(薄く)
  scrollButtons.left.disabled = !canLeft;
  scrollButtons.right.disabled = !canRight;
}

const scrollButtons = { left: null, right: null };
// 押しっぱなしの連続移動: クリック(短押し)は1本ぶん、HOLD_DELAY_MS を超えて押し続けると
// 1フレームごとに HOLD_STEP_PX 進む。HOLD_DELAY_MS はキーリピートの開始遅延と同程度
// (macOS 既定 ≈ 225〜250ms)= 「クリックのつもり」を連続移動に誤認しない下限。
// HOLD_STEP_PX = 1本の幅の 1/3(60fps で約 20 本/秒。1日ずつ目で追える上限あたり)
const HOLD_DELAY_MS = 250;
const HOLD_STEP_PX = (BAR_WIDTH + BAR_GAP) / 3;
let holdTimer = null;
let holdFrame = null;

function stopHold() {
  if (holdTimer !== null) {
    clearTimeout(holdTimer);
    holdTimer = null;
  }
  if (holdFrame !== null) {
    cancelAnimationFrame(holdFrame);
    holdFrame = null;
  }
}

function startHold(direction) {
  stopHold();
  chartWrap.scrollLeft += direction * (BAR_WIDTH + BAR_GAP);
  holdTimer = setTimeout(() => {
    holdTimer = null;
    const step = () => {
      chartWrap.scrollLeft += direction * HOLD_STEP_PX;
      holdFrame = requestAnimationFrame(step);
    };
    holdFrame = requestAnimationFrame(step);
  }, HOLD_DELAY_MS);
}

function bindScrollButton(button, direction) {
  button.addEventListener('mousedown', (event) => {
    if (event.button !== 0) return;
    event.preventDefault(); // 長押しでテキスト選択やフォーカス移動を起こさない
    startHold(direction);
  });
  for (const type of ['mouseup', 'mouseleave']) {
    button.addEventListener(type, stopHold);
  }
  // ボタンの外で離されたときも止める(mouseleave で止まるが、念のため文書側でも)
  window.addEventListener('mouseup', stopHold);
}

/** レイアウトが確定している(= 表示中)ときだけ、持ち越した右端寄せとフェード判定を行う。
 * 非表示(clientWidth 0)なら何もせず、次の表示(ft-tab-activated)で再試行する */
function syncScrollAfterLayout() {
  if (!chartWrap || chartWrap.clientWidth === 0) {
    return;
  }
  if (scrollToEndPending) {
    chartWrap.scrollLeft = chartWrap.scrollWidth;
    scrollToEndPending = false;
  }
  updateScrollHints();
}

export function initDailyChart() {
  canvas = document.getElementById('daily-chart');
  axisCanvas = document.getElementById('daily-chart-axis');
  chartWrap = canvas.parentElement;
  chartWrap.addEventListener('scroll', updateScrollHints);
  scrollButtons.left = document.getElementById('daily-scroll-left');
  scrollButtons.right = document.getElementById('daily-scroll-right');
  bindScrollButton(scrollButtons.left, -1);
  bindScrollButton(scrollButtons.right, 1);
  for (const button of [scrollButtons.left, scrollButtons.right]) {
    button.style.top = (CHART_HEIGHT - SCROLL_BUTTON_HEIGHT) + 'px';
    button.style.height = SCROLL_BUTTON_HEIGHT + 'px';
    button.style.width = SCROLL_BUTTON_WIDTH + 'px';
  }
  // 縦ホイール(マウス)を横スクロールへ。横成分があるトラックパッド操作はそのまま通す
  chartWrap.addEventListener('wheel', (event) => {
    if (Math.abs(event.deltaX) >= Math.abs(event.deltaY)) {
      return;
    }
    const maxLeft = chartWrap.scrollWidth - chartWrap.clientWidth;
    if (maxLeft <= 0) {
      return;
    }
    chartWrap.scrollLeft += event.deltaY;
    event.preventDefault();
  }, { passive: false });
  // 幅はペイン(ウィンドウ)の幅に追従する。ResizeObserver は jsdom(webview テスト)に無いので使わない
  window.addEventListener('resize', updateScrollHints);
  // モニターはデバイスタブで開くので、データはダッシュボードが非表示のうちに届くことが多い
  // (tabs.js の switchTab が display を切り替えた直後にこのイベントを出す)
  document.addEventListener('ft-tab-activated', (event) => {
    if (event.detail && event.detail.tab === 'dashboard') {
      syncScrollAfterLayout();
    }
  });
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
  // 見るべきは最新日なので右端へ(テーマ切替の再描画では位置を保つ = ここだけ)
  scrollToEndPending = true;
  syncScrollAfterLayout();
}
