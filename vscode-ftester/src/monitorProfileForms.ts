// monitorProfileForms.ts
// プロファイルタブ(実行プロファイル・アプリプロファイル・マシンプロファイル)の名前検証、
// JSON⇔フォーム変換、デバイスカタログ/インストール済みデバイス一覧の型と検証を持つ純粋関数群。
// vscode に依存しない(monitorPanel.ts と test/monitorModel.test.mjs の両方から使うため)。
// I/O(ファイル読み書き・CLI 呼び出し)は monitorPanel.ts/monitorProfilesController.ts 側の責務。

import { t } from "./i18n";
import { isRecord, type MonitorPlatform } from "./monitorDeviceModel";

// ---- 実行プロファイルの追加/コピー(名前検証・テンプレート生成) ------------------------------
// monitorPanel.ts の profileAdd/profileCopy ハンドラが使う純粋ロジック(ファイル I/O は呼び出し側)。

/**
 * 実行プロファイル名(runs/<name>.json の <name>)の妥当性検証。showInputBox の validateInput 形式
 * (問題なければ null)。呼び出し側は trim 済みの値を渡すこと(前後空白があれば防御的に弾く)。
 * 判定順は下の if 列挙順に依存する。
 */
export function validateNewRunProfileName(name: string, existing: readonly string[]): string | null {
  if (name !== name.trim()) {
    return t("monitor.runProfile.nameNoSpaces");
  }
  if (name.length === 0) {
    return t("monitor.runProfile.nameRequired");
  }
  if (name.includes("/") || name.includes("\\")) {
    return t("monitor.runProfile.nameNoSlash");
  }
  if (name.startsWith(".")) {
    return t("monitor.runProfile.nameNoDotStart");
  }
  // "@" 始まりはドロップダウンの予約値用(RUNNING_DEVICES_PROFILE_VALUE)。同名プロファイルが
  // 作れると選択値が衝突して解決不能になる。
  if (name.startsWith("@")) {
    return t("monitor.runProfile.nameNoAtStart");
  }
  if (existing.includes(name)) {
    return t("monitor.runProfile.nameExists", { name });
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
  template.fm = true;
  template.heal = true;
  template.falsePositiveCheck = false;
  template.screenIs = true;
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
    return t("monitor.appProfile.nameNoSpaces");
  }
  if (name.length === 0) {
    return t("monitor.appProfile.nameRequired");
  }
  if (name.includes("/") || name.includes("\\")) {
    return t("monitor.appProfile.nameNoSlash");
  }
  if (name.startsWith(".")) {
    return t("monitor.appProfile.nameNoDotStart");
  }
  if (existing.includes(name)) {
    return t("monitor.appProfile.nameExists", { name });
  }
  return null;
}

// ---- プロファイルタブ下半分: 実行プロファイルの設定フォーム -----------------------------
// handleRunProfileLoad/Save(monitorPanel.ts)が使う、JSON⇔フォーム21フィールド変換の純粋関数
// (未知キー保持のイミュータブルな方針。updateDeviceInMachineProfile と同じ)。

/** 実行プロファイル設定フォームの21フィールド(全て文字列/配列/真偽値化済み。空文字は未設定)。
 * recordFailuresOnly/recordBitrateKbps/recordFullResolution は「録画セクション」、heal/
 * falsePositiveCheck/screenIs は「FM」セクション、iosFastInput は「iOS」セクションのサブオプション
 * (親チェックボックスの状態に関わらず独立して保持・保存する。表示上の非表示切替は
 * runProfilesTab.js の責務)。containerInference は独立トグル(FM とは無関係の幾何ヒューリスティック)。 */
export interface RunProfileFormFields {
  readonly machine: string;
  readonly app: string;
  readonly devices: readonly string[];
  readonly fm: boolean;
  readonly heal: boolean;
  readonly falsePositiveCheck: boolean;
  readonly screenIs: boolean;
  readonly containerInference: boolean;
  readonly iosInappEngine: boolean;
  readonly iosFastInput: boolean;
  readonly enableAnimations: boolean;
  readonly reportDir: string;
  readonly defaultTimeout: string;
  readonly wipeDataOnBloat: boolean;
  readonly wipeDataThresholdGB: string;
  readonly recoverCpuFallbackToGpu: boolean;
  readonly locale: string;
  readonly record: boolean;
  readonly recordFailuresOnly: boolean;
  readonly recordBitrateKbps: string;
  readonly recordFullResolution: boolean;
}

