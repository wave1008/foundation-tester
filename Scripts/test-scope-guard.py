#!/usr/bin/env python3
# テストの実行範囲を、Bash で撃つ前に検査する PreToolUse フック(.claude/settings.json の Bash に登録)。
# ユーザー方針(2026-10-11): 全体テストは作業の区切りにユーザーの運用で回す。修正の各ステップは、変更が通るテストクラスだけ。
# 断るもの:
#   - `swift test` に --filter が無い(全体)/ --filter の語がテストクラスの正確な名前でない(部分一致の語で無関係なクラスを拾う)
#   - `swift build --build-tests`(swift test が同じビルドをやり直す = 二重払い。CLAUDE.md)
#   - 素の `npm test` / `npm run test`(全体)—— 1ファイルなら `node esbuild.mjs --tests && node --test out-test/<名前>.test.mjs`
#   - `Scripts/mutation-check.sh <json>` の各 filter がクラスの正確な名前でない / 同じ filter に向けた変異の数が、
#     その filter のテストファイルで新しく足したテスト関数の数を超える(新しいテストが無ければ 1 件まで)
#   - デバイス実行(E2E)の全体(ユーザー方針 2026-10-13「全実施を指示されたとき以外は範囲を絞る」):
#     `fleetest run` / `fleetest api run` に --scenario / --folder / --failed のどれも無い(--dry-run・--help は通す)/
#     `Scripts/e2e.sh` `e2ex.sh` `e2ey.sh`(シナリオを絞る引数を持たない = 常に全体)/ `--scenario` の無い `e2e-devices.sh` /
#     `Scripts/e2e-negative.sh` に --project が無い
#   - **起動するスクリプトファイルの中身も同じ規則で見る**(`bash <file>`・`bash -c "<file> …"`・`nohup <file>`・実行権限の直接起動。
#     同じコマンドの中で heredoc に書いたスクリプトも本文を見る)。中身を見ないと、実行をファイルに書いて起こすだけで素通りする
#     (2026-10-13 に3回)。パスの `$VAR` は同じコマンドの `VAR=…` だけで展開し、展開できない `.sh` は断る。
#     `"$@"` で fleetest run を包む関数は、その関数を呼ぶ行を絞り込みの有無で見る
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
    # **読めなければ断る**(通さない)。フックはシェルを通る前の文字列を見るので、`$S/mut.json` のような変数のパスは
    # 開けない —— 「読めなければ判定しない」にしていた間、変数で書いた変異テストは1度も検査されなかった(2026-10-11)
    if "$" in json_path:
        return [f"変異の JSON のパスにシェル変数がある({json_path})。フックは展開前の文字列しか見られないので、絶対パスで直接書く"]
    path = json_path if os.path.isabs(json_path) else os.path.join(os.getcwd(), json_path)
    try:
        mutations = json.load(open(path, encoding="utf-8"))
    except (OSError, ValueError) as error:
        return [f"変異の JSON を読めない({json_path}: {error})。範囲を検査できないので撃たない"]
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


NARROWING = ("--scenario", "--folder", "--failed")
FULL_SUITE_SCRIPTS = ("e2e.sh", "e2ex.sh", "e2ey.sh", "e2e-devices.sh")
SHELLS = ("bash", "sh", "zsh")
MAX_DEPTH = 3


def has_flag(words, names):
    return any(w == n or w.startswith(n + "=") for w in words for n in names)


def expand(text, env):
    """`$VAR` / `${VAR}` を env(同じコマンドの代入)→ フックの環境変数の順で展開する。知らない名前はそのまま残す"""
    return re.sub(r"\$\{?(\w+)\}?",
                  lambda m: env.get(m.group(1), os.environ.get(m.group(1), m.group(0))), text)


def assignments(text):
    """`NAME=value` の代入(行頭・; && の後)。値は引用を外す"""
    env = {}
    for m in re.finditer(r"(?:^|[;&|\s])(\w+)=(\"[^\"]*\"|'[^']*'|[^\s;&|]+)", text, re.M):
        value = m.group(2).strip("\"'")
        if "$(" in value or "`" in value:
            env.pop(m.group(1), None)  # コマンド置換は展開できない = 知らない名前として扱う
            continue
        env[m.group(1)] = value
    return env


def logical_lines(text):
    """行末の \\ を繋いだ論理行"""
    out, cur = [], ""
    for line in text.splitlines():
        if line.rstrip().endswith("\\"):
            cur += line.rstrip()[:-1] + " "
            continue
        out.append(cur + line)
        cur = ""
    if cur:
        out.append(cur)
    return out


HEREDOC = re.compile(r"^([^\n]*?)<<-?\s*['\"]?(\w+)['\"]?([^\n]*)\n(.*?)\n\2\s*$", re.S | re.M)


def strip_heredocs(command):
    """heredoc の本文を外したコマンド(本文は別のスクリプト = 外側の変数や区切りに混ぜない)"""
    return HEREDOC.sub(lambda m: m.group(1) + m.group(3), command)


def heredoc_scripts(command):
    """heredoc でシェルスクリプトとして書かれた本文(`cat > x.sh <<EOF` / `bash <<EOF`)"""
    out = []
    for m in HEREDOC.finditer(command):
        head = m.group(1)
        if re.search(r"\.sh\b", head) or re.search(r"(^|[\s;&|])(bash|sh|zsh)\s*$", head.rstrip()):
            out.append(m.group(4))
    return out


