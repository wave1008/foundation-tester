// デバイスモニターの「ライブ操作」タブ(#panel-live)の UI 本体。src/webview/monitor/main.js が
// applyLiveMessage を message ディスパッチャに組み込む。host への送信は type:'live' の封筒で包む
// (対向: src/liveModel.ts の LiveWebviewEnvelope、処理は src/monitorLiveController.ts。
// host 側の窓口は src/liveTabHost.ts)。

import { t } from '../i18n.js';
import { vscode, persistedState } from './vscodeApi.js';
import { clampMenuPosition } from './menu.js';
import { createH264Renderer } from './h264Decoder.js';
import { displayAspect, fitScreenSize } from './liveScreenFit.js';
import { thinTracePoints } from './traceThinning.js';

function post(message) {
  vscode.postMessage({ type: 'live', message });
}

const deviceSelect = document.getElementById('live-device-select');
const deviceWarning = document.getElementById('live-device-warning');
const busyLabel = document.getElementById('live-busy-label');
const banner = document.getElementById('live-banner');

const screenshot = document.getElementById('live-screenshot');
const screenshotPane = document.getElementById('live-screenshot-pane');
const screenshotActions = document.getElementById('live-screenshot-actions');
const screenshotWrap = document.getElementById('live-screenshot-wrap');
// monitorHtml.ts は変更対象外のため canvas はここで生成し img の直後・オーバーレイ群の手前に挿す
// (オーバーレイは絶対配置なので DOM 順序がそのまま重なり順になる)。表示切替は screenshot と同じ
// '.visible' クラス方式(style.css で #live-screenshot と併記)。
const liveCanvas = document.createElement('canvas');
liveCanvas.id = 'live-canvas';
const hoverBox = document.getElementById('live-hover-box');
const boxesOverlay = document.getElementById('live-boxes-overlay');
screenshotWrap.insertBefore(liveCanvas, hoverBox);
const screenshotPlaceholder = document.getElementById('live-screenshot-placeholder');
const dragOverlay = document.getElementById('live-drag-overlay');
const dragLine = document.getElementById('live-drag-line');
const dragStartDot = document.getElementById('live-drag-start');
const traceToggle = document.getElementById('live-btn-trace-toggle');
const connOverlay = document.getElementById('live-conn-overlay');
const connDetail = document.getElementById('live-conn-detail');
// bridgeStarting(ブリッジの自動起動が進行中)専用の中立表示。conn-overlay(エラー)とは別要素
// (host: monitorLiveController.ts の applyBridgeStarting・文言は monitorHtml.ts で host 側 t() 済み)。
const connectingOverlay = document.getElementById('live-connecting-overlay');
const busyOverlay = document.getElementById('live-busy-overlay');
const busyMessage = document.getElementById('live-busy-message');

const typeTextInput = document.getElementById('live-type-text');
const actionError = document.getElementById('live-action-error');
const actionErrorText = document.getElementById('live-action-error-text');
const actionErrorClose = document.getElementById('live-action-error-close');
const staleNotice = document.getElementById('live-stale-notice');
const staleNoticeText = document.getElementById('live-stale-notice-text');
const showBoxesToggle = document.getElementById('live-show-boxes');
const elementsList = document.getElementById('live-elements-list');
const oplogList = document.getElementById('live-oplog-list');
const oplogClearBtn = document.getElementById('live-btn-oplog-clear');
const elementsSection = document.getElementById('live-elements-section');
const listsSplitter = document.getElementById('live-lists-splitter');
const screenSplitter = document.getElementById('live-screen-splitter');

const appProfileSelect = document.getElementById('live-app-profile-select');
const recordBtn = document.getElementById('live-btn-record');
const recordStatus = document.getElementById('live-record-status');
const installBtn = document.getElementById('live-btn-install');
const launchBtn = document.getElementById('live-btn-launch');
const appProfileNameEl = document.getElementById('live-app-profile-name');
const appProfileBundleEl = document.getElementById('live-app-profile-bundle');
const appProfilePathEl = document.getElementById('live-app-profile-path');
// 画像右クリックの開始/終了メニュー(#live-btn-record と同じ start/stop フローを流す)。
const recordMenu = document.getElementById('live-record-menu');
const recordMenuStart = document.getElementById('live-record-menu-start');
const recordMenuStop = document.getElementById('live-record-menu-stop');
let recordMenuOpen = false;

const STATE_LABEL = {
  connected: t('wvMonitor.live.stateConnected'),
  booted: t('wvMonitor.deviceState.booting'),
  offline: t('wvMonitor.deviceState.offline'),
  unknown: t('wvMonitor.live.stateUnknown'),
};

let currentDevices = [];
let lastScreen = null;
let lastElements = [];
let busy = false;
// frame 受信時の自動全量更新(refreshSnapshot)の一回制御。applySnapshot で false に戻す。
let autoSnapshotRequested = false;
// host からの 'recording' メッセージのみが更新する(host が唯一の真実。ボタン押下では変えない)。
let recording = false;
// テストコード生成中(stopRecord→gen-scenario 完了まで)。この間は「レコーディング終了」を非活性表示。
let generating = false;
// 選択可能なアプリプロファイルの有無(applyAppProfiles が更新)。無い間は開始不可。
let hasAppProfile = false;
// 選択中プロファイルの appPath(インストール可否判定)。null=不可(システムアプリ・ビルド無し等)。
let installableAppPath = null;
// 選択中プロファイルの bundle/アプリID(起動可否判定)。null=不可(現 platform 用の定義なし)。
let launchableBundle = null;
// デバイス画像 pane の手動幅[px](右のスプリッターでドラッグ調整)。null=自動フィット(画像実寸ハグ)。
// 永続化: vscode.setState の liveScreenWidth。fitScreenshot が非 null のとき pane を固定幅にする。
let screenPaneWidth =
  typeof persistedState.liveScreenWidth === 'number' && persistedState.liveScreenWidth > 0
    ? persistedState.liveScreenWidth
    : null;
// h264 描画中(canvas 表示・screenshot img 非表示)かどうか。liveH264ErrorSent は codecError
// 送信済みガード(scope:'live' はデバイス紐付けが無いため単一フラグ。デバイス切替時にリセットする)。
let liveRenderer = null;
let liveUsingH264 = false;
let liveH264ErrorSent = false;
// キーフレーム未受信のまま届いたデルタチャンク数と streamStall 送信済みフラグ(タイル側 deviceTiles.js と同型)
let liveDeltasBeforeKey = 0;
let liveStallSent = false;
// **画面が動いて、止まったら一度だけ撮り直す**。操作の応答(絵と木)は操作直後の1枚なので、
// 遷移の途中やアプリが遅れて出すもの(システムアラート等)を捉えられない —— 絵はクロスフェードの
// 途中で止まり、木にはアラートが1要素も載らない。
// **遷移の完了は待たない** —— 操作の応答はそのまま返し、あとから撮り直して差し替える。
// 予約は絵が動くたび(h264 チャンク)に先送りするので、アニメーションが長くても末尾で1回だけ撃つ。
// 値: 既定 12fps の配信で数フレーム分の空白を「止まった」と見なす長さ。短くするとアニメーションの
// 途中で撃ち、長くすると追随が遅れる。
// 尽きたとき: 画面が動かないまま内容だけ変わる場合は追随しない(一覧の「更新」で撮り直す)。
const SETTLE_REFRESH_MS = 700;
// 「バウンディングボックスを表示」を ON にしたときに静定を待つ上限(ms)。
// **ループするアニメーションの画面は何秒待っても静まらない**ので必ず打ち切る —— DSL の整定
// (Sources/FTCore/StepExecutor+Settle.swift・SettleMotion.swift)と同じ考え方で、あちらも
// 基本予算 scrollSettleMaxPolls=6 周を超えて回すのは**減速が続いている間だけ**、絶対上限
// scrollSettleMaxDeceleratingPolls=24 周(= 4 倍)で必ず抜ける(等速で動き続けるアニメーションを
// 待つと毎回上限まで待つことになるため)。webview が毎周見られるのは「絵が動いたか」だけで
// 減速かどうかの判定材料(木の変位)が無いので、借りるのは**この 4 倍だけ**。
// 尽きたとき: 打ち切って最新の木で描く(動いている画面の枠を出さないより、止まらない画面で
// 永久に出ないほうが害が大きい)。
const BOXES_SETTLE_CAP_MS = SETTLE_REFRESH_MS * 4;
// 要素の枠を画像に重ねて出すか(「バウンディングボックスを表示」)。vscode.setState に永続化。
let showBoxes = persistedState.liveShowBoxes === true;
// 枠を消してから**次の木が届くまで**は描き直さない。fitScreenshot も枠を引き直すので、
// これが無いと画像のサイズが変わった拍子に古い木の枠が復活する
// (実害 2026-09-22: タスクスイッチャーを出すと直前の画面の枠が出たまま残った)。
let boxesStale = false;
let settleRefreshTimer = null;
// ON にした直後の静定待ちの打ち切りタイマー(BOXES_SETTLE_CAP_MS)。待っていない間は null。
let boxesSettleCapTimer = null;
// 静定待ち中(deferBoxesUntilSettled が立て、静定後の木か打ち切りで畳む)。**操作の直後に返る木で
// 描かない**ための印 —— あの木はまだ慣性で動いている最中のことがあり、描くと中間の座標で一度出て
// 止まってからもう一度出る(2026-09-23 の実害: 設定画面のスクロール)。
let boxesAwaitSettle = false;
// 撮り直しとして要求した snapshot か(その結果でまた仕掛けると静止画面で撮り続ける)。
let settleRefreshRequested = false;

