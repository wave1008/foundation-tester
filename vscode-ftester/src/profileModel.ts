// profileModel.ts
// `ftester api validate-profile`(Sources/ftester/ApiValidateProfileCommand.swift)の出力を、
// DiagnosticCollection や QuickPick 向けに変換する純粋関数群。vscode モジュールに依存しない
// (profileDiagnostics.ts と test/profileModel.test.mjs の両方から使うため)。
//
// stdout 1行JSON contract:
//   {"machine":"M1 Max"|null,"project":"SampleApp","results":[
//     {"kind":"apps"|"machines"|"runs","name":"sampleapp","path":"/絶対/パス.json",
//      "errors":["..."],"warnings":["..."]}, ...
//   ]}
// 検証エラーがあっても exit 0(errors 非空 = そのファイルにエラーあり、の意味)。

/** ProfileFileKind.directoryName(Sources/FTCore/RunProfile.swift)と同じ語彙。 */
export type ProfileKind = "apps" | "machines" | "runs";

const PROFILE_KINDS: ReadonlySet<string> = new Set<ProfileKind>(["apps", "machines", "runs"]);

export interface ValidateProfileResult {
  readonly kind: ProfileKind;
  readonly name: string;
  /** 絶対パス。 */
  readonly path: string;
  readonly errors: readonly string[];
  readonly warnings: readonly string[];
}

export interface ValidateProfileOutput {
  readonly project: string;
  /** 現在マシンが未登録の場合は null。 */
  readonly machine: string | null;
  readonly results: readonly ValidateProfileResult[];
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((item) => typeof item === "string");
}

function isValidateProfileResult(value: unknown): value is ValidateProfileResult {
  if (!isRecord(value)) {
    return false;
  }
  return (
    typeof value.kind === "string" &&
    PROFILE_KINDS.has(value.kind) &&
    typeof value.name === "string" &&
    typeof value.path === "string" &&
    isStringArray(value.errors) &&
    isStringArray(value.warnings)
  );
}

export function isValidateProfileOutput(value: unknown): value is ValidateProfileOutput {
  if (!isRecord(value)) {
    return false;
  }
  return (
    typeof value.project === "string" &&
    (value.machine === null || typeof value.machine === "string") &&
    Array.isArray(value.results) &&
    value.results.every(isValidateProfileResult)
  );
}

/** DiagnosticCollection 用(errors→Error, warnings→Warning に対応)。 */
export interface ProfileDiagnostics {
  readonly errors: readonly string[];
  readonly warnings: readonly string[];
}

/** 同じパスが複数回現れることは契約上想定していないが、その場合は後の要素で上書きする。 */
export function toDiagnosticsByPath(output: ValidateProfileOutput): Map<string, ProfileDiagnostics> {
  const map = new Map<string, ProfileDiagnostics>();
  for (const result of output.results) {
    map.set(result.path, { errors: [...result.errors], warnings: [...result.warnings] });
  }
  return map;
}

export interface ProfileFileLocation {
  readonly project: string;
  readonly kind: ProfileKind;
  readonly name: string;
}

function normalizePath(value: string): string {
  return value.replace(/\\/g, "/").replace(/\/+$/, "");
}

/**
 * `Projects/<project>/profiles/{apps,machines,runs}/<name>.json` の形に一致する場合だけ
 * project/kind/name を抽出する(--project/--kind/--name 絞り込み呼び出しの引数を組み立てるため)。
 * filePath は workspaceRoot 配下の絶対パス・相対パスのどちらでも受け付ける。
 */
export function parseProfileFilePath(
  workspaceRoot: string,
  filePath: string,
): ProfileFileLocation | undefined {
  const root = normalizePath(workspaceRoot);
  const target = normalizePath(filePath);
  const relative = target === root || target.startsWith(`${root}/`) ? target.slice(root.length + 1) : target;

  const segments = relative.split("/").filter((segment) => segment.length > 0);
  // ["Projects", "<project>", "profiles", "<kindディレクトリ>", "<name>.json"] の5要素のみ許容する。
  if (segments.length !== 5) {
    return undefined;
  }
  const [projectsDir, project, profilesDir, kindDir, fileName] = segments;
  if (
    projectsDir !== "Projects" ||
    profilesDir !== "profiles" ||
    project === undefined ||
    project.length === 0 ||
    kindDir === undefined ||
    !PROFILE_KINDS.has(kindDir) ||
    fileName === undefined ||
    !fileName.endsWith(".json")
  ) {
    return undefined;
  }
  const name = fileName.slice(0, -".json".length);
  if (name.length === 0) {
    return undefined;
  }
  return { project, kind: kindDir as ProfileKind, name };
}
