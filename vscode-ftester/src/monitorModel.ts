// monitorModel.ts
// `ftester api monitor` が1行ずつ出力する NDJSON の生値(unknown)を、デバイスモニターの
// webview へ postMessage する型付きメッセージへ変換・検証する純粋関数群。
// vscode モジュールに一切依存しない(monitorPanel.ts からも test/monitorModel.test.mjs からも
// 同じロジックを使えるようにするため。ndjson.ts/stepsModel.ts と同じ方針)。
//
// 契約(別エージェント実装中の `ftester api monitor --project <P> [--interval <秒>]
// [--max-width <px>] [--profile <run>]` の stdout NDJSON):
//   {"kind":"monitorDevices","devices":[{"id":..,"name":..,"platform":"ios"|"android",
//     "state":"connected"|"booted"|"offline","detail":".."}]}   … サイクル毎
//   {"kind":"monitorFrame","device":"..","jpegBase64":"..","width":480,"height":1040}
//     … connected デバイスのみ、約interval秒毎
//   {"kind":"monitorError","device":"..","message":".."}         … device は省略されうる
//
// webview 側との通信は postMessage/onDidReceiveMessage の JSON なので、双方向のメッセージ型と
// 検証関数もここにまとめる。

export type MonitorPlatform = "ios" | "android";
export type MonitorDeviceState = "connected" | "booted" | "offline";

export interface MonitorDevice {
  readonly id: string;
  readonly name: string;
  readonly platform: MonitorPlatform;
  readonly state: MonitorDeviceState;
  readonly detail: string;
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
  return (
    typeof value.id === "string" &&
    typeof value.name === "string" &&
    typeof value.platform === "string" &&
    PLATFORMS.has(value.platform) &&
    typeof value.state === "string" &&
    STATES.has(value.state) &&
    typeof value.detail === "string"
  );
}

