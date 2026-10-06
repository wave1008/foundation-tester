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
// FM/Vision系列も他と同じ hostMetrics ストリームから来る(host-metrics プロセス自身はどちらも
// 叩かない —— 呼んだ側のプロセスが `~/.fleetest/fm-usage/<pid>.json` /
// `~/.fleetest/vision-usage/<pid>.json`(OCR・画像分類器)に置いた控えを、host-metrics が毎 tick 読んで集計する。
// Sources 側の詳細は関知しない)。run の FM
// 呼び出しは FTCore の FMGate/FMLock が**ホスト全体で枠の数まで**に絞るので、生の1秒差分は
// 小さな整数になって読めない。表示は直近 HM_COUNT_RATE_WINDOW_TICKS tick の移動窓平均(回/秒)。
// **縦軸の上限は件数系列(FM/Vision)ごとの下限を持つオートスケール**。純粋なオートスケールだと
// 窓の最大値で毎回伸縮し、「1回」と「5回」が同じ高さに描かれて行同士も時刻同士も比べられない。
// 固定にすると超える負荷が天井で潰れる。両方を避けるのが下限付きスケール(hmCountScale)。
// FM と Vision は別の量なので**別々の縦軸**(片方に合わせると読めなくなる)。

import { t } from '../i18n.js';
import { HM_FM_MAX_RATE, HM_VISION_MAX_RATE, hmSharedCountScale, hmCompilingBands } from './hostChartScale.js';
import { setHoverTip } from './hoverTip.js';
import { isMachineDisabled, onMachineEnablementChanged, LOCAL_MACHINE_LABEL } from './machineColors.js';

const HM_MAX_SAMPLES = 60;
// 手元の tick が途絶えたとみなすまでの猶予(ms)。手元の host-metrics 子が落ちてから自動再起動
// までの待ち(monitorProcessManager.ts scheduleHostMetricsRestart の 5000ms)と同値 —— これを
// 超えて手元が無音なら、手元は止まっているとみなして刻みをリモートへ委譲する。
const HM_CLOCK_TAKEOVER_MS = 5000;
// 保持したサンプルを何 tick まで使い回してよいか。両側とも --interval 1 なので、生きている機械が
// 位相のずれで落とせるのは1 tick まで。これを超えたら観測が途絶えたとみなし欠測(–)にする。
const HM_STALE_TICKS = 2;
// 件数系列(FM/Vision)のレート表示の移動窓(tick 数)。host-metrics --interval は 1 固定
// (monitorProcessManager.ts startHostMetricsProcess)なので 1 tick = 1 秒とみなせる。run の FM は
// 直列化で約1回/秒に張り付き、生の1秒差分は 0/1 の二値になり読めないため、10 tick(=10秒)の
// 移動窓平均にして 0.1 刻みで見えるようにする。Vision も同じ窓を使う(件数系列共通)。
const HM_COUNT_RATE_WINDOW_TICKS = 10;
// バリデータ検証済みパレット(ダーク/ライトで系列色を切り替える。グリッド・軸は描かない)。
// dead は FM が死んでいる間の系列色。**色相を持たない**のが要件 —— 赤にすると「異常な値が
// 出ている」に見えるが、実際は値そのものに意味が無い(死んでいる間の回数は 0 で張り付く)。
// 明度は他系列と同じ帯に置く(背景に対して同じ読みやすさ)。
// vision は青 —— cpu(赤)/gpu(琥珀)/fm(紫)/mem(緑)のどれとも色相が被らない。
const HM_COLORS = {
  dark: { cpu: '#f2555a', gpu: '#b8891f', vision: '#3b9eff', fm: '#a06be0', mem: '#2f9e63', dead: '#8b9099' },
  light: { cpu: '#e5484d', gpu: '#e6a700', vision: '#0090ff', fm: '#8e4ec6', mem: '#30a46c', dead: '#8b8d98' },
};

/** 手元の行の表示名(左端のラベル)。CLI 側の DeviceMachineGrouping.localDisplayName と同じ語。 */
const HM_LOCAL_LABEL = LOCAL_MACHINE_LABEL;


