// デバイスの機種/OS(表示専用)のキャッシュ。キーは iOS の udid / Android 実機の serial /
// AVD の id。マシンプロファイルは機種/OS を持たない(または古い登録で欠けている)ため、
// 編集フォームはここから埋める。書き込みは installedDevices 応答を受ける modals.js のみ。
//
// **独立モジュールにしている理由**: machineProfilesTab.js ⇄ modals.js の相互 import は循環になり、
// バンドル後の評価順が入れ替わって modals.js 側の `btnDeviceAddExisting.addEventListener` が
// undefined を触って webview 全体が初期化に失敗する(実害。2026-07-25)。片方向依存を保つこと。

const byKey = new Map();

/** installedDevices(InstalledDevices の形)から機種/OS を取り込む。 */
export function cachePhysicalDeviceInfo(data) {
  if (!data) {
    return;
  }
  for (const device of (data.ios && data.ios.physicalDevices) || []) {
    byKey.set(device.udid, { model: device.model || '', os: device.os || '' });
  }
  for (const device of (data.android && data.android.physicalDevices) || []) {
    byKey.set(device.serial, { model: device.model || '', os: device.os || '' });
  }
  // AVD は id と表示名のどちらでもプロファイルに書けるので両方をキーにする
  // (AndroidDeviceCatalog.canonicalAVDID と同じ許容範囲に合わせる)
  for (const avd of (data.android && data.android.avds) || []) {
    const info = { model: avd.model || '', os: avd.os || '' };
    byKey.set(avd.id, info);
    if (avd.displayName) {
      byKey.set(avd.displayName, info);
    }
  }
}

/** key = iOS の udid / Android 実機の serial / AVD の id か表示名。未取得は undefined。 */
export function physicalDeviceInfo(key) {
  return key ? byKey.get(key) : undefined;
}