const busyButtons = [
  'live-btn-refresh-devices', 'live-btn-refresh-snapshot',
  'live-btn-app-switcher', 'live-btn-home',
  'live-btn-zoom-in', 'live-btn-zoom-out',
].map((id) => document.getElementById(id));

function setBusy(value) {
  busy = value;
  for (const b of busyButtons) { b.disabled = value; }
  deviceSelect.disabled = value;
  busyLabel.textContent = value ? t('wvMonitor.live.processing') : '';
  // **操作を撃った時点で枠を消す**(ユーザー決定 2026-09-22) —— これから画面が変わるので、
  // 古い木から描いた枠はもう画面と合わない。操作の結果が届いたら renderBoxes が引き直す。
  // 要素一覧は消さない(読んでいる最中に行が消えると追えない。あちらは「更新」で入れ替わる)
  //
  // **撮り直し(scheduleSettleRefresh)の間は消さない** —— あれは画面を変えない観測で、
  // 消すと遷移後に「出る → 消える → 出る」とちらつく(2026-09-22)
  if (value && !settleRefreshRequested) { deferBoxesUntilSettled(); }
  // 「レコーディング開始」も busy を見る(updateRecordButton が updateProfileActionButtons を呼ぶ)
  updateRecordButton();
}

const DETAIL_UNSET = t('wvMonitor.live.detailUnset');
// インストール(appPath 必須)/アプリを起動(bundle 必須)の活性を busy/recording/generating と
// 選択中プロファイルの解決結果から一元的に決める。
function updateProfileActionButtons() {
  const blocked = busy || recording || generating;
  installBtn.disabled = blocked || !installableAppPath;
  launchBtn.disabled = blocked || !launchableBundle;
}
function applyAppProfileDetail(message) {
  appProfileNameEl.textContent = message.appName || DETAIL_UNSET;
  appProfileBundleEl.textContent = message.bundle || DETAIL_UNSET;
  appProfilePathEl.textContent = message.appPath || DETAIL_UNSET;
  appProfilePathEl.title = message.appPath || '';
  installableAppPath = message.appPath || null;
  launchableBundle = message.bundle || null;
  updateProfileActionButtons();
}
function clearAppProfileDetail() {
  appProfileNameEl.textContent = DETAIL_UNSET;
  appProfileBundleEl.textContent = DETAIL_UNSET;
  appProfilePathEl.textContent = DETAIL_UNSET;
  appProfilePathEl.title = '';
  installableAppPath = null;
  launchableBundle = null;
  updateProfileActionButtons();
}

function showBanner(text) {
  if (!text) { banner.classList.remove('visible'); banner.textContent = ''; return; }
  banner.textContent = text;
  banner.classList.add('visible');
}

// neutral: true は bridgeStarting 中の操作失敗(live.bridgeStartingActionNotice)専用。
// エラー色にしない(#live-action-error.neutral。style.css 参照)
function showActionError(text, neutral) {
  if (!text) {
    actionError.classList.remove('visible');
    actionError.classList.remove('neutral');
    actionErrorText.textContent = '';
    return;
  }
  actionErrorText.textContent = text;
  actionError.classList.toggle('neutral', !!neutral);
  actionError.classList.add('visible');
}
// **利用者が消せる口** —— 自動で消えるのは host が復帰を検知した接続系の文言だけで、
// ブリッジ接続拒否のように serve が返す文言は次の失敗で上書きされるまで残る。
actionErrorClose.addEventListener('click', () => showActionError(''));

// snapshot.notes(鮮度警告等。エラーではないので actionError とは別枠)。閉じる口は無く、
// 次の観測で notes が空になれば自動で消える(applySnapshot/clearSnapshot から呼ぶ)。
function showStaleNotice(notes) {
  if (!notes || notes.length === 0) {
    staleNotice.classList.remove('visible');
    staleNoticeText.textContent = '';
    return;
  }
  staleNoticeText.textContent = notes.join('\n');
  staleNotice.classList.add('visible');
}

// ---- デバイス選択 ---------------------------------------------------------------

function updateDeviceWarning() {
  const selected = currentDevices.find((d) => d.id === deviceSelect.value);
  deviceWarning.textContent = selected && selected.state !== 'connected' ? t('wvMonitor.live.notConnectedWarning') : '';
}

function applyDevices(devices, selectedId) {
  currentDevices = devices;
  deviceSelect.innerHTML = '';
  for (const d of devices) {
    const opt = document.createElement('option');
    opt.value = d.id;
    // 他の機械の台は機械名も出す(同じ名前の台がこの Mac にも居ることがある)
    opt.textContent = d.name + '(' + d.platform + (d.machine ? ' / ' + d.machine : '') + ') - '
      + (STATE_LABEL[d.state] || d.state);
    deviceSelect.appendChild(opt);
  }
  if (selectedId) { deviceSelect.value = selectedId; }
  updateDeviceWarning();
}

deviceSelect.addEventListener('change', () => {
  updateDeviceWarning();
  // 前のデバイスの絵・木をその場で捨てる(host の clearSnapshot を待つと、serve の張り替えが
  // 終わるまで前のデバイスの画面が出たままになる)。disposeLiveH264 より先: あちらは src が
  // 残っていると一枚絵を前面へ戻す。
  clearSnapshot();
  // デバイス切替=新しい配信セッション。前デバイスの codecError 済みガードを引きずらない。
  disposeLiveH264();
  liveH264ErrorSent = false;
  post({ type: 'selectDevice', id: deviceSelect.value });
});

// ---- レコーディング(対向: monitorLiveController.ts / liveModel.ts) --------------

function applyAppProfiles(profiles, selectedId) {
  appProfileSelect.innerHTML = '';
  hasAppProfile = profiles.length > 0;
  if (!hasAppProfile) {
    const opt = document.createElement('option');
    opt.value = '';
    opt.textContent = t('wvMonitor.live.noAppProfile');
    opt.disabled = true;
    opt.selected = true;
    appProfileSelect.appendChild(opt);
    clearAppProfileDetail();
    updateRecordButton();
    return;
  }
  for (const profile of profiles) {
    const opt = document.createElement('option');
    opt.value = profile;
    opt.textContent = profile;
    appProfileSelect.appendChild(opt);
  }
  appProfileSelect.value = selectedId && profiles.includes(selectedId) ? selectedId : profiles[0];
  updateRecordButton();
}

function applyRecording(active, isGenerating) {
  recording = active;
  generating = !!isGenerating;
  updateRecordButton();
}

// ボタンの文言・活性を recording/generating/hasAppProfile から一元的に決める。
// - 生成中(generating): 「レコーディング終了」を非活性で表示(gen-scenario 完了まで)。
// - 録画中(recording): 「レコーディング終了」を活性(終了操作を妨げない)。
// - 停止中: 「レコーディング開始」。選択可能なプロファイルが無ければ非活性。
function updateRecordButton() {
  const showStop = recording || generating;
  recordBtn.textContent = showStop ? t('wvMonitor.live.recordStop') : t('wvMonitor.live.recordStart');
  recordBtn.classList.toggle('recording', showStop);
  recordBtn.disabled = generating || (!recording && (!hasAppProfile || busy));
  appProfileSelect.disabled = recording || generating;
  updateRecordMenuItems();
  updateProfileActionButtons();
}

// 画像右クリックメニューの開始/終了の活性を updateRecordButton と同条件で同期(開いている間に
// 状態が変わっても追随する)。開始=停止中かつ生成中でなくプロファイル有り、終了=録画中かつ生成中でない。
function updateRecordMenuItems() {
  recordMenuStart.disabled = recording || generating || !hasAppProfile || busy;
  recordMenuStop.disabled = !recording || generating;
  recordMenuStart.title = (!recording && !generating && !hasAppProfile) ? t('wvMonitor.live.appProfileRequired') : '';
}

