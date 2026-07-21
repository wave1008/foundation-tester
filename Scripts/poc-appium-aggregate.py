#!/usr/bin/env python3
# poc-appium-bench.py の出力(summary.json + *.ndjson)を集計し、
# エンジン別・シナリオ別・ステップ別の比較表(Markdown+JSON)を出力する。
# 使い方: python3 Scripts/poc-appium-aggregate.py <ベンチ出力dir>
import json
import pathlib
import statistics
import sys
from collections import defaultdict


def load_steps(ndjson_path: pathlib.Path):
    steps, finished_ok = [], None
    if not ndjson_path.exists():
        return steps, finished_ok
    for line in ndjson_path.read_text().splitlines():
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if ev.get("kind") == "step":
            steps.append(ev)
        elif ev.get("kind") == "scenarioFinished":
            ok = ev.get("passed")
            finished_ok = ok if finished_ok is None else (finished_ok and ok)
    return steps, finished_ok


def fmt_stats(values):
    if not values:
        return "-"
    med = statistics.median(values)
    mean = statistics.fmean(values)
    sd = statistics.stdev(values) if len(values) > 1 else 0.0
    return f"{med:.1f} / {mean:.1f} ± {sd:.1f}"


def main():
    out_dir = pathlib.Path(sys.argv[1]).resolve()
    summary = json.loads((out_dir / "summary.json").read_text())
    runs = [r for r in summary if not r["warmup"]]

    # engine×scenario 集計
    agg = defaultdict(lambda: {"wall": [], "dur": [], "snap": [], "act": [],
                               "wait": [], "steps": [], "fail": 0, "n": 0})
    # engine×scenario×step(index+description)集計
    step_agg = defaultdict(lambda: defaultdict(list))
    for r in runs:
        key = (r["engine"], r["scenario"])
        steps, ok = load_steps(pathlib.Path(r["events"]))
        a = agg[key]
        a["n"] += 1
        if r["rc"] != 0 or ok is False:
            a["fail"] += 1
            continue  # 失敗ランはタイミング集計から除外(打ち切り時間が混ざるため)
        a["wall"].append(r["wall_s"])
        a["dur"].append(sum(s.get("durationMs") or 0 for s in steps) / 1000)
        a["snap"].append(sum(s.get("snapshotMs") or 0 for s in steps) / 1000)
        a["act"].append(sum(s.get("actionMs") or 0 for s in steps) / 1000)
        a["wait"].append(sum(s.get("waitMs") or 0 for s in steps) / 1000)
        a["steps"].append(len(steps))
        for s in steps:
            sk = (s.get("scenario"), s.get("index"), s.get("description"))
            step_agg[sk][r["engine"]].append(
                (s.get("durationMs") or 0, s.get("snapshotMs") or 0,
                 s.get("actionMs") or 0, s.get("waitMs") or 0))

    lines = ["# PoC ベンチ集計", "",
             "値は 中央値 / 平均 ± 標準偏差(失敗ランはタイミングから除外)", ""]
    lines += ["## シナリオ別(エンジン比較)", "",
              "| シナリオ | エンジン | ラン | 失敗 | wall(s) | step計(s) | snapshot計(s) | action計(s) | wait計(s) |",
              "|---|---|---|---|---|---|---|---|---|"]
    scenarios = sorted({k[1] for k in agg})
    engines = ["hybrid", "xcuitest", "xcuitest-fast", "appium", "appium-tuned"]
    for sc in scenarios:
        for eng in engines:
            a = agg.get((eng, sc))
            if not a:
                continue
            lines.append(
                f"| {sc} | {eng} | {a['n']} | {a['fail']} | {fmt_stats(a['wall'])} | "
                f"{fmt_stats(a['dur'])} | {fmt_stats(a['snap'])} | "
                f"{fmt_stats(a['act'])} | {fmt_stats(a['wait'])} |")

    lines += ["", "## ステップ別(durationMs 中央値: " + " / ".join(engines) + ")", "",
              "| シナリオ | # | ステップ | " + " | ".join(engines) + " |",
              "|---" * (3 + len(engines)) + "|"]
    for sk in sorted(step_agg, key=lambda k: (str(k[0]), k[1] or 0)):
        per = step_agg[sk]
        cells = []
        for eng in engines:
            vals = [v[0] for v in per.get(eng, [])]
            cells.append(f"{statistics.median(vals):.0f}" if vals else "-")
        desc = (sk[2] or "").replace("|", "\\|")
        lines.append(f"| {sk[0]} | {sk[1]} | {desc} | " + " | ".join(cells) + " |")

    (out_dir / "aggregate.md").write_text("\n".join(lines) + "\n")
    (out_dir / "aggregate.json").write_text(json.dumps(
        {f"{k[0]}::{k[1]}": v for k, v in agg.items()}, ensure_ascii=False, indent=1))
    print(f"wrote {out_dir}/aggregate.md")


if __name__ == "__main__":
    main()