/**
 * value が MonitorEvent として扱ってよいか判定する。既知の kind 以外(将来の追加や壊れた行)や
 * 必須フィールドの欠落・型不一致は false を返すので、呼び出し側は安全に無視できる。
 * (device 等、契約上省略されうるフィールドは undefined を許容する。)
 */
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
    }
  | { readonly type: "deviceError"; readonly device?: string; readonly message: string }
  | { readonly type: "bootBusy"; readonly busy: boolean }
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
      /**
       * 対象プロジェクトのアプリプロファイル名一覧(Projects/<project>/profiles/apps/ 直下)。
       * 「プロファイル」タブ下半分の実行プロファイル設定フォーム(アプリ選択)が使う。
       * 既存の(デバイスタブの)applyProfileInfo はこのフィールドを無視するだけなので後方互換。
       */
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
          // 右ペインの編集フォームを組み立てるための生フィールド(MachineDeviceEntry と同じ形)。
          // undefined のフィールドは webview へは省略されうる(postMessage の JSON 化で自然に落ちる)。
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
      // finished イベントの device(avd/udid のみ。name は上の name フィールドと役割が重複するため
      // 含めない)。ok:false、または finished に device が無かった場合は null(2026-07-11 指示:
      // ピッカーの「+」から register:false で作成した場合、webview 側がここの udid/avd を使って
      // installedDevices 再読込後に該当行を自動チェックする[pendingAutoCheck]ため必要になった)。
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
  // 同モーダルの OK(machineDevicesSync)への応答(handleMachineDevicesSync)。ok:true のときの
  // added は新たに追記できた件数(名前衝突の自動サフィックス適用後)、removed は実際に登録解除
  // できた件数(プロファイルに存在しなかった名前は黙ってスキップされ、この数には含まれない)。
  // ok:true ならモーダルは閉じ、一覧は直後の machineProfileInfo 再送(postMachineProfileInfo)で
  // 最新化される(machineDeviceUpdateResult と同じ方針)。
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
  // マシンプロファイル自体の追加(machineProfileAdd)/名前変更(machineProfileRename)の直後に、
  // webview 側の選択(selectedMachine)を新プロファイルへ移すための通知。削除(machineProfileDelete)
  // 後の選択の付け替えは webview 側の既存フォールバック(machineProfileInfo受信時の current→先頭)
  // に任せるため、こちらは送らない。
  | { readonly type: "machineProfileSelected"; readonly name: string }
  // ---- プロファイルタブ下半分: 実行プロファイルの設定フォーム ---------------------------
  // 実行プロファイル自体の追加(profileAdd)/コピー(profileCopy)/名前変更(profileRename)の直後に、
  // webview 側の選択(実行プロファイルセクションの編集対象)を新プロファイルへ移すための通知
  // (machineProfileSelected と同じ趣旨)。削除(profileDelete)後の選択の付け替えは webview 側の
  // 既存フォールバック(profileInfo受信時の current→先頭)に任せるため、こちらは送らない。
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
  // runs/<name>.json の FileSystemWatcher(onDidChange)による外部編集の通知。name は拡張子なしの
  // basename(Create/Delete は既存の profileInfo 再送のみで足りるため、Change だけこの専用通知を
  // 追加する)。
  | { readonly type: "runProfileFileChanged"; readonly name: string }
  // ---- プロファイルタブ中段: アプリプロファイルの設定フォーム -----------------------------
  // 実行プロファイルセクション(runProfileSelected/runProfileData/runProfileSaveResult/
  // runProfileFileChanged)と同一設計。アプリプロファイル自体の追加(appProfileAdd)/コピー
  // (appProfileCopy)/名前変更(appProfileRename)の直後に、webview 側の選択(編集対象)を新プロファイル
  // へ移すための通知(runProfileSelected と同じ趣旨。削除後の選択の付け替えは webview 側の既存
  // フォールバックに任せるため、こちらは送らない)。
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
  // 名前入力モーダル(#name-input-overlay)を開く。実行/アプリ/マシンプロファイルの追加・コピー・
  // 名前変更(9箇所、monitorPanel.ts の promptName)に共通で使う。id は拡張側(nameInputSeq)で
  // 採番する使い捨てトークンで、webview からの nameInputConfirm/nameInputCancel と対応付ける。
  | {
      readonly type: "nameInputOpen";
      readonly id: number;
      readonly title: string;
      readonly value: string;
      readonly noun: string;
      readonly dupLabel: string;
      readonly existing: readonly string[];
      readonly caseInsensitiveDup: boolean;
    };

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
  // webview スクリプトの初期化完了(全リスナー登録済み)を拡張側へ通知する。これを受けてから
  // 拡張側は初期状態(laneHydrate/profileInfo等)を送る(ready ハンドシェイク。html設定直後の
  // postMessage はリスナー登録前のレースで捨てられるため、一度きりの送信はこの通知を待つ)。
  | { readonly type: "ready" }
  | { readonly type: "devicesUp" }
  | { readonly type: "devicesDown" }
  | { readonly type: "restartMonitor" }
  | { readonly type: "deviceOp"; readonly name: string; readonly op: DeviceOpKind }
  | { readonly type: "selectProfile"; readonly profile: string }
  // 実行プロファイルの追加/コピー/名前変更/削除(プロファイルタブ下半分の実行プロファイル
  // セクションのアイコンボタン。マシンプロファイルの追加/コピー/削除/名前変更と同じ構成)。
  // コピー/名前変更/削除の対象は profile(空文字は「対象なし」= 不正入力として扱うため、検証で弾く)。
  | { readonly type: "profileAdd" }
  | { readonly type: "profileCopy"; readonly profile: string }
  | { readonly type: "profileRename"; readonly profile: string }
  | { readonly type: "profileDelete"; readonly profile: string }
  // マシンプロファイル(プロファイルタブ)。machines/*.json の FileSystemWatcher とは別に、
  // webview 側から明示的に再取得したい場合のための手動リクエスト。
  | { readonly type: "machineProfileRefresh" }
  // マシンプロファイル自体の追加/コピー/削除/名前変更(マシン名横のアイコンボタン)。追加は対象を
  // 指さないため引数なし。コピー/削除/名前変更は machine(対象マシン名)を1件指すため、
  // profileCopy/profileRename/profileDelete と同じ理由で空文字は不正として弾く。
  | { readonly type: "machineProfileAdd" }
  | { readonly type: "machineProfileCopy"; readonly machine: string }
  | { readonly type: "machineProfileDelete"; readonly machine: string }
  | { readonly type: "machineProfileRename"; readonly machine: string }
  // デバイス追加モーダルを開いた直後に送る、`ftester api device-catalog` の再取得リクエスト。
  | { readonly type: "deviceCatalogRequest" }
  // デバイス追加モーダルの OK クリック。全フィールド非空文字列であることを検証する
  // (空文字は「未選択/未入力」を意味しうるため不正として弾く。selectProfile と違い、
  // これらは必ず有効な値を指すため)。
  | {
      readonly type: "createDevice";
      readonly machine: string;
      readonly platform: MonitorPlatform;
      readonly name: string;
      readonly model: string;
      readonly os: string;
      // true: 従来どおり物理作成(simctl/avdmanager)+マシンプロファイルへの即登録を行う。
      // false: 物理作成のみ(ホストが `--no-register` を付与)。マシンプロファイルへの登録は
      // 呼び出し側(#device-pick-overlay の「+」から開いた場合)が別途 machineDevicesSync で行う
      // (2026-07-11 指示: ピッカー経由の新規作成は「作成直後に登録」ではなく「OK で登録」にするため。
      // .profile-actions の「+新規作成」から直接開いた場合は従来どおり register:true を送る)。
      readonly register: boolean;
    }
  // 「+既存から選択」モーダル(#device-pick-overlay)が開いた直後に送る、
  // `ftester api installed-devices` の再取得リクエスト(deviceCatalogRequest と同じ趣旨)。
  | { readonly type: "installedDevicesRequest" }
  // 同モーダルの OK クリック。チェックボックスの意味を「登録状態そのもの」に変更したため、
  // 送るのは全チェック済み一覧ではなく行ごとの初期状態からの差分のみ: add は新たにチェックした
  // (未登録だった)デバイスへ追記するエントリ、remove は逆にチェックを外した(登録済みだった)
  // デバイスの、マシンプロファイル上の名前(削除対象)。machine は対象を1件指すため createDevice
  // と同じ理由で空文字を弾く。add/remove はそれぞれ単独では空配列でもよい(片方だけの差分もある)が、
  // 両方空はあり得ない(webview 側は差分が無ければ OK ボタン自体を無効化して送らせない設計のため。
  // それでも防御的に、ここでの検証では両方空を不正として弾く)。
  | {
      readonly type: "machineDevicesSync";
      readonly machine: string;
      readonly add: readonly MachineDeviceAddEntry[];
      readonly remove: readonly string[];
    }
  // デバイス行の右クリックメニュー「削除」。machine は「対象を1件指す」ため createDevice と同じ
  // 理由で空文字を弾く。names は複数選択時の一括削除に対応するため配列(単一削除も要素数1の配列
  // として送る。要件5)。空配列は「対象なし」を意味するため不正として弾く。
  | { readonly type: "machineDeviceRemove"; readonly machine: string; readonly names: readonly string[] }
  // プロファイルタブ右ペインの編集フォーム「確定」。fields は全てクライアント側で trim 済みの
  // string(空文字は「未入力/対象プラットフォーム外」を意味する。createDevice と違い、name 以外は
  // 空文字を許容する必要があるため、machine/originalName のみ非空文字列を要求する)。
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
  // プロファイルタブ下半分: 実行プロファイル設定フォームの選択変更・初回表示時のロード要求。
  // profile は「対象なし」を表せない(runs/<name>.json を1件指す必要がある)ため、
  // profileCopy 等と同じ理由で空文字は不正として弾く。
  | { readonly type: "runProfileLoad"; readonly profile: string }
  // 同フォームの「確定」。fields は全てクライアント側で trim 済み(machineDeviceUpdate と同じ方針。
  // ただし machine/app は必須項目なので空文字はクライアント側検証で弾かれた上で送られてくる想定。
  // それでも防御的に、ここでの型検証自体は空文字を許容する)。
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
  // アプリプロファイル設定フォームの選択変更・初回表示時のロード要求(runProfileLoad と同じ方針。
  // profile は「対象なし」を表せないため空文字は不正入力として弾く)。
  | { readonly type: "appProfileLoad"; readonly profile: string }
  // 同フォームの「確定」。fields は全てクライアント側で trim 済み(runProfileSave と同じ方針。
  // ただしアプリプロファイルは全フィールド省略可のため、機械的な必須検証は無い)。
  | {
      readonly type: "appProfileSave";
      readonly profile: string;
      readonly fields: AppProfileFormFields;
    }
  // 名前入力モーダル(#name-input-overlay)の OK/キャンセル。id は nameInputOpen で払い出したものを
  // そのまま返す(拡張側が pendingNameInput.id と突き合わせ、一致しなければ無視する)。
  | { readonly type: "nameInputConfirm"; readonly id: number; readonly name: string }
  | { readonly type: "nameInputCancel"; readonly id: number };