recordBtn.addEventListener('click', () => {
  if (generating) { return; } // 生成中は非活性だが二重防御(押下しても何もしない)
  if (recording) {
    post({ type: 'stopRecord' });
  } else {
    // 自動インストールは常に有効(チェックボックスは置かない)。host 側は appPath があれば install→launch する。
    post({ type: 'startRecord', appProfile: appProfileSelect.value, autoInstall: true });
  }
});

appProfileSelect.addEventListener('change', () => {
  post({ type: 'selectAppProfile', appProfile: appProfileSelect.value });
});

installBtn.addEventListener('click', () => {
  if (installBtn.disabled) { return; }
  post({ type: 'installApp', appProfile: appProfileSelect.value });
});

launchBtn.addEventListener('click', () => {
  if (launchBtn.disabled) { return; }
  post({ type: 'launchApp', appProfile: appProfileSelect.value });
});

// 画像上で右クリック → 開始/終了メニュー。stopPropagation で document の contextmenu→閉じるを抑止
// (このメニュー自身は即閉じない)。start/stop は recordBtn と同一フロー。
screenshotWrap.addEventListener('contextmenu', (event) => {
  event.preventDefault();
  event.stopPropagation();
  updateRecordMenuItems();
  recordMenu.classList.add('visible');
  clampMenuPosition(recordMenu, event.clientX, event.clientY);
  recordMenuOpen = true;
});
function closeLiveRecordMenu() {
  if (!recordMenuOpen) { return; }
  recordMenuOpen = false;
  recordMenu.classList.remove('visible');
}
recordMenuStart.addEventListener('click', (event) => {
  event.stopPropagation();
  if (recordMenuStart.disabled) { return; }
  post({ type: 'startRecord', appProfile: appProfileSelect.value, autoInstall: true });
  closeLiveRecordMenu();
});
recordMenuStop.addEventListener('click', (event) => {
  event.stopPropagation();
  if (recordMenuStop.disabled) { return; }
  post({ type: 'stopRecord' });
  closeLiveRecordMenu();
});
// 閉じる契機(deviceTiles.js の device-op-menu と同じ組。scroll は capture で子要素のスクロールも拾う)。
document.addEventListener('click', (event) => {
  if (recordMenuOpen && !recordMenu.contains(event.target)) { closeLiveRecordMenu(); }
});
document.addEventListener('keydown', (event) => { if (event.key === 'Escape') { closeLiveRecordMenu(); } });
document.addEventListener('scroll', () => closeLiveRecordMenu(), true);
window.addEventListener('resize', () => closeLiveRecordMenu());
document.addEventListener('contextmenu', () => closeLiveRecordMenu());

// ---- スクリーンショット(クリック=タップ、ドラッグ=スワイプ、要素ホバー=枠オーバーレイ) ------

// 画像を上寄せ・スクロールなしで収める。frame は内容フィット(flex:0 0 auto)で画像実寸に縮むため
// frame 自体の高さは画像に依存し測れない(循環する)。代わりに高さが flex で確定する
// #live-screenshot-pane を実測し、そこから actions 高と pane の gap を引いた残りを画像 max-height に
// する。object-fit は使えない(overlay が inset:0 で wrap に貼り付き、タップ座標も
// img.getBoundingClientRect() 前提のため、要素ボックスを実画像サイズに保つ必要がある)。
const SCREENSHOT_WRAP_BORDER = 2; // .screenshot-wrap の上下ボーダー合計(px)。CSS と一致させること
const SCREENSHOT_PANE_GAP = 6;    // .screenshot-pane の gap(px)。CSS と一致させること

// タップ/ドラッグ/ホバー枠は screenshot と liveCanvas のうち現在表示中の方を基準にする
// (どちらか一方だけが'.visible'で、サイズ・座標系は等価に保つ前提)。
// **liveUsingH264 では決めない** —— あれは「デコーダが生きている」であって、前面に出ているのが
// どちらかとは別(配信が次のフレームを描くまでは snapshot の一枚絵を前に出す。showStill/showCanvas)。
function activeScreenEl() {
  return liveCanvas.classList.contains('visible') ? liveCanvas : screenshot;
}

// 前面に出すのはどちらか一方だけ。**デコーダには触らない**(捨てると次のキーフレームまで
// 1枚も描けず、タップのたびに映像が数秒止まる)。
// **撮り直しの予約はここでは落とさない** —— 配信が描けても持っているのは絵だけで、木は
// 操作時のものから動かない(アラートが出ても要素一覧・枠が前の画面のままだった)。
/** 絵を前面に出す2経路(showStill/showCanvas)の共通後始末。placeholder を隠すだけでなく
 * 「絵が来るまで」のレイアウト(awaiting-image: 枠を左右いっぱいに伸ばす)も解く。 */
function hidePlaceholder() {
  screenshotPlaceholder.style.display = 'none';
  screenshotPane.classList.remove('awaiting-image');
}
/** hidePlaceholder の逆。**前のデバイスの絵を捨てて** placeholder の状態へ戻す(clearSnapshot)。
 * src を消すのが要点 —— 残すと切り替え後も前のデバイスの画面が出たままになり、しかも lastScreen は
 * 捨てられているのでポインタ操作は無反応(=生きた画面に見える静止画)になる。 */
function showPlaceholder() {
  screenshot.classList.remove('visible');
  liveCanvas.classList.remove('visible');
  screenshot.removeAttribute('src');
  screenshotPlaceholder.style.display = '';
  screenshotPane.classList.add('awaiting-image');
  fitScreenshot();
}
function showStill() {
  liveCanvas.classList.remove('visible');
  screenshot.classList.add('visible');
  hidePlaceholder();
}
function showCanvas() {
  screenshot.classList.remove('visible');
  liveCanvas.classList.add('visible');
  hidePlaceholder();
}

function cancelSettleRefresh() {
  if (settleRefreshTimer !== null) {
    clearTimeout(settleRefreshTimer);
    settleRefreshTimer = null;
  }
}

function cancelBoxesSettleCap() {
  if (boxesSettleCapTimer !== null) {
    clearTimeout(boxesSettleCapTimer);
    boxesSettleCapTimer = null;
  }
}

/** 枠を出すのは画面が静定してからにする(ユーザー決定 2026-09-23)。手元の木は最後に観測した
 * 時点のものなので、絵がまだ動いている間に描くと**前の画面の位置に枠が出る**。
 * 静定 = 絵が SETTLE_REFRESH_MS 動かないこと(scheduleSettleRefresh の予約は絵が動くたびに
 * 先送りされる)。止まったら撮り直しが届き、applySnapshot が boxesStale を落として描く。
 * **ループするアニメーションは静定しない**ので BOXES_SETTLE_CAP_MS で打ち切り、その時点の
 * 最新の木で描く(定数の doc 参照)。 */
function deferBoxesUntilSettled() {
  boxesAwaitSettle = true;
  clearBoxes();            // 届くまで描かない(boxesStale)
  scheduleSettleRefresh(); // 絵が止まったら撮り直す(動いている間は先送りされる)
  cancelBoxesSettleCap();
  armBoxesSettleCap(BOXES_SETTLE_CAP_MS);
}
// **busy 中に鳴ったら諦めずに待ち直す**(遅い台 = リモート・実機は1操作に数秒かかり、静定も打ち切りも
// 必ず busy 中に鳴る)。諦めると、操作の結果が失敗(木が来ない)だった回は枠が永久に出ず、
// トグルを入れ直しても撮り直しが飛ばなかった(実地 2026-09-24: M1Ultra 経由の iPhone wave)
function armBoxesSettleCap(delayMs) {
  boxesSettleCapTimer = setTimeout(() => {
    boxesSettleCapTimer = null;
    if (!showBoxes || !boxesStale) { return; } // 既に描けた
    if (busy) { armBoxesSettleCap(SETTLE_REFRESH_MS); return; } // 操作中。結果の木が来なくても次で撃つ
    settleRefreshRequested = true; // 画面を変えない観測 = 次の applySnapshot で再予約しない
    post({ type: 'refreshSnapshot' });
  }, delayMs);
}
function scheduleSettleRefresh() {
  cancelSettleRefresh();
  settleRefreshTimer = setTimeout(() => {
    settleRefreshTimer = null;
    if (!lastScreen) { return; }
    if (busy) { scheduleSettleRefresh(); return; } // 操作中は待ち直す(結果の木が来れば予約は引き直される)
    settleRefreshRequested = true;
    post({ type: 'refreshSnapshot' });
  }, SETTLE_REFRESH_MS);
}
// img は naturalWidth/Height、canvas はビットマップ実寸(h264Decoder が frame.displayWidth/Height に
// 合わせて設定済み)で自然サイズを取る。
function naturalSize(el) {
  return el === liveCanvas ? { w: el.width, h: el.height } : { w: el.naturalWidth, h: el.naturalHeight };
}

