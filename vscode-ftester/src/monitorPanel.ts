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
// - webview はマルチタブ構成(「デバイス」「プロファイル」「設定」)。既存のデバイスモニターUI
//   一式(トップの操作)はそのまま「デバイス」タブのパネル内に移動しただけで、TypeScript 側の
//   ロジックは変わらない。「設定」は現状プレースホルダーのみで、今後の機能追加先。
// - 「プロファイル」タブの3セクションは DOM 順で上から実行/アプリ/マシンプロファイル(使用
//   頻度が高い実行プロファイルを先頭にしてほしいというユーザー報告により、以前のマシン/アプリ/
//   実行の順から並べ替えた。各セクションの内部構造・JS ロジックは不変)。#panel-profiles の
//   先頭(全セクションの前)には position: sticky なジャンプヘッダー(#profile-jump-header)を
//   常設し、3セクションへのテキストリンク(button 要素)から scrollIntoView({behavior:'smooth'})
//   で各セクションへ飛べるようにする(単一の縦スクロールになったことで下のセクションまで
//   長くスクロールする必要が出たため)。sticky ヘッダーの裏に見出しが隠れないよう、各
//   .profile-section に scroll-margin-top を設定する。
// - 「プロファイル」タブの「マシンプロファイル」セクション: Projects/<project>/profiles/machines/
//   直下の *.json(config.ts の listMachineProfiles)を一覧表示する。デバイス追加の入口は
//   「デバイス」ラベル横の「+」(#btn-device-add-existing)の1つだけ(2026-07-11 指示で
//   「+新規作成」ボタンは廃止。新規作成は選択画面内の「+」から行う。`ftester api device-catalog`
//   (単発 JSON)/`ftester api create-device`(NDJSON)は新規作成モーダルが引き続き使う)。「+」は
//   #device-pick-overlay モーダルを開き、`ftester api installed-devices`(単発 JSON。runInstalledDevices)
//   でインストール済みの実体一覧を取得して2列(iOS/Android)で一覧表示する。各行のチェックボックスは
//   「選択」ではなく「マシンプロファイルへの登録状態そのもの」を表す設計(disabled/淡色化は廃止)。
//   初期状態は udid(iOS)/avd の id または displayName(Android)で現在の登録済みデバイスと突合し、
//   登録済みなら初期チェック、未登録なら初期未チェックにする。OK は行ごとの初期状態からの差分が
//   1件以上あるときだけ有効になり、押下時に差分(新たにチェック=追加/外した=登録解除)だけを
//   machineDevicesSync(add/remove)としてまとめて送る(モーダル確認は挟まず、チェック操作自体を
//   確定操作として扱う。ホスト側の syncDevicesInMachineProfile が
//   removeDeviceFromMachineProfile→addDevicesToMachineProfile の順で合成する純粋関数部分を担当。
//   削除を先に行うのは、外して同名で付け直すケースで名前衝突の自動サフィックスが誤発動しない
//   ようにするため)。モーダル下部には「チェックを外して OK すると登録解除されます(シミュレータ/
//   AVD 本体は削除されません)」という常設の注記を置き、誤操作への注意を促す。タイトル行右端の
//   「+」ボタン(#device-pick-add-new)は #device-pick-overlay を閉じずに #device-add-overlay
//   (「+新規作成」モーダル)をその上に重ねて開く(z-index を #device-pick-overlay より高くして
//   スタック表示)。#device-add-overlay はフルスクリーンのオーバーレイなので、ピッカーから開いたか
//   どうかは openDeviceAddModal() 呼び出し時点の devicePickOpen(deviceAddFromPicker に記録)で
//   判定できる。この経路(deviceAddFromPicker=true)では createDevice に register:false を送り、
//   ホストは `--no-register` を付けて物理作成のみ行う(マシンプロファイルへは追記しない。
//   register:true の即登録経路はメッセージ契約として残っているが、「+新規作成」ボタン廃止後は
//   UI からの送り手がいない。2026-07-11 指示)。register:false の作成が成功したら、
//   installedDevicesRequest を再送して一覧を作り直す前に pendingAutoCheck へ作成された実体の
//   識別子(iOS=udid/Android=avd の id。createDeviceResult の device フィールドから取る)を保持し、
//   再描画時に一致する行を「チェックON」(初期状態[registered]は false のままなので差分扱い)にする。
//   これにより新規デバイスは「未登録+チェックON」の状態で現れ、OK ボタンが有効になり、押下すると
//   machineDevicesSync の add 経由でマシンプロファイルへ登録される(=「OK で登録」を実現する)。
//   一致する行が見つからない場合は pendingAutoCheck を静かに捨てて何もしない。他行で操作中だった
//   未確定の差分は(register:true 経路と同じく)この再読込で破棄されるが、シンプルさを優先した
//   設計判断。いずれも他の短命 CLI 実行(executeBulkJob 等)と同じく直接 spawn する方針
//   (FtesterCli の直列キューは使わない)。デバイス一覧は複数選択に対応する(要件5。
//   selectedDeviceNames が Set。通常クリックは単一選択への置き換え[トグル]、Shift+クリックは
//   アンカー(直近に通常/Cmdクリックした行)からの範囲選択、Cmd/Ctrl+クリックは個別の追加/除外
//   トグル。Finder/VSCode のリストと同じ標準セマンティクス。2026-07-11 ユーザー指示)。
//   右ペインの編集フォームは「ちょうど1台選択」のときだけ表示する。
//   デバイス行の右クリック「除去」/「選択した<N>台を除去」(handleMachineDeviceRemove。複数選択に
//   対応するため machineDeviceRemove の対象は names 配列)・行選択時に右ペインに表示する編集フォーム
//   の「確定」(handleMachineDeviceUpdate)はいずれも CLI を呼ばず、machines/<machine>.json を
//   直接読み書きする(monitorModel.ts の removeDeviceFromMachineProfile / updateDeviceInMachineProfile
//   が純粋関数部分を担当)。マシンプロファイル自体の追加/コピー/削除/名前変更(マシン名横の
//   アイコンボタン。handleMachineProfileAdd/Copy/Delete/Rename)も同様に CLI を呼ばず
//   machines/*.json を直接読み書きする。名前変更時は CLI 登録名(~/.config/ftester/config.json の
//   machineName)が旧名のままだと解決が壊れるため、config.ts の updateLocalMachineName で追随させる。
// - 「プロファイル」タブ上段の「実行プロファイル」セクション: runs/<name>.json の内容を編集する
//   フォーム。一覧・初期選択は既存の profileInfo(デバイスタブのドロップダウンと共用。apps を
//   追加しただけ)を流用するが、この選択(編集対象)は ftester.profile 設定とは独立
//   (selectProfile とは別に webview 内だけで完結する)。ロード(runProfileLoad)/保存
//   (runProfileSave)はいずれも CLI を呼ばず、runs/<name>.json を直接読み書きする
//   (monitorModel.ts の parseRunProfileForForm/updateRunProfileInObject が純粋関数部分を担当。
//   removeDeviceFromMachineProfile/updateDeviceInMachineProfile と同じ、未知キー保持の
//   イミュータブル更新の方針)。dirty 管理・machineProfileInfo/profileInfo 再受信時の再プリフィル
//   可否も、右ペインのデバイス編集フォーム(machineDeviceUpdate)と同じ方針(dirty/送信中は保持、
//   そうでなければ再描画)。profileFileWatcher の onDidChange(今回追加)で外部編集も検知し、
//   編集中でなければ自動的に再ロードする。実行プロファイル自体の追加/コピー/削除/名前変更
//   (セクションヘッダーのアイコンボタン。handleProfileAdd/Copy/Delete/Rename)も、マシンプロファイル
//   の [+][コピー][−][✏] と同一デザイン・同じ対話形式(名前入力はwebview内モーダル
//   [#name-input-overlay]、削除確認はshowWarningMessageのモーダル確認)で行う
//   (以前はデバイスタブのツールバーに置いていたが、下半分のフォームが編集手段になったのに合わせて
//   ここへ移設し、デバイスタブは実行プロファイルの選択のみに絞った)。追加・コピー直後は
//   runProfileSelected で編集対象を新プロファイルへ移す(machineProfileSelected と同じ方式。
//   削除は webview 側の既存フォールバックに任せるので送らない)。名前変更時、ftester.profile が
//   旧名を指していたら selectProfile で追随させる(handleMachineProfileRename の
//   updateLocalMachineName 追随と同じ理由)。
// - 「プロファイル」タブ中段の「アプリプロファイル」セクション: apps/<name>.json(common/ios/android
//   の3セクション)を編集するフォーム。common は表示名(appName)+自動インストール(autoInstall。
//   チェックボックス1つで有効/無効の2値、既定=無効[チェックOFF])の2フィールド、ios/android は
//   表示名/アプリID(app)/パッケージパス(appPath)の3フィールド(common の app/appPath は廃止済み
//   でランタイムはこれらの値を無視するためフォーム自体に入力欄を持たない。自動インストールは
//   元々 ios/android セクション別だったが、common でのみ設定できる仕様に一本化した
//   [2026-07-11 指示。Swift 側も common 採用+platform 残存は validate 警告に変更中])。設計は
//   実行プロファイルセクションの複製(選択は webview 内だけで完結する独立状態。ただし「現在値」に
//   相当する設定が無いため、選択のフォールバックは常に一覧の先頭)。
//   ロード(appProfileLoad)/保存(appProfileSave)は monitorModel.ts の
//   parseAppProfileForForm/updateAppProfileInObject が純粋関数部分を担当する(未知キー保持の
//   イミュータブル更新。既存の空セクションはそのまま保持し、元に無いセクションは値が1つでも
//   入力されない限り作らない。autoInstall は既定=無効[false]なので「無効」を選んだだけでは
//   「値あり」に数えない)。追加/コピー/削除/名前変更(handleAppProfileAdd/Copy/
//   Delete/Rename)も実行プロファイル版の複製だが、アプリプロファイルは ftester.* のどの設定からも
//   直接参照されないため、削除・名前変更時に追随させる設定は無い(実行プロファイルの app 参照が
//   古い名前を指したままになりうるが、そちらは CLI 側の validate-profile が検出する領分とし、
//   この拡張からは追随しない)。appsFileWatcher(今回追加)の onDidChange で外部編集も検知する。
// - ホストMacのメトリクスグラフ(CPU/GPU/ANE/MEM。デバイスタブの #toolbar、実行プロファイル選択
//   [.profile-label]の直後に4つ横並びで表示): `ftester api host-metrics --interval 1` を monitor
//   プロセスとは別に常駐 spawn し(startHostMetricsProcess/stopHostMetricsProcess。stdin をパイプで
//   保持したまま EOF で終了させる・SIGTERM 送信後2秒待って SIGKILL、という流儀は monitor プロセスの
//   管理[startMonitorProcess/stopMonitorProcess]と同じ)、NdjsonParser(monitor と共用)で受けた
//   `{"kind":"hostMetrics", ...}` 行を isHostMetricsEvent で検証してから webview へ `hostMetrics`
//   メッセージとして転送する。host-metrics はプロファイル/プロジェクトに依存しない(ホストMac自体の
//   値なので、restartMonitorIfScopeChanged 等の監視対象切り替えでは再起動しない)。予期しない終了時は
//   パネルが生きていれば5秒後に自動再起動するが(scheduleHostMetricsRestart)、起動後10秒未満での
//   異常終了が3回連続したら諦めて outputChannel に1回だけログし、以後は自動再起動を止める
//   (hostMetricsGaveUp。旧バイナリに host-metrics サブコマンドが無い環境で無限に再起動ループしない
//   ようにするための安全弁)。「モニター再起動」ボタン(handleWebviewMessage の "restartMonitor")は
//   この失敗カウンタもリセットして再起動を試みるので、バイナリ更新後はボタン一つで復帰できる
//   (パネルを開き直したとき[show()]も同様にリセットする)。webview 側はグラフ描画用の独自タイマーを
//   持たず、host-metrics プロセスの1秒 interval で届く hostMetrics メッセージ受信のたびに直近60
//   サンプルのローリングバッファへ追加して canvas に再描画するだけ(CPU/GPU/ANE は 0..1 の負荷率、
//   MEM は memUsedBytes/memTotalBytes の比率。いずれも null は欠測として線を途切れさせる)。系列色は
//   ライト/ダークテーマで切り替える固定パレットを使い、body の class(vscode-light 等)の変化を
//   MutationObserver で監視して即座に全グラフを再描画する。
// - webview 資産(スタイル・スクリプト)は src/webview/monitor/{style.css,main.js} に分離されている
//   (Phase 1: webview 資産の実ファイル化。以前は renderHtml() のテンプレート文字列に CSS/JS を
//   直接内蔵していた)。esbuild(esbuild.mjs の buildWebview())がこれらを media/monitor/ に
//   バンドルし、renderHtml() は webview.asWebviewUri で変換した URI を使って
//   <link rel="stylesheet">/<script src> から外部リソースとして読み込む。
// - Phase 2(monitorPanel.ts の分割、本ファイルの現在の構成): HTML 本文(renderHtml()/generateNonce()/
//   PANEL_TITLE)は monitorHtml.ts へ、常駐子プロセス(monitor/host-metrics)の起動・停止・再起動は
//   monitorProcessManager.ts の MonitorProcessManager へ、「プロファイル」タブの一覧post・CRUD・
//   フォームのロード/保存は monitorProfilesController.ts の MonitorProfilesController へ、
//   デバイスライフサイクルキュー・device-catalog/installed-devices/create-device は
//   monitorDeviceOps.ts の MonitorDeviceOps へ、それぞれ移動した。MonitorPanelController は
//   これら3つのサブコントローラのインスタンスを保持するオーケストレーターで、show()/dispose()/
//   handleBusMessage()/handleWebviewMessage()(switch からの委譲のみ)/sendInitialState()/
//   restartMonitorIfScopeChanged()(プロファイル切り替え時のモニター再起動要否判定)/
//   enqueueShutdownOutsideNewScope()(切り替え時の自動シャットダウン)を持つ。サブコントローラは
//   互いを直接参照せず、狭いインターフェース MonitorPanelDeps(workspaceRoot/getConfig/
//   outputChannel/post に加え、isPanelActive・writeMonitorControl・notifyMachineProfilesChanged の
//   3つの仲介コールバック)だけをコンストラクタ注入で受け取る。サブコントローラ間で連携が必要な
//   箇所(例: プロファイル切り替え→デバイスshutdownキュー投入、デバイス操作→モニターへの
//   pause/resume 依頼)は MonitorPanelDeps 経由のコールバックか、このオーケストレーターが仲介する。

