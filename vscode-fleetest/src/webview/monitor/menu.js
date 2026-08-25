// 右クリックメニューの画面端クランプ。deviceTiles.js/machineProfilesTab.js/liveTab.js で共用。

export function clampMenuPosition(menuEl, clientX, clientY) {
  const rect = menuEl.getBoundingClientRect();
  const maxX = Math.max(4, window.innerWidth - rect.width - 4);
  const maxY = Math.max(4, window.innerHeight - rect.height - 4);
  menuEl.style.left = Math.min(Math.max(clientX, 4), maxX) + 'px';
  menuEl.style.top = Math.min(Math.max(clientY, 4), maxY) + 'px';
}
