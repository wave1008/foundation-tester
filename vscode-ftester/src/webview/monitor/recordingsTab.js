// モニターパネル「録画」タブ(#panel-recordings)。セッション一覧→再生ビューの2ビュー構成。
// 対向: src/monitorModel.ts の recordingsSessions/recordingsSession(拡張→webview)・
// recordingsRefresh/recordingsOpen(webview→拡張)、処理は src/monitorRecordingsController.ts。
// エラー一覧の動画内オフセット(offsetMs)は拡張側(recordingsModel.ts)で計算済みのものを使うだけ。
//
// 契約: recordings/index.json は1エントリ=1シナリオ(テスト関数)の mp4(v2)。動画の切替は
// 「ワーカー切替」ではなく「シナリオ動画の切替」(selectScenarioVideo)。動画は各シナリオの
// クリップそのものなので、再生範囲を絞るウィンドウ機構は無く、シークバー・時間表示は常に
// 表示中の動画全体(video.duration)を表す。

import { vscode, persistedState } from './vscodeApi.js';
import { t } from '../i18n.js';

const listView = document.getElementById('recordings-list-view');
const playerView = document.getElementById('recordings-player-view');
const sessionsEmpty = document.getElementById('recordings-empty');
const sessionsList = document.getElementById('recordings-sessions');
const refreshBtn = document.getElementById('recordings-refresh');
const backBtn = document.getElementById('recordings-back');
const sessionTitle = document.getElementById('recordings-session-title');
const video = document.getElementById('recordings-video');
const playBtn = document.getElementById('recordings-play');
const rewindBtn = document.getElementById('recordings-rewind');
const forwardBtn = document.getElementById('recordings-forward');
const seekBar = document.getElementById('recordings-seek');
const timeCurrent = document.getElementById('recordings-time-current');
const timeTotal = document.getElementById('recordings-time-total');
const speedSelect = document.getElementById('recordings-speed');
const errorsEmpty = document.getElementById('recordings-errors-empty');
const errorsList = document.getElementById('recordings-errors-list');
const treeEmpty = document.getElementById('recordings-tree-empty');
const treeContainer = document.getElementById('recordings-tree');
const errorsFilterChip = document.getElementById('recordings-errors-filter');
const errorsFilterLabel = document.getElementById('recordings-errors-filter-label');
const errorsFilterClear = document.getElementById('recordings-errors-filter-clear');
const treeSplitter = document.getElementById('recordings-splitter-tree');
const recordingsBody = playerView.querySelector('.recordings-body');

// シークバーの内部分解能(0〜SEEK_RESOLUTIONの整数値をvideo.durationとの比率に変換する)。
const SEEK_RESOLUTION = 1000;

// 直近の recordingsSession 応答(ok:true時)。videosByScenario: scenarioID→videoUri、
// selectedScenarioID: 現在 <video> に読み込まれているシナリオ(未選択は null)、errors は全件を保持。
let currentDetail = null;
let seekDragging = false; // ドラッグ中はtimeupdateでシークバー位置を上書きしない
// ツリー選択によるエラー一覧の絞り込み。null = 全件。scene/stepIndex は undefined なら階層ごと不問
// (シナリオ選択= scenarioID のみ、シーン選択= +scene、ステップ選択= +stepIndex)。
let errorFilter = null;

function formatTime(seconds) {
  const safe = Number.isFinite(seconds) && seconds > 0 ? seconds : 0;
  const m = Math.floor(safe / 60);
  const s = Math.floor(safe % 60);
  return `${m}:${String(s).padStart(2, '0')}`;
}

function showListView() {
  listView.style.display = 'flex';
  playerView.style.display = 'none';
  video.pause();
  video.removeAttribute('src');
  video.load();
  currentDetail = null;
  selectedTreeRowEl = null;
  errorFilter = null;
  errorsFilterChip.style.display = 'none';
  currentPlaybackEntry = null;
  clearNowPlaying();
}

function showPlayerView() {
  listView.style.display = 'none';
  playerView.style.display = 'flex';
}

