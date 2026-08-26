// devicePickMachine.js
// #device-pick-overlay(「+既存から選択」モーダル)内のマシン選択(#device-pick-machine-select)。
// マシン選択はこのダイアログのスコープだけに閉じる(マシンプロファイルタブに常設セレクタは置かない)。
// 選択状態はここに保持する(VSCode 設定は増やさない)。
//
// 用語(docs/remote-runner.md §0): ここが扱うのは **machine = 登録簿のマシン名(この Mac だけの
// エイリアス)** で、ホスト名/IP ではない。`remote exec <machine>` の第1引数に渡る値。
//
// 一覧は remoteConfig(拡張→webview。設定タブの同名メッセージと同一)を main.js から
// 直接ルーティングしてもらい、このモジュール自身のコピーとして持つ(可変状態は書き込み箇所と
// 同じモジュールに置く方針。settingsTab.js の hostRows とは別の独立したコピー)。
// 対向: src/remoteRunArgs.ts の DeviceCommandSource / deviceCommandArgs、
//       src/monitorDeviceOps.ts の runDeviceCatalog/runInstalledDevices/runCreateDevice。

import { t } from '../i18n.js';

const machineSelect = document.getElementById('device-pick-machine-select');
const addBadge = document.getElementById('device-add-source-badge');

// remoteConfig.hosts[].machine(登録簿のマシン名)のうち非空のもの。
// **キーは "machine"**(2026-08-26 改名。remoteRunArgs.ts の RemoteHostEntry と対。旧キー "name" を
// 読むと一覧が常に空になり、リモートのマシンを1つも選べない)。
let machineNames = [];
// 選択中のマシン名。null = ローカル。
let selectedMachine = null;

function localOptionValue() {
  return '';
}

/** <select> をローカル+マシン一覧で作り直す。選択中の値が一覧から消えていればローカルへ戻す。 */
function renderSelect() {
  if (selectedMachine !== null && !machineNames.includes(selectedMachine)) {
    selectedMachine = null;
  }
  machineSelect.textContent = '';
  const localOption = document.createElement('option');
  localOption.value = localOptionValue();
  localOption.textContent = t('wvMonitor.devicePick.machineLocalOption');
  machineSelect.appendChild(localOption);
  for (const name of machineNames) {
    const option = document.createElement('option');
    option.value = name;
    option.textContent = name;
    machineSelect.appendChild(option);
  }
  machineSelect.value = selectedMachine === null ? localOptionValue() : selectedMachine;
}

/** main.js が 'remoteConfig' 受信時に呼ぶ(settingsTab.js の applyRemoteConfig と同じメッセージ、
 * 別モジュールが独立に自分のコピーを持つ)。 */
export function applyDevicePickMachines(message) {
  machineNames = (Array.isArray(message.hosts) ? message.hosts : [])
    .map((h) => (h && typeof h.machine === 'string' ? h.machine.trim() : ''))
    .filter((name) => name !== '');
  renderSelect();
}

machineSelect.addEventListener('change', () => {
  selectedMachine = machineSelect.value === localOptionValue() ? null : machineSelect.value;
});

/** #device-pick-overlay を開くたびに modals.js が呼ぶ。profileMachine は編集対象マシンプロファイルの
 * machine フィールド(未設定なら null/undefined)。登録簿から消えたマシンを指していればローカルへ
 * 落とす(§13 段2 と同じ防御 —「登録簿からマシンが消えたら選択はローカルへ戻る」)。 */
export function resetDevicePickMachine(profileMachine) {
  selectedMachine =
    typeof profileMachine === 'string' && profileMachine.length > 0 && machineNames.includes(profileMachine)
      ? profileMachine
      : null;
  renderSelect();
}

/** deviceCatalogRequest/installedDevicesRequest/createDevice/machineDevicesSync の source として
 * postMessage に載せる値(remoteRunArgs.ts の DeviceCommandSource と同形)。 */
export function currentDeviceSource() {
  return selectedMachine === null ? { kind: 'local' } : { kind: 'remote', machine: selectedMachine };
}

/** #device-add-overlay(入れ子の「デバイスを新規作成」ダイアログ)は常に #device-pick-overlay の
 * 中から開くため、読み取り専用のバッジとして現在の選択をそのまま映すだけでよい
 * (「リモート取得中はどのマシンから取っているかを画面に出す」§13 段2)。 */
export function refreshDeviceAddBadge() {
  const label = selectedMachine === null ? t('wvMonitor.devicePick.machineLocalShort') : selectedMachine;
  addBadge.textContent = t('wvMonitor.devicePick.machineBadge', { source: label });
}

renderSelect();
