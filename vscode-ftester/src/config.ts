// config.ts
// ftester.* 設定の読み取りとワークスペースルート/対象プロジェクトの解決。

import * as fs from "node:fs";
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

/** ftester.* 設定を読み取る。binaryPath は workspaceRoot 基準の絶対パスに解決する。 */
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
  };
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
 * Projects/<project>/profiles/runs/<profileName>.json の devices[].name をそのまま返す。
 * 読めない・JSON として解析できない・devices が無い/空の場合は null(listRunProfileNames と同じ
 * 「読めなければ空扱い」の流儀だが、こちらは「絞り込み対象なし(=null)」と「絞り込んでも空配列」を
 * 区別する必要がある呼び出し側(monitorPanel.ts の devicesToShutdownOnScopeChange)のために
 * null を返す)。
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
 * Projects/<project>/profiles/machines/ 直下の .json が**ちょうど1つ**のときに限り、そのファイルの
 * ios→android の順で devices[].name を返す(新規実行プロファイルのテンプレートに埋め込む
 * デバイス候補として使う。monitorPanel.ts の profileAdd ハンドラ)。
 * 実際にどのマシンプロファイルを使うか(登録名 / FT_MACHINE 環境変数による選択)を決めるロジックは
 * CLI 側(Sources/ftester)にしかなく、この拡張から複数マシンプロファイルのうちどれが「使われる」
 * ものかは判定できない。そのため、あいまいさが無い(ファイルが1つしか無い)場合に限って賢く
 * 埋める、という方針にする。0個・複数・読み取り/解析に失敗した場合は空配列(listRunProfileNames
 * と同じ「読めなければ空扱い」の流儀。呼び出し側は空配列を「候補なし、空文字1件で埋める」の
 * シグナルとして扱う)。
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
      for (const device of devices) {
        const name =
          typeof device === "object" && device !== null
            ? (device as Record<string, unknown>).name
            : undefined;
        if (typeof name === "string") {
          names.push(name);
        }
      }
    }
    return names;
  } catch {
    return [];
  }
}

export type ProjectResolution =
  | { kind: "resolved"; project: string }
  | { kind: "none" }
  | { kind: "ambiguous"; candidates: string[] };

/**
 * 対象テストプロジェクト名を解決する。
 * ftester.project が設定されていればそれを優先し、空の場合は Projects/ 直下から自動判定する
 * (1つだけなら採用、0または複数なら呼び出し側で誘導が必要)。
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
