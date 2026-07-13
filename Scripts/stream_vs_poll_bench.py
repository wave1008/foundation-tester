#!/usr/bin/env python3
"""デバイス画面配信の「ストリーミング vs ポーリング」キャプチャ負荷ベンチ。

計測対象(vscode 拡張の monitor.pollingMode トグルの2方式に対応):
  - ストリーミング: ftester-simstream(iOS) / ftester-androidstream(Android)。
    変化駆動でフレームを stdout に長さ前置 JPEG で流す。
  - ポーリング: `ftester api live serve` に {"cmd":"frame"} を fps 間隔で送る画面取得経路。
    iOS はブリッジ /screenshot、Android は adb exec-out screencap。

各ワークロードを 静止/モーション × 隣接ベースライン で計測し、以下を JSON + 表で出す:
  - proc_cpu: キャプチャプロセス(ツリー)の CPU。cputime デルタ/実時間で 1コア=100%。**主指標**
  - host delta: ftester api host-metrics(GUI モニタと同一計測系)の Mac 全体 CPU の
    「ワークロード時 − 直前 ambient」。device 側込みだが 10 コア分母で小信号はノイズに埋もれる。**補助**
  - fps: 実達成フレームレート。stream_kbps: ストリーミングの JPEG 出力帯域

隣接ベースライン: 各ワークロード直前に ambient(capture 無し)を測り差分を取る=時間ドリフト相殺。
モーション時は ambient=モーションのみ(capture 無し)にするので、差分はキャプチャ経路の正味コスト。

--- 必ず守る罠(このベンチの実装で全部踏んだ)---
  1. host-metrics / simstream / androidstream は **stdin EOF で即終了**する(常駐 CLI 共通規約)。
     Popen は必ず stdin=subprocess.PIPE を開いたまま保持する。閉じる/未指定で /dev/null を継承すると
     即 EOF → 0 サンプル・0 フレーム(静止で 0 なのと区別がつかず誤診の元)。stop() で terminate。
  2. ストリーミングは変化駆動。静止画面ではフレーム≈0(バグではなく仕様)。負荷を見るには
     モーション(iOS=アプリ切替 / Android=スクロール)が要る。静止 proc≈0.2%、モーション proc≈5%。
  3. ストリーミング helper が 0 フレームでも「壊れた/表示合成が要る」と即断しないこと。simstream は
     Simulator.app 無し・ヘッドレスでも動く(実測: 静止≈0fps・モーション≈10fps)。0 フレームの第一容疑は
     罠1(stdin=PIPE 未保持の即死)、次いで静止で変化が無いだけ(罠2。モーションを与えて切り分ける)。
     参考: `xcrun simctl io <udid> screenshot -`(stdout)は 0 バイトになる場合がある。ファイル出力で確認する。
  4. iOS ポーリングは XCUITest ブリッジ必須。serve が未起動なら自動起動(初回は build-for-testing で数分)。
     **cwd=リポジトリルート**でないと repo-root 検出に失敗して自動起動が無効化される。
  5. ホスト CPU は Mac 全体(コア数分母)。単一ワークロード差分は ambient 揺らぎ(±3pt 程度)に
     埋もれやすい。プロセス別 CPU を主、ホスト差分を補助に読む。
  6. Python の `for line in proc.stdout` は bufsize=1 を付けないとブロックバッファされ行が遅延する。

使い方:
  Scripts/stream_vs_poll_bench.py                       # 起動中の sim/emu を自動検出、両OS・静止+モーション
  Scripts/stream_vs_poll_bench.py --platform ios --conditions static --out /tmp/r.json
  Scripts/stream_vs_poll_bench.py --ios-udid <UDID> --android-serial emulator-5554
  Scripts/stream_vs_poll_bench.py --boot-ios-name シミュ1 --boot-android-name エミュ1 --project SampleApp
デバイスが無ければ --boot-*-name(+ --project)で `ftester api device-up` 起動、または事前に手動起動。
"""
import argparse, json, os, struct, subprocess, sys, threading, time

# ---- リポジトリルート・バイナリ解決 ---------------------------------------------
def find_repo_root():
    d = os.path.dirname(os.path.abspath(__file__))
    while d != "/":
        if os.path.exists(os.path.join(d, ".build/debug/ftester")):
            return d
        d = os.path.dirname(d)
    sys.exit("error: .build/debug/ftester が見つからない。swift build 後に実行するか --repo-root 指定")

