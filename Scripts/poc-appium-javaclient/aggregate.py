#!/usr/bin/env python3
# PocJavaClientBench の NDJSON を集計する。ログイン3クラスは既存エンジンの
# 「ログイン入力バリデーションが働くこと」(1ランに3テスト)と比較できるよう反復毎に合算する。
# 使い方: aggregate.py <plain.ndjson> [tuned.ndjson]
import json
import re
import statistics
import sys
from collections import defaultdict

# step 行は desc 内の引用符が JSON エスケープされていない(Java 側の出力仕様)ため、
# json.loads に失敗したら正規表現で救済する
STEP_RE = re.compile(
    r'^\{"kind":"step","scenario":"([^"]*)","iter":(\d+),"index":(\d+),"desc":"(.*)","ms":(\d+)\}\s*$')


def load(path, label):
    classes, steps = [], []
    for line in open(path):
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            m = STEP_RE.match(line)
            if not m:
                continue
            ev = {"kind": "step", "scenario": m.group(1), "iter": int(m.group(2)),
                  "index": int(m.group(3)), "desc": m.group(4), "ms": int(m.group(5))}
        ev["variant"] = label
        (classes if ev.get("kind") == "class" else steps).append(ev)
    return classes, steps


def scen_key(name):
    return "ログイン入力バリデーションが働くこと" if name.startswith("ログイン") else name


def report(classes, steps, label):
    print(f"== {label}")
    grouped = defaultdict(lambda: defaultdict(lambda: {"wall": 0, "session": 0, "n": 0, "fail": 0}))
    for c in classes:
        if c["warmup"]:
            continue
        g = grouped[scen_key(c["scenario"])][c["iter"]]
        g["wall"] += c["wallMs"] / 1000
        g["session"] += c["sessionMs"] / 1000
        g["n"] += 1
        if not c["passed"]:
            g["fail"] += 1
    for sc, iters in grouped.items():
        walls = [v["wall"] for v in iters.values()]
        sessions = [v["session"] for v in iters.values()]
        fails = sum(v["fail"] for v in iters.values())
        print(f"  {sc}: wall中央値 {statistics.median(walls):.1f}s "
              f"(セッション {statistics.median(sessions):.1f}s) 反復{len(walls)} 失敗{fails}")
    kinds = defaultdict(list)
    for s in steps:
        if s["iter"] == 0:
            continue
        d = s["desc"]
        kind = d.split(" ")[0].rstrip('"')
        kinds[kind].append(s["ms"])
    for kind in ("tap", "exist", "type", "ifCanSelect"):
        vals = kinds.get(kind, [])
        if vals:
            print(f"  {kind}: 中央値 {statistics.median(vals):.0f}ms (n={len(vals)})")


for i, path in enumerate(sys.argv[1:]):
    label = ["plain(クラス毎セッション)", "tuned(使い回し+全チューニング)"][i] if i < 2 else path
    classes, steps = load(path, label)
    report(classes, steps, label)
