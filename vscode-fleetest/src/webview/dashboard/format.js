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

// 人間向けの所要表示: 1000ms 未満は ms、1秒以上は常に「XmYYs」(2026-09-01 ユーザー指示。
// 55.1s と 1m 9s の混在をやめて 0m55s / 1m9s に揃える)。
export function formatDurationHuman(ms) {
  if (typeof ms !== 'number' || !isFinite(ms)) return '–';
  if (ms < 1000) return Math.round(ms) + 'ms';
  let minutes = Math.floor(ms / 60000);
  let seconds = Math.round((ms % 60000) / 1000);
  if (seconds === 60) {
    minutes += 1;
    seconds = 0;
  }
  return minutes + 'm' + seconds + 's';
}

// 悪化率バッジ(遅いテスト/insights 共用)。符号なし数値は呼び出し側で '–' 扱いにする。
export function formatDeltaPercent(deltaPct) {
  return (deltaPct > 0 ? '+' : '') + deltaPct.toFixed(1) + '%';
}

// Sources/fleetest/ResultsCommand.swift の formatLocal(yyyy-MM-dd HH:mm:ss、ローカルタイムゾーン)
// と表示を揃える。
export function formatLocalDateTime(iso) {
  if (!iso) return '–';
  const d = new Date(iso);
  if (isNaN(d.getTime())) return iso;
  const pad = (n) => String(n).padStart(2, '0');
  return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' +
    pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
}

// マトリクステーブルの run 列見出し用の短縮表示("MM-DD HH:mm")。
export function formatShortDateTime(iso) {
  if (!iso) return '–';
  const d = new Date(iso);
  if (isNaN(d.getTime())) return iso;
  const pad = (n) => String(n).padStart(2, '0');
  return pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
}

export function passFailMark(passed) {
  return passed ? '✅' : '❌';
}

export function recentResultsMarks(recentResults) {
  return recentResults.map(passFailMark).join('');
}