def script_text_problems(text, env, full_ok, depth):
    """スクリプトの本文を論理行ごとに見る。`"$@"` で fleetest run を包む関数は呼び出し行で見る"""
    env = {**env, **assignments(text)}
    reasons = []
    wrappers = set()
    lines = logical_lines(text)
    for i, line in enumerate(lines):
        if re.search(r"fleetest\"?\s+(api\s+)?run\b", expand(line, env)) and re.search(r"\$[@*]", line) \
                and not has_flag(line.split(), NARROWING + ("--dry-run",)):  # 本体で絞っていれば呼び出し行は見ない
            for back in reversed(lines[:i + 1]):
                m = re.match(r"\s*(?:function\s+)?(\w+)\s*\(\)", back)
                if m:
                    wrappers.add(m.group(1))
                    break
    for line in lines:
        reasons.extend(check(line, env, full_ok, depth))
        words = line.split()
        if words and words[0] in wrappers and not has_flag(words, NARROWING + ("--dry-run", "--help")) and not full_ok:
            reasons.append(f"fleetest run を包む関数 {words[0]} の呼び出しに --scenario / --folder / --failed が無い: {line.strip()[:120]}")
    return reasons


def file_problems(path_word, env, full_ok, depth):
    """起動するファイルの中身を見る。リポジトリの Scripts/ は名前の規則で見るので中身は読まない"""
    path = expand(path_word, env)
    if "$" in path:
        # 断るのは利用者が打った一番外のコマンドだけ。スクリプトの中の `$(dirname "$0")` / `$1` は補助スクリプトの普通の書き方
        if depth == 0 and re.fullmatch(r"\S+\.sh", path):
            return [f"起動するスクリプトのパスに展開できない変数がある({path_word})。フックは中身を検査できないので、"
                    "同じコマンドで代入するか絶対パスで書く"]
        return []
    full = path if os.path.isabs(path) else os.path.join(os.getcwd(), path)
    if not os.path.isfile(full) or os.path.commonpath([os.path.realpath(full), os.path.join(ROOT, "Scripts")]) == \
            os.path.join(ROOT, "Scripts"):
        return []
    try:
        if os.path.getsize(full) > 512 * 1024:
            return []
        text = open(full, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError):
        return []
    return script_text_problems(text, env, full_ok, depth + 1)


def device_run_problems(words, env, full_ok, depth):
    """E2E の全体と、起動するスクリプトの中身"""
    reasons = []
    words = [expand(w, env) for w in words]
    while words and (words[0] == "nohup" or re.match(r"^\w+=", words[0])):
        words = words[1:]
    if not words:
        return reasons
    head = os.path.basename(words[0])
    # `$@` / `$*` で引数を受け渡すだけの行は判定しない(包む関数の呼び出し行で見る = script_text_problems)
    passes_args = any(w in ("$@", "$*") for w in words)
    if not full_ok and not passes_args and not has_flag(words, ("--help", "-h")):
        if head == "fleetest":
            rest = words[1:]
            if rest[:1] == ["api"]:
                rest = rest[1:]
            if rest[:1] == ["run"] and not has_flag(rest, NARROWING + ("--dry-run",)):
                reasons.append("fleetest run に --scenario / --folder / --failed が無い(プロジェクトの全シナリオ)。"
                               "全実施を指示されたとき以外は、変更が通るシナリオを --scenario で名指しする"
                               "(全実施を頼まれたときだけ FT_FULL_TEST=1 を書く)")
        if head == "e2e-devices.sh" and not has_flag(words, ("--scenario",)):
            reasons.append("e2e-devices.sh に --scenario が無い(実機の全シナリオ)。全実施を指示されたとき以外は"
                           " --scenario で絞る(全実施を頼まれたときだけ FT_FULL_TEST=1 を書く)")
        elif head in FULL_SUITE_SCRIPTS and head != "e2e-devices.sh":
            reasons.append(f"{head} はシナリオを絞る引数を持たない(常にスイート全体)。全実施を指示されたとき以外は"
                           " fleetest run --scenario で絞る(全実施を頼まれたときだけ FT_FULL_TEST=1 を書く)")
        if head == "e2e-negative.sh" and not has_flag(words, ("--project",)):
            reasons.append("e2e-negative.sh に --project が無い(陽性対照の全体)。--project で絞る"
                           "(全実施を頼まれたときだけ FT_FULL_TEST=1 を書く)")
    if depth >= MAX_DEPTH:
        return reasons
    if head in SHELLS and len(words) >= 2 and words[1] != "-c" and not words[1].startswith("-"):
        reasons.extend(file_problems(words[1], env, full_ok, depth))
    elif "/" in words[0] and head not in SHELLS and head != "fleetest" and head not in FULL_SUITE_SCRIPTS:
        reasons.extend(file_problems(words[0], env, full_ok, depth))
    return reasons


def check(command, env=None, full_ok=None, depth=0):
    """断る理由の一覧(空 = 通す)"""
    outer = strip_heredocs(command)
    segs = segments(outer)
    if segs is None:
        return []
    full_ok = full_ok or "FT_FULL_TEST=1" in outer
    env = {**(env or {}), **assignments(outer)}
    classes = None
    reasons = []
    for tokens in segs:
        words = [t for t in tokens if not re.match(r"^\w+=", t)]  # 先頭の VAR=value を飛ばす
        # **`bash -c '<コマンド>'` の中も検査する**(引用の中は1つの語に見えるので、そのままだと素通りする)
        for i, tok in enumerate(words[:-1]):
            if os.path.basename(tok) in SHELLS and words[i + 1] == "-c" and i + 2 < len(words):
                reasons.extend(check(words[i + 2], env, full_ok, depth))  # 中身は打ったコマンドそのもの = 同じ深さ
        reasons.extend(device_run_problems(words, env, full_ok, depth))
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
    if depth < MAX_DEPTH:
        for body in heredoc_scripts(command):
            reasons.extend(script_text_problems(body, env, full_ok, depth + 1))
    return list(dict.fromkeys(reasons))


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
