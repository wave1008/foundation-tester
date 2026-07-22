// hostMetrics受信毎に直近60サンプルのローリングバッファへ追加しcanvas再描画。webview側は
// 独自タイマーを持たない(更新頻度はCLI側 --interval 1 に完全依存)。他モジュールとの状態共有は無い。
//
// FM系列だけは供給元が違う: hostMetricsストリーム(host-metricsプロセス)ではなく、
// シナリオ完了イベント(runEvent の passed/failed に載る fm)を recordFmCalls() で受ける。
// FM呼び出しはホスト全体で直列化する共有資源(実測: 並列度によらず約1回/秒で頭打ち)なので、
// 台数を増やしても総処理能力は増えない。実行時間への効き方を見るための系列。
// 他系列と時間軸を揃えるため、値は hostMetrics の tick ごとに「前tickからの増分」を積む。

import { t } from '../i18n.js';

const HM_MAX_SAMPLES = 60;
// バリデータ検証済みパレット(ダーク/ライトで系列色を切り替える。グリッド・軸は描かない)。
const HM_COLORS = {
  dark: { cpu: '#f2555a', gpu: '#b8891f', fm: '#a06be0', mem: '#2f9e63' },
  light: { cpu: '#e5484d', gpu: '#e6a700', fm: '#8e4ec6', mem: '#30a46c' },
};

function hmIsLightTheme() {
  return document.body.classList.contains('vscode-light') ||
    document.body.classList.contains('vscode-high-contrast-light');
}

// countScale=true の系列は samples が「比率」ではなく「件数」。描画時にバッファ内の最大値で
// 正規化する(FM は上限が定義できないため。固定上限だと実測レンジで潰れて読めない)。
function hmMakeEntry(id, colorKey, countScale = false) {
  const el = document.getElementById(id);
  return {
    el,
    canvas: el.querySelector('.hm-canvas'),
    value: el.querySelector('.hm-value'),
    colorKey,
    countScale,
    samples: [], // 直近 HM_MAX_SAMPLES 件。0..1 の比率(countScale なら件数)、欠測は null。
  };
}

const hmEntries = {
  cpu: hmMakeEntry('hm-cpu', 'cpu'),
  gpu: hmMakeEntry('hm-gpu', 'gpu'),
  fm: hmMakeEntry('hm-fm', 'fm', true),
  mem: hmMakeEntry('hm-mem', 'mem'),
};
const HM_ALL_ENTRIES = [hmEntries.cpu, hmEntries.gpu, hmEntries.fm, hmEntries.mem];

// FM は割合ではなく件数。実行開始からの累計と、hostMetrics tick 間の増分を持つ。
// スパークラインは他系列と同じ 0..1 座標系なので、直近バッファ内の最大増分で正規化する
// (固定上限だと実測レンジ[0〜数件/秒]で潰れて読めないため)。
const fmState = { total: 0, totalMs: 0, pendingCalls: 0, lastDelta: 0 };

/** 新しい実行の開始(runStarted → cleared)で累計を捨てる。これを呼ばないと
 *  パネルを開いている限り実行をまたいで積算され、「今回の実行の回数」に見えない。 */
export function resetFmUsage() {
  fmState.total = 0;
  fmState.totalMs = 0;
  fmState.pendingCalls = 0;
  fmState.lastDelta = 0;
  hmEntries.fm.samples.length = 0;
  hmRenderFmLabel();
  hmDraw(hmEntries.fm);
}

/** シナリオ完了イベント(runEvent)から FM 実測を受け取る。tick を待って系列へ積む。 */
export function recordFmCalls(calls, totalMs) {
  if (typeof calls !== 'number' || calls <= 0) {
    return;
  }
  fmState.total += calls;
  fmState.pendingCalls += calls;
  if (typeof totalMs === 'number') {
    fmState.totalMs += totalMs;
  }
  // 数値とツールチップはここで即時更新する。スパークラインだけは他系列と時間軸を揃えるため
  // hostMetrics の tick を待つ。tick 任せにすると host-metrics プロセスが落ちている間
  // 件数が全く出なくなる(FM の供給元は runEvent で、hostMetrics とは独立)
  hmRenderFmLabel();
}

function hmRenderFmLabel() {
  hmEntries.fm.value.textContent = String(fmState.total);
  hmEntries.fm.el.title = t('wvMonitor2.hostCharts.fmTitle', {
    total: String(fmState.total),
    totalSec: (fmState.totalMs / 1000).toFixed(1),
    delta: String(fmState.lastDelta),
  });
}

function hmPushSample(entry, ratio) {
  entry.samples.push(ratio);
  if (entry.samples.length > HM_MAX_SAMPLES) {
    entry.samples.shift();
  }
}

// devicePixelRatioに合わせ実ピクセル数を上げ、ctx.scaleでCSS座標系のまま描画(にじみ防止)。
// width/height代入は毎回キャンバスをクリアするため、呼び出し側は直後に全内容を描き直すこと。
function hmSetupCanvas(canvas) {
  const dpr = window.devicePixelRatio || 1;
  const width = 72;
  const height = 22;
  canvas.width = Math.round(width * dpr);
  canvas.height = Math.round(height * dpr);
  const ctx = canvas.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  return ctx;
}

