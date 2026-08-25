// acquireVsCodeApiはwebview生存期間中に1回しか呼べないため、ここに集約し全モジュールがvscodeを
// importして共用する(直接呼ぶのはこのファイルだけ。webview/monitor/vscodeApi.js と同じ理由・
// 同じ形。パネルごとにJSコンテキストが独立しているため別バンドルとしてそれぞれ1回ずつ呼ぶ)。

export const vscode = acquireVsCodeApi();
