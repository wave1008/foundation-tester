// hostMetrics受信毎に直近60サンプルのローリングバッファへ追加しcanvas再描画。webview側は
// 独自タイマーを持たない(更新頻度はCLI側 --interval 1 に完全依存)。他モジュールとの状態共有は無い。

const HM_MAX_SAMPLES = 60;
// バリデータ検証済みパレット(ダーク/ライトで系列色を切り替える。グリッド・軸は描かない)。
const HM_COLORS = {
  dark: { cpu: '#f2555a', gpu: '#b8891f', ane: '#a06be0', mem: '#2f9e63' },
  light: { cpu: '#e5484d', gpu: '#e6a700', ane: '#8e4ec6', mem: '#30a46c' },
};

function hmIsLightTheme() {
  return document.body.classList.contains('vscode-light') ||
    document.body.classList.contains('vscode-high-contrast-light');
}

function hmMakeEntry(id, colorKey) {
  const el = document.getElementById(id);
  return {
    el,
    canvas: el.querySelector('.hm-canvas'),
    value: el.querySelector('.hm-value'),
    colorKey,
    samples: [], // 直近 HM_MAX_SAMPLES 件。要素は 0..1 の比率、または欠測を表す null。
  };
}

const hmEntries = {
  cpu: hmMakeEntry('hm-cpu', 'cpu'),
  gpu: hmMakeEntry('hm-gpu', 'gpu'),
  ane: hmMakeEntry('hm-ane', 'ane'),
  mem: hmMakeEntry('hm-mem', 'mem'),
};
const HM_ALL_ENTRIES = [hmEntries.cpu, hmEntries.gpu, hmEntries.ane, hmEntries.mem];

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
  const stepX = width / (HM_MAX_SAMPLES - 1);
  // samplesは「直近N件」なので、60件溜まるまでは右詰めで配置する(新サンプルは常に右端)。
  const startIndex = HM_MAX_SAMPLES - samples.length;
  const points = samples.map((ratio, i) => ({
    x: (startIndex + i) * stepX,
    y: ratio === null ? null : height - ratio * height,
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
  hmPushSample(hmEntries.ane, typeof message.ane === 'number' ? message.ane : null);
  hmPushSample(hmEntries.mem, memRatio);

  hmEntries.cpu.value.textContent = hmFormatPercent(message.cpu);
  hmEntries.gpu.value.textContent = hmFormatPercent(message.gpu);
  hmEntries.ane.value.textContent = hmFormatPercent(message.ane);
  hmEntries.mem.value.textContent = hmFormatPercent(memRatio);

  hmEntries.cpu.el.title = 'CPU負荷 ' + hmFormatPercent(message.cpu);
  hmEntries.gpu.el.title = 'GPU負荷 ' + hmFormatPercent(message.gpu);
  hmEntries.ane.el.title = 'ANE負荷 ' + hmFormatPercent(message.ane) +
    (typeof message.aneWatts === 'number' ? '(' + message.aneWatts.toFixed(1) + 'W)' : '');
  hmEntries.mem.el.title = 'メモリ使用量 ' + hmFormatGb(message.memUsedBytes) + ' / ' +
    hmFormatGb(message.memTotalBytes) + ' GB(' + hmFormatPercent(memRatio) + ')';

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
