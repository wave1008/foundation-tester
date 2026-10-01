#!/usr/bin/env python3
"""E2E / E2EX の結果 JSON から間欠失敗の発生率台帳を出す(デバイス不要・読むだけ)。

  python3 Scripts/flake-ledger.py                       # 直近14日・標準3プロファイル
  python3 Scripts/flake-ledger.py --since 2026-09-29T13 --by host
  python3 Scripts/flake-ledger.py --runs-file ab.tsv    # 「runID<TAB>ラベル」の行で run を条件別に束ねる

- 率は必ず機械別に読む(実測の台帳: 静かなリモート機 0.2%・負荷テストを回す機械 2〜4%。混ぜると環境差がツールの率に見える)
- 分母の揃え方は docs/results-json.md §フレークの推移を見る。中断・--set 上書き・abortReason・skipKind・小さな run は除く
- 「毎回落ちる」(キー内で全部赤)は開発中の witness として間欠失敗から外し、件数だけ出す
- 失敗の束ねは (command, failureKind, 正規化した detail)。製品側の仕分けではないので文言一致で構わない
"""
import argparse, collections, datetime, glob, json, os, re, sys
from concurrent.futures import ProcessPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read_run(rundir):
    try:
        meta = json.load(open(os.path.join(rundir, "run.json")))
    except Exception:
        return []
    files = glob.glob(os.path.join(rundir, "scenarios", "*.json"))
    run_excluded = bool(meta.get("interrupted") or meta.get("setOverrides") or meta.get("abortReason"))
    anomalies = ",".join(sorted({a.get("kind", "?") for a in meta.get("workerAnomalies") or []}))
    rows = []
    for f in files:
        try:
            d = json.load(open(f))
        except Exception:
            continue
        passed = bool(d.get("passed"))
        first = {} if passed else (d.get("failedSteps") or [{}])[0]
        detail = "" if passed else (first.get("detail") or (d.get("errorLogs") or [""])[-1] or "")
        rows.append({
            "project": meta.get("project", ""), "run": meta.get("runID", ""), "profile": meta.get("profile") or "",
            "host": meta.get("host", ""), "runSize": len(files), "anomalies": anomalies,
            "excluded": run_excluded or bool(d.get("skipKind") or d.get("interrupted")),
            "scenario": d.get("scenarioID", ""), "worker": d.get("worker") or "", "passed": passed,
            "command": first.get("command") or "-", "failureKind": first.get("failureKind") or "-",
            "detail": detail.replace("\n", " "), "startedAt": d.get("startedAt", ""),
        })
    return rows


def norm(s):
    s = re.sub(r'"[^"]*"', '"…"', s)
    return re.sub(r"\d+(\.\d+)?", "N", s)[:110]


def pct(a, b):
    return f"{a:5}/{b:7} {a / b:6.2%}" if b else f"{a:5}/{b:7}     -"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--projects", default="E2E*", help="TestProjects/ 直下の glob")
    ap.add_argument("--since", default=(datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=14)).strftime("%Y-%m-%d"),
                    help="startedAt(UTC・ISO8601 の前方一致比較)の下限")
    ap.add_argument("--until", default="9999")
    ap.add_argument("--profiles", default="android,ios-inapp,ios-xcuitest")
    ap.add_argument("--min-run-size", type=int, default=10, help="これ未満の run はデバッグ用とみなして除く")
    ap.add_argument("--by", default="host", help="内訳の軸: host / label(--runs-file)/ none")
    ap.add_argument("--runs-file", help="runID<TAB>ラベル の行。指定すると対象をその run に絞り、--since と --min-run-size は効かない")
    ap.add_argument("--top", type=int, default=20)
    a = ap.parse_args()

    labels = None
    if a.runs_file:
        labels = dict(l.rstrip("\n").split("\t", 1) for l in open(a.runs_file) if "\t" in l)
    months = sorted({m for m in [a.since[:7]] if len(a.since) >= 7})
    dirs = [d for d in glob.glob(os.path.join(ROOT, "TestProjects", a.projects, "results", "runs", "*", "*"))
            if os.path.isdir(d) and (labels is None or os.path.basename(d) in labels)
            and (labels is not None or not months or os.path.basename(os.path.dirname(d)) >= months[0])]
    with ProcessPoolExecutor(min(12, os.cpu_count() or 4)) as ex:
        rows = [r for rs in ex.map(read_run, dirs, chunksize=50) for r in rs]

    profiles = set(a.profiles.split(","))

    def keep(r):
        if r["excluded"] or r["profile"] not in profiles:
            return False
        if labels is not None:
            return True
        return a.since <= r["startedAt"] < a.until and r["runSize"] >= a.min_run_size

    rows = [r for r in rows if keep(r)]
    if not rows:
        sys.exit("no scenario records matched")
    axis = (lambda r: labels[r["run"]]) if labels is not None and a.by == "label" else \
           (lambda r: r["host"]) if a.by == "host" else (lambda r: "all")

    key = lambda r: (r["project"], r["profile"], r["scenario"])
    groups = collections.defaultdict(list)
    for r in rows:
        groups[key(r)].append(r)
    always = {k for k, v in groups.items() if not any(x["passed"] for x in v)}
    flaky = [r for r in rows if not r["passed"] and key(r) not in always]

    print(f"# window {a.since}..{a.until}  profiles={a.profiles}  executions={len(rows)}")
    print(f"always-failing keys: {len(always)} ({sum(len(groups[k]) for k in always)} executions, excluded below)")
    print(f"intermittent failures: {pct(len(flaky), len(rows))}\n")

    def table(title, f):
        n = collections.Counter(f(r) for r in rows if key(r) not in always)
        c = collections.Counter(f(r) for r in flaky)
        print(f"## {title}")
        for k in sorted(n):
            print(f"  {pct(c[k], n[k])}  {k}")
        print()

    table(f"by {a.by}", axis)
    table(f"by {a.by} / project / profile", lambda r: (axis(r), r["project"], r["profile"]))
    table(f"by {a.by} / worker", lambda r: (axis(r), r["worker"]))

    print(f"## failure signatures (top {a.top})")
    for k, v in collections.Counter((axis(r), r["command"], r["failureKind"], norm(r["detail"])) for r in flaky).most_common(a.top):
        print(f"  {v:5}  {k}")
    print(f"\n## scenarios (top {a.top})")
    for k, v in collections.Counter((axis(r),) + key(r) for r in flaky).most_common(a.top):
        print(f"  {v:5}/{len(groups[k[1:]]):5}  {k}")


if __name__ == "__main__":
    main()
