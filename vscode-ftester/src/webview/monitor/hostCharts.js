// hostCharts.js
// ツールバーのミニグラフ(CPU/GPU/ANE/メモリ)を担う。Phase 3(main.js のモジュール分割)で
// main.js の「---- ホストメトリクス(ツールバーのミニグラフ) ----」節から抽出した。
// host-metrics プロセス(拡張側が1秒間隔で常駐 spawn)からの hostMetrics メッセージ受信の
// たびに、直近60サンプルのローリングバッファへ追加して canvas に再描画する。webview 側は
// 独自のタイマーを持たない(更新頻度は完全に CLI 側の --interval 1 に駆動される)。
// 他モジュールとの状態共有は無く、DOM 参照(#hm-cpu 等)もこのモジュール内で完結する。

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

// canvas は CSS 上 72x22px 固定。devicePixelRatio に合わせて実ピクセル数(width/height 属性)を
// 上げてから ctx.scale で以後の描画を CSS ピクセル座標系のまま書けるようにする(にじみ防止)。
// width/height 属性への代入は毎回キャンバスの内容をクリアするので、呼び出し側は直後に
// 全内容を描き直すこと。
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
  // samples は「直近 N 件」なので、まだ60件溜まっていない間は右詰めで配置する
  // (新しいサンプルは常に右端、満杯になった後は左へスクロールしていく見た目になる)。
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

      // 下側の面塗り(線と同色、不透明度 0.18)。
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
