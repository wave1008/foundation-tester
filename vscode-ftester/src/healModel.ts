// healModel.ts
// vscode 非依存。以下の対応関係を維持すること:
// - HealFixCollector: healReviewPanel.ts が「実行終了時に1件以上あればパネルを開く」判定に使う。
// - selectorOccursOnce/isValidSelector/isValidComment/trailingComment/computeNewComment/
//   buildPreviewAfterLine: healReviewPanel.ts の webview は CSP で本モジュールを import できず
//   同じロジックを手書き複製している。GUI 版 HealReviewSheet.swift /
//   Sources/FTCore/ScenarioSourceComments.swift / ScenarioSourceEditor.swift の
//   isValidSelector/isValidComment/trailingCommentStart/setTrailingComment と同じ規則。
// - buildApplyHealRequest/parseApplyHealResponse/toApplyHealFix: `ftester api apply-heal`
//   (stdin/stdout の JSON 契約。Sources/ftester/ApiApplyHealCommand.swift 参照)の変換。

import type { FixSuggestionEvent, RunEvent } from "./model";

/** 1件の自己修復候補(RunEventBus の fixSuggestion イベントから収集したもの)。 */
export interface HealFix {
  readonly scenarioID: string;
  /** リポジトリルート相対パス(イベントのまま。絶対パスの場合もある)。 */
  readonly file: string;
  readonly line: number;
  readonly oldSelector: string;
  readonly newSelector: string;
  /** 提案文(detail が無ければ description。どちらも無ければ空文字列)。 */
  readonly message: string;
  /** 対象コマンドの description(例: tap "旧セレクタ")。id には含めない。 */
  readonly command: string | undefined;
}

/** HealFix.id と同形式(GUI の AppModel.HealFix.id / apply-heal の応答 id と一致させる)。 */
export function healFixId(fix: Pick<HealFix, "scenarioID" | "file" | "line" | "oldSelector">): string {
  return `${fix.scenarioID}|${fix.file}:${String(fix.line)}|${fix.oldSelector}`;
}

function fixFromFixSuggestion(event: FixSuggestionEvent): HealFix | undefined {
  if (
    typeof event.scenario !== "string" ||
    event.scenario.length === 0 ||
    typeof event.file !== "string" ||
    event.file.length === 0 ||
    typeof event.line !== "number" ||
    typeof event.oldSelector !== "string" ||
    event.oldSelector.length === 0 ||
    typeof event.newSelector !== "string" ||
    event.newSelector.length === 0
  ) {
    return undefined;
  }
  return {
    scenarioID: event.scenario,
    file: event.file,
    line: event.line,
    oldSelector: event.oldSelector,
    newSelector: event.newSelector,
    message: event.detail ?? event.description ?? "",
    command: event.description,
  };
}

/**
 * fixSuggestion イベントを収集する状態クラス。begin(isDryRun) で実行開始ごとにクリアし、
 * isDryRun なら以降 collect() は無視する。collect() は id(healFixId)で重複排除(後勝ち)。
 */
export class HealFixCollector {
  private readonly collected = new Map<string, HealFix>();
  private dryRun = false;

  begin(isDryRun: boolean): void {
    this.collected.clear();
    this.dryRun = isDryRun;
  }

  collect(event: RunEvent): void {
    if (this.dryRun || event.kind !== "fixSuggestion") {
      return;
    }
    const fix = fixFromFixSuggestion(event);
    if (!fix) {
      return;
    }
    this.collected.set(healFixId(fix), fix);
  }

  list(): HealFix[] {
    return [...this.collected.values()];
  }

  isEmpty(): boolean {
    return this.collected.size === 0;
  }
}

// ---- セレクタ・コメントの検証(GUI の HealReviewSheet.isValidSelector/isValidComment と同じ規則)----

