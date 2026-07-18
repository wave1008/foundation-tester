import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as vscode from "vscode";

export type Platform = "ios" | "android";

export interface FtesterConfig {
  /** ワークスペースルート基準の絶対パスに解決済みの CLI バイナリパス。 */
  binaryPath: string;
  /** 空文字列の場合は自動判定(Projects/ 直下)に委ねる。 */
  project: string;
  profile: string;
  platform: Platform;
  /** 0 の場合は未指定(CLI 側の既定値を使う)。 */
  port: number;
  serial: string;
  /** false の場合、CLI 呼び出しに --skip-build を付与する。 */
  buildBeforeRun: boolean;
  /** true の場合、実行(非dry-run)・デバッグ実行の CLI 呼び出しに --heal を付与する。 */
  heal: boolean;
  /** デバイスモニターの更新間隔(秒)。0.5 未満は 0.5 に切り上げる(`ftester api monitor --interval`)。 */
  monitorInterval: number;
  /** モニターのフレーム画像の長辺px(240〜1600にクランプ。`ftester api monitor --max-width`)。 */
  monitorMaxWidth: number;
  /** ライブ操作パネルの自動フレーム更新レート上限(fps、3〜30にクランプ)。旧実装は成功時 delayMs=0 の
   * ホットループでデバイスが返す限り最速で /screenshot を叩き負荷源だった。目標fpsで頭打ちにする
   * (monitorLiveController.ts frameTick)。 */
  liveFps: number;
  /** iOS シミュレータのライブ映像ストリーミング(ftester-simstream)を使うか。true でも helper が
   * 未ビルド(resolveSimStream が undefined)なら自動でポーリングにフォールバックする。 */
  iosStreamEnabled: boolean;
  /** Android 実機/エミュレータのライブ映像ストリーミング(ftester-androidstream)を使うか。
   * iosStreamEnabled と同じ方針(helper 未ビルド・adb 未検出なら自動でポーリングにフォールバック)。 */
  androidStreamEnabled: boolean;
  /** 画面ストリーミングのコーデック。"h264": WebCodecs によるハードウェアデコード(既定、
   * deviceStream.ts の v2 stdout 形式)。"mjpeg": 従来方式(v1 形式)。webview からの
   * codecError(WebCodecs 未対応/デコード失敗)を受けた個別デバイスは設定に関わらず
   * mjpeg へ自動フォールバックする(monitorDeviceStreamController.ts/monitorLiveController.ts)。 */
  streamCodec: "h264" | "mjpeg";
  /** true の場合、Test Explorer ツリーを失敗テストのみ表示(未実施・成功は除外。testTree.ts の
   * resolveFailedFilter。トグルボタンの context key 同期は extension.ts registerCommands)。 */
  showOnlyFailedTests: boolean;
  /** true の場合、ブリッジ無応答(connected→booted 降格が booted 連続5回続く)を検出したら、実行中の
   * レーンが無い間に限り device-up で自動修復を試みる(monitorBridgeWatchdog.ts)。 */
  autoRepairBridge: boolean;
  /** true の場合、Android ゲスト OS 異常(Wi-Fi 無効・時計凍結)を検出したら Wi-Fi 再有効化→再起動の
   * 順で自動修復を試みる(monitorHealthWatchdog.ts)。既定 false: autoRepairBridge と異なり、
   * Wi-Fi をわざと切ってテストするケースを勝手に上書きしないため。 */
  autoRepairDeviceHealth: boolean;
  /** true の場合、テスト実行(Run Test、非dry-run)開始時にライブ操作パネル(livePanel.ts)を
   * エディタの右側(ViewColumn.Beside)へ自動表示する。 */
  liveControlOnRun: boolean;
}

/** ワークスペースルート(Package.swift のあるフォルダ)を解決する。開いていなければ undefined。 */
export function resolveWorkspaceRoot(): string | undefined {
  const folders = vscode.workspace.workspaceFolders;
  if (!folders || folders.length === 0) {
    return undefined;
  }
  // 単一ルート運用を前提とする。複数ルートの場合は先頭のフォルダを採用する。
  return folders[0]!.uri.fsPath;
}

