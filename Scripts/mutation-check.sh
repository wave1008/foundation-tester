#!/usr/bin/env bash
# 変異テストを git worktree で並列実行する(2026-08-10 ユーザー指示)。
#
# 本線の作業ツリーには1バイトも書かない —— 変異は worktree 側にだけ適用するので、
# 「復元し忘れた変異がバイナリに残る」型の事故(rebuild-after-mutation-testing)が
# 構造的に起きない。worktree は使い回す(.build が温まっていれば増分ビルドで走る。
# 初回だけはコールドビルドで数分かかる)。
#
# 使い方:
#   Scripts/mutation-check.sh <mutations.json>
#
#   mutations.json: [
#     {"label": "paren-reject off",          # 表示名
#      "file":  "Sources/…/Foo.swift",       # 変異するファイル(リポジトリ相対)
#      "old":   "…",                         # 置換前(ちょうど1回出現すること)
#      "new":   "…",                         # 置換後
#      "filter": "FooTests|BarTests"},       # swift test --filter に渡す(密閉された
#     …                                      # テストだけを指定する。ホスト共有資源に
#   ]                                        # 触るテストは並列で走らせない)
#
# 判定: 変異でテストが落ちれば OK(検出)、緑のまま通れば SURVIVED(そのテストは
# その変異を殺せていない = テストを境界へ寄せるか、変異の置き場所を疑う)。
# SURVIVED か適用エラーが1件でもあれば exit 1。
#
# 環境変数: MUT_JOBS(同時実行数。既定 3)/ MUT_WORKTREE_ROOT(worktree の置き場。
# 既定はリポジトリの隣の <repo名>-mutwt)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
exec python3 - "$@" <<'PYEOF'
import json, os, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from queue import Queue

if len(sys.argv) != 2:
    sys.exit("usage: mutation-check.sh <mutations.json>")
mutations = json.load(open(sys.argv[1]))
if not isinstance(mutations, list) or not mutations:
    sys.exit("mutations.json must be a non-empty array")

# **デバイス実行の最中は走らせない**(2026-08-20)。変異自体は worktree(専用の .build)で
# 隔離されているが、同じ機械の CPU とシミュレータ/エミュレータを取り合うと、走っている
# run の所要が伸びて計測が濁る。**本線の swift test/build は論外**(実行中のバイナリが
# 差し替わって run のプロセスが SIGKILL される。CLAUDE.md の実害)。
# 承知のうえで重ねるときだけ MUT_ALLOW_DURING_RUN=1。
def device_run_in_progress():
    # 自分のコマンドラインにこの文字列は載らないので自己一致しない(pgrep の罠は CLAUDE.md)
    for pattern in ("Scripts/e2e.sh", "ftester run ", "ftester api run"):
        if subprocess.run(["pgrep", "-f", pattern], capture_output=True).returncode == 0:
            return pattern
    return None

if os.environ.get("MUT_ALLOW_DURING_RUN") != "1":
    busy = device_run_in_progress()
    if busy:
        sys.exit(f"device run in progress ({busy}). Wait for it, or set MUT_ALLOW_DURING_RUN=1"
                 " if you know the two will not compete for the same devices.")

repo = os.getcwd()
name = os.path.basename(repo)
root = os.environ.get("MUT_WORKTREE_ROOT", os.path.join(os.path.dirname(repo), f"{name}-mutwt"))
jobs = int(os.environ.get("MUT_JOBS", "3"))
log_dir = os.path.join(repo, ".ftester", "mutation", datetime.now().strftime("%Y%m%d-%H%M%S"))
os.makedirs(log_dir, exist_ok=True)

def sh(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)

# worktree プールを確保(既存なら使い回す。--detach なのでブランチは汚さない)
os.makedirs(root, exist_ok=True)
pool = []
for i in range(min(jobs, len(mutations))):
    wt = os.path.join(root, f"wt{i}")
    if not os.path.exists(os.path.join(wt, "Package.swift")):
        r = sh(["git", "worktree", "add", "--detach", wt, "HEAD"])
        if r.returncode != 0:
            sys.exit(f"git worktree add failed: {r.stderr.strip()}")
    pool.append(wt)

# worktree は「空いたものを借りて返す」(index の丸め当てだと、変異数がプール数を
# 超えたとき実行中の worktree に次の変異が重なる)
free_worktrees = Queue()
for wt in pool:
    free_worktrees.put(wt)

def run_one(index, mutation):
    wt = free_worktrees.get()
    try:
        return run_in(wt, index, mutation)
    finally:
        free_worktrees.put(wt)

def run_in(wt, index, mutation):
    label = mutation.get("label", f"mutation {index + 1}")
    # 作業ツリーの現状(未コミット含む)を worktree へ同期。.build は消さない(温かい
    # キャッシュが並列化の前提)。--delete は「本線で消したファイルの残留」を防ぐ
    r = sh(["rsync", "-a", "--delete",
            "--exclude=.git", "--exclude=.build", "--exclude=.ftester",
            "--exclude=node_modules", "--exclude=results", "--exclude=reports",
            f"{repo}/", f"{wt}/"])
    if r.returncode != 0:
        return (label, "ERROR", f"rsync failed: {r.stderr.strip()[:200]}", None)
    path = os.path.join(wt, mutation["file"])
    try:
        src = open(path).read()
    except OSError as e:
        return (label, "ERROR", str(e), None)
    if src.count(mutation["old"]) != 1:
        return (label, "ERROR",
                f"anchor found {src.count(mutation['old'])} times (must be exactly 1)", None)
    open(path, "w").write(src.replace(mutation["old"], mutation["new"], 1))
    log = os.path.join(log_dir, f"{index + 1}-{re.sub(r'[^A-Za-z0-9._-]', '_', label)}.log")
    with open(log, "w") as out:
        r = subprocess.run(["swift", "test", "--parallel", "--filter", mutation["filter"]],
                           cwd=wt, stdout=out, stderr=subprocess.STDOUT, text=True)
    body = open(log, errors="replace").read()
    failed = sorted(set(re.findall(r"\[\w+\.\w+ (test\w+)\]' failed", body)))
    if r.returncode != 0 and not failed and "error:" in body:
        return (label, "ERROR", "build failed (mutation does not compile) — see log", log)
    return (label, "OK" if r.returncode != 0 else "SURVIVED",
            ", ".join(failed) if failed else "-", log)

with ThreadPoolExecutor(max_workers=len(pool)) as executor:
    results = list(executor.map(lambda t: run_one(*t), enumerate(mutations)))

width = max(len(r[0]) for r in results)
bad = 0
for label, verdict, detail, log in results:
    print(f"{label.ljust(width)}  {verdict:9}  {detail}")
    if verdict != "OK":
        bad += 1
        if log:
            print(f"{''.ljust(width)}  {'':9}  log: {log}")
print(f"\n{len(results) - bad}/{len(results)} mutations detected. logs: {log_dir}")
if bad:
    print("SURVIVED = そのテストはその変異を殺せていない / ERROR = 変異を適用できていない")
sys.exit(1 if bad else 0)
PYEOF