/**
 * value が machineDevicesSync メッセージの add[] 1件分(MachineDeviceAddEntry)として扱って
 * よいか判定する。name は「対象を1件指す」ため空文字を弾く(createDevice と同じ理由)。
 * simulator/os/udid/avd は省略されうるオプショナルフィールドなので、値がある場合のみ string
 * 検証する(machineDeviceUpdate の fields とは違い、こちらは空文字を許容する意味を持たない
 * ため undefined か非空 string のみ許容する)。
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

/**
 * value がアプリプロファイル「共通」セクション分のフォームフィールド(表示名+自動インストール)
 * として扱ってよいか判定する。自動インストールの設定場所を common に一本化した(2026-07-11
 * 指示)ため、ここで autoInstall も検証する。2値("true"/"false")のみ受理する
 * (isAppProfilePlatformFieldsLike が以前 autoInstall を検証していたのと同じ方針)。
 */
function isAppProfileCommonFieldsLike(value: unknown): value is AppProfileCommonFields {
  return (
    isRecord(value) &&
    typeof value.appName === "string" &&
    (value.autoInstall === "true" || value.autoInstall === "false")
  );
}

/**
 * value がアプリプロファイル「ios」「android」セクション分のフォームフィールド(3項目)として
 * 扱ってよいか判定する。autoInstall は common に一本化されたため、ここでは検証しない
 * (isAppProfileCommonFieldsLike 側で検証する)。
 */
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
    case "devicesUp":
    case "devicesDown":
    case "restartMonitor":
    case "profileAdd":
      return true;
    case "deviceOp":
      return typeof value.name === "string" && (value.op === "up" || value.op === "down");
    case "selectProfile":
      return typeof value.profile === "string";
    case "profileCopy":
    case "profileRename":
    case "profileDelete":
      // 空文字は「対象プロファイルなし」なので不正入力として弾く(selectProfile と違い、
      // これら3種は必ず既存プロファイルを1件指すため)。
      return typeof value.profile === "string" && value.profile !== "";
    case "machineProfileRefresh":
    case "deviceCatalogRequest":
    case "machineProfileAdd":
    case "installedDevicesRequest":
      return true;
    case "machineProfileCopy":
    case "machineProfileDelete":
    case "machineProfileRename":
      // 空文字は「対象マシンなし」なので不正入力として弾く(profileCopy 等と同じ方針)。
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
      // 空文字は「対象プロファイルなし」なので不正入力として弾く(profileCopy 等と同じ方針)。
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
        typeof value.fields.reportDir === "string" &&
        typeof value.fields.defaultTimeout === "string"
      );
    case "appProfileAdd":
      return true;
    case "appProfileCopy":
    case "appProfileRename":
    case "appProfileDelete":
      // 空文字は「対象アプリプロファイルなし」なので不正入力として弾く(profileCopy 等と同じ方針)。
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

/**
 * タイル右クリックメニューの唯一の項目(起動/停止)の表示状態。
 * op は実際にクリックした際に実行する操作(disabled:true の間はクリック不可)。
 */
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
 * モニターの devices サイクルで届く state と、そのデバイスの現在のキュー状態(busy。無ければ
 * undefined)から、タイル右クリックメニューに表示する唯一の項目を決める
 * (monitorPanel.ts のコンテキストメニュー・実行中バッジ・webview 複製が使う)。
 * busy が無い場合、offline なら「起動」(op:"up")、connected/booted なら「停止」(op:"down")。
 * busy.status が "queued"(直列キューの順番待ち)なら「待機中...」、"running"(実行中)なら
 * その操作に応じた「起動中...」/「停止中...」になる(どちらも disabled:true)。
 * MonitorDeviceState の全パターンをカバーするため null にはならない。
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
// 「デバイスを全て起動/終了」(bulk)とタイル個別の起動/停止(device)は、ブリッジ供給・simctl・adb
// が競合しないよう単一の直列キューで1件ずつ実行する(FTAndroid の DeviceBooter.bootAll が
// 負荷ゲート+直列ブリッジ供給で並行起動時の競合を避けているのと同じ思想。実機ログ解析で、
// 「デバイスを全て起動」とタイル右クリックの個別起動が並行実行されるとブリッジ供給の
// waitUntilReady が失敗し、ゾンビブリッジが蓄積することが分かっている)。
//
// ここでは実際のプロセス起動(spawn)は行わない、vscode 非依存の純粋な状態管理だけを持つ。
// monitorPanel.ts が enqueueDeviceLifecycleJob で積んだジョブを deviceLifecycleQueueHead() で
// 取り出して実行し、完了したら dequeueDeviceLifecycleJob() で先頭を取り除いて次を実行する
// (常に entries[0] が「現在実行中のジョブ」という不変条件を保つ FIFO)。

export type DeviceOpQueueStatus = "queued" | "running";

/** キューに積む1件のデバイスライフサイクル操作。全台(bulk)/1台(device)の2種別。 */
export type DeviceLifecycleJob =
  | { readonly kind: "bulk"; readonly op: "up" | "down" }
  | { readonly kind: "device"; readonly name: string; readonly op: DeviceOpKind };

/** 直列キューの状態(不変)。jobs[0] が実行中、それ以降が待機中。 */
export interface DeviceLifecycleQueueState {
  readonly jobs: readonly DeviceLifecycleJob[];
}

export function createDeviceLifecycleQueueState(): DeviceLifecycleQueueState {
  return { jobs: [] };
}

/** ジョブをキュー末尾に積む(新しい state を返す。呼び出し側は戻り値で置き換えること)。 */
export function enqueueDeviceLifecycleJob(
  state: DeviceLifecycleQueueState,
  job: DeviceLifecycleJob,
): DeviceLifecycleQueueState {
  return { jobs: [...state.jobs, job] };
}

