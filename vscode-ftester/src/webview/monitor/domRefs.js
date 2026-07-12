// getElementByIdは何度呼んでも同じ要素を返す(acquireVsCodeApiのような一度きり制約は無い)。
// 複数モジュール共有のDOM参照をここに集約する。

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
export const deviceOpMenuLiveBtn = document.getElementById('device-op-menu-live');
