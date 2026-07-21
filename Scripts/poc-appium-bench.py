#!/usr/bin/env python3
# PoC: 自作ドライバ(hybrid/xcuitest) vs Appium の性能比較ベンチ。
# 使い方: python3 Scripts/poc-appium-bench.py <出力dir> [反復回数] [エンジン,カンマ区切り]
# 前提: PoC シミュレータ(machines/LDIPC96-poc.json)が Booted・アプリ導入済み・
#       Appium サーバが http://127.0.0.1:4723 で起動済み・.build/debug/ftester がビルド済み。
# 注意: エンジンブロック間で XCUITest ランナー(自作ブリッジ/WDA)が同一デバイスに同居すると
#       競合するため、engine ブロック順に実行し切替時にランナーを掃除する。
import json
import os
import pathlib
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
FTESTER = ROOT / ".build/debug/ftester"
POC_UDID = "8A590C3D-3B05-46F5-BC43-9791304A9969"

# (エンジン名, 実行プロファイル, 追加環境変数)。appium-tuned は常駐セッション(appium)に
# できるチューニングを全部載せた変種: usePrebuiltWDA・wdaLocalPort 固定・
# waitForIdleTimeout/animationCoolOffTimeout=0(FT_APPIUM_TUNED が settings 適用を有効化)
ENGINES = [
    ("hybrid", "ios-poc-hybrid", {}),
    ("xcuitest", "ios-poc-xcuitest", {}),
    # レバー1: quiescence 待ちスキップ(iosFastInput: true。FastInput.swift)
    ("xcuitest-fast", "ios-poc-xcuitest-fast", {}),
    ("appium", "ios-poc-appium", {}),
    ("appium-tuned", "ios-poc-appium",
     {"FT_APPIUM_TUNED": "1", "FT_APPIUM_USE_PREBUILT_WDA": "1",
      "FT_APPIUM_WDA_LOCAL_PORT": "8100"}),
]
SCENARIOS = [
    "タブが正しく遷移すること",
    "カートに商品を追加できること",
    "検索で絞り込めること",
    "ログイン入力バリデーションが働くこと",
]


def run_one(profile: str, scenario: str, log_path: pathlib.Path, extra_env=None):
    env = dict(os.environ, FT_EVENT_LOG_PATH=str(log_path), **(extra_env or {}))
    t0 = time.monotonic()
    p = subprocess.run(
        [str(FTESTER), "run", "--project", "sut-ec-mobile",
         "--profile", profile, "--scenario", scenario, "--skip-build"],
        cwd=ROOT, env=env, capture_output=True, text=True, timeout=1200,
    )
    wall = time.monotonic() - t0
    return wall, p.returncode, p.stdout[-3000:], p.stderr[-2000:]


def cleanup_runners():
    """XCUITest ランナー(自作ブリッジ/WDA)を PoC デバイスから引き剥がす。同一デバイスに
    2つの XCUITest ランナーが同居すると競合するため、エンジンブロック切替時に必ず呼ぶ。
    PoC デバイス向けの xcodebuild だけを対象にし、フリートのランナーには触れない。"""
    out = subprocess.run(["pgrep", "-fl", "xcodebuild"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if POC_UDID in line:
            pid = line.split()[0]
            subprocess.run(["kill", pid])
    # ランナーアプリ側(シミュレータ内)は simctl terminate で止める(WDA は appium が再起動する)
    apps = subprocess.run(["xcrun", "simctl", "listapps", POC_UDID],
                          capture_output=True, text=True).stdout
    for bundle in ("com.example.ftrunner.uitests.xctrunner",
                   "com.facebook.WebDriverAgentRunner.xctrunner"):
        if bundle in apps:
            subprocess.run(["xcrun", "simctl", "terminate", POC_UDID, bundle],
                           capture_output=True)
    time.sleep(2)


def main():
    out_dir = pathlib.Path(sys.argv[1]).resolve()
    iterations = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    only = set(sys.argv[3].split(",")) if len(sys.argv) > 3 else None
    out_dir.mkdir(parents=True, exist_ok=True)
    summary = []
    for engine, profile, extra_env in ENGINES:
        if only and engine not in only:
            continue
        cleanup_runners()
        eng_dir = out_dir / engine
        eng_dir.mkdir(exist_ok=True)
        # warmup(iter=0): セッション/ブリッジ確立・アプリ初回起動のコストを測定から除外
        for i in range(0, iterations + 1):
            for scenario in SCENARIOS:
                tag = f"{scenario}-{i:02d}"
                log_path = eng_dir / f"{tag}.ndjson"
                log_path.unlink(missing_ok=True)
                wall, rc, tail, err_tail = run_one(profile, scenario, log_path, extra_env)
                row = {
                    "engine": engine, "scenario": scenario, "iter": i,
                    "warmup": i == 0, "wall_s": round(wall, 2), "rc": rc,
                    "events": str(log_path),
                }
                summary.append(row)
                print(json.dumps(row, ensure_ascii=False), flush=True)
                if rc != 0:
                    (eng_dir / f"{tag}.fail.log").write_text(
                        f"--- stdout ---\n{tail}\n--- stderr ---\n{err_tail}\n")
        (out_dir / "summary.json").write_text(
            json.dumps(summary, ensure_ascii=False, indent=1))
    print(f"done: {out_dir}/summary.json")


if __name__ == "__main__":
    main()
