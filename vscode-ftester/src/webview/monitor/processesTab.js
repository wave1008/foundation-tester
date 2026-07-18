// モニターパネル「プロセス」タブ(#panel-processes)。main.js が applyResidentMessage を message
// ディスパッチャに組み込む。対向: src/monitorModel.ts の refreshResidentProcesses/
// killAllResidentProcesses/residentProcesses/residentKillResult、処理は src/monitorPanel.ts。

import { vscode } from './vscodeApi.js';
import { t } from '../i18n.js';

const processesPanel = document.getElementById('panel-processes');
const residentKillAllBtn = document.getElementById('resident-kill-all');
const residentStatus = document.getElementById('resident-status');
const residentTbody = document.getElementById('resident-tbody');
const residentUpdated = document.getElementById('resident-updated');

// 直近描画した内容の署名(JSON)。1 秒ポーリングで内容不変なら再描画も「前回更新」時刻更新もしない。
// ヘッダソートは renderResidentList を直接呼ぶため署名に関係なく即反映される。
let lastSignature = null;

function formatUpdatedAt(ts) {
  return new Date(ts || undefined).toLocaleString('ja-JP', { hour12: false });
}

// data-sort の値 → 並べ替えキーの取り出し方と型。number 型は空("")を最小(-Infinity)扱いにして
// ホスト順(TYPE_ORDER→pid)の並びを壊さない。Array.prototype.sort は安定なので同値はホスト順を保つ。
const SORT_COLUMNS = {
  type: { type: 'string', get: (i) => i.label },
  port: { type: 'number', get: (i) => i.port },
  pid: { type: 'number', get: (i) => (i.pid > 0 ? i.pid : i.devicePid || 0) },
  detail: { type: 'string', get: (i) => i.detail },
  ppid: { type: 'number', get: (i) => i.ppid },
  parentDescription: { type: 'string', get: (i) => i.parentDescription },
  note: { type: 'string', get: (i) => i.note },
};

// 直近受信分。ヘッダクリック時に再ソート描画するため保持する(1秒ごとの自動更新でも上書きされる)。
let lastItems = [];
let sortKey = null; // null = ホスト順(サーバが TYPE_ORDER→pid で整列済み)
let sortDir = 'asc';

function compareBy(col, a, b) {
  const va = col.get(a);
  const vb = col.get(b);
  if (col.type === 'number') {
    const na = va === '' || va == null ? -Infinity : Number(va);
    const nb = vb === '' || vb == null ? -Infinity : Number(vb);
    return na - nb;
  }
  return String(va ?? '').localeCompare(String(vb ?? ''), 'ja');
}

function sortForDisplay(items) {
  const col = sortKey && SORT_COLUMNS[sortKey];
  if (!col) {
    return items;
  }
  const sign = sortDir === 'asc' ? 1 : -1;
  return [...items].sort((a, b) => sign * compareBy(col, a, b));
}

function renderResidentList(items) {
  lastItems = items;
  residentTbody.textContent = '';
  if (items.length === 0) {
    const row = document.createElement('tr');
    const cell = document.createElement('td');
    cell.colSpan = 7;
    cell.className = 'resident-empty';
    cell.textContent = t('wvMonitor2.process.empty');
    row.appendChild(cell);
    residentTbody.appendChild(row);
    return;
  }
  for (const item of sortForDisplay(items)) {
    const row = document.createElement('tr');
    row.className = `resident-row resident-type-${item.type}`;
    if (item.zombie) {
      row.classList.add('resident-zombie');
    }
    row.dataset.type = item.type;

    const typeCell = document.createElement('td');
    typeCell.className = 'col-type';
    const badge = document.createElement('span');
    badge.className = 'resident-badge';
    badge.textContent = item.label;
    typeCell.appendChild(badge);
    if (item.zombie) {
      const z = document.createElement('span');
      z.className = 'resident-zombie-badge';
      z.textContent = t('wvMonitor2.process.zombieBadge');
      z.title = t('wvMonitor2.process.zombieTitle');
      typeCell.appendChild(z);
    }
    row.appendChild(typeCell);

    const portCell = document.createElement('td');
    portCell.className = 'col-port';
    portCell.textContent = item.port;
    row.appendChild(portCell);

    const pidCell = document.createElement('td');
    pidCell.className = 'col-pid';
    // ホスト PID があればそのまま。無い情報行はデバイス内 PID を "(12345)" と括弧付き。括弧はホスト
    // PID ではない(kill 非対象)ことを示す。android-bridge で PID 未取得は forward だけ残りブリッジ
    // 本体が未起動(遅延起動待ち)なので "(遅延起動)"。その他の PID 無し行は "—"。
    if (item.pid > 0) {
      pidCell.textContent = String(item.pid);
    } else if (item.devicePid) {
      pidCell.textContent = `(${item.devicePid})`;
    } else if (item.type === 'android-bridge') {
      pidCell.textContent = t('wvMonitor2.process.pendingLaunch');
    } else {
      pidCell.textContent = '—';
    }
    row.appendChild(pidCell);

    const detailCell = document.createElement('td');
    detailCell.className = 'col-detail';
    detailCell.textContent = item.detail;
    detailCell.title = item.detail;
    row.appendChild(detailCell);

    const ppidCell = document.createElement('td');
    ppidCell.className = 'col-ppid';
    ppidCell.textContent = item.ppid > 0 ? String(item.ppid) : '—'; // 合成行(android-bridge)はホスト親 PID 無し
    row.appendChild(ppidCell);

    const pdescCell = document.createElement('td');
    pdescCell.className = 'col-pdesc';
    pdescCell.textContent = item.parentDescription;
    pdescCell.title = item.parentDescription;
    row.appendChild(pdescCell);

    const noteCell = document.createElement('td');
    noteCell.className = 'col-note';
    noteCell.textContent = item.note;
    noteCell.title = item.note;
    row.appendChild(noteCell);

    residentTbody.appendChild(row);
  }
}

