// monitorDeviceModel.ts
// モニターが扱うデバイスの型と `fleetest api monitor` の NDJSON イベント(vscode に依存しない
// 純粋関数群。monitorPanel.ts と test/monitorModel.test.mjs の両方から同じロジックを使うため。
// ndjson.ts/stepsModel.ts と同じ方針)。
//
// 契約: `fleetest api monitor --project <P> [--interval <秒>] [--max-width <px>] [--profile <run>]`
// の stdout NDJSON:
//   {"kind":"monitorDevices","devices":[{"id":..,"name":..,"platform":"ios"|"android",
//     "state":"connected"|"booted"|"offline","detail":"..","health":string[]|null}]}   … サイクル毎
//     (health は connected な Android エミュレータのみ設定されうる。省略/null/空配列=異常なし。
//     値は "wifi-disabled"|"clock-skew" 等。未知の文字列も受理して保持する)
//     ("renderMode":"gpu"|"cpu"|null も同様。connected な Android エミュレータのみ設定されうる。
//     ブート時固定のため接続中は変化しない値)
//     ("inRun":bool は ApiMonitorCommand.swift の RunLease.isFresh 判定。`fleetest api run` が
//     このデバイスを使用中なら true。null 化されないが読み手は欠落/非bool を false とみなす)
//     ("registered":bool は ApiMonitorCommand.determineStates(includeUnregistered:) が合成した
//     マシンプロファイル未記載の起動中デバイスなら false。欠落/非boolは true とみなす)
//   {"kind":"monitorFrame","device":"..","jpegBase64":"..","width":480,"height":1040}
//     … connected デバイスのみ、約interval秒毎
//   {"kind":"monitorError","device":"..","message":".."}         … device は省略されうる。
//     現行バイナリは送出しない(スクショ変換失敗は stderr のみ。ユーザー決定)が、
//     読み手としては旧バイナリ互換のため受理し続ける
//
// webview 向けメッセージ契約は monitorWebviewMessages.ts、デバイスライフサイクルのキューは
// monitorDeviceLifecycle.ts、プロファイルのフォーム解析/デバイスカタログは monitorProfileForms.ts。
// re-export の窓口は monitorModel.ts(拡張側 import は全てそちら経由)。

import type { MonitorDeviceFilter } from "./config";

/** value がプレーンオブジェクトか(配列・null 除く)。monitorWebviewMessages.ts/monitorDeviceLifecycle.ts/
 * monitorProfileForms.ts も同じ判定基準を使うためここから import する。 */
export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

export type MonitorPlatform = "ios" | "android";
/** "unknown" は**誰も観測していない**の意味(この機械のものではなく、その機械の monitor も
 * 届いていない)。offline(= 止まっている)と区別する —— 向こうで動いていても手元の simctl/adb
 * には映らないので、offline と言うと「起動したのに未起動のまま」に見える(2026-08-17 の実害)。 */
