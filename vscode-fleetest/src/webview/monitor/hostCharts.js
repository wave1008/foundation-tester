// hostMetrics を受けたら直近60サンプルのローリングバッファへ追加しcanvas再描画。webview側は
// 独自タイマーを持たない(更新頻度はCLI側 --interval 1 に完全依存)。他モジュールとの状態共有は無い。
//
// **描く瞬間は全行で1つ**(hmClock)。機械ごとに host-metrics の子が独立して刻むので、届いた
// 順に行を書き換えると行ごとにばらばらの瞬間で動いてちらつく。リモートのサンプルは受信時には
// 保持するだけで、手元の tick で全行まとめて描く。**そのとき使うのは保持済みの最新値だけ**で、
// 描画のために問い合わせ直すことはしない(1秒の刻みに間に合わない)。
//
// **行は機械ごと**(キーは機械名。手元は '')。リモート機のデバイスがモニターに居るときだけ
// 行が増え、左端に機械名(手元は "local")が出る(monitorProcessManager.ts が機械ごとに
// `remote exec <machine> -- api host-metrics` を立て、hostMetricsMachines で行の集合を配る)。
// 行の DOM は手元の行(monitorHtml.ts の data-machine="")を複製して作るので、**中の要素は
// data-metric で引く**(id は手元の行にしか無い)。
//
// FM系列も他と同じ hostMetrics ストリームから来る(host-metrics プロセス自身は FM を叩かない ——
// FM を呼んだ側のプロセスが `~/.fleetest/fm-usage/<pid>.json` に置いた控えを、host-metrics が
// 毎 tick 読んで集計する。Sources 側の詳細は関知しない)。run の FM 呼び出しは
// FTCore の FMGate/FMLock が**ホスト全体で1件ずつに直列化する**ので実測は約1回/秒に張り付き、
// 生の1秒差分は 0/1 の二値になって読めない。表示は直近 HM_FM_RATE_WINDOW_TICKS tick の
// 移動窓平均(回/秒)。**この約1回/秒は FM の能力ではなくこちらのロックの上限**で、門を通らない
// 呼び出し(`doctor --fm-load`)は数倍出る —— だからスパークラインに固定上限を置かない。

import { t } from '../i18n.js';
import { setHoverTip } from './hoverTip.js';

const HM_MAX_SAMPLES = 60;
// 手元の tick が途絶えたとみなすまでの猶予(ms)。手元の host-metrics 子が落ちてから自動再起動
// までの待ち(monitorProcessManager.ts scheduleHostMetricsRestart の 5000ms)と同値 —— これを
// 超えて手元が無音なら、手元は止まっているとみなして刻みをリモートへ委譲する。
const HM_CLOCK_TAKEOVER_MS = 5000;
// 保持したサンプルを何 tick まで使い回してよいか。両側とも --interval 1 なので、生きている機械が
// 位相のずれで落とせるのは1 tick まで。これを超えたら観測が途絶えたとみなし欠測(–)にする。
const HM_STALE_TICKS = 2;
// FM のレート表示の移動窓(tick 数)。host-metrics --interval は 1 固定(monitorProcessManager.ts
// startHostMetricsProcess)なので 1 tick = 1 秒とみなせる。run の FM は直列化で約1回/秒に
// 張り付き、生の1秒差分は 0/1 の二値になり読めないため、10 tick(=10秒)の移動窓平均にして
// 0.1 刻みで見えるようにする。
const HM_FM_RATE_WINDOW_TICKS = 10;
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
// 正規化する(FM は上限が定義できないため。固定上限だと実測レンジで潰れて読めない)
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
    // FM のレート表示・死活判定に使う直近 HM_FM_RATE_WINDOW_TICKS tick ぶんの生値
    // ({calls,failures,totalMs} | 欠測は calls:null)。古い順に shift する。
    fm: { window: [] },
    // pending: 受信済みでまだ描いていないサンプル(1 tick の間に複数届いたら最後の1つだけ残る)。
    // latest: 直近に描いたサンプル(pending が無い tick はこれを使い回す)。missed はその回数。
    pending: undefined,
    latest: null,
    missed: 0,
  };
}

