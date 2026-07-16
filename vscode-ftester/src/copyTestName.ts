// copyTestName.ts
// ftester.copyTestName のキーボード起点(TestItem 引数無し)時に、アクティブエディタの
// カーソル位置から対象 TestItem を逆引きする純粋ロジック。vscode 非依存(理由は
// lastResults.ts 冒頭コメント参照)。

export interface TreeItemEntry {
  id: string;
  label: string;
  uriKey: string | undefined;
  startLine: number | undefined;
  /** folder=0 / class=1 / leaf=2(ツリー階層の深さ)。 */
  depth: number;
}

export interface CursorPosition {
  uriKey: string;
  line: number;
}

interface LocatedEntry extends TreeItemEntry {
  startLine: number;
}

function hasLine(entry: TreeItemEntry): entry is LocatedEntry {
  return entry.startLine !== undefined;
}

function pickDeepest(candidates: LocatedEntry[]): LocatedEntry {
  return candidates.reduce((best, cur) => (cur.depth > best.depth ? cur : best));
}

/**
 * 同一 uri 上で startLine === cursor.line の完全一致を最優先し、複数あれば depth が高い方を採る
 * (testTree.ts の range は宣言行の単一点なので「含む」ではなく行一致で判定する)。完全一致が
 * 無ければ startLine <= cursor.line の最大値(直前の宣言)にフォールバックし、同様に depth で
 * tie-break する。同一 uri に候補が無ければ undefined。
 */
export function resolveEntryAtCursor(
  entries: TreeItemEntry[],
  cursor: CursorPosition,
): TreeItemEntry | undefined {
  const sameUri = entries.filter((e) => e.uriKey === cursor.uriKey).filter(hasLine);
  if (sameUri.length === 0) {
    return undefined;
  }

  const exact = sameUri.filter((e) => e.startLine === cursor.line);
  if (exact.length > 0) {
    return pickDeepest(exact);
  }

  const before = sameUri.filter((e) => e.startLine <= cursor.line);
  if (before.length === 0) {
    return undefined;
  }
  const maxLine = Math.max(...before.map((e) => e.startLine));
  return pickDeepest(before.filter((e) => e.startLine === maxLine));
}

export function truncateForStatusBar(text: string, maxLen = 50): string {
  return text.length > maxLen ? `${text.slice(0, maxLen)}…` : text;
}
