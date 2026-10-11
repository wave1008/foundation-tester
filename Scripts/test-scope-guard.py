#!/usr/bin/env python3
# テストの実行範囲を、Bash で撃つ前に検査する PreToolUse フック(.claude/settings.json の Bash に登録)。
# ユーザー方針(2026-10-11): 全体テストは作業の区切りにユーザーの運用で回す。修正の各ステップは、変更が通るテストクラスだけ。
# 断るもの:
#   - `swift test` に --filter が無い(全体)/ --filter の語がテストクラスの正確な名前でない(部分一致の語で無関係なクラスを拾う)
#   - `swift build --build-tests`(swift test が同じビルドをやり直す = 二重払い。CLAUDE.md)
#   - 素の `npm test` / `npm run test`(全体)—— 1ファイルなら `node esbuild.mjs --tests && node --test out-test/<名前>.test.mjs`
#   - `Scripts/mutation-check.sh <json>` の各 filter がクラスの正確な名前でない / 同じ filter に向けた変異の数が、
#     その filter のテストファイルで新しく足したテスト関数の数を超える(新しいテストが無ければ 1 件まで)
# 通す: 全体の実行はコマンドに FT_FULL_TEST=1(ユーザーが全体テストを頼んだときだけ書く)。
# 使い方: Scripts/test-scope-guard.py --hook(stdin の JSON の tool_input.command を見る)/ --check '<command>'(手で試す)
import glob, json, os, re, shlex, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLASS = re.compile(r"^\s*(?:final\s+)?(?:public\s+)?class\s+(\w+)\s*:\s*([\w.]+)", re.M)
NEW_TEST = re.compile(r"^\+\s*(?:@MainActor\s+)?(?:func|public func)\s+test\w*\s*\(", re.M)


def test_classes():
    """{クラス名: ファイル}。XCTestCase の子孫(名前が …Tests / …TestCase の基底も含む)"""
    found = {}
    for path in glob.glob(os.path.join(ROOT, "Tests", "**", "*.swift"), recursive=True):
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for name, base in CLASS.findall(text):
            if base.endswith("XCTestCase") or base.endswith("TestCase") or name.endswith("Tests"):
                found[name] = os.path.relpath(path, ROOT)
    return found


def filter_problems(value, classes):
    """--filter の値の各語がクラスの正確な名前か。不正な語の一覧を返す"""
    bad = []
    for raw in value.split("|"):
        term = raw.strip().lstrip("^").rstrip("$")
        if not term:
            bad.append(raw)
            continue
        head = term.split("/", 1)[0]
        head = head.rsplit(".", 1)[-1]  # Module.Class
        if re.search(r"[^\w]", head) or head not in classes:
            bad.append(raw)
    return bad


def segments(command):
    """; && || | で区切った単純コマンドの語の並び(引用の中の | は区切らない)"""
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|")
    lexer.whitespace_split = True
    out, cur = [], []
    try:
        for tok in lexer:
            if tok and set(tok) <= set(";&|"):
                if cur:
                    out.append(cur)
                cur = []
            else:
                cur.append(tok)
    except ValueError:
        return None  # 引用が閉じていない = 判定しない
    if cur:
        out.append(cur)
    return out


def option_value(tokens, name):
    for i, tok in enumerate(tokens):
        if tok == name and i + 1 < len(tokens):
            return tokens[i + 1]
        if tok.startswith(name + "="):
            return tok[len(name) + 1:]
    return None


def new_tests_in(files):
    """未コミットの差分(追跡済み + 未追跡)で、その files に新しく足したテスト関数の数"""
    count = 0
    for f in files:
        full = os.path.join(ROOT, f)
        tracked = subprocess.run(["git", "-C", ROOT, "ls-files", "--error-unmatch", f],
                                 capture_output=True).returncode == 0
        if tracked:
            diff = subprocess.run(["git", "-C", ROOT, "diff", "HEAD", "-U0", "--", f],
                                  capture_output=True, text=True).stdout
        else:
            try:
                diff = "".join("+" + line for line in open(full, encoding="utf-8", errors="replace"))
            except OSError:
                diff = ""
        count += len(NEW_TEST.findall(diff))
    return count