/**
 * 全行を描く刻みを刻む機械(既定は手元)。手元が HM_CLOCK_TAKEOVER_MS 以上無音のときだけ、
 * 最初にサンプルを届けたリモート機へ委譲する(手元のサンプルが来たら必ず手元へ戻す)。
 */
let hmClock = '';
/** 直近の一斉描画の時刻(ms)。委譲の判定にだけ使う。パネルを開いた時刻から数える。 */
let hmLastCommitAt = Date.now();

/** 機械名(手元は '')→ 行。手元の行は静的 HTML にあるので最初から居る。 */
const hmRows = new Map([['', hmMakeRow(hmLocalRowEl, '')]]);
/** 機械ごとの占有(錠前)。**行より先に届く**ので、行の有無と独立に持つ(setMachineLock 参照)。 */
const hmLocks = new Map();

/** リモートの行があるときだけ左端の機械名を出す(CSS の .hm-multi)。 */
function hmSyncMultiClass() {
  hmContainer.classList.toggle('hm-multi', hmRows.size > 1);
}

/**
 * その機械で誰かの run が走っていることを、機械名の隣の錠前で出す(docs/remote-runner.md §18.2)。
 * **出るのは「占有中」のときだけ**(空きは無印)。ライブ配信はこの間ホスト側で畳まれ、タイルは
 * ポーリングで更新され続ける ―― その理由が画面のどこにも無いと「映像が止まった」に見える。
 * 対向: monitorProcessManager.ts の machineLock メッセージ。
 */
export function setMachineLock(machine, held, issuer, mine) {
  const key = typeof machine === 'string' ? machine : '';
  // **控えは行より先に来る**(ランナー機の子は最初のサイクルで占有を出すので、行を作る
  // hostMetricsMachines より前に届きうる)。行が無いからと捨てると、**実行中に
  // モニターを開いた人には錠前が出ない**まま配信だけ止まる ―― 覚えておいて行の生成時に貼る。
  if (held) {
    hmLocks.set(key, { issuer, mine });
  } else {
    hmLocks.delete(key);
  }
  const row = hmRows.get(key);
  if (row) {
    hmApplyLock(row, key);
  }
}

/**
 * 控え(hmLocks)を1行へ反映する。**要素は足しも消しもしない** —— 枠は monitorHtml.ts が
 * 全行に置いてあり、ここは可視性と説明文だけを切り替える(足し引きすると、その行だけ幅が
 * 変わって MEM/CPU/… の列が行ごとにずれる。2026-08-31 の実害)。
 */
function hmApplyLock(row, machine) {
  const chip = row.el.querySelector('.hm-lock');
  if (!chip) {
    return;
  }
  const lock = hmLocks.get(machine);
  chip.classList.toggle('hm-lock-on', !!lock);
  // **説明はタイルと同じ自前ツールチップ**(0.2 秒)。ネイティブ `title` は遅延が約1秒で
  // 指定できず、この錠前のような小さい的では「乗せても何も出ない」に見える(2026-08-31 の指摘)
  setHoverTip(chip, lock
    ? (lock.mine
      ? t('wvMonitor2.hostCharts.lockMine', { machine })
      : t('wvMonitor2.hostCharts.lockOther', {
        machine, issuer: lock.issuer || t('wvMonitor2.hostCharts.lockIssuerUnknown'),
      }))
    : '');
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
  hmApplyLock(row, machine);   // 行より先に届いていた占有をここで貼る
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
      hmLocks.delete(machine);   // 行ごと消えた機械の控えは残さない
    }
  }
  for (const machine of wanted) {
    hmEnsureRow(machine);
  }
  hmSortRows();
  hmSyncMultiClass();
}

