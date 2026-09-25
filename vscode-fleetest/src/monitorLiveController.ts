// monitorLiveController.ts
// デバイスモニターの「ライブ操作」タブ(liveTabHost.ts)のロジック本体。
//
// - `fleetest api list-devices` は FleetestCli の直列キュー(`fleetest api run` と共有。シナリオ実行が
//   `swift build` を伴い得るため同時2プロセスを防ぐ SPM ビルドロック対策)には乗せず、oneShotCli.ts の
//   runOneShot() で専用 spawn する。ライブ操作は実行中でも待たされず応答する必要があり、
//   list-devices はビルドを伴わないので run 側と競合しないため問題ない。
// - タップ/入力/スワイプ/終了/スナップショット取得は、選択デバイスごとに
//   `fleetest api live serve` を常駐 spawn し、stdin へ NDJSON でコマンドを送って stdout の NDJSON
//   イベント(NdjsonParser)を待つ方式で行う。プロセス管理は monitorProcessManager.ts の host-metrics
//   パターンを踏襲: stdin パイプ保持(EOF が終了指示)・SIGTERM 送信後2秒で SIGKILL・予期しない
//   終了は5秒後に自動再起動・起動10秒未満の異常終了が3連続したら諦める(serveGaveUp)。ただし
//   serve はデバイスごとの状態を持つプロセスなので、デバイス選択が変わったら明示的に再バインド
//   (停止→新デバイスで起動)し諦め状態もリセットする(=デバイスを選び直す操作が host-metrics の
//   「再起動ボタン」に相当する回復経路。専用ボタンは無い)。
// - webview 資産は src/webview/monitor/liveTab.js(src/webview/monitor/main.js から applyLiveMessage を
//   import)。frameToDisplayRect の計算だけを手書きで複製している(要素一覧の表示テキストは host 側で
//   事前整形して送るため複製不要)。liveModel.ts の frameToDisplayRect を変更したら
//   liveTab.js 側も追随させること。

import { type ChildProcessByStdio, spawn } from "node:child_process";
import type { Readable, Writable } from "node:stream";
import * as vscode from "vscode";
import { childEnv } from "./childEnv";
import type { FleetestCli } from "./cli";
import {
  type FleetestConfig,
  resolveAdb,
  resolveAndroidStream,
  resolveProjectName,
  resolveSimStream,
} from "./config";
import { StreamPipeline, type LiveStreamPipeline } from "./deviceStream";
import { t } from "./i18n";
import { LiveAppActions } from "./liveAppActions";
import {
  buildDeviceArgs,
  describeElementShort,
  devicesToOptions,
  FALLBACK_DEVICE_ID,
  fallbackDeviceOption,
  mcpCommandForServeCommand,
  hitTestElement,
  isTextInputElement,
  type LiveActionResult,
  type LiveDeviceOption,
  type LiveDeviceRef,
  type LiveElement,
  type LiveErrorResult,
  type LiveFrameResult,
  type LiveFromWebviewMessage,
  type LiveServeCommand,
  type LiveSize,
  type LiveSnapshot,
  type LiveToWebviewMessage,
  locatorChainForElement,
  parseListDevicesResult,
  GESTURE_SECONDS_CEILING,
  gestureCapFor,
  parseLiveServeEvent,
  pointFromClick,
  type RecordedStep,
  recordedGestureFingers,
  sameLiveDeviceRef,
  serializeLiveServeCommand,
  serveCommandPlaybackMs,
  stepDescriptionToOperationLabel,
  swipeDirectionLabel,
  toSnapshotMessage,
  truncateOperationLabelText,
} from "./liveModel";
import type { LiveDeps } from "./liveDeps";
import type { LiveRunTarget } from "./liveRunTarget";
import type { StepEvent } from "./model";
import { NdjsonParser } from "./ndjson";
import { type OneShotResult, type PipeProcess, runOneShot } from "./oneShotCli";

/**
 * serve プロセス用: stdin もパイプで保持する(monitorProcessManager.ts の MonitorProcess/host-metrics
 * プロセスと同じ形。`fleetest api live serve` は stdin へのコマンド送信と EOF 終了指示の両方に
 * stdin パイプを使うため、stdio を "ignore" にはできない)。
 */
type ServeProcess = ChildProcessByStdio<Writable, Readable, Readable>;

/** serve への1リクエスト(コマンド送信〜応答受信)のタイムアウト(ms)。通常は1秒未満で応答が
 * 返るが、アプリ起動(ブリッジ側の静止待ち上限10秒)等を考慮して余裕を持たせた安全弁。
 * 応答が無いまま常駐プロセスが停止したり壊れたりしても busy 状態のまま固まらないようにする。 */
const SERVE_REQUEST_TIMEOUT_MS = 20000;

/** 応答タイムアウトによる wedge 復旧(serve の kill→自動 respawn)を連続で試みる上限。これを
 * 超えたら自動再起動を止め、serveUnavailableMessage() を出す(デバイス選び直し=rebind で解除)。 */
const MAX_CONSECUTIVE_TIMEOUT_KILLS = 3;

/** デバイス切り替えの再バインド(rebindServeProcess の stop→start)が終わるのを待つ上限(ms)。
 * 旧 serve は SIGTERM を無視するので、停止は stdin EOF か killServeProcess の2秒後 SIGKILL まで
 * 掛かり、その間 serveProcess は未設定になる。この窓のコマンドを待たずに断ると、利用者が
 * **たった今選び直したデバイス**に対して「起動していません。デバイスを選び直してください」を出す
 * ことになる(案内どおり選び直しても同じ再バインドなので同じ文言が出る)。2秒の停止 + close→spawn
 * の余裕。超えたら従来どおり断る(本当に立ち上がらない場合の固まりを作らない)。 */
const SERVE_REBIND_WAIT_MS = 6000;

/** 「全て終了」の前に serve を畳むときの close 待ちの上限(ms)。killServeProcess は stdin EOF +
 * SIGTERM を送り 2 秒後に SIGKILL へ上げるので、その 2 秒 + 余裕。上限に当たっても掃討へ進む
 * (印が残っていても持ち主の pid は死んでいる = CLI は生きた印としては数えない)。 */
const SERVE_SWEEP_STOP_WAIT_MS = 2500;

/** 自動フレームを実行できなかった回(busy・パネル非表示・serve 不在)と失敗時の再試行間隔(ms)。
 * 成功時は待ちなしで次フレームを送る(ホットループ防止のため失敗系のみ間隔を空ける)。 */
const FRAME_IDLE_RETRY_MS = 500;
/** 「接続中」表示の間に観測を撃ち直す間隔[ms]。serve は自動起動の完了を自分から知らせない
 * (観測・操作の応答に載せるだけ)ので、配信中(frameTick が止まる)は誰かが聞き直さないと
 * 表示が残り続ける。2 秒 = 再利用の起動(十数秒)を待たせすぎず、serve を詰まらせない間隔 */
const BRIDGE_STARTING_PROBE_MS = 2000;

/** ライブ映像ストリーミング helper(iOS/Android共通)へ渡すフレーム長辺px。ネイティブのシミュレータ
 * フレームは ~1206x2622・JPEG ~300KB と重いため既定 900px 幅へ縮めて転送量を抑える(config に専用
 * ノブは無い)。アスペクト比は helper 側で保たれるため、serve snapshot 基準のタップ座標変換は崩れない。 */
const LIVE_STREAM_MAX_WIDTH = 900;

/** serve 常駐プロセスの不在・応答不能・終了を表す文言。これらは個々の操作失敗(タップ失敗・
 * 未入力など)とは違い「接続状態」の問題で、serve が復帰すれば自動で解消する。postActionError が
 * isConnectionClassMessage との一致で connectionBannerShown を立て、復帰時(handleConnectionOk)に
 * バナーを自動で消す。文言(キー)を増やしたら isConnectionClassMessage も追随させること。
 * locale 切替後も表示側と比較側が食い違わないよう、値はキャッシュせず都度 t() で引く。 */