function renderSessions(sessions) {
  sessionsList.textContent = '';
  if (sessions.length === 0) {
    sessionsEmpty.textContent = t('recordings.sessions.empty');
    sessionsEmpty.style.display = 'flex';
    return;
  }
  sessionsEmpty.style.display = 'none';
  for (const session of sessions) {
    const row = document.createElement('div');
    row.className = 'recordings-session-item';
    row.tabIndex = 0;
    row.setAttribute('role', 'button');

    const main = document.createElement('div');
    main.className = 'recordings-session-main';
    const runIdSpan = document.createElement('span');
    runIdSpan.className = 'recordings-session-runid';
    runIdSpan.textContent = `${session.project} / ${session.runID}`;
    main.appendChild(runIdSpan);
    const startedSpan = document.createElement('span');
    startedSpan.className = 'recordings-session-started';
    startedSpan.textContent = new Date(session.startedAt).toLocaleString();
    main.appendChild(startedSpan);
    row.appendChild(main);

    if (session.passed !== null && session.failed !== null) {
      const counts = document.createElement('span');
      counts.className = 'recordings-session-counts';
      if (session.failed > 0) {
        counts.classList.add('recordings-session-counts-failed');
      }
      counts.textContent = t('recordings.sessions.passedFailed', {
        passed: session.passed,
        failed: session.failed,
      });
      row.appendChild(counts);
    }

    const open = () => vscode.postMessage({ type: 'recordingsOpen', project: session.project, runID: session.runID });
    row.addEventListener('click', open);
    row.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        open();
      }
    });
    sessionsList.appendChild(row);
  }
}

export function applyRecordingsSessions(message) {
  renderSessions(message.sessions);
}

/** シナリオ動画へ切替える(既に表示中なら切替えず位置だけ変える)。entry = {scenarioID, videoUri}。 */
function selectScenarioVideo(entry, seekSeconds) {
  if (!currentDetail || !entry) {
    return;
  }
  const target = seekSeconds !== undefined ? seekSeconds : 0;
  if (currentDetail.selectedScenarioID === entry.scenarioID) {
    video.currentTime = Math.max(0, Math.min(target, video.duration || 0));
    updateTimeDisplay();
    return;
  }
  const wasPaused = video.paused;
  currentDetail.selectedScenarioID = entry.scenarioID;
  video.src = entry.videoUri;
  video.load();
  video.addEventListener(
    'loadedmetadata',
    () => {
      video.currentTime = Math.max(0, Math.min(target, video.duration || 0));
      if (!wasPaused) {
        video.play().catch(() => {});
      }
      updateTimeDisplay();
    },
    { once: true },
  );
}

function matchesErrorFilter(err) {
  if (!errorFilter) {
    return true;
  }
  // クラス選択: scenarioID のクラス部(最後のドットまで。groupTreeByClass と同じ分割規則)で照合。
  if (errorFilter.classID !== undefined) {
    const dot = err.scenarioID.lastIndexOf('.');
    const cls = dot > 0 ? err.scenarioID.slice(0, dot) : err.scenarioID;
    return cls === errorFilter.classID;
  }
  if (err.scenarioID !== errorFilter.scenarioID) {
    return false;
  }
  if (errorFilter.scene !== undefined && err.scene !== errorFilter.scene) {
    return false;
  }
  if (errorFilter.stepIndex !== undefined && err.stepIndex !== errorFilter.stepIndex) {
    return false;
  }
  return true;
}

/** ツリー選択に応じた絞り込みを設定して一覧を再描画する。filter=null で解除。 */
function setErrorFilter(filter, label) {
  errorFilter = filter;
  if (filter) {
    errorsFilterLabel.textContent = t('recordings.errors.filtering', { label });
    errorsFilterChip.style.display = 'flex';
  } else {
    errorsFilterChip.style.display = 'none';
  }
  renderErrors();
}

