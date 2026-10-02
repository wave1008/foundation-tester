#!/usr/bin/env python3
# 陽性対照の判定(Scripts/e2e-negative.sh が呼ぶ)。期待値は Scripts/negative-controls.json。
# 判定は3値 —— ok / fail / unverified。**unverified を ok に畳まない**(FM が死んでいる・既知の見逃し =
# 何を確かめていないかを一覧で出す)。純粋関数 judge_scenario は vscode-fleetest/test/negativeControls.test.mjs が叩く。
#
# 使い方: negative_controls_judge.py <table.json> <plan.tsv> [<summary.json>]
#   plan.tsv の1行 = "<controls の添字>\t<run ディレクトリ>"(空なら実行されていない)
import glob
import json
import os
import sys


def _failed_step(result):
    steps = result.get("failedSteps") or []
    return steps[0] if steps else {}


def _notes(result):
    return {n for st in (result.get("timeline") or []) for n in (st.get("notes") or [])}


def fm_gave_no_verdict(result):
    """その run で FM が判定を返さなかった事実(注記か失敗文言)。FM の生死の推測はしない"""
    detail = _failed_step(result).get("detail") or ""
    return "visibility-guard-skipped" in _notes(result) or "FM gave no verdict" in detail


def judge_scenario(spec, result):
    """(verdict, reasons) を返す。verdict は "ok" / "fail" / "unverified"。result が None = 結果が無い"""
    if result is None:
        return "fail", ["結果が無い(実行されていない・またはビルドに失敗した)"]
    passed = bool(result.get("passed"))

    if spec["expect"] == "green":
        if passed:
            return "ok", []
        fs = _failed_step(result)
        return "fail", [f"緑のはずが赤: {fs.get('description')} — {(fs.get('detail') or '')[:200]}"]

    if passed:
        return "fail", ["赤のはずが緑(守っている経路が発火していない)"]

    fs = _failed_step(result)
    detail = fs.get("detail") or ""
    problems = []
    if "command" in spec and fs.get("command") != spec["command"]:
        problems.append(f"落ちたコマンドが {spec['command']} でない: {fs.get('command')}({fs.get('description')})")
    if "failureKind" in spec and fs.get("failureKind") != spec["failureKind"]:
        problems.append(f"failureKind が {spec['failureKind']} でない: {fs.get('failureKind')}")
    for s in spec.get("detailContains", []):
        if s not in detail:
            problems.append(f"失敗文言に「{s}」が無い: {detail[:200]}")
    notes = _notes(result)
    for n in spec.get("notesContains", []):
        if n not in notes:
            problems.append(f"注記 {n} が無い: {sorted(notes)}")

    crash = result.get("appCrash")
    if spec.get("knownGap"):
        if crash:
            return "fail", [f"既知の見逃しのはずが記録された({crash.get('evidence')})。直ったなら表の knownGap を外す"]
        if problems:
            return "fail", problems
        return "unverified", [f"既知の見逃し: {spec['knownGap']}"]
    want = spec.get("appCrash")
    if want == "any" and not crash:
        problems.append("appCrash が無い(クラッシュを記録していない)")
    elif want and want != "any" and (crash or {}).get("evidence") != want:
        problems.append(f"appCrash.evidence が {want} でない: {crash}")

    if spec.get("requiresFM") and fm_gave_no_verdict(result):
        # 赤ではあるが FM 以外の段(OCR)で落ちている = FM の経路を通したことにならない
        return "unverified", ["FM が判定を返さなかった(この機械の FM が使えない)。FM の経路は未検証"]
    for s in spec.get("detailNotContains", []):
        if s in detail:
            problems.append(f"失敗文言に「{s}」がある(狙いと別の段で落ちている): {detail[:200]}")
    by_kind = ((result.get("fm") or {}).get("byKind") or {})
    for kind, at_least in (spec.get("fmCallsAtLeast") or {}).items():
        calls = (by_kind.get(kind) or {}).get("calls", 0)
        if calls < at_least:
            problems.append(f"fm.byKind.{kind}.calls が {at_least} 未満: {calls}")

    return ("fail", problems) if problems else ("ok", [])


def load_results(run_dir):
    out = {}
    for f in glob.glob(os.path.join(run_dir, "scenarios", "*.json")) if run_dir else []:
        d = json.load(open(f))
        out[d.get("scenarioID", "")] = d
    return out


def main():
    table = json.load(open(sys.argv[1]))
    controls = table["controls"]
    summary_path = sys.argv[3] if len(sys.argv) > 3 else None
    counts = {"ok": 0, "fail": 0, "unverified": 0}
    fm_verified = None  # requiresFM の対照が ok になったら True(FM の経路を実際に通った)
    marks = {"ok": "✅", "fail": "❌", "unverified": "⚠️"}

    for line in open(sys.argv[2]):
        if not line.strip():
            continue
        idx, _, run = line.rstrip("\n").partition("\t")
        c = controls[int(idx)]
        results = load_results(run.strip())
        print(f"\n{c['project']} / {c['profile']} / {c['file']}")
        for sid, spec in c["scenarios"].items():
            verdict, reasons = judge_scenario(spec, results.get(f"{c['class']}.{sid}"))
            counts[verdict] += 1
            if spec.get("requiresFM"):
                fm_verified = (verdict == "ok") if fm_verified is None else (fm_verified and verdict == "ok")
            print(f"  {marks[verdict]} {sid}({spec['expect']})")
            for r in reasons:
                print(f"      {r}")

    print(f"\n陽性対照: ✅ {counts['ok']} / ❌ {counts['fail']} / ⚠️ 未検証 {counts['unverified']}")
    if summary_path:
        json.dump({"counts": counts, "fmVerified": fm_verified}, open(summary_path, "w"))
    sys.exit(1 if counts["fail"] else 0)


if __name__ == "__main__":
    main()
