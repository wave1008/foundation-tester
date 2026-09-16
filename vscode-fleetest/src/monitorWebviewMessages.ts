// monitorWebviewMessages.ts
// extension ⇔ webview 間の postMessage 契約(型付き)と、その検証・変換の純粋関数群。
// vscode に依存しない(monitorPanel.ts と test/monitorModel.test.mjs の両方から使うため)。
// デバイス・NDJSON イベントの型は monitorDeviceModel.ts、デバイスライフサイクル操作の型は
// monitorDeviceLifecycle.ts、プロファイルフォーム/デバイスカタログの型は monitorProfileForms.ts
// にあり、メッセージ型はそれらを組み合わせて定義する。

import type { MonitorDeviceFilter } from "./config";
import type { DashboardFromWebviewMessage, DashboardToWebviewMessage } from "./dashboardModel";
import { isDashboardFromWebviewMessage } from "./dashboardModel";
import type {
  RecordingErrorEntry,
  RecordingScenarioDevice,
  RecordingScenarioVideo,
  RecordingTreeClass,
} from "./recordingsModel";
import type { RecordingSessionSummary } from "./recordingsStore";
import type { DeviceCommandSource, MachineColor, RemoteHostEntry } from "./remoteRunArgs";
import { isRetentionPatch, type RetentionPatch, type RetentionUsage, type RetentionValues } from "./retentionModel";
import type { ResidentProcess } from "./residentProcesses";
import { isRecord, type MonitorDevice, type MonitorEvent, type MonitorPlatform } from "./monitorDeviceModel";
import type { DeviceOpKind, DeviceOpQueueStatus } from "./monitorDeviceLifecycle";
import type {
  AppProfileCommonFields,
  AppProfileFormFields,
  AppProfileIOSFields,
  AppProfilePlatformFields,
  DeviceCatalog,
  InstalledDevices,
  RunProfileDeviceAddEntry,
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
  // GUI 実行(Test Explorer / 「テスト実行」タブの「テスト実行」)の進行。true の間だけツールバーの
  // 対象選択と一括操作を畳み、「テスト実行」を中断ボタンに変える(対向: deviceTiles.js の
  // applyTestRunActive)。**出所は RunEventBus の runStarted/runEnded**なので、誰が起こした
  // 実行でも同じ扱いになる。
  | { readonly type: "testRunActive"; readonly active: boolean }
  | { readonly type: "processDown"; readonly message: string }
  | {
      readonly type: "deviceOpBusy";
      readonly name: string;
      /** そのデバイスが居る機械(手元は undefined)。名前だけでは同名の別タイルを触りうる。 */
      readonly machine?: string;
      readonly op: DeviceOpKind | null;
      /** キュー内での状態("running"=実行中／"queued"=順番待ち)。op が null のときは null。 */
      readonly status: DeviceOpQueueStatus | null;
    }
  // machine も載せる —— 落とすとリモートの失敗が**同名の手元タイル**の状態を戻す
  // (deviceOpBusy と同じ理由)
  | { readonly type: "deviceOpFailed"; readonly name: string; readonly machine?: string;
      readonly message: string }
  // 一括 down(api stop-all-devices)で1台停止完了ごとに送る。webview はそのタイルを即「未起動」へ倒す
  // (down 中はモニター pause で state 更新が来ないため、落ちた順の反映をこの per-device 通知で行う。
  //  次の devices 反映=resume 後に本物の state で上書きされる)。name は deviceOpBusy と同じ名前空間。
  | { readonly type: "deviceDownFinished"; readonly name: string; readonly machine?: string }
  | {
      readonly type: "profileInfo";
      /** TestProjects/ 直下のテストプロジェクト名一覧(「テスト実行」タブのプロジェクト選択が使う)。 */
      readonly projects: readonly string[];
      /** 対象プロジェクトの実行プロファイル名一覧(TestProjects/<project>/profiles/runs/ 直下)。 */
      readonly profiles: readonly string[];
      /** 現在の fleetest.profile 設定値。"" はプロファイルなし。 */
      readonly current: string;
      /** 現在の fleetest.monitorDeviceFilter 設定値。"running" のときドロップダウンの選択は
       * current("")ではなく RUNNING_DEVICES_PROFILE_VALUE を選ぶ。 */
      readonly filter: MonitorDeviceFilter;
      /** 対象プロジェクトのアプリプロファイル名一覧(profiles/apps/ 直下)。既存の applyProfileInfo は
       * このフィールドを無視するだけなので後方互換。 */
      readonly apps: readonly string[];
      /** 対象プロジェクト名(解決できなければ "")。ワークスペース欄の既定値
       * "TestProjects/<project>/workspace" を透かしで出すのに使う(相対パスはリポジトリルート
       * 基準なので、この文字列はそのまま入力しても既定と同じ場所を指す)。 */
      readonly project: string;
      /** 対象プロジェクトのディレクトリ(ワークスペースルート基準の相対パス。解決できなければ "")。
       * プロファイルタブの「プロジェクトディレクトリ」欄が参照専用で出すだけで、入力としては使わない。 */
      readonly projectDir: string;
      /** プロジェクトのデバイスカタログ(config.ts の listProjectDeviceCatalog。全実行プロファイルの
       * devices[] の和集合、enabled:false のものも含む)。実行プロファイルの devices 節の
       * チェックボックス一覧・「デバイスを追加」の重複判定・「未登録」バッジの判定に使う。 */
      readonly devices: readonly {
        readonly name: string;
        readonly platform: MonitorPlatform;
        /** このデバイスが居る機械(undefined=手元)。**一意なのは (platform, machine, name)**
         * (Sources/FTCore/DeviceMachineGrouping.swift)。 */
        readonly machine?: string;
        /** 一覧2行目の表示文字列(machineDeviceDetail で組み立て済み)。 */
        readonly detail: string;
        // 右ペインの詳細表示用の生フィールド(MachineDeviceEntry と同形)。undefined は
        // postMessage の JSON 化で自然に省略される。
        readonly osVersion?: string;
        readonly udid?: string;
        readonly port?: number;
        readonly avd?: string;
        /** 実機なら "physical"(一覧・詳細表示のバッジ表示に使う)。省略=virtual。 */
        readonly kind?: "virtual" | "physical";
        readonly serial?: string;
        readonly model?: string;
      }[];
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
  // 「デバイスを追加」でシステムイメージを導入してから作るときの進み具合(スピナーの文言を切り替える)。
  // installing はライセンス確認に同意した後にだけ送る —— 確認待ちの間に「ダウンロード中」と出さない。
  // 終わりは createDeviceResult / batchCreateStarted / batchCreateFinished が兼ねる
  | {
      readonly type: "deviceAddProgress";
      readonly phase: "installing" | "creating";
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
  // #device-pick-overlay の OK(runProfileDevicesSync)への応答。added は追記できた件数
  // (サフィックス適用後)。ok:true ならモーダルは閉じ、一覧は直後の profileInfo 再送で最新化される。
  | {
      readonly type: "runProfileDevicesSyncResult";
      readonly ok: boolean;
      readonly added: number;
      readonly error: string | null;
    }
  // ---- プロファイルタブ下半分: 実行プロファイルの設定フォーム ---------------------------
  // profileAdd/Copy/Rename 直後に選択を新プロファイルへ移す通知。
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
  // 設定タブのスケジューリング section。fleetest.lptScheduling の現在値(拡張→webview)
  | { readonly type: "lptScheduling"; readonly value: boolean }
  // LPT の実績走査 run 数。default は設定タブの初期値・空欄時の戻り先に使う
  | { readonly type: "lptHistoryRuns"; readonly value: number; readonly default: number }
  // 設定タブの表示言語セレクタ(#settings-language)の現在値(fleetest.language 設定の生値)。ready 直後に
  // 送る。webview 側は settingsTab.js の applySettings。切替は setLanguage と対。
  | { readonly type: "language"; readonly value: "auto" | "ja" | "en" }
  // 設定タブのリモート実行セクション(CLI のホスト登録簿)。ready 直後に送る。
  // webview 側は settingsTab.js の applySettings。変更は setRemoteConfig と対(docs/remote-runner.md §12)。
  | {
      readonly type: "remoteConfig";
      readonly hosts: readonly RemoteHostEntry[];
      /** 未設定時の FM 枠(CLI 側 FMLock.defaultConcurrency)。ウォーターマークに出すだけ。
       *  **拡張はこの数を持たない** —— 二重管理にすると片方だけ変わったときに嘘を表示する */
      readonly defaultFMConcurrency?: number;
      /** この機械の固定行(消せない。FM 枠だけ編集できる)。settingsTab.js が先頭に描く */
      readonly local?: { readonly machine: "local"; readonly host: string; readonly fmConcurrency: number };
      /** バッジ色パレット(表示順 = 配列順)。**拡張は色の一覧を持たない** —— CLI からそのまま配る。
       *  古い CLI(欠落)では undefined = settingsTab.js/machineColors.js が色機能を黙って無効にする。 */
      readonly machineColors?: readonly MachineColor[];
      /** 直前の setRemoteConfig(追加・削除)が CLI 側で失敗したときの理由。settingsTab.js が
       * 画面に出す。成功時・ready 直後の初回配信では undefined。 */
      readonly error?: string;
    }
  // 設定タブのマシン表の削除の確認結果(requestRemoveRemoteHost への応答。確認されたときだけ送る)。
  // webview 側は settingsTab.js の removeHostRow。rowId は webview の使い捨ての行 id
  | { readonly type: "remoteHostRemoveConfirmed"; readonly rowId: number }
  // 設定タブ「更新」セクションの状態。パネル ready 直後と checkUpdate/runUpdate の前後に送る。
  // 判定そのものは Scripts/update-check.sh(拡張は解釈するだけ)。対向: settingsTab.js の applyUpdate。
  // **実行ログは webview に送らない**(VSCode の OUTPUT へ出す。monitorUpdateController.ts 冒頭)。
  | { readonly type: "updateStatus"; readonly state: string; readonly localHead: string;
      readonly remoteHead: string; readonly reason: string }
  // 設定タブ「ログ・録画」のクリーンアップ欄。保持ポリシーの正は CLI 側のマシン設定
  // (`fleetest api retention`)で、**拡張は既定値を持たない** —— policy(実効値)・defaults・
  // usage はすべて CLI が返したものをそのまま配る(FM 枠と同じ規律)。ready 直後と
  // setRetention/runCleanup の応答で送る。対向: settingsTab.js の applyRetention。
  // policy が無い(= コマンドを持たない古い CLI・読みの失敗)ときは error だけを載せる ——
  // webview はセクションを無効表示にして理由を出す。
  | {
      readonly type: "retention";
      readonly policy?: RetentionValues;
      readonly defaults?: RetentionValues;
      readonly usage?: RetentionUsage;
      readonly error?: string;
      /** 「今すぐクリーンアップ」の進行と結果。掃除を伴わない配信では undefined。
       *  freedBytes は dry-run では「消える合計」、実行では「消した合計」 */
      readonly cleanup?: {
        readonly state: "running" | "done" | "cancelled" | "failed";
        readonly dryRun?: boolean;
        readonly freedBytes?: number;
        readonly error?: string;
      };
    }
  // プロセスタブ「常駐プロセス」一覧。refreshResidentProcesses 受信時に送る。
  // 対向: processesTab.js の applyResidentMessage。
  | { readonly type: "residentProcesses"; readonly items: readonly ResidentProcess[]; readonly ts: number }
  // 「テスト実行」タブのスプリッター位置(タイルペイン高さ px)。ready 直後に workspaceState の永続値を反映する。
  // webview の getState はパネルを閉じると失われるため host 側で永続化する(setTilePaneHeight と対の契約)。
  // webview 側は splitter.js の setTilePaneHeight へ渡す。
  | { readonly type: "tilePaneHeight"; readonly value: number }
  // 「テスト実行」タブの auto-fit トグルの状態(true = 全デバイスが横幅に収まる高さへ自動調整)。
  // 永続化の理由と経路は tilePaneHeight と同じ(setTileAutoFit と対の契約)。
  | { readonly type: "tileAutoFit"; readonly value: boolean }
  // 「テスト実行」タブの全選択トグルの状態(true = 全デバイス選択)。永続化の理由と経路は
  // tileAutoFit と同じ(setSelectAllDevices と対の契約)。**0枚でも復元する** ——
  // ready 直後はモニターがまだ台を出しておらず、出てきた台を webview 側が選び直す。
  | { readonly type: "selectAllDevices"; readonly value: boolean }
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
  // Wipe Data の進行状況。出どころは2つで phase の集合は共通:
  //   `fleetest api run` の自動 Wipe(model.ts の WipeStatusEvent が NDJSON 契約の同期相手)
  //   手動の `fleetest api wipe-device`(monitorDeviceLifecycle.ts の DeviceOpWipeStatusEvent)
  // name は deviceOpBusy と同じ名前空間(デバイス論理名)。webview はタイルのバッジ表示に使う。
  // machine はそのデバイスが居る機械(省略=手元)。**手動 Wipe は必ず載せる** —— 名前だけだと
  // webview が同名の手元タイルを書き換える(deviceOpBusy と同じ理由)。
  | {
      readonly type: "wipeStatus";
      readonly name: string;
      readonly machine?: string;
      readonly phase: "stopping" | "rebooting" | "done" | "failed";
    }
  // ---- 録画タブ ---------------------------------------------------------------------------
  // セッション一覧(recordingsStore.ts が TestProjects/<current>/results/runs/*/*/recordings/index.json を
  // 列挙。新しい順・最大50件)。recordingsRefresh 受信時に post する。projects/current はプロジェクト
  // 選択の中身(ダッシュボードの "projects" と同じ意味。current "" = 未解決で sessions は空)。
  // all = 「(すべて)」選択中(全プロジェクト横断。current は fleetest.project の解決結果のまま)
  | {
      readonly type: "recordingsSessions";
      readonly sessions: readonly RecordingSessionSummary[];
      readonly projects: readonly string[];
      readonly current: string;
      readonly all: boolean;
    }
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
      // 実行マシン名(run.json の machine。読めなければ null)と、scenarioID ごとの実行デバイス
      // (index.json の worker/platform 由来。ok:false のときは null)。
      // **束ねたセッション**(runGroup を共有する run。docs/results-json.md)では machines に
      // 全マシンが入り、machine はその代表(先頭の run のもの)。
      readonly machine: string | null;
      readonly machines: readonly string[] | null;
      readonly devices: readonly RecordingScenarioDevice[] | null;
      // recordings/index.json の同名フィールド(RecordingSessionSummary と同じ意味・寛容さ)。videos が
      // 空/一部欠落のとき、webview の再生ビューが理由を出すのに使う。省略時は webview 側が「無い」
      // として扱う(旧ホスト実装との互換)。
      readonly clipsAttempted?: number | null;
      readonly clipsFailed?: number | null;
      /** 録画ソースが1本も使えなかったワーカー数(録画が全滅した run を「録画していない run」と
       *  取り違えないための欄。Sources/FTCore/RecordingIndex.swift の sourcesFailed と同期)。 */
      readonly sourcesFailed?: number | null;
      readonly encoderFallback?: boolean;
      // true = recordingsOpen への応答ではなく run 完了時の自動表示(monitorRecordingsController.ts の
      // revealRun。ok:true のときだけ来る)。webview は「テスト実行」タブ表示中だけ録画タブへ切り替えて
      // 開き、それ以外のタブでは捨てる(main.js の recordingsSession)
      readonly reveal?: boolean;
    }
  // 「テスト実行」ボタン右の「録画を編集中」表示(monitorPanel.ts の setRecordingsFinalizing)。
  // 対向: src/webview/monitor/main.js の recordingsFinalizing
  | { readonly type: "recordingsFinalizing"; readonly active: boolean }
  // ---- ダッシュボードタブ -------------------------------------------------------------------
  // 「結果ダッシュボード」タブ(旧 dashboardPanel.ts)向けの封筒。dashboardModel.ts の
  // DashboardToWebviewMessage/DashboardFromWebviewMessage 自体はモニターへの統合前と不変
  // (webview→host の ready/refresh 等がモニター既存の同名メッセージと衝突するため、
  // "dashboard" 型の封筒に包んで送る。monitorPanel.ts → monitorDashboardController.ts、
  // webview 側は src/webview/monitor/dashboardTab.js の handleDashboardMessage)。
  | { readonly type: "dashboard"; readonly message: DashboardToWebviewMessage };

/** 検証済みの MonitorEvent を、webview へそのまま postMessage できる形に変換する。 */
// monitorHold は webview へ送らない(monitorProcessManager.ts が OUTPUT ログで処理して return する)
// ため、ここでは型から除外して switch の網羅性を保つ
export function toWebviewMessage(
  // monitorHold / monitorLock は webview へ素通ししない(前者は OUTPUT だけ、後者は
  // monitorProcessManager が machineLock メッセージへ畳む)。**Exclude で受け取らない形にする**
  // = 呼び出し側が畳み忘れたらコンパイルで止まる
  event: Exclude<MonitorEvent, { kind: "monitorHold" } | { kind: "monitorLock" }>,
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
  // 未起動機のブートと同一キューで2台ずつ並行処理される(start-all-devices --restart。DeviceBooter.bootAll)。
  | { readonly type: "devicesUp"; readonly restartNames?: readonly string[] }
  // 「デバイスの起動を中断」: 実行中の bulk up プロセスを停止/キュー待ちの bulk up を除去する。
  | { readonly type: "devicesUpCancel" }
  | { readonly type: "devicesDown" }
  | { readonly type: "restartMonitor" }
  // ツールバーの「テスト実行」: Test Explorer を前面に出して全シナリオを走らせる
  // (受け手: monitorPanel.ts → コマンド fleetest.runAllTests = runHandler.ts)。
  // 押せるのは実体のある実行プロファイルが選ばれている間だけ(判定は webview 側)。
  | { readonly type: "runTests" }
  // 「テストを中断」: 実行中の GUI 実行を止める(受け手: monitorPanel.ts → コマンド
  // fleetest.cancelTestRun = runHandler.ts)。押せるのは testRunActive の間だけ。
  | { readonly type: "cancelTests" }
  // エラーバナーの「コピー」: text をホスト側で vscode.env.clipboard へ書く(webview の
  // navigator.clipboard はフォーカス条件で失敗しうる)。対向: deviceTiles.js showBanner
  | { readonly type: "copyText"; readonly text: string }
  // udid/serial/registered: 未登録(どの実行プロファイルにも記載の無い)デバイスの直指定用。registered:false の
  // ときだけ deviceTiles.js が iOS udid / Android serial のどちらかを載せる(--name で引けないため)。
  // 対向: monitorDeviceOps.ts executeDeviceOpJob(stop-device --udid/--serial の直指定モード)。
  | {
      readonly type: "deviceOp";
      readonly name: string;
      // タイルが撃つのは起動/停止だけ(Wipe Data はプロファイルタブの runProfileDeviceWipe)。
      // 型でも絞る = 検証(isMonitorFromWebviewMessage)と同じ集合にする
      readonly op: "up" | "down";
      // machine: そのデバイスが居る機械(手元は省略)。一意なのは (machine, name) なので、
      // 名前だけで CLI へ渡すと別の機械のエントリを手元で起こしてしまう
      readonly machine?: string;
      readonly udid?: string;
      readonly serial?: string;
      readonly registered?: boolean;
    }
  // デバイスタイル右クリック「ライブ操作」: 独立ライブ操作パネル(livePanel.ts)を開いて id のデバイスを
  // 選択させる(受け手: monitorPanel.ts → registerMonitorPanel の openLiveForDevice)。
  | { readonly type: "openLiveForDevice"; readonly id: string }
  // 「GPUで再起動」: CPU 描画フォールバックを解除して host GPU で再起動する手動操作。
  // webview 側は CPU バッジ(renderMode==='cpu')の Android タイルでのみメニューに出す。
  // machine: そのデバイスが居る機械(手元は省略)。**名前だけで受けない** —— リモートの
  // タイルから撃つと手元の同名の台を再起動する(deviceOp と同じ規律。monitorDeviceOps.ts が
  // machine 付きはその機械の down→up へ回す)
  | { readonly type: "deviceRestartGpu"; readonly name: string; readonly machine?: string }
  // deviceRestartGpu の複数選択版(バッチ再起動)。devices はタイル複数選択の対象(machine 付き)。
  | {
      readonly type: "devicesRestartGpu";
      readonly devices: readonly { readonly name: string; readonly machine?: string }[];
    }
  | { readonly type: "selectProfile"; readonly profile: string }
  // 「テスト実行」タブのプロジェクト選択。ダッシュボード封筒の同名メッセージとは別経路だが、
  // どちらも fleetest.project 設定を書き換えるだけ(実行プロファイルの追随は
  // extension.ts の reconciledProfileForProject が行う)。
  | { readonly type: "selectProject"; readonly project: string }
  // 実行プロファイルの追加/コピー/名前変更/削除(アプリプロファイルの追加/コピー/削除/名前変更と
  // 同じ構成)。コピー/名前変更/削除の対象 profile の空文字は「対象なし」として検証で弾く。
  | { readonly type: "profileAdd" }
  | { readonly type: "profileCopy"; readonly profile: string }
  | { readonly type: "profileRename"; readonly profile: string }
  | { readonly type: "profileDelete"; readonly profile: string }
  // プロファイルタブ先頭: テストプロジェクト自体の追加/コピー/名前変更/削除(実行プロファイルの
  // profileAdd/profileCopy/profileRename/profileDelete と同じ構成)。「テスト実行」タブの selectProject
  // (project 切替)とは別メッセージ(こちらは TestProjects/<name>/ 自体の作成・改名・削除)。
  | { readonly type: "projectAdd" }
  | { readonly type: "projectCopy"; readonly project: string }
  | { readonly type: "projectRename"; readonly project: string }
  | { readonly type: "projectDelete"; readonly project: string }
  // デバイス追加モーダルを開いた直後に送る、`fleetest api device-catalog` の再取得リクエスト。
  // source: 「+既存から選択」モーダルの「デバイス候補のホスト」セレクタの選択(§13 段2)。
  // remote なら monitorDeviceOps.ts が deviceCommandArgs で `remote exec <machine> -- api device-catalog`
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
      readonly platform: MonitorPlatform;
      readonly name: string;
      readonly model: string;
      readonly os: string;
      // このダイアログは常に #device-pick-overlay の「+」からしか開かない(register:false = 物理
      // 作成のみ・ホストが --no-register 付与)。登録は #device-pick-overlay の OK
      // (runProfileDevicesSync)が別途行う。source が remote のときはホスト側が --no-register を
      // 強制する(§13。リモート側のプロファイルは次回ディスパッチの rsync --delete で消えるため、
      // 正はローカル)。
      readonly register: boolean;
      /** 同名の実体が既にあるとき、消してから作り直す(`api create-device --overwrite`)。
       * 破壊的なので webview では決めず、ホスト側のモーダル確認を通ってから true になる。 */
      readonly overwrite?: boolean;
      /** 選んだ OS バージョンがダウンロードが要る(インストール済みでない)Android システムイメージの
       * ときだけ載る。ホストは1枚の確認モーダル(ライセンス同意)を挟んでから
       * `api install-system-image` → 成功後に通常の create-device という順で実行する
       * (2枚のモーダルを続けて出さない。§13/2026-08-25 の規律と同じ)。 */
      readonly installSystemImage?: {
        readonly package: string;
        readonly sizeBytes: number | null;
        readonly license: string | null;
      };
      readonly source: DeviceCommandSource;
    }
  // 「デバイスを追加」左下の「バッチ作成」。names は webview が「デバイス名-連番2桁(-01 始まり)」で
  // 組んだ完成形(ホストは組み立て直さない = 表示と作られる名前を必ず一致させる)。
  // overwriteNames は names のうち現ホストで衝突しているぶん(判定は webview 側 ――
  // 一覧を持っているのはあちら。ホストは「消して作り直してよいか」を聞くのに使う)。
  // register は送らない: このダイアログはピッカーからしか開かないので常に物理作成のみで、
  // 登録はピッカーの OK(runProfileDevicesSync)が行う。
  | {
      readonly type: "batchCreateDevices";
      readonly platform: MonitorPlatform;
      readonly names: readonly string[];
      readonly model: string;
      readonly os: string;
      readonly overwriteNames: readonly string[];
      /** バッチ全体で共有する OS バージョンがダウンロードが要るときだけ載る(createDevice の
       * installSystemImage と同じ形・同じ扱い)。バッチは全台が同じ model/os で作られるため、
       * 導入は1回だけ行い、成功後に台ごとの create-device ループへ進む。 */
      readonly installSystemImage?: {
        readonly package: string;
        readonly sizeBytes: number | null;
        readonly license: string | null;
      };
      readonly source: DeviceCommandSource;
    }
  // 「+既存から選択」モーダル(#device-pick-overlay)が開いた直後に送る、
  // `fleetest api installed-devices` の再取得リクエスト(deviceCatalogRequest と同じ趣旨)。
  | { readonly type: "installedDevicesRequest"; readonly source: DeviceCommandSource }
  // 同モーダルの OK クリック: 新たにチェックした(プロジェクトのデバイスカタログに未登録だった)
  // デバイスを、選択中の実行プロファイルへ追加する(除去はこのモーダルの役目ではない ——
  // プロファイルタブの実行プロファイル節のチェックボックス/右クリック「除去」が別に持つ)。
  // add が空は不正として弾く(webview は差分無しで OK を無効化する設計だが防御的に検証)。
  | {
      readonly type: "runProfileDevicesSync";
      readonly profile: string;
      readonly add: readonly RunProfileDeviceAddEntry[];
      /** OK 押下時点でダイアログ内ホスト選択(devicePickMachine.js)が指していたホスト。
       * add の各エントリの machine キーへ書き込む。 */
      readonly source: DeviceCommandSource;
    }
  // 実行プロファイル節のデバイス一覧、右クリック「除去」。devices は複数選択の一括除去に対応する
  // 配列(単一も1件配列)。空配列は「対象なし」として不正扱い。同じ (platform, machine, name) を
  // 持つ**全実行プロファイル**から取り除く(仮想デバイス/実機の登録本体は操作しない)。
  | {
      readonly type: "runProfileDeviceRemove";
      readonly devices: readonly { readonly platform: MonitorPlatform; readonly machine?: string; readonly name: string }[];
    }
  // 同デバイス一覧、右クリック「Wipe Data」: 仮想デバイスの中身を初期化する(実行プロファイルからの
  // 除去[runProfileDeviceRemove]・実体の削除[devicePickDeviceDelete]とは別物。デバイスは残る)。
  // devices は複数選択に対応する配列(単一も1件配列)。**実機は webview 側で項目を出さない**
  // (CLI 側も DeviceWiper が拒否する)。
  | {
      readonly type: "runProfileDeviceWipe";
      // **identifier で撃つ**(iOS = シミュレータの UDID / Android = AVD id)。CLI は
      // `api wipe-device --platform … --udid/--avd` でプロファイルを一切参照しない
      // (delete-device と同じ契約)。name は確認・ログ・タイル表示のためだけに運ぶ。
      // 識別子を持たない行では webview がメニュー項目自体を出さない。
      readonly devices: readonly {
        readonly name: string;
        readonly machine?: string;
        readonly platform: MonitorPlatform;
        readonly identifier: string;
      }[];
    }
  // #device-pick-overlay の行右クリック「削除」: 実行プロファイルからの除去(runProfileDeviceRemove)
  // とは別に、ホスト上の実体(シミュレータ/AVD)そのものを `fleetest api delete-device` で消す。
  // identifier は iOS=udid/Android=avd id(実機行にはこのメニュー自体を出さない)。name は確認
  // ダイアログ・失敗表示に使う表示名。source は OK 押下時と同じダイアログ内ホスト選択。
  | {
      readonly type: "devicePickDeviceDelete";
      readonly platform: MonitorPlatform;
      readonly identifier: string;
      readonly name: string;
      readonly source: DeviceCommandSource;
    }
  // 実行プロファイル設定フォームの選択変更・初回表示時のロード要求。profile の空文字は
  // profileCopy 等と同じ理由で不正として弾く。
  | { readonly type: "runProfileLoad"; readonly profile: string }
  // 同フォームの自動保存。fields はクライアント側 trim 済み。
  // app はクライアント側で必須検証済みの想定だが、型検証自体は空文字も許容する。
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
  // 同フォームの自動保存(runProfileSave と同じ方針)。アプリプロファイルは全フィールド省略可のため
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
  // 設定タブの表示言語セレクタ変更(settingsTab.js)。monitorPanel.ts が fleetest.language 設定(Global)を
  // 更新する。反映は extension.ts の onDidChangeConfiguration ハンドラ(ツリー再翻訳 + 再読み込み案内)。
  | { readonly type: "setLanguage"; readonly value: "auto" | "ja" | "en" }
  // 設定タブのリモート実行セクション変更(settingsTab.js)。monitorPanel.ts が CLI のホスト登録簿を
  // 更新する。hosts は正規化済みの想定だが検証は型のみ。
  | {
      readonly type: "setRemoteConfig";
      readonly hosts: readonly RemoteHostEntry[];
    }
  // 設定タブのマシン表の削除ボタン(登録済みの行)。**確認はホスト側のモーダル**(webview では
  // window.confirm が効かない)。確認されたら remoteHostRemoveConfirmed を返す
  | { readonly type: "requestRemoveRemoteHost"; readonly rowId: number; readonly machine: string }
  // 設定タブ「ログ・録画」のクリーンアップ欄の欄変更(settingsTab.js)。**渡した鍵だけ**を CLI へ送り、
  // null はその鍵を既定へ戻す(空欄・不正値のとき)。0 は「保持しない」の有効な指定。
  | { readonly type: "setRetention"; readonly patch: RetentionPatch }
  // 設定タブ「今すぐクリーンアップ」。dryRun=true は見積もるだけ。**確認はホスト側**(webview では
  // window.confirm が効かない)—— dryRun=false でも monitorPanel.ts が先に見積もりを撃ち、
  // 消える合計をモーダルに出してから実行する。
  | { readonly type: "runCleanup"; readonly dryRun: boolean }
  // 設定タブ「更新」の「更新を確認」ボタン(settingsTab.js)。monitorPanel.ts が update-check.sh を実行する。
  | { readonly type: "checkUpdate" }
  // 設定タブ「更新」の「更新する」ボタン。monitorPanel.ts が update.sh を実行し、出力は OUTPUT へ出す。
  | { readonly type: "runUpdate" }
  // LPT 投入順の切替(webview→拡張)。ホストは fleetest.lptScheduling 設定を更新し、
  // run 時に false なら fleetest api run へ --no-lpt を渡す(src/runHandler.ts)
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
  // 「テスト実行」タブのスプリッターをドラッグ終了した時のタイルペイン高さ(px)。monitorPanel.ts が
  // workspaceState へ永続化し、パネル再作成時に "tilePaneHeight" メッセージで復元する。
  | { readonly type: "setTilePaneHeight"; readonly value: number }
  // auto-fit トグルの切替(ボタン押下・手動ドラッグによる自動 OFF)。monitorPanel.ts が
  // workspaceState へ永続化し、パネル再作成時に "tileAutoFit" メッセージで復元する。
  | { readonly type: "setTileAutoFit"; readonly value: boolean }
  // 全選択トグルの状態が変わったとき(ボタン・Cmd/Ctrl+A・右クリックメニュー、および
  // 個別選択で全台が揃った/崩れたとき)。monitorPanel.ts が workspaceState へ永続化し、
  // パネル再作成時に "selectAllDevices" メッセージで復元する。
  | { readonly type: "setSelectAllDevices"; readonly value: boolean }
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
  // project = 名前: 「(すべて)」を解除して設定 fleetest.project を書き換える。
  // null = 「(すべて)」(録画タブだけの表示。fleetest.project は変えない)
  | { readonly type: "recordingsSelectProject"; readonly project: string | null }
  | { readonly type: "recordingsOpen"; readonly project: string; readonly runID: string }
  // ---- ダッシュボードタブ -------------------------------------------------------------------
  // dashboardModel.ts の DashboardFromWebviewMessage をそのまま運ぶ封筒(上の
  // MonitorToWebviewMessage の "dashboard" 型と対)。
  | { readonly type: "dashboard"; readonly message: DashboardFromWebviewMessage };

/**
 * runProfileDevicesSync の add[] 1件(RunProfileDeviceAddEntry)の検証。name の空文字は不正。
 * osVersion/udid/avd/model は省略可(空文字は無意味なため undefined か非空 string のみ許容)。
 */
function isRunProfileDeviceAddEntryLike(value: unknown): value is RunProfileDeviceAddEntry {
  return (
    isRecord(value) &&
    (value.platform === "ios" || value.platform === "android") &&
    typeof value.name === "string" &&
    value.name !== "" &&
    (value.osVersion === undefined || typeof value.osVersion === "string") &&
    (value.udid === undefined || typeof value.udid === "string") &&
    (value.avd === undefined || typeof value.avd === "string") &&
    (value.serial === undefined || typeof value.serial === "string") &&
    (value.model === undefined || typeof value.model === "string") &&
    (value.kind === undefined || value.kind === "virtual" || value.kind === "physical")
  );
}

/** deviceCatalogRequest/installedDevicesRequest/createDevice の source(§13 段2)の検証。
 * remote は machine(登録簿のマシン名)が非空文字列であること(空文字は `remote exec` に
 * 渡せない不正値)。 */
function isDeviceCommandSourceLike(value: unknown): value is DeviceCommandSource {
  return (
    isRecord(value) &&
    (value.kind === "local" ||
      (value.kind === "remote" && typeof value.machine === "string" && value.machine !== ""))
  );
}

/** setRemoteConfig の hosts[] 1件の検証(webview 側は既に正規化済みの値を送る想定だが、
 * 型不正なペイロードを弾くための最終ゲート)。**マシン名のキーは "machine"**(2026-08-26 改名。
 * 旧キー "name" を要求すると settingsTab.js の payload が全滅し、リモートマシンの追加・削除が
 * 黙って無視される)。 */
function isRemoteHostEntryLike(value: unknown): value is RemoteHostEntry {
  return (
    isRecord(value) &&
    typeof value.machine === "string" &&
    typeof value.host === "string" &&
    typeof value.dir === "string" &&
    (value.color === undefined || typeof value.color === "string")
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

/** アプリプロファイル ios セクションの検証(3項目 + 実機に配るパッケージ appPathPhysical)。 */
function isAppProfileIOSFieldsLike(value: unknown): value is AppProfileIOSFields {
  return isRecord(value) && isAppProfilePlatformFieldsLike(value) && typeof value.appPathPhysical === "string";
}

/** createDevice/batchCreateDevices の installSystemImage の検証。package は非空文字列必須、
 * sizeBytes/license は number|null / string|null(欠落は不可 —— 「不明」は明示的に null で送る契約)。 */
function isInstallSystemImageRequestLike(
  value: unknown,
): value is { package: string; sizeBytes: number | null; license: string | null } {
  return (
    isRecord(value) &&
    typeof value.package === "string" &&
    value.package !== "" &&
    (value.sizeBytes === null || typeof value.sizeBytes === "number") &&
    (value.license === null || typeof value.license === "string")
  );
}

/** deviceRestartGpu / devicesRestartGpu の1台ぶん(name 必須・machine は省略か非空文字列)。 */
function isGpuRestartTarget(value: unknown): value is { name: string; machine?: string } {
  if (typeof value !== "object" || value === null) {
    return false;
  }
  const record = value as Record<string, unknown>;
  return (
    typeof record.name === "string" && record.name !== "" &&
    (record.machine === undefined || (typeof record.machine === "string" && record.machine !== ""))
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
    case "runTests":
    case "cancelTests":
    case "profileAdd":
    case "projectAdd":
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
        (value.machine === undefined || (typeof value.machine === "string" && value.machine !== "")) &&
        (value.udid === undefined || typeof value.udid === "string") &&
        (value.serial === undefined || typeof value.serial === "string") &&
        (value.registered === undefined || typeof value.registered === "boolean")
      );
    case "openLiveForDevice":
      return typeof value.id === "string" && value.id !== "";
    case "copyText":
      return typeof value.text === "string" && value.text !== "";
    case "deviceRestartGpu":
      return isGpuRestartTarget(value);
    case "devicesRestartGpu":
      return (
        Array.isArray(value.devices) &&
        value.devices.length > 0 &&
        value.devices.every((d) => isGpuRestartTarget(d))
      );
    case "selectProfile":
      return typeof value.profile === "string";
    // 空文字は「未選択」= 切り替え先が無いので弾く(selectProfile と違い意味を持たない)。
    case "selectProject":
      return typeof value.project === "string" && value.project !== "";
    case "profileCopy":
    case "profileRename":
    case "profileDelete":
      return typeof value.profile === "string" && value.profile !== "";
    case "projectCopy":
    case "projectRename":
    case "projectDelete":
      return typeof value.project === "string" && value.project !== "";
    case "installCmdlineToolsRequest":
      return true;
    case "deviceCatalogRequest":
    case "installedDevicesRequest":
      return isDeviceCommandSourceLike(value.source);
    case "createDevice":
      return (
        (value.platform === "ios" || value.platform === "android") &&
        typeof value.name === "string" &&
        value.name !== "" &&
        typeof value.model === "string" &&
        value.model !== "" &&
        typeof value.os === "string" &&
        value.os !== "" &&
        typeof value.register === "boolean" &&
        (value.installSystemImage === undefined || isInstallSystemImageRequestLike(value.installSystemImage)) &&
        isDeviceCommandSourceLike(value.source)
      );
    case "batchCreateDevices":
      return (
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
        (value.installSystemImage === undefined || isInstallSystemImageRequestLike(value.installSystemImage)) &&
        isDeviceCommandSourceLike(value.source)
      );
    case "runProfileDevicesSync":
      return (
        typeof value.profile === "string" &&
        value.profile !== "" &&
        Array.isArray(value.add) &&
        value.add.length > 0 &&
        value.add.every(isRunProfileDeviceAddEntryLike) &&
        isDeviceCommandSourceLike(value.source)
      );
    case "runProfileDeviceRemove":
      return (
        Array.isArray(value.devices) &&
        value.devices.length > 0 &&
        value.devices.every(
          (device) =>
            isRecord(device) &&
            (device.platform === "ios" || device.platform === "android") &&
            typeof device.name === "string" &&
            device.name !== "" &&
            (device.machine === undefined || (typeof device.machine === "string" && device.machine !== "")),
        )
      );
    case "runProfileDeviceWipe":
      return (
        Array.isArray(value.devices) &&
        value.devices.length > 0 &&
        value.devices.every(
          (device) =>
            isRecord(device) &&
            typeof device.name === "string" &&
            device.name !== "" &&
            (device.platform === "ios" || device.platform === "android") &&
            typeof device.identifier === "string" &&
            device.identifier !== "" &&
            (device.machine === undefined || (typeof device.machine === "string" && device.machine !== "")),
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
        typeof value.fields.app === "string" &&
        Array.isArray(value.fields.devices) &&
        // devices はプロジェクトのデバイスカタログと同形 + enabled(一意なのは (platform, machine,
        // name))。**素通ししない** —— machine の無い参照を保存すると同名が別マシンに居るとき
        // run で曖昧になる
        value.fields.devices.every(
          (ref) =>
            isRecord(ref) &&
            (ref.platform === "ios" || ref.platform === "android") &&
            typeof ref.name === "string" &&
            typeof ref.enabled === "boolean" &&
            (ref.machine === undefined || typeof ref.machine === "string"),
        ) &&
        typeof value.fields.heal === "boolean" &&
        typeof value.fields.textVisualCheck === "boolean" &&
        typeof value.fields.screenLooksLike === "boolean" &&
        typeof value.fields.containerInference === "boolean" &&
        typeof value.fields.ocrTextVisualCheck === "boolean" &&
        typeof value.fields.iosInappEngine === "boolean" &&
        typeof value.fields.iosFastInput === "boolean" &&
        typeof value.fields.iosPreActionWarmup === "boolean" &&
        typeof value.fields.homeOnStart === "boolean" &&
        typeof value.fields.enableAnimations === "boolean" &&
        typeof value.fields.reportDir === "string" &&
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
        isAppProfileIOSFieldsLike(value.fields.ios) &&
        isAppProfilePlatformFieldsLike(value.fields.android)
      );
    case "nameInputConfirm":
      return typeof value.id === "number" && typeof value.name === "string";
    case "nameInputCancel":
      return typeof value.id === "number";
    case "setKeepPhysicalDevicesAwake":
    case "setPollingMode":
      return typeof value.value === "boolean";
    case "setLanguage":
      return value.value === "auto" || value.value === "ja" || value.value === "en";
    case "setRemoteConfig":
      return Array.isArray(value.hosts) && value.hosts.every(isRemoteHostEntryLike);
    case "requestRemoveRemoteHost":
      return typeof value.rowId === "number" && typeof value.machine === "string";
    case "devicesTabVisible":
      return typeof value.visible === "boolean";
    case "setRetention":
      // 未知の鍵・負値・非整数を通すと CLI へそのまま渡り、綴り違いが黙って無視される
      return isRetentionPatch(value.patch);
    case "runCleanup":
      return typeof value.dryRun === "boolean";
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
    case "setSelectAllDevices":
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
    case "recordingsSelectProject":
      return value.project === null || (typeof value.project === "string" && value.project !== "");
    case "recordingsOpen":
      return typeof value.project === "string" && value.project !== "" && typeof value.runID === "string" && value.runID !== "";
    case "dashboard":
      return isDashboardFromWebviewMessage(value.message);
    default:
      return false;
  }
}