function fitScreenshot() {
  const paneH = screenshotPane.clientHeight;
  if (paneH === 0) { return; } // タブ非表示中(display:none)は測れないので触らない
  const avail = paneH - screenshotActions.offsetHeight - SCREENSHOT_PANE_GAP - SCREENSHOT_WRAP_BORDER;
  const maxH = Math.max(40, avail);
  // **絵そのものには幅・高さを入れない**。上限(max-width/max-height)だけ与えて、縦横比は
  // 絵に決めさせる —— 寸法を明示すると、screen が実画面と食い違った回にその比へ引き伸ばされる
  // (実害 2026-09-22: セッションがウィジェットの裏方を向いて screen が 349x565 になり、
  //  0.46 の絵が 0.618 へ横に膨らんだ)。**絵の比は常に正しい**ので、こちらを信じる。
  // screen は pane の幅を決めるためだけに使う(下)。
  // 絵がまだ無い間の placeholder も絵と同じ高さまで伸ばす(CSS は box-sizing:border-box)。
  // 中身の高さのままだと縦に縮んだ箱で待つことになり、最初のフレームが届いた瞬間に
  // ペインの高さが変わってレイアウトが組み直る。
  screenshotPlaceholder.style.height = maxH + 'px';
  const aspect = displayAspect(lastScreen, naturalSize(activeScreenEl()));
  const widthCap = screenPaneWidth != null ? screenPaneWidth - SCREENSHOT_WRAP_BORDER : undefined;
  const size = fitScreenSize(aspect, maxH, widthCap);
  for (const el of [screenshot, liveCanvas]) {
    el.style.maxHeight = maxH + 'px';
    el.style.width = '';
    el.style.height = '';
  }
  // スプリッターで手動幅が設定されているときは pane を固定幅にする(自動ハグの maxWidth 計算はしない)。
  if (screenPaneWidth != null) {
    screenshotPane.style.flex = '0 0 ' + screenPaneWidth + 'px';
    screenshotPane.style.maxWidth = screenPaneWidth + 'px';
    return;
  }
  screenshotPane.style.flex = '';
  // pane 幅を画像の表示幅に合わせて縮める → 右隣の control-pane(要素一覧)が画像直後へ左寄せで
  // 並ぶ(伸ばすと右端へ押しやられる)。flex-basis:auto の max-content が画像の自然幅になる
  // 実装差(Chromium)を避けるため確定値を JS で入れる。比が分かるまでは cap を外し
  // placeholder 幅(min-width)に委ねる。
  screenshotPane.style.maxWidth = size ? Math.ceil(size.width + SCREENSHOT_WRAP_BORDER) + 'px' : '';
  renderBoxes(); // 表示サイズが変わったら枠も引き直す
}
// pane の高さは flex で決まり画像内容に依存しない(=maxHeight/maxWidth 変更で再発火しない)ため無限ループ無し。
if (typeof ResizeObserver !== 'undefined') {
  new ResizeObserver(fitScreenshot).observe(screenshotPane);
}
window.addEventListener('resize', fitScreenshot);
// data URI のデコードは非同期で src セット直後は naturalWidth=0。load 後に幅ハグを確定させる。
screenshot.addEventListener('load', fitScreenshot);

// liveH264Chunk のレンダラ破棄(codecError 送信後、mjpeg フォールバック復帰、デバイス切替のいずれか)。
// 呼び出し後は screenshot(img)側の表示に戻る前提(呼び出し元が classList を扱う)。
function disposeLiveH264() {
  liveUsingH264 = false;
  liveDeltasBeforeKey = 0;
  liveStallSent = false;
  // **canvas を降りたら一枚絵を前に出す** —— 両方隠れると wrap の背景色が見えて画面が
  // 真っ黒になる(実害 2026-09-22: Spotlight でキーボードが出た直後。デコードエラーからの
  // mjpeg フォールバックは host 側の切り替えを挟むので、その間ずっと黒いままだった)。
  // 絵をまだ1枚も受けていないときは placeholder のままにする
  if (screenshot.getAttribute('src')) {
    showStill();
  } else {
    liveCanvas.classList.remove('visible');
  }
  if (liveRenderer) {
    liveRenderer.dispose();
    liveRenderer = null;
  }
}

// liveModel.ts の pointFromClick / hitTestElement と同じ規則(webview は CSP により import 不可の
// ため複製。liveModel.ts 側を変更したらここも追随させること)。返すのは ref だけで足りる。
function hitTestRefAt(clickX, clickY, display) {
  if (!lastScreen || display.width <= 0 || display.height <= 0) { return null; }
  const x = Math.min(Math.max((clickX / display.width) * lastScreen.width, 0), lastScreen.width);
  const y = Math.min(Math.max((clickY / display.height) * lastScreen.height, 0), lastScreen.height);
  let best = null;
  let bestArea = Infinity;
  for (const element of lastElements) {
    const f = element.frame;
    if (x < f.x || x > f.x + f.width || y < f.y || y > f.y + f.height) { continue; }
    const area = f.width * f.height; // 重なりの中で最も具体的なもの = 面積最小
    if (area < bestArea) { bestArea = area; best = element.ref; }
  }
  return best;
}

// liveModel.ts の frameToDisplayRect と同じ計算(webview は CSP により import 不可のため複製。
// liveModel.ts 側を変更したらここも追随させること)。
function frameToDisplayRect(frame, screen, display) {
  if (screen.width <= 0 || screen.height <= 0) {
    return { x: 0, y: 0, width: 0, height: 0 };
  }
  const scaleX = display.width / screen.width;
  const scaleY = display.height / screen.height;
  return {
    x: frame.x * scaleX, y: frame.y * scaleY,
    width: frame.width * scaleX, height: frame.height * scaleY,
  };
}

// デバイスが切り替わった(host の clearSnapshotCache)。前のデバイスの画面サイズ・要素一覧で
// タップ座標を換算したり ref を叩いたりしないよう捨てる。lastScreen が null の間は
// ポインタ操作が無反応になり、次のフレームで requestSnapshotIfNeeded が撮り直しを要求する。
function clearSnapshot() {
  clearBoxes(); // 消してから stale にする(先に stale だけ立てると overlay が空にならない)
  cancelSettleRefresh();
  cancelBoxesSettleCap();
  boxesAwaitSettle = false;
  settleRefreshRequested = false;
  lastScreen = null;
  lastElements = [];
  autoSnapshotRequested = false;
  hideHover();
  renderElements();
  showStaleNotice([]); // 前のデバイスの鮮度警告を持ち越さない
  showPlaceholder();   // 前のデバイスの絵も捨てる(showPlaceholder の doc)
}

function applySnapshot(message) {
  lastScreen = message.screen;
  lastElements = message.elements;
  // 枠を描いてよいのは**静定してから観測した木**だけ(boxesAwaitSettle の doc)。待っていない
  // (操作もトグルも挟んでいない)ときは従来どおり届いた木で描く。
  if (settleRefreshRequested || !boxesAwaitSettle) {
    boxesStale = false;
    boxesAwaitSettle = false;
    cancelBoxesSettleCap();
  }
  autoSnapshotRequested = false;
  showStaleNotice(message.notes);
  // 届いた一枚絵は**操作の結果そのもの**(host は tap のあとに撮って返す)。配信より新しいので
  // 常に前面へ出す —— 配信は静止画面でエンコードを止めるため、出さずに待つと次のキーフレームが
  // 来るまで古い絵が残る(実測 10 秒超。simstream の MaxKeyFrameIntervalDuration は 4 秒だが、
  // 変化が無い間はそもそもエンコードされない)。
  // **デコーダは捨てない** —— 捨てると作り直しになり、キーフレーム待ちの間 1 枚も描けなくなる
  // (タップのたびに映像が止まっていた退行そのもの)。生かしたまま前面を入れ替えるだけにして、
  // 次のフレームが描けた時点で showCanvas が canvas を前に戻す。
  screenshot.src = 'data:image/jpeg;base64,' + message.image;
  showStill();
  hoverBox.style.display = 'none';
  renderElements();
  fitScreenshot();
  // 撮り直しの結果として届いた回は仕掛け直さない(静止画面で撮り続けることになる)
  if (settleRefreshRequested) {
    settleRefreshRequested = false;
  } else {
    scheduleSettleRefresh();
  }
}

// 押下→ほぼ動かさず離す=タップ、動かして離す=ドラッグ(スワイプ)。click は使わない
// (ドラッグ後にも click が発火してタップが重複するため)。座標は画像表示座標のまま送り、
// ポイント座標への変換は host 側(monitorLiveController.ts の pointFromClick)が行う。
// <img> 既定の HTML5 ドラッグ&ドロップ(緑の+コピーカーソル)が pointer イベントを乗っ取るため
// 無効化必須(style.css の -webkit-user-drag: none と対)。
screenshot.draggable = false;
screenshot.addEventListener('dragstart', (event) => event.preventDefault());
const DRAG_MIN_PX = 5;
const LONG_PRESS_MS = 500;
let dragStart = null; // el: pointerdown を受けた要素(screenshot か liveCanvas)。以後の rect 計算に使う