/** セレクタ編集値の検証: 空・「"」・改行はソースのクォート付き文字列を壊すため不可。 */
export function isValidSelector(selector: string): boolean {
  return selector.length > 0 && !selector.includes('"') && !selector.includes("\n") && !selector.includes("\r");
}

/** 説明編集値の検証: 改行のみ不可(空はコメント削除の意思として許可)。 */
export function isValidComment(comment: string): boolean {
  return !comment.includes("\n") && !comment.includes("\r");
}

/** line 内に `"oldSelector"`(クォート付き)がちょうど1回出現するか。0回・2回以上は false。 */
export function selectorOccursOnce(line: string, oldSelector: string): boolean {
  return countOccurrences(line, `"${oldSelector}"`) === 1;
}

function countOccurrences(haystack: string, needle: string): number {
  if (needle.length === 0) {
    return 0;
  }
  let count = 0;
  let index = 0;
  for (;;) {
    const found = haystack.indexOf(needle, index);
    if (found === -1) {
      return count;
    }
    count += 1;
    index = found + needle.length;
  }
}

// ---- 行末コメント(// ...)の抽出・書換(ScenarioSourceComments/ScenarioSourceEditor の TS 移植)----

/**
 * 行末コメントの「//」の開始位置(文字列リテラル内の // は無視)。無ければ undefined。
 * Sources/FTCore/ScenarioSourceComments.swift の trailingCommentStart と同じ状態機械。
 */
export function trailingCommentIndex(line: string): number | undefined {
  let inString = false;
  let escaped = false;
  let previousSlashIndex: number | undefined;
  for (let i = 0; i < line.length; i += 1) {
    const ch = line[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch === "\\") {
        escaped = true;
      } else if (ch === '"') {
        inString = false;
      }
      previousSlashIndex = undefined;
    } else if (ch === '"') {
      inString = true;
      previousSlashIndex = undefined;
    } else if (ch === "/") {
      if (previousSlashIndex !== undefined) {
        return previousSlashIndex;
      }
      previousSlashIndex = i;
    } else {
      previousSlashIndex = undefined;
    }
  }
  return undefined;
}

/** 1行から行末コメントの本文を取り出す(前後空白除去。コメントが無い・空なら undefined)。 */
export function trailingComment(line: string): string | undefined {
  const start = trailingCommentIndex(line);
  if (start === undefined) {
    return undefined;
  }
  const body = line.slice(start + 2).trim();
  return body.length === 0 ? undefined : body;
}

/**
 * 行末コメントを書き換える(ScenarioSourceEditor.setTrailingComment の TS 移植。プレビュー専用)。
 * newComment が空ならコメントを削除(前の空白ごと)、既存コメントが無ければ行末に追記、
 * 既存コメントがあれば「//」直後の空白を保ったまま本文だけ差し替える。
 */
export function setTrailingCommentPreview(line: string, newComment: string): string {
  const start = trailingCommentIndex(line);
  if (start === undefined) {
    if (newComment.length === 0) {
      return line;
    }
    let end = line.length;
    while (end > 0 && (line[end - 1] === " " || line[end - 1] === "\t")) {
      end -= 1;
    }
    return `${line.slice(0, end)}  // ${newComment}`;
  }
  if (newComment.length === 0) {
    let end = start;
    while (end > 0 && (line[end - 1] === " " || line[end - 1] === "\t")) {
      end -= 1;
    }
    return line.slice(0, end);
  }
  let textStart = start + 2;
  while (textStart < line.length && (line[textStart] === " " || line[textStart] === "\t")) {
    textStart += 1;
  }
  return line.slice(0, textStart) + newComment;
}

/**
 * 変更前セレクタ→変更後セレクタ・変更前コメント→編集中コメントを反映した「変更後」行を組み立てる
 * (diffプレビュー用。webview 側は同じロジックを手書きで複製して毎キー入力ごとに呼ぶ)。
 */