export function readConfig(workspaceRoot: string): FtesterConfig {
  const configuration = vscode.workspace.getConfiguration("ftester");
  const rawBinaryPath = configuration.get<string>("binaryPath", ".build/debug/ftester");
  const binaryPath = path.isAbsolute(rawBinaryPath)
    ? rawBinaryPath
    : path.join(workspaceRoot, rawBinaryPath);

  return {
    binaryPath,
    project: configuration.get<string>("project", ""),
    profile: configuration.get<string>("profile", ""),
    platform: configuration.get<Platform>("platform", "ios"),
    port: configuration.get<number>("port", 0),
    serial: configuration.get<string>("serial", ""),
    buildBeforeRun: configuration.get<boolean>("buildBeforeRun", true),
    heal: configuration.get<boolean>("heal", false),
    monitorInterval: Math.max(0.5, configuration.get<number>("monitorInterval", 2)),
    monitorMaxWidth: Math.min(1600, Math.max(240, configuration.get<number>("monitorMaxWidth", 960))),
    liveFps: Math.min(30, Math.max(3, configuration.get<number>("liveFps", 12))),
    iosStreamEnabled: configuration.get<boolean>("iosStreamEnabled", true),
    androidStreamEnabled: configuration.get<boolean>("androidStreamEnabled", true),
    streamCodec: configuration.get<"h264" | "mjpeg">("streamCodec", "h264"),
    showOnlyFailedTests: configuration.get<boolean>("showOnlyFailedTests", false),
    autoRepairBridge: configuration.get<boolean>("autoRepairBridge", true),
    autoRepairDeviceHealth: configuration.get<boolean>("autoRepairDeviceHealth", false),
    liveControlOnRun: configuration.get<boolean>("liveControlOnRun", true),
  };
}

