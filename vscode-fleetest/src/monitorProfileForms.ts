// monitorProfileForms.ts
// プロファイルタブ(実行プロファイル・アプリプロファイル)の名前検証、
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
 * devices は空配列(デバイスはプロファイルタブの「デバイスを追加」/チェックボックスで足す)。
 */
export function buildRunProfileTemplate(appNames: readonly string[]): string {
  const app = appNames[0] ?? "";
  const template: Record<string, unknown> = {};
  template.app = app;
  template.devices = [];
  template.heal = true;
  template.textVisualCheck = true;
  template.ocrTextVisualCheck = true;
  template.preferCheckStateClassifier = true;
  template.screenLooksLike = true;
  template.iosInappEngine = true;
  template.updateWebView = true;   // 既定 ON(WebView の版差でシナリオが端末ごとに落ちるため)
  template.wipeDataOnBloat = true;
  // reportDir は書かない(未指定 = 既定の reports。フォームは placeholder で既定を見せる)
  return `${JSON.stringify(template, null, 2)}\n`;
}

// ---- アプリプロファイル自体の追加/コピー/名前変更(名前検証) -------------------------------
// monitorPanel.ts の handleAppProfileAdd/Copy/Rename が使う純粋ロジック(ファイル I/O は呼び出し側)。

/**
 * アプリプロファイル名(apps/<name>.json の <name>)の妥当性検証。validateNewRunProfileName と
 * 同一ロジック(前後空白・空文字・"/" "\" ・"." 始まり・重複、大文字小文字を区別)。
 * 大文字小文字を無視する重複判定は行わない(プロジェクト名・デバイス名の規則とは別)。
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

// ---- プロジェクト自体の追加/コピー/名前変更(名前検証) ---------------------------------
// monitorProfilesController.ts の handleProjectAdd/Copy/Rename が使う純粋ロジック。

/** SPM のターゲット名として有効な文字集合。Sources/FTCore/TestProject.swift の
 * ProjectStore.isValidName と文字列として同期する(test/projectNameRuleSync.test.mjs が検証)。 */
const PROJECT_NAME_PATTERN = /^[A-Za-z0-9_][A-Za-z0-9_-]*$/;

/**
 * テストプロジェクト名(TestProjects/<name>/ の <name>)の妥当性検証。プロジェクト名は
 * SPM のターゲット名になるため、他のプロファイル名(validateNewAppProfileName 等)と違い
 * 日本語・空白・"/" ".": 始まりだけでなく使える文字自体を英数字・"_"・"-" に限定する
 * (先頭は英数字・"_" のみ、"-" 始まりは不可)。
 */
export function validateNewProjectName(name: string, existing: readonly string[]): string | null {
  if (name !== name.trim()) {
    return t("monitor.project.nameNoSpaces");
  }
  if (name.length === 0) {
    return t("monitor.project.nameRequired");
  }
  if (!PROJECT_NAME_PATTERN.test(name)) {
    return t("monitor.project.nameInvalid");
  }
  if (existing.includes(name)) {
    return t("monitor.project.nameExists", { name });
  }
  return null;
}

// ---- プロファイルタブ下半分: 実行プロファイルの設定フォーム -----------------------------
// handleRunProfileLoad/Save(monitorPanel.ts)が使う、JSON⇔フォームの各フィールド変換の純粋関数
// (未知キー保持のイミュータブルな方針。addDevicesToRunProfile と同じ)。

/** 実行プロファイル設定フォームのフィールド(全て文字列/配列/真偽値化済み。空文字は未設定)。
 * recordFailuresOnly/recordBitrateKbps/recordFullResolution は「録画セクション」、
 * iosFastInput / iosPreActionWarmup は「iOS」セクションのサブオプション
 * (親チェックボックスの状態に関わらず独立して保持・保存する。表示上の非表示切替は
 * runProfilesTab.js の責務)。textVisualCheck/screenLooksLike/ocrTextVisualCheck は
 * 「Advanced Features」セクションの独立トグル(親チェックボックスは無い。ocrTextVisualCheck は
 * occlusion guard の Vision OCR 事前判定段で、textVisualCheck が false の run では guard 自体が
 * 走らないため効かない)。containerInference は misc セクションの独立トグル。heal はロケータの指紋照合による自己修復の
 * トグルで、「Advanced Features」セクションの先頭に並ぶ独立トグル(FM を使わない)。 */
/** 実行プロファイルの devices[] 1件(プロジェクトのデバイスカタログと同じ形 +
 * `enabled`)。**一意なのは (platform, machine, name)**(machine 省略=手元。
 * Sources/FTCore/RunProfile.swift の DeviceSpec と同形)。enabled=false は「一覧には載るが
 * 実行しない」(RunDeviceRef.enabled)。**JSON キーは "machine"**(常に明示で書く)。 */
export interface RunProfileDeviceEntry {
  readonly platform: MonitorPlatform;
  readonly machine?: string;
  readonly name: string;
  /** 省略/true = 実行する。false = 一覧には残すが実行しない。 */
  readonly enabled: boolean;
  readonly kind?: "virtual" | "physical";
  /** Xcode / 端末が示す OS Version(プラットフォーム接頭辞つき。例 "iOS 27.0" / "Android 13")。 */
  readonly osVersion?: string;
  readonly udid?: string;
  readonly port?: number;
  readonly avd?: string;
  readonly serial?: string;
  readonly model?: string;
}