function renderErrors() {
  errorsList.textContent = '';
  const errors = (currentDetail ? currentDetail.errors : []).filter(matchesErrorFilter);
  if (errors.length === 0) {
    errorsEmpty.textContent = t(errorFilter ? 'recordings.errors.noneFiltered' : 'recordings.errors.none');
    errorsEmpty.style.display = 'flex';
    return;
  }
  errorsEmpty.style.display = 'none';
  for (const err of errors) {
    const row = document.createElement('div');
    row.className = 'recordings-error-item';
    row.tabIndex = 0;
    row.setAttribute('role', 'button');
    row.title = t('recordings.errors.jumpTitle');

    const head = document.createElement('div');
    head.className = 'recordings-error-head';
    const scenario = document.createElement('span');
    scenario.className = 'recordings-error-scenario';
    scenario.textContent = err.scenarioID;
    head.appendChild(scenario);
    if (err.sceneTitle) {
      const scene = document.createElement('span');
      scene.className = 'recordings-error-scene';
      scene.textContent = err.sceneTitle;
      head.appendChild(scene);
    }
    const worker = document.createElement('span');
    worker.className = 'recordings-error-worker';
    worker.textContent = err.worker;
    head.appendChild(worker);
    row.appendChild(head);

    const desc = document.createElement('div');
    desc.className = 'recordings-error-desc';
    desc.textContent = err.description;
    row.appendChild(desc);

    if (err.detail) {
      const detail = document.createElement('div');
      detail.className = 'recordings-error-detail';
      detail.textContent = err.detail;
      row.appendChild(detail);
    }

    const jump = () => jumpToError(err);
    row.addEventListener('click', jump);
    row.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        jump();
      }
    });
    errorsList.appendChild(row);
  }
}

// 必要なら scenarioID の動画へ切り替えてから offsetMs(ms)の位置へシークする(エラー一覧・ツリー共通)。
// 対応する動画が無い scenarioID(録画対象外だった等)は何もしない。
function seekToOffset(scenarioID, offsetMs) {
  if (!currentDetail) {
    return;
  }
  const videoUri = currentDetail.videosByScenario.get(scenarioID);
  if (!videoUri) {
    return;
  }
  selectScenarioVideo({ scenarioID, videoUri }, Math.max(0, offsetMs / 1000));
}

function jumpToError(err) {
  // 文脈が見えるよう3秒手前へ(仕様)。
  seekToOffset(err.scenarioID, Math.max(0, err.offsetMs - 3000));
}

// ---- TEST EXPLORER 風ツリー(再生ビュー左ペイン) -------------------------------------

// 丸囲みの ✓/✗(TEST EXPLORER 風)。色は .recordings-tree-icon-* の currentColor。
// codicon フォントは CSP で読めないためインライン SVG(monitorHtml.ts のボタン群と同じ方式)。
const TREE_STATUS_SVG = {
  passed:
    '<svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="6.4" fill="none" stroke="currentColor" stroke-width="1.2"/><path d="M5 8.2l2 2 4-4" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  failed:
    '<svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="6.4" fill="none" stroke="currentColor" stroke-width="1.2"/><path d="M5.8 5.8l4.4 4.4M10.2 5.8l-4.4 4.4" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>',
  other:
    '<svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="6.4" fill="none" stroke="currentColor" stroke-width="1.2"/><circle cx="8" cy="8" r="2" fill="currentColor"/></svg>',
};
// 開閉シェブロン(> を expanded で 90° 回転させて ∨ にする。CSS .recordings-tree-toggle)。
const TREE_CHEVRON_SVG =
  '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M6 4l4 4-4 4" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>';

let selectedTreeRowEl = null;
// 開閉可能な全行の setExpanded ハンドル(renderTree でリセット)。全て開く/閉じるボタン用。
let treeExpandHandles = [];
// 再生位置→対応ノードの索引。scenarioID → [{startMs, rowEl, caption}](startMs 昇順)。動画は
// 1エントリ=1シナリオなので、キーは現在表示中の scenarioID の分しか意味を持たない。
// シナリオ行とステップ行を登録し、timeupdate で「startMs ≤ 現在位置」の最後の項目を再生中扱いにする。
let playbackEntries = new Map();
let currentPlaybackEntry = null;
// 前/次テストのナビ用: セッション内全シナリオを壁時計 startedAt 昇順で持つ
// [{scenarioID, chipLabel, rowEl, landingMs, startedAtMs}](renderTree で再構築)。
let scenarioNav = [];
const nowPlayingClassEl = document.getElementById('recordings-now-playing-class');
const nowPlayingDetailEl = document.getElementById('recordings-now-playing-detail');