def resolve_adb(cli):
    cands = []
    if cli:
        cands.append(cli)
    if os.environ.get("ANDROID_HOME"):
        cands.append(os.path.join(os.environ["ANDROID_HOME"], "platform-tools/adb"))
    if os.environ.get("HOME"):
        cands.append(os.path.join(os.environ["HOME"], "Library/Android/sdk/platform-tools/adb"))
    for p in os.environ.get("PATH", "").split(":"):
        if p:
            cands.append(os.path.join(p, "adb"))
    cands += ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
    for c in cands:
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None

# ---- host-metrics 収集(全フェーズ通して1本) ----------------------------------
class HostMetrics:
    def __init__(self, root, binary):
        self.root = root; self.bin = binary; self.samples = []; self.proc = None
    def start(self):
        # 罠1: stdin=PIPE 保持しないと /dev/null 継承で即 EOF 終了。罠6: bufsize=1 で行バッファ読み。
        self.proc = subprocess.Popen([self.bin, "api", "host-metrics", "--interval", "1"], cwd=self.root,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, text=True, bufsize=1)
        threading.Thread(target=self._read, daemon=True).start()
    def _read(self):
        for line in self.proc.stdout:
            try:
                d = json.loads(line)
                if d.get("kind") == "hostMetrics":
                    self.samples.append((d["ts"], d.get("cpu"), d.get("gpu"), d.get("memUsedBytes")))
            except Exception:
                pass
    def window(self, t0, t1):
        rows = [s for s in self.samples if t0 <= s[0] <= t1]
        cpu = [r[1] for r in rows if r[1] is not None]
        return (sum(cpu) / len(cpu)) if cpu else None
    def stop(self):
        if self.proc:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except Exception:
                self.proc.kill()

# ---- プロセスCPU時間(ps。1コア=100%) ----------------------------------------
def _parse_time(s):
    s = s.strip()
    if not s:
        return None
    days = 0
    if "-" in s:
        d, s = s.split("-", 1); days = int(d)
    sec = 0.0
    for part in s.split(":"):
        sec = sec * 60 + float(part)
    return sec + days * 86400

def _descendants(pid):
    out = [pid]
    try:
        for k in subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout.split():
            out += _descendants(int(k))
    except Exception:
        pass
    return out

def tree_cputime(pid):
    res = {}
    for p in _descendants(pid):
        try:
            t = _parse_time(subprocess.run(["ps", "-o", "time=", "-p", str(p)], capture_output=True, text=True).stdout)
            if t is not None:
                res[p] = t
        except Exception:
            pass
    return res

def tree_delta_pct(c0, c1, secs):
    total = 0.0
    for p in set(c0) | set(c1):
        a, b = c0.get(p), c1.get(p)
        if a is not None and b is not None:
            total += max(0.0, b - a)
        elif b is not None:
            total += b
    return 100.0 * total / secs if secs else 0.0

# ---- ワークロード --------------------------------------------------------------
class StreamWorkload:
    """simstream/androidstream。stdout の長さ前置 JPEG(W u16BE / H u16BE / LEN u32BE / JPEG)を
    drain してフレーム計数。罠1: stdin=PIPE 保持しないと即終了で 0 フレーム。"""
    def __init__(self, root, argv, stderr_path):
        self.root = root; self.argv = argv; self.stderr_path = stderr_path
        self.frames = 0; self.bytes = 0; self.proc = None; self.err = None
    def start(self):
        self.proc = subprocess.Popen(self.argv, cwd=self.root, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=open(self.stderr_path, "w"))
        threading.Thread(target=self._read, daemon=True).start()
    def _readn(self, n):
        buf = b""
        while len(buf) < n:
            c = self.proc.stdout.read(n - len(buf))
            if not c:
                return None
            buf += c
        return buf
    def _read(self):
        try:
            while True:
                hdr = self._readn(8)
                if hdr is None:
                    break
                _w, _h, ln = struct.unpack(">HHI", hdr)
                if self._readn(ln) is None:
                    break
                self.frames += 1; self.bytes += ln
        except Exception as e:
            self.err = str(e)
    def pid(self):
        return self.proc.pid if self.proc else None
    def stop(self):
        if self.proc:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except Exception:
                self.proc.kill()

