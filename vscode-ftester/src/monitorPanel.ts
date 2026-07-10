// monitorPanel.ts
// デバイスモニターの WebviewPanel(コマンド `ftester.showDeviceMonitor`)。
//
// - `ftester api monitor --project <P> --interval <秒> --max-width <px> [--profile <run>]` を
//   自前で spawn し(--profile は ftester.profile 設定が非空のときのみ付与。指定時はそのプロファイルが
//   参照するデバイスのみに監視対象を絞り込む)、NdjsonParser(vscode 非依存)でパース →
//   monitorModel.ts(同じく vscode 非依存)で検証・変換した上で webview.postMessage する。
//   cli.ts の FtesterCli(直列実行キュー)は使わない — monitor は接続中ずっと動き続けるプロセスなので、
//   キューに載せると以後の実行・ステップ取得等の CLI 呼び出しが永久にブロックされてしまうため。
// - パネルはシングルトン(既に開いていれば reveal するだけ)。
// - パネル破棄・拡張 deactivate 時は子プロセスに SIGTERM を送り、2秒後もまだ生きていれば
//   SIGKILL する(cli.ts の cancelCurrent() と同じ方針)。
// - webview からの devicesUp/devicesDown も cli.ts のキューは使わず、ここで直接
//   短命プロセス(`ftester devices up`/`devices down`)を spawn する。ftester.profile が非空なら
//   --project/--profile を付与し、「デバイスを全て起動/終了」の対象をそのプロファイルが参照する
//   デバイスのみに限定する(空ならマシンプロファイルの全デバイス。要件1)。多重起動ガードのため
//   実行中は bootBusy:true を webview に送ってボタンを無効化させる。
// - プロファイル切り替え時の自動シャットダウン(要件2): restartMonitorIfScopeChanged() が
//   ftester.profile / ftester.project の変更でスコープが変わったことを検知すると、モニター再起動の
//   前に、直近の観測(lastKnownDevices)から「切り替え先プロファイルに定義されていない稼働中
//   デバイス」を割り出し(monitorModel.ts の devicesToShutdownOnScopeChange)、device-down ジョブを
//   キューに積む。定義されているデバイスは稼働中でもそのまま(自動起動はしない)。
// - ログレーン表示: RunEventBus(runHandler.ts の実行と同じインスタンスを extension.ts から
//   注入される)を購読し、`ftester api run` の生イベントを runLaneModel.ts(vscode/webview
//   非依存の純粋関数)でレーン用アクションに変換して webview へ転送する。デバイスタイルと
//   ログレーンは device id / worker id が同一規則なので、そのまま突合できる
//   (タイルの「実行中」バッジ・タイル選択によるレーン絞り込み)。

import * as fs from "node:fs";
import * as path from "node:path";
import { randomBytes } from "node:crypto";
import { type ChildProcessByStdio, spawn } from "node:child_process";
import type { Readable, Writable } from "node:stream";
import * as vscode from "vscode";
import {
  type FtesterConfig,
  listAppProfileNames,
  listRunProfileNames,
  readMachineDeviceNames,
  readRunProfileDeviceNames,
  resolveProjectName,
} from "./config";
import {
  buildRunProfileTemplate,
  createDeviceLifecycleQueueState,
  dequeueDeviceLifecycleJob,
  type DeviceLifecycleJob,
  type DeviceLifecycleQueueState,
  deviceLifecycleJobNeedsMonitorPause,
  deviceLifecycleQueueHead,
  deviceLifecycleStatusFor,
  type DeviceOpKind,
  devicesToShutdownOnScopeChange,
  enqueueDeviceLifecycleJob,
  hasDeviceLifecycleJobFor,
  isDeviceLifecycleQueueBusy,
  isDeviceOpEvent,
  isMonitorEvent,
  isMonitorFromWebviewMessage,
  type MonitorControlCommand,
  monitorControlLine,
  type MonitorDevice,
  toWebviewMessage,
  type MonitorToWebviewMessage,
  validateNewRunProfileName,
} from "./monitorModel";
import { NdjsonParser } from "./ndjson";
import type { RunBusMessage, RunEventBus } from "./runEventBus";
import {
  createRunLaneState,
  forceEndRunLaneState,
  MAX_LANE_LINES,
  OVERALL_LANE_ID,
  OVERALL_LANE_NAME,
  reduceLaneEvent,
  snapshotRunLaneState,
  type RunLaneToWebviewMessage,
} from "./runLaneModel";

const VIEW_TYPE = "ftesterMonitor";
const PANEL_TITLE = "ftester デバイスモニター";

/** stdin=ignore, stdout/stderr=pipe で spawn したプロセスの型(cli.ts の FtesterProcess と同じ形)。 */
type PipeProcess = ChildProcessByStdio<null, Readable, Readable>;

/**
 * monitor プロセス用: stdin もパイプで保持する。
 * `ftester api monitor` は stdin の EOF を終了指示として扱うため、stdio を "ignore"(=/dev/null)
 * にすると起動直後に EOF を検知して即終了してしまう(タイルが一切表示されない症状の原因)。
 */
type MonitorProcess = ChildProcessByStdio<Writable, Readable, Readable>;

export function registerMonitorPanel(
  context: vscode.ExtensionContext,
  workspaceRoot: string,
  getConfig: () => FtesterConfig,
  outputChannel: vscode.OutputChannel,
  eventBus: RunEventBus,
): void {
  const controller = new MonitorPanelController(workspaceRoot, getConfig, outputChannel, eventBus);
  context.subscriptions.push(
    controller,
    vscode.commands.registerCommand("ftester.showDeviceMonitor", () => controller.show()),
  );
}

class MonitorPanelController implements vscode.Disposable {
  private panel: vscode.WebviewPanel | undefined;
  private monitorProcess: MonitorProcess | undefined;
  /** stopMonitorProcess() 経由(dispose/再起動)による意図した終了かどうか。 */
  private stoppingMonitor = false;
  /**
   * 現在の monitor プロセスが実際に使っている監視スコープ("<project> <profile>" 形式。
   * profile が空なら "<project> ")。ftester.profile / ftester.project の変更を検知したときに、
   * 監視対象を変えるべきかどうか(=再起動が必要かどうか)を判定するために保持する。
   */
  private monitorScope: string | undefined;
  /**
   * restartMonitorProcess() の多重起動ガード。true の間は追加の再起動要求を無視する。
   * 連続したプロファイル変更や「モニター再起動」ボタン連打で stopMonitorProcess() →
   * startMonitorProcess() が重なり、monitor プロセスが二重起動するのを防ぐ。
   */
  private restartPending = false;
  /**
   * 直近の monitorDevices イベントで観測したデバイス一覧(state 込み)。モニタープロセスの再起動
   * (プロファイル切り替え含む)を跨いで保持し、リセットしない — restartMonitorIfScopeChanged() が
   * 「切り替え直前(旧スコープ)の最終観測」を元に、新スコープ外の稼働中デバイスを判定する
   * (devicesToShutdownOnScopeChange)ために必要なため。新しい monitor プロセスが起動して
   * 最初の monitorDevices を出すまでの間も、直前の観測を保持し続ける。
   */
  private lastKnownDevices: readonly MonitorDevice[] = [];
  /**
   * デバイスライフサイクル操作(「デバイスを全て起動/終了」とタイル個別の device-up/device-down)の
   * 直列キュー。ブリッジ供給・simctl・adb が競合しないよう、必ず1件ずつ実行する(実機ログ解析:
   * 並行実行がブリッジ供給の waitUntilReady 失敗・ゾンビブリッジ蓄積を誘発していた)。
   * 状態遷移(queued/running)の純粋ロジックは monitorModel.ts 側(vscode 非依存・単体テスト対象)。
   */
  private lifecycleQueue: DeviceLifecycleQueueState = createDeviceLifecycleQueueState();

  /** ログレーンの純粋な状態(実行を跨いで保持し、パネル再作成時のハイドレーションに使う)。 */
  private readonly laneState = createRunLaneState();
  /** 一度でも実行が始まった(=レーンセクションを表示すべき)かどうか。 */
  private laneSectionVisible = false;
  private readonly unsubscribeBus: () => void;
  /**
   * ftester.profile / ftester.project の変更を監視し、実行プロファイル選択ドロップダウンを
   * 最新化する(モニタープロセス自体は再起動不要。以後のテスト実行・デバッグ実行にのみ効く)。
   */
  private readonly configChangeSubscription: vscode.Disposable;
  /**
   * Projects 配下の各プロジェクトの profiles/runs ディレクトリにある .json ファイルの作成・削除を
   * 監視し、実行プロファイル選択ドロップダウンを最新化する(拡張内の追加/コピー/削除ボタン経由に
   * 限らず、エクスプローラーでの手動削除や他ツールでの追加もドロップダウンへ自動反映されるように
   * する目的)。Change は一覧にも選択名にも影響しないため購読しない(内容編集のたびに再描画する
   * 必要はない)。
   */
  private readonly profileFileWatcher: vscode.FileSystemWatcher;

