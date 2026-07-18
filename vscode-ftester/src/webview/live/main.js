// 独立ライブ操作パネルのエントリポイント。ライブ UI 本体は ../monitor/liveTab.js を共有する
// (id接頭辞 live-*、CSSも media/monitor/style.css を共用。host 側の窓口は src/livePanel.ts)。

import { vscode } from '../monitor/vscodeApi.js';
import {
  applyLiveMessage,
  applyLiveH264Chunk,
  initLive,
  setLiveVisible,
  openLiveDevice,
  refreshLiveDevices,
} from '../monitor/liveTab.js';

window.addEventListener('message', (event) => {
  const message = event.data;
  if (!message || typeof message.type !== 'string') {
    return;
  }
  switch (message.type) {
    case 'live':
      applyLiveMessage(message.message);
      break;
    case 'liveH264Chunk':
      applyLiveH264Chunk(message);
      break;
    case 'openDevice':
      openLiveDevice(message.id);
      break;
    case 'panelVisible':
      setLiveVisible(!!message.visible);
      break;
    case 'refreshDevicesFromHost':
      refreshLiveDevices();
      break;
    default:
      break;
  }
});

// host は 'ready' を受けて openForDevice() の保留分(html設定直後の postMessage は webview 側
// message リスナー登録前に届き握りつぶされるレース回避)があれば送る(livePanel.ts 参照)。
// 初期状態一般の push は無く、以降は webview 側の initLive() が refreshDevices/refreshAppProfiles を
// 能動的に要求する。
vscode.postMessage({ type: 'ready' });
initLive();
// スクリプトが実行される時点で(retainContextWhenHidden により初回のみ)パネルは表示中である前提
// (createWebviewPanel 直後は visible)。以後の表示切替は host からの panelVisible メッセージが更新する。
setLiveVisible(true);