/** 実行完了したジョブ(先頭)をキューから取り除く。空のキューに対して呼ぶのはバグなので例外を投げる。 */
export function dequeueDeviceLifecycleJob(state: DeviceLifecycleQueueState): DeviceLifecycleQueueState {
  if (state.jobs.length === 0) {
    throw new Error("dequeueDeviceLifecycleJob: キューが空です(先頭ジョブの完了通知が重複した可能性)");
  }
  return { jobs: state.jobs.slice(1) };
}

/** キューに何か(実行中含む)積まれているか。true の間はグローバルボタン(全て起動/終了)を無効化する。 */
export function isDeviceLifecycleQueueBusy(state: DeviceLifecycleQueueState): boolean {
  return state.jobs.length > 0;
}

/** 先頭(=現在実行すべき/実行中の)ジョブ。キューが空なら undefined。 */
export function deviceLifecycleQueueHead(state: DeviceLifecycleQueueState): DeviceLifecycleJob | undefined {
  return state.jobs[0];
}

/** 指定デバイス名を対象にした device ジョブが既にキュー内(実行中含む)にあるか(連打防止に使う)。 */
export function hasDeviceLifecycleJobFor(state: DeviceLifecycleQueueState, name: string): boolean {
  return state.jobs.some((job) => job.kind === "device" && job.name === name);
}

/**
 * 指定デバイス名の現在のキュー状態(実行中/待機中)を返す。対象ジョブが無ければ undefined。
 * 先頭(index 0)なら "running"、それ以外(まだ順番が回ってきていない)なら "queued"。
 */
export function deviceLifecycleStatusFor(
  state: DeviceLifecycleQueueState,
  name: string,
): DeviceOpBusyState | undefined {
  const index = state.jobs.findIndex((job) => job.kind === "device" && job.name === name);
  if (index === -1) {
    return undefined;
  }
  const job = state.jobs[index];
  if (!job || job.kind !== "device") {
    return undefined;
  }
  return { op: job.op, status: index === 0 ? "running" : "queued" };
}

// ---- モニターの pause/resume 制御(パネル発の「全て終了」「停止」実行中に使う) ---------------
// `ftester api monitor` は stdin から NDJSON 1行で {"cmd":"pause"} / {"cmd":"resume"} を
// 受け付ける(Sources/ftester/ApiMonitorCommand.swift 参照)。down 系ジョブ(bulk down /
// device-down)の実行直前に pause、完了時(成功・失敗問わず)に resume を送ることで、片付け中の
// デバイスへモニターがスクショ取得に行って過渡的な警告を吐くのを防ぐ。up 系ジョブ(bulk up /
// device-up)では pause しない(起動進行をタイルで見たいため)。

export type MonitorControlCommand = "pause" | "resume";

/**
 * ジョブの実行前後でモニターの pause/resume が必要かどうか(down 系のみ true)。
 * bulk/device いずれのジョブも op フィールドが "up" | "down" で共通なので、job.kind に
 * 関わらず単純に op で判定できる。
 */
export function deviceLifecycleJobNeedsMonitorPause(job: DeviceLifecycleJob): boolean {
  return job.op === "down";
}

/** モニターの stdin に書き込む制御コマンドの NDJSON 1行(末尾に改行を含む)。 */
export function monitorControlLine(cmd: MonitorControlCommand): string {
  return `${JSON.stringify({ cmd })}\n`;
}

// ---- 実行プロファイル切り替え時の自動シャットダウン対象算出 ------------------------------------
// 要件: プロファイル切り替え(ftester.profile 変更)で「デバイスを全て起動/終了」ボタンの対象が
// 新プロファイルのデバイスに変わるのに合わせて、切り替え先プロファイルに定義されていない
// 稼働中デバイスはシャットダウンする。逆に、切り替え先プロファイルに定義されているデバイスは
// (稼働中でも offline でも)一切触らない — 自動起動はしない。稼働中ならそのまま利用を続けられる
// ようにする(monitorPanel.ts の restartMonitorIfScopeChanged がこの結果を down ジョブとしてキューに積む)。

