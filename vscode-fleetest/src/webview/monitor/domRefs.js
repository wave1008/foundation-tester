// getElementByIdは何度呼んでも同じ要素を返す(acquireVsCodeApiのような一度きり制約は無い)。
// 複数モジュール共有のDOM参照をここに集約する。

export const toolbar = document.getElementById('toolbar');
export const grid = document.getElementById('grid');
export const emptyMessage = document.getElementById('empty');
export const banner = document.getElementById('banner');
export const btnUp = document.getElementById('btn-devices-up');
export const btnDown = document.getElementById('btn-devices-down');
export const btnRestart = document.getElementById('btn-restart');
export const btnRunTests = document.getElementById('btn-run-tests');
export const btnSelectAll = document.getElementById('btn-select-all');
export const projectSelect = document.getElementById('project-select');
export const profileSelect = document.getElementById('profile-select');

export const runBoard = document.getElementById('run-board');
export const lineViewHeader = document.getElementById('line-view-header');
export const lineViewToggle = document.getElementById('line-view-toggle');
export const lineViewTitle = document.getElementById('line-view-title');
export const lineViewSelection = document.getElementById('line-view-selection');
export const runBoardHeader = document.getElementById('run-board-header');
export const runBoardToggle = document.getElementById('run-board-toggle');
export const runBoardTitle = document.getElementById('run-board-title');
export const runBoardExpandAll = document.getElementById('run-board-expand-all');
export const runBoardRows = document.getElementById('run-board-rows');

export const devicesPanel = document.getElementById('panel-devices');
export const tilePane = document.getElementById('tile-pane');
export const tileMarquee = document.getElementById('tile-marquee');
export const splitter = document.getElementById('splitter');
export const lanesWaiting = document.getElementById('lanes-waiting');
export const lanesGrid = document.getElementById('lanes-grid');
export const lanesSelectionStatus = document.getElementById('lanes-selection-status');
export const lanesRunStatus = document.getElementById('lanes-run-status');

// 実行ログビュー(#log-pane)・グリッドビュー(#output-pane)の開閉・分割(splitter.js)。
export const logPane = document.getElementById('log-pane');
export const logViewHeader = document.getElementById('log-view-header');
export const logViewToggle = document.getElementById('log-view-toggle');
export const splitterLog = document.getElementById('splitter-log');
export const outputPane = document.getElementById('output-pane');
export const gridViewHeader = document.getElementById('grid-view-header');
export const gridViewToggle = document.getElementById('grid-view-toggle');
export const gridViewTitle = document.getElementById('grid-view-title');
export const previewGrid = document.getElementById('preview-grid');

export const deviceOpMenu = document.getElementById('device-op-menu');
export const deviceOpMenuItemBtn = document.getElementById('device-op-menu-item');
export const deviceOpMenuItemLabel = document.getElementById('device-op-menu-item-label');
export const deviceOpMenuLiveBtn = document.getElementById('device-op-menu-live');
export const deviceOpMenuGpuBtn = document.getElementById('device-op-menu-gpu');
export const deviceOpMenuSep = document.getElementById('device-op-menu-sep');
export const deviceOpMenuSelectAllBtn = document.getElementById('device-op-menu-select-all');
export const deviceOpMenuSelectOnlyBtn = document.getElementById('device-op-menu-select-only');
export const deviceOpMenuDeselectAllBtn = document.getElementById('device-op-menu-deselect-all');
