import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as vscode from "vscode";
import { resolveBinaryPath } from "./binaryPathResolve";

export type Platform = "ios" | "android";

/** モニターのデバイスタイル表示範囲(設定 ftester.monitorDeviceFilter)。既定は "all"。 */
export type MonitorDeviceFilter = "all" | "running";

/** 起動時の更新チェック(設定 ftester.updateCheck)。既定は "auto"。 */
export type UpdateCheckMode = "auto" | "off";

export interface FtesterConfig {
  /** ワークスペースルート基準の絶対パスに解決済みの CLI バイナリパス。 */
  binaryPath: string;
  /** 空文字列の場合は自動判定(TestProjects/ 直下)に委ねる。 */
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
  /** LPT 投入順(過去実績の長い順)。false のとき ftester api run へ --no-lpt を渡す。 */
  lptScheduling: boolean;
  /** LPT が実績として読む run 数(新しい方から)。 */
  lptHistoryRuns: number;
  /** デバイスモニターの更新間隔(秒)。0.5 未満は 0.5 に切り上げる(`ftester api monitor --interval`)。 */
  monitorInterval: number;
  /** モニターのフレーム画像の長辺px(240〜1600にクランプ。`ftester api monitor --max-width`)。 */
  monitorMaxWidth: number;
  /** モニターのデバイスタイルに出す範囲。"all": 監視スコープの全デバイス、"running": そのうち
   * 起動中(offline 以外)のみ。監視スコープ自体(= CLI の --profile)は変えず拡張側の表示フィルタ
   * として効く(monitorProcessManager.ts)。ドロップダウンの「起動中のデバイス」= profile "" +
   * この値 "running"(monitorModel.ts の RUNNING_DEVICES_PROFILE_VALUE)。 */
  monitorDeviceFilter: MonitorDeviceFilter;
  /** ライブ操作パネルの自動フレーム更新レート上限(fps、3〜30にクランプ)。**成功時 delayMs=0 の
   * ホットループにしない** —— デバイスが返す限り最速で /screenshot を叩く負荷源になる。目標fpsで頭打ちにする
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
  /** "auto": 起動時に upstream の更新有無を確認し、あれば通知する(updateCheck.ts)。"off": 確認しない。
   * 確認するだけで取り込みはしない(取り込みは /ftester-update)。 */
  updateCheck: UpdateCheckMode;
  /** リモート実行結果の回収方針(docs/remote-runner.md §13「原則」)。artifacts はリモートの
   * results/ を回収するか("collect" 既定 / "on-demand" は回収しない)。run がどのホストへ
   * ディスパッチされるかはこの設定には無い —— CLI がマシンプロファイルの `host` フィールドから
   * 判定する(拡張は関与しない)。登録簿(name→host/dir/machine)もここには持たない ——
   * 正は CLI の LocalConfig で、remoteHostsController.ts が `ftester api remote-hosts` を読む
   * (設定タブのホスト表を支えるためだけに使う)。 */
  remote: { artifacts: "collect" | "on-demand" };
  /** true の場合、実行(dry-run・ライブ操作パネル連動を除く)開始前に `ftester api remote-compat` で
   * リモート機の版ズレを照合し、ズレていれば確認ダイアログを出す(runHandler.ts executeRun)。 */
  remoteCompatCheck: boolean;
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
  const binaryPath = resolveBinaryPath(workspaceRoot, rawBinaryPath);