// デバイス側のスワイプは pointerup 時に1回で実行される(XCUITest にタッチ逐次移動 API が無く
// リアルタイム追従は不可)ため、ドラッグ中は構成中のジェスチャを軌跡オーバーレイで見せる。
function updateDragOverlay(start, x, y) {
  dragStartDot.setAttribute('cx', start.x);
  dragStartDot.setAttribute('cy', start.y);
  dragLine.setAttribute('x1', start.x);
  dragLine.setAttribute('y1', start.y);
  dragLine.setAttribute('x2', x);
  dragLine.setAttribute('y2', y);
  dragOverlay.classList.add('visible');
}
function hideDragOverlay() {
  dragOverlay.classList.remove('visible');
}

// 「軌跡」トグル(ツールバー)。ON の間、動かして離すドラッグは dragPoints(1回のスワイプ合成)
// ではなく tracePoints(離さない1本のタッチとして軌跡どおり再生)を送る。押下時に Shift を
// 押していた場合も同じ扱い(一時的な軌跡モード。トグルは変えない)。
traceToggle.addEventListener('click', () => {
  const pressed = traceToggle.getAttribute('aria-pressed') === 'true';
  traceToggle.classList.toggle('toggled', !pressed);
  traceToggle.setAttribute('aria-pressed', pressed ? 'false' : 'true');
});
function isTraceToggleOn() {
  return traceToggle.getAttribute('aria-pressed') === 'true';
}

function handleScreenPointerDown(event) {
  if (busy || !lastScreen || event.button !== 0) { return; }
  // 既定動作(画像ドラッグ・テキスト選択の開始)の抑止。dragstart 抑止だけでは環境により
  // ネイティブドラッグが始まることがあるため両方必要。
  event.preventDefault();
  const el = event.currentTarget;
  const rect = el.getBoundingClientRect();
  const downAt = performance.now();
  dragStart = {
    x: event.clientX - rect.left, y: event.clientY - rect.top, pointerId: event.pointerId,
    downAt, moveAt: null, el,
    // **押した時点の Alt を採る**(離すまでに押し直されても、利用者の意図は押下時のもの)。
    // ダブルタップは「素早く2回」では表せない —— パネルの1クリックは既にタップとして
    // 送っているので、2回目を待つと通常のタップが毎回遅くなる
    doubleTap: event.altKey,
    // **押した時点のトグル/Shift を採る**(doubleTap と同じ理由)。DRAG_MIN_PX 未満の
    // 移動(タップ/長押し/ダブルタップ)は軌跡モードでも今までどおり(下の pointerup 参照)
    trace: isTraceToggleOn() || event.shiftKey,
    points: [{ x: event.clientX - rect.left, y: event.clientY - rect.top, t: 0 }],
  };
  updateDragOverlay(dragStart, dragStart.x, dragStart.y);
  try {
    el.setPointerCapture(event.pointerId);
  } catch {
    // capture 不可でも window 側の pointerup で拾えるため無視してよい
  }
}
// screenshot(img)/liveCanvas は同時には片方しか表示されないが、両方に登録しておき
// 表示中の要素で受けたイベントの currentTarget を rect 計算に使う。
screenshot.addEventListener('pointerdown', handleScreenPointerDown);
liveCanvas.addEventListener('pointerdown', handleScreenPointerDown);

// 画像上のホバー = その点の要素(枠と一覧の行を対で光らせる)。**枠自身には当てない** ——
// SVG に pointer-events を入れると枠がクリックを吸ってタップが飛ばなくなるので、
// オーバーレイは透過のままにして、ここで当たり判定する。
function handleScreenHover(event) {
  const rect = event.currentTarget.getBoundingClientRect();
  // **枠が OFF でも一覧の行は光らせる**(どの要素を指しているかは分かったほうがよい)。
  // 違うのは見た目と一覧送りの2つだけ: 赤枠は枠が出ているときだけ(CSS の .boxes-on)、
  // 一覧のスクロールも同じく ON のときだけ(OFF で勝手に動くと読んでいる場所を見失う)。
  setHot(hitTestRefAt(event.clientX - rect.left, event.clientY - rect.top,
                      { width: rect.width, height: rect.height }), showBoxes);
}
for (const el of [screenshot, liveCanvas]) {
  el.addEventListener('pointermove', handleScreenHover);
  el.addEventListener('pointerleave', () => setHot(null, false));
}
window.addEventListener('pointermove', (event) => {
  if (!dragStart || event.pointerId !== dragStart.pointerId) { return; }
  const rect = dragStart.el.getBoundingClientRect();
  const x = Math.min(Math.max(event.clientX - rect.left, 0), rect.width);
  const y = Math.min(Math.max(event.clientY - rect.top, 0), rect.height);
  updateDragOverlay(dragStart, x, y);
  if (dragStart.moveAt === null && Math.hypot(x - dragStart.x, y - dragStart.y) >= DRAG_MIN_PX) {
    dragStart.moveAt = performance.now();
  }
  if (dragStart.trace) {
    dragStart.points.push({ x, y, t: Math.round(performance.now() - dragStart.downAt) });
  }
});
// pointerup は window で拾う(capture が効かない環境・画像外で離した場合も取りこぼさない)。
window.addEventListener('pointerup', (event) => {
  if (!dragStart || event.pointerId !== dragStart.pointerId) { return; }
  hideDragOverlay();
  const start = dragStart;
  dragStart = null;
  try {
    start.el.releasePointerCapture(event.pointerId);
  } catch {
    // 未 capture なら何もしない
  }
  if (busy || !lastScreen) { return; }
  const rect = start.el.getBoundingClientRect();
  // キャプチャ中は画像外で離せるため表示範囲にクランプする
  const endX = Math.min(Math.max(event.clientX - rect.left, 0), rect.width);
  const endY = Math.min(Math.max(event.clientY - rect.top, 0), rect.height);
  const upAt = performance.now();
  if (Math.hypot(endX - start.x, endY - start.y) < DRAG_MIN_PX) {
    const holdMs = Math.max(0, Math.round(upAt - start.downAt));
    if (start.doubleTap) {
      post({
        type: 'doubleTapPoint',
        clickX: endX, clickY: endY,
        displayWidth: rect.width, displayHeight: rect.height,
      });
    } else if (holdMs >= LONG_PRESS_MS) {
      post({
        type: 'pressPoint',
        clickX: endX, clickY: endY,
        displayWidth: rect.width, displayHeight: rect.height,
        holdMs: holdMs,
      });
    } else {
      post({
        type: 'tapPoint',
        clickX: endX, clickY: endY,
        displayWidth: rect.width, displayHeight: rect.height,
      });
    }
  } else if (start.trace) {
    const endT = Math.max(1, Math.round(upAt - start.downAt));
    const points = start.points.concat([{ x: endX, y: endY, t: endT }]);
    post({
      type: 'tracePoints',
      points: thinTracePoints(points),
      displayWidth: rect.width, displayHeight: rect.height,
    });
  } else {
    const moveAt = start.moveAt ?? upAt;
    post({
      type: 'dragPoints',
      fromX: start.x, fromY: start.y, toX: endX, toY: endY,
      displayWidth: rect.width, displayHeight: rect.height,
      pressMs: Math.max(0, Math.round(moveAt - start.downAt)),
      dragMs: Math.max(1, Math.round(upAt - moveAt)),
    });
  }
});
window.addEventListener('pointercancel', () => {
  dragStart = null;
  hideDragOverlay();
});

function showHover(element) {
  if (!lastScreen) { return; }
  const rect = activeScreenEl().getBoundingClientRect();
  const box = frameToDisplayRect(element.frame, lastScreen, { width: rect.width, height: rect.height });
  hoverBox.style.left = box.x + 'px';
  hoverBox.style.top = box.y + 'px';
  hoverBox.style.width = box.width + 'px';
  hoverBox.style.height = box.height + 'px';
  hoverBox.style.display = 'block';
}

function hideHover() {
  hoverBox.style.display = 'none';
}

// ---- バウンディングボックス(「バウンディングボックスを表示」トグル) ------------------------
// 画像に重ねて全要素の枠を出す。枠は SVG の <rect> をまとめて1つの要素に描く(要素ごとの div は
// 数百枚になると DOM が重い)。座標は hover 枠と同じ frameToDisplayRect(表示px)。
// **表示サイズが変わるたびに引き直す**(fitScreenshot・snapshot 受信・トグル操作)。

// 画像上でマウスが載っている要素。枠(SVG rect)と要素一覧の行を**対で**光らせるので、
// ref → それぞれの DOM を引けるようにしておく(描き直しのたびに作り直す)。
let hotRef = null;
const boxByRef = new Map();
const rowByRef = new Map();