export function buildPreviewAfterLine(
  originalLine: string,
  oldSelector: string,
  newSelector: string,
  originalComment: string | undefined,
  editedComment: string,
): string {
  const quotedOld = `"${oldSelector}"`;
  const quotedNew = `"${newSelector}"`;
  let replaced = originalLine.split(quotedOld).join(quotedNew);
  if (isValidComment(editedComment)) {
    const trimmed = editedComment.trim();
    if (trimmed !== (originalComment ?? "")) {
      replaced = setTrailingCommentPreview(replaced, trimmed);
    }
  }
  return replaced;
}

/**
 * 説明編集値から newComment を決める。プリフィル(originalComment ?? "")と同じなら null
 * (変更なし)、異なればトリム後の値を返す(意味は HealApplyFix.newComment 参照)。
 */
export function computeNewComment(originalComment: string | undefined, editedComment: string): string | null {
  const trimmed = editedComment.trim();
  return trimmed === (originalComment ?? "") ? null : trimmed;
}

// ---- `ftester api apply-heal` の入出力契約 ----------------------------------------------

/** apply-heal の stdin JSON に含める1件分。 */
export interface HealApplyFix {
  readonly scenarioID: string;
  readonly file: string;
  readonly line: number;
  readonly oldSelector: string;
  readonly newSelector: string;
  /** null = コメントを変更しない、空文字列 = コメント削除、非空 = 差し替え。 */
  readonly newComment: string | null;
}

export interface ApplyHealRequest {
  readonly fixes: readonly HealApplyFix[];
}

/** apply-heal の stdin へ書き込む JSON オブジェクトを組み立てる(そのまま JSON.stringify する)。 */
export function buildApplyHealRequest(fixes: readonly HealApplyFix[]): ApplyHealRequest {
  return { fixes: fixes.map((fix) => ({ ...fix })) };
}

export interface ApplyHealFailure {
  readonly id: string;
  readonly message: string;
}

export interface ApplyHealResponse {
  readonly applied: readonly string[];
  readonly failures: readonly ApplyHealFailure[];
}

/** apply-heal の stdout(1行JSON を JSON.parse した値)を検証しつつ変換する。不正なら undefined。 */
export function parseApplyHealResponse(value: unknown): ApplyHealResponse | undefined {
  if (typeof value !== "object" || value === null) {
    return undefined;
  }
  const applied = (value as { applied?: unknown }).applied;
  const failures = (value as { failures?: unknown }).failures;
  if (!Array.isArray(applied) || !applied.every((id) => typeof id === "string")) {
    return undefined;
  }
  if (!Array.isArray(failures)) {
    return undefined;
  }
  const parsedFailures: ApplyHealFailure[] = [];
  for (const failure of failures) {
    if (typeof failure !== "object" || failure === null) {
      return undefined;
    }
    const id = (failure as { id?: unknown }).id;
    const message = (failure as { message?: unknown }).message;
    if (typeof id !== "string" || typeof message !== "string") {
      return undefined;
    }
    parsedFailures.push({ id, message });
  }
  return { applied: applied as string[], failures: parsedFailures };
}

/**
 * チェック済み1件を適用リクエストの1件に変換する(GUI の HealReviewSheet.checkedFixes 相当)。
 * セレクタ・コメント不正なら undefined(UI 側の検証が壊れていても不正リクエストを組み立てない防御)。
 */
export function toApplyHealFix(
  fix: Pick<HealFix, "scenarioID" | "file" | "line" | "oldSelector">,
  editedSelector: string,
  editedComment: string,
  originalComment: string | undefined,
): HealApplyFix | undefined {
  if (!isValidSelector(editedSelector) || !isValidComment(editedComment)) {
    return undefined;
  }
  return {
    scenarioID: fix.scenarioID,
    file: fix.file,
    line: fix.line,
    oldSelector: fix.oldSelector,
    newSelector: editedSelector,
    newComment: computeNewComment(originalComment, editedComment),
  };
}
