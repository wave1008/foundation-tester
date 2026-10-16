// 折りたたみ機の開閉ボタン(「折りたたむ」「開く」)の出し分け。ライブ操作タブ(liveTab.js)と
// グリッドビュー(gridLiveControls.js)が共有する。**出すのはモニターが折りたためると答えたデバイスだけ**
// (devices[].foldable === true。契約: monitorDeviceModel.ts の MonitorDevice.foldable)。
// ボタンの DOM は monitorHtml.ts(data-fold="fold" | "unfold"・既定は hidden)。

import { monitorDevices, onMonitorDevicesChanged } from './deviceTiles.js';

/** id のデバイスが折りたためるか(表示フィルタ前の全台から引く = タイルを絞っていても答える) */
export function isFoldableDevice(id) {
  return monitorDevices().some((device) => device.id === id && device.foldable === true);
}

/** buttons: data-fold を持つボタン。deviceId(): いま操作の対象にしているデバイス(無ければ null)。
 * onFold(state): 押されたとき。戻り値の refresh() は対象が変わったときに呼ぶ(devices サイクルでは自動で呼ぶ) */
export function bindFoldButtons(buttons, deviceId, onFold) {
  const refresh = () => {
    const id = deviceId();
    const show = id !== null && id !== undefined && isFoldableDevice(id);
    for (const button of buttons) { button.hidden = !show; }
  };
  for (const button of buttons) {
    button.addEventListener('click', () => onFold(button.dataset.fold));
  }
  // **登録はモジュールの評価が終わってから** —— 呼び手(gridLiveControls.js 等)は deviceTiles.js との
  // import の循環の途中で評価されるので、その時点では deviceTiles.js の状態がまだ初期化されていない
  queueMicrotask(() => {
    onMonitorDevicesChanged(refresh);
    refresh();
  });
  return refresh;
}