/**
 * 直近に観測されたデバイス一覧(旧スコープの最終観測)と、切り替え先プロファイルのデバイス名一覧
 * (null = プロファイルなし = 全デバイスが対象なので何も止めない)から、シャットダウンすべき
 * デバイス名を返す(元の順序を保つ)。
 * - newScopeNames が null: [](絞り込みが無くなる=全デバイスが対象内なので停止対象なし)。
 * - それ以外: state が "offline" でない(=稼働中の) かつ newScopeNames に含まれない name。
 *   ("offline" のデバイスは既に停止しているので対象外。newScopeNames に含まれるデバイスは
 *   稼働中でもそのまま — 自動起動しないのと対で、自動停止もしない。)
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
// monitorPanel.ts の profileAdd/profileCopy ハンドラが使う純粋ロジック。ファイルI/O自体は
// vscode 依存(fs)なので monitorPanel.ts 側で行い、ここでは「名前が妥当か」「初期内容は何か」
// だけを扱う(config.ts の listRunProfileNames 等と同じ、vscode 非依存の方針)。

/**
 * 新規/コピー先の実行プロファイル名(runs/<name>.json の <name>)として妥当かどうかを検証する。
 * showInputBox の validateInput にそのまま渡せる形(問題なければ null、そうでなければ表示用の
 * 日本語エラーメッセージ)。呼び出し側は trim 済みの値を渡すこと(このためnameがtrim結果と
 * 一致しない=前後に空白を含む入力も、それ自体を不正として弾く。呼び出し側の trim 有無に
 * 依存しない防御的な検証にするため)。
 * 不正となる条件(優先順に判定):
 * - 前後に空白を含む(=trim済みでない)
 * - 空文字
 * - "/" または "\" を含む(runs/<name>.json のファイル名になるため、パス区切りは使えない)
 * - "." で始まる(隠しファイル的な名前を避ける)
 * - existing(既存プロファイル名一覧)に含まれる(重複)
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
 * 新規実行プロファイル(runs/<name>.json)の初期内容(整形済みJSON文字列、末尾改行あり)を作る。
 * machine が非空なら先頭に `machine` キーを含める(空文字は「使用するマシンプロファイルが
 * 決まらなかった」を意味するため、キー自体を省略する。既存プロファイルに machine が無いことがある
 * 後方互換の方針とも合わせ、必須項目だが自動生成時点では埋められないこともあるため)。
 * app は appNames の先頭(候補が無ければ空文字。ユーザーが編集画面で埋める前提)、devices は
 * machineDeviceNames から `{"name": ...}` の配列を作る(候補が無ければ空文字1件のプレースホルダー)。
 * heal/reportDir はスキーマの既定値をそのまま書き出す。
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
  template.reportDir = "reports";
  return `${JSON.stringify(template, null, 2)}\n`;
}

// ---- アプリプロファイル自体の追加/コピー/名前変更(名前検証) -------------------------------
// monitorPanel.ts の handleAppProfileAdd/Copy/Rename ハンドラが使う純粋ロジック。ファイルI/O自体は
// vscode 依存(fs)なので monitorPanel.ts 側で行う(validateNewRunProfileName と同じ方針)。

/**
 * 新規/コピー先/リネーム後のアプリプロファイル名(apps/<name>.json の <name>)として妥当かどうかを
 * 検証する。showInputBox の validateInput にそのまま渡せる形(問題なければ null、そうでなければ
 * 表示用の日本語エラーメッセージ)。呼び出し側は trim 済みの値を渡すこと(validateNewRunProfileName
 * と同じ防御的な検証方針)。
 * 検証項目は validateNewRunProfileName と同一(前後空白・空文字・"/" "\" ・"." 始まり・重複、
 * いずれも大文字小文字を区別する。マシンプロファイルと違い、apps/*.json はローカルマシン登録名
 * との整合を取る必要が無いため validateNewMachineProfileName のような大文字小文字無視の重複判定は
 * 不要)。
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
// runProfileLoad/runProfileSave(monitorPanel.ts の handleRunProfileLoad/handleRunProfileSave)が
// 使う純粋関数。ファイルI/O自体は vscode 依存(fs)なので monitorPanel.ts 側で行い、ここでは
// 「JSON オブジェクト ⇔ フォームの6フィールド」の変換ロジックだけを扱う(updateDeviceInMachineProfile
// と同じ、未知キー保持のイミュータブルな方針)。

/** 実行プロファイル設定フォームの6フィールド(全て文字列/配列/真偽値化済み。空文字は未設定)。 */
export interface RunProfileFormFields {
  readonly machine: string;
  readonly app: string;
  readonly devices: readonly string[];
  readonly heal: boolean;
  readonly reportDir: string;
  readonly defaultTimeout: string;
}

/**
 * runs/<name>.json のトップレベルオブジェクトから、実行プロファイル設定フォームの6フィールド分の
 * 値を許容的に読み取る。トップレベルが非オブジェクトなら null(呼び出し側は「不正なファイル」として
 * 扱う)。各キーは欠落・型不正を許容し、以下のように緩く読む(スキーマとしての妥当性検証は
 * 保存時(updateRunProfileInObject)・CLI 側(ProfileResolver.validate)が行うため、ここは
 * 「フォームに表示するための最善の解釈」を返すだけでよい)。
 * - machine/app/reportDir: string ならそのまま、それ以外(欠落・型不正)は ""。
 * - devices: 配列なら各要素から `{ name: string }` の name を抽出する(オブジェクトでない/name が
 *   非文字列の要素はスキップする)。devices 自体が配列でなければ []。
 * - heal: boolean ならそのまま、それ以外(欠落・型不正)は false。
 * - defaultTimeout: number ならそのまま文字列化(String(value)。整数化はしない — 0.5 のような
 *   スキーマ違反の値もそのまま表示し、保存時の検証に委ねる)。string ならそのまま。それ以外
 *   (欠落・他の型)は ""。
 */
export function parseRunProfileForForm(profileObject: unknown): RunProfileFormFields | null {
  // 配列も typeof は "object" だが、実行プロファイルのトップレベルとしては不正なので弾く
  // (updateRunProfileInObject・removeDeviceFromMachineProfile と同じ判定)。
  if (typeof profileObject !== "object" || profileObject === null || Array.isArray(profileObject)) {
    return null;
  }
  const source = profileObject as Record<string, unknown>;
  const machine = typeof source.machine === "string" ? source.machine : "";
  const app = typeof source.app === "string" ? source.app : "";
  const reportDir = typeof source.reportDir === "string" ? source.reportDir : "";
  const heal = typeof source.heal === "boolean" ? source.heal : false;
  const devices: string[] = Array.isArray(source.devices)
    ? source.devices
        .map((device) => (isRecord(device) && typeof device.name === "string" ? device.name : undefined))
        .filter((name): name is string => name !== undefined)
    : [];
  const rawTimeout = source.defaultTimeout;
  const defaultTimeout =
    typeof rawTimeout === "number" ? String(rawTimeout) : typeof rawTimeout === "string" ? rawTimeout : "";
  return { machine, app, devices, heal, reportDir, defaultTimeout };
}

export type RunProfileUpdateResult =
  | { readonly ok: true; readonly object: Record<string, unknown> }
  | { readonly ok: false; readonly error: string };

