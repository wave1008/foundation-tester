// 表示整形の純関数群(dashboard 内の render.js/charts.js/main.js が共用)。

export function isLightTheme() {
  return document.body.classList.contains('vscode-light') ||
    document.body.classList.contains('vscode-high-contrast-light');
}

export function formatPercent(rate) {
  return typeof rate === 'number' ? rate.toFixed(1) + '%' : '–';
}

export function formatDurationMs(ms) {
  return typeof ms === 'number' ? Math.round(ms) + 'ms' : '–';
}

// 遅いテストセクション向け(所要時間が長く ms 表示だと読みにくいため): 1000ms 未満は ms、
// 60秒未満は小数1桁の秒、それ以上は分+秒。
export function formatDurationHuman(ms) {
  if (typeof ms !== 'number' || !isFinite(ms)) return '–';
  if (ms < 1000) return Math.round(ms) + 'ms';
  const totalSeconds = ms / 1000;
  if (totalSeconds < 60) return totalSeconds.toFixed(1) + 's';
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = Math.round(totalSeconds % 60);
  return minutes + 'm ' + seconds + 's';
}

// 悪化率バッジ(遅いテスト/insights 共用)。符号なし数値は呼び出し側で '–' 扱いにする。
export function formatDeltaPercent(deltaPct) {
  return (deltaPct > 0 ? '+' : '') + deltaPct.toFixed(1) + '%';
}

// Sources/ftester/ResultsCommand.swift の formatLocal(yyyy-MM-dd HH:mm:ss、ローカルタイムゾーン)
// と表示を揃える。
export function formatLocalDateTime(iso) {
  if (!iso) return '–';
  const d = new Date(iso);
  if (isNaN(d.getTime())) return iso;
  const pad = (n) => String(n).padStart(2, '0');
  return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' +
    pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
}

export function passFailMark(passed) {
  return passed ? '✅' : '❌';
}

export function recentResultsMarks(recentResults) {
  return recentResults.map(passFailMark).join('');
}
