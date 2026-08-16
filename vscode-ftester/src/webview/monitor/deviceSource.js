// deviceSource.js
// 「プロファイル」タブ > マシンプロファイル節の「デバイス候補の取得元」セレクタ
// (docs/remote-runner.md §13 段2)。選択状態はここに保持する(VSCode 設定は増やさない)。
//
// ホスト一覧は remoteConfig(拡張→webview。設定タブの同名メッセージと同一)を main.js から
// 直接ルーティングしてもらい、このモジュール自身のコピーとして持つ(可変状態は書き込み箇所と
// 同じモジュールに置く方針。settingsTab.js の hostRows とは別の独立したコピー)。
// 対向: src/remoteRunArgs.ts の DeviceCommandSource / deviceCommandArgs、
//       src/monitorDeviceOps.ts の runDeviceCatalog/runInstalledDevices/runCreateDevice。

import { t } from '../i18n.js';

const sourceSelect = document.getElementById('device-source-select');
const addBadge = document.getElementById('device-add-source-badge');
const pickBadge = document.getElementById('device-pick-source-badge');

// remoteConfig.hosts[].name のうち非空のもの。
let hostNames = [];
// 選択中のホスト名。null = ローカル。
let selectedHost = null;

function localOptionValue() {
  return '';
}

/** <select> をローカル+ホスト一覧で作り直す。選択中の値が一覧から消えていればローカルへ戻す。 */
function renderSelect() {
  if (selectedHost !== null && !hostNames.includes(selectedHost)) {
    selectedHost = null;
  }
  sourceSelect.textContent = '';
  const localOption = document.createElement('option');
  localOption.value = localOptionValue();
  localOption.textContent = t('wvMonitor.deviceSource.localOption');
  sourceSelect.appendChild(localOption);
  for (const name of hostNames) {
    const option = document.createElement('option');
    option.value = name;
    option.textContent = name;
    sourceSelect.appendChild(option);
  }
  sourceSelect.value = selectedHost === null ? localOptionValue() : selectedHost;
}

/** main.js が 'remoteConfig' 受信時に呼ぶ(settingsTab.js の applyRemoteConfig と同じメッセージ、
 * 別モジュールが独立に自分のコピーを持つ)。 */
export function applyDeviceSourceHosts(message) {
  hostNames = (Array.isArray(message.hosts) ? message.hosts : [])
    .map((h) => (h && typeof h.name === 'string' ? h.name.trim() : ''))
    .filter((name) => name !== '');
  renderSelect();
}

sourceSelect.addEventListener('change', () => {
  selectedHost = sourceSelect.value === localOptionValue() ? null : sourceSelect.value;
});

/** deviceCatalogRequest/installedDevicesRequest/createDevice の source として postMessage に載せる値
 * (remoteRunArgs.ts の DeviceCommandSource と同形)。 */
export function currentDeviceSource() {
  return selectedHost === null ? { kind: 'local' } : { kind: 'remote', host: selectedHost };
}

function badgeText() {
  const label = selectedHost === null ? t('wvMonitor.deviceSource.localShort') : selectedHost;
  return t('wvMonitor.deviceSource.badge', { source: label });
}

/** デバイス追加/既存から選択モーダルを開くたびに呼び、取得元を常時表示する
 * (「リモート取得中はどのホストから取っているかを画面に出す」§13 段2)。 */
export function refreshSourceBadges() {
  const text = badgeText();
  addBadge.textContent = text;
  pickBadge.textContent = text;
}

renderSelect();
