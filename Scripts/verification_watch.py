#!/usr/bin/env python3
"""緑の run では1度も通らない経路の検証(陽性対照・指紋照合・FM の経路)を「見ている部分が変わったときだけ推奨する」ための台帳。

検証の単位(unit):
  negative:<project>/<profile>/<file>   Scripts/negative-controls.json の controls の1件(e2e-negative.sh)
  heal-verify                           Scripts/heal-verify.sh
  fm-verify                             Scripts/fm-verify.sh
監視対象は negative-controls.json の "watches"(common = 陽性対照の全件に効く・heal-verify・fm-verify)と各 control の "watches"。
陽性対照の unit は、そのシナリオファイル・プロファイル・表の自分の行も digest に含める。

**どの検証も既定では回さない**(ユーザー決定)。全部 ✅ だったときに record し、e2e.sh の終わりに stale が
「前回 ✅ のときから変わった」unit を推奨として出す。記録は .fleetest/verification-watch.json(clone ごと・git 管理外)。

使い方:
  verification_watch.py units                 全 unit
  verification_watch.py record <unit>...      いまの digest を ✅ として記録する
  verification_watch.py stale                 変わった・未記録の unit を "<unit>\t<changed|never>" で出す
  verification_watch.py files <unit>          digest に入るファイル(確認用)
"""
import glob
import hashlib
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TABLE = os.path.join(ROOT, "Scripts", "negative-controls.json")
# 差し替えはテスト用(本物の台帳を汚さない)
LEDGER = os.environ.get("FT_VERIFICATION_WATCH_LEDGER") or os.path.join(ROOT, ".fleetest", "verification-watch.json")


def table():
    return json.load(open(TABLE))


def control_unit(c):
    return f"negative:{c['project']}/{c['profile']}/{c['file']}"


def units(t):
    return [control_unit(c) for c in t["controls"]] + ["heal-verify", "fm-verify"]


def resolve(patterns):
    """glob(** 可)をリポジトリ内のファイルへ。0 件の pattern は MISSING として digest に残す(黙って空にしない)。"""
    files, missing = set(), []
    for p in patterns:
        hits = [h for h in glob.glob(os.path.join(ROOT, p), recursive=True) if os.path.isfile(h)]
        if not hits:
            missing.append(p)
        files.update(os.path.relpath(h, ROOT) for h in hits)
    return sorted(files), missing


def inputs(t, unit):
    """(patterns, extra) — extra は表の行など、ファイル以外で digest に入れるもの"""
    w = t["watches"]
    if unit in ("heal-verify", "fm-verify"):
        return w[unit], ""
    for c in t["controls"]:
        if control_unit(c) == unit:
            own = [f"TestProjects/{c['project']}/scenarios/_disabled/{c['file']}",
                   f"TestProjects/{c['project']}/profiles/runs/{c['profile']}.json"]
            return w["common"] + own + c["watches"], json.dumps(c, sort_keys=True, ensure_ascii=False)
    raise SystemExit(f"unknown unit: {unit}")


def digest(t, unit):
    patterns, extra = inputs(t, unit)
    files, missing = resolve(patterns)
    h = hashlib.sha256(extra.encode())
    for f in files:
        h.update(b"\0" + f.encode() + b"\0")
        h.update(open(os.path.join(ROOT, f), "rb").read())
    for m in missing:
        h.update(b"\0MISSING:" + m.encode())
    return h.hexdigest()


def load_ledger():
    try:
        return json.load(open(LEDGER))
    except (OSError, ValueError):
        return {}


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    cmd, args = sys.argv[1], sys.argv[2:]
    t = table()
    if cmd == "units":
        print("\n".join(units(t)))
    elif cmd == "files":
        files, missing = resolve(inputs(t, args[0])[0])
        print("\n".join(files + [f"MISSING: {m}" for m in missing]))
    elif cmd == "record":
        ledger = load_ledger()
        for u in args:
            ledger[u] = digest(t, u)
        os.makedirs(os.path.dirname(LEDGER), exist_ok=True)
        tmp = LEDGER + ".tmp"
        json.dump(ledger, open(tmp, "w"), indent=1, sort_keys=True)
        os.replace(tmp, LEDGER)
    elif cmd == "stale":
        ledger = load_ledger()
        for u in units(t):
            if u not in ledger:
                print(f"{u}\tnever")
            elif ledger[u] != digest(t, u):
                print(f"{u}\tchanged")
    else:
        raise SystemExit(f"unknown command: {cmd}")


if __name__ == "__main__":
    main()