// 強調は**専用の枠を1枚、最前面に重ねて**描く。既存の枠の色を変えるだけだと、SVG は DOM 順に
// 描かれるので後続の枠の下に隠れる(指した枠が見えないことがある)。
const hotBox = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
hotBox.setAttribute('class', 'hot');

function applyHot() {
  hotBox.remove(); // 位置も重なり順も残さない(必要なら下で最後に足し直す)
  if (hotRef === null) { return; }
  rowByRef.get(hotRef)?.classList.add('hot');
  const source = boxByRef.get(hotRef);
  if (!source) { return; } // 枠を出していない(トグル OFF)ときは行だけ光る
  for (const attribute of ['x', 'y', 'width', 'height']) {
    hotBox.setAttribute(attribute, source.getAttribute(attribute));
  }
  boxesOverlay.appendChild(hotBox); // **最後に足す = 最前面**
}
/** scrollList: 一覧を送ってよいか。**画像側で指したときだけ true** —— 行を直接ホバーしている
 * 最中に送ると、カーソルの下で一覧が動いて別の行に乗ってしまう。 */
function setHot(ref, scrollList) {
  if (ref === hotRef) { return; }
  if (hotRef !== null) {
    rowByRef.get(hotRef)?.classList.remove('hot');
  }
  hotRef = ref;
  applyHot();
  // 一覧の外にある行は見えるところまで送る。**'nearest'** = 既に見えていれば動かさない
  // (毎回中央に寄せると、マウスを少し動かすだけで一覧が跳ねる)。
  // 対象が変わった回だけ呼ぶ(applyHot は描き直しからも呼ばれるので、あちらには置かない)。
  if (ref !== null && scrollList) {
    rowByRef.get(ref)?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  }
}

/** 枠と強調をまとめて落とす(要素一覧の行はそのまま)。**次の木が届くまで描き直さない**。 */
function clearBoxes() {
  boxesStale = true;
  setHot(null, false);
  boxByRef.clear();
  hotBox.remove();
  boxesOverlay.classList.remove('visible');
  boxesOverlay.replaceChildren();
}

function renderBoxes() {
  // 行の見た目(赤枠を出すか)は CSS 側で分ける。**状態は一覧に持たせる** —— 行ごとに
  // クラスを出し分けると、描き直しのたびに全行へ付け替えることになる。
  // **「枠が実際に出ているか」と一致させる**(boxesStale の間は出ていない) —— 枠が無いのに
  // 行だけ赤いと何と対応しているのか分からない(style.css の .boxes-on の doc)
  elementsList.classList.toggle('boxes-on', showBoxes && !boxesStale);
  // 消した後は次の木を待つ(fitScreenshot からの引き直しで古い枠を蘇らせない)
  if (boxesStale) { return; }
  boxByRef.clear();
  hotBox.remove();
  if (!showBoxes || !lastScreen || lastElements.length === 0) {
    boxesOverlay.classList.remove('visible');
    boxesOverlay.replaceChildren();
    return;
  }
  const rect = activeScreenEl().getBoundingClientRect();
  if (rect.width === 0 || rect.height === 0) { return; } // タブ非表示中は測れない
  const display = { width: rect.width, height: rect.height };
  boxesOverlay.setAttribute('viewBox', `0 0 ${display.width} ${display.height}`);
  const svgNS = 'http://www.w3.org/2000/svg';
  const shapes = lastElements.map((element) => {
    const box = frameToDisplayRect(element.frame, lastScreen, display);
    const node = document.createElementNS(svgNS, 'rect');
    node.setAttribute('x', box.x);
    node.setAttribute('y', box.y);
    node.setAttribute('width', Math.max(box.width, 1));
    node.setAttribute('height', Math.max(box.height, 1));
    boxByRef.set(element.ref, node);
    return node;
  });
  boxesOverlay.replaceChildren(...shapes);
  boxesOverlay.classList.add('visible');
  applyHot();
}

showBoxesToggle.checked = showBoxes;
showBoxesToggle.addEventListener('change', () => {
  showBoxes = showBoxesToggle.checked;
  vscode.setState(Object.assign({}, vscode.getState(), { liveShowBoxes: showBoxes }));
  // ホバー中に切り替えると、行ホバーの出し先(単一枠 ⇄ hot)が入れ替わる。両方畳んでから引き直す
  setHot(null, false);
  hideHover();
  // **撮り直しの予約が残っている = 絵が動いた(動いている)**。その木はもう画面と合わないので
  // 静定を待つ(deferBoxesUntilSettled)。予約が無ければ既に静定しているので即描く。
  // **枠を消したまま(boxesStale)で予約も無い**ときも撮り直しへ —— 失敗した操作のあとはこの形になり、
  // ON にしても renderBoxes が stale で何も描かず、黙ったままだった
  if (showBoxes && (settleRefreshTimer !== null || boxesStale)) {
    deferBoxesUntilSettled();
  } else if (!showBoxes) {
    cancelBoxesSettleCap();
    boxesAwaitSettle = false;
  }
  renderBoxes();
});

function renderElements() {
  rowByRef.clear();
  elementsList.innerHTML = '';
  for (const element of lastElements) {
    const row = document.createElement('div');
    row.className = 'element-row';
    // 2カラム(矩形 | 本文)。列幅は .elements-list 側が決め、行は subgrid で乗る
    // = 矩形の幅が全行で揃い、本文の開始位置も揃う(liveModel.ts の frameText / line と対)
    const frameCell = document.createElement('span');
    frameCell.className = 'element-cell-frame';
    frameCell.textContent = element.frameText;
    const main = document.createElement('span');
    main.className = 'element-cell-main';
    main.textContent = element.line;
    row.append(frameCell, main);
    // **行のクリックでは何もしない**(ユーザー決定 2026-09-22) —— 一覧は読むためのもので、
    // 触れたつもりのないタップがデバイスへ飛ばないようにする。ホバーで枠を出すだけ。
    // 枠を出している間(showBoxes)は **hot(赤)へ一本化** —— 単一枠(青)と重ねると同じ要素に
    // 2つ枠が出る。画像側から指したときと見た目が揃うので、どちらから指しても同じに見える。
    row.addEventListener('mouseenter', () => {
      if (showBoxes) { setHot(element.ref, false); } else { showHover(element); }
    });
    row.addEventListener('mouseleave', () => {
      if (showBoxes) { setHot(null, false); } else { hideHover(); }
    });
    rowByRef.set(element.ref, row);
    elementsList.appendChild(row);
  }
  applyHot();
  renderBoxes();
}

// ---- 操作記録(host の operationLog を追記。対向: monitorLiveController.ts の postOperationLog) ----

const OPLOG_MAX_ROWS = 200; // DOM/メモリ肥大防止。超えたら最古行から捨てる
function pad2(n) { return n < 10 ? '0' + n : '' + n; }
// 行は「時刻 / 操作 / MCP のコマンド」の3列(grid は CSS の .oplog-row / .oplog-head)。MCP 列は同じ操作を
// ft_* で撃つ形(host の mcpCommandForServeCommand)で、**クリックでコピー**する(貼って使うもの)。
// テスト実行由来の行には無い(空のまま = 列は揃える)。
// **一覧は左右にもスクロールする**(MCP 列は省略しない = 行の幅は中身で決まり、.oplog-list が overflow:auto)。
// 操作列の幅は見出し行(.oplog-head)の境目をドラッグして変える(--oplog-label-width。vscode.setState に永続化)
const MIN_OPLOG_LABEL_WIDTH = 60; // px。操作列を潰し切らない下限
const DEFAULT_OPLOG_LABEL_WIDTH = 220; // px。CSS の --oplog-label-width の既定と揃えること
let oplogLabelWidth =
  typeof persistedState.liveOplogLabelWidth === 'number' && persistedState.liveOplogLabelWidth >= MIN_OPLOG_LABEL_WIDTH
    ? persistedState.liveOplogLabelWidth
    : DEFAULT_OPLOG_LABEL_WIDTH;