/**
 * runs/<name>.json のトップレベルから、フォームの21フィールドを許容的に読み取る(トップレベルが
 * 非オブジェクトなら null)。各キーは欠落・型不正を「読めなければ空/既定値」で許容し、スキーマ
 * 妥当性検証はしない(保存時 updateRunProfileInObject・CLI 側 ProfileResolver.validate に委ねる)。
 * defaultTimeout/wipeDataThresholdGB/recordBitrateKbps は number ならそのまま String() 化する
 * (0.5 のようなスキーマ違反値もそのまま表示し、整数化はしない)。record/recordFailuresOnly/
 * recordFullResolution/iosFastInput/enableAnimations は既定 false、recordBitrateKbps は既定 ""(未設定=CLI側既定1500)。
 * fm/heal/screenIs/containerInference はスキーマ既定と合わせ既定 true、falsePositiveCheck は既定 false。
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
  const fm = typeof source.fm === "boolean" ? source.fm : true;
  const heal = typeof source.heal === "boolean" ? source.heal : true;
  const falsePositiveCheck = typeof source.falsePositiveCheck === "boolean" ? source.falsePositiveCheck : false;
  const screenIs = typeof source.screenIs === "boolean" ? source.screenIs : true;
  const containerInference = typeof source.containerInference === "boolean" ? source.containerInference : true;
  const iosInappEngine = typeof source.iosInappEngine === "boolean" ? source.iosInappEngine : true;
  const iosFastInput = typeof source.iosFastInput === "boolean" ? source.iosFastInput : false;
  const enableAnimations = typeof source.enableAnimations === "boolean" ? source.enableAnimations : false;
  const wipeDataOnBloat = typeof source.wipeDataOnBloat === "boolean" ? source.wipeDataOnBloat : true;
  const recoverCpuFallbackToGpu =
    typeof source.recoverCpuFallbackToGpu === "boolean" ? source.recoverCpuFallbackToGpu : false;
  const record = typeof source.record === "boolean" ? source.record : false;
  const recordFailuresOnly = typeof source.recordFailuresOnly === "boolean" ? source.recordFailuresOnly : false;
  const recordFullResolution = typeof source.recordFullResolution === "boolean" ? source.recordFullResolution : false;
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
  const rawBitrate = source.recordBitrateKbps;
  const recordBitrateKbps =
    typeof rawBitrate === "number" ? String(rawBitrate) : typeof rawBitrate === "string" ? rawBitrate : "";
  return {
    machine,
    app,
    devices,
    fm,
    heal,
    falsePositiveCheck,
    screenIs,
    containerInference,
    iosInappEngine,
    iosFastInput,
    enableAnimations,
    reportDir,
    defaultTimeout,
    wipeDataOnBloat,
    wipeDataThresholdGB,
    recoverCpuFallbackToGpu,
    locale,
    record,
    recordFailuresOnly,
    recordBitrateKbps,
    recordFullResolution,
  };
}

export type RunProfileUpdateResult =
  | { readonly ok: true; readonly object: Record<string, unknown> }
  | { readonly ok: false; readonly error: string };

/**
 * runs/<name>.json を、フォームの21フィールドの内容で更新した新オブジェクトを組み立てる
 * (未知キー保持のイミュータブルな方針。profileObject が非オブジェクトなら ok:false)。
 * defaultTimeout は空文字ならキー削除、正の数(小数許容)文字列以外はエラー。
 * wipeDataThresholdGB は空文字ならキー削除、正の数(小数許容)文字列以外はエラー。
 * recordBitrateKbps は空文字ならキー削除、正の整数文字列以外はエラー。
 * devices は fields.devices の順に並べ直し、既存 devices 配列の同名エントリ(未知キー込み)を
 * 再利用する(新規名は { name } のみ追加。同名重複があれば最初の1件を採用)。
 * record/recordFailuresOnly/recordFullResolution/iosFastInput/enableAnimations は false のとき
 * キー自体を書かない
 * (既定値のノイズを既存プロファイルに足さない。parseRunProfileForForm の「欠落→false」と対で
 * round-trip が安定する)。
 */
