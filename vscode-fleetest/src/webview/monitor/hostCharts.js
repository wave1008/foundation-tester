// hostMetrics受信毎に直近60サンプルのローリングバッファへ追加しcanvas再描画。webview側は
// 独自タイマーを持たない(更新頻度はCLI側 --interval 1 に完全依存)。他モジュールとの状態共有は無い。
//
// **行は機械ごと**(キーは機械名。手元は '')。リモート機のデバイスがモニターに居るときだけ
// 行が増え、左端に機械名(手元は "local")が出る(monitorProcessManager.ts が機械ごとに
// `remote exec <machine> -- api host-metrics` を立て、hostMetricsMachines で行の集合を配る)。
// 行の DOM は手元の行(monitorHtml.ts の data-machine="")を複製して作るので、**中の要素は
// data-metric で引く**(id は手元の行にしか無い)。
//
// FM系列だけは供給元が違う: hostMetricsストリーム(host-metricsプロセス)ではなく、
// シナリオ完了イベント(runEvent の passed/failed に載る fm)を recordFmCalls() で受ける。
// FM呼び出しは**その機械の中で**直列化する共有資源(実測: 並列度によらず約1回/秒で頭打ち)なので、
// 台数を増やしても総処理能力は増えない。実行時間への効き方を見るための系列。
// 他系列と時間軸を揃えるため、値は hostMetrics の tick ごとに「前tickからの増分」を積む。

import { t } from '../i18n.js';

const HM_MAX_SAMPLES = 60;
// バリデータ検証済みパレット(ダーク/ライトで系列色を切り替える。グリッド・軸は描かない)。
const HM_COLORS = {
  dark: { cpu: '#f2555a', gpu: '#b8891f', fm: '#a06be0', mem: '#2f9e63' },
  light: { cpu: '#e5484d', gpu: '#e6a700', fm: '#8e4ec6', mem: '#30a46c' },
};

/** 手元の行の表示名(左端のラベル)。CLI 側の DeviceMachineGrouping.localDisplayName と同じ語。 */
const HM_LOCAL_LABEL = 'local';

const hmContainer = document.getElementById('host-metrics');
const hmLocalRowEl = hmContainer.querySelector('.hm-row[data-machine=""]');

function hmIsLightTheme() {
  return document.body.classList.contains('vscode-light') ||
    document.body.classList.contains('vscode-high-contrast-light');
}

// countScale=true の系列は samples が「比率」ではなく「件数」。描画時にバッファ内の最大値で
// 正規化する(FM は上限が定義できないため。固定上限だと実測レンジで潰れて読めない)。
function hmMakeEntry(rowEl, metric, colorKey, countScale = false) {
  const el = rowEl.querySelector(`.host-metric[data-metric="${metric}"]`);
  return {
    el,
    canvas: el.querySelector('.hm-canvas'),
    value: el.querySelector('.hm-value'),
    colorKey,
    countScale,
    samples: [], // 直近 HM_MAX_SAMPLES 件。0..1 の比率(countScale なら件数)、欠測は null。
  };
}

// FM は割合ではなく件数。実行開始からの累計と、hostMetrics tick 間の増分を持つ。
// スパークラインは他系列と同じ 0..1 座標系なので、直近バッファ内の最大増分で正規化する
// (固定上限だと実測レンジ[0〜数件/秒]で潰れて読めないため)。
// failures は FM 死活の検知用。FM 失敗は呼び出し側(occlusion-guard/heal/screenLooksLike)が
// 握りつぶして素通りする契約なので、ここで可視化しないと全滅が正常時と区別できない。
function hmMakeRow(rowEl, machine) {
  const entries = {
    cpu: hmMakeEntry(rowEl, 'cpu', 'cpu'),
    gpu: hmMakeEntry(rowEl, 'gpu', 'gpu'),
    fm: hmMakeEntry(rowEl, 'fm', 'fm', true),
    mem: hmMakeEntry(rowEl, 'mem', 'mem'),
  };
  return {
    machine,
    el: rowEl,
    entries,
    all: [entries.cpu, entries.gpu, entries.fm, entries.mem],
    fm: { total: 0, totalMs: 0, failures: 0, pendingCalls: 0, lastDelta: 0 },
  };
}