export type MonitorDeviceState = "connected" | "booted" | "offline" | "unknown";
/** デバイスの実体種別(ApiMonitorCommand の kind。旧 CLI 互換のため欠落時は virtual 扱い)。 */
export type MonitorDeviceKind = "virtual" | "physical";

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
  /** デバイスの実体種別。"physical"=実機(iOS 実機は fleetest-simstream が CoreSimulator 私有 API の
   * ため画面配信不可)。欠落("kind" を返さない旧 CLI)は "virtual" に正規化する。 */
  readonly kind: MonitorDeviceKind;
  /** iOS 実機のブリッジ宛先ホスト(USB トンネルは "127.0.0.1"、LAN 経由はその LAN IP)。
   * monitorDeviceStreamController.ts が fleetest-devicepoll の --host に渡す。
   * シミュレータ・Android・ブリッジ未起動は undefined(Swift は null を送るので正規化する)。 */
  readonly host?: string;
  /** iOS ブリッジの実効ポート(connected のときのみ)。fleetest-devicepoll の --port に渡す。
   * Android・未接続は undefined(Swift は null を送るので正規化する)。 */
  readonly port?: number;
  /** `fleetest api run` がこのデバイスを使用中か(ApiMonitorCommand.swift の RunLease.isFresh)。
   * Swift は常に true/false を送るが、欠落・非 bool は false として扱う(isMonitorDevice が正規化)。 */
  readonly inRun?: boolean;
  /** このデバイスが画面録画中か。inRun と同じ契約(Swift は常に true/false を送るが、
   * 欠落・非 bool は false として扱う=isMonitorDevice が正規化。旧バイナリとの互換のため)。 */
  readonly recording?: boolean;
  /** マシンプロファイルに実在するか。false は ApiMonitorCommand.determineStates(includeUnregistered:)
   * が合成した起動中デバイス(未登録)。欠落・非 bool は true に正規化する(旧 CLI 互換。
   * kind と同じ「欠落は従来どおりの表示に寄せる」方針)。 */
  readonly registered?: boolean;
  /** 画面が凍結しているか(一様フレームが2サイクル連続。ApiMonitorCommand の MonitorFrozenDebounce)。
   * **1サイクル遅れる**(devices イベントはフレーム取得より前に出る)。欠落・非 bool は false
   * に正規化する(旧 CLI 互換)。ヘッダの Frozen カウンタとタイルのバッジが消費する。 */
  readonly frozen?: boolean;
  /** このデバイスが居る機械(登録名。手元は undefined)。**`host` はブリッジ宛先の IP で別物**。
   * モニターは手元のデバイスしか触れないので、リモートのタイルは状態を観測できない ——
   * タイルにホスト名を出して「どの機械の台か」を分かるようにする
   * (Sources/fleetest/ApiMonitorCommand.swift の ApiMonitorDeviceInfo.machine と対)。 */
  readonly machine?: string;
}

/** `fleetest api monitor` の NDJSON 1行分のイベント(kind で判別)。 */
export type MonitorEvent =
  | { readonly kind: "monitorDevices"; readonly devices: readonly MonitorDevice[] }
  | {
      readonly kind: "monitorFrame";
      readonly device: string;
      readonly jpegBase64: string;
      readonly width: number;
      readonly height: number;
    }
  | { readonly kind: "monitorError"; readonly device?: string; readonly message: string }
  // `fleetest monitor pause` の保持状態の変化(ApiMonitorHoldEvent)。webview へは送らず
  // OUTPUT ログだけ(配信の停止自体は、hold 中の全タイル state:"unknown" 化で
  // monitorDeviceStreamController の既存の qualifying 判定が畳む)
  | { readonly kind: "monitorHold"; readonly active: boolean };

const PLATFORMS: ReadonlySet<string> = new Set<MonitorPlatform>(["ios", "android"]);
const STATES: ReadonlySet<string> = new Set<MonitorDeviceState>(["connected", "booted", "offline", "unknown"]);

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
  // kind は後から追加したフィールド。欠落・未知値は virtual(=従来の挙動)に寄せる
  if (value.kind !== "physical" && value.kind !== "virtual") {
    value.kind = "virtual";
  }
  if (value.host === null || typeof value.host !== "string") {
    value.host = undefined;
  }
  if (value.port === null || typeof value.port !== "number") {
    value.port = undefined;
  }
  if (value.recording !== true && value.recording !== false) {
    // 欠落/null/型不正を「録画していない」に寄せる(inRun と同じ方針)。
    value.recording = false;
  }
  if (value.registered !== true && value.registered !== false) {
    // 欠落/null/型不正を「登録済み」に寄せる(旧 CLI は registered を送らない=全デバイスが
    // マシンプロファイル記載のみだった挙動を保つ)。
    value.registered = true;
  }
  if (value.frozen !== true && value.frozen !== false) {
    // 欠落/null/型不正を「凍結していない」に寄せる(旧 CLI は frozen を送らない)。
    value.frozen = false;
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
    typeof value.inRun === "boolean" &&
    typeof value.recording === "boolean" &&
    typeof value.registered === "boolean" &&
    typeof value.frozen === "boolean"
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
    case "monitorHold":
      return typeof value.active === "boolean";
    default:
      return false;
  }
}