import * as vscode from "vscode";
import { type FtesterConfig, readRunProfileDeviceNames, resolveProjectName } from "./config";
import {
  devicesToShutdownOnScopeChange,
  isMonitorFromWebviewMessage,
  type MonitorControlCommand,
  type MonitorToWebviewMessage,
} from "./monitorModel";
import { MonitorDeviceOps } from "./monitorDeviceOps";
import { PANEL_TITLE, renderHtml } from "./monitorHtml";
import { type HostMetricsToWebviewMessage, MonitorProcessManager } from "./monitorProcessManager";
import { MonitorProfilesController } from "./monitorProfilesController";
import type { RunBusMessage, RunEventBus } from "./runEventBus";
import {
  createRunLaneState,
  forceEndRunLaneState,
  reduceLaneEvent,
  snapshotRunLaneState,
  type RunLaneToWebviewMessage,
} from "./runLaneModel";

const VIEW_TYPE = "ftesterMonitor";

/**
 * MonitorProcessManager / MonitorProfilesController / MonitorDeviceOps の3サブコントローラが
 * 共通で依存する狭いインターフェース。サブコントローラ同士は互いを直接参照せず、必要な相互作用は
 * ここに定義したコールバック(isPanelActive/writeMonitorControl/notifyMachineProfilesChanged)経由で
 * MonitorPanelController が仲介する。メンバーは実際に各サブコントローラの移動元コードが参照していた
 * this.* を洗い出して決めた最小集合(workspaceRoot/getConfig/outputChannel/post は3者共通、
 * 残り3つは特定のサブコントローラ間の連携専用)。
 */