function hmDraw(entry) {
  const width = 72;
  const height = 22;
  const ctx = hmSetupCanvas(entry.canvas);
  ctx.clearRect(0, 0, width, height);
  const samples = entry.samples;
  if (samples.length < 2) {
    return;
  }
  const color = HM_COLORS[hmIsLightTheme() ? 'light' : 'dark'][entry.colorKey];
  // 件数系列はバッファ内の最大値を上端に取る(全て 0 のときは平坦に描く)
  const scale = entry.countScale
    ? Math.max(1, ...samples.filter((v) => v !== null))
    : 1;
  const stepX = width / (HM_MAX_SAMPLES - 1);
  // samplesは「直近N件」なので、60件溜まるまでは右詰めで配置する(新サンプルは常に右端)。
  const startIndex = HM_MAX_SAMPLES - samples.length;
  const points = samples.map((ratio, i) => ({
    x: (startIndex + i) * stepX,
    y: ratio === null ? null : height - (ratio / scale) * height,
  }));

  // null(欠測)のところで線を分割し、区間ごとに個別のパスとして描く。
  let segment = [];
  const flushSegment = () => {
    if (segment.length >= 2) {
      ctx.beginPath();
      ctx.moveTo(segment[0].x, segment[0].y);
      for (let i = 1; i < segment.length; i++) {
        ctx.lineTo(segment[i].x, segment[i].y);
      }
      ctx.lineWidth = 2;
      ctx.lineJoin = 'round';
      ctx.lineCap = 'round';
      ctx.strokeStyle = color;
      ctx.stroke();

      // 面塗り(線と同色、不透明度0.18)。線のstrokeとは別パスで塗りつぶす2パス目。
      ctx.beginPath();
      ctx.moveTo(segment[0].x, segment[0].y);
      for (let i = 1; i < segment.length; i++) {
        ctx.lineTo(segment[i].x, segment[i].y);
      }
      ctx.lineTo(segment[segment.length - 1].x, height);
      ctx.lineTo(segment[0].x, height);
      ctx.closePath();
      ctx.globalAlpha = 0.18;
      ctx.fillStyle = color;
      ctx.fill();
      ctx.globalAlpha = 1;
    }
    segment = [];
  };
  for (const point of points) {
    if (point.y === null) {
      flushSegment();
      continue;
    }
    segment.push(point);
  }
  flushSegment();
}

function hmFormatPercent(ratio) {
  return ratio === null || ratio === undefined ? '–' : Math.round(ratio * 100) + '%';
}

function hmFormatGb(bytes) {
  return bytes === null || bytes === undefined ? '–' : (bytes / (1024 * 1024 * 1024)).toFixed(1);
}

export function applyHostMetrics(message) {
  const memRatio =
    typeof message.memUsedBytes === 'number' &&
    typeof message.memTotalBytes === 'number' &&
    message.memTotalBytes > 0
      ? message.memUsedBytes / message.memTotalBytes
      : null;

  hmPushSample(hmEntries.cpu, typeof message.cpu === 'number' ? message.cpu : null);
  hmPushSample(hmEntries.gpu, typeof message.gpu === 'number' ? message.gpu : null);
  // FM: この tick ぶんの増分を確定し、バッファ内の最大増分で正規化して積む
  const fmDelta = fmState.pendingCalls;
  fmState.pendingCalls = 0;
  fmState.lastDelta = fmDelta;
  hmPushSample(hmEntries.fm, fmDelta);
  hmPushSample(hmEntries.mem, memRatio);

  hmEntries.cpu.value.textContent = hmFormatPercent(message.cpu);
  hmEntries.gpu.value.textContent = hmFormatPercent(message.gpu);
  hmEntries.mem.value.textContent = hmFormatPercent(memRatio);

  hmEntries.cpu.el.title = t('wvMonitor2.hostCharts.cpuTitle', { value: hmFormatPercent(message.cpu) });
  hmEntries.gpu.el.title = t('wvMonitor2.hostCharts.gpuTitle', { value: hmFormatPercent(message.gpu) });
  hmRenderFmLabel();
  hmEntries.mem.el.title = t('wvMonitor2.hostCharts.memTitle', {
    used: hmFormatGb(message.memUsedBytes),
    total: hmFormatGb(message.memTotalBytes),
    percent: hmFormatPercent(memRatio),
  });

  for (const entry of HM_ALL_ENTRIES) {
    hmDraw(entry);
  }
}

// テーマ切替(body の class に vscode-light 等が付け外しされる)を検知して全グラフを再描画する。
new MutationObserver(() => {
  for (const entry of HM_ALL_ENTRIES) {
    hmDraw(entry);
  }
}).observe(document.body, { attributes: true, attributeFilter: ['class'] });