def mutation_problems(json_path, classes):
    path = json_path if os.path.isabs(json_path) else os.path.join(os.getcwd(), json_path)
    try:
        mutations = json.load(open(path, encoding="utf-8"))
    except (OSError, ValueError):
        return []  # 読めなければ判定しない(スクリプト自身が落とす)
    problems, groups = [], {}
    for m in mutations:
        value = m.get("filter", "")
        bad = filter_problems(value, classes)
        if bad:
            problems.append(f"変異「{m.get('label')}」の filter に、テストクラスの正確な名前でない語がある: {bad}")
            continue
        key = frozenset(t.strip().lstrip("^").rstrip("$").split("/", 1)[0].rsplit(".", 1)[-1]
                        for t in value.split("|"))
        groups.setdefault(key, []).append(m.get("label"))
    for key, labels in groups.items():
        files = sorted({classes[c] for c in key})
        allowed = max(new_tests_in(files), 1)
        if len(labels) > allowed:
            problems.append(
                f"filter {'|'.join(sorted(key))} に向けた変異が {len(labels)} 件ある({labels})が、そのテストファイルで"
                f"新しく足したテスト関数は {allowed if allowed > 1 else '0〜1'} 本。変異は新しいテスト1本につき1件"
                "(新しいテストが無ければ1件)")
    return problems


def check(command):
    """断る理由の一覧(空 = 通す)"""
    segs = segments(command)
    if segs is None:
        return []
    full_ok = "FT_FULL_TEST=1" in command
    classes = None
    reasons = []
    for tokens in segs:
        words = [t for t in tokens if not re.match(r"^\w+=", t)]  # 先頭の VAR=value を飛ばす
        if len(words) >= 2 and os.path.basename(words[0]) == "swift" and words[1] == "test":
            if "--help" in words or "-h" in words:
                continue
            value = option_value(words, "--filter")
            if value is None:
                if not full_ok:
                    reasons.append("swift test に --filter が無い(全体)。全体テストは作業の区切りにユーザーが回す運用 ——"
                                   "変更が通るテストクラスを --filter '<Class>|<Class>' で名指しする"
                                   "(ユーザーが全体テストを頼んだときだけ FT_FULL_TEST=1 を書く)")
            else:
                classes = classes if classes is not None else test_classes()
                bad = filter_problems(value, classes)
                if bad:
                    reasons.append(f"--filter の語がテストクラスの正確な名前でない: {bad}。部分一致の語は無関係なクラスまで拾う"
                                   "—— クラス名(または Class/testMethod)を正確に書く")
        if len(words) >= 2 and os.path.basename(words[0]) == "swift" and words[1] == "build" \
                and "--build-tests" in words:
            reasons.append("swift build --build-tests は打たない(swift test が同じビルドをやり直す = 二重払い。CLAUDE.md)")
        if len(words) >= 2 and words[0] == "npm" and (words[1] == "test" or words[1:3] == ["run", "test"]) \
                and not full_ok:
            reasons.append("npm test は全体(2000 件超)。1ファイルなら vscode-fleetest で"
                           " `node esbuild.mjs --tests && node --test out-test/<名前>.test.mjs`"
                           "(ユーザーが全体テストを頼んだときだけ FT_FULL_TEST=1 を書く)")
        for i, tok in enumerate(words):
            if os.path.basename(tok) == "mutation-check.sh" and i + 1 < len(words) and words[i + 1] != "--purge":
                classes = classes if classes is not None else test_classes()
                reasons.extend(mutation_problems(words[i + 1], classes))
    return reasons


if __name__ == "__main__":
    if sys.argv[1:2] == ["--check"]:
        print("\n".join(check(" ".join(sys.argv[2:]))) or "ok")
        sys.exit(0)
    if sys.argv[1:] != ["--hook"]:
        print(__doc__ or "usage: test-scope-guard.py --hook | --check '<command>'")
        sys.exit(0)
    data = json.load(sys.stdin)
    reasons = check((data.get("tool_input") or {}).get("command", ""))
    if reasons:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": "テストの範囲が広い(Scripts/test-scope-guard.py): " + " / ".join(reasons)}},
            ensure_ascii=False))
    sys.exit(0)