/**
 * runs/<name>.json のトップレベルオブジェクトを、フォームの6フィールドの内容で更新した新オブジェクト
 * を組み立てる(updateDeviceInMachineProfile と同じ、未知キー保持のイミュータブルな方針。
 * トップレベルの未知キーはスプレッドでそのまま保持し、対象6キーだけ差し替える)。
 * - profileObject がオブジェクト(配列を含まない)でなければ ok:false。
 * - machine/app/reportDir: trim 値をセットする。空はキー削除する(machine はフォーム側で必須検証
 *   済みの想定だが、防御的に空文字も許容してキー削除する)。
 * - heal: そのままセットする(常にキーを持たせる。boolean はどんな値でも有効なため空判定は無い)。
 * - defaultTimeout: 空文字ならキー削除、正の整数の文字列なら number でセット、それ以外はエラー。
 * - devices: fields.devices(名前の配列。表示順=フォームでのチェック順)の順で `{ name }` の配列を
 *   再構成する。既存の devices 配列に同名エントリがあれば、そのエントリ(未知キー込み)をそのまま
 *   再利用する(名前を書き換える必要が無いため)。新規名(既存に無い名前)は `{ name }` だけの
 *   エントリを追加する。既存 devices に同名エントリが複数あった場合は最初の1件を採用する。
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

  const timeoutTrimmed = fields.defaultTimeout.trim();
  if (timeoutTrimmed.length === 0) {
    delete result.defaultTimeout;
  } else if (!/^\d+$/.test(timeoutTrimmed) || Number(timeoutTrimmed) <= 0) {
    return { ok: false, error: "defaultTimeout は正の整数で入力してください。" };
  } else {
    result.defaultTimeout = Number(timeoutTrimmed);
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
// appProfileLoad/appProfileSave(monitorPanel.ts の handleAppProfileLoad/handleAppProfileSave)が
// 使う純粋関数。ファイルI/O自体は vscode 依存(fs)なので monitorPanel.ts 側で行い、ここでは
// 「JSON オブジェクト ⇔ フォームの common(表示名+自動インストール)/ios/android(表示名・
// アプリID・パッケージパス)3グループ」の変換ロジックだけを扱う(parseRunProfileForForm/
// updateRunProfileInObject と同じ、未知キー保持のイミュータブルな方針)。
// 自動インストール(autoInstall)は元々 ios/android セクション別だったが、common でのみ設定できる
// 仕様に一本化した(2026-07-11 指示。Swift 側も同時に common 採用+platform 残存は validate 警告に
// 変更中)。common に appName 以外のフィールドを持たせるのはこれが初めてだが、
// AppProfileCommonFields/AppProfilePlatformFields の型を分けている理由(ランタイムが参照する
// セクションが異なる)自体は変わらない。

/**
 * アプリプロファイル「共通」セクション分のフィールド。表示名(appName)+自動インストール
 * (autoInstall)を持つ。app/appPath は新仕様(ランタイムは common のこれらを無視する)で廃止済み
 * のため、ios/android(AppProfilePlatformFields)と型を分離している。
 */
export interface AppProfileCommonFields {
  readonly appName: string;
  readonly autoInstall: "true" | "false";
}

/**
 * アプリプロファイル「ios」「android」セクション分の3フィールド。
 * autoInstall は common に一本化されたため、ここには持たない(共通セクションでのみ設定する)。
 */
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

/**
 * apps/<name>.json の common セクションの値から表示名(appName)+自動インストール(autoInstall)を
 * 許容的に読み取る。セクション自体が非オブジェクト(欠落・型不正・配列含む)なら空セクション扱い
 * (parseRunProfileForForm の devices 欠落時の扱いと同じ「読めなければ空」の流儀)。
 * - appName: string ならそのまま、それ以外(欠落・型不正)は "".
 * - autoInstall: true のときだけ "true"。それ以外(false・欠落・型不正)は "false"
 *   (自動インストールを common に一本化したことに伴い、旧 parseAppProfilePlatformSection の
 *   autoInstall 読み取りロジックをそのままこちらへ移した)。
 * - app/appPath は common では廃止のため読み取らない(残っていても無視する。フォームにも
 *   フィールド自体が無い)。
 */
function parseAppProfileCommonSection(value: unknown): AppProfileCommonFields {
  if (!isRecord(value)) {
    return EMPTY_APP_PROFILE_COMMON_FIELDS;
  }
  const appName = typeof value.appName === "string" ? value.appName : "";
  const autoInstall = value.autoInstall === true ? "true" : "false";
  return { appName, autoInstall };
}

/**
 * apps/<name>.json の ios/android セクションの値から3フィールド分を許容的に読み取る
 * (parseAppProfileCommonSection と同じ「読めなければ空」の流儀)。
 * - appName/app/appPath: string ならそのまま、それ以外(欠落・型不正)は "".
 * - autoInstall は common に一本化されたため、ここでは読み取らない(残っていても無視する)。
 */
function parseAppProfilePlatformSection(value: unknown): AppProfilePlatformFields {
  if (!isRecord(value)) {
    return EMPTY_APP_PROFILE_PLATFORM_FIELDS;
  }
  const appName = typeof value.appName === "string" ? value.appName : "";
  const app = typeof value.app === "string" ? value.app : "";
  const appPath = typeof value.appPath === "string" ? value.appPath : "";
  return { appName, app, appPath };
}

/**
 * apps/<name>.json のトップレベルオブジェクトから、アプリプロファイル設定フォームの
 * common/ios/android 3グループ分の値を許容的に読み取る。トップレベルが非オブジェクト(配列含む)
 * なら null(呼び出し側は「不正なファイル」として扱う。parseRunProfileForForm と同じ方針)。
 */
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
 * common セクション分のフィールドから、既存セクションオブジェクト(未知キー保持)を更新した
 * 新セクションオブジェクトを組み立てる(updateRunProfileInObject と同じイミュータブルな方針)。
 * - appName: trim 値をセットする。空はキー削除する。
 * - autoInstall: "true" は boolean true をセット、"false" はキー削除する(既定=無効と同値なので
 *   書かずにファイルを最小に保つ。自動インストールを common に一本化したことに伴い、旧
 *   updateAppProfilePlatformSection の autoInstall 書き込みロジックをそのままこちらへ移した)。
 * - app/appPath: 廃止に伴いフォームにフィールド自体が無い(=書き込みようがない)ため常に削除する。
 *   既存ファイルに残っていると「common でも効く」と読み手を誤解させるため、掃除も兼ねて
 *   無条件で削除する。
 * - existing が undefined(セクション自体が元に無かった)場合、appName が空("")かつ autoInstall
 *   が "false"(既定と同値)なら undefined を返す(=セクション自体を作らない。値が1つでもあれば
 *   新規セクションを作る。updateAppProfilePlatformSection の hasAnyValue 判定と同じ方針)。
 *   existing が定義済み(空オブジェクトを含む)なら、値が既定のままでもセクション自体は
 *   (空のまま)保持する。
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
 * ios/android セクション分のフィールドから、既存セクションオブジェクト(未知キー保持)を更新した
 * 新セクションオブジェクトを組み立てる(updateAppProfileCommonSection と同じイミュータブルな方針)。
 * - appName/app/appPath: trim 値をセットする。空はキー削除する。
 * - autoInstall: common に一本化されたため、フォームにフィールド自体が無い(=書き込みようがない)。
 *   既存ファイルに残っていると「platform 側の値が効く」と読み手を誤解させるため、
 *   updateAppProfileCommonSection の app/appPath 常時削除と同じ方針で無条件に削除する
 *   (廃止に伴う掃除)。
 * - existing が undefined の場合の新規セクション作成判定(hasAnyValue)は appName/app/appPath の
 *   3項目のみで判定する(autoInstall は common 側で判定するため、ここには含めない)。
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
 * apps/<name>.json のトップレベルオブジェクトを、フォームの common/ios/android 3グループの内容で
 * 更新した新オブジェクトを組み立てる(updateRunProfileInObject と同じ、未知キー保持のイミュータブル
 * な方針。トップレベルの未知キーはスプレッドでそのまま保持し、対象3キーだけ差し替える)。
 * - profileObject がオブジェクト(配列を含まない)でなければ ok:false。
 * - common は updateAppProfileCommonSection、ios/android は updateAppProfilePlatformSection を
 *   参照(未知キー保持・空セクション保持・新セクションは値がある時だけ作成、の各方針はそちらに
 *   集約する)。
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
// 契約(別エージェント実装中):
//   `ftester api device-catalog`(引数なし): stdout に単発 JSON 1行(DeviceCatalog の形。各配列は
//   表示順=先頭がドロップダウンの既定値)。「+新規作成」(新規シミュレータ/AVDの作成)が使う。
//   `ftester api create-device --project <P> --machine <M> --platform ios|android --name <名>
//   --model <id> --os <id> [--no-register]`: stdout に NDJSON({"kind":"log",...} × n →
//   {"kind":"finished","ok":bool,"error":string|null,"device":{...}|null})。--no-register は
//   物理作成(simctl/avdmanager)のみ行い、マシンプロファイルへの追記をスキップする(2026-07-11
//   指示。#device-pick-overlay の「+」から開いた新規作成モーダルが使う。finished の形は不変)。
//   `ftester api installed-devices`(引数なし): stdout に単発 JSON 1行(InstalledDevices の形。
//   インストール済みの iOS シミュレータ実機一覧・Android AVD 一覧)。「+既存から選択」(#device-pick-
//   overlay)がマシンプロファイルへの追加候補として使う。device-catalog(新規作成用のモデル/OS
//   カタログ)とは別物 — こちらは「既に作成済みの実体」の一覧。

