// monitorModel.ts
// `ftester api monitor` の NDJSON stdout(unknown)を webview 向け型付きメッセージへ変換・検証する
// 純粋関数群。vscode に依存しない(monitorPanel.ts と test/monitorModel.test.mjs の両方から
// 同じロジックを使うため。ndjson.ts/stepsModel.ts と同じ方針)。
//
// 契約: `ftester api monitor --project <P> [--interval <秒>] [--max-width <px>] [--profile <run>]`
// の stdout NDJSON:
//   {"kind":"monitorDevices","devices":[{"id":..,"name":..,"platform":"ios"|"android",
//     "state":"connected"|"booted"|"offline","detail":"..","health":string[]|null}]}   … サイクル毎
//     (health は connected な Android エミュレータのみ設定されうる。省略/null/空配列=異常なし。
//     値は "wifi-disabled"|"clock-skew" 等。未知の文字列も受理して保持する)
//     ("renderMode":"gpu"|"cpu"|null も同様。connected な Android エミュレータのみ設定されうる。
//     ブート時固定のため接続中は変化しない値)
//     ("inRun":bool は ApiMonitorCommand.swift の RunLease.isFresh 判定。`ftester api run` が
//     このデバイスを使用中なら true。null 化されないが読み手は欠落/非bool を false とみなす)
//   {"kind":"monitorFrame","device":"..","jpegBase64":"..","width":480,"height":1040}
//     … connected デバイスのみ、約interval秒毎
//   {"kind":"monitorError","device":"..","message":".."}         … device は省略されうる。
//     現行バイナリは送出しない(スクショ変換失敗は stderr のみ。ユーザー決定 2026-07-16)が、
//     読み手としては旧バイナリ互換のため受理し続ける

export type MonitorPlatform = "ios" | "android";
export type MonitorDeviceState = "connected" | "booted" | "offline";

export interface MonitorDevice {
  readonly id: string;
  readonly name: string;
  readonly platform: MonitorPlatform;
  readonly state: MonitorDeviceState;
  readonly detail: string;
  /** iOS: 解決済みシミュレータ UDID。Android: undefined(Swift 側は null を送るがここで正規化する)。
   * monitorDeviceStreamController.ts が iOS ストリーミング helper の起動先として使う。 */
  readonly udid?: string;
  /** Android: 解決済み adb serial。iOS: undefined(Swift 側は null を送るがここで正規化する)。
   * monitorDeviceStreamController.ts が Android ストリーミング helper の起動先として使う。 */
  readonly serial?: string;
  /** ゲストOS健全性プローブの異常種別(connected な Android エミュレータのみ)。省略/空=異常なし。
   * 未知の文字列も受理して保持する(monitorHealthWatchdog.ts が消費)。 */
  readonly health?: readonly string[];
  /** Android エミュレータの実描画モード("gpu"=host/Metal、"cpu"=swiftshader)。
   * connected な Android のみ・判定不能や iOS は undefined(Swift は null を送るので正規化する)。 */
  readonly renderMode?: "gpu" | "cpu";
  /** `ftester api run` がこのデバイスを使用中か(ApiMonitorCommand.swift の RunLease.isFresh)。
   * Swift は常に true/false を送るが、欠落・非 bool は false として扱う(isMonitorDevice が正規化)。 */
  readonly inRun?: boolean;
}

/** `ftester api monitor` の NDJSON 1行分のイベント(kind で判別)。 */
export type MonitorEvent =
  | { readonly kind: "monitorDevices"; readonly devices: readonly MonitorDevice[] }
  | {
      readonly kind: "monitorFrame";
      readonly device: string;
      readonly jpegBase64: string;
      readonly width: number;
      readonly height: number;
    }
  | { readonly kind: "monitorError"; readonly device?: string; readonly message: string };

