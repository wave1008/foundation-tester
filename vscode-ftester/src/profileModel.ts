// profileModel.ts
// `ftester api validate-profile`(Sources/ftester/ApiValidateProfileCommand.swift)の出力を、
// 拡張の DiagnosticCollection や QuickPick が扱いやすい形へ変換する純粋関数群。
// vscode モジュールに一切依存しない(profileDiagnostics.ts からも test/profileModel.test.mjs
// からも同じロジックを使えるようにするため。monitorModel.ts/healModel.ts と同じ方針)。
//
// 契約(`ftester api validate-profile --project <p> [--kind apps|machines|runs] [--name <n>]` の
// stdout 1行JSON):
//   {"machine":"M1 Max"|null,"project":"SampleApp","results":[
//     {"kind":"apps"|"machines"|"runs","name":"sampleapp","path":"/絶対/パス.json",
//      "errors":["..."],"warnings":["..."]}, ...
//   ]}
// 検証エラーがあっても exit 0(errors が空でない = そのファイルに検証エラーがある、の意味)。
// machine は現在マシンが未登録(ftester machine set 未実行等)の場合 null。

/** ProfileFileKind.directoryName(Sources/FTCore/RunProfile.swift)と同じ語彙。 */
export type ProfileKind = "apps" | "machines" | "runs";

const PROFILE_KINDS: ReadonlySet<string> = new Set<ProfileKind>(["apps", "machines", "runs"]);

/** `ftester api validate-profile` の results[] の1要素。 */
export interface ValidateProfileResult {
  readonly kind: ProfileKind;
  readonly name: string;
  /** 絶対パス。 */
  readonly path: string;
  readonly errors: readonly string[];
  readonly warnings: readonly string[];
}

/** `ftester api validate-profile` の出力全体。 */
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

/**
 * value が ValidateProfileOutput として扱ってよいか判定する。契約からのずれ(フィールド欠落・
 * 型不一致・未知の kind 等)があれば false を返すので、呼び出し側は安全に無視できる。
 */
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

/** DiagnosticCollection へ渡す1ファイル分の内容(errors→Error, warnings→Warning に対応させる)。 */
export interface ProfileDiagnostics {
  readonly errors: readonly string[];
  readonly warnings: readonly string[];
}

/**
 * ValidateProfileOutput.results を、絶対パス(results[].path)をキーにした Map に変換する。
 * 同じパスが複数回現れることは契約上想定していないが、その場合は後の要素で上書きする。
 */
export function toDiagnosticsByPath(output: ValidateProfileOutput): Map<string, ProfileDiagnostics> {
  const map = new Map<string, ProfileDiagnostics>();
  for (const result of output.results) {
    map.set(result.path, { errors: [...result.errors], warnings: [...result.warnings] });
  }
  return map;
}

/** parseProfileFilePath() が返す、パスから抽出した種別情報。 */
export interface ProfileFileLocation {
  readonly project: string;
  readonly kind: ProfileKind;
  readonly name: string;
}

function normalizePath(value: string): string {
  return value.replace(/\\/g, "/").replace(/\/+$/, "");
}

/**
 * ファイルパスが `Projects/<project>/profiles/{apps,machines,runs}/<name>.json` の形に
 * 一致する場合だけ project/kind/name を抽出する(`ftester api validate-profile`
 * `--project --kind --name` 絞り込み呼び出しの引数を組み立てるため)。
 *
 * filePath は workspaceRoot 配下の絶対パス、または既にワークスペースルート相対のパスの
 * どちらでも受け付ける(先頭一致すれば workspaceRoot を取り除いてから判定する)。
 * パターンに一致しない(profiles/ 配下以外・種別ディレクトリ違い・拡張子違い等)場合は undefined。
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