/** キャプションの2段表示用パーツ。cls = クラス名(上段)、title = 関数の説明(下段。無ければ関数名)。 */
function scenarioCaptionParts(scenario) {
  const dot = scenario.scenarioID.lastIndexOf('.');
  return {
    cls: dot > 0 ? scenario.scenarioID.slice(0, dot) : scenario.scenarioID,
    title: scenario.title || scenario.method,
  };
}

function clearNowPlaying() {
  nowPlayingClassEl.textContent = '';
  nowPlayingClassEl.title = '';
  nowPlayingDetailEl.textContent = '';
  nowPlayingDetailEl.title = '';
}

/** キャプション1行をアイコン(ツリーと同じ丸囲み✓/✗)+テキストで組み立てる。 */
function setNowPlayingLine(el, status, text) {
  el.textContent = '';
  const icon = document.createElement('span');
  icon.className = 'recordings-now-playing-icon recordings-tree-icon-' + status;
  icon.innerHTML = TREE_STATUS_SVG[status] || TREE_STATUS_SVG.other;
  const label = document.createElement('span');
  label.className = 'recordings-now-playing-text';
  label.textContent = text;
  el.append(icon, label);
  el.title = text;
}

function registerPlaybackEntry(scenarioID, startMs, rowEl, caption) {
  let list = playbackEntries.get(scenarioID);
  if (!list) {
    list = [];
    playbackEntries.set(scenarioID, list);
  }
  list.push({ startMs, rowEl, caption });
}

function updateNowPlaying() {
  const scenarioID = currentDetail ? currentDetail.selectedScenarioID : null;
  const list = (scenarioID && playbackEntries.get(scenarioID)) || [];
  const ms = video.currentTime * 1000;
  let entry = null;
  for (const candidate of list) {
    if (candidate.startMs <= ms) {
      entry = candidate;
    } else {
      break;
    }
  }
  if (entry === currentPlaybackEntry) {
    return;
  }
  if (currentPlaybackEntry) {
    currentPlaybackEntry.rowEl.classList.remove('recordings-tree-row-playing');
  }
  currentPlaybackEntry = entry;
  if (entry) {
    entry.rowEl.classList.add('recordings-tree-row-playing');
    entry.rowEl.scrollIntoView({ block: 'nearest' });
    setNowPlayingLine(nowPlayingClassEl, entry.caption.clsStatus, entry.caption.cls);
    setNowPlayingLine(nowPlayingDetailEl, entry.caption.detailStatus, entry.caption.detail);
  } else {
    clearNowPlaying();
  }
}

errorsFilterClear.addEventListener('click', deselectTreeRow);

document.getElementById('recordings-tree-expand-all').addEventListener('click', () => {
  for (const setExpanded of treeExpandHandles) {
    setExpanded(true);
  }
});
document.getElementById('recordings-tree-collapse-all').addEventListener('click', () => {
  for (const setExpanded of treeExpandHandles) {
    setExpanded(false);
  }
});

/** 選択を外す(フィルターも解除)。チップの「解除」と再クリックのトグルから呼ぶ。 */
function deselectTreeRow() {
  if (selectedTreeRowEl) {
    selectedTreeRowEl.classList.remove('recordings-tree-row-selected');
    selectedTreeRowEl = null;
  }
  setErrorFilter(null);
  updateTimeDisplay();
}

/** 戻り値: 新たに選択したら true / 既に選択中の行(=トグルで解除)なら false。 */
function selectTreeRow(row) {
  if (selectedTreeRowEl === row) {
    deselectTreeRow();
    return false;
  }
  if (selectedTreeRowEl) {
    selectedTreeRowEl.classList.remove('recordings-tree-row-selected');
  }
  selectedTreeRowEl = row;
  row.classList.add('recordings-tree-row-selected');
  return true;
}