function serveUnavailableMessage(): string {
  return t("live.serveUnavailableMessage");
}
function serveTimeoutMessage(): string {
  return t("live.serveTimeoutMessage");
}
function serveClosedMessage(): string {
  return t("live.serveClosedMessage");
}
function isConnectionClassMessage(message: string): boolean {
  return message === serveUnavailableMessage() || message === serveTimeoutMessage() || message === serveClosedMessage();
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** sendServeCommand() が返す1リクエスト分の結果。action は refresh(アクション無し)のときのみ
 * undefined になる(snapshot は refresh でも常に届く)。 */
interface ServeRequestOutcome {
  readonly action: LiveActionResult | undefined;
  readonly snapshot: LiveSnapshot | LiveErrorResult;
}

/** sendServeCommand/sendServeFrame の resolve に渡す払い出し。resolvesOn で使うフィールドが決まる
 * (snapshot: action?+snapshot、frame: frame のみ)。 */
interface PendingServeOutcome {
  readonly action?: LiveActionResult;
  readonly snapshot?: LiveSnapshot | LiveErrorResult;
  readonly frame?: LiveFrameResult;
}

/** 送信中(応答待ち)の serve リクエスト1件分。自動フレームとユーザー操作が enqueueServeSend で
 * 直列化されるため同時に2件以上送らない(単一スロットで管理。activeChild と同じ「一度に1つだけ」の設計)。 */
interface PendingServeRequest {
  /** refresh/frame は actionResult を出さないため false。 */
  readonly expectsAction: boolean;
  /** どちらの観測イベントで resolve するか。handleServeEvent が届いた kind と照合し、不一致なら
   * 「対応しないイベント」として無視する(自動フレームとユーザー操作の取り違え防止)。 */
  readonly resolvesOn: "snapshot" | "frame";
  /** actionResult イベントが先に届いたら保持し、snapshot イベント到着時にまとめて resolve する。 */
  action: LiveActionResult | undefined;
  readonly resolve: (outcome: PendingServeOutcome) => void;
  readonly timeout: ReturnType<typeof setTimeout>;
}

export class MonitorLiveController implements vscode.Disposable {
  private devices: LiveDeviceOption[] = [];
  /** タイル右クリックで開いた**他の機械の台**(registerRemoteDevice)。list-devices はこの Mac の台しか
   * 返さないので、一覧を取り直すたびに applyDevices がここから足し戻す(足さないと選択が消えて
   * 先頭の台へ戻る)。 */
  private readonly remoteOptions = new Map<string, LiveDeviceOption>();
  private selectedDeviceId: string | undefined;
  /** openDevice 用: 次の applyDevices で優先選択する id(消費したら undefined に戻す)。
   * **busy が解けた時点でも消化する**(setBusy)—— busy の原因が refreshDevices でない(画面取得・
   * 操作の最中)と applyDevices が来ず、右クリックの「ライブ操作」が黙って捨てられていた。 */
  private pendingSelectId: string | undefined;
  /** booted の台へ切り替えたときの観測1回(requestOpenObservation)。busy の間は撃てない
   * (refreshSnapshot は busy なら何もしない)ので、ここに控えて setBusy(false) で撃つ。 */
  private openObservationPending = false;
  /** preferPlatform 用: Run Test 自動オープン(liveTabHost.ts)が「実行中シナリオの platform」を渡す。
   * 選択中デバイスの platform がこれと食い違う間、applyDevices/preferPlatform は一覧の先頭から
   * この platform のデバイスを探して自動選択する。ユーザーが手動で選び直したら(selectDevice/
   * openDevice)解除する(明示選択を尊重する)。 */
  private preferredPlatform: string | undefined;
  /** 直近の snapshot の screen(ポイント座標のサイズ)。クリック→タップ座標変換に使う。 */
  private lastScreen: LiveSize | undefined;
  /** 直近の snapshot の要素一覧。レコーディング中のヒットテスト・ref 解決に使う。 */
  private lastElements: readonly LiveElement[] = [];
  private busy = false;
  /** 自動フレームの連続失敗回数(スキップ回はカウントしない)。3で connectionLost に切り替える
   * (単発の取りこぼしで誤検知しないためのデバウンス)。 */
  private frameFailureStreak = 0;
  /** webview へ connection:false を post 済みかどうか(復帰時の connection:true post 要否判定)。 */
  private connectionLost = false;
  /** 直近 post した connection:false の message。文言が変わったとき(例えば自動起動が諦めて
   * failed になったとき)だけ再 post するための比較用。 */
  private lastConnectionMessage: string | undefined;
  /** 直近 post した actionError バナーが接続系(isConnectionClassMessage)かどうか。true の間は
   * serve 復帰(handleConnectionOk)で自動的に消す。個々の操作失敗バナーは false のままなので、
   * 常時回っている自動フレームで誤って消えることはない。 */
  private connectionBannerShown = false;
  /** 直近 webview へ post した bridgeStarting の値(applyBridgeStarting の冪等化・差分検知用)。 */
  private bridgeStartingShown = false;
  /** prepareForRun() の waitForStreamSync() 待ち手。handleConnectionOk() 到達のたびに全件 resolve
   * して空にする(次の接続成功を「同期完了」とみなす契約。tap 待ち等 handleConnectionOk を呼ぶ
   * 全経路が対象なので、対象デバイス切り替え後の最初のフレーム/snapshot 成功で必ず起きる)。 */
  private streamSyncWaiters: Array<() => void> = [];
  /** list-devices のワンショット spawn(専用。runOneShot 経由)。 */
  private activeChild: PipeProcess | undefined;

  // ---- live serve(常駐プロセス。デバイス選択ごとに1つ)。ファイル冒頭のコメント参照 ----
  private serveProcess: ServeProcess | undefined;
  /** serveProcess が実際にバインドされている(起動時に渡した)デバイス。selectServeProcess の
   * 「デバイスが変わったか」判定、および再起動時に同じデバイスへ再バインドするために保持する。 */
  private serveDevice: LiveDeviceRef | undefined;
  /** stopServeProcess() 経由(dispose/再バインド)による意図した終了かどうか
   * (monitorProcessManager.ts の stoppingHostMetrics と同じ役割)。 */
  private stoppingServe = false;
  /** rebindServeProcess() の多重起動ガード(monitorProcessManager.ts の hostMetricsRestartPending と
   * 同じ役割)。true の間に来た再バインド要求は serveDevice の更新だけ行い、進行中の切り替えが
   * 完了した時点の最新の serveDevice を使って起動する(restartMonitorProcess と同じ
   * 「最終的に最新設定が勝つ」方式)。 */
  private serveRestartPending = false;
  /** 再バインドの完了(新しい serveProcess が立つ/起動しないと確定する)を待っている呼び出し手。
   * rebindServeProcess の startLatest が全件起こす(awaitServeRebind の doc 参照)。 */
  private serveReadyWaiters: Array<() => void> = [];
  /** 予期しない終了後の自動再起動タイマー(5秒後)。dispose/停止時に必ずクリアする。 */
  private serveRestartTimer: ReturnType<typeof setTimeout> | undefined;
  /** 直近の起動時刻(ms)。close イベントでの経過時間から「起動後10秒未満での異常終了」を判定する。 */
  private serveStartedAt: number | undefined;
  /** 「起動後10秒未満での異常終了」が連続した回数。3回連続したら諦めて自動再起動を止める。 */
  private serveFailureStreak = 0;
  /** 応答タイムアウトで serve を kill→respawn した連続回数。成功応答(handleConnectionOk)と
   * 明示的な再バインドでリセットする。MAX_CONSECUTIVE_TIMEOUT_KILLS で諦める。 */
  private serveTimeoutKillStreak = 0;
  /** 自動再起動を諦めた状態。true の間は close イベントで再起動をスケジュールしない
   * (rebindServeProcess でリセットされる。詳細はファイル冒頭のコメント参照)。 */
  private serveGaveUp = false;
  /** 「全て終了」(suspendServeForSweep)で畳んでから resumeServeAfterSweep までの間 true。
   * この間は startServeProcess が起動しない(掃討の途中で serve が立ち直り、台の印を書き戻して
   * 掃討に断られる・掃討中のブリッジと取り合う、を作らない)。 */
  private serveSuspendedForSweep = false;
  /** 送信中(応答待ち)の serve リクエスト。同時に1件のみ(enqueueServeSend で直列化されるため)。 */
  private pendingServeRequest: PendingServeRequest | undefined;
  /** serve への送信を直列化するチェーン(自動フレームとユーザー操作の pending 競合を防ぐ)。 */
  private serveSendChain: Promise<unknown> = Promise.resolve();
  /** ライブタブ表示中かどうか(webview からの visibility メッセージで更新)。自動フレームの実行可否
   * (パネル非表示時はスキップ)に使う。 */
  private liveTabVisible = false;
  /** 自動フレームの次回 tick タイマー。 */
  private frameTimer: ReturnType<typeof setTimeout> | undefined;
  private bridgeStartingProbeTimer: ReturnType<typeof setTimeout> | undefined;

  // ---- 画面ストリーミング(iOS: fleetest-simstream / Android: fleetest-androidstream。
  // ポーリング frameTick の低負荷な代替) ----
  /** 稼働中のストリーミング helper(iOS/Android共通の StreamPipeline で1本化)。 */
  private streamPipeline: LiveStreamPipeline | undefined;
  /** streamPipeline がバインドされているデバイスキー(iOS: シミュレータ UDID、Android: adb serial)。
   * デバイス切り替え時の張り替え要否判定に使う。 */
  private streamKey: string | undefined;
  /** webview から codecError(scope=live)を受けたら true(fallbackToMjpeg 参照)。以後このパネルは
   * 設定値に関わらず mjpeg 固定。deviceStream.ts の mjpegFallbackIds と違いデバイス単位ではなく
   * パネル単位(ライブ操作パネルは常に1デバイスのみ選択するため)。 */
  private liveMjpegFallback = false;

  // ---- アプリ操作・レコーディング(liveAppActions.ts の LiveAppActions へ委譲) -----------------
  private readonly appActions: LiveAppActions;

  constructor(
    private readonly deps: LiveDeps,
    private readonly cli: FleetestCli,
    refreshTestTree: () => void,
  ) {
    this.appActions = new LiveAppActions(
      {
        workspaceRoot: this.deps.workspaceRoot,
        getConfig: () => this.deps.getConfig(),
        outputChannel: this.deps.outputChannel,
        post: (message) => this.post(message),
        currentDeviceRef: () => this.currentDeviceRef(),
        postActionError: (message) => this.postActionError(message),
        runAction: (command, recordStep, options) => this.runAction(command, recordStep, options),
        openGeneratedDocument: (filePath) => this.deps.openGeneratedDocument(filePath),
      },
      cli,
      refreshTestTree,
    );
  }

  /** パネル close 時・dispose 時の両方から呼ばれる。パネル再オープン後は webview からの
   * refreshDevices→applyDevices→ensureServeProcessForSelection で serve が再起動される。 */
  stopProcesses(): void {
    this.killActiveChild();
    this.stopServeProcess();
    this.stopStreamPipeline();
    this.clearFrameTimer();
    // パネル close/dispose 経由でのみ呼ばれる(終端)。可視フラグを落とさないと、パネル不在後に
    // preferPlatform 等が liveTabVisible=true を見て serve/stream を無表示で respawn し得る。
    // 再オープン時は panelVisible メッセージが冪等に再設定するため安全。
    this.liveTabVisible = false;
  }

  dispose(): void {
    this.clearBridgeStartingProbe();
    if (this.appActions.isGenerating()) {
      // `api gen-scenario` は `api run` と違って dispatch.lock 解放や終了スクリプトを持たない
      // 一回限りのコード生成なので、後始末を持たないヘルパー扱いで時限 SIGKILL してよい
      // (cli.ts の cancelCurrent の既定はここでは使わない。既定にすると dispose が確定しない)。
      this.cli.cancelCurrent({ escalateAfterMs: 2000 });
    }
    this.stopProcesses();
  }

  private post(message: LiveToWebviewMessage): void {
    this.deps.post({ type: "live", message });
  }

  private setBusy(busy: boolean): void {
    this.busy = busy;
    this.post({ type: "busy", busy });
    if (busy) {
      return;
    }
    const pendingId = this.pendingSelectId;
    if (pendingId !== undefined) {
      this.pendingSelectId = undefined;
      void this.openDevice(pendingId);
      return;
    }
    if (this.openObservationPending) {
      this.openObservationPending = false;
      void this.refreshSnapshot();
    }
  }

  /** **booted(台は起動済み・ブリッジ未接続)の台へ切り替えたら観測を1回撃つ**。serve の自動起動
   * (LiveBridgeAutoStarter)の引き金は観測・操作の接続拒否だけで、自動のフレーム取得(frame)は
   * 受動的な観測として起動を撃たない(ApiLiveCommand.emitFrame)。撃たないと、ブリッジの無い台
   * (実機では普通)を開いても「接続できません」のまま何も始まらない(実地 2026-09-24: iPhone wave)。
   * 切り替えの全経路(openDevice / selectDevice / applyDevices / preferPlatform)が通る
   * ensureServeProcess から呼ぶ。offline は撃たない(台そのものが起きていない = start-device の役目) */
  private requestOpenObservation(): void {
    if (this.selectedOption()?.state !== "booted") {
      return;
    }
    if (this.busy) {
      this.openObservationPending = true;
      return;
    }
    void this.refreshSnapshot();
  }

  /** 「操作記録」1行を webview へ送る(対向: liveTab.js の operationLog ハンドラ)。
   * 全ユーザー操作(tap/swipe/type/press/home/appSwitcher)の成否をここへ流す。 */
  private postOperationLog(label: string, ok: boolean, mcp?: string): void {
    this.post({ type: "operationLog", label, ok, ...(mcp !== undefined ? { mcp } : {}) });
  }

  /** テスト実行(RunEventBus の step)由来の操作を「操作記録」へ流す。section=action のみ・
   * skipped は除外。ラベルは手動操作と同じ表示文言に揃える(stepDescriptionToOperationLabel)。 */
  public injectTestStep(event: StepEvent): void {
    if (event.section !== "action" || event.status === "skipped" || !event.description) {
      return;
    }
    const label = stepDescriptionToOperationLabel(event.description);
    this.postOperationLog(label, event.status !== "failed");
  }

  /** actionError バナーを出す共通経路。接続系の文言(serve 不在・タイムアウト・終了)なら
   * connectionBannerShown を立て、serve 復帰時に自動で消せるようにする。個々の操作失敗は
   * false のまま残す(常時回る自動フレームで消さない)。全 actionError post はここを通す。
   * neutral: true は bridgeStarting 中の操作失敗(live.bridgeStartingActionNotice)専用 ——
   * 接続系と同じく自動で消える(connectionBannerShown を立てる)が、webview 側はエラー色にしない。 */
  private postActionError(message: string, neutral = false): void {
    this.connectionBannerShown = neutral || isConnectionClassMessage(message);
    this.post({ type: "actionError", message, ...(neutral ? { neutral: true } : {}) });
  }

  /** LiveBridgeAutoStarter が自動起動を進行中(bridgeStarting)かどうかの表示を同期する
   * (frameTick/applySnapshotResult/runAction のいずれかがイベントを受けるたびに呼ぶ)。
   * 前回と同じ値なら post しない(冪等)。 */
  private applyBridgeStarting(starting: boolean): void {
    if (this.bridgeStartingShown === starting) {
      return;
    }
    this.bridgeStartingShown = starting;
    this.post({ type: "bridgeStarting", starting });
    if (starting) {
      this.scheduleBridgeStartingProbe();
    } else {
      this.clearBridgeStartingProbe();
    }
  }

  /** 「接続中」の間だけ観測を撃ち直し、起動が済んだ回の応答(bridgeStarting:false)で表示を畳む。
   * **掛け直しは観測の後で自分から行う** —— applyBridgeStarting は値が変わらないと何もしないので、
   * 起動中のままの応答からは予約が掛からない */
  private scheduleBridgeStartingProbe(): void {
    this.clearBridgeStartingProbe();
    this.bridgeStartingProbeTimer = setTimeout(() => {
      this.bridgeStartingProbeTimer = undefined;
      void (async () => {
        if (this.liveTabVisible && this.serveProcess && this.currentDeviceRef() && !this.busy) {
          await this.refreshSnapshot();
        }
        if (this.bridgeStartingShown && this.liveTabVisible && this.serveProcess) {
          this.scheduleBridgeStartingProbe();
        }
      })();
    }, BRIDGE_STARTING_PROBE_MS);
  }

  private clearBridgeStartingProbe(): void {
    if (this.bridgeStartingProbeTimer) {
      clearTimeout(this.bridgeStartingProbeTimer);
      this.bridgeStartingProbeTimer = undefined;
    }
  }

  // ---- 接続断の可視化(自動フレームは失敗を無表示で再試行するため、connectionLost の間は
  // webview 側にオーバーレイを出し続けて「最後に取得した静止画」を生きた画面と誤認させない。
  // 受け手: src/webview/monitor/liveTab.js) ----

  /** 接続成功を反映する(streak リセット+connectionLost なら connection:true を post して解除)。
   * 自動フレーム成功・snapshot 成功・デバイス切り替えの起点(古いデバイスのオーバーレイを
   * 新デバイスへ持ち越さないため)から呼ぶ。 */
  private handleConnectionOk(): void {
    this.frameFailureStreak = 0;
    this.serveTimeoutKillStreak = 0;
    // prepareForRun() の waitForStreamSync() を起こす(streamSyncWaiters 冒頭コメントの契約)。
    if (this.streamSyncWaiters.length > 0) {
      const waiters = this.streamSyncWaiters;
      this.streamSyncWaiters = [];
      for (const wake of waiters) {
        wake();
      }
    }
    // serve が復帰したので接続系 actionError バナー(常駐プロセス不在・タイムアウト・終了)が
    // 残っていれば消す。connectionLost の早期 return より前に行う: デバイス切り替えの再バインド中は
    // 自動フレームが serve 不在でスキップして回るため connectionLost が立たず、serve が
    // undefined→復帰してもこの経路でしかバナーを消せない(操作可能なのにエラーが残る問題の本丸)。
    if (this.connectionBannerShown) {
      this.connectionBannerShown = false;
      this.post({ type: "actionError", message: "" });
    }
    if (!this.connectionLost) {
      return;
    }
    this.connectionLost = false;
    this.lastConnectionMessage = undefined;
    this.post({ type: "connection", connected: true, message: null });
  }

  /** 自動フレーム失敗を反映する(streak が3に達したら connectionLost にして post。既に
   * connectionLost でも message が前回と異なれば再 post する: 例えば自動起動が諦めて
   * failed になったときの文言更新を画面に反映するため)。
   * **呼び出し元が bridgeStarting:true の回をここへ回さないこと** —— 起動が進行中の失敗は
   * エラーではない(applyBridgeStarting が中立表示に倒す。frameTick 参照)。 */
  private handleFrameFailure(message: string): void {
    this.frameFailureStreak += 1;
    if (this.frameFailureStreak < 3) {
      return;
    }
    if (this.connectionLost && this.lastConnectionMessage === message) {
      return;
    }
    this.connectionLost = true;
    this.lastConnectionMessage = message;
    this.post({ type: "connection", connected: false, message });
  }

  /** 実行中の live CLI プロセスがあれば SIGTERM(2秒後 SIGKILL)で止める(cli.ts と同じ方針)。 */
  private killActiveChild(): void {
    const proc = this.activeChild;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      return;
    }
    proc.kill("SIGTERM");
    setTimeout(() => {
      if (proc.exitCode === null && proc.signalCode === null) {
        proc.kill("SIGKILL");
      }
    }, 2000);
  }

  /** FleetestCli のキューは使わず専用 spawn する(理由はファイル冒頭のコメント参照)。 */
  private async runCli(args: string[]): Promise<OneShotResult> {
    const config = this.deps.getConfig();
    try {
      return await runOneShot(config.binaryPath, this.deps.workspaceRoot, args, this.deps.outputChannel, (proc) => {
        this.activeChild = proc;
      });
    } finally {
      this.activeChild = undefined;
    }
  }

  private currentDeviceRef(): LiveDeviceRef | undefined {
    const option = this.devices.find((device) => device.id === this.selectedDeviceId);
    return option
      ? { platform: option.platform, port: option.port, serial: option.serial, udid: option.udid,
          machine: option.machine }
      : undefined;
  }

  // ---- デバイス一覧 ---------------------------------------------------------------

  private async refreshDevices(): Promise<void> {
    if (this.busy) {
      return;
    }
    const config = this.deps.getConfig();
    const resolution = resolveProjectName(this.deps.workspaceRoot, config);
    if (resolution.kind !== "resolved") {
      this.applyFallback(config, t("live.projectUnresolved"));
      return;
    }

    this.setBusy(true);
    try {
      // --profile が無いと machines/ が複数のとき「マシン名が未登録」で落ちる(monitorDeviceOps.ts と同経路)
      const listArgs = ["api", "list-devices", "--project", resolution.project];
      if (config.profile) {
        listArgs.push("--profile", config.profile);
      }
      const result = await this.runCli(listArgs);
      const parsed = parseListDevicesResult(result.json);
      if (!parsed) {
        const detail = result.stderrTail.length > 0 ? result.stderrTail : `exit code: ${String(result.exitCode)}`;
        this.applyFallback(config, t("live.deviceListFailedDetail", { detail }));
        return;
      }
      this.applyDevices(devicesToOptions(parsed.devices), undefined);
    } catch (error) {
      this.applyFallback(config, t("live.deviceListFailedError", { error: errorMessage(error) }));
    } finally {
      this.setBusy(false);
    }
  }

  /** pendingSelectId(openDevice 由来)があればそれを優先選択する。無ければ直前の選択が新しい
   * 一覧にも存在するとき維持し、それ以外は先頭を選択する。 */
  private applyDevices(listed: LiveDeviceOption[], bannerMessage: string | undefined): void {
    this.handleConnectionOk();
    const options = [...listed.filter((o) => !this.remoteOptions.has(o.id)), ...this.remoteOptions.values()];
    this.devices = options;
    const pending = this.pendingSelectId;
    this.pendingSelectId = undefined;
    const preferred = pending !== undefined && options.some((o) => o.id === pending) ? pending : undefined;
    const stillExists = this.selectedDeviceId !== undefined && options.some((o) => o.id === this.selectedDeviceId);
    let selected = preferred ?? (stillExists ? this.selectedDeviceId : options[0]?.id);
    // 明示選択(openDevice の pending)が無いときだけ platform 優先を適用する。選択中の platform が
    // preferredPlatform と食い違う場合、一覧の先頭から一致する platform のデバイスを採る。
    if (preferred === undefined && this.preferredPlatform) {
      const current = options.find((o) => o.id === selected);
      if (!current || current.platform !== this.preferredPlatform) {
        const match = options.find((o) => o.platform === this.preferredPlatform);
        if (match) {
          selected = match.id;
        }
      }
    }
    this.selectedDeviceId = selected;
    this.post({ type: "devices", devices: options, selectedId: this.selectedDeviceId });
    this.post({ type: "banner", message: bannerMessage ?? null });
    this.ensureServeProcessForSelection();
    // アプリID/パッケージパスは選択デバイスの platform で解決する(android/ios でセクションが別)。
    // デバイス確定(初期ロード・一覧更新・自動選択)のたびに送り直さないと、platform 未確定時に
    // 計算した空の詳細が残る。
    this.appActions.postAppProfileDetail();
  }

  private applyFallback(config: FleetestConfig, bannerMessage: string): void {
    const option = fallbackDeviceOption({ platform: config.platform, port: config.port, serial: config.serial });
    this.applyDevices([option], bannerMessage);
  }

  /** Run Test 自動オープン(liveTabHost.ts)が「実行中シナリオの platform」を渡す窓口。選択中デバイスの
   * platform が食い違う場合のみ、現在の一覧の先頭から一致する platform のデバイスへ即座に切り替える
   * (一致するデバイスが無ければ現状維持)。一覧未取得のときは preferredPlatform を覚えておき、次の
   * applyDevices が適用する。 */
  preferPlatform(platform: string): void {
    this.preferredPlatform = platform;
    if (this.devices.length === 0) {
      return; // 一覧未取得。refreshDevices 完了時の applyDevices が適用する。
    }
    const current = this.devices.find((o) => o.id === this.selectedDeviceId);
    if (current && current.platform === platform) {
      return; // 既に一致(ミスマッチのときだけ選び直す)。
    }
    const match = this.devices.find((o) => o.platform === platform);
    if (!match || match.id === this.selectedDeviceId) {
      return;
    }
    this.selectedDeviceId = match.id;
    this.post({ type: "devices", devices: this.devices, selectedId: this.selectedDeviceId });
    this.ensureServeProcessForSelection();
    this.appActions.postAppProfileDetail(); // platform 切替に合わせて詳細も更新する(applyDevices と同理由)。
    if (match.state === "connected") {
      void this.refreshSnapshot();
    }
  }

  /** Run Test 実行前(runHandler.ts の executeRun)から呼ばれる。対象 platform のデバイスへ選び直し、
   * 未接続なら start-device で起動して待ち、webview の表示状態に関わらずホスト側でストリーミングを起動して
   * 最初の同期(接続成功)を最大 timeoutMs 待つ(同期のタイムアウトは処理続行。デバイスは確定済み)。
   * webview の visibility メッセージは別途届くが liveTabVisible の再設定は冪等なので無害。
   * 一致する platform のデバイスが無い / 起動に失敗した / 実体識別子が無いときは undefined を返し、
   * 呼び出し元を既存のプロファイル実行へフォールバックさせる(--serial 空で「more than one device」に
   * なる事故を防ぐ)。 */
  async prepareForRun(platform: "ios" | "android", timeoutMs: number): Promise<LiveRunTarget | undefined> {
    if (this.devices.length === 0) {
      await this.refreshDevices();
    }
    this.preferPlatform(platform);
    // preferPlatform は状態を問わず対象 platform の先頭を選ぶ。一覧に対象 platform が無ければ起動対象も
    // 選べないためフォールバック(applyFallback の合成デバイスも platform 不一致なら弾かれる)。
    let option = this.selectedOption();
    if (!option || option.platform !== platform) {
      return undefined;
    }
    // 未接続(offline/booted/unknown)なら start-device で起動して待つ(冷起動は数十秒かかり得る)。
    // 起動後に一覧を取り直し、同じ platform の先頭を選び直してから接続状態を再確認する。
    if (option.state !== "connected") {
      const booted = await this.bootDevice(option.name);
      if (!booted) {
        return undefined;
      }
      await this.refreshDevices();
      this.preferPlatform(platform);
      option = this.selectedOption();
      if (!option || option.platform !== platform || option.state !== "connected") {
        return undefined;
      }
    }
    const ref = this.currentDeviceRef();
    // 実体識別子(android: serial / ios: port)が無ければ単機実行の引数を組めないためフォールバック。
    if (!ref || ref.platform !== platform || (platform === "android" ? !ref.serial : ref.port == null)) {
      return undefined;
    }
    this.liveTabVisible = true;
    this.updateLiveFrameSource();
    await this.waitForStreamSync(timeoutMs);
    return {
      platform: ref.platform,
      serial: ref.serial ?? undefined,
      port: ref.port ?? undefined,
      udid: ref.udid ?? undefined,
    };
  }

  private selectedOption(): LiveDeviceOption | undefined {
    return this.devices.find((o) => o.id === this.selectedDeviceId);
  }

  /** 選択デバイスを `api start-device --name` で起動し完了(exit 0)まで待つ。冷起動で長時間ブロックし得る
   * (start-device 自身がタイムアウト/リトライを持つ)。進捗は live バナーへ出す。list-devices と同じ
   * 専用 spawn(runCli=runOneShot)で FleetestCli の直列キューには乗せない。 */
  private async bootDevice(name: string): Promise<boolean> {
    const config = this.deps.getConfig();
    const resolution = resolveProjectName(this.deps.workspaceRoot, config);
    if (resolution.kind !== "resolved") {
      return false;
    }
    this.post({ type: "banner", message: t("live.deviceBooting", { name }) });
    const args = ["api", "start-device", "--name", name, "--project", resolution.project];
    if (config.profile) {
      args.push("--profile", config.profile);
    }
    try {
      const result = await this.runCli(args);
      const ok = result.exitCode === 0;
      this.post({ type: "banner", message: ok ? null : t("live.deviceBootFailed", { name }) });
      return ok;
    } catch (error) {
      this.post({ type: "banner", message: t("live.deviceBootFailedError", { name, error: errorMessage(error) }) });
      return false;
    }
  }

  /** 次の handleConnectionOk() 到達(=最初のフレーム/snapshot 成功)で true、timeoutMs 経過で false。
   * どちらが先でも二重 resolve しない(settled ガード)。 */
  private waitForStreamSync(timeoutMs: number): Promise<boolean> {
    return new Promise((resolve) => {
      let settled = false;
      const removeWaiter = () => {
        const i = this.streamSyncWaiters.indexOf(waiter);
        if (i >= 0) {
          this.streamSyncWaiters.splice(i, 1);
        }
      };
      // タイムアウトでも waiter を配列から除去する。残すと再接続が来ないまま prepareForRun が
      // 繰り返しタイムアウトした際に streamSyncWaiters が次の handleConnectionOk まで無制限に伸びる。
      const waiter = () => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        removeWaiter();
        resolve(true);
      };
      const timer = setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        removeWaiter();
        resolve(false);
      }, timeoutMs);
      this.streamSyncWaiters.push(waiter);
    });
  }

  /** デバイスタイル右クリック「ライブ操作」から(monitorPanel.ts の deviceTiles.js → liveTabHost.ts の
   * openForDevice → 「ライブ操作」タブの liveTab.js openLiveDevice)。
   * id はモニターと共通の `platform:name`(Swift 側 MonitorTarget.id と devicesToOptions が同形式)。
   * 一覧に無ければ取得し直してから選択し、接続済みなら snapshot まで自動取得する。 */
  /** タイル右クリック(liveTabHost.ts の openForDevice)で開く**他の機械の台**を選択肢に加える。
   * 続く openDevice が一覧を取り直さずにこの id で選べるよう、this.devices にもすぐ入れる */
  registerRemoteDevice(option: LiveDeviceOption): void {
    this.remoteOptions.set(option.id, option);
    const index = this.devices.findIndex((device) => device.id === option.id);
    if (index >= 0) {
      this.devices[index] = option;
    } else {
      this.devices.push(option);
    }
  }

  private async openDevice(id: string): Promise<void> {
    if (this.busy) {
      // 進行中の refreshDevices があれば、その applyDevices がこの id を優先選択する。
      this.pendingSelectId = id;
      return;
    }
    if (this.devices.some((device) => device.id === id)) {
      this.selectedDeviceId = id;
      this.post({ type: "devices", devices: this.devices, selectedId: id });
      this.ensureServeProcessForSelection();
    } else {
      this.pendingSelectId = id;
      await this.refreshDevices();
    }
    if (this.selectedDeviceId !== id) {
      // 一覧取得失敗(フォールバック)は refreshDevices が banner を出し済み。取れた一覧に居ないのは
      // **他の機械の台**(モニターのタイル id が `ios:<machine>/<name>`)か消えた台 —— 黙ると前の台の
      // 画面が出続け、開いたつもりの台と違う画面になる(実地 2026-09-24: M1Ultra の iPhone wave)
      if (this.devices.every((device) => device.id !== id) && this.devices[0]?.id !== FALLBACK_DEVICE_ID) {
        this.post({ type: "banner", message: t("live.deviceNotOpenable", { id }) });
      }
      return;
    }
    const selected = this.devices.find((device) => device.id === id);
    // booted は切り替えの時点で requestOpenObservation が撃つ(ここで撃つと二重になる)
    if (selected?.state === "connected") {
      await this.refreshSnapshot();
    }
  }

  // ---- live serve(常駐プロセス)の起動・停止・再バインド ------------------------------------
  // ファイル冒頭のコメント参照(monitorProcessManager.ts の host-metrics プロセス管理パターンを踏襲)。

  /** 現在選択中のデバイスに serve プロセスをバインドする(未選択なら止める)。デバイス一覧の
   * 取得・切り替えのたびに呼ぶ(applyDevices 経由)。 */
  private ensureServeProcessForSelection(): void {
    const device = this.currentDeviceRef();
    if (!device) {
      if (this.serveDevice) {
        this.clearSnapshotCache();
      }
      this.serveDevice = undefined;
      this.stopServeProcess();
    } else {
      this.ensureServeProcess(device);
    }
    // serve(操作・snapshot 用)とは別に、ライブ映像の供給元(ストリーミング/ポーリング)も
    // 選択デバイスに合わせて張り替える。デバイス選択が変わる経路は全てここを通る。
    this.updateLiveFrameSource();
  }

  /** device 向けの serve プロセスが既に起動していれば何もしない。そうでなければ
   * (未選択→選択・別デバイスへの切り替え・予期しない終了[giveUp 含む]のいずれでも)再バインドする。 */
  private ensureServeProcess(device: LiveDeviceRef): void {
    const bound = this.serveDevice;
    if (this.serveProcess && bound && sameLiveDeviceRef(bound, device)) {
      return;
    }
    const switched = !bound || !sameLiveDeviceRef(bound, device);
    if (switched) {
      this.clearSnapshotCache();
    }
    this.rebindServeProcess(device);
    if (switched) {
      this.requestOpenObservation();
    }
  }

  /** 直前のデバイスのスナップショット(画面サイズ・要素一覧)を捨てる。デバイスを切り替えた
   * のに残っていると、**タップ座標が前のデバイスの画面サイズで換算され**(px の Android →
   * pt の iOS で特に大きく外れる)、要素一覧の行タップは**新しいデバイスの木の同じ番号**を
   * 叩く(ref はスナップショットごとの採番なので、別の要素に当たっても誰も気付けない)。
   * webview 側も同時に捨てさせ、次のフレームで撮り直しを要求させる(clearSnapshot の doc)。 */
  private clearSnapshotCache(): void {
    this.lastScreen = undefined;
    this.lastElements = [];
    this.post({ type: "clearSnapshot" });
  }

  /**
   * 現在の serve(あれば)を止めて device 向けに起動し直す。明示的な再バインドなので直前の giveUp
   * (抑止対象は scheduleServeRestart の無人5秒後リトライのみ)は無視して仕切り直す。多重起動ガードは
   * デバイス連続切り替えでの stop/start 重複を防ぐ(ガード中は serveDevice 更新のみ行い、進行中の
   * 切り替え完了後は最新の serveDevice へ起動する)。
   */
  private rebindServeProcess(device: LiveDeviceRef): void {
    this.serveFailureStreak = 0;
    this.serveGaveUp = false;
    this.serveTimeoutKillStreak = 0;
    this.serveDevice = device;
    if (this.serveRestartPending) {
      return;
    }
    this.serveRestartPending = true;
    const proc = this.serveProcess;
    // 停止処理(SIGTERM→close)完了前に旧プロセスへの参照を消す: sendServeCommand は serveProcess
    // 未設定なら即座にエラーを返すため、切り替え中に送られたコマンドが停止中の旧プロセス
    // (旧デバイス宛)に届くことは無い。
    this.serveProcess = undefined;
    this.killServeProcess(proc);
    const startLatest = (): void => {
      this.serveRestartPending = false;
      const target = this.serveDevice;
      if (target) {
        this.startServeProcess(target);
      }
      // 起動できた場合もできなかった場合も待ち手を解放する(起動しなかった回を待たせ続けない)。
      this.wakeServeReadyWaiters();
    };
    if (!proc) {
      startLatest();
      return;
    }
    proc.once("close", startLatest);
  }

  /** 再バインド完了を待っている呼び出し手を全件起こす(startLatest の終端から1回だけ)。 */
  private wakeServeReadyWaiters(): void {
    if (this.serveReadyWaiters.length === 0) {
      return;
    }
    const waiters = this.serveReadyWaiters;
    this.serveReadyWaiters = [];
    for (const wake of waiters) {
      wake();
    }
  }

  /**
   * 再バインド中(serveRestartPending)なら、新しい serve が立つまで待たせる。デバイスを選んだ
   * 直後の snapshot/操作はこの窓に必ず入るため、待たずに serveUnavailableMessage() を返すと
   * 「常駐プロセスが起動していません。デバイスを選び直してください」が数秒だけ出て、その後
   * 何事もなく画面が出る = 利用者に対処のしようが無い誤報になる(2026-09-23)。
   * 再バインド中でないとき(本当に居ない・諦めた)は待たず、従来どおり即座に断る。
   */
  private awaitServeRebind(): Promise<void> {
    if (!this.serveRestartPending) {
      return Promise.resolve();
    }
    return new Promise((resolve) => {
      let settled = false;
      const wake = (): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(wake, SERVE_REBIND_WAIT_MS);
      this.serveReadyWaiters.push(wake);
    });
  }

  private startServeProcess(device: LiveDeviceRef): void {
    if (this.serveSuspendedForSweep) {
      return;
    }
    if (this.serveRestartTimer) {
      clearTimeout(this.serveRestartTimer);
      this.serveRestartTimer = undefined;
    }
    const config = this.deps.getConfig();
    const serveArgs = ["api", "live", "serve", ...buildDeviceArgs(device)];
    if (device.platform === "ios" && device.udid) {
      serveArgs.push("--udid", device.udid);
    }
    // 他の機械の台は**向こうで** serve を起こす(その台を USB で握っているのはその機械。この Mac から
    // Wi-Fi で2本目のランナーを立てると1台に2本になり両方落ちる)。NDJSON は ssh の stdin/stdout を
    // そのまま通る(remote exec の到達確認は -n で stdin を読まない = RemoteSetupCommand.swift)
    const args = device.machine ? ["remote", "exec", device.machine, "--", ...serveArgs] : serveArgs;
    let proc: ServeProcess;
    try {
      proc = spawn(config.binaryPath, args, {
        cwd: this.deps.workspaceRoot,
        shell: false,
        env: childEnv(),
        stdio: ["pipe", "pipe", "pipe"],
      });
    } catch (error) {
      this.deps.outputChannel.appendLine(t("live.serveSpawnFailed", { error: String(error) }));
      return;
    }
    proc.stdin.on("error", () => undefined);

    this.stoppingServe = false;
    this.serveProcess = proc;
    this.serveStartedAt = Date.now();

    const stdoutParser = new NdjsonParser(
      (value) => this.handleServeEvent(value),
      (line) => this.deps.outputChannel.appendLine(`[live serve stdout] ${line}`),
    );
    const stderrParser = new NdjsonParser(
      (value) => this.deps.outputChannel.appendLine(`[live serve stderr] ${JSON.stringify(value)}`),
      (line) => this.deps.outputChannel.appendLine(`[live serve stderr] ${line}`),
    );
    proc.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => stderrParser.push(chunk));

    proc.on("error", (error) => {
      this.deps.outputChannel.appendLine(t("live.serveProcessError", { error: error.message }));
    });

    proc.on("close", () => {
      stdoutParser.end();
      stderrParser.end();
      if (this.serveProcess === proc) {
        this.serveProcess = undefined;
      }
      this.failPendingServeRequest(serveClosedMessage());
      // 意図した停止(dispose/再バインド)かどうかはフラグだけで判定する(monitorProcessManager.ts と同じ理由)。
      const selfInitiated = this.stoppingServe;
      this.stoppingServe = false;
      if (selfInitiated) {
        return;
      }
      this.scheduleServeRestart();
    });
  }

  /**
   * serve プロセスの予期しない終了を受けて、5秒後に再起動するか諦めるかを決める
   * (monitorProcessManager.ts の scheduleHostMetricsRestart と同じロジック)。起動後10秒未満での
   * 異常終了が3回連続したら諦める(旧バイナリに `api live serve` が無い環境等で無限に再起動
   * ループしないための安全弁)。10秒以上動いてからの終了は正常運転とみなして連続回数をリセットする。
   */
  private scheduleServeRestart(): void {
    const elapsedMs = Date.now() - (this.serveStartedAt ?? Date.now());
    if (elapsedMs < 10000) {
      this.serveFailureStreak += 1;
    } else {
      this.serveFailureStreak = 0;
    }
    if (this.serveFailureStreak >= 3) {
      if (!this.serveGaveUp) {
        this.serveGaveUp = true;
        this.deps.outputChannel.appendLine(t("live.serveGiveUpEarlyExit"));
      }
      return;
    }
    this.serveRestartTimer = setTimeout(() => {
      this.serveRestartTimer = undefined;
      if (this.deps.isPanelActive() && this.serveDevice) {
        this.startServeProcess(this.serveDevice);
      }
    }, 5000);
  }

  /**
   * 「全て終了」の直前に呼ぶ。serve を止めて終了(close)まで待つ —— serve は終了時に自分の台の印
   * (`.fleetest/mcp-<鍵>.lease`。Sources/fleetest/LiveDeviceLease.swift)を消すので、これで
   * 全掃討(`devices down` の sweepRefusal)がこの印で丸ごと断られなくなる。掴んだままだと
   * 「MCP session が駆動中」と名指しされて何も止まらない(実地 2026-09-24)。
   * 他の機械の台(remote exec 越しの serve)も同じに畳む: 掃討はその機械へも分散し、向こうの印は
   * 向こうの serve が stdin EOF で消す(こちらで待つのは手元の子の close まで)。
   * resumeServeAfterSweep が呼ばれるまで serve は起動しない。
   */
  async suspendServeForSweep(): Promise<void> {
    this.serveSuspendedForSweep = true;
    if (this.serveRestartTimer) {
      clearTimeout(this.serveRestartTimer);
      this.serveRestartTimer = undefined;
    }
    const proc = this.serveProcess;
    this.serveProcess = undefined;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      return;
    }
    await new Promise<void>((resolve) => {
      let settled = false;
      const done = (): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(done, SERVE_SWEEP_STOP_WAIT_MS);
      proc.once("close", done);
      this.killServeProcess(proc);
    });
  }

  /** 「全て終了」が終わったら呼ぶ。起動の抑止を解き、パネル再オープンと同じ経路
   * (refreshDevices → applyDevices → ensureServeProcessForSelection)で serve を立て直す
   * (選んでいた台が落ちた・ブリッジが消えた後の扱いをそちらに任せる)。 */
  resumeServeAfterSweep(): void {
    if (!this.serveSuspendedForSweep) {
      return;
    }
    this.serveSuspendedForSweep = false;
    if (this.liveTabVisible) {
      void this.refreshDevices();
    }
  }

  /** 実行中の serve プロセスがあれば止めて(this.serveProcess も即座に未設定に戻す)、参照を
   * 手放す(dispose/panel破棄から呼ぶ。デバイス切り替え中の再バインドは rebindServeProcess が
   * 個別に this.serveProcess を扱うため、こちらは呼ばない)。 */
  private stopServeProcess(): void {
    // 表示ごと解く(予約だけ消すと「表示中」の記録が残り、次の serve も起動中だったとき
    // 値が変わらず予約が掛からない = 同じ台の切り替えで「接続中」が残り続ける)
    this.applyBridgeStarting(false);
    if (this.serveRestartTimer) {
      clearTimeout(this.serveRestartTimer);
      this.serveRestartTimer = undefined;
    }
    const proc = this.serveProcess;
    this.serveProcess = undefined;
    this.killServeProcess(proc);
  }

  /** proc(あれば)を SIGTERM(2秒後 SIGKILL)で止める(stdin EOF も送ってどちらでもクリーンに
   * 終了できるようにする)。this.serveProcess の書き換えは行わない(呼び出し元の責務。
   * rebindServeProcess/stopServeProcess のどちらも、旧プロセスへの参照を手放してから呼ぶ)。 */
  private killServeProcess(proc: ServeProcess | undefined): void {
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      return;
    }
    this.stoppingServe = true;
    proc.stdin.end();
    proc.kill("SIGTERM");
    setTimeout(() => {
      if (proc.exitCode === null && proc.signalCode === null) {
        proc.kill("SIGKILL");
      }
    }, 2000);
  }

  /** 応答タイムアウト時に、生きたまま無応答になった(wedge した)serve を止める。serve 側は
   * SIGTERM を SIG_IGN で無視するため、実際の停止は stdin EOF(serve の ResidentProcessGuard による
   * 2秒強制終了)か2秒後の SIGKILL による。killServeProcess とは違い stoppingServe を立てないので、
   * close ハンドラが scheduleServeRestart で現デバイスへ自動 respawn する(=wedge からの自動復帰)。
   * 連続 MAX_CONSECUTIVE_TIMEOUT_KILLS 回で諦め、再起動させず serveUnavailableMessage() を出す。 */
  private restartWedgedServe(proc: ServeProcess): void {
    if (this.serveProcess !== proc || proc.exitCode !== null || proc.signalCode !== null) {
      return;
    }
    this.serveTimeoutKillStreak += 1;
    if (this.serveTimeoutKillStreak >= MAX_CONSECUTIVE_TIMEOUT_KILLS) {
      this.serveGaveUp = true;
      this.stoppingServe = true; // close ハンドラに自己終了とみなさせ、再起動を抑止する
      this.deps.outputChannel.appendLine(t("live.serveGiveUpTimeout"));
      this.postActionError(serveUnavailableMessage());
    } else {
      this.deps.outputChannel.appendLine(
        t("live.serveTimeoutRestart", { seconds: SERVE_REQUEST_TIMEOUT_MS / 1000 }),
      );
    }
    proc.stdin.end();
    proc.kill("SIGTERM");
    setTimeout(() => {
      if (proc.exitCode === null && proc.signalCode === null) {
        proc.kill("SIGKILL");
      }
    }, 2000);
  }

  /** serve の stdout から届いた NDJSON 1行を pendingServeRequest に配る。actionResult は
   * 保持だけして、続く snapshot/frame イベントで resolve する(ファイル冒頭プロトコル参照)。
   * pending.resolvesOn と一致しない kind(自動フレームとユーザー操作の取り違え)は無視する。 */
  private handleServeEvent(value: unknown): void {
    const event = parseLiveServeEvent(value);
    if (!event) {
      this.deps.outputChannel.appendLine(t("live.serveUnknownLine", { value: JSON.stringify(value) }));
      return;
    }
    const pending = this.pendingServeRequest;
    if (!pending) {
      this.deps.outputChannel.appendLine(t("live.serveNoPendingRequest", { kind: event.kind }));
      return;
    }
    if (event.kind === "actionResult") {
      pending.action = event.result;
      return;
    }
    if (event.kind !== pending.resolvesOn) {
      this.deps.outputChannel.appendLine(
        t("live.serveMismatchedEvent", { expected: pending.resolvesOn, actual: event.kind }),
      );
      return;
    }
    if (event.kind === "snapshot") {
      this.settlePendingServeRequest({ action: pending.action, snapshot: event.result });
    } else {
      this.settlePendingServeRequest({ frame: event.result });
    }
  }

  private settlePendingServeRequest(outcome: PendingServeOutcome): void {
    const pending = this.pendingServeRequest;
    if (!pending) {
      return;
    }
    this.pendingServeRequest = undefined;
    clearTimeout(pending.timeout);
    pending.resolve(outcome);
  }

  /** 応答を受け取れなくなった(プロセス終了・タイムアウト)ときに、待たせている呼び出し元を
   * エラー結果で解放する(busy 状態のまま固まらないようにする安全弁)。resolvesOn に応じて
   * snapshot/frame のどちらか一方だけを埋める。 */
  private failPendingServeRequest(message: string): void {
    const pending = this.pendingServeRequest;
    if (!pending) {
      return;
    }
    // **bridgeStarting は常に false**(この経路は自動起動とは無関係の host 側の障害
    // [プロセス終了・応答タイムアウト]なので、デバイスが起動中かどうかは分からない・関係ない)
    if (pending.resolvesOn === "frame") {
      this.settlePendingServeRequest({ frame: { ok: false, error: message, bridgeStarting: false } });
      return;
    }
    this.settlePendingServeRequest({
      action: pending.expectsAction ? { ok: false, error: message, bridgeStarting: false } : undefined,
      snapshot: { ok: false, error: message, bridgeStarting: false },
    });
  }

  /** serve への送信を直列化するチェーン内で run を実行する(自動フレームとユーザー操作の pending
   * スロット競合を防ぐ)。チェーン自体は常に成功状態を維持する(run の失敗を次回以降へ持ち越さない)。 */
  private enqueueServeSend<T>(run: () => Promise<T>): Promise<T> {
    const result = this.serveSendChain.then(run, run);
    this.serveSendChain = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }

  /** command を serve の stdin へ送り、対応する応答(actionResult[refresh以外]+snapshot)が
   * 揃うまで待つ。再バインド中なら新しい serve が立つのを待ち(awaitServeRebind)、それでも
   * 起動していなければ CLI を呼ばずに即座にエラー結果を返す。
   * enqueueServeSend で直列化する(実体は sendServeCommandNow)。 */
  private sendServeCommand(command: LiveServeCommand): Promise<ServeRequestOutcome> {
    return this.enqueueServeSend(() => this.sendServeCommandNow(command));
  }

  private async sendServeCommandNow(command: LiveServeCommand): Promise<ServeRequestOutcome> {
    await this.awaitServeRebind();
    const proc = this.serveProcess;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      const message = serveUnavailableMessage();
      // serve プロセス自体が居ない(bridgeStarting とは無関係の host 側の障害)
      return Promise.resolve({
        action: command.cmd === "refresh" ? undefined : { ok: false, error: message, bridgeStarting: false },
        snapshot: { ok: false, error: message, bridgeStarting: false },
      });
    }
    return new Promise((resolve) => {
      // 軌跡の再生時間は応答待ちの上限に足す(serve 側の command watchdog も同じだけ延びる)
      const timeout = setTimeout(() => {
        this.failPendingServeRequest(serveTimeoutMessage());
        this.restartWedgedServe(proc);
      }, SERVE_REQUEST_TIMEOUT_MS + serveCommandPlaybackMs(command));
      this.pendingServeRequest = {
        expectsAction: command.cmd !== "refresh",
        resolvesOn: "snapshot",
        action: undefined,
        resolve: (outcome) =>
          resolve({
            action: outcome.action,
            snapshot: outcome.snapshot ?? {
              ok: false, error: t("live.internalErrorSnapshotMissing"), bridgeStarting: false,
            },
          }),
        timeout,
      };
      proc.stdin.write(serializeLiveServeCommand(command));
    });
  }

  /** 画像のみの frame コマンドを送る(自動リフレッシュ用)。再バインド中なら待ち、それでも serve が
   * 起動していなければ CLI を呼ばずに即座にエラー結果を返す(sendServeCommandNow と同じ文言)。
   * enqueueServeSend で直列化する。 */
  private sendServeFrame(): Promise<LiveFrameResult> {
    return this.enqueueServeSend(() => this.sendServeFrameNow());
  }

  private async sendServeFrameNow(): Promise<LiveFrameResult> {
    await this.awaitServeRebind();
    const proc = this.serveProcess;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      return Promise.resolve({
        ok: false,
        error: serveUnavailableMessage(),
        bridgeStarting: false,
      });
    }
    return new Promise((resolve) => {
      const timeout = setTimeout(() => {
        this.failPendingServeRequest(serveTimeoutMessage());
        this.restartWedgedServe(proc);
      }, SERVE_REQUEST_TIMEOUT_MS);
      this.pendingServeRequest = {
        expectsAction: false,
        resolvesOn: "frame",
        action: undefined,
        resolve: (outcome) =>
          resolve(outcome.frame ?? {
            ok: false, error: t("live.internalErrorFrameMissing"), bridgeStarting: false,
          }),
        timeout,
      };
      proc.stdin.write(serializeLiveServeCommand({ cmd: "frame" }));
    });
  }

  // ---- snapshot -------------------------------------------------------------------

  private applySnapshotResult(result: LiveSnapshot | LiveErrorResult): void {
    this.applyBridgeStarting(result.bridgeStarting);
    if (!result.ok) {
      // 自動起動が進行中の失敗はエラーとして出さない(applyBridgeStarting の中立表示に任せる。
      // 起動が終わっていればこの回は自動で reachable になる=撃ち直しはしない)
      if (result.bridgeStarting) {
        return;
      }
      this.postActionError(result.error);
      return;
    }
    this.handleConnectionOk();
    this.lastScreen = result.screen;
    this.lastElements = result.elements;
    this.post(toSnapshotMessage(result));
  }

  private async fetchSnapshot(): Promise<void> {
    const device = this.currentDeviceRef();
    if (!device) {
      this.postActionError(t("live.noDeviceSelected"));
      return;
    }
    this.ensureServeProcess(device);
    const { snapshot } = await this.sendServeCommand({ cmd: "refresh" });
    this.applySnapshotResult(snapshot);
  }

  private async refreshSnapshot(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.setBusy(true);
    try {
      await this.fetchSnapshot();
    } catch (error) {
      this.postActionError(t("live.snapshotFailed", { error: errorMessage(error) }));
    } finally {
      this.setBusy(false);
    }
  }

  // ---- ライブ映像の供給元切り替え(ストリーミング ⇄ ポーリング) --------------------------
  // 設定タブ「ポーリングモードを使用する」のトグルはワークスペース単位で永続化される
  // (workspaceState の "monitor.pollingMode")のみで、パネルを跨いだ即時反映のプッシュ通知は無い。
  // このパネルへは次のデバイス選択/表示状態変化(updateLiveFrameSource 呼び出し契機)で追随する。

  /**
   * ライブフレームの供給元を「画面ストリーミング(iOS: fleetest-simstream / Android:
   * fleetest-androidstream)」と「serve ポーリング(frameTick)」の間で切り替える唯一の分岐点。
   * デバイス選択・表示状態が変わるたびに呼ぶ。ストリーミング条件を満たせば frameTick を止めて
   * helper を起動し、満たさなければ helper を止めて(表示中なら)ポーリングへ戻す。ポーリングは
   * ヘッドレスでも動くフォールバックなので、ストリーミング不可・helper 未ビルドでもライブ操作は成立する。
   * isPollingMode() が true の間は両プラットフォームともストリーミング条件を無条件に不成立とする。
   */
  private updateLiveFrameSource(): void {
    const config = this.deps.getConfig();
    const device = this.currentDeviceRef();
    const pollingForced = this.deps.isPollingMode();
    // codecError(scope=live)を受けていれば設定値に関わらず mjpeg 固定(fallbackToMjpeg 参照)。
    const codec: "mjpeg" | "h264" = this.liveMjpegFallback ? "mjpeg" : config.streamCodec;
    const codecArgs = codec === "h264" ? ["--codec", "h264"] : [];

    // **iOS 実機は simstream を使わない**(CoreSimulator の私有 API = シミュレータ専用。実機の UDID は
    // 「invalid UDID」で即終了し、再起動を繰り返す間はポーリングも止まる = 前の台の絵が残って見えた。
    // モニターのタイルと同じ規則: monitorDeviceStreamController.ts)。ポーリング(serve の frame)へ直行する
    const physical = this.selectedOption()?.kind === "physical";
    // 他の機械の台も配信は張らない(simstream/androidstream はこの Mac の台しか映せない)。ポーリング
    // (serve の frame)は serve ごと向こうで動くのでそのまま使える
    const remote = device?.machine !== undefined;
    if (!pollingForced && this.liveTabVisible && config.iosStreamEnabled && device?.platform === "ios" && device.udid
        && !physical && !remote) {
      const simStreamPath = resolveSimStream(config);
      if (simStreamPath) {
        this.clearFrameTimer();
        this.startStreamPipeline(device.udid, {
          command: simStreamPath,
          args: [
            "--udid", device.udid, "--fps", String(config.liveFps), "--max-width", String(LIVE_STREAM_MAX_WIDTH),
            ...codecArgs,
          ],
          logPrefix: `ios-stream ${device.udid}`,
          codec,
        });
        return;
      }
    } else if (
      !pollingForced &&
      this.liveTabVisible &&
      config.androidStreamEnabled &&
      device?.platform === "android" &&
      device.serial &&
      !remote
    ) {
      const androidStreamPath = resolveAndroidStream(config);
      const adbPath = androidStreamPath ? resolveAdb() : undefined;
      if (androidStreamPath && adbPath) {
        this.clearFrameTimer();
        this.startStreamPipeline(device.serial, {
          command: androidStreamPath,
          args: [
            "--serial", device.serial, "--adb", adbPath,
            "--fps", String(config.liveFps), "--max-width", String(LIVE_STREAM_MAX_WIDTH),
            ...codecArgs,
          ],
          logPrefix: `android-stream ${device.serial}`,
          codec,
        });
        return;
      }
    }

    this.stopStreamPipeline();
    if (this.liveTabVisible) {
      this.scheduleFrameTick(0);
    } else {
      this.clearFrameTimer();
    }
  }

  /** webview から codecError(scope=live)を受けたら monitorPanel.ts から呼ぶ。以後 mjpeg 固定にし、
   * 稼働中のストリームがあれば同じ対象へ即座に mjpeg で再起動する(updateLiveFrameSource の
   * startStreamPipeline は同一 key・稼働中なら早期returnするため、先に止めてから呼び直す)。 */
  fallbackToMjpeg(): void {
    this.liveMjpegFallback = true;
    if (this.streamPipeline) {
      this.stopStreamPipeline();
      this.updateLiveFrameSource();
    }
  }

  /** webview から streamStall(scope=live)を受けたら monitorPanel.ts から呼ぶ。初期キーフレームの
   * 取り逃しで描画が始まらない状態を、helper を作り直して新キーフレームから始めさせて回復する
   * (startStreamPipeline は同一 key・稼働中なら早期returnするため、先に止めてから張り直す)。
   * fallbackToMjpeg と同型。 */
  restartStream(): void {
    if (this.streamPipeline) {
      this.stopStreamPipeline();
      this.updateLiveFrameSource();
    }
  }

  /** key(iOS: UDID、Android: adb serial)向けの StreamPipeline を起動する。同じ key で既に稼働中
   * なら何もしない(張り替えでフレームが途切れないように)。別 key なら旧 helper を止めて張り替える。 */
  private startStreamPipeline(
    key: string,
    spec: {
      readonly command: string;
      readonly args: readonly string[];
      readonly logPrefix: string;
      readonly codec: "mjpeg" | "h264";
    },
  ): void {
    if (this.streamPipeline && this.streamPipeline.isRunning() && this.streamKey === key) {
      return;
    }
    this.stopStreamPipeline();
    this.streamKey = key;
    const pipeline = new StreamPipeline({
      command: spec.command,
      args: spec.args,
      logPrefix: spec.logPrefix,
      outputChannel: this.deps.outputChannel,
      codec: spec.codec,
      onFrame: (image) => {
        // ライブ操作パネルの frame メッセージは w/h を持たない(deviceStream.ts 冒頭コメント参照)ため無視する。
        this.handleConnectionOk();
        this.post({ type: "frame", image });
      },
      onChunk: (data, keyframe, width, height) => {
        this.handleConnectionOk();
        // liveH264Chunk は "live" 封筒を経由しない top-level メッセージ(webview 側
        // src/webview/monitor/main.js の直下ディスパッチャが受ける契約。monitorModel.ts の
        // MonitorToWebviewMessage 参照)。
        this.deps.post({ type: "liveH264Chunk", keyframe, width, height, data: new Uint8Array(data) });
      },
      onConnectionOk: () => this.handleConnectionOk(),
      // helper が「この機械では h264 が無理」と降りたら mjpeg で張り直す(タイル側と同じ扱い。
      // 配線しないと同じ引数で再起動し続け、無フレームのまま諦めてポーリングへ落ちる)
      onCodecUnavailable: () => this.fallbackToMjpeg(),
      onFailure: (message) => this.handleStreamGiveUp(message),
    });
    this.streamPipeline = pipeline;
    pipeline.start();
  }

  /** 稼働中のストリーミング helper を止めてバインド情報も消す(dispose/切り替え/非表示から呼ぶ)。 */
  private stopStreamPipeline(): void {
    if (this.streamPipeline) {
      this.streamPipeline.dispose();
      this.streamPipeline = undefined;
    }
    this.streamKey = undefined;
  }

  /** ストリーミングが継続不能になったときのフォールバック。helper を止め、接続断は出さずに
   * ポーリング(frameTick)へ戻す(ポーリングはヘッドレスでも動く既存経路)。 */
  private handleStreamGiveUp(message: string): void {
    this.deps.outputChannel.appendLine(t("live.streamGiveUpSwitchPolling", { message }));
    this.stopStreamPipeline();
    if (this.liveTabVisible) {
      this.scheduleFrameTick(0);
    }
  }

  // ---- 自動フレーム(ライブタブ表示中、画像のみの定期更新) ------------------------------

  private clearFrameTimer(): void {
    if (this.frameTimer) {
      clearTimeout(this.frameTimer);
      this.frameTimer = undefined;
    }
  }

  private scheduleFrameTick(delayMs: number): void {
    if (this.frameTimer) {
      return;
    }
    this.frameTimer = setTimeout(() => {
      this.frameTimer = undefined;
      void this.frameTick();
    }, delayMs);
  }

  /** 表示中のみ回る自動フレーム。busy(ユーザー操作中)・パネル非表示・serve 不在の回はスキップ
   * (このスキップ回は handleFrameFailure の streak に数えない)。失敗3回連続で接続断オーバーレイに
   * 切り替わる(handleFrameFailure)。serve 死は既存の自動再起動が回復する。
   * **bridgeStarting 中の失敗は handleFrameFailure へ回さない** —— 自動起動の進行中は
   * applyBridgeStarting が中立の「接続中」表示に倒す(接続断のエラー表示は本当に止まった
   * ときだけ出す)。
   * 成功時は config.liveFps を上限とする間隔(1フレームの実測所要を差し引く)で次フレームへ。
   * **delayMs=0 のホットループにしない** —— デバイスが返す限り最速で /screenshot を叩く(iOS/Android 共通)。
   * スキップ・失敗時のみ FRAME_IDLE_RETRY_MS 空ける。 */
  private async frameTick(): Promise<void> {
    if (!this.liveTabVisible) {
      return;
    }
    // ストリーミング中はポーリングしない(二重取得を避ける)。ここで抜けると再スケジュールもしないため
    // 供給元がストリーミングへ切り替わった直後に残っていた tick はこの1回で自然に止まる。
    if (this.streamPipeline?.isRunning()) {
      return;
    }
    let delayMs = FRAME_IDLE_RETRY_MS;
    if (this.deps.isPanelActive() && !this.busy && this.serveProcess && this.currentDeviceRef()) {
      const startedAt = Date.now();
      const frame = await this.sendServeFrame();
      this.applyBridgeStarting(frame.bridgeStarting);
      if (frame.ok) {
        this.handleConnectionOk();
        this.post({ type: "frame", image: frame.image });
        const targetPeriodMs = Math.round(1000 / this.deps.getConfig().liveFps);
        delayMs = Math.max(0, targetPeriodMs - (Date.now() - startedAt));
      } else if (!frame.bridgeStarting) {
        this.handleFrameFailure(frame.error);
      }
    }
    if (this.liveTabVisible && !this.streamPipeline?.isRunning()) {
      this.scheduleFrameTick(delayMs);
    }
  }

  // ---- tap/type/drag/press/terminate/appSwitcher/home ---------------------------

  /** serve へ1コマンド送って結果を反映する。成功時は serve が続けて返す観測イベント(操作後の
   * 追加待ちなしで届く。ブリッジ応答=UI整定済みのため)をそのまま画面へ反映する。失敗時は
   * 画面を再取得しない(観測イベント自体は届くが反映せず、直近のエラーを表示する)。
   * recordStep はレコーディング中(appActions.recordStep)かつ action 成功時に記録する(busy中スキップ・
   * デバイス未選択・action失敗では記録しない)。snapshot 失敗では記録を止めない: home/appSwitcher/
   * terminate は対象アプリを離れ直後の観測が失敗し得るが、操作自体は成立しているため。
   * silentObservation: 直後に別コマンドが続くとき観測を反映・表示せず action 成否だけ返す。
   * install(=simctl 再インストール)はアプリを終了させるため直後の snapshot は必ず失敗する(正常)。
   * これを表示・中断に使わないための逃げ道(録画開始の install→launch で使う)。
   * 戻り値は呼び出し元(startRecord)が install/launch の成否判定に使う。 */
  private async runAction(
    command: LiveServeCommand,
    recordStep?: RecordedStep,
    options?: { readonly silentObservation?: boolean; readonly logLabel?: string },
  ): Promise<boolean> {
    if (this.busy) {
      // **黙って落とさない** —— 画面タップ・ツールバーは busy 中 webview 側で止まるが、
      // レコーディング開始は止まらないので、ここに来ると overlay だけ光って何も起きない
      this.postActionError(t("live.busyRetry"));
      return false;
    }
    const device = this.currentDeviceRef();
    if (!device) {
      this.postActionError(t("live.noDeviceSelected"));
      return false;
    }
    this.setBusy(true);
    // 要素一覧は sendServeCommand の観測で入れ替わるので、送る前の(利用者が見ていた)木で引く
    const mcp = mcpCommandForServeCommand(command, this.lastElements);
    try {
      this.ensureServeProcess(device);
      const { action, snapshot } = await this.sendServeCommand(command);
      if (action) {
        this.applyBridgeStarting(action.bridgeStarting);
      }
      if (action && !action.ok) {
        // 自動起動が進行中の失敗はエラーとして出さない —— 撃ち直しはしない
        // (利用者が画面の復帰を見てから自分でやり直す。interruption-no-resend-policy と同じ理由)
        if (action.bridgeStarting) {
          this.postActionError(t("live.bridgeStartingActionNotice"), true);
        } else {
          this.postActionError(action.error);
        }
        if (options?.logLabel) {
          this.postOperationLog(options.logLabel, false, mcp);
        }
        return false;
      }
      // **利用者の操作が通ったら前のエラーは消す** —— 自動で消えるのは接続系の3文言だけ
      // (isConnectionClassMessage)なので、ブリッジ接続拒否のように serve が返した文言は
      // 状況が直っても残り続けていた。ここは利用者が起こした操作の成功経路だけを通るので、
      // 常時回っている自動フレーム(frameTick)が読む前に消してしまうことはない。
      this.post({ type: "actionError", message: "" });
      this.connectionBannerShown = false;
      // 記録するのは対象アプリの上での操作だけ(LiveAppActions.recordStep の operationBelongsToApp doc)
      this.appActions.recordStep(recordStep, action?.app);
      if (options?.logLabel) {
        this.postOperationLog(options.logLabel, true, mcp);
      }
      if (options?.silentObservation) {
        return true;  // action は成功。観測は反映も表示もしない(直後の launch が画面を出す)
      }
      this.applySnapshotResult(snapshot);
      return snapshot.ok;
    } catch (error) {
      this.postActionError(t("live.actionFailed", { error: errorMessage(error) }));
      return false;
    } finally {
      this.setBusy(false);
    }
  }

  /** 画像上の点タップ専用。タップ成功後、当たった要素がテキスト入力欄なら webview の
   * 「入力するテキスト」欄へフォーカスを移す(デバイス側の入力欄フォーカスに続けてすぐ入力できる)。
   * hit は tapPoint 側で算出済みの当たり要素(recordStep と同じ hitTestElement 結果)。 */
  private async runTapAtPoint(
    command: LiveServeCommand,
    step: RecordedStep | undefined,
    hit: LiveElement | undefined,
    logLabel: string,
  ): Promise<void> {
    const ok = await this.runAction(command, step, { logLabel });
    if (ok && hit && isTextInputElement(hit)) {
      this.post({ type: "focusTypeInput" });
    }
  }

  // ---- webview からのメッセージ -----------------------------------------------------
  // isLiveFromWebviewMessage による型ガードは呼び出し元(monitorPanel.ts の
  // isMonitorFromWebviewMessage の "live" ケース)側で済んでいるためここでは行わない。

  handleWebviewMessage(message: LiveFromWebviewMessage): void {
    switch (message.type) {
      case "refreshDevices":
        void this.refreshDevices();
        break;
      case "selectDevice":
        if (this.devices.some((device) => device.id === message.id)) {
          this.handleConnectionOk();
          this.preferredPlatform = undefined; // 手動選択は platform 優先より強い(明示選択を尊重)
          this.selectedDeviceId = message.id;
          this.ensureServeProcessForSelection();
          this.appActions.postAppProfileDetail();
        }
        break;
      case "openDevice":
        this.preferredPlatform = undefined; // 手動(タイル右クリック)選択は platform 優先を解除する
        void this.openDevice(message.id);
        // デバイスタイル右クリック起動(liveTab.js の openLiveDevice)は refreshAppProfiles を
        // 送らない(初回自動 refresh を抑止する経路)ため、ここでアプリプロファイル一覧を補充する。
        this.appActions.refreshAppProfiles();
        break;
      case "refreshSnapshot":
        void this.refreshSnapshot();
        break;
      case "tapPoint": {
        if (!this.lastScreen) {
          this.postActionError(t("live.refreshFirst"));
          break;
        }
        const point = pointFromClick(
          { x: message.clickX, y: message.clickY },
          { width: message.displayWidth, height: message.displayHeight },
          this.lastScreen,
        );
        const tapHit = hitTestElement(point, this.lastElements);
        const tapChain = tapHit ? locatorChainForElement(tapHit, this.lastElements) : undefined;
        const tapStep: RecordedStep | undefined = tapChain ? { action: "tap", ...tapChain } : undefined;
        const tapLabel = tapHit
          ? t("live.opLabel.tap", { target: describeElementShort(tapHit) })
          : t("live.opLabel.tap", { target: `(${Math.round(point.x)}, ${Math.round(point.y)})` });
        void this.runTapAtPoint({ cmd: "tap", x: point.x, y: point.y }, tapStep, tapHit, tapLabel);
        break;
      }
      case "dragPoints": {
        if (!this.lastScreen) {
          this.postActionError(t("live.refreshFirst"));
          break;
        }
        const display = { width: message.displayWidth, height: message.displayHeight };
        const from = pointFromClick({ x: message.fromX, y: message.fromY }, display, this.lastScreen);
        const to = pointFromClick({ x: message.toX, y: message.toY }, display, this.lastScreen);
        // 実測時間をそのまま実機に流すと serve タイムアウト(20秒)に触れるためクランプする
        const pressSeconds = Math.min(Math.max(message.pressMs / 1000, 0), 3);
        const durationSeconds = Math.min(Math.max(message.dragMs / 1000, 0.05), 8);
        const dx = message.toX - message.fromX;
        const dy = message.toY - message.fromY;
        const direction: "up" | "down" | "left" | "right" =
          Math.abs(dx) >= Math.abs(dy) ? (dx >= 0 ? "right" : "left") : dy < 0 ? "up" : "down";
        const swipeLabel = t("live.opLabel.swipe", { direction: swipeDirectionLabel(direction) });
        void this.runAction(
          {
            cmd: "drag",
            fromX: from.x, fromY: from.y, toX: to.x, toY: to.y,
            press: pressSeconds, duration: durationSeconds,
          },
          { action: "swipe", direction },
          { logLabel: swipeLabel },
        );
        break;
      }
      case "tracePoints": {
        if (!this.lastScreen) {
          this.postActionError(t("live.refreshFirst"));
          break;
        }
        const screen = this.lastScreen;
        const display = { width: message.displayWidth, height: message.displayHeight };
        // t は webview ではミリ秒(pointerdown からの経過)。GestureRequest/ft_gesture は秒なので
        // ここで一度だけ変換する(座標は既存のドラッグと同じ pointFromClick)
        const devicePoints = message.points.map((p) => ({
          ...pointFromClick({ x: p.x, y: p.y }, display, screen),
          t: p.t / 1000,
        }));
        const totalSeconds = devicePoints[devicePoints.length - 1]?.t ?? 0;
        // **時間を縮めない**(利用者の決定: なぞった時間どおりに再生する)。既定上限を超えたら
        // この1回だけ maxGestureSeconds で上げ、絶対上限を超えるものは送らずに断る
        const cap = gestureCapFor(totalSeconds);
        if (cap === "tooLong") {
          this.postActionError(t("live.traceTooLong", {
            seconds: Math.round(totalSeconds), max: GESTURE_SECONDS_CEILING,
          }));
          break;
        }
        const fingers = [{ points: devicePoints }];
        const traceLabel = t("live.opLabel.trace");
        void this.runAction(
          cap === undefined ? { cmd: "gesture", fingers } : { cmd: "gesture", fingers, maxGestureSeconds: cap },
          {
            action: "gesture", gesture: recordedGestureFingers(fingers, screen),
            ...(cap === undefined ? {} : { maxGestureSeconds: cap }),
          },
          { logLabel: traceLabel },
        );
        break;
      }
      case "pressPoint": {
        if (!this.lastScreen) {
          this.postActionError(t("live.refreshFirst"));
          break;
        }
        const point = pointFromClick(
          { x: message.clickX, y: message.clickY },
          { width: message.displayWidth, height: message.displayHeight },
          this.lastScreen,
        );
        // 実測ホールド時間をそのまま流す(serve タイムアウト対策で 0.5〜5 秒にクランプ)
        const duration = Math.min(Math.max(message.holdMs / 1000, 0.5), 5);
        const pressHit = hitTestElement(point, this.lastElements);
        const pressStep: RecordedStep | undefined = pressHit
          ? { action: "press", ...locatorChainForElement(pressHit, this.lastElements) }
          : undefined;
        const pressLabel = pressHit
          ? t("live.opLabel.press", { target: describeElementShort(pressHit) })
          : t("live.opLabel.press", { target: `(${Math.round(point.x)}, ${Math.round(point.y)})` });
        void this.runAction({ cmd: "press", x: point.x, y: point.y, duration }, pressStep, { logLabel: pressLabel });
        break;
      }
      case "doubleTapPoint": {
        if (!this.lastScreen) {
          this.postActionError(t("live.refreshFirst"));
          break;
        }
        const point = pointFromClick(
          { x: message.clickX, y: message.clickY },
          { width: message.displayWidth, height: message.displayHeight },
          this.lastScreen,
        );
        // 記録は tap と同じくロケータ付きにする(生成コードは doubleTap("#id"))。
        // **座標へ畳んでから送る**のは ref の名前空間がブリッジごとに違うため(AppDriver の注記)
        const hit = hitTestElement(point, this.lastElements);
        const step: RecordedStep | undefined = hit
          ? { action: "doubleTap", ...locatorChainForElement(hit, this.lastElements) }
          : undefined;
        const label = hit
          ? t("live.opLabel.doubleTap", { target: describeElementShort(hit) })
          : t("live.opLabel.doubleTap", { target: `(${Math.round(point.x)}, ${Math.round(point.y)})` });
        void this.runAction({ cmd: "doubleTap", x: point.x, y: point.y }, step, { logLabel: label });
        break;
      }
      case "pinch": {
        // 画面全体が対象(要素指定はパネルからは出さない — 対象の指し方が経路で違い、
        // 人が選べる形にすると誤解を招く。DSL 側は pinchOut("#map") が書ける)
        const zoomIn = message.zoomIn;
        void this.runAction(
          { cmd: "pinch", scale: zoomIn ? 2 : 0.5, duration: 0.5 },
          { action: zoomIn ? "pinchOut" : "pinchIn" },
          { logLabel: t(zoomIn ? "live.opLabel.pinchOut" : "live.opLabel.pinchIn") },
        );
        break;
      }
      case "tapRef": {
        const refHit = this.lastElements.find((element) => element.ref === message.ref);
        const refChain = refHit ? locatorChainForElement(refHit, this.lastElements) : undefined;
        const tapRefStep: RecordedStep | undefined = refChain ? { action: "tap", ...refChain } : undefined;
        const tapRefLabel = refHit
          ? t("live.opLabel.tap", { target: describeElementShort(refHit) })
          : t("live.opLabel.tapPlain");
        void this.runAction({ cmd: "tap", ref: message.ref }, tapRefStep, { logLabel: tapRefLabel });
        break;
      }
      case "typeText": {
        if (message.text.trim().length === 0) {
          this.postActionError(t("live.typeTextEmpty"));
          break;
        }
        // 直前の tap でフォーカスした要素へ送る前提でロケータを付けずに記録する(ScenarioCodeGen が
        // type("text") を出す)。**入力先も同じ**で、ref は付けずフォーカス中の要素へ送る
        // (理由は LiveFromWebviewMessage の typeText の doc)。
        const typeStep: RecordedStep = { action: "type", text: message.text };
        const typedLabel = t("live.opLabel.type", { text: truncateOperationLabelText(message.text) });
        void this.runAction(
          { cmd: "type", text: message.text, ref: null },
          typeStep,
          { logLabel: typedLabel },
        );
        break;
      }
      case "home":
        void this.runAction({ cmd: "home" }, { action: "home" }, { logLabel: t("live.opLabel.home") });
        break;
      case "appSwitcher":
        void this.runAction(
          { cmd: "appSwitcher" },
          { action: "appSwitcher" },
          { logLabel: t("live.opLabel.appSwitcher") },
        );
        break;
      case "visibility":
        this.liveTabVisible = message.visible;
        // 表示なら供給元を確定(ストリーミング開始 or ポーリング再開)、非表示なら両方止める。
        this.updateLiveFrameSource();
        break;
      case "refreshAppProfiles":
        this.appActions.refreshAppProfiles();
        break;
      case "selectAppProfile":
        this.appActions.selectAppProfile(message.appProfile);
        break;
      case "installApp":
        void this.appActions.installApp(message.appProfile);
        break;
      case "launchApp":
        void this.appActions.launchApp(message.appProfile);
        break;
      case "startRecord":
        void this.appActions.startRecord(message.appProfile, message.autoInstall);
        break;
      case "stopRecord":
        this.appActions.stopRecord();
        break;
    }
  }
}
