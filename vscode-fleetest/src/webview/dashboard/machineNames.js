// 記録の host(ホスト名)→ この Mac の登録名(machine)の表示読み替え。
// 対応表は payload.machines(facts キャッシュ由来)で、main.js が data 受信のたびに差し替える。
// 表に無い host(古い記録・未観測の機械)はホスト名のまま出す(事実を落とさない)。
// 記録・runID は host のまま —— ここは表示だけ(docs/remote-runner.md §0 の用語規律)。

let aliasByHost = new Map();

export function setMachineAliases(rows) {
  aliasByHost = new Map(rows.map((row) => [row.host, row.machine]));
}

export function machineLabel(host) {
  return aliasByHost.get(host) || host;
}

/** hosts → 表示名の配列。local を常に先頭に(モニターのホスト負荷グラフと同じ並び)、残りは名前昇順 */
export function machineLabels(hosts) {
  const labels = hosts.map(machineLabel);
  labels.sort((a, b) => {
    if (a === 'local') return -1;
    if (b === 'local') return 1;
    return a < b ? -1 : a > b ? 1 : 0;
  });
  return labels;
}