// collapsible:false の葉(ステップ)は常に childrenEl なし。トグルは event.stopPropagation() で
// 行クリック(シーク)への伝播を止める。
function buildTreeRow({ depth, label, status, collapsible, expanded, childrenEl, onActivate }) {
  const row = document.createElement('div');
  row.className = 'recordings-tree-row';
  row.style.setProperty('--tree-depth', String(depth));
  row.tabIndex = 0;
  row.setAttribute('role', 'treeitem');

  const toggle = document.createElement('span');
  if (collapsible) {
    toggle.className = 'recordings-tree-toggle' + (expanded ? ' expanded' : '');
    toggle.innerHTML = TREE_CHEVRON_SVG;
    row.setAttribute('aria-expanded', String(expanded));
    const setExpanded = (nowExpanded) => {
      childrenEl.style.display = nowExpanded ? '' : 'none';
      toggle.classList.toggle('expanded', nowExpanded);
      row.setAttribute('aria-expanded', String(nowExpanded));
    };
    treeExpandHandles.push(setExpanded);
    toggle.addEventListener('click', (event) => {
      event.stopPropagation();
      setExpanded(childrenEl.style.display === 'none');
    });
  } else {
    toggle.className = 'recordings-tree-toggle recordings-tree-toggle-empty';
  }
  row.appendChild(toggle);

  const icon = document.createElement('span');
  icon.className = 'recordings-tree-icon recordings-tree-icon-' + status;
  icon.innerHTML = TREE_STATUS_SVG[status] || TREE_STATUS_SVG.other;
  row.appendChild(icon);

  const text = document.createElement('span');
  text.className = 'recordings-tree-label';
  text.textContent = label;
  text.title = label;
  row.appendChild(text);

  const activate = () => {
    // 選択中の行の再クリックは選択解除(=フィルター解除)。シークもしない。
    if (selectTreeRow(row)) {
      onActivate();
    }
  };
  row.addEventListener('click', activate);
  row.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      activate();
    }
  });

  return row;
}

function buildStepNode(scenario, scene, step, clsStatus) {
  const node = document.createElement('div');
  node.className = 'recordings-tree-node';
  const label = `${step.index}. ${step.description}`;
  const row = buildTreeRow({
    depth: 3,
    label,
    status: step.status,
    collapsible: false,
    onActivate: () => {
      setErrorFilter({ scenarioID: scenario.scenarioID, scene: scene.scene, stepIndex: step.index }, label);
      seekToOffset(scenario.scenarioID, step.offsetMs);
    },
  });
  node.appendChild(row);
  const sceneLabel = scene.sceneTitle || t('recordings.tree.sceneDefaultTitle', { n: scene.scene });
  const parts = scenarioCaptionParts(scenario);
  registerPlaybackEntry(scenario.scenarioID, step.offsetMs, row, {
    cls: parts.cls,
    clsStatus,
    detail: `${parts.title} › ${sceneLabel} › ${label}`,
    detailStatus: step.status,
  });
  return node;
}

function buildSceneNode(scenario, scene, clsStatus) {
  const node = document.createElement('div');
  node.className = 'recordings-tree-node';
  const hasSteps = scene.steps.length > 0;
  const childrenEl = document.createElement('div');
  childrenEl.className = 'recordings-tree-children';
  const label = scene.sceneTitle || t('recordings.tree.sceneDefaultTitle', { n: scene.scene });
  // 失敗を含むシーンは既定で展開する(探しやすさのため。仕様)。
  const expanded = scene.status === 'failed';
  node.appendChild(
    buildTreeRow({
      depth: 2,
      label,
      status: scene.status,
      collapsible: hasSteps,
      expanded,
      childrenEl,
      onActivate: () => {
        setErrorFilter({ scenarioID: scenario.scenarioID, scene: scene.scene }, label);
        seekToOffset(scenario.scenarioID, scene.offsetMs);
      },
    }),
  );
  if (hasSteps) {
    for (const step of scene.steps) {
      childrenEl.appendChild(buildStepNode(scenario, scene, step, clsStatus));
    }
  }
  if (!expanded) {
    childrenEl.style.display = 'none';
  }
  node.appendChild(childrenEl);
  return node;
}

