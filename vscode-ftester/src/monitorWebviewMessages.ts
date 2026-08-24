// monitorWebviewMessages.ts
// extension ⇔ webview 間の postMessage 契約(型付き)と、その検証・変換の純粋関数群。
// vscode に依存しない(monitorPanel.ts と test/monitorModel.test.mjs の両方から使うため)。
// デバイス・NDJSON イベントの型は monitorDeviceModel.ts、デバイスライフサイクル操作の型は
// monitorDeviceLifecycle.ts、プロファイルフォーム/デバイスカタログの型は monitorProfileForms.ts
// にあり、メッセージ型はそれらを組み合わせて定義する。

import type { MonitorDeviceFilter } from "./config";
import type { RecordingErrorEntry, RecordingScenarioVideo, RecordingTreeClass } from "./recordingsModel";
import type { RecordingSessionSummary } from "./recordingsStore";
import type { DeviceCommandSource, RemoteHostEntry } from "./remoteRunArgs";
import type { ResidentProcess } from "./residentProcesses";
import { isRecord, type MonitorDevice, type MonitorEvent, type MonitorPlatform } from "./monitorDeviceModel";
import type { DeviceOpKind, DeviceOpQueueStatus } from "./monitorDeviceLifecycle";
import type {
  AppProfileCommonFields,
  AppProfileFormFields,
  AppProfilePlatformFields,
  DeviceCatalog,
  InstalledDevices,
  MachineDeviceAddEntry,
  RunProfileFormFields,
} from "./monitorProfileForms";