/**
 * machines/<name>.json の devices[] 1件分。config.ts の MachineDeviceEntry と同じ形だが、
 * vscode 非依存を保つためここでも独立して定義する(型のためだけに config.ts を import
 * させない方針。webview 側が monitorModel.ts の関数を複製しているのと同じ理由)。
 * 呼び出し側(monitorPanel.ts)は config.ts の MachineDeviceEntry をそのまま渡せる
 * (構造的に同一の形のため)。
 */
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

/**
 * `ftester api device-catalog` の stdout 1行が DeviceCatalog として扱ってよいか判定する。
 * android/ios いずれかの内部要素が不正なら全体を不合格(false)にする
 * (isMonitorEvent 等と同じ、部分的に壊れた値は安全側で丸ごと無視する方針)。
 */
export function isDeviceCatalogJson(value: unknown): value is DeviceCatalog {
  return isRecord(value) && isAndroidCatalog(value.android) && isIosCatalog(value.ios);
}

// ---- 「+既存から選択」モーダル(#device-pick-overlay): インストール済みデバイス一覧 --------------
// `ftester api installed-devices` の stdout 1行(単発 JSON)の形。DeviceCatalog(新規作成用の
// モデル/OS カタログ)とは別の契約 — こちらは「既にローカルに作成済み」の実体一覧を返す。

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

/**
 * `ftester api installed-devices` の stdout 1行が InstalledDevices として扱ってよいか判定する
 * (isDeviceCatalogJson と同じ、部分的に壊れた値は安全側で丸ごと無視する方針)。
 */
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

/**
 * value が CreateDeviceEvent として扱ってよいか判定する(isDeviceOpEvent と同じ方針)。
 * finished の device フィールドは、失敗時(ok:false)は省略されうる契約のため
 * null/undefined のどちらも許容する。
 */
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
 * マシンプロファイルのデバイス一覧(プロファイルタブ左側)の2行目に表示する詳細文字列。
 * - iOS: simulator があれば simulator( + os があれば " / iOS " + os を続ける)。
 *   simulator が無ければ udid の先頭8文字、それも無ければ "iOS"。
 * - Android: avd があれば "AVD: " + avd、無ければ "Android"。
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

/**
 * デバイス追加モーダルの新規デバイス名として妥当かどうかを検証する(webview 内の複製版が
 * 入力中の検証にも使う)。trim 後空ならエラー、選択中マシンの全デバイス名(ios/android 横断)
 * と重複するならエラー、それ以外は null。
 */
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
// monitorPanel.ts の handleMachineProfileAdd/handleMachineProfileRename が使う純粋ロジック。
// ファイルI/O自体は vscode 依存(fs)なので monitorPanel.ts 側で行う(validateNewRunProfileName と
// 同じ方針)。

/**
 * 新規/リネーム後のマシンプロファイル名(machines/<name>.json の <name>)として妥当かどうかを
 * 検証する。showInputBox の validateInput にそのまま渡せる形(問題なければ null、そうでなければ
 * 表示用の日本語エラーメッセージ)。呼び出し側は trim 済みの値を渡すこと(validateNewRunProfileName
 * と同じ防御的な検証方針)。
 * 検証項目は validateNewRunProfileName と揃える(前後空白・空文字・"/" "\" ・"." 始まり)が、
 * 重複チェックだけは大文字小文字を無視する(macOS の既定ファイルシステムは大文字小文字を
 * 区別しないため、"m1 max" のような大文字違いの名前を許すと同一ファイルを指す2つのプロファイルが
 * できてしまう)。
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
// machineDeviceRemove メッセージのホスト側処理(monitorPanel.ts の handleMachineDeviceRemove)が
// 使う純粋関数。ファイルI/O自体は vscode 依存(fs)なので monitorPanel.ts 側で行い、ここでは
// 「JSON オブジェクトから該当デバイスを取り除いた新オブジェクトを組み立てる」ロジックだけを扱う
// (config.ts の各 list*/read* 関数と同じ、vscode 非依存の方針)。