function buildScenarioNode(scenario, clsStatus) {
  const node = document.createElement('div');
  node.className = 'recordings-tree-node';
  const hasScenes = scenario.scenes.length > 0;
  const childrenEl = document.createElement('div');
  childrenEl.className = 'recordings-tree-children';
  // 失敗したテスト関数は既定で展開(シーンの既定展開規則と同じ。成功はコンパクトに畳む)。
  const expanded = scenario.status === 'failed';
  const row = buildTreeRow({
    depth: 1,
    // @Test の説明文を表示(古い記録などで無ければ method 名)。
    label: scenario.title || scenario.method,
    status: scenario.status,
    collapsible: hasScenes,
    expanded,
    childrenEl,
    onActivate: () => {
      const parts = scenarioCaptionParts(scenario);
      setErrorFilter({ scenarioID: scenario.scenarioID }, `${parts.cls}/${parts.title}`);
      seekToOffset(scenario.scenarioID, scenario.offsetMs);
    },
  });
  node.appendChild(row);
  const parts = scenarioCaptionParts(scenario);
  registerPlaybackEntry(scenario.scenarioID, scenario.offsetMs, row, {
    cls: parts.cls,
    clsStatus,
    detail: parts.title,
    detailStatus: scenario.status,
  });
  scenarioNav.push({
    scenarioID: scenario.scenarioID,
    chipLabel: `${parts.cls}/${parts.title}`,
    rowEl: row,
    // ⏮/⏭ の着地点。シナリオ記録開始(0秒)はアプリ起動前の画面が映るため、
    // 最初のシーン(=最初のステップ)の開始があればそちらへ着地する。
    landingMs: scenario.scenes[0]?.offsetMs ?? 0,
    startedAtMs: Date.parse(scenario.startedAt) || 0,
  });
  if (hasScenes) {
    for (const scene of scenario.scenes) {
      childrenEl.appendChild(buildSceneNode(scenario, scene, clsStatus));
    }
  }
  if (!expanded) {
    childrenEl.style.display = 'none';
  }
  node.appendChild(childrenEl);
  return node;
}

function buildClassNode(cls) {
  const node = document.createElement('div');
  node.className = 'recordings-tree-node';
  const childrenEl = document.createElement('div');
  childrenEl.className = 'recordings-tree-children';
  node.appendChild(
    buildTreeRow({
      depth: 0,
      label: cls.classID,
      status: cls.status,
      collapsible: cls.scenarios.length > 0,
      expanded: true, // 既定はクラス展開(テスト関数一覧が見える状態)
      childrenEl,
      onActivate: () => {
        setErrorFilter({ classID: cls.classID }, cls.classID);
        // クラスクリックは最初のシナリオ動画の先頭へ。
        seekToOffset(cls.firstScenarioID, 0);
      },
    }),
  );
  for (const scenario of cls.scenarios) {
    childrenEl.appendChild(buildScenarioNode(scenario, cls.status));
  }
  node.appendChild(childrenEl);
  return node;
}

function renderTree(tree) {
  treeContainer.textContent = '';
  selectedTreeRowEl = null;
  treeExpandHandles = [];
  playbackEntries = new Map();
  currentPlaybackEntry = null;
  clearNowPlaying();
  scenarioNav = [];
  if (tree.length === 0) {
    treeEmpty.textContent = t('recordings.tree.empty');
    treeEmpty.style.display = 'flex';
    return;
  }
  treeEmpty.style.display = 'none';
  for (const cls of tree) {
    treeContainer.appendChild(buildClassNode(cls));
  }
  for (const list of playbackEntries.values()) {
    list.sort((a, b) => a.startMs - b.startMs);
  }
  scenarioNav.sort((a, b) => a.startedAtMs - b.startedAtMs);
}