/** extension → webview へ送るメッセージ(型付き)。 */
export type MonitorToWebviewMessage =
  | { readonly type: "devices"; readonly devices: readonly MonitorDevice[] }
  | {
      readonly type: "frame";
      readonly device: string;
      readonly jpegBase64: string;
      readonly width: number;
      readonly height: number;
      /** true = ストリーミングヘルパー由来(monitorDeviceStreamController の mjpeg 経路)。
       * webview は描画後に streamRendered を ack する(ポーリング由来のフレームには付かない。
       * ack でポーリング抑止を発動する契約は monitorDeviceStreamController.ts 冒頭参照) */
      readonly stream?: boolean;
    }
  // 配信を諦めた(unavailable:true)/対象から外れて解除した(false)。
  // monitorDeviceStreamController.ts の onFailure と対。**プロファイル未選択の iOS は
  // ブリッジが無くポーリングのフレームも来ない**ので、伝えないとタイルが永久に「接続中」に見える
  | { readonly type: "streamUnavailable"; readonly device: string; readonly unavailable: boolean }
  // H.264 AU 1件(deviceStream.ts v2 形式。monitorDeviceStreamController.ts の onChunk が post する。
  // data は構造化クローンで転送される Uint8Array、base64 化しない。webview 側は main.js の
  // 直下ディスパッチャから直接 applyH264Chunk へ渡す — "live" 封筒は経由しない)。
  | {
      readonly type: "h264Chunk";
      readonly device: string;
      readonly keyframe: boolean;
      readonly width: number;
      readonly height: number;
      readonly data: Uint8Array;
    }
  // ライブ操作パネルの H.264 AU 1件(monitorLiveController.ts の onChunk が post する。既存の
  // { type: "frame", image } と並置。h264Chunk と同じく "live" 封筒は経由しない — webview 側は
  // src/webview/live/main.js の直下ディスパッチャから直接 liveTab.js の applyLiveH264Chunk へ渡す)。
  | {
      readonly type: "liveH264Chunk";
      readonly keyframe: boolean;
      readonly width: number;
      readonly height: number;
      readonly data: Uint8Array;
    }
  | { readonly type: "deviceError"; readonly device?: string; readonly message: string }
  | { readonly type: "bootBusy"; readonly busy: boolean; readonly bulkOp: "up" | "down" | null }
  | { readonly type: "processDown"; readonly message: string }
  | {
      readonly type: "deviceOpBusy";
      readonly name: string;
      /** そのデバイスが居る機械(手元は undefined)。名前だけでは同名の別タイルを触りうる。 */
      readonly host?: string;
      readonly op: DeviceOpKind | null;
      /** キュー内での状態("running"=実行中／"queued"=順番待ち)。op が null のときは null。 */
      readonly status: DeviceOpQueueStatus | null;
    }
  | { readonly type: "deviceOpFailed"; readonly name: string; readonly message: string }
  // 一括 down(api devices-down)で1台停止完了ごとに送る。webview はそのタイルを即「未起動」へ倒す
  // (down 中はモニター pause で state 更新が来ないため、落ちた順の反映をこの per-device 通知で行う。
  //  次の devices 反映=resume 後に本物の state で上書きされる)。name は deviceOpBusy と同じ名前空間。
  | { readonly type: "deviceDownFinished"; readonly name: string; readonly host?: string }
  | {
      readonly type: "profileInfo";
      /** 対象プロジェクトの実行プロファイル名一覧(TestProjects/<project>/profiles/runs/ 直下)。 */
      readonly profiles: readonly string[];
      /** 現在の ftester.profile 設定値。"" はプロファイルなし。 */
      readonly current: string;
      /** 現在の ftester.monitorDeviceFilter 設定値。"running" のときドロップダウンの選択は
       * current("")ではなく RUNNING_DEVICES_PROFILE_VALUE を選ぶ。 */
      readonly filter: MonitorDeviceFilter;
      /** 対象プロジェクトのアプリプロファイル名一覧(profiles/apps/ 直下)。既存の applyProfileInfo は
       * このフィールドを無視するだけなので後方互換。 */
      readonly apps: readonly string[];
      /** 対象プロジェクト名(解決できなければ "")。ワークスペース欄の既定値
       * "TestProjects/<project>/workspace" を透かしで出すのに使う(相対パスはリポジトリルート
       * 基準なので、この文字列はそのまま入力しても既定と同じ場所を指す)。 */
      readonly project: string;
    }
  | {
      readonly type: "machineProfileInfo";
      /** 対象プロジェクトのマシンプロファイル一覧(config.ts の listMachineProfiles の要約形)。 */
      readonly machines: readonly {
        readonly name: string;
        /** 登録済みリモートホスト名(config.ts の MachineProfileSummary.host。未設定=ローカル)。
         * device-pick ダイアログのホスト選択の初期値に使う。 */
        readonly host?: string;
        readonly devices: readonly {
          readonly name: string;
          readonly platform: MonitorPlatform;
          /** このデバイスが居る機械(実効値。undefined=手元)。**一意なのは (host, name)** なので、
           * 重複判定はホストごとに行う(Sources/FTCore/DeviceHostGrouping.swift)。 */
          readonly host?: string;
          /** 一覧2行目の表示文字列(machineDeviceDetail で組み立て済み)。 */
          readonly detail: string;
          // 右ペインの編集フォーム用の生フィールド(MachineDeviceEntry と同形)。undefined は
          // postMessage の JSON 化で自然に省略される。
          readonly simulator?: string;
          readonly os?: string;
          readonly udid?: string;
          readonly port?: number;
          readonly avd?: string;
          /** 実機なら "physical"(一覧・編集フォームのバッジ表示に使う)。省略=virtual。 */
          readonly kind?: "virtual" | "physical";
          readonly serial?: string;
          readonly model?: string;
        }[];
      }[];
      /** 現在選択中とみなすマシン名(machines に無ければ null)。 */
      readonly current: string | null;
      /** 対象プロジェクトが解決できない場合のエラーメッセージ(問題なければ null)。 */
      readonly error: string | null;
    }
  | {
      readonly type: "deviceCatalog";
      readonly ok: boolean;
      readonly catalog: DeviceCatalog | null;
      readonly error: string | null;
    }
  // 「デバイスを追加」の Android モデル一覧が空(avdmanager 不在)のとき出る導入ボタンへの応答。
  // 進捗は CLI の stderr → OUTPUT へ流れるのでここには載せない。ok:true なら webview は
  // カタログを再取得する。
  | {
      readonly type: "installCmdlineToolsResult";
      readonly ok: boolean;
      readonly error: string | null;
    }
  | {
      readonly type: "createDeviceResult";
      readonly ok: boolean;
      readonly name: string;
      readonly error: string | null;
      // finished イベントの device(avd/udid のみ、name は上の name フィールドと重複するため除外)。
      // ok:false または finished.device 無しなら null。webview は register:false 作成時、これを
      // installedDevices 再読込後の該当行自動チェック(pendingAutoCheck)に使う。
      readonly device: { readonly avd: string | null; readonly udid: string | null } | null;
    }
  // バッチ作成(#device-batch-overlay)。3通で1つの流れを表す:
  //   started  … 確認をすべて通り、作成を開始した(webview は「デバイスを追加」を閉じ進行窓を開く)
  //   progress … 1台ごとの状態遷移(running → ok/failed)
  //   finished … 全件終了、または started に至らず終わった場合(started:false + error)
  // **started を出す前に終わる形がある**(確認のキャンセル・多重実行)ので、webview は
  // finished.started を見て「進行窓を閉じる」か「追加ダイアログを元に戻す」かを決める。
  | { readonly type: "batchCreateStarted"; readonly names: readonly string[] }
  | {
      readonly type: "batchCreateProgress";
      readonly index: number;
      readonly name: string;
      readonly state: "running" | "ok" | "failed";
      readonly error: string | null;
    }
  | {
      readonly type: "batchCreateFinished";
      readonly started: boolean;
      readonly created: readonly {
        readonly name: string;
        readonly avd: string | null;
        readonly udid: string | null;
      }[];
      readonly failed: readonly { readonly name: string; readonly error: string | null }[];
      readonly error: string | null;
    }
  // 「+既存から選択」モーダル(#device-pick-overlay)が開いた直後に送る installedDevicesRequest
  // への応答(runInstalledDevices)。deviceCatalog と同じ形。
  | {
      readonly type: "installedDevices";
      readonly ok: boolean;
      readonly data: InstalledDevices | null;
      readonly error: string | null;
    }
  // デバイス選択ダイアログの行右クリック「削除」(devicePickDeviceDelete)への応答。ok:true でも
  // モーダルが閉じていれば webview 側は表示更新をせず捨てる(applyInstalledDevices と同じ方針)。
  // referencedBy はホスト側が既に withSourceContext で error にホスト名を付記済みなので、webview は
  // error をそのまま表示するだけでよい。
  | {
      readonly type: "devicePickDeviceDeleteResult";
      readonly ok: boolean;
      /** 削除対象の識別子(iOS=udid/Android=avd id)。行の再特定に使う。 */
      readonly identifier: string;
      readonly name: string;
      readonly error: string | null;
      readonly referencedBy: readonly string[];
    }
  // 同モーダルの OK(machineDevicesSync)への応答。added は追記できた件数(サフィックス適用後)、
  // removed は実際に登録解除できた件数(存在しない名前は黙ってスキップし数に含めない)。
  // ok:true ならモーダルは閉じ、一覧は直後の machineProfileInfo 再送で最新化される。
  | {
      readonly type: "machineDevicesSyncResult";
      readonly ok: boolean;
      readonly added: number;
      readonly removed: number;
      readonly error: string | null;
    }
  | {
      readonly type: "machineDeviceUpdateResult";
      readonly ok: boolean;
      /** ok:true なら更新後(リネーム後)の名前。ok:false なら originalName をそのまま返す。 */
      readonly name: string;
      readonly error: string | null;
    }
  // machineProfileAdd/Rename 直後に webview の選択を新プロファイルへ移す通知。
  // machineProfileDelete 後は webview 既存フォールバック(current→先頭)任せなので送らない。
  | { readonly type: "machineProfileSelected"; readonly name: string }
  // ---- プロファイルタブ下半分: 実行プロファイルの設定フォーム ---------------------------
  // profileAdd/Copy/Rename 直後に選択を新プロファイルへ移す通知(machineProfileSelected と同趣旨)。
  // profileDelete 後は既存フォールバック(current→先頭)任せなので送らない。
  | { readonly type: "runProfileSelected"; readonly name: string }
  // runProfileLoad(webview→host)への応答。fields は ok:true のときのみ非 null
  // (parseRunProfileForForm の戻り値そのもの)。
  | {
      readonly type: "runProfileData";
      readonly profile: string;
      readonly ok: boolean;
      readonly error: string | null;
      readonly fields: RunProfileFormFields | null;
    }
  // runProfileSave(webview→host)への応答。ok:true のときも fields は送らない — ホストが続けて
  // runProfileData を送り直すことで最新化する(handleRunProfileSave の方針)。
  | {
      readonly type: "runProfileSaveResult";
      readonly profile: string;
      readonly ok: boolean;
      readonly error: string | null;
    }
  // runs/<name>.json の外部編集通知(FileSystemWatcher onDidChange)。name は拡張子なし basename。
  // Create/Delete は profileInfo 再送のみで足りるため、Change だけ専用通知を追加する。
  | { readonly type: "runProfileFileChanged"; readonly name: string }
  // ---- プロファイルタブ中段: アプリプロファイルの設定フォーム -----------------------------
  // 以下4メッセージは実行プロファイルセクション(runProfileSelected〜runProfileFileChanged)と
  // 同一設計。appProfileAdd/Copy/Rename 直後に選択を新プロファイルへ移す通知(削除後は送らない)。
  | { readonly type: "appProfileSelected"; readonly name: string }
  // appProfileLoad(webview→host)への応答。fields は ok:true のときのみ非 null
  // (parseAppProfileForForm の戻り値そのもの)。
  | {
      readonly type: "appProfileData";
      readonly profile: string;
      readonly ok: boolean;
      readonly error: string | null;
      readonly fields: AppProfileFormFields | null;
    }
  // appProfileSave(webview→host)への応答。ok:true のときも fields は送らない — ホストが続けて
  // appProfileData を送り直すことで最新化する(handleRunProfileSave と同じ方針)。
  | {
      readonly type: "appProfileSaveResult";
      readonly profile: string;
      readonly ok: boolean;
      readonly error: string | null;
    }
  // apps/<name>.json の FileSystemWatcher(onDidChange)による外部編集の通知(runProfileFileChanged
  // と同じ方針)。
  | { readonly type: "appProfileFileChanged"; readonly name: string }
  // 名前入力モーダル(#name-input-overlay)を開く。プロファイル追加/コピー/名前変更(monitorPanel.ts
  // の promptName)に共通で使う。id は拡張側の使い捨てトークンで nameInputConfirm/Cancel と対応付ける。
  | {
      readonly type: "nameInputOpen";
      readonly id: number;
      readonly title: string;
      readonly value: string;
      readonly noun: string;
      readonly dupLabel: string;
      readonly existing: readonly string[];
      readonly caseInsensitiveDup: boolean;
    }
  // ホスト駆動のタブ切替(パネルを開き直さず特定タブへ直接切り替える。monitorPanel.ts の
  // show(initialTab) が使う)。webview 側は tabs.js の activateTab へそのまま渡す。
  | { readonly type: "switchTab"; readonly tab: string }
  // 設定タブの「ポーリングモードを使用する」チェックボックスの現在値。ready 直後(永続状態の反映)と
  // setPollingMode 受信直後(monitorPanel.ts)の両方で送る。webview 側は settingsTab.js の
  // applySettings へそのまま渡す(setPollingMode と対の契約)。
  | { readonly type: "pollingMode"; readonly value: boolean }
  // 設定タブのスケジューリング section。ftester.lptScheduling の現在値(拡張→webview)
  | { readonly type: "lptScheduling"; readonly value: boolean }
  // LPT の実績走査 run 数。default は設定タブの初期値・空欄時の戻り先に使う
  | { readonly type: "lptHistoryRuns"; readonly value: number; readonly default: number }
  // 設定タブの表示言語セレクタ(#settings-language)の現在値(ftester.language 設定の生値)。ready 直後に
  // 送る。webview 側は settingsTab.js の applySettings。切替は setLanguage と対。
  | { readonly type: "language"; readonly value: "auto" | "ja" | "en" }
  // 設定タブのリモート実行セクション(CLI のホスト登録簿 + ftester.remote.artifacts 設定の生値)。
  // ready 直後に送る。webview 側は settingsTab.js の applySettings。
  // artifacts(results/ 回収モード)も同じメッセージに相乗りする(専用メッセージ型は起こさない)。
  // 変更は setRemoteConfig と対(docs/remote-runner.md §12)。
  | {
      readonly type: "remoteConfig";
      readonly hosts: readonly RemoteHostEntry[];
      readonly artifacts: "collect" | "on-demand";
      /** 直前の setRemoteConfig(追加・削除)が CLI 側で失敗したときの理由。settingsTab.js が
       * 画面に出す。成功時・ready 直後の初回配信では undefined。 */
      readonly error?: string;
    }
  // 設定タブ「更新」セクションの状態。パネル ready 直後と checkUpdate/runUpdate の前後に送る。
  // 判定そのものは Scripts/update-check.sh(拡張は解釈するだけ)。対向: settingsTab.js の applyUpdate。
  // **実行ログは webview に送らない**(VSCode の OUTPUT へ出す。monitorUpdateController.ts 冒頭)。
  | { readonly type: "updateStatus"; readonly state: string; readonly localHead: string;
      readonly remoteHead: string; readonly reason: string }
  // プロセスタブ「常駐プロセス」一覧。refreshResidentProcesses 受信時に送る。
  // 対向: processesTab.js の applyResidentMessage。
  | { readonly type: "residentProcesses"; readonly items: readonly ResidentProcess[]; readonly ts: number }
  // デバイスタブのスプリッター位置(タイルペイン高さ px)。ready 直後に workspaceState の永続値を反映する。
  // webview の getState はパネルを閉じると失われるため host 側で永続化する(setTilePaneHeight と対の契約)。
  // webview 側は splitter.js の setTilePaneHeight へ渡す。
  | { readonly type: "tilePaneHeight"; readonly value: number }
  // デバイスタブの auto-fit トグルの状態(true = 全デバイスが横幅に収まる高さへ自動調整)。
  // 永続化の理由と経路は tilePaneHeight と同じ(setTileAutoFit と対の契約)。
  | { readonly type: "tileAutoFit"; readonly value: boolean }
  // ブリッジ突然死の自動修復ウォッチドッグ(monitorBridgeWatchdog.ts)の状態遷移通知。name は
  // deviceOpBusy と同じ名前空間(デバイス論理名)。webview 側はタイルのバッジ表示に使う。
  | {
      readonly type: "bridgeWatch";
      readonly name: string;
      readonly phase: "unresponsive" | "repairing" | "failed" | "ok";
    }
  // ゲストOS健全性の自動修復ウォッチドッグ(monitorHealthWatchdog.ts)の状態遷移通知。
  // name は deviceOpBusy と同じ名前空間(デバイス論理名)。webview はタイルのバッジ表示に使う。
  | {
      readonly type: "healthWatch";
      readonly name: string;
      readonly phase: "unhealthy" | "repairing" | "displayRepairing" | "streamRepairing" | "cpuFallback" | "restarting" | "failed" | "ok";
    }
  // `ftester api run` の AVD Wipe Data 進行状況(model.ts の WipeStatusEvent が NDJSON 契約の同期相手)。
  // name は deviceOpBusy と同じ名前空間(デバイス論理名)。webview はタイルのバッジ表示に使う。
  | {
      readonly type: "wipeStatus";
      readonly name: string;
      readonly phase: "stopping" | "rebooting" | "done" | "failed";
    }
  // ---- 録画タブ ---------------------------------------------------------------------------
  // セッション一覧(recordingsStore.ts が TestProjects/*/results/runs/*/*/recordings/index.json を
  // 列挙。新しい順・最大50件)。recordingsRefresh 受信時に post する。
  | { readonly type: "recordingsSessions"; readonly sessions: readonly RecordingSessionSummary[] }
  // recordingsOpen への応答。ok:false は index.json 未検出等(webview は一覧ビューのまま)。
  // videos は scenarioID→動画 webview URI(MonitorPanelDeps.videoWebviewUri で変換済み。1エントリ=
  // 1シナリオのクリップ契約なので worker タブは無い)。errors は動画内オフセット計算済み
  // (recordingsModel.ts の buildRecordingErrorEntries、at 昇順)。
  // tree は TEST EXPLORER 風ツリー(buildRecordingTree → groupTreeByClass。クラスは初出順)。timeline の無い
  // 古い記録のシナリオは scenes:[] (ツリーはそのシナリオノードのみ)。
  | {
      readonly type: "recordingsSession";
      readonly ok: boolean;
      readonly project: string;
      readonly runID: string;
      readonly error: string | null;
      readonly videos: readonly RecordingScenarioVideo[] | null;
      readonly errors: readonly RecordingErrorEntry[] | null;
      readonly tree: readonly RecordingTreeClass[] | null;
      // recordings/index.json の同名フィールド(RecordingSessionSummary と同じ意味・寛容さ)。videos が
      // 空/一部欠落のとき、webview の再生ビューが理由を出すのに使う。省略時は webview 側が「無い」
      // として扱う(旧ホスト実装との互換)。
      readonly clipsAttempted?: number | null;
      readonly clipsFailed?: number | null;
      readonly encoderFallback?: boolean;
    };