export function applyResidentMessage(message) {
  if (message.type === 'residentProcesses') {
    const signature = JSON.stringify(message.items);
    if (signature === lastSignature) {
      return; // 内容不変: 再描画も「前回更新」時刻の更新もしない
    }
    lastSignature = signature;
    renderResidentList(message.items);
    residentStatus.textContent =
      message.items.length > 0 ? t('wvMonitor2.process.statusCount', { count: message.items.length }) : '';
    residentUpdated.textContent = t('wvMonitor2.process.lastUpdated', { time: formatUpdatedAt(message.ts) });
    return;
  }
  if (message.type === 'residentKillResult') {
    residentKillAllBtn.disabled = false;
    if (message.status === 'done') {
      residentStatus.textContent = t('wvMonitor2.process.killedCount', { count: message.killed ?? 0 });
    } else if (message.status === 'cancelled') {
      residentStatus.textContent = '';
    } else {
      residentStatus.textContent = t('wvMonitor2.process.killFailed', { error: message.error ?? '' });
    }
  }
}

function requestRefresh() {
  vscode.postMessage({ type: 'refreshResidentProcesses' });
}

residentKillAllBtn.addEventListener('click', () => {
  residentKillAllBtn.disabled = true;
  residentStatus.textContent = t('wvMonitor2.process.running');
  vscode.postMessage({ type: 'killAllResidentProcesses' });
});

// ヘッダクリックで昇順⇄降順トグル。別列クリックでその列の昇順から。状態は自動更新をまたいで保持し、
// renderResidentList が毎回 sortForDisplay で反映する。
const residentHeaders = Array.from(document.querySelectorAll('#resident-list thead th[data-sort]'));

function updateSortIndicators() {
  for (const th of residentHeaders) {
    const active = th.dataset.sort === sortKey;
    th.classList.toggle('sort-active', active);
    th.textContent = th.dataset.baseLabel + (active ? (sortDir === 'asc' ? ' ▲' : ' ▼') : '');
  }
}

for (const th of residentHeaders) {
  th.classList.add('sortable');
  th.dataset.baseLabel = th.textContent;
  th.addEventListener('click', () => {
    const key = th.dataset.sort;
    if (sortKey === key) {
      sortDir = sortDir === 'asc' ? 'desc' : 'asc';
    } else {
      sortKey = key;
      sortDir = 'asc';
    }
    updateSortIndicators();
    renderResidentList(lastItems);
  });
}

// プロセスタブに切り替わった瞬間に即更新(tabs.js が dispatch する ft-tab-activated)。
document.addEventListener('ft-tab-activated', (event) => {
  if (event.detail?.tab === 'processes') {
    requestRefresh();
  }
});

// #panel-processes が表示中の間だけ 1 秒間隔で ps を回す(非表示のタブ分まで常時ポーリングしない)。
setInterval(() => {
  if (processesPanel.style.display !== 'none') {
    requestRefresh();
  }
}, 1000);