export interface RunProfileFormFields {
  readonly app: string;
  readonly devices: readonly RunProfileDeviceEntry[];
  readonly heal: boolean;
  readonly textVisualCheck: boolean;
  readonly screenLooksLike: boolean;
  readonly containerInference: boolean;
  /** occlusion guard の Vision OCR 事前判定段(独立トグル。textVisualCheck が false の run では
   * guard 自体が走らないため効かない)。 */
  readonly ocrTextVisualCheck: boolean;
  /** checkIsON/checkIsOFF で CheckStateClassifier(vision/classifiers/CheckStateClassifier/ の見本画像)を
   * a11y より優先するか(**既定 true**。false なら a11y が状態を報告しない要素にだけ使う)。
   * Swift 側は RunProfileDocument.preferCheckStateClassifier */
  readonly preferCheckStateClassifier: boolean;
  readonly iosInappEngine: boolean;
  readonly iosFastInput: boolean;
  /// **既定 true**。domInterop の委譲イベント直前にランナーへ1回問い合わせてから撃つ
  /// (attach セッションの静かなイベント欠落の防御。Swift 側は iosPreActionWarmup → FT_PRE_ACTION_WARMUP)
  readonly iosPreActionWarmup: boolean;
  /// **既定 true**。一斉 launch 直後の黒画面(描画要求が無いだけ)を避ける予防措置
  readonly homeOnStart: boolean;
  /// **既定 true**。Android install 中だけ Play Protect の照会をバイパスするキルスイッチ
  readonly playProtectBypass: boolean;
  readonly enableAnimations: boolean;
  readonly reportDir: string;
  readonly updateWebView: boolean;
  readonly wipeDataOnBloat: boolean;
  readonly wipeDataThresholdGB: string;
  readonly recoverCpuFallbackToGpu: boolean;
  readonly locale: string;
  readonly record: boolean;
  readonly recordFailuresOnly: boolean;
  readonly recordBitrateKbps: string;
  readonly recordFullResolution: boolean;
  /** remoteControl.workspace(ネストしたセクション。Sources/FTCore/RunProfile.swift の同名キーと同期)。
   * アプリのバイナリ/資材を置くフォルダ。リモートの Mac にはこのフォルダが運ばれる。 */
  readonly workspace: string;
}

/**
 * runs/<name>.json のトップレベルから、フォームのフィールドを許容的に読み取る(トップレベルが
 * 非オブジェクトなら null)。各キーは欠落・型不正を「読めなければ空/既定値」で許容し、スキーマ
 * 妥当性検証はしない(保存時 updateRunProfileInObject・CLI 側 ProfileResolver.validate に委ねる)。
 * wipeDataThresholdGB/recordBitrateKbps は number ならそのまま String() 化する
 * (0.5 のようなスキーマ違反値もそのまま表示し、整数化はしない)。defaultTimeout は GUI のフォーム欄では
 * 扱わない(CLI `--set defaultTimeout=` と手編集のためにキーとしては有効なまま。
 * updateRunProfileInObject の `{ ...source }` がそのまま保つ)。record/recordFailuresOnly/
 * recordFullResolution/iosFastInput/enableAnimations は既定 false、recordBitrateKbps は既定 ""(未設定=CLI側既定1500)。
 * heal/screenLooksLike/textVisualCheck/ocrTextVisualCheck/preferCheckStateClassifier/containerInference/
 * homeOnStart/playProtectBypass はスキーマ既定と合わせ既定 true
 * (textVisualCheck は 2026-09-03 に false から変更)。
 */