/** 検証済みの MonitorEvent を、webview へそのまま postMessage できる形に変換する。 */
// monitorHold は webview へ送らない(monitorProcessManager.ts が OUTPUT ログで処理して return する)
// ため、ここでは型から除外して switch の網羅性を保つ
export function toWebviewMessage(
  event: Exclude<MonitorEvent, { kind: "monitorHold" }>,
): MonitorToWebviewMessage {
  switch (event.kind) {
    case "monitorDevices":
      return { type: "devices", devices: event.devices };
    case "monitorFrame":
      return {
        type: "frame",
        device: event.device,
        jpegBase64: event.jpegBase64,
        width: event.width,
        height: event.height,
      };
    case "monitorError":
      return { type: "deviceError", device: event.device, message: event.message };
  }
}

/** webview → extension へ送るメッセージ(ボタン操作)。 */
export type MonitorFromWebviewMessage =
  // webview の初期化完了通知。拡張側はこれを受けてから初期状態を送る(html設定直後の postMessage は
  // リスナー登録前のレースで捨てられるため、一度きりの送信はこの通知を待つ)。
  | { readonly type: "ready" }
  // restartNames: 起動済みでも down→up で再起動するデバイス論理名(CPU バッジ機の GPU 復帰)。
  // 未起動機のブートと同一キューで2台ずつ並行処理される(devices-up --restart。DeviceBooter.bootAll)。
  | { readonly type: "devicesUp"; readonly restartNames?: readonly string[] }
  // 「デバイスの起動を中断」: 実行中の bulk up プロセスを停止/キュー待ちの bulk up を除去する。
  | { readonly type: "devicesUpCancel" }
  | { readonly type: "devicesDown" }
  | { readonly type: "restartMonitor" }
  // udid/serial/registered: 未登録(マシンプロファイル未記載)デバイスの直指定用。registered:false の
  // ときだけ deviceTiles.js が iOS udid / Android serial のどちらかを載せる(--name で引けないため)。
  // 対向: monitorDeviceOps.ts executeDeviceOpJob(device-down --udid/--serial の直指定モード)。
  | {
      readonly type: "deviceOp";
      readonly name: string;
      readonly op: DeviceOpKind;
      // host: そのデバイスが居る機械(手元は省略)。一意なのは (host, name) なので、
      // 名前だけで CLI へ渡すと別の機械のエントリを手元で起こしてしまう
      readonly host?: string;
      readonly udid?: string;
      readonly serial?: string;
      readonly registered?: boolean;
    }
  // デバイスタイル右クリック「ライブ操作」: 独立ライブ操作パネル(livePanel.ts)を開いて id のデバイスを
  // 選択させる(受け手: monitorPanel.ts → registerMonitorPanel の openLiveForDevice)。
  | { readonly type: "openLiveForDevice"; readonly id: string }
  // 「GPUで再起動」: CPU 描画フォールバックを解除して host GPU で再起動する手動操作。
  // webview 側は CPU バッジ(renderMode==='cpu')の Android タイルでのみメニューに出す。
  | { readonly type: "deviceRestartGpu"; readonly name: string }
  // deviceRestartGpu の複数選択版(バッチ再起動)。names はタイル複数選択の対象デバイス名。
  | { readonly type: "devicesRestartGpu"; readonly names: readonly string[] }
  | { readonly type: "selectProfile"; readonly profile: string }
  // 実行プロファイルの追加/コピー/名前変更/削除(マシンプロファイルの追加/コピー/削除/名前変更と
  // 同じ構成)。コピー/名前変更/削除の対象 profile の空文字は「対象なし」として検証で弾く。
  | { readonly type: "profileAdd" }
  | { readonly type: "profileCopy"; readonly profile: string }
  | { readonly type: "profileRename"; readonly profile: string }
  | { readonly type: "profileDelete"; readonly profile: string }
  // マシンプロファイルの手動再取得リクエスト(machines/*.json の FileSystemWatcher とは別経路)。
  | { readonly type: "machineProfileRefresh" }
  // マシンプロファイル自体の追加/コピー/削除/名前変更。追加は対象を指さないため引数なし。
  // コピー/削除/名前変更の machine の空文字は profileCopy 等と同じ理由で不正として弾く。
  | { readonly type: "machineProfileAdd" }
  | { readonly type: "machineProfileCopy"; readonly machine: string }
  | { readonly type: "machineProfileDelete"; readonly machine: string }
  | { readonly type: "machineProfileRename"; readonly machine: string }
  // デバイス追加モーダルを開いた直後に送る、`ftester api device-catalog` の再取得リクエスト。
  // source: マシンプロファイルタブの「デバイス候補のホスト」セレクタの選択(§13 段2)。
  // remote なら monitorDeviceOps.ts が deviceCommandArgs で `remote exec <host> -- api device-catalog`
  // に組み立てる(docs/remote-runner.md §13「プロファイルのリモート対応」)。
  | { readonly type: "deviceCatalogRequest"; readonly source: DeviceCommandSource }
  // 同モーダルで Android のモデル一覧が空(errorCode: "avdmanager-missing")のときだけ出る
  // 導入ボタン。応答は installCmdlineToolsResult。cmdline-tools の導入はローカル専用
  // (ホストセレクタの対象外。リモートの avdmanager 導入はスコープ外)。
  | { readonly type: "installCmdlineToolsRequest" }
  // デバイス追加モーダルの OK クリック。全フィールドは空文字だと「未選択/未入力」を意味するため、
  // selectProfile と違い非空文字列を必須として検証する。
  | {
      readonly type: "createDevice";
      readonly machine: string;
      readonly platform: MonitorPlatform;
      readonly name: string;
      readonly model: string;
      readonly os: string;
      // true: 物理作成+即登録。false: 物理作成のみ(ホストが --no-register 付与)、登録は
      // #device-pick-overlay の「+」経由なら呼び出し側が machineDevicesSync で別途行う(OK 押下時に
      // 登録するため)。.profile-actions の「+新規作成」なら register:true を送る。
      // source が remote のときはホスト側が register の値によらず --no-register を強制する
      // (§13。リモート側のプロファイルは次回ディスパッチの rsync --delete で消えるため、
      // 正はローカル。作成した1台は #device-pick-overlay の再取得→チェック→OK[machineDevicesSync]
      // という既存の register:false 経路にそのまま乗せる)。
      readonly register: boolean;
      /** 同名の実体が既にあるとき、消してから作り直す(`api create-device --overwrite`)。
       * 破壊的なので webview では決めず、ホスト側のモーダル確認を通ってから true になる。 */
      readonly overwrite?: boolean;
      readonly source: DeviceCommandSource;
    }
  // 「デバイスを追加」左下の「バッチ作成」。names は webview が「デバイス名+連番2桁(01 始まり)」で
  // 組んだ完成形(ホストは組み立て直さない = 表示と作られる名前を必ず一致させる)。
  // overwriteNames は names のうち現ホストで衝突しているぶん(判定は webview 側 ――
  // 一覧を持っているのはあちら。ホストは「消して作り直してよいか」を聞くのに使う)。
  // register は送らない: このダイアログはピッカーからしか開かないので常に物理作成のみで、
  // 登録はピッカーの OK(machineDevicesSync)が行う。
  | {
      readonly type: "batchCreateDevices";
      readonly machine: string;
      readonly platform: MonitorPlatform;
      readonly names: readonly string[];
      readonly model: string;
      readonly os: string;
      readonly overwriteNames: readonly string[];
      readonly source: DeviceCommandSource;
    }
  // 「+既存から選択」モーダル(#device-pick-overlay)が開いた直後に送る、
  // `ftester api installed-devices` の再取得リクエスト(deviceCatalogRequest と同じ趣旨)。
  | { readonly type: "installedDevicesRequest"; readonly source: DeviceCommandSource }
  // 同モーダルの OK クリック。チェックボックスは「登録状態そのもの」を表すため、送るのは全件では
  // なく初期状態からの差分のみ: add は新たにチェックした(未登録だった)デバイス、remove は
  // チェックを外した(登録済みだった)デバイスのマシンプロファイル上の名前。add/remove は片方が
  // 空配列でもよいが、両方空は不正として弾く(webview は差分無しで OK を無効化する設計だが防御的に検証)。
  | {
      readonly type: "machineDevicesSync";
      readonly machine: string;
      readonly add: readonly MachineDeviceAddEntry[];
      readonly remove: readonly string[];
      /** OK 押下時点でダイアログ内ホスト選択(devicePickHost.js)が指していたホスト。add が非空かつ
       * remote のときだけ monitorProfileForms.ts がマシンプロファイルの host キーへ書き込む。 */
      readonly source: DeviceCommandSource;
    }
  // デバイス行の右クリック「削除」。devices は複数選択の一括削除に対応する配列(単一削除も1件配列)。
  // 空配列は「対象なし」として不正扱い。**参照は (host, name)**(host 省略=手元) —— 名前だけだと
  // 別の機械の同名デバイスまで巻き添えで消える。
  | {
      readonly type: "machineDeviceRemove";
      readonly machine: string;
      readonly devices: readonly { readonly name: string; readonly host?: string }[];
    }
  // #device-pick-overlay の行右クリック「削除」: マシンプロファイルからの除去(machineDeviceRemove)
  // とは別に、ホスト上の実体(シミュレータ/AVD)そのものを `ftester api delete-device` で消す。
  // identifier は iOS=udid/Android=avd id(実機行にはこのメニュー自体を出さない)。name は確認
  // ダイアログ・失敗表示に使う表示名。source は OK 押下時と同じダイアログ内ホスト選択。
  | {
      readonly type: "devicePickDeviceDelete";
      readonly platform: MonitorPlatform;
      readonly identifier: string;
      readonly name: string;
      readonly source: DeviceCommandSource;
    }
  // プロファイルタブ右ペインの編集フォーム「確定」。fields はクライアント側で trim 済み(空文字=
  // 未入力/対象外)。createDevice と違い machine/originalName 以外は空文字を許容する。
  | {
      readonly type: "machineDeviceUpdate";
      readonly machine: string;
      readonly platform: MonitorPlatform;
      readonly originalName: string;
      /** 対象が居る機械(省略=手元)。引き当ては (host, name) —— 名前だけだと別の機械の
       * 同名デバイスを書き換える。 */
      readonly host?: string;
      readonly fields: {
        readonly name: string;
        readonly simulator: string;
        readonly os: string;
        readonly udid: string;
        readonly port: string;
        readonly avd: string;
        /** Android 実機の adb シリアル。旧 webview は送らないため受信側で "" に補う。 */
        readonly serial: string;
      };
    }
  // 実行プロファイル設定フォームの選択変更・初回表示時のロード要求。profile の空文字は
  // profileCopy 等と同じ理由で不正として弾く。
  | { readonly type: "runProfileLoad"; readonly profile: string }
  // 同フォームの「確定」。fields はクライアント側 trim 済み(machineDeviceUpdate と同じ方針)。
  // machine/app はクライアント側で必須検証済みの想定だが、型検証自体は空文字も許容する。
  | {
      readonly type: "runProfileSave";
      readonly profile: string;
      readonly fields: RunProfileFormFields;
    }
  // 同フォーム「リモート制御」の「スクリプトの雛形を作成する」。workspace は**入力中の値**
  // (保存前でも画面に見えている場所へ作る)。空なら既定 TestProjects/<project>/workspace。
  | {
      readonly type: "runProfileHookScaffold";
      readonly profile: string;
      readonly workspace: string;
    }
  // プロファイルタブ中段: アプリプロファイル自体の追加/コピー/名前変更/削除(実行プロファイルの
  // profileAdd/profileCopy/profileRename/profileDelete と同じ構成。対象は profile で1件指す)。
  | { readonly type: "appProfileAdd" }
  | { readonly type: "appProfileCopy"; readonly profile: string }
  | { readonly type: "appProfileRename"; readonly profile: string }
  | { readonly type: "appProfileDelete"; readonly profile: string }
  // アプリプロファイル設定フォームのロード要求(runProfileLoad と同じ方針。profile の空文字は不正)。
  | { readonly type: "appProfileLoad"; readonly profile: string }
  // 同フォームの「確定」(runProfileSave と同じ方針)。アプリプロファイルは全フィールド省略可のため
  // 機械的な必須検証は無い。
  | {
      readonly type: "appProfileSave";
      readonly profile: string;
      readonly fields: AppProfileFormFields;
    }
  // 名前入力モーダル(#name-input-overlay)の OK/キャンセル。id は nameInputOpen で払い出したものを
  // そのまま返す(拡張側が pendingNameInput.id と突き合わせ、一致しなければ無視する)。
  | { readonly type: "nameInputConfirm"; readonly id: number; readonly name: string }
  | { readonly type: "nameInputCancel"; readonly id: number }
  // 設定タブの「ポーリングモードを使用する」チェックボックス変更(settingsTab.js)。true でストリーミングを
  // 止めてポーリングへ強制する(iOS/Android・ライブ操作パネル/デバイスタイル共通)。monitorPanel.ts が
  // workspaceState へ永続化し、対の "pollingMode" メッセージで即時反映する(livePanel.ts は
  // workspaceState を直接読むため、この即時反映の対象はデバイスタイルのみ)。
  | { readonly type: "setPollingMode"; readonly value: boolean }
  // 設定タブの表示言語セレクタ変更(settingsTab.js)。monitorPanel.ts が ftester.language 設定(Global)を
  // 更新する。反映は extension.ts の onDidChangeConfiguration ハンドラ(ツリー再翻訳 + 再読み込み案内)。
  | { readonly type: "setLanguage"; readonly value: "auto" | "ja" | "en" }
  // 設定タブのリモート実行セクション変更(settingsTab.js)。monitorPanel.ts が CLI のホスト登録簿と
  // ftester.remote.artifacts 設定(Global)を更新する。hosts は正規化済みの想定だが検証は型のみ。
  // artifacts は remoteConfig と同じ相乗り。
  | {
      readonly type: "setRemoteConfig";
      readonly hosts: readonly RemoteHostEntry[];
      readonly artifacts: "collect" | "on-demand";
    }
  // 設定タブ「更新」の「更新を確認」ボタン(settingsTab.js)。monitorPanel.ts が update-check.sh を実行する。
  | { readonly type: "checkUpdate" }
  // 設定タブ「更新」の「更新する」ボタン。monitorPanel.ts が update.sh を実行し、出力は OUTPUT へ出す。
  | { readonly type: "runUpdate" }
  // LPT 投入順の切替(webview→拡張)。ホストは ftester.lptScheduling 設定を更新し、
  // run 時に false なら ftester api run へ --no-lpt を渡す(src/runHandler.ts)
  | { readonly type: "setLptScheduling"; readonly value: boolean }
  // null = 既定へ戻す(入力欄を空にした場合)
  | { readonly type: "setLptHistoryRuns"; readonly value: number | null }
  | { readonly type: "refreshResidentProcesses" }
  // タブ切替でデバイスタイルが display:none になったことの通知。ホストは配信helperを止める
  // (対向: src/webview/monitor/tabs.js の switchTab)。パネル自体の表示可否とは別軸で、
  // ホスト側は両方の AND を deviceStream.setVisible へ渡す
  | { readonly type: "devicesTabVisible"; readonly visible: boolean }
  // 常駐プロセス(モニター/host-metrics/配信・ブリッジ・workspace 由来の残余)を掃討したあと、
  // 再起動せずにモニターパネル(タブ)を閉じる。確認ダイアログは出さず即実行。応答は返さない
  // (成功時は webview ごと消える。掃討の失敗はホスト側の showErrorMessage で通知しつつ閉じる)
  | { readonly type: "killAllResidentProcessesAndClose" }
  // デバイスタブのスプリッターをドラッグ終了した時のタイルペイン高さ(px)。monitorPanel.ts が
  // workspaceState へ永続化し、パネル再作成時に "tilePaneHeight" メッセージで復元する。
  | { readonly type: "setTilePaneHeight"; readonly value: number }
  // auto-fit トグルの切替(ボタン押下・手動ドラッグによる自動 OFF)。monitorPanel.ts が
  // workspaceState へ永続化し、パネル再作成時に "tileAutoFit" メッセージで復元する。
  | { readonly type: "setTileAutoFit"; readonly value: boolean }
  // webview 側 WebCodecs が未対応/デコード失敗したときに1回送られてくる(受け手: monitorPanel.ts の
  // codecError ハンドラ→monitorDeviceStreamController.fallbackToMjpeg/monitorLiveController.fallbackToMjpeg)。
  // scope="tile" は device 必須(対象タイルを1つ特定するため)、scope="live" は選択中デバイスに
  // 一律適用するため device 不要。
  | { readonly type: "codecError"; readonly scope: "tile" | "live"; readonly device?: string }
  // webview がストリーム由来フレーム(h264 デコード成功 or stream:true の mjpeg)を描画できた ack
  // (deviceTiles.js が2秒スロットリングで送る)。受け手: monitorPanel.ts →
  // monitorDeviceStreamController.noteStreamRendered。これが届くまでポーリングは間引かれない
  | { readonly type: "streamRendered"; readonly device: string }
  // キーフレーム未受信のままデルタチャンクが流れ続けている(初期キーフレームの取り逃し)。受け手:
  // monitorPanel.ts。scope="tile"(既定・device 必須)→ monitorDeviceStreamController.restartDevice、
  // scope="live"(選択中デバイス一律・device 不要)→ monitorLiveController.restartStream。
  // どちらもヘルパー再起動で新キーフレームを得る。
  | { readonly type: "streamStall"; readonly scope?: "tile" | "live"; readonly device?: string }
  // ---- 録画タブ ---------------------------------------------------------------------------
  | { readonly type: "recordingsRefresh" }
  | { readonly type: "recordingsOpen"; readonly project: string; readonly runID: string };