const hmContainer = document.getElementById('host-metrics');
const hmLocalRowEl = hmContainer.querySelector('.hm-row[data-machine=""]');

function hmIsLightTheme() {
  return document.body.classList.contains('vscode-light') ||
    document.body.classList.contains('vscode-high-contrast-light');
}

// countScale=true の系列は samples が「比率」ではなく「件数」(FM/Vision)。描画時に
// hmDrawAllRows が求めた共有スケールで正規化する(固定上限だと実測レンジで潰れて読めない)
function hmMakeEntry(rowEl, metric, colorKey, countScale = false) {
  const el = rowEl.querySelector(`.host-metric[data-metric="${metric}"]`);
  return {
    el,
    label: el.querySelector('.hm-label'),
    canvas: el.querySelector('.hm-canvas'),
    value: el.querySelector('.hm-value'),
    colorKey,
    countScale,
    samples: [], // 直近 HM_MAX_SAMPLES 件。0..1 の比率(countScale なら件数)、欠測は null。
  };
}

// failures は FM 死活の検知用。FM 失敗は呼び出し側(occlusion-guard/screenLooksLike)が
// 握りつぶして素通りする契約なので、ここで可視化しないと全滅が正常時と区別できない
// (heal はロケータの指紋照合だけで FM を呼ばないため対象外)。
// Vision の failures は死活の軸を持たない(失敗はその回の判定が別の経路 = OCR は FM・分類器は a11y へ回るだけで判定能力は
// 落ちないため) —— ツールチップの事実としてだけ出す。
function hmMakeRow(rowEl, machine) {
  const entries = {
    cpu: hmMakeEntry(rowEl, 'cpu', 'cpu'),
    gpu: hmMakeEntry(rowEl, 'gpu', 'gpu'),
    vision: hmMakeEntry(rowEl, 'vision', 'vision', true),
    fm: hmMakeEntry(rowEl, 'fm', 'fm', true),
    mem: hmMakeEntry(rowEl, 'mem', 'mem'),
  };
  return {
    machine,
    el: rowEl,
    // FM が死んでいるときの語を出す枠(行の最後尾。監視の対象は FM だけなので entries には入れない。
    // Vision は死活を持たないのでバッジも無い)
    deadBadge: rowEl.querySelector('.hm-fm-dead-badge'),
    entries,
    capacity: {}, // metric → 容量(CPU/GPU はコア数・MEM は GB)。未着はキー無し
    all: [entries.cpu, entries.gpu, entries.vision, entries.fm, entries.mem],
    // FM/Vision のレート表示に使う直近 HM_COUNT_RATE_WINDOW_TICKS tick ぶんの生値
    // ({calls,failures,totalMs} | 欠測は calls:null)。古い順に shift する。
    // fm は死活判定(fmIsDead)にも使う。
    fm: { window: [] },
    // compiling: OCR モデルのコンパイル中だった tick(直近 HM_MAX_SAMPLES 件の boolean。entries.vision.samples と同じ右詰め)。
    // count: 直近 tick のコンパイルプロセス数
    vision: { window: [], compiling: [], compilingCount: 0 },
    // FM の死活(FMLiveness の最新の観測)。**窓を持たない** —— これはレートではなく
    // 「今この機械で FM を呼べるか」という水準で、直近の1サンプルがそのまま答え。
    // 'alive' / 'dead' / null=不明。呼び出しが0件でも埋まるのが回数系列との違い。
    liveness: { text: null, vision: null, reason: null, checkedAt: null },
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
 * その機械で誰かの run が走っていることを、機械名の隣の錠前で出す(docs/remote-runner.md §18.7)。
 * **手元の行も同じ**(キーは空文字)—— dispatch.lock は機械に1本で、ローカル run も取る。
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
 * 変わって MEM/CPU/… の列が行ごとにずれる実害)。
 */
function hmApplyLock(row, machine) {
  const chip = row.el.querySelector('.hm-lock');
  if (!chip) {
    return;
  }
  const lock = hmLocks.get(machine);
  chip.classList.toggle('hm-lock-on', !!lock);
  // 手元の行キーは空文字なので、名前のスロットには行の呼び名を入れる(hmApplyDisabled と同じ)
  const label = machine === '' ? HM_LOCAL_LABEL : machine;
  // **説明はタイルと同じ自前ツールチップ**(0.2 秒)。ネイティブ `title` は遅延が約1秒で
  // 指定できず、この錠前のような小さい的では「乗せても何も出ない」に見える(指摘あり)
  setHoverTip(chip, lock
    ? (lock.mine
      ? t('wvMonitor2.hostCharts.lockMine', { machine: label })
      : t('wvMonitor2.hostCharts.lockOther', {
        machine: label, issuer: lock.issuer || t('wvMonitor2.hostCharts.lockIssuerUnknown'),
      }))
    : '');
}

/** 「マシン有効」off の印を1行へ反映する(要素は足し引きしない。hmApplyLock と同じ理由) */
function hmApplyDisabled(row, machine) {
  const chip = row.el.querySelector('.hm-off');
  if (!chip) {
    return;
  }
  const off = isMachineDisabled(machine);
  chip.classList.toggle('hm-off-on', off);
  // 行ごと明度を下げる(ユーザー決定)—— 使えない機械のグラフが同じ明るさで
  // 並んでいると、動いている機械と見分けが付かない
  row.el.classList.toggle('hm-row-disabled', off);
  setHoverTip(chip, off
    ? t('wvMonitor2.hostCharts.machineDisabled', { machine: machine === '' ? HM_LOCAL_LABEL : machine })
    : '');
}

// remoteConfig は行より後にも先にも届く。届いた時点で全行を塗り直し、行の生成時にも貼る(hmEnsureRow)
onMachineEnablementChanged(() => {
  for (const [machine, row] of hmRows) {
    hmApplyDisabled(row, machine);
  }
  // 線の色も無効かどうかで変わるので描き直す(次の tick まで待つと1秒ほど古い色が残る)
  hmDrawAllRows();
});

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
  // 複製元(手元の行)が死んでいると、その語まで一緒に複製される —— 新しい機械の行が
  // 1度も観測していないうちから死を名乗ることになるので、必ず空から始める
  const clonedBadge = rowEl.querySelector('.hm-fm-dead-badge');
  clonedBadge.textContent = '';
  clonedBadge.classList.remove('hm-visible');
  hmContainer.appendChild(rowEl);
  const row = hmMakeRow(rowEl, machine);
  hmRows.set(machine, row);
  // 容量は機械ごと。複製元(手元)の `CPU n` 等の文字を引き継ぐと、届くまで手元の値を名乗る
  for (const metric of HM_CAPACITY_LABEL_METRICS) {
    hmRenderCapacityLabel(row, metric);
  }
  hmApplyLock(row, machine);   // 行より先に届いていた占有をここで貼る
  hmApplyDisabled(row, machine);   // 複製元(手元の行)の印を引き継がない
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
  // 最も広い名札の行が消えたら幅を詰める
  for (const metric of HM_CAPACITY_LABEL_METRICS) {
    hmAlignLabels(metric);
  }
}