/** 機械名(手元は '')→ 行。手元の行は静的 HTML にあるので最初から居る。 */
const hmRows = new Map([['', hmMakeRow(hmLocalRowEl, '')]]);

/** リモートの行があるときだけ左端の機械名を出す(CSS の .hm-multi)。 */
function hmSyncMultiClass() {
  hmContainer.classList.toggle('hm-multi', hmRows.size > 1);
}

/** 手元が先・以降は機械名順に並べ直す(appendChild は既存ノードでは移動として働く)。 */
function hmSortRows() {
  for (const machine of [...hmRows.keys()].filter((key) => key !== '').sort()) {
    hmContainer.appendChild(hmRows.get(machine).el);
  }
}

function hmEnsureRow(machine) {
  const existing = hmRows.get(machine);
  if (existing) {
    return existing;
  }
  // 手元の行を複製する(i18n 済みの title・ラベル・canvas 寸法をそのまま引き継ぐ)。
  // **id は落とす** —— 複製すると id が重複し、getElementById が手元の行を返さなくなる。
  const rowEl = hmLocalRowEl.cloneNode(true);
  rowEl.dataset.machine = machine;
  for (const withId of rowEl.querySelectorAll('[id]')) {
    withId.removeAttribute('id');
  }
  const label = rowEl.querySelector('.hm-machine');
  label.textContent = machine;
  label.title = machine;
  for (const value of rowEl.querySelectorAll('.hm-value')) {
    value.textContent = '–';
  }
  for (const metric of rowEl.querySelectorAll('.host-metric')) {
    metric.classList.remove('hm-fm-dead', 'hm-fm-warn');
  }
  hmContainer.appendChild(rowEl);
  const row = hmMakeRow(rowEl, machine);
  hmRows.set(machine, row);
  hmSortRows(); // サンプル先着で作られた行も並びは機械名順に保つ
  hmSyncMultiClass();
  return row;
}

/**
 * 行の集合を「手元 + 渡されたリモート機」に合わせる(monitorProcessManager.ts の
 * hostMetricsMachines メッセージ)。**消えた機械の行は捨てる** —— 観測が止まったまま
 * 最後の値を出し続けると、向こうが落ちているのに動いているように見える(リモートのタイルを
 * state:"unknown" に戻すのと同じ規律)。
 */
export function setHostMetricMachines(machines) {
  const wanted = [...new Set(machines.filter((m) => typeof m === 'string' && m !== ''))].sort();
  for (const [machine, row] of hmRows) {
    if (machine !== '' && !wanted.includes(machine)) {
      row.el.remove();
      hmRows.delete(machine);
    }
  }
  for (const machine of wanted) {
    hmEnsureRow(machine);
  }
  hmSortRows();
  hmSyncMultiClass();
}

// FMHealth.Snapshot.allFailed と同じ判定: 1回以上呼ばれ、かつ全て失敗
function fmIsDead(row) {
  return row.fm.failures > 0 && row.fm.failures >= row.fm.total;
}

/** 新しい実行の開始(runStarted → cleared)で累計を捨てる。これを呼ばないと
 *  パネルを開いている限り実行をまたいで積算され、「今回の実行の回数」に見えない。 */
export function resetFmUsage() {
  for (const row of hmRows.values()) {
    row.fm.total = 0;
    row.fm.totalMs = 0;
    row.fm.failures = 0;
    row.fm.pendingCalls = 0;
    row.fm.lastDelta = 0;
    row.entries.fm.samples.length = 0;
    hmRenderFmLabel(row);
    hmDraw(row, row.entries.fm);
  }
}

/** シナリオ完了イベント(runEvent)から FM 実測を受け取る。tick を待って系列へ積む。
 *  machine はそのシナリオを回したレーンの機械(手元は undefined。runLaneModel.ts の LaneInfo)。 */
export function recordFmCalls(calls, totalMs, failures, machine) {
  if (typeof calls !== 'number' || calls <= 0) {
    return;
  }
  const row = hmEnsureRow(typeof machine === 'string' ? machine : '');
  row.fm.total += calls;
  row.fm.pendingCalls += calls;
  if (typeof totalMs === 'number') {
    row.fm.totalMs += totalMs;
  }
  if (typeof failures === 'number' && failures > 0) {
    row.fm.failures += failures;
  }
  // 数値とツールチップはここで即時更新する。スパークラインだけは他系列と時間軸を揃えるため
  // hostMetrics の tick を待つ。tick 任せにすると host-metrics プロセスが落ちている間
  // 件数が全く出なくなる(FM の供給元は runEvent で、hostMetrics とは独立)
  hmRenderFmLabel(row);
}

