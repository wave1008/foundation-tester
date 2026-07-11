// domRefs.js
// main.js 冒頭(旧・IIFE 直下)にあった DOM 要素参照のうち、複数モジュールから参照される
// もの(ツールバー・タイルペイン/出力ペイン・レーン関連・タイル右クリックメニュー)をまとめた
// モジュール。Phase 3(main.js のモジュール分割)で main.js から抽出した。
// getElementById は何度呼んでも同じ要素を返す(acquireVsCodeApi のような一度きり制約は無い)が、
// ここで1箇所にまとめておくことで「どの要素がどのモジュールから使われているか」を
// 見通しやすくする。

export const toolbar = document.getElementById('toolbar');
export const grid = document.getElementById('grid');
export const emptyMessage = document.getElementById('empty');
export const banner = document.getElementById('banner');
export const btnUp = document.getElementById('btn-devices-up');
export const btnDown = document.getElementById('btn-devices-down');
export const btnRestart = document.getElementById('btn-restart');
export const profileSelect = document.getElementById('profile-select');

export const devicesPanel = document.getElementById('panel-devices');
export const tilePane = document.getElementById('tile-pane');
export const splitter = document.getElementById('splitter');
export const lanesPlaceholder = document.getElementById('lanes-placeholder');
export const lanesGrid = document.getElementById('lanes-grid');
export const lanesSelectionStatus = document.getElementById('lanes-selection-status');
export const lanesRunStatus = document.getElementById('lanes-run-status');

export const deviceOpMenu = document.getElementById('device-op-menu');
export const deviceOpMenuItemBtn = document.getElementById('device-op-menu-item');