/** 件数系列(FM/Vision)の窓(直近 HM_COUNT_RATE_WINDOW_TICKS tick。row.fm.window / row.vision.window)を
 *  集計する。窓内が全て欠測(calls:null)なら null を返す(呼び出し側はこれを「不明」= 表示 '–'
 *  の合図にする。0件は別に区別できる —— 欠測でない tick は calls が数値、0 も含む)。 */
function hmWindowStats(window) {
  const known = window.filter((tick) => tick.calls !== null);
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

/** 台帳(FMLiveness)が「死」と言っている経路。**呼び出しが0件でも出る**のが窓の判定との違い —
 *  誰も FM を使っていない間、窓の判定は永久に沈黙する(それがこの行の穴だった)。 */
function fmDeadPaths(row) {
  const paths = [];
  if (row.liveness.text === 'dead') paths.push('text');
  if (row.liveness.vision === 'dead') paths.push('vision');
  return paths;
}

// 死の根拠は2つ: ①台帳(実呼び出し or 死活プローブの観測。呼び出し0件でも効く)
// ②窓内の全滅(FMHealth.Snapshot.allFailed と同じ判定: 1回以上呼ばれ、かつ全て失敗)。
// **どちらか一方でも死なら死**。②だけに戻さないこと —— run を回していない間は②が沈黙する
function fmIsDead(row) {
  if (fmDeadPaths(row).length > 0) {
    return true;
  }
  const stats = hmWindowStats(row.fm.window);
  return !!stats && stats.failures > 0 && stats.failures >= stats.calls;
}

/** ツールチップの先頭に付ける機械名(1行だけのときは付けない)。 */
function hmTitlePrefix(row) {
  return hmRows.size > 1 ? `${row.machine === '' ? HM_LOCAL_LABEL : row.machine} — ` : '';
}

function hmRenderFmLabel(row) {
  const entry = row.entries.fm;
  const stats = hmWindowStats(row.fm.window);
  const dead = fmIsDead(row);
  const partial = !!stats && !dead && stats.failures > 0;
  entry.el.classList.toggle('hm-fm-dead', dead);
  entry.el.classList.toggle('hm-fm-warn', partial);
  // **数字は直近 tick の呼び出し回数そのもの**(窓の移動平均ではない)。スパークラインが
  // 描いているのも tick ごとの回数なので、線と数字の単位が一致する。
  // ⚠︎/⚠ と ツールチップは窓(HM_COUNT_RATE_WINDOW_TICKS tick)で判定する —— 1 tick では
  // 「全部失敗」がすぐ立ってしまい落ち着かないため。
  const latest = row.fm.window.length > 0 ? row.fm.window[row.fm.window.length - 1] : null;
  const callsText = latest && latest.calls !== null ? String(latest.calls) : '–';
  // **死んでいる間は値の欄に何も出さない**(ユーザー決定)。死んだ FM の「0回」は事実ではあるが読み手を誤らせ、
  // '–' を出すと右のバッジと並んで「– N/A」になる。死はグレーの線と右のバッジ(N/A 等)だけが言う
  // (欄そのものは CSS の .hm-fm-dead で畳む)
  entry.value.textContent = dead ? '' : (partial ? '⚠' : '') + callsText;
  let title = hmTitlePrefix(row) + t('wvMonitor2.hostCharts.fmTitle', {
    seconds: String(HM_COUNT_RATE_WINDOW_TICKS),
    rate: stats ? stats.rate.toFixed(1) : '–',
    calls: stats ? String(stats.calls) : '–',
    failures: stats ? String(stats.failures) : '–',
    totalSec: stats ? (stats.totalMs / 1000).toFixed(1) : '–',
  });
  const deadPaths = fmDeadPaths(row);
  // **台帳由来の死はここでは語らない**(ユーザー決定)。死は右のバッジが語で出しており、
  // 理由(どの経路か)と観測時刻はそのバッジのツールチップが持つ。ここで同じことを
  // 繰り返すと、レート統計を見に来た人が毎回 3 行の説明を読まされる。
  // 窓内の全滅だけは台帳の理由が無いので、ここに残す
  if (deadPaths.length === 0 && dead) {
    title += '\n' + t('wvMonitor2.hostCharts.fmDeadLine', {
      seconds: String(HM_COUNT_RATE_WINDOW_TICKS), failures: String(stats.failures) });
  } else if (partial) {
    title += '\n' + t('wvMonitor2.hostCharts.fmWarnLine', {
      seconds: String(HM_COUNT_RATE_WINDOW_TICKS),
      failures: String(stats.failures),
      successes: String(stats.calls - stats.failures),
    });
  }
  entry.el.title = title;
  hmRenderDeadBadge(row, { dead, deadPaths, stats });
}

/** FM の死を語で出す。**生きている行と不明の行には何も出さない**(ユーザー決定)
 *  —— 不明で出すと、プローブの谷間で点滅し続ける。
 *  根拠が2つある(台帳 / 窓内の全滅)ので語も分ける: 台帳なら `N/A`(理由は
 *  ツールチップ)、窓内の全滅は台帳の理由が無いので「全呼び出し失敗」という事実だけ述べる。 */
function hmRenderDeadBadge(row, { dead, deadPaths, stats }) {
  const badge = row.deadBadge;
  if (!dead) {
    badge.textContent = '';
    badge.classList.remove('hm-visible');
    badge.removeAttribute('title');
    return;
  }
  // 台帳由来の死は経路を問わず `N/A` の1語(ユーザー決定。日英とも同じ語なので辞書を通さない)。
  // どの経路が死んだかはツールチップの理由(row.liveness.reason)が持つ
  badge.textContent = deadPaths.length > 0
    ? 'N/A'
    : t('wvMonitor2.hostCharts.fmDeadBadgeAllFailed');
  badge.classList.add('hm-visible');
  // 語だけでは「なぜ・いつから」が分からない。理由はここにも付ける(FM セルのツールチップと
  // 同じ内容だが、**語の上にカーソルを置いた人が読めない**のは不親切)
  badge.title = deadPaths.length > 0
    ? `${row.liveness.reason ?? ''}\n${hmFormatAge(row.liveness.checkedAt)}`.trim()
    : t('wvMonitor2.hostCharts.fmDeadLine', {
      seconds: String(HM_COUNT_RATE_WINDOW_TICKS), failures: String(stats.failures) });
}

/** Vision(Vision / Core ML。OCR と画像分類器)呼び出し回数の表示。**死活・バッジは持たない**(FM と違う) —— FM の失敗は
 *  ガード自体を無効化する(誰も知らせない)ので死活の軸が要るが、Vision の失敗はその回の判定が別の経路
 *  (OCR は FM・分類器は a11y)へ回るだけで判定能力は落ちない。失敗はツールチップの事実だけで足りる。 */
function hmRenderVisionLabel(row) {
  const entry = row.entries.vision;
  const stats = hmWindowStats(row.vision.window);
  // 数字は直近 tick の呼び出し回数そのもの(hmRenderFmLabel と同じ理由 —— スパークラインの
  // 単位と一致させる)。
  const latest = row.vision.window.length > 0 ? row.vision.window[row.vision.window.length - 1] : null;
  const callsText = latest && latest.calls !== null ? String(latest.calls) : '–';
  const compiling = hmIsCompilingNow(row);
  entry.value.textContent = callsText;
  const compilingLine = compiling
    ? t('wvMonitor2.hostCharts.visionCompilingTitle', { count: String(row.vision.compilingCount) }) + '\n'
    : '';
  entry.el.title = hmTitlePrefix(row) + compilingLine + t('wvMonitor2.hostCharts.visionTitle', {
    seconds: String(HM_COUNT_RATE_WINDOW_TICKS),
    rate: stats ? stats.rate.toFixed(1) : '–',
    calls: stats ? String(stats.calls) : '–',
    failures: stats ? String(stats.failures) : '–',
    totalSec: stats ? (stats.totalMs / 1000).toFixed(1) : '–',
  });
}

/** 直近 tick が OCR のコンパイル中か(Vision のチャートに重ねる語・ツールチップの行) */
function hmIsCompilingNow(row) {
  return row.vision.compiling.length > 0 && row.vision.compiling[row.vision.compiling.length - 1];
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
  // 2D コンテキストが取れないことはある(コンテキスト喪失・キャンバスを持たない実行環境)。
  // **ここで throw させない** —— 描画は呼び手(remoteConfig のハンドラ等)の途中で走るので、
  // 落ちるとその後の処理が丸ごと消える
  if (!ctx) {
    return null;
  }
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  return ctx;
}

/** scale は**呼び出し側が決める**(既定値を置かない) —— 件数系列は全行で1つの縦軸を共有する
 *  必要があり、ここで entry 単独から計算できるようにしておくと行ごとのスケールへ静かに戻る。 */
function hmDraw(row, entry, scale) {
  const width = 72;
  const height = 22;
  const ctx = hmSetupCanvas(entry.canvas);
  if (!ctx) {
    return;
  }
  ctx.clearRect(0, 0, width, height);
  const samples = entry.samples;
  if (samples.length < 2) {
    return;
  }
  const palette = HM_COLORS[hmIsLightTheme() ? 'light' : 'dark'];
  // FM が死んでいる間はスパークラインをグレーにする(ユーザー決定)。
  // **文字(FM ラベル・値)の色は変えない** —— 行のどこかが赤くなると、隣の CPU/GPU/MEM と
  // 同じ「高い値が出ている」の合図に見える。死は値ではなく系列そのものが無効という話なので、
  // 色を抜くことで表す
  // **「マシン有効」が off の機械も同じグレー**(ユーザー決定)—— 行を薄くするだけだと
  // 色は残るので、系列の色で機械を見分ける目には「動いているが暗い」に見える。無効は値ではなく
  // 系列そのものが無効という話なので、FM の死と同じく色を抜いて表す
  const grey = isMachineDisabled(row.machine) || (entry === row.entries.fm && fmIsDead(row));
  const color = grey ? palette.dead : palette[entry.colorKey];
  const stepX = width / (HM_MAX_SAMPLES - 1);
  // samplesは「直近N件」なので、60件溜まるまでは右詰めで配置する(新サンプルは常に右端)。
  const startIndex = HM_MAX_SAMPLES - samples.length;
  // コンパイル中の帯は線より先に塗る(Vision だけ)。色は系列色(グレー化のときは dead)
  if (entry === row.entries.vision) {
    ctx.globalAlpha = 0.35;
    ctx.fillStyle = color;
    for (const band of hmCompilingBands(row.vision.compiling, HM_MAX_SAMPLES, width)) {
      ctx.fillRect(band.x0, 0, band.x1 - band.x0, height);
    }
    ctx.globalAlpha = 1;
  }
  const points = samples.map((ratio, i) => ({
    x: (startIndex + i) * stepX,
    // 念のため枠外へはみ出させない(件数系列は hmCountScale が上限を含むので通常は効かない)
    y: ratio === null ? null : height - Math.min(1, ratio / scale) * height,
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
  // コンパイル中の語はチャートの上に重ねる(ユーザー決定。値のセルは回数のまま)。線の後に描いて隠れないようにする
  if (entry === row.entries.vision && hmIsCompilingNow(row)) {
    const style = window.getComputedStyle(document.body);
    ctx.font = `10px ${style.fontFamily || 'sans-serif'}`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    // 文字は系列と同じ色(ユーザー決定。機械が無効でグレーのときは文字もグレー)
    ctx.fillStyle = color;
    ctx.fillText(t('wvMonitor2.hostCharts.visionCompilingShort'), width / 2, height / 2);
  }
}

function hmFormatPercent(ratio) {
  return ratio === null || ratio === undefined ? '–' : Math.round(ratio * 100) + '%';
}

/** 死活を観測した時刻(epoch 秒)→ 「N 秒前 / N 分前」。**いつの観測かを必ず出す** ——
 *  台帳は最大 FMLiveness.freshSeconds(120秒)ぶん古くなりうるので、「今まさに死んでいる」と
 *  「2分前にそう見えた」を読み手が区別できるようにする。null は不明。 */
function hmFormatAge(checkedAt) {
  if (typeof checkedAt !== 'number') {
    return '–';
  }
  const seconds = Math.max(0, Math.round(Date.now() / 1000 - checkedAt));
  return seconds < 90
    ? t('wvMonitor2.hostCharts.fmAgeSeconds', { seconds: String(seconds) })
    : t('wvMonitor2.hostCharts.fmAgeMinutes', { minutes: String(Math.round(seconds / 60)) });
}

function hmFormatGb(bytes) {
  return bytes === null || bytes === undefined ? '–' : (bytes / (1024 * 1024 * 1024)).toFixed(1);
}

/**
 * host-metrics の1サンプルを受け取る。**ここでは保持するだけ**で、描画は刻み(hmClock)を持つ
 * 機械のサンプルが来た tick に全行まとめて行う。machine 欄が無い行 = 手元。
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

/** 全行を1度に描き直す(値・ツールチップ・スパークライン)。
 *  **値の更新を全行終えてから描く** —— 件数系列の縦軸は全行のサンプルから決まるので、
 *  行ごとに「積んで描く」を繰り返すと先に描いた行だけ古い縦軸になる。 */
function hmCommitTick() {
  hmLastCommitAt = Date.now();
  for (const row of hmRows.values()) {
    hmCommitRow(row);
  }
  hmDrawAllRows();
}

/** 容量付きの名札(CPU n / GPU n / MEM n)の系列と素の名前。行ごとに桁が変わるので幅を揃える対象 */
const HM_CAPACITY_LABEL_METRICS = ['cpu', 'gpu', 'mem'];
const HM_CAPACITY_LABEL_NAMES = { cpu: 'CPU', gpu: 'GPU', mem: 'MEM' };
/** 設定タブ「デバイスモニターにメモリ容量、CPUコア数、GPUコア数を表示する」(既定 OFF = 素の CPU / GPU / MEM)。
 *  値は monitorPanel.ts の showMachineCapacity メッセージで届く */
let hmShowCapacity = false;

export function setShowMachineCapacity(show) {
  hmShowCapacity = show;
  for (const row of hmRows.values()) {
    for (const metric of HM_CAPACITY_LABEL_METRICS) {
      hmRenderCapacityLabel(row, metric);
    }
  }
  for (const metric of HM_CAPACITY_LABEL_METRICS) {
    hmAlignLabels(metric);
  }
}

/** 名札を描く。容量(row.capacity[metric]。未着は undefined)は ON のときだけ `NAME n`、未着は `NAME -` */
function hmRenderCapacityLabel(row, metric) {
  const name = HM_CAPACITY_LABEL_NAMES[metric];
  const value = row.capacity[metric];
  const label = row.entries[metric].label;
  label.textContent = name;
  if (hmShowCapacity) {
    // 数字だけ別の要素にして色を変え、右寄せする(style.css の .hm-capacity・幅は hmAlignLabels)
    const capacity = document.createElement('span');
    capacity.className = 'hm-capacity';
    capacity.textContent = String(value ?? '-');
    label.append(' ', capacity);
  }
}

/** その系列の数字の枠を最も桁の多い行に揃える(数字は右寄せ・グラフの左端も揃う)。**レイアウトを測らない** ——
 *  設定タブで切り替える間などモニターが非表示だと幅が 0 で測れず、揃えが外れたまま戻らなかった。
 *  数字は CSS の tabular-nums で等幅なので、枠は桁数 × 1ch で足りる */
function hmAlignLabels(metric) {
  const spans = [...hmRows.values()]
    .map((row) => row.entries[metric].label.querySelector('.hm-capacity'))
    .filter((span) => span !== null);
  const longest = Math.max(0, ...spans.map((span) => span.textContent.length));
  for (const span of spans) {
    span.style.minWidth = `${longest}ch`;
  }
}

/** 容量は機械の固定値なので、欠測 tick(value が null)では書き換えず直前の値を残す */
function hmSetCapacity(row, metric, value) {
  if (value !== null && row.capacity[metric] !== value) {
    row.capacity[metric] = value;
    hmRenderCapacityLabel(row, metric);
    hmAlignLabels(metric);
  }
}

/** 全行のスパークラインを描く。件数系列(FM/Vision)は**全行で1つの縦軸**を、
 *  ただし**FM と Vision は別々の縦軸**を共有する(別の量なので片方に合わせると読めなくなる)。 */
function hmDrawAllRows() {
  const rows = [...hmRows.values()];
  const fmScale = hmSharedCountScale(rows.map((row) => row.entries.fm.samples), HM_FM_MAX_RATE);
  const visionScale = hmSharedCountScale(rows.map((row) => row.entries.vision.samples), HM_VISION_MAX_RATE);
  for (const row of rows) {
    for (const entry of row.all) {
      // entry ごとにどちらの縦軸を使うかは identity で引く(行ごとのスケールへ静かに戻らない)。
      const scale = entry === row.entries.fm ? fmScale : entry === row.entries.vision ? visionScale : 1;
      hmDraw(row, entry, entry.countScale ? scale : 1);
    }
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
  const visionCalls = sample && typeof sample.visionCalls === 'number' ? sample.visionCalls : null;
  const visionFailures = sample && typeof sample.visionFailures === 'number' ? sample.visionFailures : null;
  const visionTotalMs = sample && typeof sample.visionTotalMs === 'number' ? sample.visionTotalMs : null;
  // 欠測 tick(sample が null)は死活も**不明へ戻す**。古い「生きている」を出し続けると、
  // 観測が途絶えたことと FM が健康であることが同じ絵になる(不明と生を混ぜない)
  row.liveness = {
    text: sample && typeof sample.fmTextState === 'string' ? sample.fmTextState : null,
    vision: sample && typeof sample.fmVisionState === 'string' ? sample.fmVisionState : null,
    reason: sample && typeof sample.fmDeadReason === 'string' ? sample.fmDeadReason : null,
    checkedAt: sample && typeof sample.fmCheckedAt === 'number' ? sample.fmCheckedAt : null,
  };

  hmPushSample(row.entries.cpu, cpu);
  hmPushSample(row.entries.gpu, gpu);
  row.fm.window.push({ calls: fmCalls, failures: fmFailures, totalMs: fmTotalMs });
  if (row.fm.window.length > HM_COUNT_RATE_WINDOW_TICKS) {
    row.fm.window.shift();
  }
  const ocrCompiling = sample && typeof sample.ocrCompiling === 'number' ? sample.ocrCompiling : 0;
  row.vision.compiling.push(ocrCompiling > 0);
  row.vision.compilingCount = ocrCompiling;
  if (row.vision.compiling.length > HM_MAX_SAMPLES) {
    row.vision.compiling.shift();
  }
  row.vision.window.push({ calls: visionCalls, failures: visionFailures, totalMs: visionTotalMs });
  if (row.vision.window.length > HM_COUNT_RATE_WINDOW_TICKS) {
    row.vision.window.shift();
  }
  // FM/Vision は他の3系列と違い**割合ではなく件数**。描画時に hmCountScale で正規化する
  // (hmDraw の countScale)
  hmPushSample(row.entries.fm, fmCalls);
  hmPushSample(row.entries.vision, visionCalls);
  hmPushSample(row.entries.mem, memRatio);

  hmSetCapacity(row, 'cpu', sample && typeof sample.cpuCores === 'number' ? sample.cpuCores : null);
  hmSetCapacity(row, 'gpu', sample && typeof sample.gpuCores === 'number' ? sample.gpuCores : null);
  // GB は 2^30 バイト(hmFormatGb と同じ単位。64GB 機は 68719476736)
  hmSetCapacity(row, 'mem', memTotalBytes !== null ? Math.round(memTotalBytes / 1024 ** 3) : null);
  row.entries.cpu.value.textContent = hmFormatPercent(cpu);
  row.entries.gpu.value.textContent = hmFormatPercent(gpu);
  row.entries.mem.value.textContent = hmFormatPercent(memRatio);

  const prefix = hmTitlePrefix(row);
  row.entries.cpu.el.title = prefix + t('wvMonitor2.hostCharts.cpuTitle', { value: hmFormatPercent(cpu) });
  row.entries.gpu.el.title = prefix + t('wvMonitor2.hostCharts.gpuTitle', { value: hmFormatPercent(gpu) });
  hmRenderVisionLabel(row);
  hmRenderFmLabel(row);
  row.entries.mem.el.title = prefix + t('wvMonitor2.hostCharts.memTitle', {
    used: hmFormatGb(memUsedBytes),
    total: hmFormatGb(memTotalBytes),
    percent: hmFormatPercent(memRatio),
  });
}

// テーマ切替(body の class に vscode-light 等が付け外しされる)を検知して全グラフを再描画する。
new MutationObserver(() => {
  hmDrawAllRows();
}).observe(document.body, { attributes: true, attributeFilter: ['class'] });