/** ツールチップの先頭に付ける機械名(1行だけのときは付けない)。 */
function hmTitlePrefix(row) {
  return hmRows.size > 1 ? `${row.machine === '' ? HM_LOCAL_LABEL : row.machine} — ` : '';
}

function hmRenderFmLabel(row) {
  const entry = row.entries.fm;
  const dead = fmIsDead(row);
  const partial = !dead && row.fm.failures > 0;
  entry.el.classList.toggle('hm-fm-dead', dead);
  entry.el.classList.toggle('hm-fm-warn', partial);
  entry.value.textContent = (dead ? '✕' : partial ? '⚠' : '') + String(row.fm.total);
  let title = hmTitlePrefix(row) + t('wvMonitor2.hostCharts.fmTitle', {
    total: String(row.fm.total),
    totalSec: (row.fm.totalMs / 1000).toFixed(1),
    delta: String(row.fm.lastDelta),
  });
  if (dead) {
    title += '\n' + t('wvMonitor2.hostCharts.fmDeadLine', { failures: String(row.fm.failures) });
  } else if (partial) {
    title += '\n' + t('wvMonitor2.hostCharts.fmWarnLine', {
      failures: String(row.fm.failures),
      successes: String(row.fm.total - row.fm.failures),
    });
  }
  entry.el.title = title;
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

function hmDraw(row, entry) {
  const width = 72;
  const height = 22;
  const ctx = hmSetupCanvas(entry.canvas);
  ctx.clearRect(0, 0, width, height);
  const samples = entry.samples;
  if (samples.length < 2) {
    return;
  }
  const palette = HM_COLORS[hmIsLightTheme() ? 'light' : 'dark'];
  // FM 全滅中はスパークラインも失敗の系列だと分かるよう赤(cpu と同色)で描く
  const color = entry === row.entries.fm && fmIsDead(row) ? palette.cpu : palette[entry.colorKey];
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

  // machine 欄が無い行 = 手元(旧 CLI・手元の host-metrics プロセス)
  const row = hmEnsureRow(typeof message.machine === 'string' ? message.machine : '');
  hmPushSample(row.entries.cpu, typeof message.cpu === 'number' ? message.cpu : null);
  hmPushSample(row.entries.gpu, typeof message.gpu === 'number' ? message.gpu : null);
  // FM: この tick ぶんの増分を確定し、バッファ内の最大増分で正規化して積む
  const fmDelta = row.fm.pendingCalls;
  row.fm.pendingCalls = 0;
  row.fm.lastDelta = fmDelta;
  hmPushSample(row.entries.fm, fmDelta);
  hmPushSample(row.entries.mem, memRatio);

  row.entries.cpu.value.textContent = hmFormatPercent(message.cpu);
  row.entries.gpu.value.textContent = hmFormatPercent(message.gpu);
  row.entries.mem.value.textContent = hmFormatPercent(memRatio);

  const prefix = hmTitlePrefix(row);
  row.entries.cpu.el.title = prefix + t('wvMonitor2.hostCharts.cpuTitle', { value: hmFormatPercent(message.cpu) });
  row.entries.gpu.el.title = prefix + t('wvMonitor2.hostCharts.gpuTitle', { value: hmFormatPercent(message.gpu) });
  hmRenderFmLabel(row);
  row.entries.mem.el.title = prefix + t('wvMonitor2.hostCharts.memTitle', {
    used: hmFormatGb(message.memUsedBytes),
    total: hmFormatGb(message.memTotalBytes),
    percent: hmFormatPercent(memRatio),
  });

  for (const entry of row.all) {
    hmDraw(row, entry);
  }
}

// テーマ切替(body の class に vscode-light 等が付け外しされる)を検知して全グラフを再描画する。
new MutationObserver(() => {
  for (const row of hmRows.values()) {
    for (const entry of row.all) {
      hmDraw(row, entry);
    }
  }
}).observe(document.body, { attributes: true, attributeFilter: ['class'] });