/**
 * machineDevicesSync の add[] 1件(MachineDeviceAddEntry)の検証。name の空文字は不正。
 * simulator/os/udid/avd は省略可(machineDeviceUpdate の fields と違い空文字は無意味なため
 * undefined か非空 string のみ許容)。
 */
function isMachineDeviceAddEntryLike(value: unknown): value is MachineDeviceAddEntry {
  return (
    isRecord(value) &&
    (value.platform === "ios" || value.platform === "android") &&
    typeof value.name === "string" &&
    value.name !== "" &&
    (value.simulator === undefined || typeof value.simulator === "string") &&
    (value.os === undefined || typeof value.os === "string") &&
    (value.udid === undefined || typeof value.udid === "string") &&
    (value.avd === undefined || typeof value.avd === "string") &&
    (value.serial === undefined || typeof value.serial === "string") &&
    (value.model === undefined || typeof value.model === "string") &&
    (value.kind === undefined || value.kind === "virtual" || value.kind === "physical")
  );
}

/** deviceCatalogRequest/installedDevicesRequest/createDevice の source(§13 段2)の検証。
 * remote は host が非空文字列であること(空文字は `remote exec` に渡せない不正値)。 */
function isDeviceCommandSourceLike(value: unknown): value is DeviceCommandSource {
  return (
    isRecord(value) &&
    (value.kind === "local" || (value.kind === "remote" && typeof value.host === "string" && value.host !== ""))
  );
}