export function parseRunProfileForForm(profileObject: unknown): RunProfileFormFields | null {
  // 配列も typeof "object" だが、トップレベルとしては不正なので弾く(他の同様関数と同じ判定)。
  if (typeof profileObject !== "object" || profileObject === null || Array.isArray(profileObject)) {
    return null;
  }
  const source = profileObject as Record<string, unknown>;
  const app = typeof source.app === "string" ? source.app : "";
  const reportDir = typeof source.reportDir === "string" ? source.reportDir : "";
  const locale = typeof source.locale === "string" ? source.locale : "";
  const heal = typeof source.heal === "boolean" ? source.heal : true;
  const textVisualCheck = typeof source.textVisualCheck === "boolean" ? source.textVisualCheck : true;
  const ocrTextVisualCheck =
    typeof source.ocrTextVisualCheck === "boolean" ? source.ocrTextVisualCheck : true;
  const preferCheckStateClassifier =
    typeof source.preferCheckStateClassifier === "boolean" ? source.preferCheckStateClassifier : true;
  const screenLooksLike = typeof source.screenLooksLike === "boolean" ? source.screenLooksLike : true;
  const containerInference = typeof source.containerInference === "boolean" ? source.containerInference : true;
  const iosInappEngine = typeof source.iosInappEngine === "boolean" ? source.iosInappEngine : true;
  const iosFastInput = typeof source.iosFastInput === "boolean" ? source.iosFastInput : false;
  const iosPreActionWarmup = typeof source.iosPreActionWarmup === "boolean" ? source.iosPreActionWarmup : true;
  const homeOnStart = typeof source.homeOnStart === "boolean" ? source.homeOnStart : true;
  const playProtectBypass = typeof source.playProtectBypass === "boolean" ? source.playProtectBypass : true;
  const enableAnimations = typeof source.enableAnimations === "boolean" ? source.enableAnimations : false;
  const updateWebView = typeof source.updateWebView === "boolean" ? source.updateWebView : true;
  const wipeDataOnBloat = typeof source.wipeDataOnBloat === "boolean" ? source.wipeDataOnBloat : true;
  const recoverCpuFallbackToGpu =
    typeof source.recoverCpuFallbackToGpu === "boolean" ? source.recoverCpuFallbackToGpu : false;
  const record = typeof source.record === "boolean" ? source.record : false;
  const recordFailuresOnly = typeof source.recordFailuresOnly === "boolean" ? source.recordFailuresOnly : false;
  const recordFullResolution = typeof source.recordFullResolution === "boolean" ? source.recordFullResolution : false;
  const devices: RunProfileDeviceEntry[] = Array.isArray(source.devices)
    ? source.devices
        .map((device) => {
          if (!isRecord(device) || typeof device.name !== "string") {
            return undefined;
          }
          if (device.platform !== "ios" && device.platform !== "android") {
            return undefined;
          }
          // 内部表現は「手元 = undefined」。ファイル側の "local"(明示)と "" と省略は同じ意味。
          const raw = typeof device.machine === "string" ? device.machine.trim() : "";
          const machine = raw === "" || raw === "local" ? undefined : raw;
          const enabled = device.enabled !== false;
          const entry: RunProfileDeviceEntry = {
            platform: device.platform,
            name: device.name,
            enabled,
            ...(machine !== undefined ? { machine } : {}),
            ...(typeof device.kind === "string" && (device.kind === "virtual" || device.kind === "physical")
              ? { kind: device.kind } : {}),
            ...(typeof device.osVersion === "string" ? { osVersion: device.osVersion } : {}),
            ...(typeof device.udid === "string" ? { udid: device.udid } : {}),
            ...(typeof device.port === "number" ? { port: device.port } : {}),
            ...(typeof device.avd === "string" ? { avd: device.avd } : {}),
            ...(typeof device.serial === "string" ? { serial: device.serial } : {}),
            ...(typeof device.model === "string" ? { model: device.model } : {}),
          };
          return entry;
        })
        .filter((ref): ref is RunProfileDeviceEntry => ref !== undefined)
    : [];
  const rawThreshold = source.wipeDataThresholdGB;
  const wipeDataThresholdGB =
    typeof rawThreshold === "number" ? String(rawThreshold) : typeof rawThreshold === "string" ? rawThreshold : "";
  const rawBitrate = source.recordBitrateKbps;
  const recordBitrateKbps =
    typeof rawBitrate === "number" ? String(rawBitrate) : typeof rawBitrate === "string" ? rawBitrate : "";
  // remoteControl はネストしたオブジェクト(他フィールドと違いトップレベル直下ではない)。
  // 非オブジェクト・欠落は空セクション扱いにして workspace を既定 "" に落とす。
  const remoteControl = isRecord(source.remoteControl) ? source.remoteControl : {};
  const workspace = typeof remoteControl.workspace === "string" ? remoteControl.workspace : "";
  return {
    app,
    devices,
    heal,
    textVisualCheck,
    screenLooksLike,
    containerInference,
    ocrTextVisualCheck,
    preferCheckStateClassifier,
    iosInappEngine,
    iosFastInput,
    iosPreActionWarmup,
    homeOnStart,
    playProtectBypass,
    enableAnimations,
    reportDir,
    updateWebView,
    wipeDataOnBloat,
    wipeDataThresholdGB,
    recoverCpuFallbackToGpu,
    locale,
    record,
    recordFailuresOnly,
    recordBitrateKbps,
    recordFullResolution,
    workspace,
  };
}

export type RunProfileUpdateResult =
  | { readonly ok: true; readonly object: Record<string, unknown> }
  | { readonly ok: false; readonly error: string };

/**
 * runs/<name>.json を、フォームのフィールドの内容で更新した新オブジェクトを組み立てる
 * (未知キー保持のイミュータブルな方針。profileObject が非オブジェクトなら ok:false)。
 * defaultTimeout はフォーム欄を持たない。result は `{ ...source }` から始まるため、
 * 既存 JSON の defaultTimeout はそのまま(未検証で)保たれる。
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

  for (const key of ["app", "reportDir"] as const) {
    const value = fields[key].trim();
    if (value.length === 0) {
      delete result[key];
    } else {
      result[key] = value;
    }
  }

  result.heal = fields.heal;
  result.textVisualCheck = fields.textVisualCheck;
  result.screenLooksLike = fields.screenLooksLike;
  result.containerInference = fields.containerInference;
  result.ocrTextVisualCheck = fields.ocrTextVisualCheck;  // 同上(既定 true 側。containerInference と同じ理由で常に書く)
  result.preferCheckStateClassifier = fields.preferCheckStateClassifier;  // 同上(既定 true 側)
  result.iosInappEngine = fields.iosInappEngine;
  result.updateWebView = fields.updateWebView;
  result.wipeDataOnBloat = fields.wipeDataOnBloat;
  // 既定 true 側なので containerInference と同じく常に書く(false を落とすと既定へ戻ってしまう)
  result.homeOnStart = fields.homeOnStart;
  result.iosPreActionWarmup = fields.iosPreActionWarmup;  // 同上(既定 true 側)
  result.playProtectBypass = fields.playProtectBypass;  // 同上(既定 true 側)
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

  // remoteControl は3欄とも空ならセクションごと削除する(既存プロファイルに空セクションを
  // 増やさない)。既存セクションの他キー(将来の追加分)は保ったまま、空欄のキーだけ落とす。
  // remoteControl.workspace は空文字ならセクションごと削除する(既存プロファイルに空セクションを
  // 増やさない)。既存セクションの他キー(将来の追加分)は保ったまま workspace だけ差し替える。
  const workspaceTrimmed = fields.workspace.trim();
  if (workspaceTrimmed.length === 0) {
    delete result.remoteControl;
  } else {
    const existingRemoteControl = isRecord(source.remoteControl) ? source.remoteControl : {};
    result.remoteControl = { ...existingRemoteControl, workspace: workspaceTrimmed };
  }

  const localeTrimmed = fields.locale.trim();
  if (localeTrimmed.length === 0) {
    delete result.locale;
  } else if (!/^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$/.test(localeTrimmed)) {
    return { ok: false, error: t("monitor.runProfile.localeInvalid") };
  } else {
    result.locale = localeTrimmed;
  }

  // 既存エントリの未知キーは保つ。**引き当ては (platform, machine, name)** —— 名前だけだと、
  // 同名が別の機械/別 OS に並ぶ台で別のエントリの未知キーを持ってきてしまう。
  // チェックボックスの操作は enabled の有無・machine の正規化だけに触れ、それ以外の欄
  // (名前・機種/OS/UDID/AVD 等)は素通しする(runProfileDeviceRefKey/orderedDeviceEntry を
  // addDeviceRefsToRunProfile と共有)。
  const existingDevices = Array.isArray(source.devices) ? source.devices : [];
  const existingByRef = new Map<string, Record<string, unknown>>();
  for (const device of existingDevices) {
    if (!isRecord(device) || typeof device.name !== "string") {
      continue;
    }
    if (device.platform !== "ios" && device.platform !== "android") {
      continue;
    }
    const rawMachine = typeof device.machine === "string" ? device.machine.trim() : "";
    const key = runProfileDeviceRefKey({
      platform: device.platform,
      name: device.name,
      machine: rawMachine === "" || rawMachine === "local" ? undefined : rawMachine,
    });
    if (!existingByRef.has(key)) {
      existingByRef.set(key, device);
    }
  }
  result.devices = fields.devices.map((entry) => {
    const existing = existingByRef.get(runProfileDeviceRefKey(entry));
    if (!existing) {
      return orderedDeviceEntry(entry);
    }
    const merged: Record<string, unknown> = { ...existing };
    // **machine は省略しない**(手元なら "local")。省略した参照は、同名が複数の機械に居ると
    // 実行時に「どちらか決められない」で止まる(FTCore の ambiguousDeviceRef)
    merged.machine = entry.machine ?? "local";
    if (entry.enabled) {
      delete merged.enabled;
    } else {
      merged.enabled = false;
    }
    return merged;
  });

  return { ok: true, object: result };
}

/** devices[] エントリの同一性の鍵(**(platform, machine, name)**。machine 省略=手元)。
 * updateRunProfileInObject / addDeviceRefsToRunProfile が共有する。 */
