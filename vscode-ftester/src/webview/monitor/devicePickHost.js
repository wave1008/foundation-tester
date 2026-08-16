// devicePickHost.js
// #device-pick-overlay(「+既存から選択」モーダル)内のホスト選択(#device-pick-host-select)。
// マシンプロファイルタブの常設セレクタは廃止し、このダイアログのスコープだけに閉じたホスト選択に
// 置き換えた(旧 deviceSource.js の役割を引き継ぐ)。選択状態はここに保持する(VSCode 設定は増やさない)。
//
// ホスト一覧は remoteConfig(拡張→webview。設定タブの同名メッセージと同一)を main.js から
// 直接ルーティングしてもらい、このモジュール自身のコピーとして持つ(可変状態は書き込み箇所と
// 同じモジュールに置く方針。settingsTab.js の hostRows とは別の独立したコピー)。
// 対向: src/remoteRunArgs.ts の DeviceCommandSource / deviceCommandArgs、
//       src/monitorDeviceOps.ts の runDeviceCatalog/runInstalledDevices/runCreateDevice。

import { t } from '../i18n.js';

const hostSelect = document.getElementById('device-pick-host-select');
const addBadge = document.getElementById('device-add-source-badge');

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
  hostSelect.textContent = '';
  const localOption = document.createElement('option');
  localOption.value = localOptionValue();
  localOption.textContent = t('wvMonitor.devicePick.hostLocalOption');
  hostSelect.appendChild(localOption);
  for (const name of hostNames) {
    const option = document.createElement('option');
    option.value = name;
    option.textContent = name;
    hostSelect.appendChild(option);
  }
  hostSelect.value = selectedHost === null ? localOptionValue() : selectedHost;
}

/** main.js が 'remoteConfig' 受信時に呼ぶ(settingsTab.js の applyRemoteConfig と同じメッセージ、
 * 別モジュールが独立に自分のコピーを持つ)。 */
export function applyDevicePickHosts(message) {
  hostNames = (Array.isArray(message.hosts) ? message.hosts : [])
    .map((h) => (h && typeof h.name === 'string' ? h.name.trim() : ''))
    .filter((name) => name !== '');
  renderSelect();
}

hostSelect.addEventListener('change', () => {
  selectedHost = hostSelect.value === localOptionValue() ? null : hostSelect.value;
});

/** #device-pick-overlay を開くたびに modals.js が呼ぶ。machineHost は編集対象マシンプロファイルの
 * host フィールド(未設定なら null/undefined)。登録簿から消えたホストを指していればローカルへ
 * 落とす(§13 段2 と同じ防御 —「登録簿からホストが消えたら選択はローカルへ戻る」)。 */
export function resetDevicePickHost(machineHost) {
  selectedHost = typeof machineHost === 'string' && machineHost.length > 0 && hostNames.includes(machineHost)
    ? machineHost
    : null;
  renderSelect();
}

/** deviceCatalogRequest/installedDevicesRequest/createDevice/machineDevicesSync の source として
 * postMessage に載せる値(remoteRunArgs.ts の DeviceCommandSource と同形)。 */
export function currentDeviceSource() {
  return selectedHost === null ? { kind: 'local' } : { kind: 'remote', host: selectedHost };
}

/** #device-add-overlay(入れ子の「デバイスを新規作成」ダイアログ)は常に #device-pick-overlay の
 * 中から開くため、読み取り専用のバッジとして現在の選択をそのまま映すだけでよい
 * (「リモート取得中はどのホストから取っているかを画面に出す」§13 段2)。 */
export function refreshDeviceAddBadge() {
  const label = selectedHost === null ? t('wvMonitor.devicePick.hostLocalShort') : selectedHost;
  addBadge.textContent = t('wvMonitor.devicePick.hostBadge', { source: label });
}

renderSelect();
