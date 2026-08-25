// acquireVsCodeApiはwebview生存期間中に1回しか呼べないため、ここに集約し全モジュールがvscodeを
// importして共用する(直接呼ぶのはこのファイルだけ)。
// persistedStateは複数モジュール(splitter.js/main.js等)が参照するためここに置く。

export const vscode = acquireVsCodeApi();

const persistedState = vscode.getState() || {};
export { persistedState };
