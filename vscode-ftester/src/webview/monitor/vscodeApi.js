// vscodeApi.js
// webview 側の vscode API アクセス(acquireVsCodeApi)を1箇所に集約したモジュール。
// Phase 3(main.js のモジュール分割)で main.js から抽出した。acquireVsCodeApi() は
// webview の生存期間中に1回しか呼び出せないため、postMessage/getState/setState を使う
// 全モジュールがこの vscode 定数を import して共用する(直接呼び出すのはこのファイルだけ)。
//
// persistedState(vscode.getState() の起動時スナップショット)も、上下ペインの高さ復元
// (splitter.js)・選択中タブ復元(main.js のブートストラップ)など複数モジュールが参照するため、
// 元は splitter 節にあったものをここへ合わせて置く。

export const vscode = acquireVsCodeApi();

const persistedState = vscode.getState() || {};
export { persistedState };