export function updateRunProfileInObject(
  profileObject: unknown,
  fields: RunProfileFormFields,
): RunProfileUpdateResult {
  if (typeof profileObject !== "object" || profileObject === null || Array.isArray(profileObject)) {
    return { ok: false, error: t("monitor.runProfile.invalidFormat") };
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

  result.fm = fields.fm;
  result.heal = fields.heal;
  result.falsePositiveCheck = fields.falsePositiveCheck;
  result.screenIs = fields.screenIs;
  result.containerInference = fields.containerInference;
  result.iosInappEngine = fields.iosInappEngine;
  result.wipeDataOnBloat = fields.wipeDataOnBloat;
  for (const key of [
    "record", "recordFailuresOnly", "recordFullResolution", "iosFastInput", "recoverCpuFallbackToGpu",
    "enableAnimations",
  ] as const) {
    if (fields[key]) {
      result[key] = true;
    } else {
      delete result[key];
    }
  }

  const timeoutTrimmed = fields.defaultTimeout.trim();
  if (timeoutTrimmed.length === 0) {
    delete result.defaultTimeout;
  } else if (!/^\d+(\.\d+)?$/.test(timeoutTrimmed) || Number(timeoutTrimmed) <= 0) {
    return { ok: false, error: t("monitor.runProfile.defaultTimeoutInvalid") };
  } else {
    result.defaultTimeout = Number(timeoutTrimmed);
  }

  const thresholdTrimmed = fields.wipeDataThresholdGB.trim();
  if (thresholdTrimmed.length === 0) {
    delete result.wipeDataThresholdGB;
  } else if (!/^\d+(\.\d+)?$/.test(thresholdTrimmed) || Number(thresholdTrimmed) <= 0) {
    return { ok: false, error: t("monitor.runProfile.wipeThresholdInvalid") };
  } else {
    result.wipeDataThresholdGB = Number(thresholdTrimmed);
  }

  const bitrateTrimmed = fields.recordBitrateKbps.trim();
  if (bitrateTrimmed.length === 0) {
    delete result.recordBitrateKbps;
  } else if (!/^\d+$/.test(bitrateTrimmed) || Number(bitrateTrimmed) <= 0) {
    return { ok: false, error: t("monitor.runProfile.recordBitrateInvalid") };
  } else {
    result.recordBitrateKbps = Number(bitrateTrimmed);
  }

  const localeTrimmed = fields.locale.trim();
  if (localeTrimmed.length === 0) {
    delete result.locale;
  } else if (!/^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$/.test(localeTrimmed)) {
    return { ok: false, error: t("monitor.runProfile.localeInvalid") };
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
    return { ok: false, error: t("monitor.appProfile.invalidFormat") };
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
  /** 実体種別。省略=virtual(シミュレータ/エミュレータ)。physical は実機で、
   * 識別子は iOS=udid / Android=serial(Sources/FTCore/RunProfile.swift の DeviceKind と同期)。 */
  readonly kind?: "virtual" | "physical";
  readonly simulator?: string;
  readonly os?: string;
  readonly udid?: string;
  readonly port?: number;
  readonly avd?: string;
  /** Android 実機の adb シリアル(kind=physical のとき必須)。 */
  readonly serial?: string;
  /** 実機の機種名(表示専用。同定には使わない)。 */
  readonly model?: string;
}

/**
 * machineDevicesSync(webview→host)メッセージの add[] 1件分。「+既存から選択」モーダルで
 * 新たにチェックした(未登録だった)iOS シミュレータ/Android AVD 1件を表す(MachineDeviceEntry
 * と違い、追加前なので port は持たない — ポートは追加後に右ペインの編集フォームで設定する)。
 * - iOS: { platform:"ios", name:<シミュレータ名>, simulator:<シミュレータ名>, os:<os>, udid:<udid> }
 * - Android: { platform:"android", name:<displayName>, avd:<id> }
 * 実機は kind:"physical" 付きで、実体を指すのは iOS=udid / Android=serial のみ
 * (simulator/os/avd は持たない)。
 */
export interface MachineDeviceAddEntry {
  readonly platform: MonitorPlatform;
  readonly name: string;
  readonly kind?: "virtual" | "physical";
  readonly simulator?: string;
  readonly os?: string;
  readonly udid?: string;
  readonly avd?: string;
  readonly serial?: string;
  /** 実機の機種名(表示専用)。 */
  readonly model?: string;
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

/** Sources/ftester/ApiDeviceCatalogCommand.swift の ApiAndroidCatalog.errorCode と対。
 * 文言ではなくこれで分岐する(webview は avdmanager-missing のときだけ導入ボタンを出す)。 */
export type AndroidCatalogErrorCode = "sdk-missing" | "avdmanager-missing" | "avdmanager-failed";

export interface AndroidCatalog {
  readonly available: boolean;
  readonly error: string | null;
  /** 旧 CLI は送ってこないため省略可(その場合ボタンは出さず理由文だけ出す)。 */
  readonly errorCode?: AndroidCatalogErrorCode | null;
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
    // 未知のコードは「知らない理由」として扱えるよう string を通す(分岐側が既知値だけ見る)
    (value.errorCode === undefined || value.errorCode === null || typeof value.errorCode === "string") &&
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
  /** config.ini の hw.device.name(例 "pixel_9")。旧 CLI は返さないため省略可。 */
  readonly model?: string | null;
  /** image.sysdir.1 から導出した OS 表記(例 "Android 15")。旧 CLI は返さないため省略可。 */
  readonly os?: string | null;
}

/** 接続中の Android 実機(installed-devices の android.physicalDevices)。 */
export interface InstalledAndroidPhysicalDevice {
  /** ro.product.model(取れなければ serial)。 */
  readonly model: string;
  /** ro.build.version.release(例 "13")。旧 CLI は返さないため省略可。 */
  readonly os?: string;
  /** マシンプロファイルの serial にそのまま書ける値。 */
  readonly serial: string;
}

export interface InstalledAndroidDevices {
  readonly available: boolean;
  readonly avds: readonly InstalledAndroidAvd[];
  /** 旧 CLI は返さないため省略可(欠落=実機なし扱い)。 */
  readonly physicalDevices?: readonly InstalledAndroidPhysicalDevice[];
  readonly error: string | null;
}

export interface InstalledIosDevice {
  readonly name: string;
  readonly os: string;
  readonly udid: string;
}

/** 接続中の iOS 実機(installed-devices の ios.physicalDevices)。 */
export interface InstalledIosPhysicalDevice {
  readonly name: string;
  readonly os: string;
  /** ハードウェア UDID。マシンプロファイルの udid にそのまま書ける値
   * (devicectl の Identifier 列とは別物。IOSPhysicalDeviceCatalog 参照)。 */
  readonly udid: string;
  /** "wired" / "localNetwork" 等。 */
  readonly transport: string;
  /** 機種名(marketingName。例 "iPhone 15 Pro")。旧 CLI は返さないため省略可。 */
  readonly model?: string;
}

export interface InstalledIosDevices {
  readonly available: boolean;
  readonly devices: readonly InstalledIosDevice[];
  /** 旧 CLI は返さないため省略可(欠落=実機なし扱い)。 */
  readonly physicalDevices?: readonly InstalledIosPhysicalDevice[];
  readonly error: string | null;
}

/** `ftester api installed-devices` の stdout 1行(単発 JSON)の形。 */
export interface InstalledDevices {
  readonly android: InstalledAndroidDevices;
  readonly ios: InstalledIosDevices;
}

function isInstalledAndroidAvd(value: unknown): value is InstalledAndroidAvd {
  return (
    isRecord(value) &&
    typeof value.displayName === "string" &&
    typeof value.id === "string" &&
    // model/os は後から追加。null(取得できず)も許容する
    (value.model === undefined || value.model === null || typeof value.model === "string") &&
    (value.os === undefined || value.os === null || typeof value.os === "string")
  );
}

function isInstalledIosDevice(value: unknown): value is InstalledIosDevice {
  return (
    isRecord(value) &&
    typeof value.name === "string" &&
    typeof value.os === "string" &&
    typeof value.udid === "string"
  );
}

function isInstalledAndroidPhysical(value: unknown): value is InstalledAndroidPhysicalDevice {
  return isRecord(value) && typeof value.model === "string" && typeof value.serial === "string";
}

function isInstalledAndroidDevices(value: unknown): value is InstalledAndroidDevices {
  return (
    isRecord(value) &&
    typeof value.available === "boolean" &&
    (value.error === null || typeof value.error === "string") &&
    Array.isArray(value.avds) &&
    value.avds.every(isInstalledAndroidAvd) &&
    // physicalDevices は後から追加。欠落は許容し、あれば形を検証する
    (value.physicalDevices === undefined ||
      (Array.isArray(value.physicalDevices) && value.physicalDevices.every(isInstalledAndroidPhysical)))
  );
}

function isInstalledIosPhysical(value: unknown): value is InstalledIosPhysicalDevice {
  return (
    isRecord(value) &&
    typeof value.name === "string" &&
    typeof value.os === "string" &&
    typeof value.udid === "string" &&
    typeof value.transport === "string"
  );
}

function isInstalledIosDevices(value: unknown): value is InstalledIosDevices {
  return (
    isRecord(value) &&
    typeof value.available === "boolean" &&
    (value.error === null || typeof value.error === "string") &&
    Array.isArray(value.devices) &&
    value.devices.every(isInstalledIosDevice) &&
    (value.physicalDevices === undefined ||
      (Array.isArray(value.physicalDevices) && value.physicalDevices.every(isInstalledIosPhysical)))
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
 * 無ければ udid 先頭8文字、それも無ければ "iOS"。Android: avd があれば "AVD: "+avd、
 * 実機(avd を持たない)は serial、どちらも無ければ "Android"。
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
  if (entry.avd) {
    return `AVD: ${entry.avd}`;
  }
  // 実機は AVD を持たない。serial が唯一の同定手段なのでそれを出す
  return entry.serial ?? "Android";
}

/** デバイス追加モーダルの新規デバイス名検証(webview 内の複製版が入力中の検証にも使う)。 */
export function validateNewDeviceName(name: string, existing: readonly string[]): string | null {
  const trimmed = name.trim();
  if (trimmed.length === 0) {
    return t("monitor.device.nameRequired");
  }
  if (existing.includes(trimmed)) {
    return t("monitor.validation.nameAlreadyExists", { name: trimmed });
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
    return t("monitor.machineProfile.nameNoSpaces");
  }
  if (name.length === 0) {
    return t("monitor.machineProfile.nameRequired");
  }
  if (name.includes("/") || name.includes("\\")) {
    return t("monitor.machineProfile.nameNoSlash");
  }
  if (name.startsWith(".")) {
    return t("monitor.machineProfile.nameNoDotStart");
  }
  const lowerName = name.toLowerCase();
  if (existing.some((item) => item.toLowerCase() === lowerName)) {
    return t("monitor.machineProfile.nameExists", { name });
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
  /** Android 実機の adb シリアル(kind=physical のみ意味を持つ)。 */
  readonly serial: string;
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
    return { ok: false, error: t("monitor.machineProfile.invalidFormat") };
  }
  const source = profileObject as Record<string, unknown>;
  const notFoundError = {
    ok: false as const,
    error: t("monitor.device.notFound", { name: originalName }),
  };

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
    return { ok: false, error: t("monitor.device.nameRequired") };
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
        return { ok: false, error: t("monitor.validation.nameAlreadyExists", { name: newName }) };
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
        return { ok: false, error: t("monitor.device.portInvalid") };
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
    // 実機は udid が唯一の同定手段(simulator/os は使わない)。空のまま保存すると
    // run で「kind=physical ですが udid がありません」と落ちるので手前で止める
    if (newEntry.kind === "physical" && typeof newEntry.udid !== "string") {
      return { ok: false, error: t("monitor.device.physicalUdidRequired") };
    }
  } else {
    for (const key of ["avd", "serial"] as const) {
      // serial は後から追加したフィールド。拡張と webview のバンドルは別々に更新されうるので
      // 欠落しても落ちないようにする(欠落=未入力として扱う)
      const value = (fields[key] ?? "").trim();
      if (value.length === 0) {
        delete newEntry[key];
      } else {
        newEntry[key] = value;
      }
    }
    if (newEntry.kind === "physical" && typeof newEntry.serial !== "string") {
      return { ok: false, error: t("monitor.device.physicalSerialRequired") };
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
    return { ok: false, error: t("monitor.machineProfile.invalidFormat") };
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
    // kind は physical のときだけ書く(未指定=virtual が既定。既存プロファイルにノイズを足さない)
    if (entry.kind === "physical") {
      deviceEntry.kind = "physical";
    }
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
    if (entry.serial) {
      deviceEntry.serial = entry.serial;
    }
    if (entry.model) {
      deviceEntry.model = entry.model;
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
    return { ok: false, error: t("monitor.machineProfile.invalidFormat") };
  }
  let current: unknown = profileObject;
  let removedCount = 0;
  for (const name of remove) {
    const result = removeDeviceFromMachineProfile(current, name);
    if (!result) {
      // removeDeviceFromMachineProfile は object 入力に対し常に非null を返すため実際には到達しないが、
      // 型上 null を返しうるための防御(削除しない)。
      return { ok: false, error: t("monitor.machineProfile.invalidFormat") };
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