export function runProfileDeviceRefKey(ref: {
  readonly platform: string;
  readonly machine?: string;
  readonly name: string;
}): string {
  return `${ref.platform}\t${ref.machine ?? ""}\t${ref.name}`;
}

/** runs/<name>.json の devices[] へ書く1件分を、鍵の順(platform, machine, name, enabled、
 * 残りはアルファベット順。Sources/FTCore/OrderedProfileJSON.swift と同期)で組み立てる。
 * カタログから新規に持ち込む(=このプロファイルにまだ無い)エントリの生成に使う。 */
export function orderedDeviceEntry(entry: {
  readonly platform: MonitorPlatform;
  readonly machine?: string;
  readonly name: string;
  readonly enabled: boolean;
  readonly kind?: "virtual" | "physical";
  readonly osVersion?: string;
  readonly udid?: string;
  readonly port?: number;
  readonly avd?: string;
  readonly serial?: string;
  readonly model?: string;
}): Record<string, unknown> {
  const result: Record<string, unknown> = {
    platform: entry.platform,
    machine: entry.machine ?? "local",
    name: entry.name,
  };
  if (!entry.enabled) {
    result.enabled = false;
  }
  const rest: readonly (readonly [string, unknown])[] = [
    ["avd", entry.avd],
    ["kind", entry.kind],
    ["model", entry.model],
    ["osVersion", entry.osVersion],
    ["port", entry.port],
    ["serial", entry.serial],
    ["udid", entry.udid],
  ];
  for (const [key, value] of rest) {
    if (value !== undefined) {
      result[key] = value;
    }
  }
  return result;
}

// ---- プロファイルタブ中段: アプリプロファイルの設定フォーム -------------------------------
// handleAppProfileLoad/Save(monitorPanel.ts)が使う、JSON⇔フォーム common/ios/android 3グループ
// 変換の純粋関数(parseRunProfileForForm/updateRunProfileInObject と同じ方針)。
// autoInstall は common に一本化済み(ios/android に残存していると Swift 側 validate が警告する)。

/** アプリプロファイル common セクション。app/appPath/appName は廃止済み(ランタイムは common の
 * これらを無視する。表示名は ios/android のそれぞれに書き、common からは継承しない)ため
 * ios/android(AppProfilePlatformFields)と型を分離。 */
export interface AppProfileCommonFields {
  readonly autoInstall: "true" | "false";
}

/** アプリプロファイル ios/android セクションの3フィールド。autoInstall は common に一本化済みの
 * ためここには持たない。 */
export interface AppProfilePlatformFields {
  readonly appName: string;
  readonly app: string;
  readonly appPath: string;
}

/** iOS セクション。実機に配るパッケージ(appPathPhysical。RunProfile.swift
 * AppProfileSection.appPathPhysical と同期)を持つ点だけが android と違う —— iOS は
 * シミュレータ用ビルド(未署名)を実機へ入れられず、同じアプリでも成果物が2つ要る。
 * Android は同じ APK が両方で動くため欄を置かない(手書きで android.appPathPhysical が
 * 書かれていても未知キーとして保たれる。updateAppProfilePlatformSection 参照)。 */
export interface AppProfileIOSFields extends AppProfilePlatformFields {
  readonly appPathPhysical: string;
}

/** アプリプロファイル設定フォームの common/ios/android 3グループ分のフィールド。 */
export interface AppProfileFormFields {
  readonly common: AppProfileCommonFields;
  readonly ios: AppProfileIOSFields;
  readonly android: AppProfilePlatformFields;
}