// 現在表示中の動画(scenarioID)の scenarioNav 上の位置。見つからなければ -1。
function currentScenarioNavIndex() {
  const scenarioID = currentDetail ? currentDetail.selectedScenarioID : null;
  return scenarioNav.findIndex((nav) => nav.scenarioID === scenarioID);
}

// ツリー選択とエラー一覧フィルターも移動先テストへ連動させる(ツリーの行クリックと同じ状態にする)。
function jumpToScenarioNav(index) {
  const nav = scenarioNav[index];
  if (!nav) {
    return;
  }
  if (selectedTreeRowEl !== nav.rowEl) {
    if (selectedTreeRowEl) {
      selectedTreeRowEl.classList.remove('recordings-tree-row-selected');
    }
    selectedTreeRowEl = nav.rowEl;
    nav.rowEl.classList.add('recordings-tree-row-selected');
  }
  setErrorFilter({ scenarioID: nav.scenarioID }, nav.chipLabel);
  seekToOffset(nav.scenarioID, nav.landingMs);
}

// ⏮ は一般的なプレイヤー流儀: テストの途中(先頭から2秒超)なら現在テストの先頭へ戻り、
// 先頭付近ならひとつ前のテストへ移る(現在動画自身のクリップ内位置で判定するので動画は
// 切り替わらない)。
document.getElementById('recordings-prev-test').addEventListener('click', () => {
  const index = currentScenarioNavIndex();
  if (index < 0) {
    jumpToScenarioNav(0);
    return;
  }
  const nav = scenarioNav[index];
  const intoTestMs = video.currentTime * 1000 - nav.landingMs;
  jumpToScenarioNav(intoTestMs > 2000 || index === 0 ? index : index - 1);
});
document.getElementById('recordings-next-test').addEventListener('click', () => {
  const index = currentScenarioNavIndex();
  jumpToScenarioNav(index < 0 ? 0 : Math.min(index + 1, scenarioNav.length - 1));
});

export function applyRecordingsSession(message) {
  if (!message.ok || !message.videos || message.videos.length === 0) {
    showListView();
    return;
  }
  currentDetail = {
    videosByScenario: new Map(message.videos.map((v) => [v.scenarioID, v.videoUri])),
    selectedScenarioID: null,
    errors: message.errors || [],
  };
  sessionTitle.textContent = `${message.project} / ${message.runID}`;
  setErrorFilter(null);
  renderTree(message.tree || []);
  showPlayerView();
  if (scenarioNav.length > 0) {
    seekToOffset(scenarioNav[0].scenarioID, 0);
  }
}

// ---- 再生コントロール ---------------------------------------------------------------
// シークバー・時間表示は常に表示中の動画全体(video.duration)を表す(再生範囲を絞るウィンドウは
// 無い。動画自体が1シナリオ分のクリップなので、終端は <video> が自然に停止する)。

function updatePlayIcon() {
  playBtn.textContent = video.paused ? '▶' : '⏸';
}

function updateTimeDisplay() {
  const duration = video.duration || 0;
  timeCurrent.textContent = formatTime(video.currentTime);
  timeTotal.textContent = formatTime(duration);
  if (!seekDragging && duration > 0) {
    seekBar.value = String(Math.round((video.currentTime / duration) * SEEK_RESOLUTION));
  }
  updateNowPlaying();
}

updatePlayIcon();

playBtn.addEventListener('click', () => {
  if (video.paused) {
    video.play().catch(() => {});
  } else {
    video.pause();
  }
});
video.addEventListener('play', updatePlayIcon);
video.addEventListener('pause', updatePlayIcon);
video.addEventListener('timeupdate', updateTimeDisplay);
video.addEventListener('loadedmetadata', updateTimeDisplay);

rewindBtn.addEventListener('click', () => {
  video.currentTime = Math.max(0, video.currentTime - 10);
});
forwardBtn.addEventListener('click', () => {
  video.currentTime = Math.min(video.duration || Infinity, video.currentTime + 10);
});

speedSelect.addEventListener('change', () => {
  video.playbackRate = Number(speedSelect.value);
});