/** X_OK で実行可能な通常ファイルか(ディレクトリや非実行ファイルは false)。存在しない・アクセス不可は false。 */
function isExecutableFile(candidate: string): boolean {
  try {
    if (!fs.statSync(candidate).isFile()) {
      return false;
    }
    fs.accessSync(candidate, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/** binaryPath を見つけた ftester-simstream のパスをキーにキャッシュ(見つかった正の結果のみ)。 */
const simStreamCache = new Map<string, string>();

/**
 * ftester バイナリと同じディレクトリにある ftester-simstream(iOS ライブ映像 helper)の絶対パス。
 * 実行可能ファイルが無ければ undefined(呼び出し側はポーリングにフォールバック)。
 * 正の結果だけキャッシュする(未検出はキャッシュしない=後から helper をビルドすれば Reload 無しで有効化される)。
 */
export function resolveSimStream(config: FtesterConfig): string | undefined {
  const cached = simStreamCache.get(config.binaryPath);
  if (cached !== undefined) {
    return cached;
  }
  const candidate = path.join(path.dirname(config.binaryPath), "ftester-simstream");
  if (isExecutableFile(candidate)) {
    simStreamCache.set(config.binaryPath, candidate);
    return candidate;
  }
  return undefined;
}

/** binaryPath を見つけた ftester-androidstream のパスをキーにキャッシュ(resolveSimStream と同じ方針)。 */
const androidStreamCache = new Map<string, string>();

/**
 * ftester バイナリと同じディレクトリにある ftester-androidstream(Android ライブ映像 helper)の絶対パス。
 * resolveSimStream と同じ方針(実行可能ファイルが無ければ undefined、正の結果のみキャッシュ)。
 */
export function resolveAndroidStream(config: FtesterConfig): string | undefined {
  const cached = androidStreamCache.get(config.binaryPath);
  if (cached !== undefined) {
    return cached;
  }
  const candidate = path.join(path.dirname(config.binaryPath), "ftester-androidstream");
  if (isExecutableFile(candidate)) {
    androidStreamCache.set(config.binaryPath, candidate);
    return candidate;
  }
  return undefined;
}

/** resolveAdb が見つけた adb の絶対パス(config に依存しないため単一キャッシュ。正の結果のみ)。 */
let adbPathCache: string | undefined;

/**
 * adb 実行ファイルの絶対パス。候補順は ANDROID_HOME→$HOME/Library/Android/sdk→$PATH 各ディレクトリ→
 * /opt/homebrew/bin→/usr/local/bin(Sources/ftester-androidstream/main.m・FTAndroid/AndroidDriver.swift の
 * 解決順と揃えること。ただし当拡張は対話シェルの PATH を素直に使えるため $PATH 探索を追加している)。
 * 見つからなければ undefined(呼び出し側はポーリングにフォールバック)。正の結果のみキャッシュする
 * (resolveSimStream と同じ理由: 後から adb を導入すれば Reload 無しで有効化される)。
 */
export function resolveAdb(): string | undefined {
  if (adbPathCache !== undefined) {
    return adbPathCache;
  }
  const candidates: string[] = [];
  const androidHome = process.env.ANDROID_HOME;
  if (androidHome) {
    candidates.push(path.join(androidHome, "platform-tools", "adb"));
  }
  candidates.push(path.join(os.homedir(), "Library", "Android", "sdk", "platform-tools", "adb"));
  for (const dir of (process.env.PATH ?? "").split(path.delimiter)) {
    if (dir.length > 0) {
      candidates.push(path.join(dir, "adb"));
    }
  }
  candidates.push("/opt/homebrew/bin/adb", "/usr/local/bin/adb");
  for (const candidate of candidates) {
    if (isExecutableFile(candidate)) {
      adbPathCache = candidate;
      return candidate;
    }
  }
  return undefined;
}

/** Projects/ 直下にあるテストプロジェクト名(ディレクトリ名)の一覧を返す。 */
export function listProjectCandidates(workspaceRoot: string): string[] {
  const projectsDir = path.join(workspaceRoot, "Projects");
  try {
    return fs
      .readdirSync(projectsDir, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .sort((a, b) => a.localeCompare(b));
  } catch {
    return [];
  }
}

/** Projects/<project>/profiles/runs/ にある実行プロファイル名(拡張子なし)の一覧を返す。 */
export function listRunProfileNames(workspaceRoot: string, project: string): string[] {
  const runsDir = path.join(workspaceRoot, "Projects", project, "profiles", "runs");
  try {
    return fs
      .readdirSync(runsDir, { withFileTypes: true })
      .filter((entry) => entry.isFile() && entry.name.endsWith(".json"))
      .map((entry) => entry.name.slice(0, -".json".length))
      .sort((a, b) => a.localeCompare(b));
  } catch {
    return [];
  }
}

/**
 * Projects/<project>/profiles/runs/<profileName>.json の devices[].name。
 * 読めない/解析不可/devices無しは null(空配列と区別: monitorPanel.ts の
 * devicesToShutdownOnScopeChange が「絞り込みなし」と「絞り込んだ結果0件」を区別するため)。
 */
export function readRunProfileDeviceNames(
  workspaceRoot: string,
  project: string,
  profileName: string,
): string[] | null {
  const runProfilePath = path.join(workspaceRoot, "Projects", project, "profiles", "runs", `${profileName}.json`);
  try {
    const raw = fs.readFileSync(runProfilePath, "utf8");
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== "object" || parsed === null || !("devices" in parsed)) {
      return null;
    }
    const devices = (parsed as { devices: unknown }).devices;
    if (!Array.isArray(devices) || devices.length === 0) {
      return null;
    }
    const names = devices
      .map((device) => (typeof device === "object" && device !== null ? (device as { name: unknown }).name : undefined))
      .filter((name): name is string => typeof name === "string");
    return names.length > 0 ? names : null;
  } catch {
    return null;
  }
}

/** Projects/<project>/profiles/apps/ にあるアプリプロファイル名(拡張子なし)の一覧を返す。 */
export function listAppProfileNames(workspaceRoot: string, project: string): string[] {
  const appsDir = path.join(workspaceRoot, "Projects", project, "profiles", "apps");
  try {
    return fs
      .readdirSync(appsDir, { withFileTypes: true })
      .filter((entry) => entry.isFile() && entry.name.endsWith(".json"))
      .map((entry) => entry.name.slice(0, -".json".length))
      .sort((a, b) => a.localeCompare(b));
  } catch {
    return [];
  }
}

/**
 * Projects/<project>/profiles/apps/<name>.json から platform 向けの起動対象を読む。
 * app/appPath は platform セクションのみ参照する(RunProfile.swift AppProfileSection.merging:
 * common へのフォールバックは無い。common.app は非推奨)。bundle が無ければ null。
 */
export function readAppProfileTarget(
  workspaceRoot: string,
  project: string,
  name: string,
  platform: Platform,
): { bundle: string; appPath: string | null } | null {
  const profilePath = path.join(workspaceRoot, "Projects", project, "profiles", "apps", `${name}.json`);
  try {
    const raw = fs.readFileSync(profilePath, "utf8");
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== "object" || parsed === null) {
      return null;
    }
    const section = (parsed as Record<string, unknown>)[platform];
    if (typeof section !== "object" || section === null) {
      return null;
    }
    const { app, appPath: rawAppPath } = section as Record<string, unknown>;
    if (typeof app !== "string") {
      return null;
    }
    let appPath: string | null = null;
    if (typeof rawAppPath === "string") {
      // ベースディレクトリ・~展開の契約: RunProfile.swift:492 resolvePath(_, base: project.rootURL)
      // (rootURL = Projects/<project>/)。
      const expanded = rawAppPath.startsWith("~") ? path.join(os.homedir(), rawAppPath.slice(1)) : rawAppPath;
      appPath = path.isAbsolute(expanded)
        ? expanded
        : path.resolve(path.join(workspaceRoot, "Projects", project), expanded);
    }
    return { bundle: app, appPath };
  } catch {
    return null;
  }
}

/**
 * profiles/machines/ 直下の .json が**ちょうど1つ**のときのみ、その ios→android 順
 * (各プラットフォーム内は name 順)の devices[].name を返す(monitorPanel.ts の profileAdd が新規実行プロファイルの
 * デバイス候補に使う)。実際に「使われる」マシンプロファイルの判定(登録名/FT_MACHINE)は
 * CLI 側にしか無く、この拡張からは複数存在時にどれを使うか判定できないため、あいまいさが
 * 無い場合に限って埋める。0個・複数・読み取り/解析失敗は空配列。
 */
export function readMachineDeviceNames(workspaceRoot: string, project: string): string[] {
  const machinesDir = path.join(workspaceRoot, "Projects", project, "profiles", "machines");
  let entries: fs.Dirent[];
  try {
    entries = fs
      .readdirSync(machinesDir, { withFileTypes: true })
      .filter((entry) => entry.isFile() && entry.name.endsWith(".json"));
  } catch {
    return [];
  }
  if (entries.length !== 1) {
    return [];
  }
  try {
    const raw = fs.readFileSync(path.join(machinesDir, entries[0]!.name), "utf8");
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== "object" || parsed === null) {
      return [];
    }
    const names: string[] = [];
    for (const platform of ["ios", "android"] as const) {
      const section = (parsed as Record<string, unknown>)[platform];
      if (typeof section !== "object" || section === null) {
        continue;
      }
      const devices = (section as Record<string, unknown>).devices;
      if (!Array.isArray(devices)) {
        continue;
      }
      const sectionNames: string[] = [];
      for (const device of devices) {
        const name =
          typeof device === "object" && device !== null
            ? (device as Record<string, unknown>).name
            : undefined;
        if (typeof name === "string") {
          sectionNames.push(name);
        }
      }
      sectionNames.sort((a, b) => a.localeCompare(b));
      names.push(...sectionNames);
    }
    return names;
  } catch {
    return [];
  }
}

/**
 * profiles/machines/<マシン名>.json の devices[] 1件分。name のみ必須(simulator/os/udid は
 * iOS 用、avd は Android 用。未知キーは無視)。monitorModel.ts にも同じ形の型を独立定義している
 * (vscode 非依存を保つため、型のためだけに config.ts を import させない方針)。
 */
export interface MachineDeviceEntry {
  readonly name: string;
  readonly platform: Platform;
  readonly simulator?: string;
  readonly os?: string;
  readonly udid?: string;
  readonly port?: number;
  readonly avd?: string;
}

/** 1マシンプロファイル(machines/<マシン名>.json、ファイル名=マシン名)の要約。 */
export interface MachineProfileSummary {
  readonly name: string;
  readonly devices: readonly MachineDeviceEntry[];
}

/** machines/<name>.json の devices[] 1要素を検証・変換する。name欠落/型不正は undefined(呼び出し側でスキップ)。 */
function toMachineDeviceEntry(value: unknown, platform: Platform): MachineDeviceEntry | undefined {
  if (typeof value !== "object" || value === null) {
    return undefined;
  }
  const record = value as Record<string, unknown>;
  const { name, simulator, os: osVersion, udid, port, avd } = record;
  if (typeof name !== "string") {
    return undefined;
  }
  if (simulator !== undefined && typeof simulator !== "string") {
    return undefined;
  }
  if (osVersion !== undefined && typeof osVersion !== "string") {
    return undefined;
  }
  if (udid !== undefined && typeof udid !== "string") {
    return undefined;
  }
  if (port !== undefined && typeof port !== "number") {
    return undefined;
  }
  if (avd !== undefined && typeof avd !== "string") {
    return undefined;
  }
  return {
    name,
    platform,
    simulator: simulator as string | undefined,
    os: osVersion as string | undefined,
    udid: udid as string | undefined,
    port: port as number | undefined,
    avd: avd as string | undefined,
  };
}

/**
 * profiles/machines/ 直下の .json をファイル名順に読み、ios→android順・各プラットフォーム内は
 * name 順で devices を一覧化する(webview「プロファイル」タブ用)。要素単位の型不正はスキップ、ファイル自体が読めなければ
 * そのマシンは devices:[] のみ返す(1件の不備で一覧全体を空にしないため)。readMachineDeviceNames
 * と異なり複数ファイルを許容する(UI表示用のため「1マシン1ファイル」制約は課さない)。
 */
export function listMachineProfiles(workspaceRoot: string, project: string): MachineProfileSummary[] {
  const machinesDir = path.join(workspaceRoot, "Projects", project, "profiles", "machines");
  let entries: fs.Dirent[];
  try {
    entries = fs
      .readdirSync(machinesDir, { withFileTypes: true })
      .filter((entry) => entry.isFile() && entry.name.endsWith(".json"))
      .sort((a, b) => a.name.localeCompare(b.name));
  } catch {
    return [];
  }

  return entries.map((entry) => {
    const name = entry.name.slice(0, -".json".length);
    try {
      const raw = fs.readFileSync(path.join(machinesDir, entry.name), "utf8");
      const parsed: unknown = JSON.parse(raw);
      if (typeof parsed !== "object" || parsed === null) {
        return { name, devices: [] };
      }
      const devices: MachineDeviceEntry[] = [];
      for (const platform of ["ios", "android"] as const) {
        const section = (parsed as Record<string, unknown>)[platform];
        if (typeof section !== "object" || section === null) {
          continue;
        }
        const rawDevices = (section as Record<string, unknown>).devices;
        if (!Array.isArray(rawDevices)) {
          continue;
        }
        const sectionDevices: MachineDeviceEntry[] = [];
        for (const rawDevice of rawDevices) {
          const device = toMachineDeviceEntry(rawDevice, platform);
          if (device) {
            sectionDevices.push(device);
          }
        }
        sectionDevices.sort((a, b) => a.name.localeCompare(b.name));
        devices.push(...sectionDevices);
      }
      return { name, devices };
    } catch {
      return { name, devices: [] };
    }
  });
}

/**
 * マシンローカル設定($XDG_CONFIG_HOME/ftester/config.json、既定 ~/.config/ftester/config.json。
 * Sources/FTCore/LocalConfig.swift と同じファイル場所・スキーマ)の machineName を読む。
 * 読めない/解析不可/machineName が string でなければ null。
 * (LocalConfig.swift は FT_MACHINE 環境変数を優先するが、この拡張はファイルの状態のみ反映する)。
 */
export function readLocalMachineName(): string | null {
  const xdg = process.env.XDG_CONFIG_HOME;
  const base = xdg && xdg.length > 0 ? xdg : path.join(os.homedir(), ".config");
  const configPath = path.join(base, "ftester", "config.json");
  try {
    const raw = fs.readFileSync(configPath, "utf8");
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== "object" || parsed === null) {
      return null;
    }
    const machineName = (parsed as Record<string, unknown>).machineName;
    return typeof machineName === "string" ? machineName : null;
  } catch {
    return null;
  }
}