class ServeWorkload:
    """`ftester api live serve` に {"cmd":"frame"} を fps 間隔で送る=ポーリング経路。
    serve は元々 stdin=PIPE 前提(コマンド送信)なので罠1は自然回避。iOS は refresh 先行でブリッジ ready 待ち。"""
    def __init__(self, root, argv, stderr_path, ios=False, fps=12):
        self.root = root; self.argv = argv; self.stderr_path = stderr_path; self.ios = ios; self.fps = fps
        self.frames = 0; self.proc = None; self.ready = threading.Event()
        self.stop_flag = False; self.first_err = None
    def start(self):
        self.proc = subprocess.Popen(self.argv, cwd=self.root, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=open(self.stderr_path, "w"), text=True, bufsize=1)
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._drive, daemon=True).start()
    def _read(self):
        for line in self.proc.stdout:
            try:
                d = json.loads(line)
            except Exception:
                continue
            k = d.get("kind")
            if k == "frame" and d.get("ok"):
                self.frames += 1
            elif k == "snapshot":
                if d.get("ok"):
                    self.ready.set()
                elif self.first_err is None:
                    self.first_err = d.get("error")
    def _send(self, obj):
        try:
            self.proc.stdin.write(json.dumps(obj) + "\n"); self.proc.stdin.flush()
        except Exception:
            pass
    def _drive(self):
        if self.ios:
            self._send({"cmd": "refresh"})   # 罠4: ブリッジ未起動なら serve が自動起動(初回は数分)
            self.ready.wait(timeout=180)
        else:
            self.ready.set()
        period = 1.0 / self.fps
        while not self.stop_flag:
            t = time.time()
            self._send({"cmd": "frame"})
            time.sleep(max(0.0, period - (time.time() - t)))
    def wait_ready(self, timeout):
        return self.ready.wait(timeout=timeout)
    def pid(self):
        return self.proc.pid if self.proc else None
    def stop(self):
        self.stop_flag = True
        if self.proc:
            try:
                self.proc.stdin.close()
            except Exception:
                pass
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except Exception:
                self.proc.kill()