/**
 * machines/<name>.json のトップレベルオブジェクトから、ios/android 両セクションの devices[] を
 * 走査し、name に完全一致するエントリを全て取り除いた新オブジェクトを組み立てる。
 * - profileObject がオブジェクト(配列を含まない)でなければ null(呼び出し側は「不正なファイル」
 *   として扱う)。
 * - トップレベル・各セクション内・保持されるデバイスエントリの未知キーはすべてそのまま保持する
 *   (スプレッドで複製し、変更したセクションだけ差し替えるため)。
 * - セクションが無い/オブジェクトでない、または devices が配列でない場合はそのセクションに
 *   一切手を加えない(listMachineProfiles・readMachineDeviceNames と同じ「読めなければそのまま」
 *   の流儀)。
 * - removed は ios/android いずれかで1件以上取り除けたら true(name が一致するエントリが
 *   一つも無かった場合は false。呼び出し側はこれを「対象が見つからなかった」の判定に使う)。
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
// handleMachineDeviceUpdate(monitorPanel.ts)が使う純粋関数。ファイルI/O自体は vscode 依存(fs)
// なので monitorPanel.ts 側で行い、ここでは「JSON オブジェクトの対象デバイスを更新した新オブジェクト
// を組み立てる」ロジックだけを扱う(removeDeviceFromMachineProfile と同じ、イミュータブルな方針)。

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
 * machines/<name>.json のトップレベルオブジェクトから、platform セクションの devices[] 内で
 * name===originalName の最初のエントリを見つけ、fields の内容で更新した新オブジェクトを返す。
 * - profileObject がオブジェクト(配列を含まない)でなければ ok:false(「形式が不正」)。
 * - platform セクション/devices[] が無い、または originalName に一致するエントリが無ければ
 *   ok:false(「見つからない」。removeDeviceFromMachineProfile と違い、こちらは対象が1件に
 *   定まらないと更新しようがないため null ではなくエラーとして扱う)。
 * - 新しい name(trim 済みで渡される想定。念のためここでも trim する)が空、または他のデバイス
 *   (ios/android 横断、対象エントリ自身を除く)と重複するなら ok:false。
 * - port は空文字ならキーを削除、非空なら 0〜65535 の整数でなければ ok:false、妥当なら number で
 *   セットする。iOS の simulator/os/udid、Android の avd も同様に空文字ならキー削除・非空なら
 *   trim 済み文字列をセットする(反対プラットフォームのフィールドには一切触れない)。
 * - トップレベル・セクション内・対象エントリ内の未知キーは全て保持する(スプレッドで複製し、
 *   変更したセクション/エントリだけ差し替えるため。removeDeviceFromMachineProfile と同じ方針)。
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
    // port を含む iOS 用フィールドの設定/削除は iOS 分岐の中だけで行う — Android エントリに
    // 手書きの port キー等が万一あっても「反対プラットフォームのフィールドは触らない」方針で保持する
    // (Android のフォームは port を持たず常に空文字を送ってくるため、分岐の外で処理すると
    // avd 編集のついでに port キーが黙って消えてしまう)。
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
// handleMachineDevicesSync(monitorPanel.ts)が使う純粋関数。ファイルI/O自体は vscode 依存(fs)
// なので monitorPanel.ts 側で行い、ここでは「JSON オブジェクトへ複数デバイスを追記/除去した新
// オブジェクトを組み立てる」ロジックだけを扱う(removeDeviceFromMachineProfile/
// updateDeviceInMachineProfile と同じ、未知キー保持のイミュータブルな方針)。チェックボックスが
// 「登録状態そのもの」を表す設計になったため、OK 押下時は行ごとの初期状態からの差分(新たに
// チェック=追加/外した=登録解除)だけを add/remove として送ってもらい、ここではその両方を
// 一つのプロファイル更新にまとめる(syncDevicesInMachineProfile が addDevicesToMachineProfile と
// removeDeviceFromMachineProfile を合成する)。

export type AddDevicesToMachineProfileResult =
  | { readonly ok: true; readonly object: Record<string, unknown>; readonly added: readonly string[] }
  | { readonly ok: false; readonly error: string };

/**
 * machines/<name>.json のトップレベルオブジェクトへ、entries(machineDevicesSync の add)を
 * ios/android 両セクションの devices[] 末尾に追記した新オブジェクトを組み立てる。
 * - profileObject がオブジェクト(配列を含まない)でなければ ok:false(「形式が不正」。
 *   removeDeviceFromMachineProfile が null を返すのと違い、こちらは syncDevicesInMachineProfile
 *   がそのまま ok:false 形で呼び出し元へ伝播できるよう、この形にしている)。
 * - 各エントリは name + 値が非空の(simulator/os/udid/avd のうち該当プラットフォームの)
 *   オプショナルフィールドのみをキーとして構築する(空文字・undefined のフィールドは持たせない)。
 * - 名前の一意化: 既存デバイス名(ios/android 横断)、および同一バッチ内で先に確定した名前と
 *   衝突する場合、"名前 (2)"、"名前 (3)" ... と衝突しなくなるまでサフィックスを付け直す
 *   (validateNewDeviceName のような「エラーにして弾く」ではなく、モーダルでチェックした時点では
 *   衝突が無くても、追加までの間に他の操作でファイルが変わりうるため自動採番で救済する方針)。
 *   added にはこの最終的に使われた名前を、entries と同じ順序で返す。
 * - トップレベル・既存セクション・既存デバイスエントリの未知キーは全て保持する(スプレッドで
 *   複製し、新規デバイスを追記したセクションだけ差し替えるため)。
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

  // ios/android 横断で既存デバイス名を集める(名前の一意化の判定材料。同一バッチ内で確定した
  // 名前もこの Set に随時追加していくことで、バッチ内衝突も検出できる)。
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
 * 「+既存から選択」モーダル(#device-pick-overlay)の OK(machineDevicesSync)が使う純粋関数。
 * remove の各名前を removeDeviceFromMachineProfile で順次除去(見つからない名前はスキップし、
 * removed には実際に除去できた数のみ数える)し、その結果へ addDevicesToMachineProfile で
 * add を追記する(名前衝突の自動サフィックスは除去後の状態を基準に判定されるため、外して
 * 同名で付け直すケースが自然に成立する — 先に削除してから追加する順序が重要)。
 * profileObject がオブジェクト(配列を含まない)でなければ ok:false。
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
      // profileObject は関数冒頭で検証済みで、removeDeviceFromMachineProfile は object の
      // 入力に対して常に非null を返すため実際には到達しないが、型上 null を返しうるための防御。
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