function applyOplogLabelWidth(width) {
  oplogLabelWidth = Math.max(MIN_OPLOG_LABEL_WIDTH, Math.round(width));
  oplogList.style.setProperty('--oplog-label-width', oplogLabelWidth + 'px');
}
// 見出し行は一覧の中に置く(外に置くと横スクロールで列がずれる)。クリア・行数の上限では消さない
const oplogHead = document.createElement('div');
oplogHead.className = 'oplog-head';
{
  const timeHead = document.createElement('span');
  timeHead.className = 'oplog-time';
  const labelHead = document.createElement('span');
  labelHead.className = 'oplog-label';
  labelHead.textContent = t('wvMonitor.live.oplogColOperation');
  const resizer = document.createElement('span');
  resizer.className = 'oplog-col-resizer';
  resizer.title = t('wvMonitor.live.oplogColResize');
  labelHead.appendChild(resizer);
  const mcpHead = document.createElement('span');
  mcpHead.className = 'oplog-mcp';
  mcpHead.textContent = t('wvMonitor.live.oplogColMcp');
  oplogHead.append(timeHead, labelHead, mcpHead);
  let resizePointerId = null;
  let resizeStartX = 0;
  let resizeStartWidth = 0;
  resizer.addEventListener('pointerdown', (event) => {
    if (event.button !== 0) { return; }
    resizePointerId = event.pointerId;
    resizeStartX = event.clientX;
    resizeStartWidth = oplogLabelWidth;
    resizer.setPointerCapture(event.pointerId);
    resizer.classList.add('dragging');
    event.preventDefault();
  });
  resizer.addEventListener('pointermove', (event) => {
    if (resizePointerId !== event.pointerId) { return; }
    applyOplogLabelWidth(resizeStartWidth + (event.clientX - resizeStartX));
  });
  const endResize = (event) => {
    if (resizePointerId !== event.pointerId) { return; }
    resizePointerId = null;
    resizer.classList.remove('dragging');
    resizer.releasePointerCapture(event.pointerId);
    vscode.setState(Object.assign({}, vscode.getState(), { liveOplogLabelWidth: oplogLabelWidth }));
  };
  resizer.addEventListener('pointerup', endResize);
  resizer.addEventListener('pointercancel', endResize);
}
oplogList.appendChild(oplogHead);
applyOplogLabelWidth(oplogLabelWidth);

function appendOperationLog(label, ok, mcp) {
  const row = document.createElement('div');
  row.className = ok ? 'oplog-row' : 'oplog-row failed';
  const now = new Date();
  const time = document.createElement('span');
  time.className = 'oplog-time';
  time.textContent = pad2(now.getHours()) + ':' + pad2(now.getMinutes()) + ':' + pad2(now.getSeconds());
  const text = document.createElement('span');
  text.className = 'oplog-label';
  text.textContent = (ok ? '' : '✗ ') + label;
  const command = document.createElement('span');
  command.className = 'oplog-mcp';
  if (mcp) {
    command.textContent = mcp;
    command.title = mcp + '\n' + t('wvMonitor.live.oplogMcpCopy');
    command.addEventListener('click', () => { vscode.postMessage({ type: 'copyText', text: mcp }); });
  }
  row.appendChild(time);
  row.appendChild(text);
  row.appendChild(command);
  oplogList.appendChild(row);
  // 見出し行(.oplog-head)は数えない・消さない
  const rows = oplogList.querySelectorAll('.oplog-row');
  for (let i = 0; i < rows.length - OPLOG_MAX_ROWS; i++) {
    rows[i].remove();
  }
  oplogList.scrollTop = oplogList.scrollHeight; // 最新行を見せる
}
oplogClearBtn.addEventListener('click', () => {
  for (const row of oplogList.querySelectorAll('.oplog-row')) { row.remove(); }
});

// ---- 操作ボタン ------------------------------------------------------------------

document.getElementById('live-btn-refresh-devices').addEventListener('click', () => {
  post({ type: 'refreshDevices' });
});
document.getElementById('live-btn-refresh-snapshot').addEventListener('click', () => {
  showActionError('');
  post({ type: 'refreshSnapshot' });
});
document.getElementById('live-btn-zoom-in').addEventListener('click', () => {
  showActionError('');
  post({ type: 'pinch', zoomIn: true });
});
document.getElementById('live-btn-zoom-out').addEventListener('click', () => {
  showActionError('');
  post({ type: 'pinch', zoomIn: false });
});
document.getElementById('live-btn-home').addEventListener('click', () => {
  showActionError('');
  post({ type: 'home' });
});
document.getElementById('live-btn-app-switcher').addEventListener('click', () => {
  showActionError('');
  post({ type: 'appSwitcher' });
});
function submitTypeText() {
  showActionError('');
  post({ type: 'typeText', text: typeTextInput.value });
  // 送信したら入力欄をクリアする(post は value を同期読みするので後でクリアしてよい)。
  typeTextInput.value = '';
}
// テキスト送信は Enter のみ(「入力」ボタンは置かない)。IME変換中(日本語変換の確定)の Enter は
// 送信しない: isComposing が true、環境により keyDown が keyCode 229(IME処理中)で届くため両方を除外する。
// busy 中も送らない(処理中の多重送信を防ぐ)。
typeTextInput.addEventListener('keydown', (event) => {
  if (event.key !== 'Enter' || event.isComposing || event.keyCode === 229) { return; }
  if (busy) { return; }
  event.preventDefault();
  submitTypeText();
});

// frame/liveH264Chunk は screen(タップ/ドラッグ座標変換の基準)を持たない。snapshot 未取得のまま
// 流れているとポインタ操作が無反応になるため、一度だけ全量更新を要求する(パネル開き直しでライブ
// タブが復元された直後に起きる)。フラグは applySnapshot で戻す。
function requestSnapshotIfNeeded() {
  if (!lastScreen && !autoSnapshotRequested && !busy) {
    autoSnapshotRequested = true;
    post({ type: 'refreshSnapshot' });
  }
}

// liveH264Chunk は main.js の直下ディスパッチャから呼ばれる('live' 封筒を経由しない。対向の
// h264Chunk[タイル]と同じ形の top-level メッセージ)。レンダラは1つだけ保持し、初回描画
// (onFirstFrame)で screenshot(img)→liveCanvas に切り替える。
export function applyLiveH264Chunk(message) {
  if (liveH264ErrorSent) {
    return;
  }
  // 絵が動いた = まだ遷移の途中かもしれない。止まってから撮り直すよう予約を先送りする
  scheduleSettleRefresh();
  // 初期キーフレームを取り逃すとデルタしか届かず永久に描画できない(タイルで実害化したのと同型)。
  // 一定数デルタが続いたらホストにヘルパー再起動を頼み、新キーフレームから始め直す(deviceTiles.js と同型)。
  if (message.keyframe) {
    liveDeltasBeforeKey = 0;
    liveStallSent = false;
  } else if (!liveUsingH264) {
    liveDeltasBeforeKey += 1;
    if (liveDeltasBeforeKey >= 30 && !liveStallSent) {
      liveStallSent = true;
      vscode.postMessage({ type: 'streamStall', scope: 'live' });
    }
  }
  if (!liveRenderer) {
    liveRenderer = createH264Renderer({
      canvas: liveCanvas,
      onFirstFrame: () => {
        liveUsingH264 = true;
        showCanvas();
        fitScreenshot();
        requestSnapshotIfNeeded();
      },
      // **描けた時点で canvas を前に戻す** —— snapshot の一枚絵を前面にしている間も
      // デコーダは生きているので、次のフレームはキーフレームを待たずに描ける。
      onFrameRendered: () => showCanvas(),
      onError: () => {
        liveH264ErrorSent = true;
        vscode.postMessage({ type: 'codecError', scope: 'live' });
        disposeLiveH264();
      },
    });
  }
  liveRenderer.pushChunk(message.data, message.keyframe, message.width, message.height);
}

// ---- host からのメッセージ(type:'live' 封筒の中身。main.js のディスパッチャから呼ばれる) --------

export function applyLiveMessage(message) {
  switch (message.type) {
    case 'devices':
      applyDevices(message.devices, message.selectedId);
      break;
    case 'banner':
      showBanner(message.message);
      break;
    case 'snapshot':
      applySnapshot(message);
      break;
    case 'clearSnapshot':
      // host がデバイスを切り替えた。前の台のデコーダも捨てる —— 残すと、デコード待ちだった
      // 前の台のフレームが描けた時点で onFrameRendered が canvas を前面へ戻し、新しい台の絵が
      // 来るまで(来なければずっと)前の台の画面が出たままになる
      clearSnapshot();
      disposeLiveH264();
      liveH264ErrorSent = false;
      break;
    case 'frame':
      disposeLiveH264(); // mjpeg フォールバック復帰(codecError 後、host が frame 送信に切替えた場合)
      screenshot.src = 'data:image/jpeg;base64,' + message.image;
      showStill();
      requestSnapshotIfNeeded();
      break;
    case 'actionError':
      showActionError(message.message, !!message.neutral);
      break;
    case 'busy':
      setBusy(!!message.busy);
      break;
    case 'connection':
      if (message.connected === false) {
        connOverlay.classList.add('visible');
        connDetail.textContent = message.message ?? '';
        screenshot.classList.add('disconnected');
        liveCanvas.classList.add('disconnected');
      } else {
        connOverlay.classList.remove('visible');
        connDetail.textContent = '';
        screenshot.classList.remove('disconnected');
        liveCanvas.classList.remove('disconnected');
      }
      break;
    // ブリッジの自動起動が進行中(bridgeStarting)。文言は monitorHtml.ts で host 側 t() 済みの固定文
    // なので、ここは .visible の付け外しだけ行う(conn-overlay の "接続エラー" とは別状態)
    case 'bridgeStarting':
      connectingOverlay.classList.toggle('visible', !!message.starting);
      // オーバーレイは半透明なので、下の「接続されていません」が透けて矛盾した2文になる。場所は保って文字だけ隠す
      screenshotPlaceholder.classList.toggle('connecting', !!message.starting);
      break;
    case 'appProfiles':
      applyAppProfiles(message.profiles, message.selectedId);
      break;
    case 'appProfileDetail':
      applyAppProfileDetail(message);
      break;
    case 'recording':
      applyRecording(!!message.active, !!message.generating);
      break;
    case 'recordStatus':
      recordStatus.textContent = message.message;
      break;
    case 'busyOverlay':
      if (message.message) {
        busyMessage.textContent = message.message;
        busyOverlay.classList.add('visible');
      } else {
        busyOverlay.classList.remove('visible');
        busyMessage.textContent = '';
      }
      break;
    case 'focusTypeInput':
      // 画像上のテキスト入力欄をタップした直後(host が判定して送る)。既存テキストは選択し、
      // そのまま打鍵で置き換えられるようにする。
      typeTextInput.focus();
      typeTextInput.select();
      break;
    case 'operationLog':
      appendOperationLog(message.label, !!message.ok, typeof message.mcp === 'string' ? message.mcp : '');
      break;
    default:
      break;
  }
}