/** setRemoteConfig の hosts[] 1件の検証(webview 側は既に正規化済みの値を送る想定だが、
 * 型不正なペイロードを弾くための最終ゲート)。machine は settingsTab.js が remoteConfig 受信時の
 * 値をパススルーするだけの隠しフィールド(UI に入力欄は無い)なので、無い(旧版 webview 由来)
 * ときも通す — 無いと "" 扱いになるだけで、無くても壊れない形にしておく。 */
function isRemoteHostEntryLike(value: unknown): value is RemoteHostEntry {
  return (
    isRecord(value) &&
    typeof value.name === "string" &&
    typeof value.host === "string" &&
    typeof value.dir === "string" &&
    (value.machine === undefined || typeof value.machine === "string")
  );
}

/** アプリプロファイル common セクション(自動インストールのみ。表示名は ios/android のそれぞれで
 * 持ち common からは継承しない)の検証。autoInstall は common に一本化されているため
 * "true"/"false" の2値のみ受理する。 */
function isAppProfileCommonFieldsLike(value: unknown): value is AppProfileCommonFields {
  return isRecord(value) && (value.autoInstall === "true" || value.autoInstall === "false");
}

/** アプリプロファイル ios/android セクション(3項目)の検証。autoInstall は common 側で検証する。 */
function isAppProfilePlatformFieldsLike(value: unknown): value is AppProfilePlatformFields {
  return (
    isRecord(value) &&
    typeof value.appName === "string" &&
    typeof value.app === "string" &&
    typeof value.appPath === "string"
  );
}