# ---- モーション源(stream/poll 両方で共通に回す→差分がキャプチャコストになる) -----
class AndroidSwiper:
    def __init__(self, adb, serial):
        self.adb = adb; self.serial = serial; self.stop_flag = False
    def start(self):
        subprocess.run([self.adb, "-s", self.serial, "shell", "am", "start", "-n", "com.android.settings/.Settings"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        threading.Thread(target=self._loop, daemon=True).start()
    def _loop(self):
        y = [1500, 500]; i = 0
        while not self.stop_flag:
            subprocess.run([self.adb, "-s", self.serial, "shell", "input", "swipe",
                            "540", str(y[i % 2]), "540", str(y[(i + 1) % 2]), "100"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            i += 1
    def stop(self):
        self.stop_flag = True

class IosSwitcher:
    """iOS はブリッジ非依存の入力手段が無いので、アプリ切替(全画面遷移アニメ)をモーション源にする。"""
    def __init__(self, udid):
        self.udid = udid; self.stop_flag = False
    def start(self):
        threading.Thread(target=self._loop, daemon=True).start()
    def _loop(self):
        apps = ["com.apple.Preferences", "com.apple.mobilesafari", "com.apple.MobileAddressBook"]
        i = 0
        while not self.stop_flag:
            subprocess.run(["xcrun", "simctl", "launch", self.udid, apps[i % len(apps)]],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            i += 1; time.sleep(0.6)
    def stop(self):
        self.stop_flag = True

# ---- デバイス検出・起動 --------------------------------------------------------
def booted_ios():
    try:
        out = subprocess.run(["xcrun", "simctl", "list", "devices", "booted"], capture_output=True, text=True).stdout
        for line in out.splitlines():
            if "Booted" in line and "(" in line:
                return line.split("(")[1].split(")")[0]
    except Exception:
        pass
    return None

def first_android(adb):
    try:
        for line in subprocess.run([adb, "devices"], capture_output=True, text=True).stdout.splitlines():
            if "\tdevice" in line:
                return line.split("\t")[0]
    except Exception:
        pass
    return None

def device_up(root, binary, name, project):
    print(f"  device-up: {name} ...", flush=True)
    subprocess.run([binary, "api", "device-up", "--name", name] + (["--project", project] if project else []),
                   cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

# ---- 計測 ----------------------------------------------------------------------
class Bench:
    def __init__(self, args, root, binary, adb, outdir):
        self.a = args; self.root = root; self.bin = binary; self.adb = adb; self.outdir = outdir
        self.hm = HostMetrics(root, binary)
    def _measure(self, name, make_capture, proc_label, motion=None, ios_ready=False):
        a = self.a
        print(f"[{time.strftime('%H:%M:%S')}] {name} ...", flush=True)
        if motion:
            motion.start(); time.sleep(2)
        ta0 = time.time(); time.sleep(a.amb); ta1 = time.time()
        amb = self.hm.window(ta0, ta1)
        w = make_capture()
        w.start()
        if ios_ready:
            if not w.wait_ready(a.ready_timeout):
                print(f"    warn: iOS ブリッジ ready せず: {getattr(w, 'first_err', None)}", flush=True)
        time.sleep(a.warm)
        pid = w.pid(); c0 = tree_cputime(pid); f0 = w.frames; tw0 = time.time()
        time.sleep(a.meas)
        tw1 = time.time(); f1 = w.frames; c1 = tree_cputime(pid)
        work = self.hm.window(tw0, tw1)
        proc = tree_delta_pct(c0, c1, tw1 - tw0)
        w.stop()
        if motion:
            motion.stop()
        r = {"name": name, "proc_label": proc_label,
             "proc_cpu_pct": round(proc, 1),
             "fps": round((f1 - f0) / (tw1 - tw0), 2),
             "host_amb_cpu": round(amb, 4) if amb else None,
             "host_work_cpu": round(work, 4) if work else None,
             "host_delta_pct": round((work - amb) * 100, 1) if (amb and work is not None) else None}
        if hasattr(w, "bytes"):
            r["stream_kbps"] = round(w.bytes / 1024 / (tw1 - tw0), 1)
        print(f"    proc={r['proc_cpu_pct']}% fps={r['fps']} hostΔ={r['host_delta_pct']}pt", flush=True)
        time.sleep(a.cooldown)
        return r

    def _p(self, label):
        return os.path.join(self.outdir, f"{label}.stderr")

    def run(self):
        a = self.a
        self.hm.start(); time.sleep(3)
        res = []
        conds = a.conditions.split(",")
        if a.ios_udid and a.platform in ("ios", "both"):
            u = a.ios_udid; W = str(a.max_width); F = str(a.fps)
            def s_cap(tag):
                return lambda: StreamWorkload(self.root, [f"{self.root}/.build/debug/ftester-simstream",
                    "--udid", u, "--fps", F, "--max-width", W], self._p(tag))
            def p_cap(tag):
                return lambda: ServeWorkload(self.root, [self.bin, "api", "live", "serve", "--platform", "ios",
                    "--udid", u, "--max-width", W], self._p(tag), ios=True, fps=a.fps)
            subprocess.run(["xcrun", "simctl", "launch", u, "com.apple.Preferences"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
            if "static" in conds:
                res.append(self._measure("ios_stream_static", s_cap("ios_stream_s"), "simstream"))
                res.append(self._measure("ios_poll_static", p_cap("ios_poll_s"), "serve(bridge screenshot)", ios_ready=True))
            if "motion" in conds:
                res.append(self._measure("ios_stream_motion", s_cap("ios_stream_m"), "simstream", motion=IosSwitcher(u)))
                res.append(self._measure("ios_poll_motion", p_cap("ios_poll_m"), "serve(bridge screenshot)", motion=IosSwitcher(u), ios_ready=True))
        if a.android_serial and a.platform in ("android", "both"):
            s = a.android_serial; W = str(a.max_width); F = str(a.fps)
            def as_cap(tag):
                return lambda: StreamWorkload(self.root, [f"{self.root}/.build/debug/ftester-androidstream",
                    "--serial", s, "--adb", self.adb, "--fps", F, "--max-width", W], self._p(tag))
            def ap_cap(tag):
                return lambda: ServeWorkload(self.root, [self.bin, "api", "live", "serve", "--platform", "android",
                    "--serial", s, "--max-width", W], self._p(tag), fps=a.fps)
            subprocess.run([self.adb, "-s", s, "shell", "am", "start", "-n", "com.android.settings/.Settings"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
            if "static" in conds:
                res.append(self._measure("android_stream_static", as_cap("and_stream_s"), "androidstream(+screenrecord)"))
                res.append(self._measure("android_poll_static", ap_cap("and_poll_s"), "serve(+adb screencap)"))
            if "motion" in conds:
                res.append(self._measure("android_stream_motion", as_cap("and_stream_m"), "androidstream(+screenrecord)", motion=AndroidSwiper(self.adb, s)))
                res.append(self._measure("android_poll_motion", ap_cap("and_poll_m"), "serve(+adb screencap)", motion=AndroidSwiper(self.adb, s)))
        self.hm.stop()
        return res

# ---- 出力 ----------------------------------------------------------------------
def print_table(res):
    print("\n" + "=" * 78)
    print(f"{'workload':<26}{'proc%/core':>12}{'fps':>8}{'hostΔpt':>10}{'kbps':>10}")
    print("-" * 78)
    for r in res:
        print(f"{r['name']:<26}{r['proc_cpu_pct']:>11}%{r['fps']:>8}"
              f"{(str(r['host_delta_pct']) if r['host_delta_pct'] is not None else '-'):>10}"
              f"{(str(r.get('stream_kbps', '-'))):>10}")
    print("=" * 78)
    print("proc%/core=キャプチャプロセスCPU(主指標,1コア=100%) / hostΔ=Mac全体差分(補助,ノイズ有) / kbps=ストリーム帯域")

def main():
    ap = argparse.ArgumentParser(description="ストリーミング vs ポーリング キャプチャ負荷ベンチ")
    ap.add_argument("--platform", choices=["ios", "android", "both"], default="both")
    ap.add_argument("--conditions", default="static,motion", help="static,motion のカンマ区切り")
    ap.add_argument("--ios-udid", default=None, help="省略時は起動中の最初の sim")
    ap.add_argument("--android-serial", default=None, help="省略時は adb devices の最初の1台")
    ap.add_argument("--fps", type=int, default=12)
    ap.add_argument("--max-width", type=int, default=900)
    ap.add_argument("--amb", type=float, default=8.0, help="ambient 窓(秒)")
    ap.add_argument("--warm", type=float, default=5.0, help="ウォームアップ(秒)")
    ap.add_argument("--meas", type=float, default=15.0, help="計測窓(秒)")
    ap.add_argument("--cooldown", type=float, default=3.0)
    ap.add_argument("--ready-timeout", type=float, default=180.0, help="iOS ブリッジ ready 待ち上限(秒)")
    ap.add_argument("--adb", default=None)
    ap.add_argument("--repo-root", default=None)
    ap.add_argument("--project", default=None, help="--boot-*-name 用の device-up プロジェクト")
    ap.add_argument("--boot-ios-name", default=None, help="未起動なら device-up するプロファイル名(例: シミュ1)")
    ap.add_argument("--boot-android-name", default=None, help="未起動なら device-up するプロファイル名(例: エミュ1)")
    ap.add_argument("--out", default=None, help="結果 JSON 出力先")
    args = ap.parse_args()

    root = args.repo_root or find_repo_root()
    binary = f"{root}/.build/debug/ftester"
    adb = resolve_adb(args.adb)
    outdir = os.path.join(root, "bench-results", "stream-vs-poll")
    os.makedirs(outdir, exist_ok=True)

    if args.platform in ("ios", "both"):
        if not args.ios_udid and args.boot_ios_name:
            device_up(root, binary, args.boot_ios_name, args.project)
        args.ios_udid = args.ios_udid or booted_ios()
        if not args.ios_udid:
            print("warn: iOS sim が見つからない。--ios-udid か --boot-ios-name を指定(iOS はスキップ)", flush=True)
    if args.platform in ("android", "both"):
        if not adb:
            print("warn: adb が見つからない(Android はスキップ)", flush=True)
        else:
            if not args.android_serial and args.boot_android_name:
                device_up(root, binary, args.boot_android_name, args.project)
            args.android_serial = args.android_serial or first_android(adb)
            if not args.android_serial:
                print("warn: Android emu が見つからない。--android-serial か --boot-android-name を指定(Android はスキップ)", flush=True)

    print(f"repo={root} ios={args.ios_udid} android={args.android_serial} "
          f"fps={args.fps} max_width={args.max_width} conditions={args.conditions}", flush=True)
    res = Bench(args, root, binary, adb, outdir).run()
    print_table(res)
    out = {"params": vars(args), "host_cores_note": "host_delta_pct は Mac 全体コア分母", "phases": res}
    out_path = args.out or os.path.join(outdir, "results.json")
    with open(out_path, "w") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
    print(f"\n-> {out_path}", flush=True)

if __name__ == "__main__":
    main()