/** row.fm.window(直近 HM_FM_RATE_WINDOW_TICKS tick)を集計する。窓内が全て欠測(calls:null)
 *  なら null を返す(呼び出し側はこれを「不明」= 表示 '–' の合図にする。0件は別に区別できる —
 *  欠測でない tick は calls が数値、0 も含む)。 */
function hmFmWindowStats(row) {
  const known = row.fm.window.filter((tick) => tick.calls !== null);
  if (known.length === 0) {
    return null;
  }
  const calls = known.reduce((sum, tick) => sum + tick.calls, 0);
  const failures = known.reduce((sum, tick) => sum + (tick.failures ?? 0), 0);
  const totalMs = known.reduce((sum, tick) => sum + (tick.totalMs ?? 0), 0);
  // 分母は**観測できた tick 数**であって窓の長さではない。欠測 tick(サンプルを落とした・
  // 控えを読めなかった)を分母に入れると、それを「呼び出し0件」として平均に混ぜることになり、
  // 取りこぼしのたびにレートが静かに小さく出る(不明と0件を混ぜない)。
  return { calls, failures, totalMs, rate: calls / known.length };
}

// FMHealth.Snapshot.allFailed と同じ判定: 1回以上呼ばれ、かつ全て失敗(窓内で判定)
function fmIsDead(row) {
  const stats = hmFmWindowStats(row);
  return !!stats && stats.failures > 0 && stats.failures >= stats.calls;
}

/** ツールチップの先頭に付ける機械名(1行だけのときは付けない)。 */
function hmTitlePrefix(row) {
  return hmRows.size > 1 ? `${row.machine === '' ? HM_LOCAL_LABEL : row.machine} — ` : '';
}