/**
 * デバイス一覧をプロファイルタブの表示順に整列する:
 * **ios→android → 手元が先 → ホスト名順 → name 順**。
 * プラットフォームが外側なのは、プロファイルタブが ios/android の別セクションを持ち、
 * ホストでのまとまりはその中にあるため(config.ts の listMachineProfiles と同じ規則 —
 * 変更時は両方揃える)。タイルは1列なので、外側=左右のかたまりになる。
 * monitorProcessManager.ts が monitorDevices 受信時に適用し、以降の全消費側
 * (デバイスタブのタイル)はこの順で受け取る。
 */
export function sortMonitorDevices(devices: readonly MonitorDevice[]): MonitorDevice[] {
  return [...devices].sort((a, b) => {
    if (a.platform !== b.platform) {
      return a.platform === "ios" ? -1 : 1;
    }
    const [ha, hb] = [a.machine ?? "", b.machine ?? ""];
    if (ha !== hb) {
      return ha === "" ? -1 : hb === "" ? 1 : ha.localeCompare(hb);  // 手元が先
    }
    return a.name.localeCompare(b.name);
  });
}

// ---- 「起動中のデバイス」(動的プロファイル)------------------------------------------------
// 実行プロファイルではなく表示フィルタ: 監視スコープは「プロファイルなし」(= 全デバイス)のまま、
// タイルに出すのを起動中(タイルが「未起動」表示にならないもの)だけに絞る。選択時は fleetest.profile="" +
// fleetest.monitorDeviceFilter="running" の2設定に分解して保存する(この値自体は fleetest.profile へ
// 保存しない — CLI の --profile へ渡ると実行プロファイル未検出で落ちるため)。
// 同期相手: src/webview/monitor/deviceTiles.js(同名の複製定数。webview は CSP で import 不可)

/** ドロップダウンでの「起動中のデバイス」の予約値。実行プロファイル名としては
 * validateNewRunProfileName が "@" 始まりを予約済みとして弾くため衝突しない。 */
export const RUNNING_DEVICES_PROFILE_VALUE = "@running";

/** filter="running" なら起動中のみに絞る(offline と unknown を除外)。
 * 未登録デバイス(registered===false)は定義上「起動中」なので running では素通りする。
 * **"all" は何も落とさない**(元の順序のまま素通し)。
 *
 * 以前の "all" は registered===false を落としていた(マシンプロファイルタブの一覧と揃える意図)。
 * **これが「(プロファイルなし)で1台も出ない」の正体**(実害 2026-08-28): マシンプロファイルが
 * 2つ以上ある案件では `--profile` 無しの `api monitor` はマシンを決められず、
 * 「起動中のデバイスだけを見る」に縮退して**全台を registered:false で出す**
 * (ApiMonitorCommand の includeUnregistered)。それを丸ごと落としていたので 0 件になっていた。
 * マシンプロファイルが複数あるとき「登録済みの台の一覧」は一意に決まらないので、
 * 縮退そのものは正しい —— 落とす側が間違っていた。
 *
 * **ブリッジ不在の iOS 実機(state==="booted")も出す**(2026-08-26 に方針変更)。以前は
 * 「タイルが未起動表示になるので出さない」として除外していたが、`api monitor` が接続中の実機を
 * 合成するようになった以上、**繋がっている端末を「起動中のデバイス」から隠すほうが実態と食い違う**
 * (ブリッジはタイルのメニューから起こせる。タイル側の表示は deviceTiles.js の bridgeNotRunning のまま)。 */
export function filterMonitorDevices(
  devices: readonly MonitorDevice[],
  filter: MonitorDeviceFilter,
): readonly MonitorDevice[] {
  return filter === "running"
    // unknown(誰も観測していない)は running に含めない —— 動いている根拠が無いものを
    // 「稼働中だけ」の一覧に出すと、その一覧の意味が「稼働中か、分からないもの」になる
    ? devices.filter((device) => device.state !== "offline" && device.state !== "unknown")
    : [...devices];
}