export interface MonitorPanelDeps {
  readonly workspaceRoot: string;
  getConfig(): FtesterConfig;
  readonly outputChannel: vscode.OutputChannel;
  post(message: MonitorToWebviewMessage | RunLaneToWebviewMessage | HostMetricsToWebviewMessage): void;
  /**
   * パネルが現在表示中かどうか。MonitorProcessManager.scheduleHostMetricsRestart() が、
   * 5秒後の自動再起動タイマー発火時点でパネルがまだ開いているかを確認するために使う。
   */
  isPanelActive(): boolean;
  /**
   * モニタープロセスの stdin へ pause/resume を書き込む(MonitorProcessManager.writeMonitorControl
   * への委譲)。MonitorDeviceOps のデバイスライフサイクルキューが down 系ジョブの前後で呼ぶ。
   */
  writeMonitorControl(cmd: MonitorControlCommand): void;
  /**
   * マシンプロファイル一覧を最新化して webview へ再送する(MonitorProfilesController.
   * postMachineProfileInfo への委譲)。MonitorDeviceOps.runCreateDevice が成功時に呼ぶ。
   */
  notifyMachineProfilesChanged(): void;
}

export function registerMonitorPanel(
  context: vscode.ExtensionContext,
  workspaceRoot: string,
  getConfig: () => FtesterConfig,
  outputChannel: vscode.OutputChannel,
  eventBus: RunEventBus,
): void {
  const controller = new MonitorPanelController(
    workspaceRoot,
    getConfig,
    outputChannel,
    eventBus,
    context.extensionUri,
  );
  context.subscriptions.push(
    controller,
    vscode.commands.registerCommand("ftester.showDeviceMonitor", () => controller.show()),
  );
}

