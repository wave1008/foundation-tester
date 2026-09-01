// acquireVsCodeApi は document の生存期間中に1回しか呼べない。ダッシュボードは独立パネルではなく
// モニターパネルのタブとして同一 document に同居するため、ここでは呼ばない ——
// 実 acquire は src/webview/monitor/vscodeApi.js が1回だけ行い、dashboardTab.js が
// setDashboardTransport() でその postMessage 呼び出しを注入する(封筒 {type:'dashboard', message}
// で包むのは注入する側の責務。render.js/runDetail.js/trend.js 等は従来どおり
// vscode.postMessage(message) の形で呼ぶだけでよい)。

let send = () => {};

export function setDashboardTransport(fn) {
  send = fn;
}

export const vscode = {
  postMessage: (message) => send(message),
};