  return {
    binaryPath,
    project: configuration.get<string>("project", ""),
    profile: configuration.get<string>("profile", ""),
    platform: configuration.get<Platform>("platform", "ios"),
    port: configuration.get<number>("port", 0),
    serial: configuration.get<string>("serial", ""),
    buildBeforeRun: configuration.get<boolean>("buildBeforeRun", true),
    heal: configuration.get<boolean>("heal", false),
    lptScheduling: configuration.get<boolean>("lptScheduling", true),
    lptHistoryRuns: Math.max(1, Math.floor(configuration.get<number>("lptHistoryRuns", 5))),
    monitorInterval: Math.max(0.5, configuration.get<number>("monitorInterval", 2)),
    monitorMaxWidth: Math.min(1600, Math.max(240, configuration.get<number>("monitorMaxWidth", 960))),
    monitorDeviceFilter: configuration.get<string>("monitorDeviceFilter", "all") === "running" ? "running" : "all",
    liveFps: Math.min(30, Math.max(3, configuration.get<number>("liveFps", 12))),
    iosStreamEnabled: configuration.get<boolean>("iosStreamEnabled", true),
    androidStreamEnabled: configuration.get<boolean>("androidStreamEnabled", true),
    streamCodec: configuration.get<"h264" | "mjpeg">("streamCodec", "h264"),
    showOnlyFailedTests: configuration.get<boolean>("showOnlyFailedTests", false),
    autoRepairBridge: configuration.get<boolean>("autoRepairBridge", true),
    autoRepairDeviceHealth: configuration.get<boolean>("autoRepairDeviceHealth", false),
    liveControlOnRun: configuration.get<boolean>("liveControlOnRun", true),
    updateCheck: configuration.get<string>("updateCheck", "auto") === "off" ? "off" : "auto",
    remote: {
      artifacts: configuration.get<string>("remote.artifacts", "collect") === "on-demand" ? "on-demand" : "collect",
    },
    remoteCompatCheck: configuration.get<boolean>("remoteCompatCheck", true),
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

/** binaryPath を見つけた ftester-devicepoll のパスをキーにキャッシュ(resolveSimStream と同じ方針)。 */
const devicePollCache = new Map<string, string>();

/**
 * ftester バイナリと同じディレクトリにある ftester-devicepoll(**実機**のライブ映像 helper)の絶対パス。
 * 実機はスクリーンショットのポーリングで配信する: iOS 実機は simstream が CoreSimulator 私有 API の
 * ため不可、Android 実機は screenrecord だと静止画面でフレームが流れない(Sources/ftester-devicepoll
 * の冒頭コメント参照)。resolveSimStream と同じ方針(未検出は undefined・正の結果のみキャッシュ)。
 */
export function resolveDevicePoll(config: FtesterConfig): string | undefined {
  const cached = devicePollCache.get(config.binaryPath);
  if (cached !== undefined) {
    return cached;
  }
  const candidate = path.join(path.dirname(config.binaryPath), "ftester-devicepoll");
  if (isExecutableFile(candidate)) {
    devicePollCache.set(config.binaryPath, candidate);
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

/** TestProjects/ 直下にあるテストプロジェクト名(ディレクトリ名)の一覧を返す。 */
export function listProjectCandidates(workspaceRoot: string): string[] {
  const projectsDir = path.join(workspaceRoot, "TestProjects");
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

/** TestProjects/<project>/profiles/runs/ にある実行プロファイル名(拡張子なし)の一覧を返す。 */
export function listRunProfileNames(workspaceRoot: string, project: string): string[] {
  const runsDir = path.join(workspaceRoot, "TestProjects", project, "profiles", "runs");
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
 * プロジェクト切替に追従して `ftester.profile` をどうするか。**実行プロファイルはプロジェクトに
 * 属する**ので、切り替えたあとも前のプロジェクトの名前が残ると、その名前はもう存在せず
 * CLI が「run profile not found」で落ちる(2026-08-17 の実害: project=E2E-Android /
 * profile=local+remote でモニターが起動できなくなった)。
 *
 * - 新しいプロジェクトにその名前があるなら**そのまま**(同名のプロファイルを持つ構成は普通)
 * - 無いなら **"" (未選択)** へ。**別の名前を勝手に選ばない** —— どのプロファイルで走るかは
 *   デバイスとアプリを決める選択なので、黙って差し替えると別の対象を操作したことになる
 * 戻り値 nil = 変更不要(書き込まない = 設定変更ループを起こさない)
 */
export function reconciledProfileForProject(
  currentProfile: string,
  availableProfiles: readonly string[],
): string | undefined {
  if (currentProfile === "" || availableProfiles.includes(currentProfile)) {
    return undefined;
  }
  return "";
}

/** TestProjects/<project>/profiles/apps/ にあるアプリプロファイル名(拡張子なし)の一覧を返す。 */
export function listAppProfileNames(workspaceRoot: string, project: string): string[] {
  const appsDir = path.join(workspaceRoot, "TestProjects", project, "profiles", "apps");
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
 * TestProjects/<project>/profiles/apps/<name>.json から platform 向けの起動対象を読む。
 * app/appPath は platform セクションのみ参照する(RunProfile.swift AppProfileSection.merging:
 * common へのフォールバックは無い。common.app は非推奨)。bundle が無ければ null。
 */
export function readAppProfileTarget(
  workspaceRoot: string,
  project: string,
  name: string,
  platform: Platform,
): { bundle: string; appPath: string | null } | null {
  const profilePath = path.join(workspaceRoot, "TestProjects", project, "profiles", "apps", `${name}.json`);
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
      // (rootURL = TestProjects/<project>/)。
      const expanded = rawAppPath.startsWith("~") ? path.join(os.homedir(), rawAppPath.slice(1)) : rawAppPath;
      appPath = path.isAbsolute(expanded)
        ? expanded
        : path.resolve(path.join(workspaceRoot, "TestProjects", project), expanded);
    }
    return { bundle: app, appPath };
  } catch {
    return null;
  }
}

export interface AppProfileDetail {
  readonly appName: string | null;
  readonly bundle: string | null;
  readonly appPath: string | null;
}

/** ライブ操作パネルの詳細表示用。readAppProfileTarget と違い bundle 欠落でも null にせず、
 * 表示名(platform セクションのみ。common からは継承しない)と
 * platform セクションの app / appPath を個別に返す。ファイル未読/解析失敗のみ null。 */
export function readAppProfileDetail(
  workspaceRoot: string,
  project: string,
  name: string,
  platform: Platform,
): AppProfileDetail | null {
  const profilePath = path.join(workspaceRoot, "TestProjects", project, "profiles", "apps", `${name}.json`);
  try {
    const parsed: unknown = JSON.parse(fs.readFileSync(profilePath, "utf8"));
    if (typeof parsed !== "object" || parsed === null) {
      return null;
    }
    const record = parsed as Record<string, unknown>;
    const section = typeof record[platform] === "object" && record[platform] !== null
      ? (record[platform] as Record<string, unknown>) : undefined;
    const str = (v: unknown): string | null => (typeof v === "string" && v.length > 0 ? v : null);
    // 表示名は platform セクションのみ。**common からは継承しない**(Sources/FTCore/RunProfile.swift
    // の AppProfileSection.merging と同期。common に残っている appName は CLI 側が未知キーとして
    // 警告する対象なので、ここで拾うと警告と表示が食い違う)
    const appName = str(section?.appName);
    const bundle = str(section?.app);
    const rawAppPath = str(section?.appPath);
    let appPath: string | null = null;
    if (rawAppPath) {
      // ベースディレクトリ・~展開の契約は readAppProfileTarget と同一(RunProfile.swift:492 resolvePath, base=TestProjects/<project>/)。
      const expanded = rawAppPath.startsWith("~") ? path.join(os.homedir(), rawAppPath.slice(1)) : rawAppPath;
      appPath = path.isAbsolute(expanded)
        ? expanded
        : path.resolve(path.join(workspaceRoot, "TestProjects", project), expanded);
    }
    return { appName, bundle, appPath };
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
  const machinesDir = path.join(workspaceRoot, "TestProjects", project, "profiles", "machines");
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
 * kind="physical" は実機で、識別子は iOS=udid / Android=serial(Sources/FTCore/RunProfile.swift)。
 */
export interface MachineDeviceEntry {
  readonly name: string;
  readonly platform: Platform;
  /** このデバイスが居る機械(登録名。省略=プロファイル直下の host、それも無ければ手元)。
   * 一意なのは (host, name)(Sources/FTCore/DeviceHostGrouping.swift)。 */
  readonly host?: string;
  readonly kind?: "virtual" | "physical";
  readonly simulator?: string;
  readonly os?: string;
  readonly udid?: string;
  readonly port?: number;
  readonly avd?: string;
  readonly serial?: string;
  /** 実機の機種名(表示専用。同定には使わない)。 */
  readonly model?: string;
}

/** 1マシンプロファイル(machines/<マシン名>.json、ファイル名=マシン名)の要約。 */
export interface MachineProfileSummary {
  readonly name: string;
  readonly devices: readonly MachineDeviceEntry[];
  /** 登録済みリモートホスト名(machines/<name>.json 直下の "host"。未設定/absent = ローカル)。
   * CLI が run のディスパッチ先をここから判定する(この拡張は判定しない)。 */
  readonly host?: string;
}

/** machines/<name>.json の devices[] 1要素を検証・変換する。name欠落/型不正は undefined(呼び出し側でスキップ)。 */
function toMachineDeviceEntry(value: unknown, platform: Platform): MachineDeviceEntry | undefined {
  if (typeof value !== "object" || value === null) {
    return undefined;
  }
  const record = value as Record<string, unknown>;
  const { name, host, kind, simulator, os: osVersion, udid, port, avd, serial, model } = record;
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
  if (serial !== undefined && typeof serial !== "string") {
    return undefined;
  }
  if (model !== undefined && typeof model !== "string") {
    return undefined;
  }
  if (host !== undefined && typeof host !== "string") {
    return undefined;
  }
  // kind は省略可(未指定=virtual)。未知の値はこのエントリだけ捨てる
  // (Swift 側は DeviceKind の decode に失敗してプロファイル全体がエラーになる。
  // 拡張が勝手に virtual と解釈して表示すると、run では動かないものを動くように見せてしまう)
  if (kind !== undefined && kind !== "virtual" && kind !== "physical") {
    return undefined;
  }
  return {
    name,
    platform,
    host: host as string | undefined,
    kind: kind as "virtual" | "physical" | undefined,
    simulator: simulator as string | undefined,
    os: osVersion as string | undefined,
    udid: udid as string | undefined,
    port: port as number | undefined,
    avd: avd as string | undefined,
    serial: serial as string | undefined,
    model: model as string | undefined,
  };
}

/**
 * profiles/machines/ 直下の .json をファイル名順に読み、ios→android順・各プラットフォーム内は
 * name 順で devices を一覧化する(webview「プロファイル」タブ用)。要素単位の型不正はスキップ、ファイル自体が読めなければ
 * そのマシンは devices:[] のみ返す(1件の不備で一覧全体を空にしないため)。readMachineDeviceNames
 * と異なり複数ファイルを許容する(UI表示用のため「1マシン1ファイル」制約は課さない)。
 */
export function listMachineProfiles(workspaceRoot: string, project: string): MachineProfileSummary[] {
  const machinesDir = path.join(workspaceRoot, "TestProjects", project, "profiles", "machines");
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
      const rawHost = (parsed as Record<string, unknown>).host;
      const host = typeof rawHost === "string" && rawHost.length > 0 ? rawHost : undefined;
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
        // **機械ごとにまとめる**(2026-08-17 指示): 手元が先 → ホスト名順、その中で名前順。
        // 同名が別ホストに並ぶのが通常なので、名前を第1キーにすると1台ずつ機械が入れ替わり、
        // 「この機械には何が居るか」が読めない。実効ホスト(デバイス指定 > 直下の既定)で比べる
        const hostKey = (device: MachineDeviceEntry): string => {
          const raw = (device.host ?? "").trim();
          if (raw === "local") {
            return "";
          }
          return raw !== "" ? raw : (host ?? "");
        };
        sectionDevices.sort((a, b) => {
          const [ha, hb] = [hostKey(a), hostKey(b)];
          if (ha !== hb) {
            return ha === "" ? -1 : hb === "" ? 1 : ha.localeCompare(hb);  // 手元が先
          }
          return a.name.localeCompare(b.name);
        });
        devices.push(...sectionDevices);
      }
      return { name, devices, ...(host !== undefined ? { host } : {}) };
    } catch {
      return { name, devices: [] };
    }
  });
}


export type ProjectResolution =
  | { kind: "resolved"; project: string }
  | { kind: "none" }
  | { kind: "ambiguous"; candidates: string[] };

/**
 * ftester.project が設定されていればそれを優先。空なら TestProjects/ 直下から自動判定
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