class MonitorPanelController implements vscode.Disposable {
  private panel: vscode.WebviewPanel | undefined;
  private readonly deps: MonitorPanelDeps;
  /** monitor / host-metrics 常駐プロセスの起動・停止・再起動(monitorProcessManager.ts)。 */
  private readonly processManager: MonitorProcessManager;
  /** 「プロファイル」タブの一覧post・CRUD・フォームのロード/保存(monitorProfilesController.ts)。 */
  private readonly profiles: MonitorProfilesController;
  /** デバイスライフサイクルキュー・device-catalog/installed-devices/create-device(monitorDeviceOps.ts)。 */
  private readonly deviceOps: MonitorDeviceOps;

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

  constructor(
    private readonly workspaceRoot: string,
    private readonly getConfig: () => FtesterConfig,
    private readonly outputChannel: vscode.OutputChannel,
    eventBus: RunEventBus,
    private readonly extensionUri: vscode.Uri,
  ) {
    this.deps = {
      workspaceRoot: this.workspaceRoot,
      getConfig: this.getConfig,
      outputChannel: this.outputChannel,
      post: (message) => this.post(message),
      isPanelActive: () => this.panel !== undefined,
      writeMonitorControl: (cmd) => this.processManager.writeMonitorControl(cmd),
      notifyMachineProfilesChanged: () => this.profiles.postMachineProfileInfo(),
    };
    this.processManager = new MonitorProcessManager(this.deps);
    this.profiles = new MonitorProfilesController(this.deps);
    this.deviceOps = new MonitorDeviceOps(this.deps);

    this.unsubscribeBus = eventBus.subscribe((message) => this.handleBusMessage(message));
    this.configChangeSubscription = vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration("ftester.profile") || event.affectsConfiguration("ftester.project")) {
        this.profiles.postProfileInfo();
        this.restartMonitorIfScopeChanged();
        // ftester.project の変更は対象マシンプロファイル一覧にも影響するため、こちらも最新化する。
        this.profiles.postMachineProfileInfo();
      }
    });
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
    if (scope === this.processManager.monitorScope) {
      return;
    }
    this.enqueueShutdownOutsideNewScope(resolution.project, config.profile);
    this.processManager.restartMonitorProcess();
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
    const targets = devicesToShutdownOnScopeChange(this.processManager.lastKnownDevices, newScopeNames);
    if (targets.length === 0) {
      return;
    }
    this.outputChannel.appendLine(
      `[ftester] プロファイル切り替えに伴い監視対象外のデバイスを停止します: ${targets.join(", ")}`,
    );
    for (const name of targets) {
      this.deviceOps.enqueueLifecycleJob({ kind: "device", name, op: "down" });
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
      localResourceRoots: [vscode.Uri.joinPath(this.extensionUri, "media")],
    });
    this.panel = panel;
    panel.webview.html = renderHtml(panel.webview, this.extensionUri);

    panel.webview.onDidReceiveMessage((message: unknown) => this.handleWebviewMessage(message));
    panel.onDidDispose(() => {
      this.panel = undefined;
      this.processManager.stopMonitorProcess();
      this.processManager.stopHostMetricsProcess();
    });

    this.processManager.startAll();
    // 初期状態(laneHydrate/profileInfo等)の送信はここでは行わない。html設定直後の
    // postMessage は webview 側スクリプトの message リスナー登録前に届き、VS Code webview の
    // 既知のレースで握りつぶされる(タイル/フレームはモニタープロセスが継続的に流すので
    // 自然回復するが、一度きりの送信であるこれらは落ちたら復旧しない)。webview からの
    // "ready"(初期化完了通知)を受けてから sendInitialState() で送る(ready ハンドシェイク)。
  }

  dispose(): void {
    this.profiles.disposePendingNameInput();
    this.unsubscribeBus();
    this.configChangeSubscription.dispose();
    this.profiles.disposeWatchers();
    this.processManager.stopMonitorProcess();
    this.processManager.stopHostMetricsProcess();
    const panel = this.panel;
    this.panel = undefined;
    panel?.dispose();
  }

  private post(
    message: MonitorToWebviewMessage | RunLaneToWebviewMessage | HostMetricsToWebviewMessage,
  ): void {
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
        this.deviceOps.enqueueLifecycleJob({ kind: "bulk", op: "up" });
        break;
      case "devicesDown":
        this.deviceOps.enqueueLifecycleJob({ kind: "bulk", op: "down" });
        break;
      case "restartMonitor":
        this.processManager.restartAll();
        break;
      case "deviceOp":
        this.deviceOps.enqueueLifecycleJob({ kind: "device", name: message.name, op: message.op });
        break;
      case "selectProfile":
        this.profiles.selectProfile(message.profile);
        break;
      case "profileAdd":
        void this.profiles.handleProfileAdd();
        break;
      case "profileCopy":
        void this.profiles.handleProfileCopy(message.profile);
        break;
      case "profileDelete":
        void this.profiles.handleProfileDelete(message.profile);
        break;
      case "profileRename":
        void this.profiles.handleProfileRename(message.profile);
        break;
      case "machineProfileRefresh":
        this.profiles.postMachineProfileInfo();
        break;
      case "machineProfileAdd":
        void this.profiles.handleMachineProfileAdd();
        break;
      case "machineProfileCopy":
        void this.profiles.handleMachineProfileCopy(message.machine);
        break;
      case "machineProfileDelete":
        void this.profiles.handleMachineProfileDelete(message.machine);
        break;
      case "machineProfileRename":
        void this.profiles.handleMachineProfileRename(message.machine);
        break;
      case "deviceCatalogRequest":
        this.deviceOps.runDeviceCatalog();
        break;
      case "createDevice":
        this.deviceOps.runCreateDevice(message);
        break;
      case "installedDevicesRequest":
        this.deviceOps.runInstalledDevices();
        break;
      case "machineDevicesSync":
        this.profiles.handleMachineDevicesSync(message);
        break;
      case "machineDeviceRemove":
        void this.profiles.handleMachineDeviceRemove(message.machine, message.names);
        break;
      case "machineDeviceUpdate":
        this.profiles.handleMachineDeviceUpdate(message);
        break;
      case "runProfileLoad":
        this.profiles.handleRunProfileLoad(message.profile);
        break;
      case "runProfileSave":
        this.profiles.handleRunProfileSave(message);
        break;
      case "appProfileAdd":
        void this.profiles.handleAppProfileAdd();
        break;
      case "appProfileCopy":
        void this.profiles.handleAppProfileCopy(message.profile);
        break;
      case "appProfileDelete":
        void this.profiles.handleAppProfileDelete(message.profile);
        break;
      case "appProfileRename":
        void this.profiles.handleAppProfileRename(message.profile);
        break;
      case "appProfileLoad":
        this.profiles.handleAppProfileLoad(message.profile);
        break;
      case "appProfileSave":
        this.profiles.handleAppProfileSave(message);
        break;
      case "nameInputConfirm":
        this.profiles.resolveNameInput(message.id, message.name);
        break;
      case "nameInputCancel":
        this.profiles.cancelNameInput(message.id);
        break;
    }
  }

  /**
   * webview からの "ready"(初期化完了通知)を受けて、初期状態をまとめて送る(ready ハンドシェイク)。
   * ready は webview 再読込(タブのエディタグループ移動等)のたびに再送されうるので、ここで行う
   * 各処理が冪等であることが前提になる(hydrateLaneUi はスナップショットの一括送信、
   * profileInfo・デバイスライフサイクルキュー状態の再送はいずれも webview 側で上書き描画するだけ
   * なので何度呼んでも問題ない)。
   */
  private sendInitialState(): void {
    this.hydrateLaneUi();
    this.profiles.postProfileInfo();
    this.profiles.postMachineProfileInfo();
    // デバイスライフサイクルキューの状態も再送する(webview 再読込がジョブ実行中に起きた場合に、
    // ボタンの無効状態・タイルのバッジを復元するため)。
    this.deviceOps.resendQueueStatus();
  }
}