// ---- パネル本体(src/webview/monitor/main.js)から呼ばれるエントリポイント -----------------------

let initialized = false;

/** パネル初期化(初回のみ)。デバイス一覧・アプリプロファイル一覧を取得し、要素一覧セクションの
 * 高さを復元する。 */
export function initLive() {
  if (initialized) { return; }
  initialized = true;
  post({ type: 'refreshDevices' });
  post({ type: 'refreshAppProfiles' });
  applyElementsHeight(elementsSectionHeight);
}

/** パネルの表示状態を host へ通知する(自動フレーム更新のオンオフ。監視元: monitorLiveController.ts)。 */
export function setLiveVisible(visible) {
  post({ type: 'visibility', visible });
  if (visible) { applyElementsHeight(elementsSectionHeight); }
}

/** デバイスタイル右クリック「ライブ操作」(受信元: deviceTiles.js → liveTabHost.ts → ここ)。 */
export function openLiveDevice(id) {
  // 別の台へ移るなら前の台の絵・木をその場で捨てる(セレクトの change と同じ)。捨てずに
  // disposeLiveH264 を呼ぶと、残った src(前の台の静止画)を前面へ戻してしまう
  if (deviceSelect.value !== id) {
    clearSnapshot();
  }
  disposeLiveH264();
  liveH264ErrorSent = false;
  post({ type: 'openDevice', id });
}

/** fleetest.showLiveControl の再表示(パネルが既に開いている場合の再バインド要求)。 */
export function refreshLiveDevices() {
  post({ type: 'refreshDevices' });
}

// ---- 要素一覧 / 操作記録 の上下スプリッター(splitter.js の「デバイスモニター」タブ版と同パターン。
// こちらはライブタブ専用で elements セクションの高さ[px]を持つ。位置は vscode.setState に永続化)。----

const MIN_LIVE_SECTION = 80; // px。elements/oplog 各セクションの最小高(CSS の min-height と揃える)
const livePanel = document.getElementById('panel-live');
let elementsSectionHeight =
  typeof persistedState.liveElementsHeight === 'number' && persistedState.liveElementsHeight > 0
    ? persistedState.liveElementsHeight
    : Math.round(window.innerHeight * 0.4);

function liveListsAvailable() {
  const lists = listsSplitter.parentElement; // .live-lists
  return lists.clientHeight - listsSplitter.offsetHeight;
}
function clampElementsHeight(height) {
  const available = liveListsAvailable();
  const maxHeight = Math.max(MIN_LIVE_SECTION, available - MIN_LIVE_SECTION);
  return Math.min(Math.max(height, MIN_LIVE_SECTION), maxHeight);
}
function applyElementsHeight(height) {
  // ライブタブ非表示中は clientHeight=0 で誤って最小へクランプするため触らない(活性化時に呼び直す)。
  if (livePanel.offsetParent === null || livePanel.clientHeight === 0) { return; }
  elementsSectionHeight = clampElementsHeight(height);
  elementsSection.style.height = elementsSectionHeight + 'px';
}
function persistElementsHeight() {
  vscode.setState(Object.assign({}, vscode.getState(), { liveElementsHeight: elementsSectionHeight }));
}

let listsPointerId = null;
let listsStartY = 0;
let listsStartHeight = 0;
listsSplitter.addEventListener('pointerdown', (event) => {
  if (event.button !== 0) { return; }
  listsPointerId = event.pointerId;
  listsStartY = event.clientY;
  listsStartHeight = elementsSectionHeight;
  listsSplitter.setPointerCapture(event.pointerId);
  listsSplitter.classList.add('dragging');
  event.preventDefault();
});
listsSplitter.addEventListener('pointermove', (event) => {
  if (listsPointerId !== event.pointerId) { return; }
  applyElementsHeight(listsStartHeight + (event.clientY - listsStartY));
});
const endListsDrag = (event) => {
  if (listsPointerId !== event.pointerId) { return; }
  listsPointerId = null;
  listsSplitter.classList.remove('dragging');
  listsSplitter.releasePointerCapture(event.pointerId);
  persistElementsHeight();
};
listsSplitter.addEventListener('pointerup', endListsDrag);
listsSplitter.addEventListener('pointercancel', endListsDrag);
window.addEventListener('resize', () => applyElementsHeight(elementsSectionHeight));

// ---- デバイス画像の右スプリッター(左右ドラッグで screenshot-pane 幅を調整。fitScreenshot が反映)。----
// 幅は px で持ち vscode.setState(liveScreenWidth)に永続化。MIN は CSS の .screenshot-pane min-width と、
// 右端の下限は .control-pane min-width(280)と揃える(超えると overflow:hidden で片方が切れるため)。
const MIN_SCREEN_WIDTH = 200; // px。CSS の #panel-live .screenshot-pane min-width と揃えること
const CONTROL_MIN_WIDTH = 280; // px。CSS の #panel-live .control-pane min-width と揃えること
function clampScreenWidth(width) {
  const content = screenSplitter.parentElement; // .content
  // .content は padding:12・gap:12(pane|splitter|control の2箇所)。使える横幅から control 下限と
  // splitter 幅・余白を引いた残りが pane の上限。
  const maxWidth = Math.max(
    MIN_SCREEN_WIDTH,
    content.clientWidth - 24 /* padding */ - 24 /* 2 gaps */ - screenSplitter.offsetWidth - CONTROL_MIN_WIDTH,
  );
  return Math.min(Math.max(width, MIN_SCREEN_WIDTH), maxWidth);
}
function applyScreenWidth(width) {
  // タブ非表示中は content.clientWidth=0 で誤クランプするため触らない(活性化時の fitScreenshot が反映)。
  if (livePanel.offsetParent === null || livePanel.clientHeight === 0) { return; }
  screenPaneWidth = clampScreenWidth(width);
  fitScreenshot();
}
function persistScreenWidth() {
  vscode.setState(Object.assign({}, vscode.getState(), { liveScreenWidth: screenPaneWidth }));
}

let screenPointerId = null;
let screenStartX = 0;
let screenStartWidth = 0;
screenSplitter.addEventListener('pointerdown', (event) => {
  if (event.button !== 0) { return; }
  screenPointerId = event.pointerId;
  screenStartX = event.clientX;
  // 未設定(自動フィット)時は現在の実測幅を基準にする → ドラッグが連続して感じられる。
  screenStartWidth = screenPaneWidth != null ? screenPaneWidth : screenshotPane.getBoundingClientRect().width;
  screenSplitter.setPointerCapture(event.pointerId);
  screenSplitter.classList.add('dragging');
  event.preventDefault();
});
screenSplitter.addEventListener('pointermove', (event) => {
  if (screenPointerId !== event.pointerId) { return; }
  applyScreenWidth(screenStartWidth + (event.clientX - screenStartX));
});
const endScreenDrag = (event) => {
  if (screenPointerId !== event.pointerId) { return; }
  screenPointerId = null;
  screenSplitter.classList.remove('dragging');
  screenSplitter.releasePointerCapture(event.pointerId);
  persistScreenWidth();
};
screenSplitter.addEventListener('pointerup', endScreenDrag);
screenSplitter.addEventListener('pointercancel', endScreenDrag);
// ウィンドウ幅が変わったら手動幅を再クランプ(狭くなって上限を割ったら縮める)。
window.addEventListener('resize', () => { if (screenPaneWidth != null) { applyScreenWidth(screenPaneWidth); } });