const EMPTY_APP_PROFILE_COMMON_FIELDS: AppProfileCommonFields = {
  autoInstall: "false",
};

const EMPTY_APP_PROFILE_PLATFORM_FIELDS: AppProfilePlatformFields = {
  appName: "",
  app: "",
  appPath: "",
};

const EMPTY_APP_PROFILE_IOS_FIELDS: AppProfileIOSFields = {
  ...EMPTY_APP_PROFILE_PLATFORM_FIELDS,
  appPathPhysical: "",
};

/** apps/<name>.json の common セクションを許容的に読み取る(非オブジェクトなら空セクション扱い)。
 * app/appPath/appName は common では廃止のため読み取らない(残っていても無視。表示名は
 * ios/android のそれぞれで読む)。 */
function parseAppProfileCommonSection(value: unknown): AppProfileCommonFields {
  if (!isRecord(value)) {
    return EMPTY_APP_PROFILE_COMMON_FIELDS;
  }
  const autoInstall = value.autoInstall === true ? "true" : "false";
  return { autoInstall };
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

/** apps/<name>.json の ios セクションを読み取る(android との差は appPathPhysical の1欄だけ)。 */
function parseAppProfileIOSSection(value: unknown): AppProfileIOSFields {
  if (!isRecord(value)) {
    return EMPTY_APP_PROFILE_IOS_FIELDS;
  }
  const appPathPhysical = typeof value.appPathPhysical === "string" ? value.appPathPhysical : "";
  return { ...parseAppProfilePlatformSection(value), appPathPhysical };
}

/** apps/<name>.json のトップレベルから common/ios/android 3グループを読み取る(非オブジェクトなら null)。 */
export function parseAppProfileForForm(profileObject: unknown): AppProfileFormFields | null {
  if (typeof profileObject !== "object" || profileObject === null || Array.isArray(profileObject)) {
    return null;
  }
  const source = profileObject as Record<string, unknown>;
  return {
    common: parseAppProfileCommonSection(source.common),
    ios: parseAppProfileIOSSection(source.ios),
    android: parseAppProfilePlatformSection(source.android),
  };
}

export type AppProfileUpdateResult =
  | { readonly ok: true; readonly object: Record<string, unknown> }
  | { readonly ok: false; readonly error: string };

/**
 * common セクションを fields で更新した新オブジェクトを組み立てる(未知キー保持)。
 * autoInstall は "false" ならキー削除(既定と同値のため書かない)。app/appPath/appName は
 * 廃止済みのため値に関わらず常に削除する(appName の残存は Swift 側で未知キー警告になる。
 * 表示名は ios/android のそれぞれに書き、common からは継承しない)。
 * existing が undefined かつ autoInstall=false(値が何も無い)なら undefined を返しセクション
 * 自体を作らない。existing が定義済み(空オブジェクト含む)ならセクションは保持する
 * (healthCheckURL 等の他キーはここで触れず existing のスプレッドで保たれる)。
 */
function updateAppProfileCommonSection(
  existing: Record<string, unknown> | undefined,
  fields: AppProfileCommonFields,
): Record<string, unknown> | undefined {
  const hasAnyValue = fields.autoInstall === "true";
  if (existing === undefined && !hasAnyValue) {
    return undefined;
  }
  const result: Record<string, unknown> = { ...(existing ?? {}) };
  if (fields.autoInstall === "true") {
    result.autoInstall = true;
  } else {
    delete result.autoInstall;
  }
  delete result.appName;
  delete result.app;
  delete result.appPath;
  return result;
}

/**
 * ios/android セクションを fields で更新した新オブジェクトを組み立てる(updateAppProfileCommonSection
 * と同じ方針)。autoInstall は common に一本化済みのため値に関わらず常に削除する(廃止分の掃除)。
 * **触るのは欄のあるキーだけ** —— appPathPhysical の欄は iOS にしか無いので、android の fields
 * には持たせず、ここでも消しに行かない(消しに行くと手書きの android.appPathPhysical が保存の
 * たびに落ちる)。新規セクション作成の要否(hasAnyValue)も欄のあるキーだけで判定する。
 */
function updateAppProfilePlatformSection(
  existing: Record<string, unknown> | undefined,
  fields: AppProfilePlatformFields | AppProfileIOSFields,
): Record<string, unknown> | undefined {
  const values: Record<string, string> = {
    appName: fields.appName,
    app: fields.app,
    appPath: fields.appPath,
    ...("appPathPhysical" in fields ? { appPathPhysical: fields.appPathPhysical } : {}),
  };
  const entries = Object.entries(values).map(([key, value]) => [key, value.trim()] as const);
  const hasAnyValue = entries.some(([, value]) => value !== "");
  if (existing === undefined && !hasAnyValue) {
    return undefined;
  }
  const result: Record<string, unknown> = { ...(existing ?? {}) };
  for (const [key, value] of entries) {
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

// ---- プロファイルタブ: プロジェクトのデバイスカタログ・デバイス追加 ------------------
// 契約:
//   `fleetest api device-catalog`(引数なし): stdout に単発 JSON 1行(DeviceCatalog の形。各配列は
//   表示順=先頭がドロップダウンの既定値)。「デバイスを追加」内の新規作成が使う。
//   `fleetest api create-device --project <P> --platform ios|android --name <名>
//   --model <id> --os <id> [--profile <実行プロファイル名>] [--no-register]`: stdout に NDJSON
//   ({"kind":"log",...} × n → {"kind":"finished","ok":bool,"error":string|null,"device":{...}|null})。
//   --no-register は物理作成のみ行い実行プロファイルへの追記をスキップする(#device-pick-overlay の
//   「+」から開いた新規作成モーダルは常にこちら。登録は #device-pick-overlay の OK が行う)。
//   `fleetest api installed-devices`(引数なし): stdout に単発 JSON 1行(InstalledDevices の形。
//   インストール済み実機一覧)。「+既存から選択」が追加候補として使う。device-catalog(新規作成用
//   カタログ)とは別物 — こちらは「既に作成済みの実体」の一覧。

/** プロジェクトのデバイスカタログ(全実行プロファイルの devices[] の和集合)1件分。config.ts の
 * MachineDeviceEntry と構造的に同一だが、vscode 非依存を保つため独立定義する(型のためだけに
 * config.ts を import させない方針)。 */
export interface MachineDeviceEntry {
  readonly name: string;
  readonly platform: MonitorPlatform;
  /** このデバイスが居る機械(登録名 = マシンのエイリアス。省略=手元)。一意なのは
   * (platform, machine, name) で、別マシンの同名は重複ではない
   * (Sources/FTCore/DeviceMachineGrouping.swift)。 */
  readonly machine?: string;
  /** 実体種別。省略=virtual(シミュレータ/エミュレータ)。physical は実機で、
   * 識別子は iOS=udid / Android=serial(Sources/FTCore/RunProfile.swift の DeviceKind と同期)。 */
  readonly kind?: "virtual" | "physical";
  /** Xcode / 端末が示す OS Version(プラットフォーム接頭辞つき。例 "iOS 27.0" / "Android 13")。 */
  readonly osVersion?: string;
  readonly udid?: string;
  readonly port?: number;
  readonly avd?: string;
  /** Android 実機の adb シリアル(kind=physical のとき必須)。 */
  readonly serial?: string;
  /** デバイスの機種名(表示専用。同定には使わない)。iOS シミュレータは Xcode の Model、
   * iOS 実機は marketingName、Android は ro.product.model。 */
  readonly model?: string;
}

/**
 * runProfileDevicesSync(webview→host)メッセージの add[] 1件分。「+既存から選択」モーダルで
 * 新たにチェックした(カタログに未登録だった)iOS シミュレータ/Android AVD 1件を表す
 * (MachineDeviceEntry と違い、port は持たない — port は画面から設定できず、
 * JSON を直接編集したときだけ乗る値)。
 * - iOS: { platform:"ios", name:<シミュレータ名>, osVersion:<osVersion>, udid:<udid>, model?:<機種> }
 * - Android: { platform:"android", name:<displayName>, avd:<id> }
 * 実機は kind:"physical" 付きで、実体を指すのは iOS=udid / Android=serial のみ(avd は持たない)。
 * osVersion は installed-devices の素の os(接頭辞なし)にプラットフォーム接頭辞を足した値
 * (webview の prefixedOsVersion。「+既存から選択」の OK 時にだけ組み立てる)。
 */
export interface RunProfileDeviceAddEntry {
  readonly platform: MonitorPlatform;
  readonly name: string;
  /** 追加先の機械(devicePickHost の選択。省略=手元)。JSON にも "machine" で書く。 */
  readonly machine?: string;
  readonly kind?: "virtual" | "physical";
  readonly osVersion?: string;
  readonly udid?: string;
  readonly avd?: string;
  readonly serial?: string;
  /** デバイスの機種名(表示専用)。 */
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

/** インストール済みでない(ダウンロードが要る)Android システムイメージ1件。license/sizeBytes は
 * CLI 側が読めなければ null(表示側は「不明」として扱い、断定しない)。 */
export interface AndroidCatalogDownloadableSystemImage {
  readonly abi: string;
  readonly apiLevel: number;
  readonly license: string | null;
  readonly package: string;
  readonly sizeBytes: number | null;
  readonly tag: string;
  readonly versionName: string;
}

/** Sources/fleetest/ApiDeviceCatalogCommand.swift の ApiAndroidCatalog.errorCode と対。
 * 文言ではなくこれで分岐する(webview は avdmanager-missing のときだけ導入ボタンを出す)。 */
export type AndroidCatalogErrorCode = "sdk-missing" | "avdmanager-missing" | "avdmanager-failed";

export interface AndroidCatalog {
  readonly available: boolean;
  readonly error: string | null;
  /** 旧 CLI は送ってこないため省略可(その場合ボタンは出さず理由文だけ出す)。 */
  readonly errorCode?: AndroidCatalogErrorCode | null;
  readonly models: readonly AndroidCatalogModel[];
  readonly systemImages: readonly AndroidCatalogSystemImage[];
  /** ダウンロードして導入できるシステムイメージ(既にインストール済みのものは含まない)。
   * 旧 CLI は送ってこないため省略可(その場合「デバイスを追加」は従来どおり systemImages だけを見せる)。 */
  readonly downloadableSystemImages?: readonly AndroidCatalogDownloadableSystemImage[];
  /** ダウンロード候補の取得自体が失敗した理由(英語。枠だけ i18n)。旧 CLI は送ってこないため省略可。 */
  readonly downloadableError?: string | null;
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

/** `fleetest api device-catalog` の stdout 1行(単発 JSON)の形。 */
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

function isAndroidCatalogDownloadableSystemImage(value: unknown): value is AndroidCatalogDownloadableSystemImage {
  return (
    isRecord(value) &&
    typeof value.abi === "string" &&
    typeof value.apiLevel === "number" &&
    (value.license === null || typeof value.license === "string") &&
    typeof value.package === "string" &&
    (value.sizeBytes === null || typeof value.sizeBytes === "number") &&
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
    value.systemImages.every(isAndroidCatalogSystemImage) &&
    // 旧 CLI は送ってこないため欠落を許容する(欠落時は webview が従来どおり動く)
    (value.downloadableSystemImages === undefined ||
      (Array.isArray(value.downloadableSystemImages) &&
        value.downloadableSystemImages.every(isAndroidCatalogDownloadableSystemImage))) &&
    (value.downloadableError === undefined || value.downloadableError === null ||
      typeof value.downloadableError === "string")
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
// `fleetest api installed-devices` の stdout 1行(単発 JSON)。DeviceCatalog とは別契約(既に
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
  /** プロジェクトのデバイスカタログの serial にそのまま書ける値。 */
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
  /** Xcode の Model(デバイスタイプ名。例 "iPhone 17 Pro")。旧 CLI は返さないため省略可、
   * 取得できなければ null。 */
  readonly model?: string | null;
}

/** 接続中の iOS 実機(installed-devices の ios.physicalDevices)。 */
export interface InstalledIosPhysicalDevice {
  readonly name: string;
  readonly os: string;
  /** ハードウェア UDID。プロジェクトのデバイスカタログの udid にそのまま書ける値
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

/** `fleetest api installed-devices` の stdout 1行(単発 JSON)の形。 */
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
    typeof value.udid === "string" &&
    // 旧 CLI は返さないため省略可。取得できなければ null(取得できずと空文字を混同しない)
    (value.model === undefined || value.model === null || typeof value.model === "string")
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

/** `fleetest api create-device` の NDJSON 1行分のイベント(kind で判別。isDeviceOpEvent と対になる形)。 */
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

export interface InstallSystemImageLogEvent {
  readonly kind: "log";
  readonly message: string;
}

export interface InstallSystemImageFinishedEvent {
  readonly kind: "finished";
  readonly ok: boolean;
  readonly error: string | null;
}

/** `fleetest api install-system-image` の NDJSON 1行分のイベント(create-device と違い作成物を
 * 持たないので device フィールドが無い。isCreateDeviceEvent と同じ判定方針)。 */
export type InstallSystemImageEvent = InstallSystemImageLogEvent | InstallSystemImageFinishedEvent;

export function isInstallSystemImageEvent(value: unknown): value is InstallSystemImageEvent {
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
 * `fleetest api install-system-image` の CLI 引数を組み立てる純粋関数(deviceCommandArgs と組み合わせて
 * 使う。deleteDeviceApiArgs と同じくテスト分離のために公開する)。**`--accept-licenses` は必ず付ける**
 * —— これが無いと CLI は導入を拒否する契約(ライセンス同意はこの呼び出しの直前にホスト側の
 * confirm モーダルで得ている)。
 */
export function installSystemImageApiArgs(pkg: string): string[] {
  return ["api", "install-system-image", "--package", pkg, "--accept-licenses"];
}

/**
 * `fleetest api delete-device` の CLI 引数を組み立てる(deviceCommandArgs と組み合わせて使う純粋関数。
 * monitorDeviceCreateOps.ts の spawnDeleteDevice からテスト分離のために公開する)。iOS は --udid、
 * Android は --avd(いずれも識別子1本。実行プロファイル・プロジェクトは参照しない —— この操作は
 * ホスト上の実体[シミュレータ/AVD]を直接消すだけで、どの実行プロファイルが参照しているかは
 * finished イベントの referencedBy で返ってくる)。
 */
export function deleteDeviceApiArgs(
  platform: MonitorPlatform,
  identifier: string,
  project?: string,
): string[] {
  const args = ["api", "delete-device", "--platform", platform,
                platform === "ios" ? "--udid" : "--avd", identifier];
  // **解決済みのプロジェクト名を必ず渡す**。省略すると CLI 側は「TestProjects/ に1つだけなら
  // それ、無ければ既定」で推測し、複数プロジェクトがあると解決できず referencedBy が
  // 黙って空になる(= 参照が残っている警告が出なくなる)
  if (project !== undefined && project !== "") {
    args.push("--project", project);
  }
  return args;
}

export interface DeleteDeviceLogEvent {
  readonly kind: "log";
  readonly message: string;
}

export interface DeleteDeviceFinishedEvent {
  readonly kind: "finished";
  readonly ok: boolean;
  readonly error: string | null;
  /** 削除した識別子を参照している実行プロファイル名。省略時は空扱い(古い CLI 互換)。 */
  readonly referencedBy?: readonly string[];
}

/** `fleetest api delete-device` の NDJSON 1行分のイベント(isCreateDeviceEvent と対になる形)。 */
export type DeleteDeviceEvent = DeleteDeviceLogEvent | DeleteDeviceFinishedEvent;

function isReferencedByLike(value: unknown): value is readonly string[] {
  return Array.isArray(value) && value.every((v) => typeof v === "string");
}

/** DeleteDeviceEvent の判定(isCreateDeviceEvent と同じ方針)。referencedBy は省略可・あれば string[] のみ許容。 */
export function isDeleteDeviceEvent(value: unknown): value is DeleteDeviceEvent {
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
        (value.referencedBy === undefined || isReferencedByLike(value.referencedBy))
      );
    default:
      return false;
  }
}

/**
 * デバイス一覧の詳細文字列(webview の runProfileDevicesTab.js の deviceDetail と同じ規則)。
 * Android エミュレータ: "AVD: <avd>"。それ以外は "<model> / <osVersion> / <識別子>" を
 * 欠けた要素を飛ばして連結する(識別子は iOS = udid・Android 実機 = serial)。
 * 全部欠けていれば "iOS" / "Android"。
 */
export function machineDeviceDetail(entry: MachineDeviceEntry): string {
  if (entry.platform === "android" && entry.avd) {
    return `AVD: ${entry.avd}`;
  }
  const id = entry.platform === "ios" ? entry.udid : entry.serial;
  const parts = [entry.model, entry.osVersion, id].filter((part): part is string => !!part);
  return parts.length > 0 ? parts.join(" / ") : (entry.platform === "ios" ? "iOS" : "Android");
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

// ---- デバイス行の右クリックメニュー「除去」(プロファイルタブ・run 単位) -----------------------
// handleRunProfileDeviceRemove(monitorProfilesController.ts)が全実行プロファイルへ順に適用する
// 純粋関数(ファイル I/O・全プロファイルの走査は呼び出し側)。

/** value がデバイスエントリ(オブジェクト、配列でない)として扱ってよいか。 */
function isDeviceEntryLike(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** devices[] エントリの platform/machine/name を読む(型不正・欠落は undefined)。machine は
 * "local"/"" を手元(undefined)に正規化する。 */
function readDeviceRef(
  value: unknown,
): { readonly platform: MonitorPlatform; readonly machine?: string; readonly name: string } | undefined {
  if (!isDeviceEntryLike(value) || typeof value.name !== "string") {
    return undefined;
  }
  if (value.platform !== "ios" && value.platform !== "android") {
    return undefined;
  }
  const raw = typeof value.machine === "string" ? value.machine.trim() : "";
  return { platform: value.platform, name: value.name, machine: raw === "" || raw === "local" ? undefined : raw };
}

/**
 * runs/<name>.json の devices[] から (platform, machine, name) が一致するエントリを取り除いた
 * 新オブジェクトを返す(未知キー保持)。**実体を消したあとの後始末**(delete-device 成功時)と
 * **プロファイルタブの「除去」**(利用者操作)の両方から、対象の実行プロファイルすべてへ
 * 順に適用する。非オブジェクトなら null(「不正なファイル」)、removed は取り除いた件数
 * (通常 0 か 1。同じ鍵の重複エントリがあれば全部取り除く)。
 */
export function removeDeviceFromRunProfile(
  profileObject: unknown,
  key: { readonly platform: MonitorPlatform; readonly machine?: string; readonly name: string },
): { readonly object: Record<string, unknown>; readonly removed: number } | null {
  if (typeof profileObject !== "object" || profileObject === null || Array.isArray(profileObject)) {
    return null;
  }
  const source = profileObject as Record<string, unknown>;
  const devices = source.devices;
  if (!Array.isArray(devices)) {
    return { object: { ...source }, removed: 0 };
  }
  const targetKey = runProfileDeviceRefKey(key);
  const filtered = devices.filter((device) => {
    const ref = readDeviceRef(device);
    return ref === undefined || runProfileDeviceRefKey(ref) !== targetKey;
  });
  if (filtered.length === devices.length) {
    return { object: { ...source }, removed: 0 };
  }
  return { object: { ...source, devices: filtered }, removed: devices.length - filtered.length };
}

// ---- 「+既存から選択」モーダル(#device-pick-overlay)の OK(runProfileDevicesSync) ---------------
// handleRunProfileDevicesSync(monitorProfilesController.ts)が使う純粋関数(ファイル I/O は呼び出し側)。
// 追加先は「現在選択中の実行プロファイル」1つだけ(除去はプロファイルタブのチェックボックス/
// 右クリック「除去」が別に持つ)。

export type AddDevicesToRunProfileResult =
  | { readonly ok: true; readonly object: Record<string, unknown>; readonly added: readonly string[] }
  | { readonly ok: false; readonly error: string };

/**
 * 選択中の実行プロファイルの devices[] 末尾へ entries(runProfileDevicesSync の add)を追記した
 * 新オブジェクトを返す(未知キー保持)。profileObject 非オブジェクトなら ok:false。
 * 名前衝突は catalog(プロジェクトのデバイスカタログ)+ このプロファイルの既存分 + 同一バッチ内で
 * 判定し、"名前 (2)"、"名前 (3)" ... と自動採番で解決する(チェック時点では衝突が無くても
 * 追加までの間にファイルが変わりうるため、エラーにせず救済する)。**判定は同じ machine の中だけ**
 * (一意なのは (machine, name))。added は entries と同じ順序で最終的に使われた名前を返す。
 */
export function addDevicesToRunProfile(
  profileObject: unknown,
  entries: readonly RunProfileDeviceAddEntry[],
  catalog: readonly MachineDeviceEntry[],
): AddDevicesToRunProfileResult {
  if (typeof profileObject !== "object" || profileObject === null || Array.isArray(profileObject)) {
    return { ok: false, error: t("monitor.runProfile.invalidFormat") };
  }
  const source = profileObject as Record<string, unknown>;
  const existingDevices = Array.isArray(source.devices) ? source.devices : [];

  const nameKey = (machine: string | undefined, name: string): string => `${machine ?? ""}\t${name}`;
  const existingNames = new Set<string>();
  for (const entry of catalog) {
    existingNames.add(nameKey(entry.machine, entry.name));
  }
  for (const device of existingDevices) {
    const ref = readDeviceRef(device);
    if (ref) {
      existingNames.add(nameKey(ref.machine, ref.name));
    }
  }

  const added: string[] = [];
  const newEntries: Record<string, unknown>[] = [];
  for (const entry of entries) {
    let name = entry.name;
    let suffix = 2;
    while (existingNames.has(nameKey(entry.machine, name))) {
      name = `${entry.name} (${suffix})`;
      suffix += 1;
    }
    existingNames.add(nameKey(entry.machine, name));
    added.push(name);
    newEntries.push(orderedDeviceEntry({ ...entry, name, enabled: true }));
  }

  return { ok: true, object: { ...source, devices: [...existingDevices, ...newEntries] }, added };
}