  constructor(
    private readonly workspaceRoot: string,
    private readonly getConfig: () => FtesterConfig,
    private readonly outputChannel: vscode.OutputChannel,
    eventBus: RunEventBus,
  ) {
    this.unsubscribeBus = eventBus.subscribe((message) => this.handleBusMessage(message));
    this.configChangeSubscription = vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration("ftester.profile") || event.affectsConfiguration("ftester.project")) {
        this.postProfileInfo();
        this.restartMonitorIfScopeChanged();
      }
    });
    this.profileFileWatcher = vscode.workspace.createFileSystemWatcher(
      new vscode.RelativePattern(workspaceRoot, "Projects/*/profiles/runs/*.json"),
    );
    this.profileFileWatcher.onDidCreate(() => this.postProfileInfo());
    this.profileFileWatcher.onDidDelete(() => this.postProfileInfo());
  }

  /**
   * ftester.profile / ftester.project の変更で、モニターの監視対象デバイス(--profile が絞り込む
   * スコープ)が実際に変わった場合に限り、モニタープロセスを再起動して追随させる。パネル未表示、
   * またはプロジェクトが解決できない(既存のエラーバナー表示に任せる)場合は何もしない。
   * 再起動の前に、切り替え先プロファイルに定義されていない稼働中デバイスの自動シャットダウンを
   * キューに積む(要件2)。
   */
  private restartMonitorIfScopeChanged(): void {
    if (!this.panel) {
      return;
    }
    const config = this.getConfig();
    const resolution = resolveProjectName(this.workspaceRoot, config);
    if (resolution.kind !== "resolved") {
      return;
    }
    const scope = `${resolution.project} ${config.profile}`;
    if (scope === this.monitorScope) {
      return;
    }
    this.enqueueShutdownOutsideNewScope(resolution.project, config.profile);
    this.restartMonitorProcess();
  }

  /**
   * プロファイル切り替え時、切り替え先プロファイルに定義されていない稼働中デバイスを
   * シャットダウンする(定義されているデバイスは稼働中でもそのまま — 自動起動はしない方針と対)。
   * newProfile が空文字なら「プロファイルなし」= 全デバイスが対象なので何もしない。
   * newProfile が非空で readRunProfileDeviceNames が null を返した場合(プロファイルが読めない)も、
   * devicesToShutdownOnScopeChange(devices, null) は空配列を返す(=絞り込みなし扱い)ため、
   * 結果として自動的にシャットダウンをスキップできる(モニター再起動側の既存のエラー表示で
   * ユーザーが気付ける)。
   */
  private enqueueShutdownOutsideNewScope(project: string, newProfile: string): void {
    const newScopeNames =
      newProfile === "" ? null : readRunProfileDeviceNames(this.workspaceRoot, project, newProfile);
    const targets = devicesToShutdownOnScopeChange(this.lastKnownDevices, newScopeNames);
    if (targets.length === 0) {
      return;
    }
    this.outputChannel.appendLine(
      `[ftester] プロファイル切り替えに伴い監視対象外のデバイスを停止します: ${targets.join(", ")}`,
    );
    for (const name of targets) {
      this.enqueueLifecycleJob({ kind: "device", name, op: "down" });
    }
  }

  /** コマンド `ftester.showDeviceMonitor` のハンドラ。既に開いていれば reveal するだけ。 */
  show(): void {
    if (this.panel) {
      this.panel.reveal(vscode.ViewColumn.Beside);
      return;
    }

    const panel = vscode.window.createWebviewPanel(VIEW_TYPE, PANEL_TITLE, vscode.ViewColumn.Beside, {
      enableScripts: true,
      retainContextWhenHidden: true,
    });
    this.panel = panel;
    panel.webview.html = renderHtml();

    panel.webview.onDidReceiveMessage((message: unknown) => this.handleWebviewMessage(message));
    panel.onDidDispose(() => {
      this.panel = undefined;
      this.stopMonitorProcess();
    });

    this.startMonitorProcess();
    // 初期状態(laneHydrate/profileInfo等)の送信はここでは行わない。html設定直後の
    // postMessage は webview 側スクリプトの message リスナー登録前に届き、VS Code webview の
    // 既知のレースで握りつぶされる(タイル/フレームはモニタープロセスが継続的に流すので
    // 自然回復するが、一度きりの送信であるこれらは落ちたら復旧しない)。webview からの
    // "ready"(初期化完了通知)を受けてから sendInitialState() で送る(ready ハンドシェイク)。
  }

  dispose(): void {
    this.unsubscribeBus();
    this.configChangeSubscription.dispose();
    this.profileFileWatcher.dispose();
    this.stopMonitorProcess();
    const panel = this.panel;
    this.panel = undefined;
    panel?.dispose();
  }

  private post(message: MonitorToWebviewMessage | RunLaneToWebviewMessage): void {
    void this.panel?.webview.postMessage(message);
  }

  /** 新しく作成した webview に、既知のレーン状態(直近の実行の途中経過)を一括で流し込む。 */
  private hydrateLaneUi(): void {
    if (this.laneSectionVisible) {
      this.post({ type: "laneSectionVisible", visible: true });
    }
    const snapshot = snapshotRunLaneState(this.laneState);
    if (snapshot.lanes.length > 0 || Object.keys(snapshot.linesByLane).length > 0) {
      this.post({ type: "laneHydrate", snapshot });
    }
  }

  /**
   * 実行プロファイル選択ドロップダウンの内容(一覧+現在値)を webview へ送る。
   * 対象プロジェクトが解決できない場合は一覧を空にする(current はそのまま送る。設定に
   * 手書きされた値の表示自体は webview 側で保つ方針のため)。
   */
  private postProfileInfo(): void {
    const config = this.getConfig();
    const resolution = resolveProjectName(this.workspaceRoot, config);
    const profiles =
      resolution.kind === "resolved" ? listRunProfileNames(this.workspaceRoot, resolution.project) : [];
    this.post({ type: "profileInfo", profiles, current: config.profile });
  }

  /** RunEventBus からのメッセージ(runHandler.ts の実行と同じインスタンス)をレーン更新に反映する。 */
  private handleBusMessage(message: RunBusMessage): void {
    switch (message.type) {
      case "runStarted":
        this.laneSectionVisible = true;
        this.post({ type: "laneSectionVisible", visible: true });
        break;
      case "event":
        for (const action of reduceLaneEvent(this.laneState, message.event, Date.now())) {
          this.post({ type: "runEvent", action });
        }
        break;
      case "runEnded":
        // runFinished を受信しないまま終了した(異常終了/キャンセル)場合の後始末。
        // 正常終了(runFinished 済み)なら runningWorkers は既に空なので何も起きない。
        for (const action of forceEndRunLaneState(this.laneState)) {
          this.post({ type: "runEvent", action });
        }
        break;
    }
  }

  private handleWebviewMessage(message: unknown): void {
    if (!isMonitorFromWebviewMessage(message)) {
      return;
    }
    switch (message.type) {
      case "ready":
        this.sendInitialState();
        break;
      case "devicesUp":
        this.enqueueLifecycleJob({ kind: "bulk", op: "up" });
        break;
      case "devicesDown":
        this.enqueueLifecycleJob({ kind: "bulk", op: "down" });
        break;
      case "restartMonitor":
        this.restartMonitorProcess();
        break;
      case "deviceOp":
        this.enqueueLifecycleJob({ kind: "device", name: message.name, op: message.op });
        break;
      case "selectProfile":
        this.selectProfile(message.profile);
        break;
      case "profileAdd":
        void this.handleProfileAdd();
        break;
      case "profileCopy":
        void this.handleProfileCopy(message.profile);
        break;
      case "profileEdit":
        void this.handleProfileEdit(message.profile);
        break;
      case "profileDelete":
        void this.handleProfileDelete(message.profile);
        break;
    }
  }

  /**
   * webview のドロップダウン操作を ftester.profile 設定へ反映する
   * (extension.ts の ftester.selectProfile コマンドと同じログ形式で出力チャネルに記録する)。
   * 設定更新に成功すると onDidChangeConfiguration 経由で postProfileInfo() が呼ばれ、
   * webview のドロップダウンが最新化されるので、ここから直接 post する必要はない。
   */
  private selectProfile(profile: string): void {
    const NONE_LABEL = "(プロファイルなし)";
    const displayValue = profile === "" ? NONE_LABEL : profile;
    vscode.workspace
      .getConfiguration("ftester")
      .update("profile", profile, vscode.ConfigurationTarget.Workspace)
      .then(
        () => {
          this.outputChannel.appendLine(`[ftester] 実行プロファイルを「${displayValue}」に設定しました。`);
        },
        (error: unknown) => {
          this.outputChannel.appendLine(
            `[ftester] 実行プロファイルの設定に失敗しました(${displayValue}): ${String(error)}`,
          );
        },
      );
  }

  // ---- 実行プロファイルの追加/コピー/編集/削除(ツールバーのボタン) -------------------------
  // ドロップダウンの選択自体(selectProfile)の挙動は変えない。追加・コピー・削除の後、新しい/
  // コピー先のプロファイルを自動で選択状態にはしない — 選択するとモニター再起動+対象外デバイスの
  // 自動停止が走るため(restartMonitorIfScopeChanged)、ユーザーの明示操作(ドロップダウン選択)に
  // 任せる。

  /** Projects/<project>/profiles/runs ディレクトリの絶対パス。 */
  private runsDir(project: string): string {
    return path.join(this.workspaceRoot, "Projects", project, "profiles", "runs");
  }

  /**
   * 実行プロファイル操作(追加/コピー/編集/削除)共通の前提チェック。対象プロジェクトが
   * 解決できない場合は警告して undefined を返す(呼び出し側はここで処理を中断する)。
   */
  private resolveProjectOrWarn(): string | undefined {
    const resolution = resolveProjectName(this.workspaceRoot, this.getConfig());
    if (resolution.kind !== "resolved") {
      void vscode.window.showWarningMessage(
        "ftester: 対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
      );
      return undefined;
    }
    return resolution.project;
  }

  /** 実行プロファイル(<name>.json)をエディタで開く(プレビューではなく通常タブとして)。 */
  private async openRunProfileDocument(project: string, name: string): Promise<void> {
    const document = await vscode.workspace.openTextDocument(path.join(this.runsDir(project), `${name}.json`));
    await vscode.window.showTextDocument(document, { preview: false });
  }

  /** 「追加」ボタン: 新しいプロファイル名を入力させ、テンプレート内容で作成してエディタで開く。 */
  private async handleProfileAdd(): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const existing = listRunProfileNames(this.workspaceRoot, project);
    const input = await vscode.window.showInputBox({
      prompt: "新しい実行プロファイル名",
      validateInput: (value) => validateNewRunProfileName(value.trim(), existing),
    });
    if (input === undefined) {
      return; // キャンセル
    }
    const name = input.trim();
    const runsDir = this.runsDir(project);
    try {
      fs.mkdirSync(runsDir, { recursive: true });
      const template = buildRunProfileTemplate(
        listAppProfileNames(this.workspaceRoot, project),
        readMachineDeviceNames(this.workspaceRoot, project),
      );
      fs.writeFileSync(path.join(runsDir, `${name}.json`), template, "utf8");
      this.outputChannel.appendLine(`[ftester] 実行プロファイル「${name}」を追加しました。`);
      await this.openRunProfileDocument(project, name);
    } catch (error) {
      this.outputChannel.appendLine(`[ftester] 実行プロファイル「${name}」の追加に失敗しました: ${String(error)}`);
      void vscode.window.showErrorMessage(`ftester: 実行プロファイル「${name}」の追加に失敗しました。`);
    }
    this.postProfileInfo();
  }

  /** 「コピー」ボタン: コピー元の内容をそのまま新しい名前で複製してエディタで開く。 */
  private async handleProfileCopy(source: string): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const runsDir = this.runsDir(project);
    const sourcePath = path.join(runsDir, `${source}.json`);
    if (!fs.existsSync(sourcePath)) {
      void vscode.window.showWarningMessage(`ftester: 実行プロファイル「${source}」が見つかりません。`);
      this.postProfileInfo();
      return;
    }
    const existing = listRunProfileNames(this.workspaceRoot, project);
    const input = await vscode.window.showInputBox({
      prompt: `「${source}」のコピー先の実行プロファイル名`,
      value: `${source}-copy`,
      validateInput: (value) => validateNewRunProfileName(value.trim(), existing),
    });
    if (input === undefined) {
      return; // キャンセル
    }
    const name = input.trim();
    try {
      const content = fs.readFileSync(sourcePath, "utf8");
      fs.mkdirSync(runsDir, { recursive: true });
      fs.writeFileSync(path.join(runsDir, `${name}.json`), content, "utf8");
      this.outputChannel.appendLine(`[ftester] 実行プロファイル「${source}」を「${name}」としてコピーしました。`);
      await this.openRunProfileDocument(project, name);
    } catch (error) {
      this.outputChannel.appendLine(`[ftester] 実行プロファイル「${name}」のコピーに失敗しました: ${String(error)}`);
      void vscode.window.showErrorMessage(`ftester: 実行プロファイル「${name}」のコピーに失敗しました。`);
    }
    this.postProfileInfo();
  }

  /** 「編集」ボタン: 存在すればエディタで開く。存在しなければ警告し、一覧を再送する(古い可能性があるため)。 */
  private async handleProfileEdit(name: string): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    if (!fs.existsSync(path.join(this.runsDir(project), `${name}.json`))) {
      void vscode.window.showWarningMessage(`ftester: 実行プロファイル「${name}」が見つかりません。`);
      this.postProfileInfo();
      return;
    }
    try {
      await this.openRunProfileDocument(project, name);
    } catch (error) {
      this.outputChannel.appendLine(`[ftester] 実行プロファイル「${name}」を開けませんでした: ${String(error)}`);
      void vscode.window.showErrorMessage(`ftester: 実行プロファイル「${name}」を開けませんでした。`);
    }
  }

  /**
   * 「削除」ボタン: モーダル確認で「削除」が選ばれたときのみ削除する。削除したのが現在選択中の
   * プロファイル(ftester.profile)であれば selectProfile("") で「プロファイルなし」に戻す
   * (onDidChangeConfiguration 経由でモニターは全デバイス監視に切り替わる。新スコープが null に
   * なるだけで、devicesToShutdownOnScopeChange(devices, null) は常に空を返すため、この切り替え
   * 自体による自動シャットダウンは発生しない)。
   */
  private async handleProfileDelete(name: string): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const choice = await vscode.window.showWarningMessage(
      `実行プロファイル「${name}」を削除しますか?この操作は元に戻せません。`,
      { modal: true },
      "削除",
    );
    if (choice !== "削除") {
      return;
    }
    try {
      fs.unlinkSync(path.join(this.runsDir(project), `${name}.json`));
      this.outputChannel.appendLine(`[ftester] 実行プロファイル「${name}」を削除しました。`);
      if (this.getConfig().profile === name) {
        this.selectProfile("");
      }
    } catch (error) {
      this.outputChannel.appendLine(`[ftester] 実行プロファイル「${name}」の削除に失敗しました: ${String(error)}`);
      void vscode.window.showErrorMessage(`ftester: 実行プロファイル「${name}」の削除に失敗しました。`);
    }
    this.postProfileInfo();
  }

  private startMonitorProcess(): void {
    const config = this.getConfig();
    const resolution = resolveProjectName(this.workspaceRoot, config);
    if (resolution.kind !== "resolved") {
      this.monitorScope = undefined;
      this.post({
        type: "processDown",
        message:
          "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
      });
      return;
    }

    const interval = Math.max(0.5, config.monitorInterval);
    const args = [
      "api",
      "monitor",
      "--project",
      resolution.project,
      "--interval",
      String(interval),
      "--max-width",
      String(config.monitorMaxWidth),
    ];
    if (config.profile) {
      // 実行プロファイルが参照するデバイスのみに監視対象を絞り込む(空なら全デバイス。CLI 側の既定)。
      args.push("--profile", config.profile);
    }
    // 実際に使った監視スコープを記録する(restartMonitorIfScopeChanged() が変化検知に使う)。
    this.monitorScope = `${resolution.project} ${config.profile}`;

    let proc: MonitorProcess;
    try {
      proc = spawn(config.binaryPath, args, {
        cwd: this.workspaceRoot,
        shell: false,
        stdio: ["pipe", "pipe", "pipe"],
      });
    } catch (error) {
      this.outputChannel.appendLine(`[ftester] monitor プロセスの起動に失敗しました: ${String(error)}`);
      this.post({
        type: "processDown",
        message: `モニタープロセスの起動に失敗しました: ${String(error)}`,
      });
      return;
    }

    // stdin は EOF が終了指示なので、こちらからは何も書かず開いたまま保持する。
    // 相手が先に死んだ後の書き込み(end等)で EPIPE が飛んでも拡張を落とさない。
    proc.stdin.on("error", () => undefined);

    this.stoppingMonitor = false;
    this.monitorProcess = proc;

    const stdoutParser = new NdjsonParser(
      (value) => {
        if (!isMonitorEvent(value)) {
          this.outputChannel.appendLine(
            `[monitor] 未知の形式の行を無視しました: ${JSON.stringify(value)}`,
          );
          return;
        }
        if (value.kind === "monitorDevices") {
          // モニター再起動(プロファイル切り替え含む)を跨いで保持する(lastKnownDevices 宣言部参照)。
          this.lastKnownDevices = value.devices;
        }
        this.post(toWebviewMessage(value));
      },
      (line) => this.outputChannel.appendLine(`[monitor stdout] ${line}`),
    );
    const stderrParser = new NdjsonParser(
      (value) => this.outputChannel.appendLine(`[monitor stderr] ${JSON.stringify(value)}`),
      (line) => this.outputChannel.appendLine(`[monitor stderr] ${line}`),
    );

    proc.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => stderrParser.push(chunk));

    proc.on("error", (error) => {
      this.outputChannel.appendLine(`[ftester] monitor プロセスでエラーが発生しました: ${error.message}`);
    });

    proc.on("close", (exitCode, signal) => {
      stdoutParser.end();
      stderrParser.end();
      if (this.monitorProcess === proc) {
        this.monitorProcess = undefined;
      }
      // 意図した停止(dispose/再起動)かどうかはフラグだけで判定する。
      // stdin EOF 経由で終了した場合は signal が null になるため、signal では判定できない。
      const selfInitiated = this.stoppingMonitor;
      this.stoppingMonitor = false;
      if (!selfInitiated) {
        // exit 0 の予期しない終了(過去例: stdin の扱いの不備)も無言にせず必ず通知する。
        const hint =
          exitCode === 0
            ? "予期せず終了しました。「モニター再起動」で再開できます。"
            : "マシンプロファイル未設定の可能性があります。" +
              "「ftester machine set」の実行、または Projects/<project>/profiles/machines/ の内容を確認してください。";
        this.post({
          type: "processDown",
          message: `モニタープロセスが終了しました(exit code: ${String(exitCode)}, signal: ${String(signal)})。${hint}`,
        });
      }
    });
  }

  /** 実行中の monitor プロセスがあれば SIGTERM(2秒後 SIGKILL)で止める。無ければ何もしない。 */
  private stopMonitorProcess(): void {
    const proc = this.monitorProcess;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      return;
    }
    this.stoppingMonitor = true;
    // 行儀よく stdin EOF(=終了指示)を送ってから SIGTERM も送る(どちらでもクリーンに終了する)。
    proc.stdin.end();
    proc.kill("SIGTERM");
    setTimeout(() => {
      if (proc.exitCode === null && proc.signalCode === null) {
        proc.kill("SIGKILL");
      }
    }, 2000);
  }

  /**
   * monitor プロセスを止めてから起動し直す(「モニター再起動」ボタン、および
   * restartMonitorIfScopeChanged() による監視対象追随の両方から呼ばれる)。
   * 多重起動ガード: restartPending が true の間は追加の呼び出しを無視する(連続したプロファイル
   * 変更やボタン連打で stopMonitorProcess()/startMonitorProcess() が重なり、monitor プロセスが
   * 二重起動するのを防ぐ)。ガードで潰された再起動要求があっても実害はない — 実際に走る
   * startMonitorProcess() は呼び出し時点の getConfig() を読むので、最終的に反映されるのは
   * 常に最新の設定であるため。
   */
  private restartMonitorProcess(): void {
    if (this.restartPending) {
      return;
    }
    this.restartPending = true;
    const proc = this.monitorProcess;
    this.stopMonitorProcess();
    if (!proc) {
      this.restartPending = false;
      this.startMonitorProcess();
      return;
    }
    proc.once("close", () => {
      this.restartPending = false;
      this.startMonitorProcess();
    });
  }

  /**
   * デバイスライフサイクル操作(devicesUp/devicesDown/deviceOp)をキューに積む。
   * キューが空(何も実行中でない)ならそのまま実行を開始し、そうでなければ先に積まれている
   * ジョブの完了後に順番に実行される。同じデバイスへの deviceOp が既にキュー内(実行中または
   * 待機中)にある場合は連打とみなして無視する(グローバルボタン側は呼び出し元
   * (handleWebviewMessage 経由)では素通しだが、`isDeviceLifecycleQueueBusy` を見て webview 側の
   * ボタンが disabled になっているため、通常はここに届く前に抑止される)。
   */
  private enqueueLifecycleJob(job: DeviceLifecycleJob): void {
    if (job.kind === "device" && hasDeviceLifecycleJobFor(this.lifecycleQueue, job.name)) {
      return;
    }
    const wasBusy = isDeviceLifecycleQueueBusy(this.lifecycleQueue);
    this.lifecycleQueue = enqueueDeviceLifecycleJob(this.lifecycleQueue, job);
    if (!wasBusy) {
      // キューが空だったので、このジョブがそのまま先頭になり即実行される。
      this.post({ type: "bootBusy", busy: true });
      this.runLifecycleQueueHead();
    } else if (job.kind === "device") {
      // 何か実行中/待機中なので、このジョブは順番待ち(「待機中...」バッジ)になる。
      this.postDeviceLifecycleStatus(job.name);
    }
  }

  /** 指定デバイスの現在のキュー状態(実行中/待機中/なし)を deviceOpBusy として webview に送る。 */
  private postDeviceLifecycleStatus(name: string): void {
    const status = deviceLifecycleStatusFor(this.lifecycleQueue, name);
    this.post({ type: "deviceOpBusy", name, op: status?.op ?? null, status: status?.status ?? null });
  }

  /**
   * webview からの "ready"(初期化完了通知)を受けて、初期状態をまとめて送る(ready ハンドシェイク)。
   * ready は webview 再読込(タブのエディタグループ移動等)のたびに再送されうるので、ここで行う
   * 各処理が冪等であることが前提になる(hydrateLaneUi はスナップショットの一括送信、
   * profileInfo・以下のライフサイクル状態の再送はいずれも webview 側で上書き描画するだけなので
   * 何度呼んでも問題ない)。
   */
  private sendInitialState(): void {
    this.hydrateLaneUi();
    this.postProfileInfo();
    // デバイスライフサイクルキューの状態も再送する(webview 再読込がジョブ実行中に起きた場合に、
    // ボタンの無効状態・タイルのバッジを復元するため)。
    if (isDeviceLifecycleQueueBusy(this.lifecycleQueue)) {
      this.post({ type: "bootBusy", busy: true });
    }
    for (const job of this.lifecycleQueue.jobs) {
      if (job.kind === "device") {
        this.postDeviceLifecycleStatus(job.name);
      }
    }
  }

  /** キュー先頭のジョブを実行する(devices up/down の一括実行、または device-up/down の個別実行)。 */
  private runLifecycleQueueHead(): void {
    const job = deviceLifecycleQueueHead(this.lifecycleQueue);
    if (!job) {
      return;
    }
    // down 系ジョブ(bulk down / device-down)は実行直前にモニターへ pause を送り、片付け中の
    // デバイスへポーリングがスクショ取得に行って過渡的な警告を吐くのを防ぐ。up 系は起動進行を
    // タイルで見たいので pause しない。
    if (deviceLifecycleJobNeedsMonitorPause(job)) {
      this.writeMonitorControl("pause");
    }
    if (job.kind === "bulk") {
      this.executeBulkJob(job.op);
    } else {
      // 待機中だったジョブがここで先頭に回ってきた場合も含め、「実行中」バッジに更新する。
      this.postDeviceLifecycleStatus(job.name);
      this.executeDeviceOpJob(job.name, job.op);
    }
  }

  /**
   * 先頭ジョブの完了後始末。キューから取り除き、残りがあれば続けて次を実行し、
   * 空になったらグローバルボタンの busy 状態を解除する。
   */
  private finishLifecycleQueueHead(): void {
    const finished = deviceLifecycleQueueHead(this.lifecycleQueue);
    // pause した down 系ジョブは、成功・失敗を問わずここ(finally 相当)でモニターを resume する。
    if (finished && deviceLifecycleJobNeedsMonitorPause(finished)) {
      this.writeMonitorControl("resume");
    }
    this.lifecycleQueue = dequeueDeviceLifecycleJob(this.lifecycleQueue);
    if (finished?.kind === "device") {
      this.post({ type: "deviceOpBusy", name: finished.name, op: null, status: null });
    }
    if (isDeviceLifecycleQueueBusy(this.lifecycleQueue)) {
      this.runLifecycleQueueHead();
    } else {
      this.post({ type: "bootBusy", busy: false });
    }
  }

  /**
   * モニタープロセスの stdin に pause/resume の制御コマンドを書き込む(NDJSON 1行)。
   * モニターが未起動・終了済みのときは黙ってスキップする(エラーにしない)。書き込み自体が
   * 失敗した場合も握りつぶし、呼び出し元のジョブ実行は継続させる(stdin の "error" ハンドラは
   * startMonitorProcess() 側で既に no-op 登録済み)。
   */
  private writeMonitorControl(cmd: MonitorControlCommand): void {
    const proc = this.monitorProcess;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      return;
    }
    try {
      proc.stdin.write(monitorControlLine(cmd));
    } catch {
      // 書き込み失敗は無視する(ジョブ自体は続行する)。
    }
  }

  /**
   * `ftester devices up`/`devices down` を短命プロセスとして実行する(bulk ジョブの実処理)。
   * 選択中の実行プロファイル(ftester.profile)が非空なら --profile を付与し、対象を
   * そのプロファイルが参照するデバイスのみに限定する(要件1。空ならマシンプロファイルの全デバイス。
   * down は元々引数なしの全体停止だったが、--profile 対応により --project/--profile を渡せるようにした)。
   */
  private executeBulkJob(kind: "up" | "down"): void {
    const config = this.getConfig();
    const resolution = resolveProjectName(this.workspaceRoot, config);
    const args: string[] = ["devices", kind];
    if (resolution.kind === "resolved") {
      args.push("--project", resolution.project);
    }
    if (config.profile) {
      args.push("--profile", config.profile);
    }

    // spawn 失敗時(ENOENT 等)は 'error' の後に 'close' も発火することがある(Node の既知の挙動)。
    // finishLifecycleQueueHead() はキュー先頭を1回だけ取り除く前提なので、二重呼び出しを防ぐ。
    let jobFinished = false;
    const finishOnce = (): void => {
      if (jobFinished) {
        return;
      }
      jobFinished = true;
      this.finishLifecycleQueueHead();
    };

    let proc: PipeProcess;
    try {
      proc = spawn(config.binaryPath, args, {
        cwd: this.workspaceRoot,
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      this.outputChannel.appendLine(`[ftester] devices ${kind} の起動に失敗しました: ${String(error)}`);
      finishOnce();
      return;
    }

    const appendLines = (stream: "stdout" | "stderr", chunk: Buffer): void => {
      for (const rawLine of chunk.toString("utf8").split("\n")) {
        const line = rawLine.trim();
        if (line.length > 0) {
          this.outputChannel.appendLine(`[devices ${kind} ${stream}] ${line}`);
        }
      }
    };
    proc.stdout.on("data", (chunk: Buffer) => appendLines("stdout", chunk));
    proc.stderr.on("data", (chunk: Buffer) => appendLines("stderr", chunk));

    proc.on("error", (error) => {
      this.outputChannel.appendLine(
        `[ftester] devices ${kind} の実行でエラーが発生しました: ${error.message}`,
      );
      finishOnce();
    });
    proc.on("close", (exitCode) => {
      this.outputChannel.appendLine(
        `[ftester] devices ${kind} が終了しました(exit code: ${String(exitCode)})`,
      );
      finishOnce();
    });
  }

  /**
   * タイル右クリックメニューの起動/停止項目から、デバイス1台だけを
   * `ftester api device-up`/`device-down` で起動/停止する(device ジョブの実処理)。
   * finished イベントが ok:false のとき、およびプロセスが異常終了したとき(finished を出せずに
   * 落ちた場合を含む)は、webview のエラーバナーに加えて出力チャネルにも必ずログを残す
   * (バナーはパネルを閉じると消えるため、事後診断できるよう出力チャネル側にも記録する)。
   */
  private executeDeviceOpJob(name: string, op: DeviceOpKind): void {
    const config = this.getConfig();
    const resolution = resolveProjectName(this.workspaceRoot, config);
    const args: string[] = ["api", op === "up" ? "device-up" : "device-down", "--name", name];
    if (resolution.kind === "resolved") {
      args.push("--project", resolution.project);
    }

    let failureLogged = false;
    const logFailure = (message: string): void => {
      failureLogged = true;
      this.outputChannel.appendLine(`[ftester] device-${op}(${name})が失敗しました: ${message}`);
    };

    // spawn 失敗時(ENOENT 等)は 'error' の後に 'close' も発火することがある(Node の既知の挙動)。
    // finishLifecycleQueueHead() はキュー先頭を1回だけ取り除く前提なので、二重呼び出しを防ぐ。
    let jobFinished = false;
    const finishOnce = (): void => {
      if (jobFinished) {
        return;
      }
      jobFinished = true;
      this.finishLifecycleQueueHead();
    };

    let proc: PipeProcess;
    try {
      proc = spawn(config.binaryPath, args, {
        cwd: this.workspaceRoot,
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      logFailure(String(error));
      this.post({ type: "deviceOpFailed", name, message: String(error) });
      finishOnce();
      return;
    }

    const stdoutParser = new NdjsonParser(
      (value) => {
        if (!isDeviceOpEvent(value)) {
          this.outputChannel.appendLine(
            `[device-${op} ${name}] 未知の形式の行を無視しました: ${JSON.stringify(value)}`,
          );
          return;
        }
        if (value.kind === "log") {
          this.outputChannel.appendLine(`[device-${op} ${name}] ${value.message}`);
        } else if (!value.ok) {
          const message = value.error ?? `device-${op} に失敗しました。`;
          logFailure(message);
          this.post({ type: "deviceOpFailed", name, message });
        }
      },
      (line) => this.outputChannel.appendLine(`[device-${op} ${name} stdout] ${line}`),
    );
    const stderrParser = new NdjsonParser(
      (value) => this.outputChannel.appendLine(`[device-${op} ${name} stderr] ${JSON.stringify(value)}`),
      (line) => this.outputChannel.appendLine(`[device-${op} ${name} stderr] ${line}`),
    );

    proc.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => stderrParser.push(chunk));

    proc.on("error", (error) => {
      logFailure(error.message);
      this.post({ type: "deviceOpFailed", name, message: error.message });
      finishOnce();
    });
    proc.on("close", (exitCode) => {
      stdoutParser.end();
      stderrParser.end();
      this.outputChannel.appendLine(
        `[ftester] device-${op}(${name})が終了しました(exit code: ${String(exitCode)})`,
      );
      // finished(ok:false)を経由せずに落ちたケース(クラッシュ・kill 等)を捕捉する。
      // finished 経由で既にログ済みの場合は二重に出さない。
      if (!failureLogged && exitCode !== 0) {
        logFailure(`プロセスが exit code ${String(exitCode)} で終了しました`);
      }
      finishOnce();
    });
  }
}

function generateNonce(): string {
  return randomBytes(16).toString("hex");
}

/** webview の HTML をインライン生成する。外部リソースは一切読み込まない(CSP: default-src 'none')。 */
function renderHtml(): string {
  const nonce = generateNonce();
  const csp = [
    "default-src 'none'",
    "img-src data:",
    "style-src 'unsafe-inline'",
    `script-src 'nonce-${nonce}'`,
  ].join("; ");

  return `<!doctype html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="${csp}">
<title>${PANEL_TITLE}</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  html, body {
    height: 100%;
  }
  body {
    margin: 0;
    padding: 0;
    font-family: var(--vscode-font-family, sans-serif);
    font-size: var(--vscode-font-size, 13px);
    color: var(--vscode-foreground);
    background-color: var(--vscode-editor-background);
    /* パネル全体を上下2ペイン([タイル][スプリッター][出力])の flex column にし、
       body 自体はスクロールさせない(各ペイン内でスクロールする)。 */
    display: flex;
    flex-direction: column;
    height: 100vh;
    overflow: hidden;
  }
  .toolbar {
    flex: 0 0 auto;
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 8px;
    padding: 12px 12px 0 12px;
  }
  button {
    font-family: inherit;
    font-size: inherit;
    padding: 4px 10px;
    border: 1px solid var(--vscode-button-border, transparent);
    border-radius: 2px;
    background-color: var(--vscode-button-background);
    color: var(--vscode-button-foreground);
    cursor: pointer;
  }
  button:hover:not(:disabled) { background-color: var(--vscode-button-hoverBackground); }
  button:disabled { opacity: 0.5; cursor: default; }
  button.secondary {
    background-color: var(--vscode-button-secondaryBackground, transparent);
    color: var(--vscode-button-secondaryForeground, var(--vscode-foreground));
  }
  button.secondary:hover:not(:disabled) {
    background-color: var(--vscode-button-secondaryHoverBackground, var(--vscode-toolbar-hoverBackground));
  }
  .profile-label {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 12px;
    color: var(--vscode-descriptionForeground);
  }
  select {
    font-family: inherit;
    font-size: inherit;
    padding: 2px 6px;
    border-radius: 2px;
    background-color: var(--vscode-dropdown-background);
    color: var(--vscode-dropdown-foreground);
    border: 1px solid var(--vscode-dropdown-border);
  }
  select:disabled { opacity: 0.5; cursor: default; }
  .status {
    margin-left: auto;
    font-size: 12px;
    color: var(--vscode-descriptionForeground);
  }
  .banner {
    flex: 0 0 auto;
    display: none;
    padding: 8px 10px;
    margin: 12px 12px 0 12px;
    border-radius: 3px;
    background-color: var(--vscode-inputValidation-errorBackground, #5a1d1d);
    border: 1px solid var(--vscode-inputValidation-errorBorder, #be1100);
    color: var(--vscode-foreground);
    white-space: pre-wrap;
    font-size: 12px;
  }
  .banner.visible { display: block; }
  .tile-pane {
    /* 高さは JS(スプリッタードラッグ/初期化/復元)が inline style で設定する。
       最小値は JS 側でクランプする(要件: 上下それぞれ最小120px程度)。
       余白は子要素(.grid/.empty)の inset で付けるので、ここでは padding を持たない。 */
    flex: 0 0 auto;
    position: relative;
    overflow: hidden;
  }
  .grid {
    position: absolute;
    inset: 12px 12px 0 12px;
    display: flex;
    flex-wrap: nowrap;
    /* タイルが上ペインの高さいっぱいに伸びる(タイル高さフィットの土台)。 */
    align-items: stretch;
    gap: 8px;
    /* auto だとあふれた時しかバーが出ないため、常時表示の指定(scroll)にする */
    overflow-x: scroll;
    overflow-y: hidden;
    /* 横スクロールバー分の余白を確保する */
    padding-bottom: 10px;
  }
  /* 横スクロールバーを常時表示する(webview は Chromium なので、::-webkit-scrollbar を
     明示的にスタイルすることで、OS のオーバーレイ式スクロールバー(操作しないと自動的に
     フェードアウトする)ではなくクラシック表示になり、常に見える状態を保てる)。
     トラックにも薄い背景色を付け、あふれていない(つまみが無い)ときもバーの位置が見えるようにする。
     色は VSCode のスクロールバー用テーマ変数に合わせる。 */
  .grid::-webkit-scrollbar {
    height: 12px;
  }
  .grid::-webkit-scrollbar-track {
    /* つまみ(テーマ変数)より薄い固定の半透明グレー(ライト/ダーク両テーマで視認可) */
    background-color: rgba(121, 121, 121, 0.15);
    border-radius: 6px;
  }
  .grid::-webkit-scrollbar-thumb {
    background-color: var(--vscode-scrollbarSlider-background, rgba(121, 121, 121, 0.4));
    border-radius: 6px;
  }
  .grid::-webkit-scrollbar-thumb:hover {
    background-color: var(--vscode-scrollbarSlider-hoverBackground, rgba(100, 100, 100, 0.7));
  }
  .grid::-webkit-scrollbar-thumb:active {
    background-color: var(--vscode-scrollbarSlider-activeBackground, rgba(191, 191, 191, 0.4));
  }
  .tile {
    /* 固定幅は廃止。高さ = グリッド(上ペイン)の高さいっぱいに stretch し、
       幅はフレーム画像のアスペクト比(frame-wrap 側)に応じて内容が決める(fit-content)。 */
    flex: 0 0 auto;
    border: 1px solid var(--vscode-widget-border, var(--vscode-panel-border));
    border-radius: 4px;
    padding: 8px;
    background-color: var(--vscode-sideBar-background, var(--vscode-editor-background));
    display: flex;
    flex-direction: column;
    gap: 6px;
    /* クリックでレーン絞り込みの選択ができるが、カーソルは通常のまま(ユーザー指定) */
  }
  .tile.selected {
    border-color: var(--vscode-focusBorder, #007acc);
    border-width: 2px;
    padding: 7px;
  }
  /* ヘッダー・フッターのテキスト行はタイルの幅の決定に寄与させない
     (width:0 + min-width:100% で「フレーム画像が決めた幅」に従わせる)。
     これが無いとバッジ列や省略前のエラーテキストの固有幅でタイルが画像より
     広がり、左右に大きな余白ができて一列に並ぶ台数が減る(ユーザー報告)。 */
  .tile-header,
  .tile-footer {
    width: 0;
    min-width: 100%;
  }
  /* ヘッダーは固定高(スプリッター位置に関わらず文字が潰れない。ユーザー指定)。
     detail/updated/error も固定高で常時スロットを確保し、タイルの「画像以外の高さ」を
     定数化する(JS の relayoutTiles() の TILE_CHROME_HEIGHT と一致させること)。 */
  .tile-header {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-wrap: nowrap;
    overflow: hidden;
    flex: 0 0 20px;
    height: 20px;
  }
  /* デバイス名: プラットフォームバッジは廃止し、名前自体を同じスタイルで装飾する
     (iOS=水色/Android=Androidブランド緑、文字は白。ユーザー指定) */
  .tile-name {
    font-weight: 600;
    font-size: 12px;
    flex: 0 1 auto;
    min-width: 0;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    padding: 1px 8px;
    border-radius: 10px;
    color: #ffffff;
  }
  .tile-name-ios { background-color: #29b6f6; }
  .tile-name-android { background-color: #3ddc84; }
  .badge {
    font-size: 11px;
    padding: 1px 6px;
    border-radius: 10px;
    white-space: nowrap;
  }
  /* 状態表示は装飾なしのプレーンテキスト(ユーザー指定) */
  .tile-state {
    font-size: 11px;
    color: var(--vscode-descriptionForeground);
    white-space: nowrap;
  }
  .badge-running {
    background-color: var(--vscode-charts-blue, #0078d4);
    color: #ffffff;
    display: none;
    /* デバイス名が縮んでも右端に寄せる */
    margin-left: auto;
  }
  .frame-wrap {
    /* 高さフィット: 画像に使える高さ(--tile-image-h)は JS の relayoutTiles() が
       タイルの実測高さから算出して grid に設定する。幅は実フレームのアスペクト比
       (--tile-aspect、フレーム受信時にタイルへ設定。既定は 9/19.5)から計算する。
       これにより「タイル幅 = 画像幅 + 固定マージン(padding)」になり、
       画像の自然サイズ(960px配信で幅442px等)が固有幅としてタイルを
       押し広げることがない(横に並ぶ台数を最大化する。ユーザー指定)。 */
    flex: 0 0 auto;
    align-self: center;
    position: relative;
    height: var(--tile-image-h, 240px);
    width: calc(var(--tile-image-h, 240px) * var(--tile-aspect, 0.4615));
    background-color: var(--vscode-input-background, #1e1e1e);
    /* 画像の輪郭が分かるよう、細くて濃いめのグレーの実線(ユーザー指定) */
    border: 1px solid #757575;
    border-radius: 3px;
    display: flex;
    align-items: center;
    justify-content: center;
    overflow: hidden;
  }
  .frame-wrap img {
    /* 絶対配置にして、img の自然サイズが intrinsic 幅の計算に寄与しないようにする */
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: contain;
    display: block;
  }
  .frame-placeholder {
    color: var(--vscode-descriptionForeground);
    font-size: 12px;
    text-align: center;
    padding: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
  }
  /* プレースホルダー左側の状態アイコン(未起動=電源アイコン / 起動中=スピナー) */
  .placeholder-icon {
    width: 14px;
    height: 14px;
    flex: none;
    display: block;
  }
  .placeholder-icon.offline {
    color: var(--vscode-descriptionForeground);
  }
  .placeholder-icon.booting {
    box-sizing: border-box;
    border-radius: 50%;
    border: 2px solid rgba(226, 185, 61, 0.25);
    border-top-color: var(--vscode-charts-yellow, #e2b93d);
    animation: ft-placeholder-spin 1s linear infinite;
  }
  @keyframes ft-placeholder-spin {
    to { transform: rotate(360deg); }
  }
  /* タイル右クリックメニューでの起動/停止操作中バッジ(画像左上に重ねる)。
     ボタンを廃止した代わりの実行中表示(要件3)。frame-wrap は renderFrame() が
     textContent='' で中身を作り直すため、このバッジも毎回末尾に再アペンドされる
     (表示可否はこの要素の 'visible' クラスで独立して管理する)。 */
  .tile-op-badge {
    position: absolute;
    top: 4px;
    left: 4px;
    z-index: 1;
    font-size: 10px;
    padding: 1px 6px;
    border-radius: 10px;
    background-color: var(--vscode-badge-background, #6e6e6e);
    color: var(--vscode-badge-foreground, #ffffff);
    white-space: nowrap;
    display: none;
    pointer-events: none;
  }
  .tile-op-badge.visible { display: inline-block; }
  /* フッター(1行固定): [状態バッジ] [HH:MM:SS] [⚠エラー(あれば、省略表示)] */
  .tile-footer {
    display: flex;
    align-items: center;
    gap: 6px;
    flex: 0 0 18px;
    height: 18px;
    overflow: hidden;
  }
  .tile-updated {
    font-size: 11px;
    color: var(--vscode-descriptionForeground);
    white-space: nowrap;
    /* 時刻は右寄せ(ユーザー指定)。中間のエラー要素が空でも右端に寄るように */
    margin-left: auto;
  }
  .tile-error {
    flex: 1 1 auto;
    min-width: 0;
    font-size: 11px;
    color: var(--vscode-errorForeground, #f14c4c);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .empty {
    position: absolute;
    inset: 12px 12px 0 12px;
    display: none;
    align-items: center;
    justify-content: center;
    text-align: center;
    color: var(--vscode-descriptionForeground);
    font-size: 13px;
    padding: 12px;
  }
  /* 上下ペインの分割境界線。ドラッグで .tile-pane の高さを調整する(要件2)。
     常時視認できる色を付ける(ユーザー指定。ホバー/ドラッグでアクセント色に変化)。 */
  .splitter {
    flex: 0 0 6px;
    height: 6px;
    cursor: row-resize;
    background-color: var(--vscode-scrollbarSlider-background, rgba(121, 121, 121, 0.4));
    border-radius: 3px;
  }
  .splitter:hover,
  .splitter.dragging {
    background-color: var(--vscode-focusBorder, #007acc);
  }
  .output-pane {
    /* 出力ペイン(下側)= 常設エリア。残りの縦スペースを全て占有し、内部でスクロールする。 */
    flex: 1 1 auto;
    min-height: 0;
    display: flex;
    flex-direction: column;
    padding: 8px 12px 12px 12px;
    overflow: hidden;
  }
  .lanes-header {
    flex: 0 0 auto;
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 8px;
    font-size: 12px;
    color: var(--vscode-descriptionForeground);
  }
  .lanes-title {
    font-weight: 600;
    color: var(--vscode-foreground);
  }
  .lanes-placeholder {
    flex: 1 1 auto;
    display: flex;
    align-items: center;
    justify-content: center;
    text-align: center;
    color: var(--vscode-descriptionForeground);
    font-size: 13px;
    padding: 12px;
  }
  .lanes-grid {
    flex: 1 1 auto;
    min-height: 0;
    overflow-y: auto;
    display: grid;
    /* minmax(0, 1fr) = 列数が増えてもコンテナ幅に収めて等分する(全レーンが常に見える)。
       固定min幅(240px等)だと5台選択時に右端のレーンが画面外に見切れる */
    grid-template-columns: repeat(1, minmax(0, 1fr));
    gap: 10px;
    /* align-content は既定(stretch)のまま = 1行だけの行が出力ペインの下端まで伸びる
       (start にすると下半分が余白になる) */
  }
  .lane {
    display: flex;
    flex-direction: column;
    border: 1px solid var(--vscode-widget-border, var(--vscode-panel-border));
    border-radius: 4px;
    overflow: hidden;
    min-height: 160px;
    min-width: 0;
  }
  .lane-header {
    padding: 4px 8px;
    background-color: var(--vscode-sideBar-background, var(--vscode-editor-background));
    border-bottom: 1px solid var(--vscode-widget-border, var(--vscode-panel-border));
    white-space: nowrap;
    overflow: hidden;
  }
  /* レーン名はデバイスタイルのタイトルと同じ表現(色付きピル、.tile-name-ios/-android を共用) */
  .lane-name {
    display: inline-block;
    font-weight: 600;
    font-size: 12px;
    padding: 1px 8px;
    border-radius: 10px;
    color: #ffffff;
    max-width: 100%;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .lane-name-neutral {
    background-color: var(--vscode-badge-background, #6e6e6e);
    color: var(--vscode-badge-foreground, #ffffff);
  }
  .lane-body {
    flex: 1 1 auto;
    min-height: 0;
    overflow-y: auto;
    padding: 4px 8px;
    font-family: var(--vscode-editor-font-family, monospace);
    font-size: 11px;
    background-color: var(--vscode-editor-background);
  }
  .lane-line {
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    line-height: 1.4;
  }
  /* タイル右クリックの起動/停止メニュー(VS Code Webview は native メニューを使えないため
     div で自作する)。1タイルにつき1項目(起動 or 停止)のみ。マウス位置に表示し、
     JS(openDeviceOpMenu)が画面端で座標をクランプする。 */
  .device-op-menu {
    position: fixed;
    z-index: 1000;
    display: none;
    min-width: 140px;
    padding: 4px;
    border-radius: 4px;
    background-color: var(--vscode-menu-background, var(--vscode-dropdown-background, #252526));
    color: var(--vscode-menu-foreground, var(--vscode-foreground));
    border: 1px solid var(--vscode-menu-border, var(--vscode-widget-border, var(--vscode-panel-border)));
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.35);
  }
  .device-op-menu.visible { display: block; }
  .device-op-menu-item {
    display: block;
    width: 100%;
    text-align: left;
    font-family: inherit;
    font-size: inherit;
    padding: 5px 10px;
    border: none;
    border-radius: 3px;
    background: transparent;
    color: inherit;
    cursor: pointer;
  }
  .device-op-menu-item:hover:not(:disabled) {
    background-color: var(--vscode-menu-selectionBackground, var(--vscode-list-hoverBackground));
    color: var(--vscode-menu-selectionForeground, inherit);
  }
  .device-op-menu-item:disabled { opacity: 0.6; cursor: default; }
</style>
</head>
<body>
  <div id="toolbar" class="toolbar">
    <button id="btn-devices-up">デバイスを全て起動</button>
    <button id="btn-devices-down" class="secondary">全て終了</button>
    <button id="btn-restart" class="secondary">モニター再起動</button>
    <label class="profile-label">実行プロファイル
      <select id="profile-select" title="以後のテスト実行・デバッグ実行と、このモニターの監視対象デバイスに使う実行プロファイル(ftester.profile 設定)" disabled></select>
    </label>
    <button id="btn-profile-add" class="secondary" disabled>追加</button>
    <button id="btn-profile-copy" class="secondary" disabled>コピー</button>
    <button id="btn-profile-edit" class="secondary" disabled>編集</button>
    <button id="btn-profile-delete" class="secondary" disabled>削除</button>
    <span id="status" class="status">接続中...</span>
  </div>
  <div id="banner" class="banner"></div>

  <div id="tile-pane" class="tile-pane">
    <div id="grid" class="grid"></div>
    <div id="empty" class="empty">デバイス情報を待機しています(ポーリング形式のため反映まで数秒かかることがあります)...</div>
  </div>

  <div id="device-op-menu" class="device-op-menu" role="menu">
    <button id="device-op-menu-item" class="device-op-menu-item" type="button" role="menuitem"></button>
  </div>

  <div id="splitter" class="splitter" role="separator" aria-orientation="horizontal" aria-label="タイルと出力の分割境界線"></div>

  <div id="output-pane" class="output-pane">
    <div class="lanes-header">
      <span class="lanes-title">実行ログ</span>
      <span id="lanes-selection-status"></span>
      <span id="lanes-run-status"></span>
    </div>
    <div id="lanes-placeholder" class="lanes-placeholder">テストを実行するとデバイス毎の出力がここに表示されます</div>
    <div id="lanes-grid" class="lanes-grid" style="display: none;"></div>
  </div>

  <script nonce="${nonce}">
  (function () {
    const vscode = acquireVsCodeApi();

    const OVERALL_LANE_ID = ${JSON.stringify(OVERALL_LANE_ID)};
    const OVERALL_LANE_NAME = ${JSON.stringify(OVERALL_LANE_NAME)};
    const MAX_LANE_LINES = ${JSON.stringify(MAX_LANE_LINES)};

    const toolbar = document.getElementById('toolbar');
    const grid = document.getElementById('grid');
    const emptyMessage = document.getElementById('empty');
    const banner = document.getElementById('banner');
    const statusEl = document.getElementById('status');
    const btnUp = document.getElementById('btn-devices-up');
    const btnDown = document.getElementById('btn-devices-down');
    const btnRestart = document.getElementById('btn-restart');
    const profileSelect = document.getElementById('profile-select');
    const btnProfileAdd = document.getElementById('btn-profile-add');
    const btnProfileCopy = document.getElementById('btn-profile-copy');
    const btnProfileEdit = document.getElementById('btn-profile-edit');
    const btnProfileDelete = document.getElementById('btn-profile-delete');

    const tilePane = document.getElementById('tile-pane');
    const splitter = document.getElementById('splitter');
    const lanesPlaceholder = document.getElementById('lanes-placeholder');
    const lanesGrid = document.getElementById('lanes-grid');
    const lanesSelectionStatus = document.getElementById('lanes-selection-status');
    const lanesRunStatus = document.getElementById('lanes-run-status');

    const deviceOpMenu = document.getElementById('device-op-menu');
    const deviceOpMenuItemBtn = document.getElementById('device-op-menu-item');

    const STATE_LABEL = {
      connected: '接続済み',
      booted: '起動中',
      offline: '未起動',
    };

    // 複製元: src/monitorModel.ts の deviceOpMenuItem。webview は CSP により import 不可のため
    // 複製する(healReviewPanel.ts が healModel.ts の一部ロジックを複製しているのと同じ方針)。
    // タイル右クリックメニューの項目ラベル・実行する操作と、実行中/待機中バッジの表示にも共用する。
    // busy は { op, status } の形('queued'=順番待ち／'running'=実行中)。無ければ undefined。
    function deviceOpMenuItem(state, busy) {
      if (busy && busy.status === 'queued') { return { label: '待機中...', op: busy.op, disabled: true }; }
      if (busy && busy.op === 'up') { return { label: '起動中...', op: 'up', disabled: true }; }
      if (busy && busy.op === 'down') { return { label: '停止中...', op: 'down', disabled: true }; }
      return state === 'offline'
        ? { label: '起動', op: 'up', disabled: false }
        : { label: '停止', op: 'down', disabled: false };
    }

    // device id -> タイルの DOM 要素・最新フレーム(1枚のみ保持。履歴は溜めない)
    const tiles = new Map();
    // レーン id(worker id、または OVERALL_LANE_ID) -> DOM 要素・自動スクロール状態
    const lanes = new Map();
    // タイルクリックで選択された device id 集合(空 = 全ワーカー表示)
    const selectedDeviceIds = new Set();

    function formatTime(date) {
      const pad = (n) => String(n).padStart(2, '0');
      return pad(date.getHours()) + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds());
    }

    // ---- 上下ペインのスプリッター ---------------------------------------------
    // タイルペイン(上)の高さを JS 側の状態として保持し、setState/getState にも保存して
    // パネル再表示時に復元する。出力ペイン(下)は flex の残りスペースを自動的に占有するので、
    // 高さを個別に管理する必要はない。

    const MIN_PANE_HEIGHT = 120;
    const persistedState = vscode.getState() || {};
    let tilePaneHeight =
      typeof persistedState.tilePaneHeight === 'number' && persistedState.tilePaneHeight > 0
        ? persistedState.tilePaneHeight
        : Math.round(window.innerHeight * 0.45);

    // タイルペイン+出力ペインに配分できる合計の高さ(ツールバー・バナー・スプリッター分を除く)。
    function availableSplitHeight() {
      const bannerHeight = banner.classList.contains('visible') ? banner.offsetHeight : 0;
      return document.body.clientHeight - toolbar.offsetHeight - bannerHeight - splitter.offsetHeight;
    }

    // 上下それぞれ最小 MIN_PANE_HEIGHT を確保するようにクランプする。
    function clampTilePaneHeight(height) {
      const available = availableSplitHeight();
      const maxHeight = Math.max(MIN_PANE_HEIGHT, available - MIN_PANE_HEIGHT);
      return Math.min(Math.max(height, MIN_PANE_HEIGHT), maxHeight);
    }

    function applyTilePaneHeight(height) {
      tilePaneHeight = clampTilePaneHeight(height);
      tilePane.style.height = tilePaneHeight + 'px';
      relayoutTiles();
    }

    function persistTilePaneHeight() {
      vscode.setState(Object.assign({}, vscode.getState(), { tilePaneHeight }));
    }

    applyTilePaneHeight(tilePaneHeight);
    // ウィンドウリサイズ/バナー表示切替でも上下の最小高さを維持する。
    window.addEventListener('resize', () => applyTilePaneHeight(tilePaneHeight));

    let splitterPointerId = null;
    let splitterStartY = 0;
    let splitterStartHeight = 0;

    splitter.addEventListener('pointerdown', (event) => {
      if (event.button !== 0) {
        return;
      }
      splitterPointerId = event.pointerId;
      splitterStartY = event.clientY;
      splitterStartHeight = tilePaneHeight;
      splitter.setPointerCapture(event.pointerId);
      splitter.classList.add('dragging');
      event.preventDefault();
    });
    splitter.addEventListener('pointermove', (event) => {
      if (splitterPointerId !== event.pointerId) {
        return;
      }
      applyTilePaneHeight(splitterStartHeight + (event.clientY - splitterStartY));
    });
    const endSplitterDrag = (event) => {
      if (splitterPointerId !== event.pointerId) {
        return;
      }
      splitterPointerId = null;
      splitter.classList.remove('dragging');
      splitter.releasePointerCapture(event.pointerId);
      persistTilePaneHeight();
    };
    splitter.addEventListener('pointerup', endSplitterDrag);
    splitter.addEventListener('pointercancel', endSplitterDrag);

    // ---- デバイスタイル -----------------------------------------------------

    // タイル内の「画像以外」の高さの合計(px)。CSS の固定高と一致させること:
    // padding 上下 8+8 + header 20 + footer 18 + gap 6×2 = 66
    const TILE_CHROME_HEIGHT = 66;

    // タイルの実測高さ(グリッドの stretch 結果)から画像に使える高さを算出し、
    // CSS 変数 --tile-image-h として grid に設定する(タイル幅はこの高さ×アスペクト比で決まる)。
    // スプリッター移動・リサイズ・タイル生成のたびに呼ぶ。
    function relayoutTiles() {
      const probe = grid.querySelector('.tile');
      if (!probe) {
        return;
      }
      const imageHeight = Math.max(60, probe.clientHeight - TILE_CHROME_HEIGHT);
      grid.style.setProperty('--tile-image-h', imageHeight + 'px');
    }

    function createTile(device) {
      const tile = document.createElement('div');
      tile.className = 'tile';
      // ボタン廃止(要件1)によりヒントが無くなるため、ツールチップで操作方法を示す
      // (macOS GUI 版のタイルの .help() と同じ趣旨)。
      tile.title = 'クリックで選択 / 右クリックで起動・停止';
      tile.addEventListener('click', () => toggleDeviceSelection(device.id));
      tile.addEventListener('contextmenu', (event) => {
        // 既定の(OS/ブラウザの)コンテキストメニューを抑止し、タイル本体のクリック
        // (レーン絞り込みの選択トグル)にも波及させない。
        event.preventDefault();
        event.stopPropagation();
        openDeviceOpMenu(entry, event.clientX, event.clientY);
      });

      // ヘッダー: 左からプラットフォーム色で装飾したデバイス名、右端に「実行中」
      // (個別起動/停止は右クリックメニューに移動した。ボタンが無くなった分、名前表示が
      // フル幅を使える)
      const header = document.createElement('div');
      header.className = 'tile-header';
      const name = document.createElement('span');
      name.className = 'tile-name';
      const runningBadge = document.createElement('span');
      runningBadge.className = 'badge badge-running';
      runningBadge.textContent = '実行中';
      header.append(name, runningBadge);

      const frameWrap = document.createElement('div');
      frameWrap.className = 'frame-wrap';
      const img = document.createElement('img');
      const placeholder = document.createElement('div');
      placeholder.className = 'frame-placeholder';
      // 起動/停止操作中バッジ(画像左上に重ねる。要件3)。renderFrame() が
      // frame-wrap の中身を作り直すたびに末尾へ再アペンドする。
      const opBadge = document.createElement('span');
      opBadge.className = 'tile-op-badge';

      // フッター: [状態テキスト] [⚠エラー(あれば、中間で省略)] [HH:MM:SS(右寄せ)]
      const footer = document.createElement('div');
      footer.className = 'tile-footer';
      const stateBadge = document.createElement('span');
      stateBadge.className = 'tile-state';
      const updated = document.createElement('span');
      updated.className = 'tile-updated';
      const error = document.createElement('span');
      error.className = 'tile-error';
      footer.append(stateBadge, error, updated);

      tile.append(header, frameWrap, footer);
      grid.appendChild(tile);

      const entry = {
        device,
        tile,
        nameEl: name,
        // そのデバイスの直列キュー上の状態({ op: 'up'|'down', status: 'queued'|'running' })。
        // キューに入っていなければ undefined。
        opBusy: undefined,
        opBadgeEl: opBadge,
        stateBadgeEl: stateBadge,
        runningBadgeEl: runningBadge,
        frameWrapEl: frameWrap,
        imgEl: img,
        placeholderEl: placeholder,
        updatedEl: updated,
        errorEl: error,
        frameSrc: null,
        lastUpdated: null,
      };
      tiles.set(device.id, entry);
      return entry;
    }

    function renderFrame(entry) {
      entry.frameWrapEl.textContent = '';
      if (entry.device.state !== 'offline' && entry.frameSrc) {
        entry.imgEl.src = entry.frameSrc;
        entry.imgEl.alt = entry.device.name;
        entry.frameWrapEl.appendChild(entry.imgEl);
      } else {
        // フレーム未受信のプレースホルダーはデバイス状態で出し分ける
        // (offline=未起動+電源アイコン / それ以外(booted・接続直後でフレーム未着)=起動中+スピナー)
        const offline = entry.device.state === 'offline';
        entry.placeholderEl.textContent = '';
        const icon = document.createElement('span');
        if (offline) {
          icon.className = 'placeholder-icon offline';
          icon.innerHTML = '<svg width="14" height="14" viewBox="0 0 16 16" fill="none"'
            + ' stroke="currentColor" stroke-width="1.6" stroke-linecap="round">'
            + '<path d="M8 1.8v5.4"/><path d="M4.4 3.9a5.4 5.4 0 1 0 7.2 0"/></svg>';
        } else {
          icon.className = 'placeholder-icon booting';
        }
        const labelSpan = document.createElement('span');
        labelSpan.textContent = offline ? '未起動' : '起動中';
        entry.placeholderEl.append(icon, labelSpan);
        entry.frameWrapEl.appendChild(entry.placeholderEl);
      }
      entry.frameWrapEl.appendChild(entry.opBadgeEl);
    }

    function renderMeta(entry) {
      entry.nameEl.textContent = entry.device.name;
      entry.nameEl.className = 'tile-name tile-name-' + entry.device.platform;
      entry.nameEl.title = entry.device.name + ' (' + entry.device.platform + ')';
      // フッター左下の表示ルール:
      //   connected(フレーム表示中) → 「接続済み」
      //   booted(iOSブリッジ未接続 / Androidブート完了待ち) → 「接続中」
      //   それ以外(未起動・フレーム未着) → 空(要素は固定高レイアウトのため残す)
      let footerText = '';
      if (entry.device.state === 'connected' && entry.frameSrc) {
        footerText = STATE_LABEL.connected;
      } else if (entry.device.state === 'booted') {
        footerText = '接続中';
      }
      entry.stateBadgeEl.textContent = footerText;
      entry.updatedEl.textContent = entry.lastUpdated ? formatTime(entry.lastUpdated) : '';
      renderOpBadge(entry);
      // 右クリックメニューがこのタイルに対して開いていれば、内容(ラベル/disabled)も
      // 最新の state/opBusy で更新する。
      if (deviceOpMenuEntry === entry) {
        renderDeviceOpMenuItem();
      }
    }

    // 起動/停止操作中バッジの表示可否・文言を、デバイスの現在状態(state)とそのデバイスで
    // 実行中の操作(opBusy)から再計算する。devices サイクル毎(renderMeta 経由)と
    // deviceOpBusy 受信時の両方から呼ぶ(モニターの既存ポーリングで状態変化が反映される)。
    function renderOpBadge(entry) {
      const item = deviceOpMenuItem(entry.device.state, entry.opBusy);
      entry.opBadgeEl.textContent = item.label;
      entry.opBadgeEl.classList.toggle('visible', item.disabled);
    }

    // ---- タイル右クリックメニュー ---------------------------------------------

    // 現在メニューを開いている対象のタイル entry(未オープンなら null)。
    let deviceOpMenuEntry = null;

    function renderDeviceOpMenuItem() {
      if (!deviceOpMenuEntry) {
        return;
      }
      const item = deviceOpMenuItem(deviceOpMenuEntry.device.state, deviceOpMenuEntry.opBusy);
      deviceOpMenuItemBtn.textContent = item.label;
      deviceOpMenuItemBtn.disabled = item.disabled;
      deviceOpMenuItemBtn.dataset.op = item.op;
    }

    function closeDeviceOpMenu() {
      if (!deviceOpMenuEntry) {
        return;
      }
      deviceOpMenuEntry = null;
      deviceOpMenu.classList.remove('visible');
    }

    // マウス位置にメニューを開く。画面端でははみ出さないよう、実測サイズで座標をクランプする。
    function openDeviceOpMenu(entry, clientX, clientY) {
      deviceOpMenuEntry = entry;
      renderDeviceOpMenuItem();
      deviceOpMenu.classList.add('visible');
      const rect = deviceOpMenu.getBoundingClientRect();
      const maxX = Math.max(4, window.innerWidth - rect.width - 4);
      const maxY = Math.max(4, window.innerHeight - rect.height - 4);
      deviceOpMenu.style.left = Math.min(Math.max(clientX, 4), maxX) + 'px';
      deviceOpMenu.style.top = Math.min(Math.max(clientY, 4), maxY) + 'px';
    }

    deviceOpMenuItemBtn.addEventListener('click', (event) => {
      event.stopPropagation();
      if (!deviceOpMenuEntry || deviceOpMenuItemBtn.disabled) {
        return;
      }
      vscode.postMessage({
        type: 'deviceOp',
        name: deviceOpMenuEntry.device.name,
        op: deviceOpMenuItemBtn.dataset.op,
      });
      closeDeviceOpMenu();
    });

    // メニュー外クリック・Esc・スクロールで閉じる(要件2)。
    document.addEventListener('click', (event) => {
      if (deviceOpMenuEntry && !deviceOpMenu.contains(event.target)) {
        closeDeviceOpMenu();
      }
    });
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') {
        closeDeviceOpMenu();
      }
    });
    // capture:true で登録することで、スクロール可能な子要素(grid の横スクロール・
    // lane-body 等)で発生した(バブリングしない)scroll イベントも document 側で拾える。
    document.addEventListener('scroll', () => closeDeviceOpMenu(), true);
    window.addEventListener('resize', () => closeDeviceOpMenu());
    // タイル上での contextmenu は stopPropagation 済みなのでここには来ない。
    // タイル外(空きエリア等)で右クリックし、既定のコンテキストメニューが別途開く場合に
    // こちらのメニューを残さないようにする。
    document.addEventListener('contextmenu', () => closeDeviceOpMenu());

    // デバイス名から対応するタイルを探す(deviceOp は --name(論理名)だけを host に渡すため、
    // host からの deviceOpBusy/deviceOpFailed 応答も name で返ってくる)。
    function findTileByName(name) {
      for (const entry of tiles.values()) {
        if (entry.device.name === name) {
          return entry;
        }
      }
      return undefined;
    }

    function touch(entry) {
      entry.lastUpdated = new Date();
      renderMeta(entry);
    }

    // monitorError はタイルに表示したままにせず、そのデバイスの monitorFrame か state 更新
    // (devices サイクル)を受信した時点で消す(過渡的なエラーが赤字のまま残り続けないように)。
    function setTileError(entry, message) {
      entry.errorEl.textContent = '⚠ ' + message;
      entry.errorEl.title = message;
    }

    function clearTileError(entry) {
      entry.errorEl.textContent = '';
      entry.errorEl.removeAttribute('title');
    }

    function applyDevices(devices) {
      const seen = new Set();
      for (const device of devices) {
        seen.add(device.id);
        let entry = tiles.get(device.id);
        if (!entry) {
          entry = createTile(device);
          entry.runningBadgeEl.style.display = runningWorkers.has(device.id) ? 'inline-block' : 'none';
        } else {
          entry.device = device;
        }
        touch(entry);
        renderFrame(entry);
        clearTileError(entry);
      }
      for (const [id, entry] of tiles) {
        if (!seen.has(id)) {
          if (deviceOpMenuEntry === entry) {
            closeDeviceOpMenu();
          }
          entry.tile.remove();
          tiles.delete(id);
          selectedDeviceIds.delete(id);
        }
      }
      emptyMessage.style.display = tiles.size === 0 ? 'flex' : 'none';
      relayoutTiles();
      syncLanesToDevices(devices);
      updateLaneVisibility();
    }

    function applyFrame(message) {
      const entry = tiles.get(message.device);
      if (!entry) {
        return; // devices サイクルより先に届いた場合は無視する(次の devices で改めて反映される)
      }
      entry.frameSrc = 'data:image/jpeg;base64,' + message.jpegBase64;
      // 実フレームのアスペクト比でタイル幅を決める(縦横比の異なるデバイスが混在しても
      // それぞれの画像幅ちょうどに締まる)
      if (message.width > 0 && message.height > 0) {
        entry.tile.style.setProperty('--tile-aspect', (message.width / message.height).toFixed(4));
      }
      touch(entry);
      renderFrame(entry);
      clearTileError(entry);
    }

    function applyDeviceError(message) {
      const entry = message.device ? tiles.get(message.device) : undefined;
      if (entry) {
        setTileError(entry, message.message);
        return;
      }
      showBanner(message.message);
    }

    function showBanner(text) {
      banner.textContent = text;
      banner.classList.add('visible');
    }
    function hideBanner() {
      banner.textContent = '';
      banner.classList.remove('visible');
    }

    function setBusy(busy) {
      btnUp.disabled = busy;
      btnDown.disabled = busy;
      statusEl.textContent = busy ? '操作を実行中...' : 'モニタリング中';
    }

    // ---- 実行プロファイル選択 ---------------------------------------------------

    const PROFILE_NONE_LABEL = '(プロファイルなし)';

    // profileInfo 受信のたびに select の中身を作り直す(現在値が profiles に無い場合も、
    // 設定に手書きされた未知の名前として option を補い選択状態を保つ)。
    function applyProfileInfo(message) {
      const profiles = Array.isArray(message.profiles) ? message.profiles : [];
      const current = typeof message.current === 'string' ? message.current : '';
      profileSelect.textContent = '';

      const noneOption = document.createElement('option');
      noneOption.value = '';
      noneOption.textContent = PROFILE_NONE_LABEL;
      profileSelect.appendChild(noneOption);

      let matched = current === '';
      for (const name of profiles) {
        const option = document.createElement('option');
        option.value = name;
        option.textContent = name;
        profileSelect.appendChild(option);
        if (name === current) {
          matched = true;
        }
      }
      if (!matched) {
        const unknownOption = document.createElement('option');
        unknownOption.value = current;
        unknownOption.textContent = current;
        profileSelect.appendChild(unknownOption);
      }
      profileSelect.value = current;
      profileSelect.disabled = false;
      updateProfileButtonsEnabled();
    }

    // 追加はドロップダウンが有効な間はいつでも押せる。コピー/編集/削除は「プロファイルなし」
    // (select.value === '')の間は対象が無いので無効化する。初期状態(profileInfo未着)は
    // select 自体が disabled なので4つとも無効。
    function updateProfileButtonsEnabled() {
      btnProfileAdd.disabled = profileSelect.disabled;
      const hasSelection = !profileSelect.disabled && profileSelect.value !== '';
      btnProfileCopy.disabled = !hasSelection;
      btnProfileEdit.disabled = !hasSelection;
      btnProfileDelete.disabled = !hasSelection;
    }

    profileSelect.addEventListener('change', () => {
      vscode.postMessage({ type: 'selectProfile', profile: profileSelect.value });
      updateProfileButtonsEnabled();
    });

    btnProfileAdd.addEventListener('click', () => vscode.postMessage({ type: 'profileAdd' }));
    btnProfileCopy.addEventListener('click', () =>
      vscode.postMessage({ type: 'profileCopy', profile: profileSelect.value }),
    );
    btnProfileEdit.addEventListener('click', () =>
      vscode.postMessage({ type: 'profileEdit', profile: profileSelect.value }),
    );
    btnProfileDelete.addEventListener('click', () =>
      vscode.postMessage({ type: 'profileDelete', profile: profileSelect.value }),
    );

    function toggleDeviceSelection(id) {
      if (selectedDeviceIds.has(id)) {
        selectedDeviceIds.delete(id);
      } else {
        selectedDeviceIds.add(id);
      }
      updateSelectionUi();
    }

    function updateSelectionUi() {
      for (const [id, entry] of tiles) {
        entry.tile.classList.toggle('selected', selectedDeviceIds.has(id));
      }
      updateLaneVisibility();
    }

    // 空きエリア(タイルの外、横スクロールコンテナ内の余白を含む)をクリックしたら選択を全解除する。
    grid.addEventListener('click', (event) => {
      if (event.target === grid && selectedDeviceIds.size > 0) {
        selectedDeviceIds.clear();
        updateSelectionUi();
      }
    });

    // ホイール操作を横スクロールに変換する(下回転→右スクロール、上回転→左スクロール)。
    // トラックパッドの横方向(deltaX)はそのまま加算し、縦回転(deltaY)も横スクロールに合算する。
    // ページ側の縦スクロールに奪われないよう preventDefault() するため passive:false で登録する。
    grid.addEventListener(
      'wheel',
      (event) => {
        grid.scrollLeft += event.deltaX + event.deltaY;
        event.preventDefault();
      },
      { passive: false },
    );

    // 中ボタン(ホイールボタン)ドラッグでパンスクロール(GUI版のステップ表と同じ操作感)。
    // 「掴んで動かす」向き = ポインタを右へ動かすとコンテンツが右へ付いてくる(scrollLeft は減る)。
    // Pointer Events + setPointerCapture でグリッド外へ出てもドラッグを継続する。
    let panPointerId = null;
    let panLastX = 0;
    grid.addEventListener('pointerdown', (event) => {
      if (event.button !== 1) {
        return;
      }
      panPointerId = event.pointerId;
      panLastX = event.clientX;
      grid.setPointerCapture(event.pointerId);
      grid.style.cursor = 'grabbing';
      event.preventDefault();
    });
    grid.addEventListener('pointermove', (event) => {
      if (panPointerId !== event.pointerId) {
        return;
      }
      grid.scrollLeft -= event.clientX - panLastX;
      panLastX = event.clientX;
    });
    const endPan = (event) => {
      if (panPointerId !== event.pointerId) {
        return;
      }
      panPointerId = null;
      grid.style.cursor = '';
      grid.releasePointerCapture(event.pointerId);
    };
    grid.addEventListener('pointerup', endPan);
    grid.addEventListener('pointercancel', endPan);
    // Chromium の中クリック既定動作(オートスクロール等)を抑止する
    grid.addEventListener('auxclick', (event) => {
      if (event.button === 1) {
        event.preventDefault();
      }
    });

    // ---- ログレーン -----------------------------------------------------------

    // worker id(またはタイルが存在しない全体レーン)ごとの「実行中」状態。
    const runningWorkers = new Set();

    function setTileRunning(id, running) {
      if (running) {
        runningWorkers.add(id);
      } else {
        runningWorkers.delete(id);
      }
      const entry = tiles.get(id);
      if (entry) {
        entry.runningBadgeEl.style.display = running ? 'inline-block' : 'none';
      }
    }

    // レーン名はデバイスタイルのタイトルと同じテキスト・同じ装飾(色付きピル)にする。
    // platform 不明(全体レーンやフォールバック)は中立色のピル。
    function setLaneHeader(headerEl, name, platform) {
      headerEl.textContent = '';
      const pill = document.createElement('span');
      pill.className = 'lane-name ' + (platform ? 'tile-name-' + platform : 'lane-name-neutral');
      pill.textContent = name;
      headerEl.appendChild(pill);
    }

    // updateLabel=true は workersReady/hydrate/デバイス同期によるレーン構成時のみ。
    // 行追加(appendLaneLine)からの呼び出しで true にすると、フォールバック名(生の worker id)で
    // 構成済みの表示名を上書きしてしまう(過去に実際に起きた表記崩れ)。
    function ensureLane(id, name, platform, updateLabel) {
      let lane = lanes.get(id);
      if (lane) {
        if (updateLabel) {
          setLaneHeader(lane.headerEl, name, platform);
        }
        return lane;
      }
      const el = document.createElement('div');
      el.className = 'lane';
      const header = document.createElement('div');
      header.className = 'lane-header';
      setLaneHeader(header, name, platform);
      const body = document.createElement('div');
      body.className = 'lane-body';
      el.append(header, body);
      lanesGrid.appendChild(el);

      lane = { el, headerEl: header, bodyEl: body, atBottom: true, lineCount: 0 };
      body.addEventListener('scroll', () => {
        lane.atBottom = body.scrollHeight - body.scrollTop - body.clientHeight < 24;
      });
      lanes.set(id, lane);
      updateLaneVisibility();
      return lane;
    }

    function appendLaneLine(laneId, text) {
      const lane = ensureLane(laneId, laneId === OVERALL_LANE_ID ? OVERALL_LANE_NAME : laneId, undefined, false);
      const wasAtBottom = lane.atBottom;
      const line = document.createElement('div');
      line.className = 'lane-line';
      line.textContent = text;
      lane.bodyEl.appendChild(line);
      lane.lineCount += 1;
      while (lane.lineCount > MAX_LANE_LINES) {
        const first = lane.bodyEl.firstChild;
        if (!first) {
          break;
        }
        lane.bodyEl.removeChild(first);
        lane.lineCount -= 1;
      }
      if (wasAtBottom) {
        lane.bodyEl.scrollTop = lane.bodyEl.scrollHeight;
      }
    }

    function clearAllLanes() {
      for (const lane of lanes.values()) {
        lane.el.remove();
      }
      lanes.clear();
      for (const id of [...runningWorkers]) {
        setTileRunning(id, false);
      }
      lanesRunStatus.textContent = '';
      updateLaneVisibility();
    }

    function configureLanes(laneInfos) {
      const nextIds = new Set(laneInfos.map((l) => l.id));
      for (const [id, lane] of [...lanes]) {
        if (!nextIds.has(id)) {
          lane.el.remove();
          lanes.delete(id);
        }
      }
      for (const info of laneInfos) {
        ensureLane(info.id, info.name, info.platform, true);
      }
      updateLaneVisibility();
    }

    function updateLaneVisibility() {
      const allIds = [...lanes.keys()];
      const activeIds = selectedDeviceIds.size > 0
        ? allIds.filter((id) => selectedDeviceIds.has(id))
        : allIds;
      const columns = Math.max(1, activeIds.length);
      lanesGrid.style.gridTemplateColumns = 'repeat(' + columns + ', minmax(0, 1fr))';
      for (const [id, lane] of lanes) {
        lane.el.style.display = activeIds.includes(id) ? 'flex' : 'none';
      }
      lanesSelectionStatus.textContent = selectedDeviceIds.size > 0
        ? '選択中' + selectedDeviceIds.size + '台を表示'
        : '全ワーカー';
    }

    // 出力ペインは常設で、実行前でもデバイス毎の空レーンを表示する(ユーザー指定で
    // プレースホルダー文言は廃止)。レーンはモニターの devices サイクルから常時同期する。
    function updateLanesPlaceholder() {
      lanesPlaceholder.style.display = 'none';
      lanesGrid.style.display = 'grid';
    }
    updateLanesPlaceholder();

    // モニターのデバイス一覧に合わせて空レーンを用意する(既存レーンはそのまま。
    // 実行開始(cleared)で一旦消えても、次の devices サイクル(interval秒毎)で復元される)。
    function syncLanesToDevices(devices) {
      for (const device of devices) {
        ensureLane(device.id, device.name, device.platform, true);
      }
    }

    function applyLaneAction(action) {
      switch (action.type) {
        case 'cleared':
          clearAllLanes();
          break;
        case 'lanesConfigured':
          configureLanes(action.lanes);
          break;
        case 'line':
          appendLaneLine(action.laneId, action.text);
          break;
        case 'workerRunning':
          setTileRunning(action.workerId, action.running);
          break;
        case 'runFinished':
          lanesRunStatus.textContent = '完了: 成功 ' + action.passed + ' / 失敗 ' + action.failed;
          break;
        default:
          break;
      }
    }

    function applyLaneHydrate(snapshot) {
      clearAllLanes();
      if (snapshot.lanes.length > 0) {
        configureLanes(snapshot.lanes);
      }
      for (const laneId of Object.keys(snapshot.linesByLane)) {
        for (const text of snapshot.linesByLane[laneId]) {
          appendLaneLine(laneId, text);
        }
      }
      for (const workerId of snapshot.runningWorkers) {
        setTileRunning(workerId, true);
      }
    }

    // ---- メッセージ受信 ---------------------------------------------------------

    window.addEventListener('message', (event) => {
      const message = event.data;
      if (!message || typeof message.type !== 'string') {
        return;
      }
      switch (message.type) {
        case 'devices':
          hideBanner();
          statusEl.textContent = 'モニタリング中';
          applyDevices(message.devices);
          break;
        case 'frame':
          applyFrame(message);
          break;
        case 'deviceError':
          applyDeviceError(message);
          break;
        case 'bootBusy':
          setBusy(!!message.busy);
          break;
        case 'processDown':
          statusEl.textContent = '停止中';
          showBanner(message.message);
          break;
        case 'deviceOpBusy': {
          const entry = findTileByName(message.name);
          if (entry) {
            entry.opBusy = message.op ? { op: message.op, status: message.status || 'running' } : undefined;
            renderOpBadge(entry);
            if (deviceOpMenuEntry === entry) {
              renderDeviceOpMenuItem();
            }
          }
          break;
        }
        case 'deviceOpFailed':
          showBanner(message.name + ': ' + message.message);
          break;
        case 'laneSectionVisible':
          // レーンは常時表示になったため何もしない(TS側からのメッセージ自体は互換のため残る)
          break;
        case 'runEvent':
          applyLaneAction(message.action);
          break;
        case 'laneHydrate':
          applyLaneHydrate(message.snapshot);
          break;
        case 'profileInfo':
          applyProfileInfo(message);
          break;
        default:
          break;
      }
    });

    btnUp.addEventListener('click', () => vscode.postMessage({ type: 'devicesUp' }));
    btnDown.addEventListener('click', () => vscode.postMessage({ type: 'devicesDown' }));
    btnRestart.addEventListener('click', () => {
      hideBanner();
      statusEl.textContent = '再起動中...';
      closeDeviceOpMenu();
      for (const entry of tiles.values()) {
        entry.tile.remove();
      }
      tiles.clear();
      selectedDeviceIds.clear();
      emptyMessage.style.display = 'flex';
      vscode.postMessage({ type: 'restartMonitor' });
    });

    updateLaneVisibility();
    updateLanesPlaceholder();

    // 初期化完了(全リスナー登録済み)を拡張側へ通知する(ready ハンドシェイク)。
    // 拡張側はこれを受けて初期状態(laneHydrate/profileInfo等)を送る。
    vscode.postMessage({ type: 'ready' });
  })();
  </script>
</body>
</html>`;
}