/**
 * readLocalMachineName と同じ config.json の machineName を書き換える(マシンプロファイル名変更時、
 * CLI `ftester machine set` が書いた登録名が旧名のままだと解決が壊れるため追随させる)。
 * machineName === oldName のときのみ newName に更新して true を返す(他キーは保持)。
 * 読み取り/解析失敗・オブジェクトでない・不一致なら false(例外は握りつぶす)。
 */
export function updateLocalMachineName(oldName: string, newName: string): boolean {
  const xdg = process.env.XDG_CONFIG_HOME;
  const base = xdg && xdg.length > 0 ? xdg : path.join(os.homedir(), ".config");
  const configPath = path.join(base, "ftester", "config.json");
  try {
    const raw = fs.readFileSync(configPath, "utf8");
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== "object" || parsed === null) {
      return false;
    }
    const record = parsed as Record<string, unknown>;
    if (record.machineName !== oldName) {
      return false;
    }
    const updated = { ...record, machineName: newName };
    fs.writeFileSync(configPath, `${JSON.stringify(updated, null, 2)}\n`, "utf8");
    return true;
  } catch {
    return false;
  }
}

export type ProjectResolution =
  | { kind: "resolved"; project: string }
  | { kind: "none" }
  | { kind: "ambiguous"; candidates: string[] };

/**
 * ftester.project が設定されていればそれを優先。空なら Projects/ 直下から自動判定
 * (1つだけなら採用、0/複数は呼び出し側で誘導が必要)。
 */
export function resolveProjectName(
  workspaceRoot: string,
  config: FtesterConfig,
): ProjectResolution {
  const configured = config.project.trim();
  if (configured.length > 0) {
    return { kind: "resolved", project: configured };
  }
  const candidates = listProjectCandidates(workspaceRoot);
  if (candidates.length === 1) {
    return { kind: "resolved", project: candidates[0]! };
  }
  if (candidates.length === 0) {
    return { kind: "none" };
  }
  return { kind: "ambiguous", candidates };
}
