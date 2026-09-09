// 他モジュールの状態には依存しない(vscode の postMessage/受信ハンドラのみで完結)。
//
// プロジェクトは TestProjects/<名前>/ ディレクトリのみで名前以外の設定値を持たないため、
// 実行/アプリ/マシンプロファイル(appProfilesTab.js 等)と違いフォーム本体・dirty管理・
// ロード/保存の口を持たない。選択の正はホスト側(fleetest.project 設定)なので、
// ここでは選択状態を持たず profileInfo が届くたび message.project をそのまま反映するだけ。

import { vscode } from './vscodeApi.js';
import { t } from '../i18n.js';

const projectSelect = document.getElementById('project-section-select');
const projectNameStatic = document.getElementById('project-name-static');
const btnProjectAdd = document.getElementById('btn-project-add');
const btnProjectCopy = document.getElementById('btn-project-copy');
const btnProjectRemove = document.getElementById('btn-project-remove');
const btnProjectRename = document.getElementById('btn-project-rename');
const projectError = document.getElementById('project-error');
const projectDirectoryRow = document.getElementById('project-directory-row');
const projectDirectory = document.getElementById('project-directory');

// profileInfo受信。「現在値」は常にホスト由来(message.project)なので、appProfilesTab.js の
// ような webview 内の選択記憶は持たない。
export function applyProjectInfo(message) {
  const projects = Array.isArray(message.projects) ? message.projects : [];
  const current = typeof message.project === 'string' ? message.project : '';
  projectError.textContent = '';

  if (projects.length >= 1) {
    projectSelect.style.display = '';
    projectNameStatic.style.display = 'none';
    projectSelect.textContent = '';
    // 未解決(候補が複数あってどれとも決まっていない)ときの置き札。「テスト実行」タブの
    // 同じ select(deviceTiles.js の applyProjectInfo)と同じ形にする
    if (current === '') {
      const placeholder = document.createElement('option');
      placeholder.value = '';
      placeholder.disabled = true;
      placeholder.selected = true;
      placeholder.textContent = t('wvMonitor.project.placeholder');
      projectSelect.appendChild(placeholder);
    }
    for (const name of projects) {
      const option = document.createElement('option');
      option.value = name;
      option.textContent = name;
      projectSelect.appendChild(option);
    }
    projectSelect.value = current;
  } else {
    projectSelect.style.display = 'none';
    projectNameStatic.style.display = '';
    projectNameStatic.textContent = t('wvMonitor2.project.none');
  }

  // 参照のみの表示。ellipsis で切れるので全体は title(ホバー)へ回す。
  const dir = typeof message.projectDir === 'string' ? message.projectDir : '';
  projectDirectoryRow.style.display = dir === '' ? 'none' : '';
  projectDirectory.textContent = dir;
  projectDirectory.title = dir;

  // [+]は常に有効(追加先は常にある)。コピー/−/✏は**選択が決まっているときだけ**有効にする
  // —— 一覧が非空でも未解決なら対象が無く、押しても無言で何も起きないため。
  btnProjectAdd.disabled = false;
  const noTarget = current === '' || !projects.includes(current);
  btnProjectCopy.disabled = noTarget;
  btnProjectRemove.disabled = noTarget;
  btnProjectRename.disabled = noTarget;
}

projectSelect.addEventListener('change', () => {
  vscode.postMessage({ type: 'selectProject', project: projectSelect.value });
});

btnProjectAdd.addEventListener('click', () => vscode.postMessage({ type: 'projectAdd' }));
btnProjectCopy.addEventListener('click', () => {
  if (projectSelect.value) {
    vscode.postMessage({ type: 'projectCopy', project: projectSelect.value });
  }
});
btnProjectRemove.addEventListener('click', () => {
  if (projectSelect.value) {
    vscode.postMessage({ type: 'projectDelete', project: projectSelect.value });
  }
});
btnProjectRename.addEventListener('click', () => {
  if (projectSelect.value) {
    vscode.postMessage({ type: 'projectRename', project: projectSelect.value });
  }
});