// ドラッグ中(input)も即シークして画像を追従させる(スクラブ)。Chromium はシーク要求を
// 内部で間引くため input 毎の currentTime 代入で問題ない。
seekBar.addEventListener('input', () => {
  seekDragging = true;
  const duration = video.duration || 0;
  if (duration > 0) {
    const target = (Number(seekBar.value) / SEEK_RESOLUTION) * duration;
    video.currentTime = target;
    timeCurrent.textContent = formatTime(target);
  }
});
seekBar.addEventListener('change', () => {
  seekDragging = false;
});

// ---- ツールバー ---------------------------------------------------------------------

export function requestSessionsRefresh() {
  sessionsEmpty.textContent = t('recordings.sessions.loading');
  sessionsEmpty.style.display = 'flex';
  vscode.postMessage({ type: 'recordingsRefresh' });
}

refreshBtn.addEventListener('click', requestSessionsRefresh);
backBtn.addEventListener('click', () => {
  showListView();
  requestSessionsRefresh();
});

// タブ活性化のたびにセッション一覧を更新する(一覧ビュー表示中のみ。再生ビュー中は保持)。
document.addEventListener('ft-tab-activated', (event) => {
  if (event.detail?.tab === 'recordings' && playerView.style.display === 'none') {
    requestSessionsRefresh();
  }
});

// ---- ペイン幅スプリッター --------------------------------------------------------------
// カラム順は [動画 | ツリー | エラー一覧]。ドラッグ可能なのは動画|ツリー間のみで、動画幅を
// px でピン止めする。ツリーとエラー一覧はともに flex:1 のまま触らない = 残り幅を常に 1:1 で
// 等分し、表示エリアの変化にも自動追従する(ユーザー指定)。ツリー|エラー一覧間のバーは
// 静的な仕切り(CSS .splitter-static)でドラッグ不可。
// 動画幅は setState で同一パネル生存中は復元される。liveTab.js と同じ pointer capture 方式。

const VIDEO_MIN_WIDTH = 200;
// ツリー+エラー一覧の等分に最低幅(140px×2相当)を残す。
const VIDEO_MAX_RATIO = 0.7;

const videoPane = playerView.querySelector('.recordings-video-pane');

function applyVideoWidth(width) {
  const bodyWidth = recordingsBody.clientWidth;
  const max = Math.max(VIDEO_MIN_WIDTH, bodyWidth * VIDEO_MAX_RATIO);
  const clamped = Math.round(Math.min(Math.max(width, VIDEO_MIN_WIDTH), max));
  videoPane.style.flex = `0 0 ${clamped}px`;
  return clamped;
}

if (typeof persistedState.recordingsVideoWidth === 'number' && persistedState.recordingsVideoWidth > 0) {
  applyVideoWidth(persistedState.recordingsVideoWidth);
}

{
  let pointerId = null;
  let startX = 0;
  let startWidth = 0;
  let currentWidth = null;

  treeSplitter.addEventListener('pointerdown', (event) => {
    if (event.button !== 0) {
      return;
    }
    pointerId = event.pointerId;
    startX = event.clientX;
    startWidth = videoPane.getBoundingClientRect().width;
    treeSplitter.setPointerCapture(event.pointerId);
    treeSplitter.classList.add('dragging');
    event.preventDefault();
  });
  treeSplitter.addEventListener('pointermove', (event) => {
    if (pointerId !== event.pointerId) {
      return;
    }
    // 動画はスプリッターの左なので +dx で拡大。
    currentWidth = applyVideoWidth(startWidth + (event.clientX - startX));
  });
  const endDrag = (event) => {
    if (pointerId !== event.pointerId) {
      return;
    }
    pointerId = null;
    treeSplitter.classList.remove('dragging');
    treeSplitter.releasePointerCapture(event.pointerId);
    if (currentWidth != null) {
      vscode.setState(Object.assign({}, vscode.getState(), { recordingsVideoWidth: currentWidth }));
    }
  };
  treeSplitter.addEventListener('pointerup', endDrag);
  treeSplitter.addEventListener('pointercancel', endDrag);
}
