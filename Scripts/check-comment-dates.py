#!/usr/bin/env python3
# コメントに日付(20xx-xx-xx)を書かない規則の速い検査。判定は Tests/FTCoreTests/CommentDateScanTests.swift と同じ
# (コメント部分の切り出し・走査の対象・許可リスト)。許可リストはそのテストのファイルから読む = 正は1つ。
# swift test を待たずに、書いた直後に当てるためのもの(フィックスの往復でフルテストをやり直さない)。
#
# 使い方:
#   Scripts/check-comment-dates.py                 # 対象の全ファイル
#   Scripts/check-comment-dates.py <file>...       # 指定したファイルだけ(対象外のパスは黙って飛ばす)
#   Scripts/check-comment-dates.py --hook          # PostToolUse フック: stdin の JSON の tool_input.file_path だけを見る
#   (stdin は --hook のときだけ読む —— 閉じない stdin(Bash ツール等)で引数なしに呼ぶと読み待ちで止まるため)
# 終了コード: 0 = 違反なし / 2 = 違反あり(stderr に一覧。フックでは exit 2 が書き手へ返る)
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOTS = {"Sources": {"swift", "m", "h"}, "vscode-fleetest/src": {"ts", "js", "mjs", "css"}}
SKIPPED_DIRS = {"Generated", "node_modules", ".build"}
DATE = re.compile(r"20[0-9]{2}-[0-9]{2}-[0-9]{2}")
TEST_FILE = os.path.join(ROOT, "Tests/FTCoreTests/CommentDateScanTests.swift")


def allowlist():
    text = open(TEST_FILE, encoding="utf-8").read()
    return set(re.findall(r'\("([^"]+)",\s*"(20[0-9]{2}-[0-9]{2}-[0-9]{2})",\s*"[^"]*"\)', text))


def in_scope(rel):
    parts = rel.split(os.sep)
    if any(p in SKIPPED_DIRS for p in parts):
        return False
    ext = rel.rsplit(".", 1)[-1] if "." in rel else ""
    return any(rel.startswith(r + os.sep) and ext in exts for r, exts in ROOTS.items())


def comment_segments(text):
    """CommentDateScanTests.commentSegments の写し(行単位・手前の `"` が奇数なら文字列内として飛ばす)"""
    segments, block_end = [], None
    for index, line in enumerate(text.split("\n")):
        collected = ""
        while line:
            if block_end is not None:
                i = line.find(block_end)
                if i >= 0:
                    collected += line[:i]
                    line = line[i + len(block_end):]
                    block_end = None
                else:
                    collected += line
                    line = ""
                continue
            best = None
            for opener, closer in (("//", None), ("/*", "*/"), ("<!--", "-->")):
                start = 0
                while True:
                    i = line.find(opener, start)
                    if i < 0:
                        break
                    if line[:i].count('"') % 2 == 0:
                        if best is None or i < best[0]:
                            best = (i, opener, closer)
                        break
                    start = i + len(opener)
            if best is None:
                break
            i, opener, closer = best
            if closer:
                block_end = closer
                line = line[i + len(opener):]
            else:
                collected += line[i + len(opener):]
                line = ""
        if collected:
            segments.append((index + 1, collected))
    return segments


def scan(rel, allowed):
    try:
        text = open(os.path.join(ROOT, rel), encoding="utf-8").read()
    except (OSError, UnicodeDecodeError):
        return []
    hits = []
    for line_no, comment in comment_segments(text):
        for m in DATE.finditer(comment):
            if (rel, m.group(0)) not in allowed:
                hits.append(f"{rel}:{line_no}  {comment.strip()}")
    return hits


def targets_from_args_or_stdin():
    if sys.argv[1:] == ["--hook"]:
        raw = sys.stdin.read()
        if raw.strip():
            try:
                path = json.loads(raw).get("tool_input", {}).get("file_path")
                return [path] if path else []
            except json.JSONDecodeError:
                return []
        return []
    if len(sys.argv) > 1:
        return sys.argv[1:]
    return None  # 全数


def main():
    allowed = allowlist()
    targets = targets_from_args_or_stdin()
    if targets is None:
        rels = []
        for r in ROOTS:
            for d, dirs, files in os.walk(os.path.join(ROOT, r)):
                dirs[:] = [x for x in dirs if x not in SKIPPED_DIRS]
                rels += [os.path.relpath(os.path.join(d, f), ROOT) for f in files]
    else:
        rels = [os.path.relpath(os.path.abspath(p), ROOT) for p in targets]
    hits = [h for rel in rels if in_scope(rel) for h in scan(rel, allowed)]
    if hits:
        print("コメントに日付を書かない(CLAUDE.md §コメント規約)。事実は残して日付だけ消す:"
              " `(2026-07-25 実測)` → `(実測)`。日付が契約・名前の一部なら"
              " CommentDateScanTests の allowlist に理由付きで足す。", file=sys.stderr)
        print("\n".join(hits), file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