function hmRenderFmLabel(row) {
  const entry = row.entries.fm;
  const stats = hmFmWindowStats(row);
  const dead = fmIsDead(row);
  const partial = !!stats && !dead && stats.failures > 0;
  entry.el.classList.toggle('hm-fm-dead', dead);
  entry.el.classList.toggle('hm-fm-warn', partial);
  const rateText = stats ? `${stats.rate.toFixed(1)}/s` : '–';
  entry.value.textContent = (dead ? '✕' : partial ? '⚠' : '') + rateText;
  let title = hmTitlePrefix(row) + t('wvMonitor2.hostCharts.fmTitle', {
    seconds: String(HM_FM_RATE_WINDOW_TICKS),
    rate: stats ? stats.rate.toFixed(1) : '–',
    calls: stats ? String(stats.calls) : '–',
    failures: stats ? String(stats.failures) : '–',
    totalSec: stats ? (stats.totalMs / 1000).toFixed(1) : '–',
  });
  if (dead) {
    title += '\n' + t('wvMonitor2.hostCharts.fmDeadLine', {
      seconds: String(HM_FM_RATE_WINDOW_TICKS), failures: String(stats.failures) });
  } else if (partial) {
    title += '\n' + t('wvMonitor2.hostCharts.fmWarnLine', {
      seconds: String(HM_FM_RATE_WINDOW_TICKS),
      failures: String(stats.failures),
      successes: String(stats.calls - stats.failures),
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
  // 件数系列(FM)はバッファ内の最大値で正規化する。全部0のときは0で割らない
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

/**
 * host-metrics の1サンプルを受け取る。**ここでは保持するだけ**で、描画は刻み(hmClock)を持つ
 * 機械のサンプルが来た tick に全行まとめて行う。machine 欄が無い行 = 手元(旧 CLI・手元の子)。
 */
export function applyHostMetrics(message) {
  const machine = typeof message.machine === 'string' ? message.machine : '';
  const row = hmEnsureRow(machine);
  row.pending = message;
  if (machine === '') {
    hmClock = ''; // 手元が復活したら刻みは必ず手元へ戻す
  } else if (machine !== hmClock && Date.now() - hmLastCommitAt > HM_CLOCK_TAKEOVER_MS) {
    hmClock = machine; // 手元が黙っている間もリモートの行を止めない
  }
  if (machine === hmClock) {
    hmCommitTick();
  }
}

/** 全行を1度に描き直す(値・ツールチップ・スパークライン)。 */
function hmCommitTick() {
  hmLastCommitAt = Date.now();
  for (const row of hmRows.values()) {
    hmCommitRow(row);
  }
}

/** この tick でその行に使うサンプルを決めて描く。保持済みが無ければ直近の値を使い回し、
 *  それも HM_STALE_TICKS を超えたら欠測にする(観測が途絶えた行に古い値を出し続けない)。 */
function hmCommitRow(row) {
  if (row.pending) {
    row.latest = row.pending;
    row.pending = undefined;
    row.missed = 0;
  } else if (row.latest !== null && ++row.missed > HM_STALE_TICKS) {
    row.latest = null;
  }
  hmRenderRow(row, row.latest);
}

/** sample が null の tick は行全体が欠測(値は '–'、全系列 null)。FM の欠測はフィールド単位でも
 *  起こる(その tick だけ控えを読めなかった)ので、sample 自体は非 null でも fmCalls は null になりうる。 */
function hmRenderRow(row, sample) {
  const cpu = sample && typeof sample.cpu === 'number' ? sample.cpu : null;
  const gpu = sample && typeof sample.gpu === 'number' ? sample.gpu : null;
  const memUsedBytes = sample && typeof sample.memUsedBytes === 'number' ? sample.memUsedBytes : null;
  const memTotalBytes = sample && typeof sample.memTotalBytes === 'number' ? sample.memTotalBytes : null;
  const memRatio = memUsedBytes !== null && memTotalBytes !== null && memTotalBytes > 0
    ? memUsedBytes / memTotalBytes
    : null;
  const fmCalls = sample && typeof sample.fmCalls === 'number' ? sample.fmCalls : null;
  const fmFailures = sample && typeof sample.fmFailures === 'number' ? sample.fmFailures : null;
  const fmTotalMs = sample && typeof sample.fmTotalMs === 'number' ? sample.fmTotalMs : null;

  hmPushSample(row.entries.cpu, cpu);
  hmPushSample(row.entries.gpu, gpu);
  row.fm.window.push({ calls: fmCalls, failures: fmFailures, totalMs: fmTotalMs });
  if (row.fm.window.length > HM_FM_RATE_WINDOW_TICKS) {
    row.fm.window.shift();
  }
  // FM は他の3系列と違い**割合ではなく件数**なので、固定の上限を置かない。
  // production の run は FMGate/FMLock で1件ずつに直列化されるので実測は約1回/秒に張り付くが、
  // 門を通らない呼び出し(doctor --fm-load)は数倍出る。固定上限だとどちらかが必ず潰れて読めない。
  // 描画時にバッファ内の最大値で正規化する(hmDraw の countScale)
  hmPushSample(row.entries.fm, fmCalls);
  hmPushSample(row.entries.mem, memRatio);

  row.entries.cpu.value.textContent = hmFormatPercent(cpu);
  row.entries.gpu.value.textContent = hmFormatPercent(gpu);
  row.entries.mem.value.textContent = hmFormatPercent(memRatio);

  const prefix = hmTitlePrefix(row);
  row.entries.cpu.el.title = prefix + t('wvMonitor2.hostCharts.cpuTitle', { value: hmFormatPercent(cpu) });
  row.entries.gpu.el.title = prefix + t('wvMonitor2.hostCharts.gpuTitle', { value: hmFormatPercent(gpu) });
  hmRenderFmLabel(row);
  row.entries.mem.el.title = prefix + t('wvMonitor2.hostCharts.memTitle', {
    used: hmFormatGb(memUsedBytes),
    total: hmFormatGb(memTotalBytes),
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