/** webview からの postMessage 値を MonitorFromWebviewMessage として扱ってよいか判定する。 */
export function isMonitorFromWebviewMessage(value: unknown): value is MonitorFromWebviewMessage {
  if (!isRecord(value) || typeof value.type !== "string") {
    return false;
  }
  switch (value.type) {
    case "ready":
    case "devicesUpCancel":
    case "devicesDown":
    case "restartMonitor":
    case "profileAdd":
      return true;
    case "devicesUp":
      return (
        value.restartNames === undefined ||
        (Array.isArray(value.restartNames) &&
          value.restartNames.every((n) => typeof n === "string" && n !== ""))
      );
    case "deviceOp":
      return (
        typeof value.name === "string" &&
        (value.op === "up" || value.op === "down") &&
        (value.host === undefined || (typeof value.host === "string" && value.host !== "")) &&
        (value.udid === undefined || typeof value.udid === "string") &&
        (value.serial === undefined || typeof value.serial === "string") &&
        (value.registered === undefined || typeof value.registered === "boolean")
      );
    case "openLiveForDevice":
      return typeof value.id === "string" && value.id !== "";
    case "deviceRestartGpu":
      return typeof value.name === "string" && value.name !== "";
    case "devicesRestartGpu":
      return (
        Array.isArray(value.names) &&
        value.names.length > 0 &&
        value.names.every((n) => typeof n === "string" && n !== "")
      );
    case "selectProfile":
      return typeof value.profile === "string";
    case "profileCopy":
    case "profileRename":
    case "profileDelete":
      return typeof value.profile === "string" && value.profile !== "";
    case "machineProfileRefresh":
    case "installCmdlineToolsRequest":
    case "machineProfileAdd":
      return true;
    case "deviceCatalogRequest":
    case "installedDevicesRequest":
      return isDeviceCommandSourceLike(value.source);
    case "machineProfileCopy":
    case "machineProfileDelete":
    case "machineProfileRename":
      return typeof value.machine === "string" && value.machine !== "";
    case "createDevice":
      return (
        typeof value.machine === "string" &&
        value.machine !== "" &&
        (value.platform === "ios" || value.platform === "android") &&
        typeof value.name === "string" &&
        value.name !== "" &&
        typeof value.model === "string" &&
        value.model !== "" &&
        typeof value.os === "string" &&
        value.os !== "" &&
        typeof value.register === "boolean" &&
        isDeviceCommandSourceLike(value.source)
      );
    case "batchCreateDevices":
      return (
        typeof value.machine === "string" &&
        value.machine !== "" &&
        (value.platform === "ios" || value.platform === "android") &&
        Array.isArray(value.names) &&
        value.names.length > 0 &&
        value.names.length <= 99 &&
        value.names.every((name) => typeof name === "string" && name !== "") &&
        typeof value.model === "string" &&
        value.model !== "" &&
        typeof value.os === "string" &&
        value.os !== "" &&
        Array.isArray(value.overwriteNames) &&
        value.overwriteNames.every((name) => typeof name === "string" && name !== "") &&
        isDeviceCommandSourceLike(value.source)
      );
    case "machineDevicesSync":
      return (
        typeof value.machine === "string" &&
        value.machine !== "" &&
        Array.isArray(value.add) &&
        value.add.every(isMachineDeviceAddEntryLike) &&
        Array.isArray(value.remove) &&
        value.remove.every((name) => typeof name === "string" && name !== "") &&
        (value.add.length > 0 || value.remove.length > 0) &&
        isDeviceCommandSourceLike(value.source)
      );
    case "machineDeviceRemove":
      return (
        typeof value.machine === "string" &&
        value.machine !== "" &&
        Array.isArray(value.devices) &&
        value.devices.length > 0 &&
        value.devices.every(
          (device) =>
            isRecord(device) &&
            typeof device.name === "string" &&
            device.name !== "" &&
            (device.host === undefined || (typeof device.host === "string" && device.host !== "")),
        )
      );
    case "devicePickDeviceDelete":
      return (
        (value.platform === "ios" || value.platform === "android") &&
        typeof value.identifier === "string" &&
        value.identifier !== "" &&
        typeof value.name === "string" &&
        value.name !== "" &&
        isDeviceCommandSourceLike(value.source)
      );
    case "machineDeviceUpdate":
      return (
        typeof value.machine === "string" &&
        value.machine !== "" &&
        (value.platform === "ios" || value.platform === "android") &&
        typeof value.originalName === "string" &&
        value.originalName !== "" &&
        (value.host === undefined || (typeof value.host === "string" && value.host !== "")) &&
        isRecord(value.fields) &&
        typeof value.fields.name === "string" &&
        typeof value.fields.simulator === "string" &&
        typeof value.fields.os === "string" &&
        typeof value.fields.udid === "string" &&
        typeof value.fields.port === "string" &&
        typeof value.fields.avd === "string" &&
        // serial は後から追加したフィールド。欠落は "" に補う(旧 webview との混在を弾かない)
        (value.fields.serial === undefined
          ? ((value.fields as Record<string, unknown>).serial = "") === ""
          : typeof value.fields.serial === "string")
      );
    case "runProfileLoad":
      return typeof value.profile === "string" && value.profile !== "";
    case "runProfileHookScaffold":
      return (
        typeof value.profile === "string" && value.profile !== "" && typeof value.workspace === "string"
      );
    case "runProfileSave":
      return (
        typeof value.profile === "string" &&
        value.profile !== "" &&
        isRecord(value.fields) &&
        typeof value.fields.machine === "string" &&
        typeof value.fields.app === "string" &&
        Array.isArray(value.fields.devices) &&
        // 参照は { name, host? }(一意なのは (host, name))。**文字列だった頃の形は受け取らない** ——
        // 素通しすると host の無い参照として保存され、同名が別ホストに居ると run で曖昧になる
        value.fields.devices.every(
          (ref) =>
            isRecord(ref) &&
            typeof ref.name === "string" &&
            (ref.host === undefined || typeof ref.host === "string"),
        ) &&
        typeof value.fields.fm === "boolean" &&
        typeof value.fields.heal === "boolean" &&
        typeof value.fields.falsePositiveCheck === "boolean" &&
        typeof value.fields.screenLooksLike === "boolean" &&
        typeof value.fields.containerInference === "boolean" &&
        typeof value.fields.iosInappEngine === "boolean" &&
        typeof value.fields.iosFastInput === "boolean" &&
        typeof value.fields.homeOnStart === "boolean" &&
        typeof value.fields.enableAnimations === "boolean" &&
        typeof value.fields.reportDir === "string" &&
        typeof value.fields.defaultTimeout === "string" &&
        typeof value.fields.wipeDataOnBloat === "boolean" &&
        typeof value.fields.wipeDataThresholdGB === "string" &&
        typeof value.fields.recoverCpuFallbackToGpu === "boolean" &&
        typeof value.fields.locale === "string" &&
        typeof value.fields.record === "boolean" &&
        typeof value.fields.recordFailuresOnly === "boolean" &&
        typeof value.fields.recordBitrateKbps === "string" &&
        typeof value.fields.recordFullResolution === "boolean"
      );
    case "appProfileAdd":
      return true;
    case "appProfileCopy":
    case "appProfileRename":
    case "appProfileDelete":
      return typeof value.profile === "string" && value.profile !== "";
    case "appProfileLoad":
      return typeof value.profile === "string" && value.profile !== "";
    case "appProfileSave":
      return (
        typeof value.profile === "string" &&
        value.profile !== "" &&
        isRecord(value.fields) &&
        isAppProfileCommonFieldsLike(value.fields.common) &&
        isAppProfilePlatformFieldsLike(value.fields.ios) &&
        isAppProfilePlatformFieldsLike(value.fields.android)
      );
    case "nameInputConfirm":
      return typeof value.id === "number" && typeof value.name === "string";
    case "nameInputCancel":
      return typeof value.id === "number";
    case "setPollingMode":
      return typeof value.value === "boolean";
    case "setLanguage":
      return value.value === "auto" || value.value === "ja" || value.value === "en";
    case "setRemoteConfig":
      return (
        Array.isArray(value.hosts) &&
        value.hosts.every(isRemoteHostEntryLike) &&
        (value.artifacts === "collect" || value.artifacts === "on-demand")
      );
    case "devicesTabVisible":
      return typeof value.visible === "boolean";
    case "setLptScheduling":
      return typeof value.value === "boolean";
    case "setLptHistoryRuns":
      // 0 や負値・小数を通すと走査件数が壊れる(CLI 側でも 1 に丸めるが、ここで弾く)
      return (
        value.value === null ||
        (typeof value.value === "number" && Number.isInteger(value.value) && value.value >= 1)
      );
    case "refreshResidentProcesses":
    case "killAllResidentProcessesAndClose":
    case "checkUpdate":
    case "runUpdate":
      return true;
    case "setTilePaneHeight":
      return typeof value.value === "number" && value.value > 0;
    case "setTileAutoFit":
      return typeof value.value === "boolean";
    case "codecError":
      return (
        (value.scope === "tile" || value.scope === "live") &&
        (value.device === undefined || typeof value.device === "string") &&
        (value.scope !== "tile" || typeof value.device === "string")
      );
    case "streamRendered":
      return typeof value.device === "string" && value.device !== "";
    case "streamStall":
      // scope="live" は device 不要(選択中デバイスに一律)。それ以外(tile/未指定)は device 必須
      return value.scope === "live" || (typeof value.device === "string" && value.device !== "");
    case "recordingsRefresh":
      return true;
    case "recordingsOpen":
      return typeof value.project === "string" && value.project !== "" && typeof value.runID === "string" && value.runID !== "";
    default:
      return false;
  }
}