const PLATFORMS: ReadonlySet<string> = new Set<MonitorPlatform>(["ios", "android"]);
const STATES: ReadonlySet<string> = new Set<MonitorDeviceState>(["connected", "booted", "offline"]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isMonitorDevice(value: unknown): value is MonitorDevice {
  if (!isRecord(value)) {
    return false;
  }
  if (value.udid === null) {
    // JSON の null を undefined に正規化する(以後 string | undefined 前提で扱えるようにする)。
    value.udid = undefined;
  }
  if (value.serial === null) {
    value.serial = undefined;
  }
  if (value.health === null) {
    value.health = undefined;
  }
  if (value.renderMode === null) {
    value.renderMode = undefined;
  }
  // 未知の文字列は"判定不能"として undefined に落とす(丸ごと弾いてイベント全体を捨てない)
  if (value.renderMode !== undefined && value.renderMode !== "gpu" && value.renderMode !== "cpu") {
    value.renderMode = undefined;
  }
  if (value.inRun !== true && value.inRun !== false) {
    // 欠落/null/型不正を「未使用中」に寄せる(イベント全体は捨てない)。
    value.inRun = false;
  }
  return (
    typeof value.id === "string" &&
    typeof value.name === "string" &&
    typeof value.platform === "string" &&
    PLATFORMS.has(value.platform) &&
    typeof value.state === "string" &&
    STATES.has(value.state) &&
    typeof value.detail === "string" &&
    (value.udid === undefined || typeof value.udid === "string") &&
    (value.serial === undefined || typeof value.serial === "string") &&
    (value.health === undefined ||
      (Array.isArray(value.health) && value.health.every((item) => typeof item === "string"))) &&
    (value.renderMode === undefined || value.renderMode === "gpu" || value.renderMode === "cpu") &&
    typeof value.inRun === "boolean"
  );
}

/** 未知の kind・型不一致は false(呼び出し側は安全に無視できる)。device 等の省略可フィールドは undefined を許容。 */
export function isMonitorEvent(value: unknown): value is MonitorEvent {
  if (!isRecord(value) || typeof value.kind !== "string") {
    return false;
  }
  switch (value.kind) {
    case "monitorDevices":
      return Array.isArray(value.devices) && value.devices.every(isMonitorDevice);
    case "monitorFrame":
      return (
        typeof value.device === "string" &&
        typeof value.jpegBase64 === "string" &&
        typeof value.width === "number" &&
        typeof value.height === "number"
      );
    case "monitorError":
      return (
        typeof value.message === "string" &&
        (value.device === undefined || typeof value.device === "string")
      );
    default:
      return false;
  }
}

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
  // ライブ操作タブの H.264 AU 1件(monitorLiveController.ts の onChunk が post する。既存の
  // { type: "frame", image } と並置。h264Chunk と同じく "live" 封筒は経由しない — webview 側は
  // main.js の直下ディスパッチャから直接 liveTab.js の applyLiveH264Chunk へ渡す)。
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
      readonly op: DeviceOpKind | null;
      /** キュー内での状態("running"=実行中／"queued"=順番待ち)。op が null のときは null。 */
      readonly status: DeviceOpQueueStatus | null;
    }
  | { readonly type: "deviceOpFailed"; readonly name: string; readonly message: string }
  | {
      readonly type: "profileInfo";
      /** 対象プロジェクトの実行プロファイル名一覧(Projects/<project>/profiles/runs/ 直下)。 */
      readonly profiles: readonly string[];
      /** 現在の ftester.profile 設定値。"" はプロファイルなし。 */
      readonly current: string;
      /** 対象プロジェクトのアプリプロファイル名一覧(profiles/apps/ 直下)。既存の applyProfileInfo は
       * このフィールドを無視するだけなので後方互換。 */
      readonly apps: readonly string[];
    }
  | {
      readonly type: "machineProfileInfo";
      /** 対象プロジェクトのマシンプロファイル一覧(config.ts の listMachineProfiles の要約形)。 */
      readonly machines: readonly {
        readonly name: string;
        readonly devices: readonly {
          readonly name: string;
          readonly platform: MonitorPlatform;
          /** 一覧2行目の表示文字列(machineDeviceDetail で組み立て済み)。 */
          readonly detail: string;
          // 右ペインの編集フォーム用の生フィールド(MachineDeviceEntry と同形)。undefined は
          // postMessage の JSON 化で自然に省略される。
          readonly simulator?: string;
          readonly os?: string;
          readonly udid?: string;
          readonly port?: number;
          readonly avd?: string;
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
  // 「+既存から選択」モーダル(#device-pick-overlay)が開いた直後に送る installedDevicesRequest
  // への応答(runInstalledDevices)。deviceCatalog と同じ形。
  | {
      readonly type: "installedDevices";
      readonly ok: boolean;
      readonly data: InstalledDevices | null;
      readonly error: string | null;
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
  // ホスト駆動のタブ切替(例: ftester.showLiveControl でパネルを開き直さず「ライブ操作」タブへ
  // 直接切り替える)。webview 側は tabs.js の activateTab へそのまま渡す。
  | { readonly type: "switchTab"; readonly tab: string }
  // 設定タブの「ポーリングモードを使用する」チェックボックスの現在値。ready 直後(永続状態の反映)と
  // setPollingMode 受信直後(monitorPanel.ts)の両方で送る。webview 側は settingsTab.js の
  // applySettings へそのまま渡す(setPollingMode と対の契約)。
  | { readonly type: "pollingMode"; readonly value: boolean }
  // デバイスタブのスプリッター位置(タイルペイン高さ px)。ready 直後に workspaceState の永続値を反映する。
  // webview の getState はパネルを閉じると失われるため host 側で永続化する(setTilePaneHeight と対の契約)。
  // webview 側は splitter.js の setTilePaneHeight へ渡す。
  | { readonly type: "tilePaneHeight"; readonly value: number }
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
      readonly phase: "unhealthy" | "repairing" | "streamRepairing" | "cpuFallback" | "restarting" | "failed" | "ok";
    }
  // `ftester api run` の AVD Wipe Data 進行状況(model.ts の WipeStatusEvent が NDJSON 契約の同期相手)。
  // name は deviceOpBusy と同じ名前空間(デバイス論理名)。webview はタイルのバッジ表示に使う。
  | {
      readonly type: "wipeStatus";
      readonly name: string;
      readonly phase: "stopping" | "rebooting" | "done" | "failed";
    };

/**
 * デバイス一覧をプロファイルタブの表示順(ios→android・各プラットフォーム内は name 順。
 * config.ts の listMachineProfiles と同じ規則 — 変更時は両方揃える)に整列する。
 * monitorProcessManager.ts が monitorDevices 受信時に適用し、以降の全消費側
 * (デバイスタブのタイル・lastKnownDevices)はこの順で受け取る。
 */
export function sortMonitorDevices(devices: readonly MonitorDevice[]): MonitorDevice[] {
  return [...devices].sort((a, b) =>
    a.platform !== b.platform ? (a.platform === "ios" ? -1 : 1) : a.name.localeCompare(b.name),
  );
}

/** 検証済みの MonitorEvent を、webview へそのまま postMessage できる形に変換する。 */
export function toWebviewMessage(event: MonitorEvent): MonitorToWebviewMessage {
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
  | { readonly type: "deviceOp"; readonly name: string; readonly op: DeviceOpKind }
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
  | { readonly type: "deviceCatalogRequest" }
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
      readonly register: boolean;
    }
  // 「+既存から選択」モーダル(#device-pick-overlay)が開いた直後に送る、
  // `ftester api installed-devices` の再取得リクエスト(deviceCatalogRequest と同じ趣旨)。
  | { readonly type: "installedDevicesRequest" }
  // 同モーダルの OK クリック。チェックボックスは「登録状態そのもの」を表すため、送るのは全件では
  // なく初期状態からの差分のみ: add は新たにチェックした(未登録だった)デバイス、remove は
  // チェックを外した(登録済みだった)デバイスのマシンプロファイル上の名前。add/remove は片方が
  // 空配列でもよいが、両方空は不正として弾く(webview は差分無しで OK を無効化する設計だが防御的に検証)。
  | {
      readonly type: "machineDevicesSync";
      readonly machine: string;
      readonly add: readonly MachineDeviceAddEntry[];
      readonly remove: readonly string[];
    }
  // デバイス行の右クリック「削除」。names は複数選択の一括削除に対応する配列(単一削除も1件配列)。
  // 空配列は「対象なし」として不正扱い。
  | { readonly type: "machineDeviceRemove"; readonly machine: string; readonly names: readonly string[] }
  // プロファイルタブ右ペインの編集フォーム「確定」。fields はクライアント側で trim 済み(空文字=
  // 未入力/対象外)。createDevice と違い machine/originalName 以外は空文字を許容する。
  | {
      readonly type: "machineDeviceUpdate";
      readonly machine: string;
      readonly platform: MonitorPlatform;
      readonly originalName: string;
      readonly fields: {
        readonly name: string;
        readonly simulator: string;
        readonly os: string;
        readonly udid: string;
        readonly port: string;
        readonly avd: string;
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
  // 止めてポーリングへ強制する(iOS/Android・ライブ操作タブ/デバイスタイル共通)。monitorPanel.ts が
  // workspaceState へ永続化し、対の "pollingMode" メッセージで即時反映する。
  | { readonly type: "setPollingMode"; readonly value: boolean }
  // デバイスタブのスプリッターをドラッグ終了した時のタイルペイン高さ(px)。monitorPanel.ts が
  // workspaceState へ永続化し、パネル再作成時に "tilePaneHeight" メッセージで復元する。
  | { readonly type: "setTilePaneHeight"; readonly value: number }
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
  | { readonly type: "streamStall"; readonly scope?: "tile" | "live"; readonly device?: string };

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
    (value.avd === undefined || typeof value.avd === "string")
  );
}

/** アプリプロファイル common セクション(表示名+自動インストール)の検証。autoInstall は
 * common に一本化されているため "true"/"false" の2値のみ受理する。 */
function isAppProfileCommonFieldsLike(value: unknown): value is AppProfileCommonFields {
  return (
    isRecord(value) &&
    typeof value.appName === "string" &&
    (value.autoInstall === "true" || value.autoInstall === "false")
  );
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
      return typeof value.name === "string" && (value.op === "up" || value.op === "down");
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
    case "deviceCatalogRequest":
    case "machineProfileAdd":
    case "installedDevicesRequest":
      return true;
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
        typeof value.register === "boolean"
      );
    case "machineDevicesSync":
      return (
        typeof value.machine === "string" &&
        value.machine !== "" &&
        Array.isArray(value.add) &&
        value.add.every(isMachineDeviceAddEntryLike) &&
        Array.isArray(value.remove) &&
        value.remove.every((name) => typeof name === "string" && name !== "") &&
        (value.add.length > 0 || value.remove.length > 0)
      );
    case "machineDeviceRemove":
      return (
        typeof value.machine === "string" &&
        value.machine !== "" &&
        Array.isArray(value.names) &&
        value.names.length > 0 &&
        value.names.every((name) => typeof name === "string" && name !== "")
      );
    case "machineDeviceUpdate":
      return (
        typeof value.machine === "string" &&
        value.machine !== "" &&
        (value.platform === "ios" || value.platform === "android") &&
        typeof value.originalName === "string" &&
        value.originalName !== "" &&
        isRecord(value.fields) &&
        typeof value.fields.name === "string" &&
        typeof value.fields.simulator === "string" &&
        typeof value.fields.os === "string" &&
        typeof value.fields.udid === "string" &&
        typeof value.fields.port === "string" &&
        typeof value.fields.avd === "string"
      );
    case "runProfileLoad":
      return typeof value.profile === "string" && value.profile !== "";
    case "runProfileSave":
      return (
        typeof value.profile === "string" &&
        value.profile !== "" &&
        isRecord(value.fields) &&
        typeof value.fields.machine === "string" &&
        typeof value.fields.app === "string" &&
        Array.isArray(value.fields.devices) &&
        value.fields.devices.every((name) => typeof name === "string") &&
        typeof value.fields.heal === "boolean" &&
        typeof value.fields.iosInappEngine === "boolean" &&
        typeof value.fields.reportDir === "string" &&
        typeof value.fields.defaultTimeout === "string" &&
        typeof value.fields.wipeDataOnBloat === "boolean" &&
        typeof value.fields.wipeDataThresholdGB === "string" &&
        typeof value.fields.locale === "string"
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
    case "setTilePaneHeight":
      return typeof value.value === "number" && value.value > 0;
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
    default:
      return false;
  }
}

// ---- デバイス個別起動/停止(ftester api device-up / device-down) ------------------------
// 契約(Sources/ftester/ApiDeviceCommands.swift): `ftester api device-up --name <論理名>
// [--project <p>]` / `ftester api device-down --name <論理名> [--project <p>]` の stdout NDJSON:
//   {"kind":"log","message":".."} × n → {"kind":"finished","ok":bool,"error":string|null}
// (ok:false のときは exit code 1。診断は stderr のみ)。

export type DeviceOpKind = "up" | "down";

export interface DeviceOpLogEvent {
  readonly kind: "log";
  readonly message: string;
}

export interface DeviceOpFinishedEvent {
  readonly kind: "finished";
  readonly ok: boolean;
  readonly error: string | null;
}

export type DeviceOpEvent = DeviceOpLogEvent | DeviceOpFinishedEvent;

/** value が DeviceOpEvent として扱ってよいか判定する(isMonitorEvent と同じ方針)。 */
export function isDeviceOpEvent(value: unknown): value is DeviceOpEvent {
  if (!isRecord(value) || typeof value.kind !== "string") {
    return false;
  }
  switch (value.kind) {
    case "log":
      return typeof value.message === "string";
    case "finished":
      return typeof value.ok === "boolean" && (value.error === null || typeof value.error === "string");
    default:
      return false;
  }
}

/** `ftester api devices-up` の NDJSON 1行分のイベント。
 * 契約の同期相手: Sources/ftester/ApiDeviceCommands.swift ApiDevicesUp(deviceStarting/deviceFinished は
 * ブート開始/完了の即時通知で、モニターの状態スキャンを待たずタイルを「起動中」表示にするために使う。
 * deviceStopping は --restart 指定デバイスの down 開始通知)。 */
export type DevicesUpEvent =
  | { readonly kind: "log"; readonly message: string }
  | { readonly kind: "deviceStopping"; readonly name: string; readonly platform: string }
  | { readonly kind: "deviceStarting"; readonly name: string; readonly platform: string }
  | { readonly kind: "deviceFinished"; readonly name: string; readonly platform: string }
  | { readonly kind: "finished"; readonly ok: boolean; readonly error: string | null };

/** value が DevicesUpEvent として扱ってよいか判定する(isDeviceOpEvent と同じ方針)。 */
export function isDevicesUpEvent(value: unknown): value is DevicesUpEvent {
  if (!isRecord(value) || typeof value.kind !== "string") {
    return false;
  }
  switch (value.kind) {
    case "log":
      return typeof value.message === "string";
    case "deviceStopping":
    case "deviceStarting":
    case "deviceFinished":
      return typeof value.name === "string" && typeof value.platform === "string";
    case "finished":
      return typeof value.ok === "boolean" && (value.error === null || typeof value.error === "string");
    default:
      return false;
  }
}

/** `ftester api devices-restart` の NDJSON 1行分のイベント。deviceStopping/deviceStarting/
 * deviceFinished はバッチ内の1台ごとの down→up 進行通知(モニターの状態スキャンを待たず
 * タイルを更新するために使う。deviceLifecycleStatusFor は restartBatch を常に queued 扱いにする
 * ため、running 表示はこのイベント由来の deviceOpBusy post が担う)。 */
export type DevicesRestartEvent =
  | { readonly kind: "log"; readonly message: string }
  | { readonly kind: "deviceStopping"; readonly name: string; readonly platform: string }
  | { readonly kind: "deviceStarting"; readonly name: string; readonly platform: string }
  | { readonly kind: "deviceFinished"; readonly name: string; readonly platform: string }
  | { readonly kind: "finished"; readonly ok: boolean; readonly error?: string | null };

/** value が DevicesRestartEvent として扱ってよいか判定する(isDevicesUpEvent と同じ方針)。 */
export function isDevicesRestartEvent(value: unknown): value is DevicesRestartEvent {
  if (!isRecord(value) || typeof value.kind !== "string") {
    return false;
  }
  switch (value.kind) {
    case "log":
      return typeof value.message === "string";
    case "deviceStopping":
    case "deviceStarting":
    case "deviceFinished":
      return typeof value.name === "string" && typeof value.platform === "string";
    case "finished":
      return (
        typeof value.ok === "boolean" &&
        (value.error === undefined || value.error === null || typeof value.error === "string")
      );
    default:
      return false;
  }
}

/** タイル右クリックメニューの唯一の項目の表示状態。op はクリック時に実行する操作(disabled:true の間はクリック不可)。 */
export interface DeviceOpMenuItem {
  readonly label: string;
  readonly op: DeviceOpKind;
  readonly disabled: boolean;
}

/** タイルで実行中/待機中の操作(deviceOpBusy メッセージ・DeviceLifecycleQueue の状態から作る)。 */
export interface DeviceOpBusyState {
  readonly op: DeviceOpKind;
  readonly status: DeviceOpQueueStatus;
}

/**
 * タイル右クリックメニュー項目を決める(monitorPanel.ts 本体・webview 複製で使用)。
 * MonitorDeviceState の全パターンをカバーするため戻り値は null にならない。
 */
export function deviceOpMenuItem(
  state: MonitorDeviceState,
  busy: DeviceOpBusyState | undefined,
): DeviceOpMenuItem {
  if (busy?.status === "queued") {
    return { label: "待機中...", op: busy.op, disabled: true };
  }
  if (busy?.op === "up") {
    return { label: "起動中...", op: "up", disabled: true };
  }
  if (busy?.op === "down") {
    return { label: "停止中...", op: "down", disabled: true };
  }
  return state === "offline"
    ? { label: "起動", op: "up", disabled: false }
    : { label: "停止", op: "down", disabled: false };
}

// ---- デバイスライフサイクル操作の直列キュー ------------------------------------------------
// 「全て起動/終了」(bulk)とタイル個別操作(device)は、ブリッジ供給・simctl・adb の競合を避けるため
// 単一の直列キューで1件ずつ実行する(実機ログ解析で、全起動とタイル個別起動の並行実行により
// ブリッジ供給の waitUntilReady が失敗しゾンビブリッジが蓄積することが判明済み)。
//
// ここは vscode 非依存の純粋な状態管理のみ(spawn 自体は monitorPanel.ts 側)。常に entries[0] が
// デバイスライフサイクルのスケジューラ(running=実行中・jobs=FIFO 待機列)。
// - device ジョブは最大 DEVICE_LIFECYCLE_MAX_CONCURRENT 台まで同時実行(右クリック起動を2台並行に)。
// - bulk / restartBatch は単独占有(内部で2台並行するため、他と重ねると全体上限2を超える)。
// - 追い越しはしない(先頭が開始できない間は後続も待つ=投入順の保証)。
// - 同一デバイス名のジョブは同時に実行しない(enqueueRestart の down→up ペアの逐次性を守る)。

export type DeviceOpQueueStatus = "queued" | "running";

/** キューに積む1件のデバイスライフサイクル操作。全台(bulk)/1台(device)/複数台GPU再起動(restartBatch)の3種別。 */
export type DeviceLifecycleJob =
  // restartNames: up のみ。起動済みでも down→up する対象(devices-up --restart に渡す)。
  | { readonly kind: "bulk"; readonly op: "up" | "down"; readonly restartNames?: readonly string[] }
  | { readonly kind: "device"; readonly name: string; readonly op: DeviceOpKind }
  | { readonly kind: "restartBatch"; readonly names: readonly string[] };

/** device ジョブの同時実行上限(2台同時でホスト CPU がほぼ飽和する実測に基づくフリート共通の上限)。 */
export const DEVICE_LIFECYCLE_MAX_CONCURRENT = 2;

/** スケジューラ状態(不変)。running が実行中、jobs が待機列(FIFO)。 */
export interface DeviceLifecycleQueueState {
  readonly running: readonly DeviceLifecycleJob[];
  readonly jobs: readonly DeviceLifecycleJob[];
}

export function createDeviceLifecycleQueueState(): DeviceLifecycleQueueState {
  return { running: [], jobs: [] };
}

/** ジョブを待機列末尾に積む(新しい state を返す。実行開始は promoteDeviceLifecycleJobs)。 */
export function enqueueDeviceLifecycleJob(
  state: DeviceLifecycleQueueState,
  job: DeviceLifecycleJob,
): DeviceLifecycleQueueState {
  return { running: state.running, jobs: [...state.jobs, job] };
}

/** ジョブの同一性(finish の running 照合用)。device は name+op、bulk は op、restartBatch は names。 */
function sameLifecycleJob(a: DeviceLifecycleJob, b: DeviceLifecycleJob): boolean {
  if (a.kind === "device" && b.kind === "device") {
    return a.name === b.name && a.op === b.op;
  }
  if (a.kind === "bulk" && b.kind === "bulk") {
    return a.op === b.op;
  }
  if (a.kind === "restartBatch" && b.kind === "restartBatch") {
    return a.names.length === b.names.length && a.names.every((n, i) => n === b.names[i]);
  }
  return false;
}

/** 今すぐ実行開始できる待機ジョブを running へ昇格する。started が新規開始分(呼び出し側が実処理を開始する)。 */
export function promoteDeviceLifecycleJobs(state: DeviceLifecycleQueueState): {
  readonly state: DeviceLifecycleQueueState;
  readonly started: readonly DeviceLifecycleJob[];
} {
  const running = [...state.running];
  const jobs = [...state.jobs];
  const started: DeviceLifecycleJob[] = [];
  while (jobs.length > 0) {
    const job = jobs[0];
    if (!job) {
      break;
    }
    if (job.kind === "device") {
      if (running.length >= DEVICE_LIFECYCLE_MAX_CONCURRENT) {
        break;
      }
      if (running.some((j) => j.kind !== "device")) {
        break;
      }
      if (running.some((j) => j.kind === "device" && j.name === job.name)) {
        break;
      }
      running.push(job);
      started.push(job);
      jobs.shift();
      continue;
    }
    if (running.length > 0) {
      break;
    }
    running.push(job);
    started.push(job);
    jobs.shift();
    break;
  }
  return { state: { running, jobs }, started };
}

/** 完了したジョブを running から取り除く。見つからないのはバグ(完了通知の重複等)なので例外を投げる。 */
export function finishDeviceLifecycleJob(
  state: DeviceLifecycleQueueState,
  finished: DeviceLifecycleJob,
): { readonly state: DeviceLifecycleQueueState; readonly removed: DeviceLifecycleJob } {
  const index = state.running.findIndex((j) => sameLifecycleJob(j, finished));
  if (index === -1) {
    throw new Error("finishDeviceLifecycleJob: 実行中に該当ジョブがありません(完了通知が重複した可能性)");
  }
  const removed = state.running[index] as DeviceLifecycleJob;
  return {
    state: {
      running: [...state.running.slice(0, index), ...state.running.slice(index + 1)],
      jobs: state.jobs,
    },
    removed,
  };
}

/** 実行中/待機中を問わず何か積まれているか。true の間はグローバルボタン(全て起動/終了)を無効化する。 */
export function isDeviceLifecycleQueueBusy(state: DeviceLifecycleQueueState): boolean {
  return state.running.length > 0 || state.jobs.length > 0;
}

/** 指定デバイス名を対象にした device ジョブが既にキュー内(実行中含む)にあるか(連打防止に使う)。 */
export function hasDeviceLifecycleJobFor(state: DeviceLifecycleQueueState, name: string): boolean {
  return [...state.running, ...state.jobs].some(
    (job) =>
      (job.kind === "device" && job.name === name) ||
      (job.kind === "restartBatch" && job.names.includes(name)) ||
      (job.kind === "bulk" && (job.restartNames?.includes(name) ?? false)),
  );
}

/** 待機中の bulk up ジョブを1件取り除く(「デバイスの起動を中断」用。実行中(running)の bulk up は
 * プロセス kill で止める=ここでは触らない)。該当が無ければ state をそのまま返す。 */
export function removeQueuedBulkUpJob(state: DeviceLifecycleQueueState): {
  readonly state: DeviceLifecycleQueueState;
  readonly removed?: Extract<DeviceLifecycleJob, { kind: "bulk" }>;
} {
  const index = state.jobs.findIndex((job) => job.kind === "bulk" && job.op === "up");
  if (index === -1) {
    return { state };
  }
  const removed = state.jobs[index] as Extract<DeviceLifecycleJob, { kind: "bulk" }>;
  return {
    state: {
      running: state.running,
      jobs: [...state.jobs.slice(0, index), ...state.jobs.slice(index + 1)],
    },
    removed,
  };
}

/** キュー内(実行中含む)の bulk(全て起動/終了)ジョブの op。bootBusy.bulkOp の算出に使う
 * (webview は up の間 未起動タイルを「待機中」、down の間 稼働中タイルを「シャットダウン中」表示にする)。 */
export function bulkLifecycleOp(state: DeviceLifecycleQueueState): "up" | "down" | null {
  const job = [...state.running, ...state.jobs].find((job) => job.kind === "bulk");
  return job?.kind === "bulk" ? job.op : null;
}

/** 指定デバイス名の現在のキュー状態を返す(対象ジョブが無ければ undefined)。 */
export function deviceLifecycleStatusFor(
  state: DeviceLifecycleQueueState,
  name: string,
): DeviceOpBusyState | undefined {
  const all = [...state.running, ...state.jobs];
  // bulk up の restartNames(GPU 復帰対象)/ restartBatch は、ジョブが実行中でも CLI がその
  // デバイスに触れる(deviceStopping)までは「順番待ち」。per-device の実行中表示は
  // monitorDeviceOps.ts が NDJSON イベントから別途 deviceOpBusy を post する側の責務。
  if (all.some((job) => job.kind === "bulk" && (job.restartNames?.includes(name) ?? false))) {
    return { op: "down", status: "queued" };
  }
  if (all.some((job) => job.kind === "restartBatch" && job.names.includes(name))) {
    return { op: "down", status: "queued" };
  }
  const runningJob = state.running.find((job) => job.kind === "device" && job.name === name);
  if (runningJob && runningJob.kind === "device") {
    return { op: runningJob.op, status: "running" };
  }
  const queuedJob = state.jobs.find((job) => job.kind === "device" && job.name === name);
  if (queuedJob && queuedJob.kind === "device") {
    return { op: queuedJob.op, status: "queued" };
  }
  return undefined;
}

// ---- モニターの pause/resume/suppressFrames 制御 --------------------------------------------
// `ftester api monitor` は stdin から NDJSON 1行を受け付ける(Sources/ftester/ApiMonitorCommand.swift、
// 同期必須)。
// - pause/resume:「全て終了」「停止」実行中に使う。down 系ジョブの実行直前に pause・完了時に resume を
//   送り、片付け中のデバイスへスクショ取得に行くのを防ぐ(up 系は起動進行を見せるため pause しない)。
// - suppressFrames: フレーム抑制対象デバイス id 集合の全置換(差分ではない)。空配列 = 全デバイス再開。

export type MonitorControlCommand =
  | { readonly cmd: "pause" }
  | { readonly cmd: "resume" }
  | { readonly cmd: "suppressFrames"; readonly devices: readonly string[] };

/** down 系ジョブのみ true(bulk/device いずれも op フィールドで判定可能)。restartBatch は
 * up 系と同様 pause せずタイル上に進行を出す(GPU 再起動はタイル単位で見せたいため)。 */
export function deviceLifecycleJobNeedsMonitorPause(job: DeviceLifecycleJob): boolean {
  return job.kind !== "restartBatch" && job.op === "down";
}

/** モニターの stdin に書き込む制御コマンドの NDJSON 1行(末尾に改行を含む)。 */
export function monitorControlLine(cmd: MonitorControlCommand): string {
  return `${JSON.stringify(cmd)}\n`;
}

// ---- 実行プロファイル切り替え時の自動シャットダウン対象算出 ------------------------------------
// プロファイル切り替え時、新プロファイルに含まれない稼働中デバイスはシャットダウンするが、
// 含まれるデバイスは稼働中でも offline でも一切触らない(自動起動はしない)。
// monitorPanel.ts の restartMonitorIfScopeChanged がこの結果を down ジョブとしてキューに積む。

/**
 * シャットダウン対象デバイス名を返す(元の順序を保つ)。newScopeNames が null(プロファイルなし)
 * なら [](全デバイスが対象なので停止しない)。
 */
export function devicesToShutdownOnScopeChange(
  devices: readonly MonitorDevice[],
  newScopeNames: readonly string[] | null,
): string[] {
  if (newScopeNames === null) {
    return [];
  }
  const keep = new Set(newScopeNames);
  return devices.filter((device) => device.state !== "offline" && !keep.has(device.name)).map((device) => device.name);
}

// ---- 実行プロファイルの追加/コピー(名前検証・テンプレート生成) ------------------------------
// monitorPanel.ts の profileAdd/profileCopy ハンドラが使う純粋ロジック(ファイル I/O は呼び出し側)。

/**
 * 実行プロファイル名(runs/<name>.json の <name>)の妥当性検証。showInputBox の validateInput 形式
 * (問題なければ null)。呼び出し側は trim 済みの値を渡すこと(前後空白があれば防御的に弾く)。
 * 判定順は下の if 列挙順に依存する。
 */
export function validateNewRunProfileName(name: string, existing: readonly string[]): string | null {
  if (name !== name.trim()) {
    return "プロファイル名の前後に空白を含めることはできません。";
  }
  if (name.length === 0) {
    return "プロファイル名を入力してください。";
  }
  if (name.includes("/") || name.includes("\\")) {
    return 'プロファイル名に "/" や "\\" は使えません。';
  }
  if (name.startsWith(".")) {
    return 'プロファイル名を "." で始めることはできません。';
  }
  if (existing.includes(name)) {
    return `実行プロファイル「${name}」は既に存在します。`;
  }
  return null;
}

/**
 * 新規実行プロファイル(runs/<name>.json)の初期内容(整形済みJSON、末尾改行あり)を作る。
 * machine が空文字ならキー自体を省略する(必須項目だが自動生成時点では決まらないことがあるため)。
 */
export function buildRunProfileTemplate(
  machine: string,
  appNames: readonly string[],
  machineDeviceNames: readonly string[],
): string {
  const app = appNames[0] ?? "";
  const devices =
    machineDeviceNames.length > 0
      ? machineDeviceNames.map((name) => ({ name }))
      : [{ name: "" }];
  const template: Record<string, unknown> = {};
  if (machine !== "") {
    template.machine = machine;
  }
  template.app = app;
  template.devices = devices;
  template.heal = false;
  template.iosInappEngine = true;
  template.wipeDataOnBloat = true;
  template.reportDir = "reports";
  return `${JSON.stringify(template, null, 2)}\n`;
}

// ---- アプリプロファイル自体の追加/コピー/名前変更(名前検証) -------------------------------
// monitorPanel.ts の handleAppProfileAdd/Copy/Rename が使う純粋ロジック(ファイル I/O は呼び出し側)。

/**
 * アプリプロファイル名(apps/<name>.json の <name>)の妥当性検証。validateNewRunProfileName と
 * 同一ロジック(前後空白・空文字・"/" "\" ・"." 始まり・重複、大文字小文字を区別)。
 * マシンプロファイルと違いローカルマシン登録名との整合が不要なため、大文字小文字無視の重複判定
 * (validateNewMachineProfileName)は行わない。
 */
export function validateNewAppProfileName(name: string, existing: readonly string[]): string | null {
  if (name !== name.trim()) {
    return "アプリプロファイル名の前後に空白を含めることはできません。";
  }
  if (name.length === 0) {
    return "アプリプロファイル名を入力してください。";
  }
  if (name.includes("/") || name.includes("\\")) {
    return 'アプリプロファイル名に "/" や "\\" は使えません。';
  }
  if (name.startsWith(".")) {
    return 'アプリプロファイル名を "." で始めることはできません。';
  }
  if (existing.includes(name)) {
    return `アプリプロファイル「${name}」は既に存在します。`;
  }
  return null;
}

// ---- プロファイルタブ下半分: 実行プロファイルの設定フォーム -----------------------------
// handleRunProfileLoad/Save(monitorPanel.ts)が使う、JSON⇔フォーム10フィールド変換の純粋関数
// (未知キー保持のイミュータブルな方針。updateDeviceInMachineProfile と同じ)。

/** 実行プロファイル設定フォームの10フィールド(全て文字列/配列/真偽値化済み。空文字は未設定)。 */
export interface RunProfileFormFields {
  readonly machine: string;
  readonly app: string;
  readonly devices: readonly string[];
  readonly heal: boolean;
  readonly iosInappEngine: boolean;
  readonly reportDir: string;
  readonly defaultTimeout: string;
  readonly wipeDataOnBloat: boolean;
  readonly wipeDataThresholdGB: string;
  readonly locale: string;
}

/**
 * runs/<name>.json のトップレベルから、フォームの10フィールドを許容的に読み取る(トップレベルが
 * 非オブジェクトなら null)。各キーは欠落・型不正を「読めなければ空/既定値」で許容し、スキーマ
 * 妥当性検証はしない(保存時 updateRunProfileInObject・CLI 側 ProfileResolver.validate に委ねる)。
 * defaultTimeout/wipeDataThresholdGB は number ならそのまま String() 化する(0.5 のような
 * スキーマ違反値もそのまま表示し、整数化はしない)。
 */
export function parseRunProfileForForm(profileObject: unknown): RunProfileFormFields | null {
  // 配列も typeof "object" だが、トップレベルとしては不正なので弾く(他の同様関数と同じ判定)。
  if (typeof profileObject !== "object" || profileObject === null || Array.isArray(profileObject)) {
    return null;
  }
  const source = profileObject as Record<string, unknown>;
  const machine = typeof source.machine === "string" ? source.machine : "";
  const app = typeof source.app === "string" ? source.app : "";
  const reportDir = typeof source.reportDir === "string" ? source.reportDir : "";
  const locale = typeof source.locale === "string" ? source.locale : "";
  const heal = typeof source.heal === "boolean" ? source.heal : false;
  const iosInappEngine = typeof source.iosInappEngine === "boolean" ? source.iosInappEngine : true;
  const wipeDataOnBloat = typeof source.wipeDataOnBloat === "boolean" ? source.wipeDataOnBloat : true;
  const devices: string[] = Array.isArray(source.devices)
    ? source.devices
        .map((device) => (isRecord(device) && typeof device.name === "string" ? device.name : undefined))
        .filter((name): name is string => name !== undefined)
    : [];
  const rawTimeout = source.defaultTimeout;
  const defaultTimeout =
    typeof rawTimeout === "number" ? String(rawTimeout) : typeof rawTimeout === "string" ? rawTimeout : "";
  const rawThreshold = source.wipeDataThresholdGB;
  const wipeDataThresholdGB =
    typeof rawThreshold === "number" ? String(rawThreshold) : typeof rawThreshold === "string" ? rawThreshold : "";
  return { machine, app, devices, heal, iosInappEngine, reportDir, defaultTimeout, wipeDataOnBloat, wipeDataThresholdGB, locale };
}

export type RunProfileUpdateResult =
  | { readonly ok: true; readonly object: Record<string, unknown> }
  | { readonly ok: false; readonly error: string };

/**
 * runs/<name>.json を、フォームの10フィールドの内容で更新した新オブジェクトを組み立てる
 * (未知キー保持のイミュータブルな方針。profileObject が非オブジェクトなら ok:false)。
 * defaultTimeout は空文字ならキー削除、正の整数文字列以外はエラー。
 * wipeDataThresholdGB は空文字ならキー削除、正の数(小数許容)文字列以外はエラー。
 * devices は fields.devices の順に並べ直し、既存 devices 配列の同名エントリ(未知キー込み)を
 * 再利用する(新規名は { name } のみ追加。同名重複があれば最初の1件を採用)。
 */
export function updateRunProfileInObject(
  profileObject: unknown,
  fields: RunProfileFormFields,
): RunProfileUpdateResult {
  if (typeof profileObject !== "object" || profileObject === null || Array.isArray(profileObject)) {
    return { ok: false, error: "実行プロファイルの形式が不正です。" };
  }
  const source = profileObject as Record<string, unknown>;
  const result: Record<string, unknown> = { ...source };

  for (const key of ["machine", "app", "reportDir"] as const) {
    const value = fields[key].trim();
    if (value.length === 0) {
      delete result[key];
    } else {
      result[key] = value;
    }
  }

  result.heal = fields.heal;
  result.iosInappEngine = fields.iosInappEngine;
  result.wipeDataOnBloat = fields.wipeDataOnBloat;

  const timeoutTrimmed = fields.defaultTimeout.trim();
  if (timeoutTrimmed.length === 0) {
    delete result.defaultTimeout;
  } else if (!/^\d+$/.test(timeoutTrimmed) || Number(timeoutTrimmed) <= 0) {
    return { ok: false, error: "defaultTimeout は正の整数で入力してください。" };
  } else {
    result.defaultTimeout = Number(timeoutTrimmed);
  }

  const thresholdTrimmed = fields.wipeDataThresholdGB.trim();
  if (thresholdTrimmed.length === 0) {
    delete result.wipeDataThresholdGB;
  } else if (!/^\d+(\.\d+)?$/.test(thresholdTrimmed) || Number(thresholdTrimmed) <= 0) {
    return { ok: false, error: "wipeDataThresholdGB は正の数(GB)で入力してください。" };
  } else {
    result.wipeDataThresholdGB = Number(thresholdTrimmed);
  }

  const localeTrimmed = fields.locale.trim();
  if (localeTrimmed.length === 0) {
    delete result.locale;
  } else if (!/^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$/.test(localeTrimmed)) {
    return { ok: false, error: "locale は ja_JP のような形式で入力してください。" };
  } else {
    result.locale = localeTrimmed;
  }

  const existingDevices = Array.isArray(source.devices) ? source.devices : [];
  const existingByName = new Map<string, Record<string, unknown>>();
  for (const device of existingDevices) {
    if (isRecord(device) && typeof device.name === "string" && !existingByName.has(device.name)) {
      existingByName.set(device.name, device);
    }
  }
  result.devices = fields.devices.map((name) => existingByName.get(name) ?? { name });

  return { ok: true, object: result };
}

// ---- プロファイルタブ中段: アプリプロファイルの設定フォーム -------------------------------
// handleAppProfileLoad/Save(monitorPanel.ts)が使う、JSON⇔フォーム common/ios/android 3グループ
// 変換の純粋関数(parseRunProfileForForm/updateRunProfileInObject と同じ方針)。
// autoInstall は common に一本化済み(ios/android に残存していると Swift 側 validate が警告する)。

/** アプリプロファイル common セクション。app/appPath は廃止済み(ランタイムは common のこれらを
 * 無視する)のため ios/android(AppProfilePlatformFields)と型を分離。 */
export interface AppProfileCommonFields {
  readonly appName: string;
  readonly autoInstall: "true" | "false";
}

/** アプリプロファイル ios/android セクションの3フィールド。autoInstall は common に一本化済みの
 * ためここには持たない。 */
export interface AppProfilePlatformFields {
  readonly appName: string;
  readonly app: string;
  readonly appPath: string;
}

/** アプリプロファイル設定フォームの common/ios/android 3グループ分のフィールド。 */
export interface AppProfileFormFields {
  readonly common: AppProfileCommonFields;
  readonly ios: AppProfilePlatformFields;
  readonly android: AppProfilePlatformFields;
}

const EMPTY_APP_PROFILE_COMMON_FIELDS: AppProfileCommonFields = {
  appName: "",
  autoInstall: "false",
};

const EMPTY_APP_PROFILE_PLATFORM_FIELDS: AppProfilePlatformFields = {
  appName: "",
  app: "",
  appPath: "",
};

/** apps/<name>.json の common セクションを許容的に読み取る(非オブジェクトなら空セクション扱い)。
 * app/appPath は common では廃止のため読み取らない(残っていても無視)。 */
function parseAppProfileCommonSection(value: unknown): AppProfileCommonFields {
  if (!isRecord(value)) {
    return EMPTY_APP_PROFILE_COMMON_FIELDS;
  }
  const appName = typeof value.appName === "string" ? value.appName : "";
  const autoInstall = value.autoInstall === true ? "true" : "false";
  return { appName, autoInstall };
}

/** apps/<name>.json の ios/android セクションを許容的に読み取る(非オブジェクトなら空セクション扱い)。
 * autoInstall は common 側で読むためここでは読まない。 */
function parseAppProfilePlatformSection(value: unknown): AppProfilePlatformFields {
  if (!isRecord(value)) {
    return EMPTY_APP_PROFILE_PLATFORM_FIELDS;
  }
  const appName = typeof value.appName === "string" ? value.appName : "";
  const app = typeof value.app === "string" ? value.app : "";
  const appPath = typeof value.appPath === "string" ? value.appPath : "";
  return { appName, app, appPath };
}

/** apps/<name>.json のトップレベルから common/ios/android 3グループを読み取る(非オブジェクトなら null)。 */
export function parseAppProfileForForm(profileObject: unknown): AppProfileFormFields | null {
  if (typeof profileObject !== "object" || profileObject === null || Array.isArray(profileObject)) {
    return null;
  }
  const source = profileObject as Record<string, unknown>;
  return {
    common: parseAppProfileCommonSection(source.common),
    ios: parseAppProfilePlatformSection(source.ios),
    android: parseAppProfilePlatformSection(source.android),
  };
}

export type AppProfileUpdateResult =
  | { readonly ok: true; readonly object: Record<string, unknown> }
  | { readonly ok: false; readonly error: string };

/**
 * common セクションを fields で更新した新オブジェクトを組み立てる(未知キー保持)。
 * autoInstall は "false" ならキー削除(既定と同値のため書かない)。app/appPath は廃止済みのため
 * 値に関わらず常に削除する(残存が「common でも効く」と読み手を誤解させるため)。
 * existing が undefined かつ appName空/autoInstall=false(値が何も無い)なら undefined を返し
 * セクション自体を作らない。existing が定義済み(空オブジェクト含む)ならセクションは保持する。
 */
function updateAppProfileCommonSection(
  existing: Record<string, unknown> | undefined,
  fields: AppProfileCommonFields,
): Record<string, unknown> | undefined {
  const trimmedAppName = fields.appName.trim();
  const hasAnyValue = trimmedAppName !== "" || fields.autoInstall === "true";
  if (existing === undefined && !hasAnyValue) {
    return undefined;
  }
  const result: Record<string, unknown> = { ...(existing ?? {}) };
  if (trimmedAppName.length === 0) {
    delete result.appName;
  } else {
    result.appName = trimmedAppName;
  }
  if (fields.autoInstall === "true") {
    result.autoInstall = true;
  } else {
    delete result.autoInstall;
  }
  delete result.app;
  delete result.appPath;
  return result;
}

/**
 * ios/android セクションを fields で更新した新オブジェクトを組み立てる(updateAppProfileCommonSection
 * と同じ方針)。autoInstall は common に一本化済みのため値に関わらず常に削除する(廃止分の掃除)。
 * 新規セクション作成の要否(hasAnyValue)は appName/app/appPath の3項目のみで判定する。
 */
function updateAppProfilePlatformSection(
  existing: Record<string, unknown> | undefined,
  fields: AppProfilePlatformFields,
): Record<string, unknown> | undefined {
  const hasAnyValue = fields.appName.trim() !== "" || fields.app.trim() !== "" || fields.appPath.trim() !== "";
  if (existing === undefined && !hasAnyValue) {
    return undefined;
  }
  const result: Record<string, unknown> = { ...(existing ?? {}) };
  for (const key of ["appName", "app", "appPath"] as const) {
    const value = fields[key].trim();
    if (value.length === 0) {
      delete result[key];
    } else {
      result[key] = value;
    }
  }
  delete result.autoInstall;
  return result;
}

/**
 * apps/<name>.json を common/ios/android 3グループの内容で更新した新オブジェクトを組み立てる
 * (未知キー保持。profileObject が非オブジェクトなら ok:false)。各セクションの構築は
 * updateAppProfileCommonSection/updateAppProfilePlatformSection を参照。
 */
export function updateAppProfileInObject(
  profileObject: unknown,
  fields: AppProfileFormFields,
): AppProfileUpdateResult {
  if (typeof profileObject !== "object" || profileObject === null || Array.isArray(profileObject)) {
    return { ok: false, error: "アプリプロファイルの形式が不正です。" };
  }
  const source = profileObject as Record<string, unknown>;
  const result: Record<string, unknown> = { ...source };

  const existingCommon = isRecord(source.common) ? (source.common as Record<string, unknown>) : undefined;
  const updatedCommon = updateAppProfileCommonSection(existingCommon, fields.common);
  if (updatedCommon === undefined) {
    delete result.common;
  } else {
    result.common = updatedCommon;
  }

  for (const key of ["ios", "android"] as const) {
    const existingSection = isRecord(source[key]) ? (source[key] as Record<string, unknown>) : undefined;
    const updated = updateAppProfilePlatformSection(existingSection, fields[key]);
    if (updated === undefined) {
      delete result[key];
    } else {
      result[key] = updated;
    }
  }

  return { ok: true, object: result };
}

// ---- マシンプロファイル(プロファイルタブ): 一覧表示・デバイスカタログ・デバイス追加 ------------------
// 契約:
//   `ftester api device-catalog`(引数なし): stdout に単発 JSON 1行(DeviceCatalog の形。各配列は
//   表示順=先頭がドロップダウンの既定値)。「+新規作成」が使う。
//   `ftester api create-device --project <P> --machine <M> --platform ios|android --name <名>
//   --model <id> --os <id> [--no-register]`: stdout に NDJSON({"kind":"log",...} × n →
//   {"kind":"finished","ok":bool,"error":string|null,"device":{...}|null})。--no-register は
//   物理作成のみ行いマシンプロファイルへの追記をスキップする(#device-pick-overlay の「+」から
//   開いた新規作成モーダルが使う)。
//   `ftester api installed-devices`(引数なし): stdout に単発 JSON 1行(InstalledDevices の形。
//   インストール済み実機一覧)。「+既存から選択」が追加候補として使う。device-catalog(新規作成用
//   カタログ)とは別物 — こちらは「既に作成済みの実体」の一覧。

/** machines/<name>.json の devices[] 1件分。config.ts の MachineDeviceEntry と構造的に同一だが、
 * vscode 非依存を保つため独立定義する(型のためだけに config.ts を import させない方針)。 */
export interface MachineDeviceEntry {
  readonly name: string;
  readonly platform: MonitorPlatform;
  readonly simulator?: string;
  readonly os?: string;
  readonly udid?: string;
  readonly port?: number;
  readonly avd?: string;
}

/**
 * machineDevicesSync(webview→host)メッセージの add[] 1件分。「+既存から選択」モーダルで
 * 新たにチェックした(未登録だった)iOS シミュレータ/Android AVD 1件を表す(MachineDeviceEntry
 * と違い、追加前なので port は持たない — ポートは追加後に右ペインの編集フォームで設定する)。
 * - iOS: { platform:"ios", name:<シミュレータ名>, simulator:<シミュレータ名>, os:<os>, udid:<udid> }
 * - Android: { platform:"android", name:<displayName>, avd:<id> }
 */
export interface MachineDeviceAddEntry {
  readonly platform: MonitorPlatform;
  readonly name: string;
  readonly simulator?: string;
  readonly os?: string;
  readonly udid?: string;
  readonly avd?: string;
}

export interface AndroidCatalogModel {
  readonly id: string;
  readonly name: string;
}

export interface AndroidCatalogSystemImage {
  readonly abi: string;
  readonly apiLevel: number;
  readonly package: string;
  readonly tag: string;
  readonly versionName: string;
}

export interface AndroidCatalog {
  readonly available: boolean;
  readonly error: string | null;
  readonly models: readonly AndroidCatalogModel[];
  readonly systemImages: readonly AndroidCatalogSystemImage[];
}

export interface IosCatalogDeviceType {
  readonly identifier: string;
  readonly name: string;
  readonly productFamily: string;
}

export interface IosCatalogRuntime {
  readonly identifier: string;
  readonly name: string;
  readonly version: string;
}

export interface IosCatalog {
  readonly available: boolean;
  readonly error: string | null;
  readonly deviceTypes: readonly IosCatalogDeviceType[];
  readonly runtimes: readonly IosCatalogRuntime[];
}

/** `ftester api device-catalog` の stdout 1行(単発 JSON)の形。 */
export interface DeviceCatalog {
  readonly android: AndroidCatalog;
  readonly ios: IosCatalog;
}

function isAndroidCatalogModel(value: unknown): value is AndroidCatalogModel {
  return isRecord(value) && typeof value.id === "string" && typeof value.name === "string";
}

function isAndroidCatalogSystemImage(value: unknown): value is AndroidCatalogSystemImage {
  return (
    isRecord(value) &&
    typeof value.abi === "string" &&
    typeof value.apiLevel === "number" &&
    typeof value.package === "string" &&
    typeof value.tag === "string" &&
    typeof value.versionName === "string"
  );
}

function isIosCatalogDeviceType(value: unknown): value is IosCatalogDeviceType {
  return (
    isRecord(value) &&
    typeof value.identifier === "string" &&
    typeof value.name === "string" &&
    typeof value.productFamily === "string"
  );
}

function isIosCatalogRuntime(value: unknown): value is IosCatalogRuntime {
  return (
    isRecord(value) &&
    typeof value.identifier === "string" &&
    typeof value.name === "string" &&
    typeof value.version === "string"
  );
}

function isAndroidCatalog(value: unknown): value is AndroidCatalog {
  return (
    isRecord(value) &&
    typeof value.available === "boolean" &&
    (value.error === null || typeof value.error === "string") &&
    Array.isArray(value.models) &&
    value.models.every(isAndroidCatalogModel) &&
    Array.isArray(value.systemImages) &&
    value.systemImages.every(isAndroidCatalogSystemImage)
  );
}

function isIosCatalog(value: unknown): value is IosCatalog {
  return (
    isRecord(value) &&
    typeof value.available === "boolean" &&
    (value.error === null || typeof value.error === "string") &&
    Array.isArray(value.deviceTypes) &&
    value.deviceTypes.every(isIosCatalogDeviceType) &&
    Array.isArray(value.runtimes) &&
    value.runtimes.every(isIosCatalogRuntime)
  );
}

/** device-catalog の stdout が DeviceCatalog として妥当か判定(内部要素が1つでも不正なら false、
 * isMonitorEvent と同じ安全側の方針)。 */
export function isDeviceCatalogJson(value: unknown): value is DeviceCatalog {
  return isRecord(value) && isAndroidCatalog(value.android) && isIosCatalog(value.ios);
}

// ---- 「+既存から選択」モーダル(#device-pick-overlay): インストール済みデバイス一覧 --------------
// `ftester api installed-devices` の stdout 1行(単発 JSON)。DeviceCatalog とは別契約(既に
// ローカル作成済みの実体一覧)。

export interface InstalledAndroidAvd {
  readonly displayName: string;
  readonly id: string;
}

export interface InstalledAndroidDevices {
  readonly available: boolean;
  readonly avds: readonly InstalledAndroidAvd[];
  readonly error: string | null;
}

export interface InstalledIosDevice {
  readonly name: string;
  readonly os: string;
  readonly udid: string;
}

export interface InstalledIosDevices {
  readonly available: boolean;
  readonly devices: readonly InstalledIosDevice[];
  readonly error: string | null;
}

/** `ftester api installed-devices` の stdout 1行(単発 JSON)の形。 */
export interface InstalledDevices {
  readonly android: InstalledAndroidDevices;
  readonly ios: InstalledIosDevices;
}

function isInstalledAndroidAvd(value: unknown): value is InstalledAndroidAvd {
  return isRecord(value) && typeof value.displayName === "string" && typeof value.id === "string";
}

function isInstalledIosDevice(value: unknown): value is InstalledIosDevice {
  return (
    isRecord(value) &&
    typeof value.name === "string" &&
    typeof value.os === "string" &&
    typeof value.udid === "string"
  );
}

function isInstalledAndroidDevices(value: unknown): value is InstalledAndroidDevices {
  return (
    isRecord(value) &&
    typeof value.available === "boolean" &&
    (value.error === null || typeof value.error === "string") &&
    Array.isArray(value.avds) &&
    value.avds.every(isInstalledAndroidAvd)
  );
}

function isInstalledIosDevices(value: unknown): value is InstalledIosDevices {
  return (
    isRecord(value) &&
    typeof value.available === "boolean" &&
    (value.error === null || typeof value.error === "string") &&
    Array.isArray(value.devices) &&
    value.devices.every(isInstalledIosDevice)
  );
}

/** installed-devices の stdout が InstalledDevices として妥当か判定(isDeviceCatalogJson と同じ方針)。 */
export function isInstalledDevicesJson(value: unknown): value is InstalledDevices {
  return isRecord(value) && isInstalledAndroidDevices(value.android) && isInstalledIosDevices(value.ios);
}

/** create-device の finished イベントに含まれる、実際に作成されたデバイスの情報。 */
export interface CreateDeviceResultDevice {
  readonly avd: string | null;
  readonly name: string;
  readonly udid: string | null;
}

export interface CreateDeviceLogEvent {
  readonly kind: "log";
  readonly message: string;
}

export interface CreateDeviceFinishedEvent {
  readonly kind: "finished";
  readonly ok: boolean;
  readonly error: string | null;
  readonly device: CreateDeviceResultDevice | null;
}

/** `ftester api create-device` の NDJSON 1行分のイベント(kind で判別。isDeviceOpEvent と対になる形)。 */
export type CreateDeviceEvent = CreateDeviceLogEvent | CreateDeviceFinishedEvent;

function isCreateDeviceResultDevice(value: unknown): value is CreateDeviceResultDevice {
  return (
    isRecord(value) &&
    (value.avd === null || typeof value.avd === "string") &&
    typeof value.name === "string" &&
    (value.udid === null || typeof value.udid === "string")
  );
}

/** CreateDeviceEvent の判定(isDeviceOpEvent と同じ方針)。finished.device は失敗時省略されうるため
 * null/undefined 両方許容する。 */
export function isCreateDeviceEvent(value: unknown): value is CreateDeviceEvent {
  if (!isRecord(value) || typeof value.kind !== "string") {
    return false;
  }
  switch (value.kind) {
    case "log":
      return typeof value.message === "string";
    case "finished":
      return (
        typeof value.ok === "boolean" &&
        (value.error === null || typeof value.error === "string") &&
        (value.device === null || value.device === undefined || isCreateDeviceResultDevice(value.device))
      );
    default:
      return false;
  }
}

/**
 * マシンプロファイルのデバイス一覧2行目の詳細文字列。iOS: simulator優先(os があれば併記)、
 * 無ければ udid 先頭8文字、それも無ければ "iOS"。Android: avd があれば "AVD: "+avd、無ければ "Android"。
 */
export function machineDeviceDetail(entry: MachineDeviceEntry): string {
  if (entry.platform === "ios") {
    if (entry.simulator) {
      return entry.os ? `${entry.simulator} / iOS ${entry.os}` : entry.simulator;
    }
    if (entry.udid) {
      return entry.udid.slice(0, 8);
    }
    return "iOS";
  }
  return entry.avd ? `AVD: ${entry.avd}` : "Android";
}

/** デバイス追加モーダルの新規デバイス名検証(webview 内の複製版が入力中の検証にも使う)。 */
export function validateNewDeviceName(name: string, existing: readonly string[]): string | null {
  const trimmed = name.trim();
  if (trimmed.length === 0) {
    return "デバイス名を入力してください。";
  }
  if (existing.includes(trimmed)) {
    return `「${trimmed}」は既に存在します。`;
  }
  return null;
}

// ---- マシンプロファイル自体の追加/名前変更(マシン名横の [+]/[✏] アイコンボタン) ----------------
// monitorPanel.ts の handleMachineProfileAdd/handleMachineProfileRename が使う純粋ロジック
// (ファイル I/O は呼び出し側)。

/**
 * マシンプロファイル名(machines/<name>.json の <name>)の妥当性検証(validateNewRunProfileName と
 * 同様の検証項目)。ただし重複チェックは大文字小文字を無視する(macOS の既定ファイルシステムは
 * 大文字小文字を区別しないため、大文字違いの名前が同一ファイルを指してしまうのを防ぐ)。
 */
export function validateNewMachineProfileName(name: string, existing: readonly string[]): string | null {
  if (name !== name.trim()) {
    return "マシンプロファイル名の前後に空白を含めることはできません。";
  }
  if (name.length === 0) {
    return "マシンプロファイル名を入力してください。";
  }
  if (name.includes("/") || name.includes("\\")) {
    return 'マシンプロファイル名に "/" や "\\" は使えません。';
  }
  if (name.startsWith(".")) {
    return 'マシンプロファイル名を "." で始めることはできません。';
  }
  const lowerName = name.toLowerCase();
  if (existing.some((item) => item.toLowerCase() === lowerName)) {
    return `マシンプロファイル「${name}」は既に存在します。`;
  }
  return null;
}

// ---- デバイス行の右クリックメニュー「削除」(プロファイルタブ) -----------------------------
// handleMachineDeviceRemove(monitorPanel.ts)が使う純粋関数(ファイル I/O は呼び出し側)。

/**
 * machines/<name>.json から ios/android 両セクションの devices[] を走査し、name に一致するエントリを
 * 全て取り除いた新オブジェクトを返す(未知キー保持)。profileObject が非オブジェクトなら null
 * (「不正なファイル」)。removed は1件も取り除けなければ false(「対象が見つからなかった」の判定に使う。
 * null とは別のケースなので注意)。
 */
export function removeDeviceFromMachineProfile(
  profileObject: unknown,
  name: string,
): { readonly object: Record<string, unknown>; readonly removed: boolean } | null {
  if (typeof profileObject !== "object" || profileObject === null || Array.isArray(profileObject)) {
    return null;
  }
  const source = profileObject as Record<string, unknown>;
  const result: Record<string, unknown> = { ...source };
  let removed = false;

  for (const platform of ["ios", "android"] as const) {
    const section = source[platform];
    if (typeof section !== "object" || section === null || Array.isArray(section)) {
      continue;
    }
    const sectionRecord = section as Record<string, unknown>;
    const devices = sectionRecord.devices;
    if (!Array.isArray(devices)) {
      continue;
    }
    const filtered = devices.filter((device) => {
      if (typeof device !== "object" || device === null || Array.isArray(device)) {
        return true; // 型不正の要素はこの操作の対象外として保持する
      }
      return (device as Record<string, unknown>).name !== name;
    });
    if (filtered.length !== devices.length) {
      removed = true;
      result[platform] = { ...sectionRecord, devices: filtered };
    }
  }

  return { object: result, removed };
}

// ---- プロファイルタブ右ペインの編集フォーム「確定」(machineDeviceUpdate) -----------------------
// handleMachineDeviceUpdate(monitorPanel.ts)が使う純粋関数(ファイル I/O は呼び出し側)。

/** 編集フォームから送られる、trim 済み文字列のみのフィールド一式(空文字は「未入力/対象外」)。 */
export interface MachineDeviceUpdateFields {
  readonly name: string;
  readonly simulator: string;
  readonly os: string;
  readonly udid: string;
  readonly port: string;
  readonly avd: string;
}

export type MachineDeviceUpdateResult =
  | { readonly ok: true; readonly object: Record<string, unknown>; readonly name: string }
  | { readonly ok: false; readonly error: string };

/** value がデバイスエントリ(オブジェクト、配列でない)として扱ってよいか。 */
function isDeviceEntryLike(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * machines/<name>.json の platform セクション内 name===originalName の最初のエントリを fields で
 * 更新した新オブジェクトを返す(未知キー保持)。profileObject 非オブジェクト、対象セクション/
 * devices[]/該当エントリ無し、新名が空、新名が他デバイス(対象自身除く)と重複、のいずれかで ok:false。
 * port は 0〜65535 の整数文字列以外はエラー。反対プラットフォームのフィールドには触れない(理由は
 * 下の port 処理コメント参照)。
 */
export function updateDeviceInMachineProfile(
  profileObject: unknown,
  platform: MonitorPlatform,
  originalName: string,
  fields: MachineDeviceUpdateFields,
): MachineDeviceUpdateResult {
  if (typeof profileObject !== "object" || profileObject === null || Array.isArray(profileObject)) {
    return { ok: false, error: "マシンプロファイルの形式が不正です。" };
  }
  const source = profileObject as Record<string, unknown>;
  const notFoundError = { ok: false as const, error: `デバイス「${originalName}」が見つかりませんでした。` };

  const section = source[platform];
  if (!isDeviceEntryLike(section)) {
    return notFoundError;
  }
  const devices = section.devices;
  if (!Array.isArray(devices)) {
    return notFoundError;
  }
  const index = devices.findIndex((device) => isDeviceEntryLike(device) && device.name === originalName);
  if (index === -1) {
    return notFoundError;
  }
  const target = devices[index] as Record<string, unknown>;

  const newName = fields.name.trim();
  if (newName.length === 0) {
    return { ok: false, error: "デバイス名を入力してください。" };
  }
  for (const p of ["ios", "android"] as const) {
    const otherSection = source[p];
    if (!isDeviceEntryLike(otherSection) || !Array.isArray(otherSection.devices)) {
      continue;
    }
    for (const device of otherSection.devices) {
      if (device === target || !isDeviceEntryLike(device)) {
        continue; // 対象エントリ自身は重複チェックから除く
      }
      if (device.name === newName) {
        return { ok: false, error: `「${newName}」は既に存在します。` };
      }
    }
  }

  const newEntry: Record<string, unknown> = { ...target, name: newName };
  if (platform === "ios") {
    // port は iOS 分岐内でのみ設定/削除する(反対プラットフォームには触れない方針)。Android は
    // port を持たず常に空文字を送るため、分岐の外で処理すると avd 編集で port キーが黙って消える。
    const portTrimmed = fields.port.trim();
    if (portTrimmed.length === 0) {
      delete newEntry.port;
    } else {
      if (!/^\d+$/.test(portTrimmed) || Number(portTrimmed) > 65535) {
        return { ok: false, error: "port は 0〜65535 の整数で入力してください。" };
      }
      newEntry.port = Number(portTrimmed);
    }
    for (const key of ["simulator", "os", "udid"] as const) {
      const value = fields[key].trim();
      if (value.length === 0) {
        delete newEntry[key];
      } else {
        newEntry[key] = value;
      }
    }
  } else {
    const value = fields.avd.trim();
    if (value.length === 0) {
      delete newEntry.avd;
    } else {
      newEntry.avd = value;
    }
  }

  const newDevices = devices.slice();
  newDevices[index] = newEntry;
  const newObject: Record<string, unknown> = {
    ...source,
    [platform]: { ...section, devices: newDevices },
  };
  return { ok: true, object: newObject, name: newName };
}

// ---- 「+既存から選択」モーダル(#device-pick-overlay)の OK(machineDevicesSync) -----------------
// handleMachineDevicesSync(monitorPanel.ts)が使う純粋関数(ファイル I/O は呼び出し側)。
// syncDevicesInMachineProfile が addDevicesToMachineProfile と removeDeviceFromMachineProfile を
// 合成し、add/remove(差分)を1つのプロファイル更新にまとめる。

export type AddDevicesToMachineProfileResult =
  | { readonly ok: true; readonly object: Record<string, unknown>; readonly added: readonly string[] }
  | { readonly ok: false; readonly error: string };

/**
 * machines/<name>.json へ entries(machineDevicesSync の add)を ios/android 両セクション末尾に
 * 追記した新オブジェクトを返す(未知キー保持)。profileObject 非オブジェクトなら ok:false。
 * 名前衝突(既存デバイス名 or 同一バッチ内)は "名前 (2)"、"名前 (3)" ... と自動採番で解決する
 * (チェック時点では衝突が無くても追加までの間にファイルが変わりうるため、エラーにせず救済する)。
 * added は entries と同じ順序で最終的に使われた名前を返す。
 */
export function addDevicesToMachineProfile(
  profileObject: unknown,
  entries: readonly MachineDeviceAddEntry[],
): AddDevicesToMachineProfileResult {
  if (typeof profileObject !== "object" || profileObject === null || Array.isArray(profileObject)) {
    return { ok: false, error: "マシンプロファイルの形式が不正です。" };
  }
  const source = profileObject as Record<string, unknown>;
  const result: Record<string, unknown> = { ...source };

  // ios/android 横断で既存デバイス名を集める(同一バッチ内で確定した名前も随時追加し、
  // バッチ内衝突も検出する)。
  const existingNames = new Set<string>();
  for (const platform of ["ios", "android"] as const) {
    const section = source[platform];
    if (isDeviceEntryLike(section) && Array.isArray(section.devices)) {
      for (const device of section.devices) {
        if (isDeviceEntryLike(device) && typeof device.name === "string") {
          existingNames.add(device.name);
        }
      }
    }
  }

  const added: string[] = [];
  const newEntriesByPlatform: Record<MonitorPlatform, Record<string, unknown>[]> = { ios: [], android: [] };

  for (const entry of entries) {
    let name = entry.name;
    let suffix = 2;
    while (existingNames.has(name)) {
      name = `${entry.name} (${suffix})`;
      suffix += 1;
    }
    existingNames.add(name);
    added.push(name);

    const deviceEntry: Record<string, unknown> = { name };
    if (entry.simulator) {
      deviceEntry.simulator = entry.simulator;
    }
    if (entry.os) {
      deviceEntry.os = entry.os;
    }
    if (entry.udid) {
      deviceEntry.udid = entry.udid;
    }
    if (entry.avd) {
      deviceEntry.avd = entry.avd;
    }
    newEntriesByPlatform[entry.platform].push(deviceEntry);
  }

  for (const platform of ["ios", "android"] as const) {
    const newEntries = newEntriesByPlatform[platform];
    if (newEntries.length === 0) {
      continue;
    }
    const section = source[platform];
    const sectionRecord = isDeviceEntryLike(section) ? section : {};
    const existingDevices = Array.isArray(sectionRecord.devices) ? sectionRecord.devices : [];
    result[platform] = { ...sectionRecord, devices: [...existingDevices, ...newEntries] };
  }

  return { ok: true, object: result, added };
}

export type SyncDevicesInMachineProfileResult =
  | {
      readonly ok: true;
      readonly object: Record<string, unknown>;
      readonly added: readonly string[];
      readonly removed: number;
    }
  | { readonly ok: false; readonly error: string };

/**
 * remove の各名前を順次除去(見つからない名前はスキップ、removed は実際に除去できた数のみ)し、
 * その結果へ add を追記する。削除→追加の順序が重要(名前衝突の自動サフィックスは除去後の状態を
 * 基準に判定されるため、外して同名で付け直すケースが成立する)。profileObject 非オブジェクトなら
 * ok:false。
 */
export function syncDevicesInMachineProfile(
  profileObject: unknown,
  add: readonly MachineDeviceAddEntry[],
  remove: readonly string[],
): SyncDevicesInMachineProfileResult {
  if (typeof profileObject !== "object" || profileObject === null || Array.isArray(profileObject)) {
    return { ok: false, error: "マシンプロファイルの形式が不正です。" };
  }
  let current: unknown = profileObject;
  let removedCount = 0;
  for (const name of remove) {
    const result = removeDeviceFromMachineProfile(current, name);
    if (!result) {
      // removeDeviceFromMachineProfile は object 入力に対し常に非null を返すため実際には到達しないが、
      // 型上 null を返しうるための防御(削除しない)。
      return { ok: false, error: "マシンプロファイルの形式が不正です。" };
    }
    current = result.object;
    if (result.removed) {
      removedCount += 1;
    }
  }
  const addResult = addDevicesToMachineProfile(current, add);
  if (!addResult.ok) {
    return addResult;
  }
  return { ok: true, object: addResult.object, added: addResult.added, removed: removedCount };
}
